#if os(macOS) || os(Linux)
import Foundation
import Synchronization
import Testing
import NorthpaneProtocol
import NorthpaneHostRuntime
@testable import NorthpaneBridge
@testable import NorthpaneNativeRuntime

@Test func nativeChangesCanStartBeforeAnyClientHandshakeOrSnapshot() async throws {
    let directory = URL(fileURLWithPath: "/tmp/np-watch-" + UUID().uuidString.prefix(10))
    let home = directory.appending(path: "home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = NativeProcessConfiguration(shell: "/bin/sh", arguments: ["-i"],
        environment: ["HOME": home.path, "ENV": "/dev/null", "PATH": "/usr/bin:/bin", "PS1": "probe$ "])
    let server = try NativeRuntimeServer(stateDirectory: directory, version: "test", workspaceModelEnabled: true, processConfiguration: config)
    let done = AsyncStream<Void>.makeStream()
    Thread.detachNewThread { try? server.run(); done.continuation.yield(()); done.continuation.finish() }
    let host = HostID()
    let runtime = NativeHostRuntime(stateDirectory: directory, hostID: host,
        executableURL: URL(fileURLWithPath: "/never-start-a-service"))
    let context = try await BridgeHostContext(stateDirectory: directory, runtimeFactory: { _, _ in runtime })
    let received = Mutex(0)
    var subscription: (any RuntimeChanges)?
    do {
        let changes = try await context.makeChanges(sessionName: nil)
        subscription = changes
        try await changes.start(onEvent: { received.withLock { $0 += 1 } }, onClose: { _ in })
        // No handshake initialized this adapter. The existing healthy owner was
        // reused; the deliberately invalid service executable was never used.
        let connection = try await NativeRuntimeConnection.connect(stateDirectory: directory)
        defer { connection.close() }
        let created = try await connection.createWorkspace(hostID: host, label: "Project", workingDirectory: directory.path)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while received.withLock({ $0 }) == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(received.withLock { $0 } > 0)
        try await connection.closeWorkspace(hostID: host, workspaceID: created.workspaceID)
        changes.stop(); server.stop(); for await _ in done.stream {}
    } catch {
        subscription?.stop(); server.stop(); for await _ in done.stream {}
        throw error
    }
}
#endif
