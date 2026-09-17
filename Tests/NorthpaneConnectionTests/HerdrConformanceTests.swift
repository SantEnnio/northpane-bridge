import Foundation
import Testing
import NorthpaneProtocol
import NorthpaneSecurity
@testable import NorthpaneConnection

/// The conformance run against a real Herdr, not the fixture: it is what certifies
/// a Herdr release for the compatibility list. Opt-in, because it needs a Herdr binary and an
/// isolated home so the operator's own Herdr is never touched:
///
///     NORTHPANE_CONFORMANCE_HERDR=/path/to/herdr NORTHPANE_CONFORMANCE_HOME=/tmp/herdr-home \
///       swift test --filter liveHerdr
///
/// The run starts a headless server under a private session name, then walks the whole path a
/// Client walks: handshake and version, pairing, snapshot after an event subscription, a
/// Workspace created and seen in the next snapshot, a terminal observed, controlled, typed into
/// and read back, scrolled, released and re-observed, and the Workspace closed.
@Test func liveHerdrConformance() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let herdrPath = environment["NORTHPANE_CONFORMANCE_HERDR"], let homePath = environment["NORTHPANE_CONFORMANCE_HOME"] else {
        return // not asked for
    }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bridge = environment["NORTHPANE_TEST_BRIDGE_EXECUTABLE"].map(URL.init(fileURLWithPath:)) ?? repository.appending(path: ".build/debug/northpane-bridge")
    let state = URL(fileURLWithPath: homePath).appending(path: "northpane-state-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: state) }
    let session = environment["NORTHPANE_CONFORMANCE_SESSION"] ?? "npcert"

    let transport = try ProcessBridgeTransport(
        kind: .localIPC,
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [
            // The Bridge resolves the event socket from the account's home directory, which HOME
            // does not move on macOS; the explicit path keeps every process on the isolated session.
            "HOME=\(homePath)",
            "HERDR_SOCKET_PATH=\(homePath)/.config/herdr/sessions/\(session)/herdr.sock",
            "NORTHPANE_HERDR_EXECUTABLE=\(herdrPath)",
            "NORTHPANE_STATE_DIRECTORY=\(state.path)",
            bridge.path, "serve", "--stdio",
        ]
    )
    let signer = try ClientDeviceSigner()
    let client = NorthpaneBridgeClient(transport: transport, deviceID: signer.deviceID)
    defer { Task { await client.close() } }

    let accepted = try await client.handshake()
    let version = accepted.herdrVersion
    print("[conformance] Herdr \(version), schema \(accepted.schemaRevision), Bridge \(accepted.bridgeVersion)")
    #expect(version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil)
    _ = try await client.pair(using: signer)

    // The server may already be running under this session name; starting is idempotent then.
    _ = try? await client.startHerdr(sessionName: session)
    try await Task.sleep(for: .seconds(1))
    let initial = try await client.observe(sessionName: session)
    print("[conformance] initial snapshot: \(initial.workspaces.count) workspaces, \(initial.panes.count) panes, incarnation \(initial.incarnationID)")

    // A Workspace with a shell, created through Herdr and seen again in the next snapshot.
    // On a remote Host (a Windows one included) the directory is written in the Host's own form, which
    // this machine's URL rules would mangle; NORTHPANE_CONFORMANCE_WORKDIR gives it verbatim.
    let workspaceName = "conformance-\(UUID().uuidString.prefix(8))"
    let directory = environment["NORTHPANE_CONFORMANCE_WORKDIR"].map { $0 + "/" + workspaceName }
        ?? URL(fileURLWithPath: homePath).appending(path: workspaceName).path
    let created = try await client.createWorkspace(label: "Conformance", workingDirectory: directory)
    print("[conformance] created workspace \(created.workspaceID), root pane \(created.paneID)")
    #expect(!created.workspaceID.isEmpty && !created.paneID.isEmpty)
    // The event path, not a re-read: Herdr's lifecycle event reaches the Bridge, which re-reads
    // the snapshot and pushes it. This is the step Herdr 0.9.0 changed (no replay of retained
    // events), and it holds because the Bridge subscribes before its first snapshot.
    var pushed: WireRuntimeSnapshot?
    let eventDeadline = Date().addingTimeInterval(8)
    while Date() < eventDeadline, pushed == nil {
        let envelope = try await client.receive()
        if case let .runtimeSnapshot(snapshot) = envelope.payload, snapshot.workspaces.contains(where: { $0.id == created.workspaceID }) { pushed = snapshot }
    }
    print("[conformance] workspace creation pushed through the event stream: \(pushed != nil)")
    #expect(pushed != nil)
    let after = try await client.observe(sessionName: session)
    #expect(after.workspaces.contains { $0.id == created.workspaceID })
    let pane = try #require(after.panes.first { $0.id == created.paneID })
    #expect(pane.workspaceID == created.workspaceID)
    #expect(pane.cwd == directory || pane.cwd?.hasSuffix(workspaceName) == true)

    // Observe: a frame arrives. Control: what is typed comes back through the frame stream.
    let observeChannel = ChannelID()
    let observed = try await client.attach(.init(paneID: created.paneID, mode: .observe, columns: 100, rows: 30, incarnationID: after.incarnationID, snapshotID: after.snapshotID, nextEventSequence: after.nextEventSequence), channelID: observeChannel)
    let firstFrame = try await nextTerminalOutput(client, attachment: observed.attachmentID)
    #expect(firstFrame != nil)
    try await client.release(.init(attachmentID: observed.attachmentID), channelID: observeChannel)

    let controlChannel = ChannelID()
    let controlled = try await client.attach(.init(paneID: created.paneID, mode: .takeover, columns: 100, rows: 30, incarnationID: after.incarnationID, snapshotID: after.snapshotID, nextEventSequence: after.nextEventSequence), channelID: controlChannel)
    _ = try await nextTerminalOutput(client, attachment: controlled.attachmentID)
    let marker = "conformance-\(Int.random(in: 1000...9999))"
    try await client.sendInput(.init(attachmentID: controlled.attachmentID, sequence: 0, bytes: Data("echo \(marker)\r".utf8)), channelID: controlChannel)
    var seenMarker = false
    var acknowledged = false
    let deadline = Date().addingTimeInterval(10)
    var screen = ""
    while Date() < deadline, !(seenMarker && acknowledged) {
        let envelope = try await client.receive()
        switch envelope.payload {
        case let .terminalAcknowledgement(ack): acknowledged = ack.acceptedThroughSequence >= 0
        case let .terminalOutput(output):
            screen += String(decoding: output.bytes, as: UTF8.self)
            // The echoed command and its output both carry the marker; two occurrences prove the shell ran it.
            seenMarker = screen.components(separatedBy: marker).count >= 3
        default: break
        }
    }
    print("[conformance] acknowledged \(acknowledged), marker echoed by the shell \(seenMarker)")
    #expect(acknowledged)
    #expect(seenMarker)
    // Scroll is accepted (a shell pane keeps its scrollback on the Host); the reply is a frame or nothing.
    try await client.scroll(.init(attachmentID: controlled.attachmentID, direction: .up, lines: 5), channelID: controlChannel)
    try await client.release(.init(attachmentID: controlled.attachmentID), channelID: controlChannel)

    // Close what was created; the Workspace must be gone from the next snapshot.
    let closed = try await client.closeWorkspace(workspaceID: created.workspaceID)
    #expect(closed.outcome == .applied)
    try await Task.sleep(for: .seconds(1))
    let final = try await client.observe(sessionName: session)
    #expect(!final.workspaces.contains { $0.id == created.workspaceID })
    print("[conformance] Herdr \(version): PASS")
}

private func nextTerminalOutput(_ client: NorthpaneBridgeClient, attachment: UUID, within seconds: TimeInterval = 8) async throws -> TerminalOutputFrame? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        let envelope = try await client.receive()
        if case let .terminalOutput(output) = envelope.payload, output.attachmentID == attachment { return output }
    }
    return nil
}
