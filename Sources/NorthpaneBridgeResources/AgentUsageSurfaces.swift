import Foundation
import NorthpaneProtocol

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One agent CLI a subscription can be read through. The Bridge never holds a credential of its
/// own: it runs the CLI the Host user installed, with the session that installation holds, and
/// signing out there blinds it.
public protocol AgentUsageSurface: Sendable {
    /// Chosen here and stable. Not the name of the binary, which may change and live anywhere.
    var providerID: String { get }
    var label: String { get }
    /// What a person should know of how this agent is read. Nil for a door its maker documents,
    /// and the absence is itself information.
    var notice: AgentUsageNotice? { get }
    /// Reading this agent carries a risk only the person whose account it is can take: until
    /// someone accepts the `notice` for this Host, the CLI is never run. Finding the binary, or
    /// a session that would work, is never a substitute.
    var needsConsent: Bool { get }
    /// Blocks for as long as the CLI takes, within its own deadline. Throws `AgentUsageFailure`.
    func read(now: Date) throws -> [AgentUsageMeter]
}

public struct AgentUsageNotice: Equatable, Sendable {
    public let text: String
    public let url: String?
    public init(text: String, url: String? = nil) { self.text = text; self.url = url }
}

public extension AgentUsageSurface {
    var notice: AgentUsageNotice? { nil }
    var needsConsent: Bool { false }
}

// The surfaces run a CLI, which only a Host can: the apps link this module for its types.
#if os(macOS) || os(Linux) || os(Windows)
/// A child process spoken to line by line, with a deadline after which it is stopped whatever
/// it is doing. Reads block the calling thread, so it is never used from the connection loop.
final class AgentCLIConversation: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let deadline: Date
    private let maximumBytes: Int

    init(executable: URL, arguments: [String], environment: [String: String] = [:], timeout: TimeInterval, maximumBytes: Int = 8 * 1_024 * 1_024) throws {
        self.maximumBytes = maximumBytes
        deadline = Date().addingTimeInterval(timeout)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, imposed in imposed }
        // A directory of its own: a CLI that keeps state per directory keeps it in one place,
        // away from the Host user's projects.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("northpane-agent-usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { Self.stop(process) }
    }

    func send(_ message: [String: Any]) throws {
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        // A child that already died would turn this write into a signal, not an error.
        guard process.isRunning else { throw AgentUsageFailure.unreachable }
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    func sendBytes(_ bytes: Data) throws {
        guard process.isRunning else { throw AgentUsageFailure.unreachable }
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }

    func readBytes(_ count: Int) -> Data? {
        guard count >= 0, count <= maximumBytes else { return nil }
        while buffer.count < count {
            guard let chunk = nextChunk(), buffer.count + chunk.count <= maximumBytes else { return nil }
            buffer.append(chunk)
        }
        let result = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return result
    }

    /// The next line, or nil once the child closed its output or the deadline stopped it.
    func nextLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                return Data(line)
            }
            guard let chunk = nextChunk() else {
                defer { buffer = Data() }
                return buffer.isEmpty ? nil : buffer
            }
            guard buffer.count + chunk.count <= maximumBytes else { return nil }
            buffer.append(chunk)
        }
    }

    /// What the child wrote next, or nil at the end of its output or at the deadline. Stopping
    /// the child is not enough to end a read: a process it started can outlive it holding the
    /// same pipe, so the wait itself is bounded and never relies on the pipe closing.
    private func nextChunk() -> Data? {
        #if os(Windows)
        let chunk = output.fileHandleForReading.availableData
        return chunk.isEmpty ? nil : chunk
        #else
        let descriptor = output.fileHandleForReading.fileDescriptor
        while Date() < deadline {
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, 100)
            if ready < 0, errno != EINTR { return nil }
            guard ready > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = read(descriptor, &bytes, bytes.count)
            if count > 0 { return Data(bytes[0..<count]) }
            if count == 0 || (errno != EINTR && errno != EAGAIN) { return nil }
        }
        return nil
        #endif
    }

    func readToEnd() -> Data {
        var everything = Data()
        while let line = nextLine() { everything.append(line); everything.append(0x0A) }
        return everything
    }

    /// Closing the input is how a line-oriented server is dismissed; what does not leave is stopped.
    func finish() {
        try? input.fileHandleForWriting.close()
        let grace = Date().addingTimeInterval(1)
        while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
        Self.stop(process)
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let grace = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
        #if !os(Windows)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        #endif
    }
}

/// Claude Code: invoked, waited for, read. `claude -p "/usage"` prints the plan's meters as text
/// for a person, at no token cost; the documentation says the command does not work in print
/// mode, and it does. It is an undeclared door: nobody has promised to keep that text, so when
/// it changes the reader stops (`ClaudeUsageProse`) instead of guessing.
public struct ClaudeUsageSurface: AgentUsageSurface {
    public let providerID = "claude"
    public let label = "Claude"
    public let notice: AgentUsageNotice? = .init(text: "Read by running the Claude CLI installed on this Host. Its output format can change without notice; if it does, the Bridge stops reading rather than guessing.")
    private let executable: URL
    private let timeout: TimeInterval

    public init(executable: URL, timeout: TimeInterval = 30) { self.executable = executable; self.timeout = timeout }

    public func read(now: Date) throws -> [AgentUsageMeter] {
        let usage = ["-p", "/usage", "--output-format", "json"]
        // Without these two every Reading would save a session on the Host and start the Host
        // user's MCP servers. A CLI too old to know them refuses the whole invocation, so the
        // plain one is the fallback.
        let quiet = ["--no-session-persistence", "--strict-mcp-config"]
        // The text follows the process's `TZ` and not its locale. Imposing it leaves a month,
        // a day and a time to put together, with no zone database and no daylight saving.
        let zone = ["TZ": ClaudeUsageProse.imposedZone]
        guard let envelope = run(usage + quiet, environment: zone) ?? run(usage, environment: zone) else { throw sessionFailure() }
        guard envelope["is_error"] as? Bool == false else { throw sessionFailure() }
        // An envelope that says success and carries no result is a CLI speaking another language.
        guard let prose = envelope["result"] as? String else { throw AgentUsageFailure.unreadable }
        return try ClaudeUsageProse.meters(in: prose, now: now)
    }

    private func run(_ arguments: [String], environment: [String: String] = [:]) -> [String: Any]? {
        guard let conversation = try? AgentCLIConversation(executable: executable, arguments: arguments, environment: environment, timeout: timeout) else { return nil }
        defer { conversation.finish() }
        return (try? JSONSerialization.jsonObject(with: conversation.readToEnd())) as? [String: Any]
    }

    /// `claude auth status` names the cause of a failure. It reads the local store without
    /// touching the network, so an expired session still says it is signed in: that case stays
    /// a failure that may pass, which is retried, rather than one that waits for a person.
    private func sessionFailure() -> AgentUsageFailure {
        guard let status = run(["auth", "status"]), let signedIn = status["loggedIn"] as? Bool else { return .unreachable }
        guard signedIn else { return .signedOut }
        let subscription = status["authMethod"] as? String == "claude.ai" && status["apiProvider"] as? String == "firstParty"
        return subscription ? .unreachable : .noPlan
    }
}

/// Codex: `codex app-server` speaks JSON-RPC, one message per line, and
/// `account/rateLimits/read` is its documented method. Nothing below it is touched.
public struct CodexUsageSurface: AgentUsageSurface {
    public let providerID = "codex"
    public let label = "Codex"
    private let executable: URL
    private let clientVersion: String
    private let timeout: TimeInterval
    private static let methodNotFound = -32_601

    public init(executable: URL, clientVersion: String = NorthpaneRelease.version, timeout: TimeInterval = 15) {
        self.executable = executable; self.clientVersion = clientVersion; self.timeout = timeout
    }

    public func read(now: Date) throws -> [AgentUsageMeter] {
        guard let conversation = try? AgentCLIConversation(executable: executable, arguments: ["app-server"], timeout: timeout) else { throw AgentUsageFailure.unreachable }
        defer { conversation.finish() }
        // `app-server` greets a client with no session too, so a refused greeting says nothing
        // of the session and borrows no cause from it.
        let client = ["name": "northpane-bridge", "title": "Northpane Bridge", "version": clientVersion]
        guard case .result = try call(conversation, id: 1, method: "initialize", parameters: ["clientInfo": client]) else { throw AgentUsageFailure.unreachable }
        try conversation.send(["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()])
        switch try call(conversation, id: 2, method: "account/rateLimits/read") {
        case let .result(limits): return try CodexRateLimits.meters(in: limits)
        case let .error(code):
            guard code != Self.methodNotFound else { throw AgentUsageFailure.unreadable }
            // The session decides, not the wording of the error.
            guard case let .result(account) = try call(conversation, id: 3, method: "account/read") else { throw AgentUsageFailure.unreachable }
            throw CodexRateLimits.sessionFailure(in: account) ?? .unreachable
        }
    }

    private enum Answer { case result(Any), error(code: Int) }

    private func call(_ conversation: AgentCLIConversation, id: Int, method: String, parameters: [String: Any] = [:]) throws -> Answer {
        try conversation.send(["jsonrpc": "2.0", "id": id, "method": method, "params": parameters])
        while let line = conversation.nextLine() {
            // Noise on the wire, and what the server says of its own accord, is not the answer.
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], (message["id"] as? NSNumber)?.intValue == id else { continue }
            if let result = message["result"] { return .result(result) }
            let code = ((message["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue ?? 0
            if code == Self.methodNotFound, id == 1 { throw AgentUsageFailure.unreadable }
            return .error(code: code)
        }
        throw AgentUsageFailure.unreachable
    }
}

/// Antigravity: `agy -p /usage --output-format json`, one invocation per Reading, which runs no
/// model and opens no turn. Google's Antigravity Additional Terms speak of third-party software
/// used to access the service, Google has not said whether this is that, and the remedy they
/// name reaches the account: so this agent is off until someone accepts that for the Host, and
/// accepting it is not Google's permission. Nothing else is ever asked of `agy`: no second
/// probe to name a failure, no other surface, nothing beneath the CLI.
public struct AntigravityUsageSurface: AgentUsageSurface {
    public let providerID = "antigravity"
    public let label = "Antigravity"
    public let notice: AgentUsageNotice? = .init(
        text: "Read by running the agy CLI installed on this Host once per reading, with the Google account it is signed in to. No model is invoked. Google's Antigravity Additional Terms restrict third-party software that accesses the service and Google has not said whether this counts: the consequences they name reach the Google account. Turning this on accepts that risk for this Host; it is not Google's permission.",
        url: "https://antigravity.google/terms")
    public let needsConsent = true
    private let executable: URL
    private let timeout: TimeInterval

    public init(executable: URL, timeout: TimeInterval = 90) { self.executable = executable; self.timeout = timeout }

    /// Where `agy` is, by looking at files only: before consent not even `--version` is run.
    public static func find(environment: [String: String] = ProcessInfo.processInfo.environment,
                            homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> URL? {
        #if os(Windows)
        let name = "agy.exe", separator: Character = ";"
        #else
        let name = "agy", separator: Character = ":"
        #endif
        let fromPath = (environment["PATH"] ?? "").split(separator: separator, omittingEmptySubsequences: true).map(String.init)
        // A Bridge started by the system has a short PATH: the places a CLI is usually put.
        let usual = ["\(homeDirectory)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let candidates = [environment["NORTHPANE_AGY_EXECUTABLE"]].compactMap { $0 } + (fromPath + usual).map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public func read(now: Date) throws -> [AgentUsageMeter] {
        guard let conversation = try? AgentCLIConversation(executable: executable, arguments: ["-p", "/usage", "--output-format", "json"], timeout: timeout) else { throw AgentUsageFailure.unreachable }
        defer { conversation.finish() }
        let output = conversation.readToEnd()
        // Nothing printed is a process that died or was stopped at the deadline.
        guard !output.isEmpty else { throw AgentUsageFailure.unreachable }
        return try AntigravityQuota.meters(in: output)
    }
}

#endif

/// Reads the JSON `agy` answers `/usage` with: groups of models, each with the quantities it
/// calls buckets. A group is a scope and what `agy` calls a bucket is a meter of it — the
/// window stays out of the scope's identity, so a second window on the same group would be a
/// second meter and not a second scope.
public enum AntigravityQuota {
    public static func meters(in output: Data) throws -> [AgentUsageMeter] {
        guard let root = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any], let status = root["status"] as? String else { throw AgentUsageFailure.unreadable }
        // The error text mixes authentication, timeouts and the network, so an error names
        // nothing: it may pass, and it is tried again.
        guard status != "ERROR" else { throw AgentUsageFailure.unreachable }
        guard status == "SUCCESS", let command = root["command"] as? [String: Any], command["name"] as? String == "usage",
              let groups = (command["data"] as? [String: Any])?["groups"] as? [[String: Any]] else { throw AgentUsageFailure.unreadable }

        var meters: [AgentUsageMeter] = []
        var scopes = Set<String>()
        for group in groups {
            guard let label = text(group["name"]), let quantities = group["buckets"] as? [[String: Any]], !quantities.isEmpty else { throw AgentUsageFailure.unreadable }
            var scopeID: String?
            for quantity in quantities {
                // A window other than the weekly one is something this reader has not seen.
                guard let id = text(quantity["id"]), text(quantity["name"]) != nil, text(quantity["window"]) == "weekly",
                      let remaining = (quantity["remaining_fraction"] as? NSNumber)?.doubleValue, remaining.isFinite, (0...1).contains(remaining),
                      let reset = text(quantity["reset_time"]).flatMap(instant) else { throw AgentUsageFailure.unreadable }
                let scope = id.hasSuffix("-weekly") && id.count > "-weekly".count ? String(id.dropLast("-weekly".count)) : id
                guard scopeID == nil, scopes.insert(scope).inserted else { throw AgentUsageFailure.unreadable }
                scopeID = scope
                // With nothing spent the server answers "now plus seven days": a reset that
                // slides, not an instant anyone observed.
                meters.append(.init(scopeID: scope, scopeLabel: label, kind: .longWindow, usedPercent: Int(((1 - remaining) * 100).rounded()),
                                    resetsAt: remaining == 1 ? nil : reset, windowMinutes: 7 * 24 * 60))
            }
        }
        return meters
    }

    private static func text(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }

    private static func instant(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        return plain.date(from: text) ?? fractional.date(from: text)
    }
}
