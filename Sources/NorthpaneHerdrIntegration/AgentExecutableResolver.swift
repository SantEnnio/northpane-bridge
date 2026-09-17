import Foundation
import NorthpaneProtocol

#if canImport(Darwin)
import Darwin
#endif

public enum AgentExecutableResolutionError: Error, Equatable, Sendable {
    case unsupported(WorkspaceAgentKind)
    case unavailable(WorkspaceAgentKind)
}

public struct DetectedAgentExecutable: Equatable, Sendable {
    public let kind: WorkspaceAgentKind
    public let url: URL

    public init(kind: WorkspaceAgentKind, url: URL) {
        self.kind = kind
        self.url = url
    }
}

public protocol AgentExecutableChecking: Sendable {
    /// A file merely existing is not enough: package-manager shims and damaged binaries often do.
    /// The bounded version probe is intentionally the same cheap operation for every supported CLI.
    func isWorkingExecutable(_ url: URL, timeout: TimeInterval) -> Bool
}

public struct SystemAgentExecutableChecker: AgentExecutableChecking {
    public init() {}

    public func isWorkingExecutable(_ url: URL, timeout: TimeInterval) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }

        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.2)
            while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            #if canImport(Darwin)
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            #endif
            process.waitUntilExit()
            return false
        }
        return process.terminationStatus == 0
    }
}

/// Resolves only Northpane's bounded agent set. The optional override is useful for managed Hosts;
/// known app-bundled locations precede PATH so a healthy bundled Codex can replace a broken shim.
/// The returned absolute path is launched directly instead of being resolved again by a login shell.
public struct AgentExecutableResolver: Sendable {
    private let checker: any AgentExecutableChecking
    private let environment: [String: String]
    private let homeDirectory: String
    private let probeTimeout: TimeInterval

    public init(
        checker: any AgentExecutableChecking = SystemAgentExecutableChecker(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        probeTimeout: TimeInterval = 3
    ) {
        self.checker = checker
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.probeTimeout = probeTimeout
    }

    public func resolve(_ kind: WorkspaceAgentKind) throws -> DetectedAgentExecutable {
        guard kind != .shell else { throw AgentExecutableResolutionError.unsupported(kind) }
        for path in candidatePaths(for: kind) {
            let url = URL(fileURLWithPath: path)
            if checker.isWorkingExecutable(url, timeout: probeTimeout) {
                return DetectedAgentExecutable(kind: kind, url: url)
            }
        }
        throw AgentExecutableResolutionError.unavailable(kind)
    }

    public func candidatePaths(for kind: WorkspaceAgentKind) -> [String] {
        let command: String
        let overrideKey: String
        var preferred: [String]
        switch kind {
        case .shell:
            return []
        case .codex:
            command = "codex"
            overrideKey = "NORTHPANE_CODEX_EXECUTABLE"
            preferred = [
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "\(homeDirectory)/Applications/ChatGPT.app/Contents/Resources/codex",
            ]
        case .claude:
            command = "claude"
            overrideKey = "NORTHPANE_CLAUDE_EXECUTABLE"
            preferred = ["\(homeDirectory)/.local/bin/claude"]
        case .openCode:
            command = "opencode"
            overrideKey = "NORTHPANE_OPENCODE_EXECUTABLE"
            preferred = ["\(homeDirectory)/.local/bin/opencode"]
        }
        let fromPath = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)).appending(path: command).path }
        let ordered = [environment[overrideKey]].compactMap { $0 } + preferred + fromPath
        var seen = Set<String>()
        return ordered.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

}
