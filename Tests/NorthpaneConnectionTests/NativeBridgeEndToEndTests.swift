#if os(macOS) || os(Linux)
import Foundation
import Testing
import NorthpaneProtocol
import NorthpaneSecurity
@testable import NorthpaneConnection
@testable import NorthpaneNativeRuntime

@Test func nativeBridgeAuthenticatesCreatesAndKeepsTheTerminalAcrossBridgeExit() async throws {
    let root = URL(fileURLWithPath: "/tmp/np-bridge-" + UUID().uuidString.prefix(10))
    let home = root.appending(path: "home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = NativeProcessConfiguration(shell: "/bin/sh", arguments: ["-i"],
        environment: ["HOME": home.path, "ENV": "/dev/null", "PATH": "/usr/bin:/bin", "PS1": "probe$ "])
    let server = try NativeRuntimeServer(stateDirectory: root, version: "test", workspaceModelEnabled: true, processConfiguration: configuration)
    let done = AsyncStream<Void>.makeStream()
    Thread.detachNewThread { try? server.run(); done.continuation.yield(()); done.continuation.finish() }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let executable = ProcessInfo.processInfo.environment["NORTHPANE_TEST_BRIDGE_EXECUTABLE"].map(URL.init(fileURLWithPath:))
        ?? repository.appending(path: ".build/debug/northpane-bridge")
    // A healthy prestarted isolated owner prevents registration in launchd or
    // systemd. env -i also prevents inherited provider/session configuration.
    func client(_ signer: ClientDeviceSigner) throws -> NorthpaneBridgeClient {
        let transport = try ProcessBridgeTransport(kind: .localIPC, executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: [
            "-i", "HOME=" + home.path, "PATH=/usr/bin:/bin", "SHELL=/bin/sh", "ENV=/dev/null",
            "NORTHPANE_RUNTIME=native", "NORTHPANE_STATE_DIRECTORY=" + root.path,
            executable.path, "serve", "--stdio"
        ])
        return NorthpaneBridgeClient(transport: transport, deviceID: signer.deviceID)
    }
    let signer = try ClientDeviceSigner()
    let first = try client(signer)
    var second: NorthpaneBridgeClient?
    do {
        let accepted = try await first.handshake()
        #expect(accepted.usesNativeRuntime && accepted.runtimeVersion == "test" && accepted.herdrVersion.isEmpty)
        _ = try await first.pair(using: signer)
        let empty = try await first.observe()
        #expect(empty.panes.isEmpty && empty.incarnationID == server.status.incarnationID)
        let workspace = try await first.createWorkspace(label: "Project", workingDirectory: root.appending(path: "project").path)
        let paneID = try #require(workspace.paneID)
        #expect(workspace.outcome == .applied)
        let snapshot = try await first.observe()
        #expect(snapshot.panes.map(\.id) == [paneID])
        let channel = ChannelID()
        let attachment = try await first.attach(.init(paneID: paneID, mode: .control, columns: 80, rows: 24,
            incarnationID: snapshot.incarnationID, snapshotID: snapshot.snapshotID, nextEventSequence: snapshot.nextEventSequence), channelID: channel)
        try await first.sendInput(.init(attachmentID: attachment.attachmentID, sequence: 0,
            bytes: Data("printf '\\156\\141\\164\\151\\166\\145\\055\\145\\062\\145\\012'\r".utf8)), channelID: channel)
        var result = false, acknowledged = false
        for _ in 0..<20 {
            let envelope = try await first.receive()
            if case let .terminalOutput(output) = envelope.payload { result = result || String(decoding: output.bytes, as: UTF8.self).contains("native-e2e") }
            if case let .terminalAcknowledgement(ack) = envelope.payload { acknowledged = ack.acceptedThroughSequence == 0 }
            if result && acknowledged { break }
        }
        #expect(result && acknowledged)
        await first.close()
        let reopened = try client(signer); second = reopened
        _ = try await reopened.handshake(expectedHostFingerprint: authorityFingerprint(accepted), signer: signer)
        let restored = try await reopened.observe()
        #expect(restored.incarnationID == snapshot.incarnationID && restored.panes.map(\.id) == [paneID])
        let otherChannel = ChannelID()
        _ = try await reopened.attach(.init(paneID: paneID, mode: .takeover, columns: 80, rows: 24,
            incarnationID: restored.incarnationID, snapshotID: restored.snapshotID, nextEventSequence: restored.nextEventSequence), channelID: otherChannel)
        var redraw = false
        for _ in 0..<20 {
            let envelope = try await reopened.receive()
            if case let .terminalOutput(output) = envelope.payload, String(decoding: output.bytes, as: UTF8.self).contains("native-e2e") { redraw = true; break }
        }
        #expect(redraw)
        #expect(try await reopened.closeWorkspace(workspaceID: workspace.workspaceID).outcome == .applied)
        await reopened.close()
        server.stop(); for await _ in done.stream {}
    } catch {
        await first.close(); await second?.close()
        server.stop(); for await _ in done.stream {}
        throw error
    }
}

private func authorityFingerprint(_ accepted: HandshakeAccepted) -> String {
    HostIdentity(hostID: accepted.hostID, signingPublicKey: accepted.hostSigningPublicKey).fingerprint
}
#endif
