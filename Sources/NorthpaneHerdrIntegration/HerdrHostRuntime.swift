import Foundation
import NorthpaneHostRuntime
import NorthpaneProtocol

/// Binds Herdr's CLI, events and terminal stream to one runtime scope. Consumers
/// use HostRuntime; all Herdr-specific process and subscription details stay here.
public actor HerdrHostRuntime: HostRuntime {
    private let runner: any HerdrCommandRunning
    private let runtime: HerdrRuntime
    private let executableURL: URL
    private let sessionName: String?
    private let incarnationID: String
    private let activity: any PaneActivityReading
    private var serverProcess: Process?
    private var version: String?

    public init(executableURL: URL? = nil, sessionName: String? = nil,
                incarnationID: String = UUID().uuidString,
                activity: any PaneActivityReading = PaneActivityProbe()) throws {
        let runner = try HerdrProcessRunner(executableURL: executableURL)
        self.runner = runner
        self.executableURL = runner.executableURL
        self.sessionName = sessionName.flatMap { $0.isEmpty ? nil : $0 }
        self.incarnationID = incarnationID
        self.activity = activity
        runtime = HerdrRuntime(runner: runner, incarnationID: incarnationID, activity: activity)
    }

    /// Allows adapter conformance tests to exercise commands without launching Herdr.
    init(runner: any HerdrCommandRunning, executableURL: URL, sessionName: String?,
         incarnationID: String, activity: any PaneActivityReading = PaneActivityProbe()) {
        self.runner = runner; self.executableURL = executableURL; self.sessionName = sessionName
        self.incarnationID = incarnationID; self.activity = activity
        runtime = HerdrRuntime(runner: runner, incarnationID: incarnationID, activity: activity)
    }

    public var descriptor: RuntimeDescriptor {
        get async {
            if version == nil {
                if let configured = ProcessInfo.processInfo.environment["NORTHPANE_HERDR_VERSION"], !configured.isEmpty {
                    version = configured
                } else if let output = try? await runner.run(arguments: ["--version"]) {
                    let text = String(decoding: output, as: UTF8.self)
                    version = text.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression).map { String(text[$0]) } ?? "unknown"
                } else { version = "unavailable" }
            }
            return RuntimeDescriptor(kind: .herdr, version: version!, incarnationID: incarnationID)
        }
    }

    public func ensureRunning() async throws {
        if serverProcess?.isRunning == true { return }
        if let sessionName {
            guard sessionName.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil else {
                throw HerdrRuntimeError.commandFailed("invalid session name")
            }
        }
        let arguments = (sessionName.map { ["--session", $0] } ?? []) + ["server"]
        let process = Process()
        #if os(Windows)
        // The WMI service starts a process outside the SSH session, so ending
        // the Bridge connection does not terminate the user's Herdr server.
        guard !executableURL.path.contains("'"), !executableURL.path.contains("\"") else {
            throw HerdrRuntimeError.commandFailed("the path to herdr cannot be quoted safely")
        }
        let command = ([executableURL.path] + arguments).joined(separator: "\" \"")
        process.executableURL = URL(fileURLWithPath: #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#)
        process.arguments = ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
            "$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = '\"\(command)\"' }; exit $r.ReturnValue"]
        #else
        process.executableURL = executableURL
        process.arguments = arguments
        #endif
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        #if os(Windows)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw HerdrRuntimeError.commandFailed("herdr server could not be started") }
        #else
        serverProcess = process
        #endif
    }

    public func currentSnapshot(hostID: HostID) async throws -> WireRuntimeSnapshot {
        try await runtime.currentSnapshot(hostID: hostID, sessionName: sessionName)
    }

    public func changes() -> any RuntimeChanges { HerdrRuntimeChanges(sessionName: sessionName) }

    public func createWorkspace(label: String, workingDirectory: String, environment: [String: String]) async throws -> CreatedPane {
        try await runtime.createWorkspace(label: label, workingDirectory: workingDirectory, sessionName: sessionName, environment: environment)
    }

    public func createTab(workspaceID: String, workingDirectory: String) async throws -> CreatedPane {
        try await runtime.createTab(workspaceID: workspaceID, workingDirectory: workingDirectory, sessionName: sessionName)
    }

    public func splitPane(paneID: String, direction: PaneSplitDirection, workingDirectory: String) async throws -> CreatedPane {
        try await runtime.splitPane(paneID: paneID, direction: direction, workingDirectory: workingDirectory, sessionName: sessionName)
    }

    public func renameWorkspace(workspaceID: String, label: String) async throws {
        try await runtime.renameWorkspace(workspaceID: workspaceID, label: label, sessionName: sessionName)
    }

    public func closeWorkspace(workspaceID: String) async throws {
        try await runtime.closeWorkspace(workspaceID: workspaceID, sessionName: sessionName)
    }

    public func startAgent(_ kind: WorkspaceAgentKind, executableURL: URL, name: String, paneID: String) async throws {
        try await runtime.startAgent(kind, executableURL: executableURL, name: name, paneID: paneID, sessionName: sessionName)
    }

    public func hostScrollbackLines(paneID: String) async -> Int {
        await runtime.hostScrollbackLines(paneID: paneID, sessionName: sessionName)
    }

    public func paneActivity(paneIDs: [String]) -> [String: Date] {
        activity.lastActivity(paneIDs: paneIDs, now: Date())
    }

    public func makeTerminalChannel(paneID: String, mode: TerminalAttachMode) throws -> any TerminalChannel {
        let herdrMode: HerdrTerminalSession.Mode = switch mode {
        case .observe: .observe
        case .control: .control
        case .takeover: .takeover
        }
        return HerdrTerminalChannel(session: HerdrTerminalSession(executableURL: executableURL, paneID: paneID,
                                                                sessionName: sessionName, mode: herdrMode))
    }
}

private struct HerdrTerminalChannel: TerminalChannel {
    let session: HerdrTerminalSession
    func start(columns: Int, rows: Int, onOutput: @escaping @Sendable (Data) -> Void,
               onClose: @escaping @Sendable (Error?) -> Void) throws {
        try session.start(columns: columns, rows: rows, onOutput: onOutput, onClose: onClose)
    }
    func sendInput(_ data: Data) throws { try session.sendInput(data) }
    func resize(columns: Int, rows: Int) throws { try session.resize(columns: columns, rows: rows) }
    func scroll(direction: TerminalScrollDirection, lines: Int) throws {
        try session.scroll(direction: direction == .up ? .up : .down, lines: lines)
    }
    func release() throws { try session.release() }
    func stop() { session.stop() }
}

private final class HerdrRuntimeChanges: RuntimeChanges, @unchecked Sendable {
    private let subscription: HerdrEventSubscription
    private let agents: HerdrAgentStatusSubscriptions
    private let lock = NSLock()
    private var onEvent: (@Sendable () -> Void)?
    private var stopped = false

    init(sessionName: String?) {
        subscription = HerdrEventSubscription(sessionName: sessionName)
        agents = HerdrAgentStatusSubscriptions(sessionName: sessionName)
    }

    func start(onEvent: @escaping @Sendable () -> Void, onClose: @escaping @Sendable (Error?) -> Void) async throws {
        lock.withLock { self.onEvent = onEvent }
        try await subscription.start(onEvent: onEvent, onClose: onClose)
    }

    func updatePaneIDs(_ paneIDs: [String]) async {
        guard let callback = lock.withLock({ stopped ? nil : onEvent }) else { return }
        await agents.update(paneIDs: paneIDs.sorted(), onEvent: callback)
    }

    func stop() {
        lock.withLock { stopped = true; onEvent = nil }
        subscription.stop()
        Task { await agents.stop() }
    }
}

private actor HerdrAgentStatusSubscriptions {
    private let sessionName: String?
    private var current: HerdrEventSubscription?
    private var paneIDs: [String] = []
    private var generation = 0
    private var stopped = false

    init(sessionName: String?) { self.sessionName = sessionName }

    func update(paneIDs: [String], onEvent: @escaping @Sendable () -> Void) async {
        guard !stopped, paneIDs != self.paneIDs || current == nil else { return }
        generation += 1
        let expectedGeneration = generation
        current?.stop()
        current = nil
        self.paneIDs = paneIDs
        guard !paneIDs.isEmpty else { return }
        let subscription = HerdrEventSubscription(sessionName: sessionName, scope: .agentStatus(paneIDs: paneIDs))
        current = subscription
        do {
            try await subscription.start(onEvent: onEvent, onClose: { [weak self] _ in Task { await self?.closed(subscription) } })
            guard !stopped, generation == expectedGeneration, current === subscription else { subscription.stop(); return }
            onEvent()
        } catch {
            subscription.stop()
            closed(subscription)
        }
    }

    private func closed(_ subscription: HerdrEventSubscription) {
        guard current === subscription else { return }
        current = nil
        paneIDs = []
    }

    func stop() {
        stopped = true
        generation += 1
        current?.stop()
        current = nil
        paneIDs = []
    }
}
