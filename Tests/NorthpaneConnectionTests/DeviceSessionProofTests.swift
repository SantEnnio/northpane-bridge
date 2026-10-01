import Foundation
import NorthpaneProtocol
import NorthpaneSecurity
import Testing
@testable import NorthpaneConnection

// Real Bridge processes sharing one Host state directory, the way the SSH connections of a Host
// share it: each connection is a `serve --stdio` process of its own. They drive the fake Herdr of
// Tests/Fixtures, a shell script, so POSIX Hosts only.
#if !os(Windows)
private struct BridgeHostFixture: Sendable {
    let state = FileManager.default.temporaryDirectory.appending(path: "northpane-proof-\(UUID().uuidString)")

    func connect(as signer: ClientDeviceSigner) throws -> NorthpaneBridgeClient { try connect(deviceID: signer.deviceID) }

    func connect(deviceID: ClientDeviceID) throws -> NorthpaneBridgeClient {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = ProcessInfo.processInfo.environment["NORTHPANE_TEST_BRIDGE_EXECUTABLE"].map(URL.init(fileURLWithPath:))
            ?? repository.appending(path: ".build/debug/northpane-bridge")
        let herdr = repository.appending(path: "Tests/Fixtures/fake-herdr.sh")
        let transport = try ProcessBridgeTransport(kind: .localIPC, executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: [
            "NORTHPANE_HERDR_EXECUTABLE=\(herdr.path)",
            "NORTHPANE_HERDR_EVENT_SOCKET_OPTIONAL=1",
            "HERDR_SOCKET_PATH=\(state.appending(path: "missing-herdr.sock").path)",
            "NORTHPANE_STATE_DIRECTORY=\(state.path)",
            bridge.path, "serve", "--stdio",
        ])
        return NorthpaneBridgeClient(transport: transport, deviceID: deviceID)
    }

    /// What the Host's pairing file holds now.
    func pairedDevices() throws -> [PairedDevice] {
        struct Document: Decodable { let devices: [PairedDevice] }
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: state.appending(path: "paired-devices.json"))).devices
    }

    /// Pairs `signer` in a session of its own, as a current client does, and closes it.
    func pair(_ signer: ClientDeviceSigner) async throws {
        let client = try connect(as: signer)
        _ = try await client.handshake(signer: signer)
        _ = try await client.pair(using: signer)
        await client.close()
    }

    func remove() { try? FileManager.default.removeItem(at: state) }
}

private func expectProblem(_ code: String, _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("Expected the Bridge to answer \(code)")
    } catch let problem as Problem {
        #expect(problem.code == code)
    } catch {
        Issue.record("Expected the Bridge to answer \(code), got \(error)")
    }
}

/// A hello sent by hand, to know the challenge a client made for the Host's identity.
private func hello(_ client: NorthpaneBridgeClient, as deviceID: ClientDeviceID) async throws -> (HandshakeAccepted, Data) {
    let challenge = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    let hello = HandshakeHello(protocolRange: .init(minimum: 1, maximum: BridgeProtocol.major),
                               schemaRange: .init(minimum: NorthpaneBridgeClient.oldestSchemaRevisionSpoken, maximum: BridgeProtocol.schemaRevision),
                               clientDeviceID: deviceID, hostIdentityChallenge: challenge)
    guard case let .accepted(accepted) = try await client.request(.hello(hello)).payload else { throw Problem.malformedFrame }
    return (accepted, challenge)
}

@Test func aPairedDeviceProvesItsKeyAgainInEverySession() async throws {
    let host = BridgeHostFixture()
    defer { host.remove() }
    let signer = try ClientDeviceSigner()

    let first = try host.connect(as: signer)
    _ = try await first.handshake(signer: signer)
    // Not paired yet: no proof can stand, and nothing is granted until the device pairs.
    #expect(await first.deviceProven == false)
    await expectProblem(Problem.unauthorized.code) { _ = try await first.observe() }
    _ = try await first.pair(using: signer)
    #expect(await first.deviceProven)
    _ = try await first.observe()
    await first.close()

    let again = try host.connect(as: signer)
    defer { Task { await again.close() } }
    _ = try await again.handshake(signer: signer)
    #expect(await again.deviceProven)
    _ = try await again.observe()
    #expect(try host.pairedDevices().map(\.requiresSessionProof) == [true])
}

@Test func aCurrentClientThatOnlyDeclaresAPairedDeviceIsGrantedNothing() async throws {
    let host = BridgeHostFixture()
    defer { host.remove() }
    let owner = try ClientDeviceSigner()
    try await host.pair(owner)

    // The owner's ID and no key.
    let declared = try host.connect(deviceID: owner.deviceID)
    defer { Task { await declared.close() } }
    _ = try await declared.handshake()
    #expect(await declared.deviceProven == false)
    await expectProblem(Problem.unauthorized.code) { _ = try await declared.observe() }

    // The owner's ID and another key.
    let impostor = try ClientDeviceSigner(deviceID: owner.deviceID)
    let forged = try host.connect(as: impostor)
    defer { Task { await forged.close() } }
    await expectProblem("device_proof_invalid") { _ = try await forged.handshake(signer: impostor) }
    await expectProblem(Problem.unauthorized.code) { _ = try await forged.observe() }
}

@Test func aProofSignedInOneSessionIsRefusedInAnother() async throws {
    let host = BridgeHostFixture()
    defer { host.remove() }
    let owner = try ClientDeviceSigner()
    try await host.pair(owner)

    let x = try host.connect(as: owner), y = try host.connect(as: owner)
    defer { Task { await x.close(); await y.close() } }
    let (acceptedX, challengeX) = try await hello(x, as: owner.deviceID)
    let (acceptedY, challengeY) = try await hello(y, as: owner.deviceID)
    let signedForX = try owner.prove(DeviceSessionStatement(hostID: acceptedX.hostID, deviceID: owner.deviceID, connectionID: x.connectionID,
        protocolMajor: acceptedX.protocolMajor, schemaRevision: acceptedX.schemaRevision,
        bridgeChallenge: acceptedX.deviceChallenge, hostIdentityChallenge: challengeX))

    // Replayed in another session it proves nothing...
    guard case let .problem(replayed) = try await y.request(.deviceSessionProof(.init(clientDeviceID: owner.deviceID, signature: signedForX))).payload else {
        Issue.record("A proof made for another session was accepted")
        return
    }
    #expect(replayed.code == "device_proof_invalid")
    // ...and that session's challenge is spent: one attempt each.
    let signedForY = try owner.prove(DeviceSessionStatement(hostID: acceptedY.hostID, deviceID: owner.deviceID, connectionID: y.connectionID,
        protocolMajor: acceptedY.protocolMajor, schemaRevision: acceptedY.schemaRevision,
        bridgeChallenge: acceptedY.deviceChallenge, hostIdentityChallenge: challengeY))
    guard case let .problem(second) = try await y.request(.deviceSessionProof(.init(clientDeviceID: owner.deviceID, signature: signedForY))).payload else {
        Issue.record("A second proof was taken on a spent challenge")
        return
    }
    #expect(second.code == "device_proof_unexpected")

    // In the session it was made for, it is the proof it should be.
    guard case .deviceSessionAccepted = try await x.request(.deviceSessionProof(.init(clientDeviceID: owner.deviceID, signature: signedForX))).payload else {
        Issue.record("The proof was refused in its own session")
        return
    }
    // The hello went by hand, so the observation does too.
    guard case .runtimeSnapshot = try await x.request(.observeRuntime(.init(sessionName: nil))).payload else {
        Issue.record("The proven session was not let observe")
        return
    }
}

@Test func pairingCannotGiveAPairedDeviceAnotherKey() async throws {
    let host = BridgeHostFixture()
    defer { host.remove() }
    let owner = try ClientDeviceSigner()
    try await host.pair(owner)

    let impostor = try ClientDeviceSigner(deviceID: owner.deviceID)
    let client = try host.connect(as: impostor)
    defer { Task { await client.close() } }
    _ = try await client.handshake()
    await expectProblem("pairing_identity_conflict") { _ = try await client.pair(using: impostor) }
    #expect(try host.pairedDevices().map(\.publicKey) == [owner.publicKey])
}

@Test func pairingAgainWithTheSameKeyKeepsTheGrants() async throws {
    let host = BridgeHostFixture()
    defer { host.remove() }
    let owner = try ClientDeviceSigner()
    let first = try host.connect(as: owner)
    _ = try await first.handshake(signer: owner)
    _ = try await first.pair(using: owner)
    _ = try await first.requestAuthorizationGrant()
    await first.close()
    #expect(try host.pairedDevices().first?.grant.grants.contains(.authorizationBroker) == true)

    let again = try host.connect(as: owner)
    defer { Task { await again.close() } }
    _ = try await again.handshake()
    _ = try await again.pair(using: owner)
    #expect(try host.pairedDevices().first?.grant.grants.contains(.authorizationBroker) == true)
}

@Test func aRevocationInAnotherProcessClosesAnOpenTerminal() async throws {
    let host = BridgeHostFixture()
    defer { host.remove() }
    let owner = try ClientDeviceSigner()
    let first = try host.connect(as: owner)
    defer { Task { await first.close() } }
    _ = try await first.handshake(signer: owner)
    _ = try await first.pair(using: owner)
    let snapshot = try await first.observe()
    let channel = ChannelID()
    let attached = try await first.attach(.init(paneID: "pane-1", mode: .takeover, columns: 80, rows: 24, incarnationID: snapshot.incarnationID,
                                                snapshotID: snapshot.snapshotID, nextEventSequence: snapshot.nextEventSequence), channelID: channel)
    _ = try await first.receive() // the initial frame

    // The same device, from another connection: another Bridge process.
    let second = try host.connect(as: owner)
    _ = try await second.handshake(signer: owner)
    #expect(await second.deviceProven)
    #expect(try await second.revokeThisDevice().outcome == .applied)
    await second.close()

    // The first session's next keystroke finds the device gone, and its terminal goes with it.
    try await first.sendInput(.init(attachmentID: attached.attachmentID, sequence: 0, bytes: Data("x".utf8)), channelID: channel)
    let answer = try await withThrowingTaskGroup(of: Problem?.self) { group in
        group.addTask {
            while true { if case let .problem(problem) = try await first.receive().payload { return problem } }
        }
        group.addTask { try await Task.sleep(for: .seconds(10)); return nil }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
    #expect(answer?.code == "device_revoked")
    await expectProblem(Problem.unauthorized.code) { _ = try await first.observe() }
}

@Test func anOlderRevisionCannotDeclareADeviceThatHasProvedItsKey() async throws {
    let host = BridgeHostFixture()
    defer { host.remove() }
    let owner = try ClientDeviceSigner()
    try await host.pair(owner)

    let downgraded = try host.connect(deviceID: owner.deviceID)
    defer { Task { await downgraded.close() } }
    let accepted = try await downgraded.handshake(expectedHostFingerprint: nil, clientVersion: "older", signer: nil, newestSchemaRevision: 19)
    #expect(accepted.schemaRevision == 19)
    await expectProblem(Problem.unauthorized.code) { _ = try await downgraded.observe() }
}

/// A client of revision 19 or older can only declare its device. That keeps working for a device
/// that has never proved its key, so an older app is not cut off by an updated Host, and stops the
/// day that device proves its key from a current client.
@Test func anOlderClientKeepsItsDeviceUntilThatDeviceFirstProvesItsKey() async throws {
    let host = BridgeHostFixture()
    defer { host.remove() }
    let owner = try ClientDeviceSigner()

    let older = try host.connect(as: owner)
    _ = try await older.handshake(expectedHostFingerprint: nil, clientVersion: "older", signer: owner, newestSchemaRevision: 19)
    _ = try await older.pair(using: owner)
    await older.close()
    #expect(try host.pairedDevices().map(\.requiresSessionProof) == [false])

    let olderAgain = try host.connect(deviceID: owner.deviceID)
    _ = try await olderAgain.handshake(expectedHostFingerprint: nil, clientVersion: "older", signer: nil, newestSchemaRevision: 19)
    _ = try await olderAgain.observe()
    await olderAgain.close()

    let current = try host.connect(as: owner)
    _ = try await current.handshake(signer: owner)
    #expect(await current.deviceProven)
    await current.close()
    #expect(try host.pairedDevices().map(\.requiresSessionProof) == [true])

    let olderOnceMore = try host.connect(deviceID: owner.deviceID)
    defer { Task { await olderOnceMore.close() } }
    _ = try await olderOnceMore.handshake(expectedHostFingerprint: nil, clientVersion: "older", signer: nil, newestSchemaRevision: 19)
    await expectProblem(Problem.unauthorized.code) { _ = try await olderOnceMore.observe() }
}

/// Four connections pairing four devices at once: each is a process reading, changing and writing
/// the pairing file, and none of the four pairings is lost.
@Test func pairingsMadeAtOnceInSeparateProcessesAreAllKept() async throws {
    let host = BridgeHostFixture()
    defer { host.remove() }
    // The Host's identity is made by the first Bridge to start; made by four at once, it would be four.
    let first = try host.connect(deviceID: ClientDeviceID())
    _ = try await first.handshake()
    await first.close()

    let keys = try (0..<4).map { _ in try ClientDeviceSigner().privateKey }
    let deviceIDs = (0..<4).map { _ in ClientDeviceID() }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for (deviceID, key) in zip(deviceIDs, keys) {
            group.addTask {
                let signer = try ClientDeviceSigner(deviceID: deviceID, rawPrivateKey: key)
                try await host.pair(signer)
            }
        }
        try await group.waitForAll()
    }
    #expect(Set(try host.pairedDevices().map(\.deviceID)) == Set(deviceIDs))
}
#endif
