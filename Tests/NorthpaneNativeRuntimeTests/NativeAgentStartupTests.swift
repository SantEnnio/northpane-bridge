#if os(macOS) || os(Linux)
import Foundation
import Testing
import NorthpaneProtocol
@testable import NorthpaneNativeRuntime

/// Explicit opt-in: startup only, no prompts and no provider conversations.
/// Paths are supplied privately by the operator and never stored in fixtures.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NORTHPANE_NATIVE_STARTUP_AGENTS"] != nil))
func nativeAgentHookArgumentsAreAcceptedAtIsolatedStartup() async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["NORTHPANE_NATIVE_STARTUP_AGENTS"])
    let paths = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bridge = repository.appending(path: ".build/debug/northpane-bridge")
    for kind in [WorkspaceAgentKind.codex, .claude, .openCode] {
        guard let executable = paths[kind.rawValue] ?? paths[kind.rawValue.lowercased()] else { continue }
        let directory = URL(fileURLWithPath: "/tmp/np-agent-start-" + UUID().uuidString.prefix(8))
        let home = directory.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let configuration = NativeProcessConfiguration(shell: "/bin/sh", arguments: ["-i"],
            environment: ["HOME": home.path, "ENV": "/dev/null", "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "PS1": "probe$ "],
            hookExecutable: bridge)
        let server = try NativeRuntimeServer(stateDirectory: directory, version: "test", workspaceModelEnabled: true, processConfiguration: configuration)
        let done = AsyncStream<Void>.makeStream()
        Thread.detachNewThread { try? server.run(); done.continuation.yield(()); done.continuation.finish() }
        do {
            let connection = try await NativeRuntimeConnection.connect(stateDirectory: directory)
            defer { connection.close() }
            let host = HostID()
            let created = try await connection.createWorkspace(hostID: host, label: "Startup", workingDirectory: home.path)
            try await connection.startAgent(paneID: created.paneID, kind: kind, executable: URL(fileURLWithPath: executable))
            let attachment = try connection.openTerminal(paneID: created.paneID, mode: .observe, columns: 80, rows: 24)
            try await Task.sleep(for: .milliseconds(1800))
            let frame = try connection.pollTerminal(attachmentID: attachment.attachmentID, afterRevision: -1)
            let terminal = NativeTerminalEngine(columns: 80, rows: 24)
            terminal.feed(frame.bytes)
            let text = (0..<24).map { terminal.terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }.joined(separator: " ")
            let badConfiguration = text.range(of: "error parsing.*config|invalid.*hook|unrecognized.*option|unknown.*option|failed to load plugin", options: [.regularExpression, .caseInsensitive]) != nil
            #expect(!frame.ended, "Agent should remain alive at startup: \(kind.rawValue)")
            #expect(!badConfiguration, "Agent rejected the per-process launch configuration: \(kind.rawValue)")
            #expect(!frame.bytes.isEmpty)
            print("Verified isolated startup: \(kind.rawValue)")
            try await connection.closeWorkspace(hostID: host, workspaceID: created.workspaceID)
            server.stop(); for await _ in done.stream {}
        } catch {
            server.stop(); for await _ in done.stream {}
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        try FileManager.default.removeItem(at: directory)
    }
}
#endif
