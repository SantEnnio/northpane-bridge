#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import NorthpaneProtocol
import NorthpaneSecurity
import Testing
@testable import NorthpaneConnection

/// A stopped Herdr fails at the event socket before the Bridge ever reaches the snapshot. The
/// authenticated Bridge session must stay usable so the recovery button can start Herdr over that
/// same SSH-carried protocol instead of opening an unrestricted remote shell.
@Test func anAuthenticatedBridgeCanStartHerdrAfterEarlyDiscoveryFailure() async throws {
    let (client, signer) = try await makeRealBridgeClient(
        fixtureEnvironment: ["NORTHPANE_HERDR_EVENT_SOCKET_OPTIONAL=0"]
    )
    defer { Task { await client.close() } }
    _ = try await client.handshake()
    _ = try await client.pair(using: signer)

    do {
        _ = try await client.observe()
        Issue.record("Expected discovery to fail while the Herdr event socket is absent")
    } catch let problem as Problem {
        #expect(problem.code == "herdr_event_subscription_failed")
    }

    #expect(try await client.startHerdr(sessionName: "test-session").outcome == .applied)
}

@Test func realBridgeProcessNegotiatesSnapshotsAndStreamsTerminalBytes() async throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let bridge = ProcessInfo.processInfo.environment["NORTHPANE_TEST_BRIDGE_EXECUTABLE"]
        .map(URL.init(fileURLWithPath:))
        ?? repository.appending(path: ".build/debug/northpane-bridge")
    let herdr = repository.appending(path: "Tests/Fixtures/fake-herdr.sh")
    let state = FileManager.default.temporaryDirectory.appending(path: "northpane-e2e-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: state) }

    let transport = try ProcessBridgeTransport(
        kind: .localIPC,
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [
            "NORTHPANE_HERDR_EXECUTABLE=\(herdr.path)",
            "NORTHPANE_CODEX_EXECUTABLE=/usr/bin/true",
            "NORTHPANE_HERDR_EVENT_SOCKET_OPTIONAL=1",
            "HERDR_SOCKET_PATH=\(state.appending(path: "missing-herdr.sock").path)",
            "NORTHPANE_STATE_DIRECTORY=\(state.path)",
            bridge.path,
            "serve",
            "--stdio",
        ]
    )
    let signer = try ClientDeviceSigner()
    let client = NorthpaneBridgeClient(transport: transport, deviceID: signer.deviceID)
    defer { Task { await client.close() } }
    let accepted = try await client.handshake()
    #expect(accepted.herdrVersion == "0.8.2")
    _ = try await client.pair(using: signer)
    #expect(try await client.startHerdr(sessionName: "test-session").outcome == .applied)
    let snapshot = try await client.observe()
    #expect(snapshot.workspaces.map(\.id) == ["workspace-1"])
    #expect(snapshot.panes.first?.agentStatus == "blocked")

    let workspaceDirectory = state.appending(path: "preview-demo").path
    let created = try await client.createWorkspace(label: "Preview demo", workingDirectory: workspaceDirectory)
    #expect(created.workspaceID == "workspace-created")
    #expect(created.paneID == "workspace-created:p1")
    #expect(FileManager.default.fileExists(atPath: workspaceDirectory))

    let closed = try await client.closeWorkspace(workspaceID: "workspace-1")
    #expect(closed.outcome == .applied)
    #expect(closed.workspaceID == "workspace-1")

    let agentDirectory = state.appending(path: "agent-demo").path
    let launched = try await client.createWorkspace(label: "Agent demo", workingDirectory: agentDirectory, agentKind: .codex)
    #expect(launched.workspaceID == "workspace-created")
    #expect(launched.workspaceAgentKind == .codex)
    #expect(launched.workspaceAgentStarted)
    #expect(launched.problem == nil)

    let channel = ChannelID()
    let attached = try await client.attach(.init(paneID: "pane-1", mode: .observe, columns: 80, rows: 24, incarnationID: snapshot.incarnationID, snapshotID: snapshot.snapshotID, nextEventSequence: snapshot.nextEventSequence), channelID: channel)
    let output = try await client.receive()
    guard case let .terminalOutput(frame) = output.payload else {
        Issue.record("Expected terminal output after attach")
        return
    }
    #expect(frame.attachmentID == attached.attachmentID)
    #expect(String(decoding: frame.bytes, as: UTF8.self).contains("Test frame"))

    let controlChannel = ChannelID()
    let controlled = try await client.attach(.init(paneID: "pane-1", mode: .takeover, columns: 80, rows: 24, incarnationID: snapshot.incarnationID, snapshotID: snapshot.snapshotID, nextEventSequence: snapshot.nextEventSequence), channelID: controlChannel)
    _ = try await client.receive() // initial full terminal frame
    try await client.sendInput(.init(attachmentID: controlled.attachmentID, sequence: 0, bytes: Data("whoami\r".utf8)), channelID: controlChannel)
    var acknowledged = false
    var echoed = false
    for _ in 0..<2 {
        let envelope = try await client.receive()
        if case let .terminalAcknowledgement(ack) = envelope.payload { acknowledged = ack.acceptedThroughSequence == 0 }
        if case let .terminalOutput(output) = envelope.payload { echoed = String(decoding: output.bytes, as: UTF8.self).contains("ack") }
    }
    #expect(acknowledged)
    #expect(echoed)
    try await client.release(.init(attachmentID: controlled.attachmentID), channelID: controlChannel)

    // Releasing ends the Herdr stream on the bridge. That must not surface as an unsolicited terminal
    // problem: the client treats such problems as a lost connection and would restart the bridge.
    try await Task.sleep(for: .milliseconds(300))
    try await client.heartbeat()
    let reobserveChannel = ChannelID()
    let reobserved = try await client.attach(.init(paneID: "pane-1", mode: .observe, columns: 80, rows: 24, incarnationID: snapshot.incarnationID, snapshotID: snapshot.snapshotID, nextEventSequence: snapshot.nextEventSequence), channelID: reobserveChannel)
    var afterRelease = try await client.receive()
    for _ in 0..<5 {
        guard case .heartbeat = afterRelease.payload else { break }
        afterRelease = try await client.receive() // periodic bridge heartbeats are not the subject here
    }
    guard case let .terminalOutput(reobservedFrame) = afterRelease.payload else {
        Issue.record("Expected terminal output after re-attaching, received \(afterRelease.payload)")
        return
    }
    #expect(reobservedFrame.attachmentID == reobserved.attachmentID)
    try await client.release(.init(attachmentID: reobserved.attachmentID), channelID: reobserveChannel)
}

/// A Bridge that fixes how something behaves carries the same version and the same schema as the
/// one it replaces, so a client comparing those sees no reason to offer the fix it is holding. The
/// handshake therefore says which binary is answering: the SHA-256 of the Bridge's own executable.
@Test func theHandshakeNamesTheBridgeBinaryAndNotOnlyItsRelease() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bridge = repository.appending(path: ".build/debug/northpane-bridge")
    let (client, signer) = try await makeRealBridgeClient()
    defer { Task { await client.close() } }
    let accepted = try await client.handshake()
    _ = try await client.pair(using: signer)

    #expect(accepted.schemaRevision >= 9)
    var hasher = SHA256()
    let handle = try FileHandle(forReadingFrom: bridge)
    defer { try? handle.close() }
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    #expect(accepted.bridgeBuildID == hasher.finalize().map { String(format: "%02x", $0) }.joined())
    // The version alone cannot tell two builds apart, which is the whole reason for the field.
    #expect(accepted.bridgeVersion == NorthpaneRelease.version)
}

private func makeRealBridgeClient(fixtureEnvironment: [String] = []) async throws -> (NorthpaneBridgeClient, ClientDeviceSigner) {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bridge = repository.appending(path: ".build/debug/northpane-bridge")
    let herdr = repository.appending(path: "Tests/Fixtures/fake-herdr.sh")
    let state = FileManager.default.temporaryDirectory.appending(path: "northpane-e2e-\(UUID().uuidString)")
    let transport = try ProcessBridgeTransport(
        kind: .localIPC,
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [
            "NORTHPANE_HERDR_EXECUTABLE=\(herdr.path)",
            "NORTHPANE_HERDR_EVENT_SOCKET_OPTIONAL=1",
            "HERDR_SOCKET_PATH=\(state.appending(path: "missing-herdr.sock").path)",
            "NORTHPANE_STATE_DIRECTORY=\(state.path)",
        ] + fixtureEnvironment + [
            bridge.path, "serve", "--stdio",
        ]
    )
    let signer = try ClientDeviceSigner()
    return (NorthpaneBridgeClient(transport: transport, deviceID: signer.deviceID), signer)
}

/// An agent that draws on the alternate screen owns the whole screen: Herdr holds nothing above it
/// to page, and the `terminal.scroll` it would be sent is dropped without a word — which is what an
/// operator saw as an OpenCode pane that would not scroll. The one scrolling such a pane does
/// understand is the mouse wheel it asked for, so that is what the scroll becomes, and the Host
/// stays the one saying which is which.
@Test func scrollingAnAlternateScreenAgentReachesThePaneAsAWheelInstead() async throws {
    let (client, signer) = try await makeRealBridgeClient(fixtureEnvironment: ["NORTHPANE_FIXTURE_ALT_SCREEN_PANE=1"])
    defer { Task { await client.close() } }
    _ = try await client.handshake()
    _ = try await client.pair(using: signer)
    let snapshot = try await client.observe()
    #expect(snapshot.panes.map(\.id) == ["pane-1", "pane-alt"])

    // The fixture answers a scroll with "scrolled" and an input with "ack", so the frame that comes
    // back says which of the two the Bridge chose.
    let paged = ChannelID()
    let shell = try await client.attach(.init(paneID: "pane-1", mode: .takeover, columns: 80, rows: 24, incarnationID: snapshot.incarnationID, snapshotID: snapshot.snapshotID, nextEventSequence: snapshot.nextEventSequence), channelID: paged)
    _ = try await client.receive() // initial frame
    try await client.scroll(.init(attachmentID: shell.attachmentID, direction: .up, lines: 5), channelID: paged)
    #expect(try await scrollOutcome(from: client) == "scrolled")
    try await client.release(.init(attachmentID: shell.attachmentID), channelID: paged)

    let wheeled = ChannelID()
    let agent = try await client.attach(.init(paneID: "pane-alt", mode: .takeover, columns: 80, rows: 24, incarnationID: snapshot.incarnationID, snapshotID: snapshot.snapshotID, nextEventSequence: snapshot.nextEventSequence), channelID: wheeled)
    _ = try await client.receive() // initial frame
    try await client.scroll(.init(attachmentID: agent.attachmentID, direction: .up, lines: 5), channelID: wheeled)
    #expect(try await scrollOutcome(from: client) == "ack")
    try await client.release(.init(attachmentID: agent.attachmentID), channelID: wheeled)
}

/// Which of the two the fixture answered with — "scrolled" for `terminal.scroll`, "ack" for
/// `terminal.input` — past the repaint that opens every attachment and the bridge's heartbeats.
private func scrollOutcome(from client: NorthpaneBridgeClient) async throws -> String? {
    for _ in 0..<8 {
        let envelope = try await client.receive()
        guard case let .terminalOutput(output) = envelope.payload else { continue }
        let text = String(decoding: output.bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "scrolled" || text == "ack" { return text }
    }
    return nil
}

/// A busy pane advances the bridge's event sequence between the client reading a snapshot and
/// the bridge receiving the attach. The terminal attach must still succeed: it only needs the
/// same Herdr incarnation and a pane that exists, not an exact event-sequence match.
@Test func terminalAttachSucceedsEvenWhenTheEventSequenceHasMovedOn() async throws {
    let (client, signer) = try await makeRealBridgeClient()
    defer { Task { await client.close() } }
    _ = try await client.handshake()
    _ = try await client.pair(using: signer)
    let snapshot = try await client.observe()

    let channel = ChannelID()
    let attached = try await client.attach(.init(paneID: "pane-1", mode: .observe, columns: 80, rows: 24, incarnationID: snapshot.incarnationID, snapshotID: "stale-\(UUID().uuidString)", nextEventSequence: snapshot.nextEventSequence + 4096), channelID: channel)
    let output = try await client.receive()
    guard case let .terminalOutput(frame) = output.payload else {
        Issue.record("Expected a terminal frame despite the advanced event sequence, got \(output.payload)")
        return
    }
    #expect(frame.attachmentID == attached.attachmentID)
    #expect(String(decoding: frame.bytes, as: UTF8.self).contains("Test frame"))
    try await client.release(.init(attachmentID: attached.attachmentID), channelID: channel)
}

/// Herdr streams a rendered viewport, so scrollback is paged on the Host: a scroll on a controlled
/// attachment reaches the Herdr stream (the fixture answers with a frame), while an observe
/// attachment is refused because Herdr ignores scrolling there.
@Test func controlledTerminalScrollIsPagedOnTheHost() async throws {
    let (client, signer) = try await makeRealBridgeClient()
    defer { Task { await client.close() } }
    let accepted = try await client.handshake()
    #expect(accepted.schemaRevision >= 4)
    _ = try await client.pair(using: signer)
    let snapshot = try await client.observe()

    let observeChannel = ChannelID()
    let observed = try await client.attach(.init(paneID: "pane-1", mode: .observe, columns: 80, rows: 24, incarnationID: snapshot.incarnationID, snapshotID: snapshot.snapshotID, nextEventSequence: snapshot.nextEventSequence), channelID: observeChannel)
    _ = try await client.receive() // initial frame
    try await client.scroll(.init(attachmentID: observed.attachmentID, direction: .up, lines: 5), channelID: observeChannel)
    let refused = try await client.receive()
    guard case let .problem(problem) = refused.payload else {
        Issue.record("Expected scrolling an observe attachment to be refused, got \(refused.payload)")
        return
    }
    #expect(problem.code == "terminal_control_required")
    try await client.release(.init(attachmentID: observed.attachmentID), channelID: observeChannel)

    let controlChannel = ChannelID()
    let controlled = try await client.attach(.init(paneID: "pane-1", mode: .takeover, columns: 80, rows: 24, incarnationID: snapshot.incarnationID, snapshotID: snapshot.snapshotID, nextEventSequence: snapshot.nextEventSequence), channelID: controlChannel)
    _ = try await client.receive() // initial frame
    try await client.scroll(.init(attachmentID: controlled.attachmentID, direction: .up, lines: 5), channelID: controlChannel)
    var scrolled = false
    for _ in 0..<3 where !scrolled {
        let envelope = try await client.receive()
        if case let .terminalOutput(output) = envelope.payload { scrolled = String(decoding: output.bytes, as: UTF8.self).contains("scrolled") }
    }
    #expect(scrolled)
    try await client.release(.init(attachmentID: controlled.attachmentID), channelID: controlChannel)
}

@Test func embeddedBridgeObservesRealHerdr082() async throws {
    guard ProcessInfo.processInfo.environment["NORTHPANE_TEST_REAL_HERDR"] == "1" else { return }
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let configuredBridge = ProcessInfo.processInfo.environment["NORTHPANE_TEST_BRIDGE_EXECUTABLE"]
    let bridge = configuredBridge.map(URL.init(fileURLWithPath:))
        ?? repository.appending(path: ".build/debug/northpane-bridge")
    let state = FileManager.default.temporaryDirectory.appending(path: "northpane-real-herdr-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: state) }

    let transport = try ProcessBridgeTransport(
        kind: .localIPC,
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [
            "NORTHPANE_STATE_DIRECTORY=\(state.path)",
            bridge.path,
            "serve",
            "--stdio",
        ]
    )
    let signer = try ClientDeviceSigner()
    let client = NorthpaneBridgeClient(transport: transport, deviceID: signer.deviceID)
    defer { Task { await client.close() } }
    _ = try await client.handshake()
    _ = try await client.pair(using: signer)
    let snapshot = try await client.observe()
    #expect(!snapshot.workspaces.isEmpty)
    #expect(!snapshot.panes.isEmpty)
}

#if os(macOS)
import Security

/// A remote Client cannot register an arbitrary Host-local service: the Pane must exist in the
/// current snapshot and belong to the named Workspace before any readiness probe is attempted.
@Test func authenticatedRemotePreviewRejectsAnUnrelatedPane() async throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-remote-preview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let transport = try ProcessBridgeTransport(
        kind: .ssh,
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [
            "NORTHPANE_HERDR_EXECUTABLE=\(repository.appending(path: "Tests/Fixtures/fake-herdr.sh").path)",
            "NORTHPANE_HERDR_EVENT_SOCKET_OPTIONAL=1",
            "HERDR_SOCKET_PATH=\(directory.appending(path: "missing-herdr.sock").path)",
            "NORTHPANE_STATE_DIRECTORY=\(directory.appending(path: "state").path)",
            repository.appending(path: ".build/debug/northpane-bridge").path,
            "serve", "--stdio",
        ]
    )
    let signer = try ClientDeviceSigner()
    let client = NorthpaneBridgeClient(transport: transport, deviceID: signer.deviceID)
    defer { Task { await client.close() } }
    _ = try await client.handshake()
    _ = try await client.pair(using: signer)
    _ = try await client.observe()

    do {
        _ = try await client.performResourceCommand(.init(
            kind: .registerPreview,
            workspaceID: "workspace-1",
            origin: "http://127.0.0.1:5173/",
            title: "Pane Preview",
            idempotencyKey: "remote-preview-fixture",
            paneID: "somebody-elses-pane"
        ))
        Issue.record("Expected an unrelated Pane to be rejected")
    } catch let problem as Problem {
        #expect(problem.code == "local_publication_required")
    }
}

@Test func localUnixSocketBridgeObservesRealHerdr082AfterPairing() async throws {
    guard ProcessInfo.processInfo.environment["NORTHPANE_TEST_REAL_HERDR"] == "1" else { return }
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let configuredBridge = ProcessInfo.processInfo.environment["NORTHPANE_TEST_BRIDGE_EXECUTABLE"]
    let bridge = configuredBridge.map(URL.init(fileURLWithPath:))
        ?? repository.appending(path: ".build/debug/northpane-bridge")
    let state = FileManager.default.temporaryDirectory.appending(path: "northpane-real-ipc-\(UUID().uuidString)")
    let socket = FileManager.default.temporaryDirectory.appending(path: "np-real-\(UUID().uuidString.prefix(8)).sock")
    let process = Process()
    process.executableURL = bridge
    process.arguments = ["serve", "--socket", socket.path]
    process.environment = ProcessInfo.processInfo.environment.merging(["NORTHPANE_STATE_DIRECTORY": state.path]) { _, new in new }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: socket)
        try? FileManager.default.removeItem(at: state)
    }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket.path) {
        try await Task.sleep(for: .milliseconds(20))
    }

    let signer = try ClientDeviceSigner()
    let client = NorthpaneBridgeClient(
        transport: try UnixSocketBridgeTransport(path: socket.path),
        deviceID: signer.deviceID
    )
    defer { Task { await client.close() } }
    _ = try await client.handshake()
    _ = try await client.pair(using: signer)
    let snapshot = try await client.observe()
    #expect(!snapshot.workspaces.isEmpty)
    #expect(!snapshot.panes.isEmpty)
}

private final class TestCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@Test func localUnixSocketCarriesTheSameHandshakeAndSnapshot() async throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let bridge = repository.appending(path: ".build/debug/northpane-bridge")
    let herdr = repository.appending(path: "Tests/Fixtures/fake-herdr.sh")
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-ipc-\(UUID().uuidString)")
    let worktree = directory.appending(path: "worktree", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try Data("<h1>Bridge resource</h1>".utf8).write(to: worktree.appending(path: "index.html"))
    let socket = URL(fileURLWithPath: "/tmp/np-\(UUID().uuidString.prefix(8)).sock")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["NORTHPANE_HERDR_EXECUTABLE=\(herdr.path)", "NORTHPANE_HERDR_EVENT_SOCKET_OPTIONAL=1", "HERDR_SOCKET_PATH=\(directory.appending(path: "missing-herdr.sock").path)", "NORTHPANE_FIXTURE_WORKTREE=\(worktree.path)", "NORTHPANE_STATE_DIRECTORY=\(directory.path)", bridge.path, "serve", "--socket", socket.path]
    process.standardOutput = Pipe(); process.standardError = Pipe()
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: socket)
        try? FileManager.default.removeItem(at: directory)
    }
    for _ in 0..<50 where !FileManager.default.fileExists(atPath: socket.path) {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(FileManager.default.fileExists(atPath: socket.path))
    let signer = try ClientDeviceSigner()
    let client = NorthpaneBridgeClient(transport: try UnixSocketBridgeTransport(path: socket.path), deviceID: signer.deviceID)
    _ = try await client.handshake()
    _ = try await client.pair(using: signer)
    let snapshot = try await client.observe()
    #expect(snapshot.panes.map(\.id) == ["pane-1"])
    let publication = try await client.performResourceCommand(.init(kind: .publishArtifact, workspaceID: "workspace-1", path: "index.html", ttlSeconds: 3_600, mediaType: "text/html", idempotencyKey: "fixture-build"))
    let descriptor = try #require(publication.resources.first)
    let resources = try await client.performResourceCommand(.init(kind: .listResources))
    #expect(resources.resources.contains(descriptor))
    let downloaded = try await client.downloadArtifact(descriptor)
    #expect(downloaded.files["index.html"] == Data("<h1>Bridge resource</h1>".utf8))

    // Schema revision 6: a file the terminal cited is read relative to the pane's working
    // directory (the fixture reports `<worktree>/docs`), confined to the worktree.
    try FileManager.default.createDirectory(at: worktree.appending(path: "docs"), withIntermediateDirectories: true)
    try Data("# Cited\n".utf8).write(to: worktree.appending(path: "docs/cited.md"))
    #expect(snapshot.panes.first?.cwd == worktree.appending(path: "docs").path)
    let cited = try await client.readWorkspaceFile(path: "cited.md", paneID: "pane-1", workspaceID: "workspace-1")
    #expect(cited.relativePath == "docs/cited.md")
    #expect(cited.mediaType == "text/markdown")
    #expect(cited.data == Data("# Cited\n".utf8))
    await #expect(throws: Problem.self) { try await client.readWorkspaceFile(path: "../../etc/passwd", paneID: "pane-1", workspaceID: "workspace-1") }

    // Schema revision 7: the same roots can be searched by name, and the answer carries names
    // and metadata only. The file just written is inside the worktree, so it is findable.
    try FileManager.default.createDirectory(at: worktree.appending(path: "docs/cited-folder"), withIntermediateDirectories: true)
    let found = try await client.searchWorkspacePaths(query: "cited", paneID: "pane-1", workspaceID: "workspace-1")
    #expect(found.hits.contains { $0.relativePath == "docs/cited.md" && !$0.isDirectory })
    #expect(found.hits.contains { $0.relativePath == "docs/cited-folder" && $0.isDirectory })
    #expect(found.hits.allSatisfy { $0.rootLabel == "workspace" && $0.path.hasPrefix("/") })
    // A folder outranks a file that scores the same, so the search leads with what was asked for.
    #expect(found.hits.first?.relativePath == "docs/cited-folder")
    // A query too short to narrow anything is answered locally, and refused by the Host for
    // any client that sends it anyway.
    let tooShort = try await client.searchWorkspacePaths(query: "c", paneID: "pane-1", workspaceID: "workspace-1")
    #expect(tooShort.hits.isEmpty)
    await #expect(throws: Problem.self) {
        try await client.performResourceCommand(.init(kind: .searchWorkspacePaths, workspaceID: "workspace-1", paneID: "pane-1", query: "c"))
    }

    // Schema revision 8: the Host lists what its screen shows and captures one target. A test
    // runner is rarely allowed to record the screen, so a refusal on that ground is as good an
    // answer as a capture; the listing is always answered and a bogus target always refused.
    let targets = try await client.listScreenCaptureTargets(paneID: "pane-1", workspaceID: "workspace-1")
    #expect(targets.allSatisfy { $0.id.hasPrefix("display:") || $0.id.hasPrefix("window:") })
    #expect(targets.prefix(targets.filter { $0.kind == .display }.count).allSatisfy { $0.kind == .display })
    await #expect(throws: Problem.self) {
        try await client.captureScreen(targetID: "bogus", paneID: "pane-1", workspaceID: "workspace-1")
    }
    if let display = targets.first(where: { $0.kind == .display }) {
        do {
            let shot = try await client.captureScreen(targetID: display.id, paneID: "pane-1", workspaceID: "workspace-1")
            #expect(shot.path.hasPrefix("/") && shot.path.hasSuffix(".png"))
            #expect(shot.previewMediaType == "image/jpeg" && !shot.preview.isEmpty && shot.preview.count <= 700 * 1_024)
            // The PNG sits in one of the roots the confined read serves from, so the same client
            // can read the full image back the way it reads any cited file.
            let readBack = try await client.readWorkspaceFile(path: shot.path, paneID: "pane-1", workspaceID: "workspace-1")
            #expect(readBack.mediaType == "image/png" && readBack.data.count == shot.byteCount)
        } catch let problem as Problem {
            #expect(problem.code == "screen_capture_not_permitted")
        }
    }
    // Schema revision 12: a file pasted on the Client is staged on the Host in ordered chunks
    // (700 KiB is two of them), recognised by its bytes, and read back through the same confined
    // read; bytes that are no image or PDF are refused whatever they are called.
    let pastedPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0xAB, count: 700 * 1_024)
    let staged = try await client.stagePastedFile(pastedPNG, paneID: "pane-1", workspaceID: "workspace-1")
    #expect(staged.mediaType == "image/png" && staged.byteCount == pastedPNG.count && staged.path.hasSuffix(".png"))
    let pastedBack = try await client.readWorkspaceFile(path: staged.path, paneID: "pane-1", workspaceID: "workspace-1")
    #expect(pastedBack.data == pastedPNG && pastedBack.mediaType == "image/png")
    await #expect(throws: Problem.self) { try await client.stagePastedFile(Data("plain text".utf8), paneID: "pane-1", workspaceID: "workspace-1") }
    await client.close()

    let returningClient = NorthpaneBridgeClient(transport: try UnixSocketBridgeTransport(path: socket.path), deviceID: signer.deviceID)
    _ = try await returningClient.handshake()
    let returningSnapshot = try await returningClient.observe()
    #expect(returningSnapshot.snapshotID != snapshot.snapshotID)
    let receipt = try await returningClient.revokeThisDevice()
    #expect(receipt.outcome == .applied)
    await #expect(throws: Problem.self) { try await returningClient.observe() }
    await returningClient.close()

    let revokedClient = NorthpaneBridgeClient(transport: try UnixSocketBridgeTransport(path: socket.path), deviceID: signer.deviceID)
    _ = try await revokedClient.handshake()
    await #expect(throws: Problem.self) { try await revokedClient.observe() }
    await revokedClient.close()
}

@Test func privateWSSCarriesTheRealBridgeContract() async throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-wss-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let certificate = directory.appending(path: "certificate.pem")
    let key = directory.appending(path: "key.pem")
    let openssl = Process()
    openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=127.0.0.1", "-keyout", key.path, "-out", certificate.path, "-days", "1"]
    openssl.standardOutput = FileHandle.nullDevice
    openssl.standardError = FileHandle.nullDevice
    try openssl.run(); openssl.waitUntilExit()
    #expect(openssl.terminationStatus == 0)

    let port = Int.random(in: 40_000...55_000)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "NORTHPANE_HERDR_EXECUTABLE=\(repository.appending(path: "Tests/Fixtures/fake-herdr.sh").path)",
        "NORTHPANE_HERDR_EVENT_SOCKET_OPTIONAL=1",
        "HERDR_SOCKET_PATH=\(directory.appending(path: "missing-herdr.sock").path)",
        "NORTHPANE_STATE_DIRECTORY=\(directory.appending(path: "state").path)",
        repository.appending(path: ".build/debug/northpane-bridge").path,
        "serve", "--private", "127.0.0.1", String(port), "--certificate", certificate.path, "--key", key.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    try await Task.sleep(for: .milliseconds(250))
    #expect(process.isRunning)

    let session = URLSession(configuration: .ephemeral, delegate: TestCertificateDelegate(), delegateQueue: nil)
    let transport = try WebSocketBridgeTransport(url: URL(string: "wss://127.0.0.1:\(port)/bridge")!, session: session)
    let signer = try ClientDeviceSigner()
    let client = NorthpaneBridgeClient(transport: transport, deviceID: signer.deviceID)
    _ = try await client.handshake()
    _ = try await client.pair(using: signer)
    let snapshot = try await client.observe()
    #expect(snapshot.panes.map(\.id) == ["pane-1"])
    await client.close()
    session.invalidateAndCancel()
}

@Test func bridgeHandshakeRemainsAvailableWhenHerdrIsMissing() async throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let bridge = repository.appending(path: ".build/debug/northpane-bridge")
    let state = FileManager.default.temporaryDirectory.appending(path: "northpane-no-herdr-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: state) }
    let transport = try ProcessBridgeTransport(
        kind: .ssh,
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["PATH=/nonexistent", "NORTHPANE_STATE_DIRECTORY=\(state.path)", bridge.path, "serve", "--stdio"]
    )
    let signer = try ClientDeviceSigner()
    let client = NorthpaneBridgeClient(transport: transport, deviceID: signer.deviceID)
    let accepted = try await client.handshake()
    #expect(!accepted.hostSigningPublicKey.isEmpty)
    await client.close()
}
#endif
