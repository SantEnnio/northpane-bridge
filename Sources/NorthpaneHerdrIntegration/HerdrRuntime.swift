import Foundation
import NorthpaneProtocol

public enum HerdrRuntimeError: Error, Equatable, Sendable {
    case executableUnavailable
    case commandFailed(String)
    case malformedResponse
    case unstableSnapshot
    case sessionAlreadyRunning
    case sessionNotRunning
}

public struct CreatedWorkspace: Equatable, Sendable {
    public let workspaceID: String
    public let paneID: String
    public init(workspaceID: String, paneID: String) {
        self.workspaceID = workspaceID
        self.paneID = paneID
    }
}

public protocol HerdrCommandRunning: Sendable {
    func run(arguments: [String]) async throws -> Data
}

public struct HerdrProcessRunner: HerdrCommandRunning {
    public let executableURL: URL

    public init(executableURL: URL? = nil) throws {
        if let executableURL {
            self.executableURL = executableURL
            return
        }
        guard let path = Self.resolveExecutable(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        ) else {
            throw HerdrRuntimeError.executableUnavailable
        }
        self.executableURL = URL(fileURLWithPath: path)
    }

    /// Where Herdr is looked for, first match wins: the explicit override; the directory Herdr's own
    /// installer uses (`HERDR_INSTALL_DIR`, else `~/.local/bin` from install.sh, or
    /// `%LOCALAPPDATA%\Programs\Herdr\bin` from install.ps1); the package managers' prefixes;
    /// then `PATH`. The order matches the remote SSH command's `PATH`, so the Bridge runs the
    /// same Herdr a login shell on the Host would.
    static func resolveExecutable(
        environment: [String: String],
        homeDirectory: String,
        isExecutable: (String) -> Bool,
        windows: Bool = isWindows
    ) -> String? {
        if let explicit = environment["NORTHPANE_HERDR_EXECUTABLE"], isExecutable(explicit) { return explicit }
        let separator = windows ? "\\" : "/"
        let name = windows ? "herdr.exe" : "herdr"
        var directories: [String] = []
        if let installDirectory = environment["HERDR_INSTALL_DIR"], !installDirectory.isEmpty { directories.append(installDirectory) }
        if windows {
            if let localAppData = environment["LOCALAPPDATA"], !localAppData.isEmpty {
                directories.append("\(localAppData)\\Programs\\Herdr\\bin")
            }
        } else {
            directories += ["\(homeDirectory)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        }
        let pathVariable = environment["PATH"] ?? environment["Path"] ?? ""
        directories += pathVariable.split(separator: windows ? ";" : ":").map(String.init).filter { !$0.isEmpty }
        for directory in directories {
            let trimmed = directory.hasSuffix(separator) ? String(directory.dropLast()) : directory
            let candidate = trimmed + separator + name
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    #if os(Windows)
    static let isWindows = true
    #else
    static let isWindows = false
    #endif

    public func run(arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                let errors = Pipe()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                    guard process.terminationStatus == 0 else {
                        let detail = String(data: errorData.isEmpty ? data : errorData, encoding: .utf8) ?? "herdr command failed"
                        continuation.resume(throwing: HerdrRuntimeError.commandFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines)))
                        return
                    }
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public actor HerdrRuntime {
    private let runner: any HerdrCommandRunning
    private let incarnationID: String
    private let capabilities: Set<Capability>

    public init(runner: any HerdrCommandRunning, incarnationID: String = UUID().uuidString, capabilities: Set<Capability> = Set(Capability.allCases)) {
        self.runner = runner
        self.incarnationID = incarnationID
        self.capabilities = CapabilityRegistry.validated(capabilities)
    }

    public func currentSnapshot(hostID: HostID, sessionName: String? = nil, attempts: Int = 3) async throws -> WireRuntimeSnapshot {
        let count = max(1, attempts)
        for _ in 0..<count {
            let first = try await readSnapshot(sessionName: sessionName)
            let second = try await readSnapshot(sessionName: sessionName)
            guard first == second else { continue }
            return WireRuntimeSnapshot(
                hostID: hostID,
                incarnationID: incarnationID,
                snapshotID: UUID().uuidString,
                nextEventSequence: 0,
                panes: first.panes,
                capabilities: capabilities,
                workspaces: first.workspaces,
                tabs: first.tabs
            )
        }
        throw HerdrRuntimeError.unstableSnapshot
    }

    /// Creates one Herdr Workspace without changing the runtime's shared focus. The returned
    /// identities come from Herdr's response; Northpane never guesses them from labels or order.
    public func createWorkspace(label: String, workingDirectory: String, sessionName: String? = nil, environment: [String: String] = [:]) async throws -> CreatedWorkspace {
        var arguments: [String] = []
        if let sessionName, !sessionName.isEmpty { arguments += ["--session", sessionName] }
        arguments += ["workspace", "create", "--cwd", workingDirectory, "--label", label]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) { arguments += ["--env", "\(key)=\(value)"] }
        arguments.append("--no-focus")
        let data = try await runner.run(arguments: arguments)
        do {
            let response = try JSONDecoder().decode(WorkspaceCreateResponse.self, from: data)
            guard response.result.type == "workspace_created",
                  !response.result.workspace.workspaceID.isEmpty,
                  !response.result.rootPane.paneID.isEmpty,
                  response.result.rootPane.workspaceID == response.result.workspace.workspaceID
            else { throw HerdrRuntimeError.malformedResponse }
            return CreatedWorkspace(workspaceID: response.result.workspace.workspaceID, paneID: response.result.rootPane.paneID)
        } catch let error as HerdrRuntimeError {
            throw error
        } catch {
            throw HerdrRuntimeError.malformedResponse
        }
    }

    /// Closes the Workspace in the same Herdr session the client is observing. Herdr owns the
    /// lifecycle: closing the Workspace terminates its panes and foreground processes, but it does
    /// not remove the working directories or files those processes used.
    public func closeWorkspace(workspaceID: String, sessionName: String? = nil) async throws {
        var arguments: [String] = []
        if let sessionName, !sessionName.isEmpty { arguments += ["--session", sessionName] }
        arguments += ["workspace", "close", workspaceID]
        _ = try await runner.run(arguments: arguments)
    }

    /// Lines Herdr is keeping above a pane's viewport, from the last snapshot it answered with.
    ///
    /// Zero means there is nothing up there to page, and that is the one thing worth knowing about
    /// a pane before scrolling it: an app drawing on the alternate screen (OpenCode) never has any
    /// Host scrollback, while a shell — and the agents that write their transcript into the normal
    /// buffer, Codex and Claude Code among them — has some as soon as its output outgrows the
    /// screen. The answer is a moment old at most: a scroll flick asks for it several times a
    /// second, and whether a pane keeps scrollback at all changes slowly.
    public func hostScrollbackLines(paneID: String, sessionName: String? = nil,
                                    now: Date = Date(), freshFor: TimeInterval = 1) async -> Int {
        if let read = scrollbackReadAt, now.timeIntervalSince(read) < freshFor { return scrollbackByPane[paneID] ?? 0 }
        _ = try? await readSnapshot(sessionName: sessionName)
        return scrollbackByPane[paneID] ?? 0
    }

    /// Kept apart from `NormalizedSnapshot` on purpose: it moves with every line a pane prints, and
    /// a snapshot is only accepted when two consecutive reads agree.
    private var scrollbackByPane: [String: Int] = [:]
    private var scrollbackReadAt: Date?

    private func readSnapshot(sessionName: String?) async throws -> NormalizedSnapshot {
        var arguments: [String] = []
        if let sessionName, !sessionName.isEmpty { arguments += ["--session", sessionName] }
        arguments += ["api", "snapshot"]
        let data = try await runner.run(arguments: arguments)
        do {
            let response = try JSONDecoder().decode(APIResponse.self, from: data)
            guard response.result.type == "session_snapshot" else { throw HerdrRuntimeError.malformedResponse }
            scrollbackByPane = Dictionary(response.result.snapshot.panes.map { ($0.paneID, $0.scroll?.maxOffsetFromBottom ?? 0) },
                                          uniquingKeysWith: { first, _ in first })
            scrollbackReadAt = Date()
            return NormalizedSnapshot(snapshot: response.result.snapshot)
        } catch let error as HerdrRuntimeError {
            throw error
        } catch {
            throw HerdrRuntimeError.malformedResponse
        }
    }

    /// Launches the exact executable already verified by Northpane, then asks Herdr to wait for
    /// its semantic state. `blocked` is a successful launch: first-run and update prompts are live
    /// agents which need operator input, not failed processes.
    public func startAgent(_ kind: WorkspaceAgentKind, executableURL: URL, name: String, paneID: String, sessionName: String? = nil, timeoutMilliseconds: Int = 30_000) async throws {
        guard kind != .shell else { return }
        let prefix = sessionName.flatMap { $0.isEmpty ? nil : ["--session", $0] } ?? []
        let command = "exec \(Self.shellQuote(executableURL.path))"
        _ = try await runner.run(arguments: prefix + ["pane", "run", paneID, command])
        // `pane run` acknowledges the terminal input before the lifecycle detector has necessarily
        // registered the new process. During that short window Herdr reports `agent_not_found`
        // instead of waiting. Retry only that precise race; every other CLI error remains fatal.
        let waitBudget = max(1_000, timeoutMilliseconds)
        let deadline = Date().addingTimeInterval(Double(waitBudget) / 1_000)
        var firstAttempt = true
        while true {
            let remaining = firstAttempt
                ? waitBudget
                : max(1, Int((deadline.timeIntervalSinceNow * 1_000).rounded(.up)))
            firstAttempt = false
            do {
                _ = try await runner.run(arguments: prefix + [
                    "agent", "wait", paneID,
                    "--until", "idle", "--until", "working", "--until", "blocked",
                    "--timeout", String(remaining),
                ])
                break
            } catch {
                guard Self.isAgentDetectionRace(error), Date() < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        // Naming is a convenience for later automation. The process is already live and observable
        // if this best-effort step races with a lifecycle transition.
        _ = try? await runner.run(arguments: prefix + ["agent", "rename", paneID, name])
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func isAgentDetectionRace(_ error: Error) -> Bool {
        guard case let HerdrRuntimeError.commandFailed(detail) = error else { return false }
        if let data = detail.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(HerdrCLIErrorEnvelope.self, from: data) {
            return envelope.error.code == "agent_not_found"
        }
        return detail.contains("agent_not_found")
    }
}

public extension WorkspaceAgentKind {
    var herdrKind: String {
        switch self {
        case .shell: "shell"
        case .codex: "codex"
        case .claude: "claude"
        case .openCode: "opencode"
        }
    }
}

public enum HerdrAgentNaming {
    public static func name(workspaceID: String) -> String {
        let body = workspaceID.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return String(("northpane-" + (body.isEmpty ? "agent" : body)).prefix(32))
    }
}

private struct WorkspaceCreateResponse: Decodable {
    struct Result: Decodable {
        struct Workspace: Decodable {
            let workspaceID: String
            enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
        }
        struct RootPane: Decodable {
            let paneID: String
            let workspaceID: String
            enum CodingKeys: String, CodingKey { case paneID = "pane_id", workspaceID = "workspace_id" }
        }
        let type: String
        let workspace: Workspace
        let rootPane: RootPane
        enum CodingKeys: String, CodingKey { case type, workspace, rootPane = "root_pane" }
    }
    let result: Result
}

private struct HerdrCLIErrorEnvelope: Decodable {
    struct Failure: Decodable { let code: String }
    let error: Failure
}

private struct APIResponse: Decodable {
    struct Result: Decodable {
        let type: String
        let snapshot: Snapshot
    }
    let result: Result
}

private struct Snapshot: Decodable {
    struct Workspace: Decodable {
        /// Herdr 0.8.2 reports `checkout_path` (with `repo_root`, `repo_key`, `repo_name` and
        /// `is_linked_worktree`) for a workspace opened through `herdr worktree`; `path` is kept only
        /// as a fallback. Reading `path` alone left every real Workspace without a worktree, so
        /// `northpane artifact publish` could never infer one.
        struct Worktree: Decodable {
            let checkoutPath: String?
            let path: String?
            var resolvedPath: String? { checkoutPath ?? path }
            enum CodingKeys: String, CodingKey { case checkoutPath = "checkout_path", path }
        }
        let workspaceID: String
        let label: String
        let number: Int
        let focused: Bool
        let activeTabID: String
        let worktree: Worktree?

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id", label, number, focused, activeTabID = "active_tab_id", worktree
        }
    }
    struct Tab: Decodable {
        let tabID: String
        let workspaceID: String
        let label: String
        let number: Int
        let focused: Bool

        enum CodingKeys: String, CodingKey {
            case tabID = "tab_id", workspaceID = "workspace_id", label, number, focused
        }
    }
    struct Pane: Decodable {
        /// What Herdr is holding above the pane's viewport.
        struct Scroll: Decodable {
            let maxOffsetFromBottom: Int
            enum CodingKeys: String, CodingKey { case maxOffsetFromBottom = "max_offset_from_bottom" }
        }
        let paneID: String
        let workspaceID: String
        let tabID: String
        let revision: Int
        let focused: Bool
        let label: String?
        let title: String?
        let terminalTitleStripped: String?
        let displayAgent: String?
        let agent: String?
        let agentStatus: String
        let cwd: String?
        let foregroundCwd: String?
        let scroll: Scroll?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id", workspaceID = "workspace_id", tabID = "tab_id", revision, focused, label, title
            case terminalTitleStripped = "terminal_title_stripped", displayAgent = "display_agent", agent, agentStatus = "agent_status"
            case cwd, foregroundCwd = "foreground_cwd", scroll
        }
    }
    let workspaces: [Workspace]
    let tabs: [Tab]
    let panes: [Pane]
}

private struct NormalizedSnapshot: Equatable {
    let workspaces: [WireWorkspace]
    let tabs: [WireTab]
    let panes: [WirePane]

    init(snapshot: Snapshot) {
        workspaces = snapshot.workspaces.map {
            WireWorkspace(id: $0.workspaceID, label: $0.label, number: $0.number, focused: $0.focused, activeTabID: $0.activeTabID, worktreePath: $0.worktree?.resolvedPath)
        }.sorted { $0.id < $1.id }
        tabs = snapshot.tabs.map {
            WireTab(id: $0.tabID, workspaceID: $0.workspaceID, label: $0.label, number: $0.number, focused: $0.focused)
        }.sorted { $0.id < $1.id }
        panes = snapshot.panes.map {
            let title = $0.label ?? $0.title ?? $0.terminalTitleStripped ?? $0.displayAgent ?? $0.paneID
            return WirePane(id: $0.paneID, title: title, workspaceID: $0.workspaceID, tabID: $0.tabID, revision: $0.revision, agent: $0.displayAgent ?? $0.agent, agentStatus: $0.agentStatus, focused: $0.focused, cwd: $0.foregroundCwd ?? $0.cwd)
        }.sorted { $0.id < $1.id }
    }
}

public final class HerdrTerminalSession: @unchecked Sendable {
    public enum Mode: Sendable { case observe, control, takeover }

    private let executableURL: URL
    private let paneID: String
    private let sessionName: String?
    private let mode: Mode
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var pending = Data()

    public init(executableURL: URL, paneID: String, sessionName: String? = nil, mode: Mode) {
        self.executableURL = executableURL; self.paneID = paneID; self.sessionName = sessionName; self.mode = mode
    }

    public func start(columns: Int, rows: Int, onOutput: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Error?) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard process == nil else { throw HerdrRuntimeError.sessionAlreadyRunning }
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        var arguments: [String] = []
        if let sessionName, !sessionName.isEmpty { arguments += ["--session", sessionName] }
        arguments += ["terminal", "session", mode == .observe ? "observe" : "control", paneID]
        if mode == .takeover { arguments.append("--takeover") }
        arguments += ["--cols", String(max(1, columns)), "--rows", String(max(1, rows))]
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data, onOutput: onOutput)
        }
        process.terminationHandler = { process in
            let error: Error? = process.terminationStatus == 0 ? nil : HerdrRuntimeError.commandFailed(String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "terminal session failed")
            onClose(error)
        }
        do { try process.run() }
        catch { throw HerdrRuntimeError.commandFailed(error.localizedDescription) }
        self.process = process
        self.input = inputPipe.fileHandleForWriting
    }

    public func sendInput(_ data: Data) throws {
        let object: [String: Any] = ["type": "terminal.input", "bytes": data.base64EncodedString()]
        try writeJSONLine(object)
    }

    public func resize(columns: Int, rows: Int) throws {
        try writeJSONLine(["type": "terminal.resize", "cols": max(1, columns), "rows": max(1, rows)])
    }

    /// Pages Herdr's own scrollback: the stream renders a viewport, so scrolling happens on the Host.
    /// Herdr accepts this only on a control stream; an observe stream ignores it.
    public func scroll(direction: ScrollDirection, lines: Int) throws {
        try writeJSONLine(["type": "terminal.scroll", "direction": direction.rawValue, "lines": max(1, lines)])
    }

    public enum ScrollDirection: String, Sendable { case up, down }

    public func release() throws { try writeJSONLine(["type": "terminal.release"]) }

    public func stop() {
        lock.lock()
        let process = self.process
        self.process = nil
        input = nil
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func writeJSONLine(_ object: [String: Any]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let input, process?.isRunning == true else { throw HerdrRuntimeError.sessionNotRunning }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func consume(_ data: Data, onOutput: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            lines.append(line)
        }
        lock.unlock()
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "terminal.frame",
                  let encoded = (object["bytes"] ?? object["data"]) as? String,
                  let bytes = Data(base64Encoded: encoded) else { continue }
            onOutput(bytes)
        }
    }
}
