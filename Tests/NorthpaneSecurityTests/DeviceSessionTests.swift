import Foundation
import Synchronization
import Testing
@testable import NorthpaneProtocol
@testable import NorthpaneSecurity

private func statement(
    hostID: HostID, deviceID: ClientDeviceID, connectionID: ConnectionID, protocolMajor: Int = 1, schemaRevision: Int = 20,
    bridgeChallenge: Data = Data(repeating: 1, count: 32), hostIdentityChallenge: Data = Data(repeating: 2, count: 32)
) -> DeviceSessionStatement {
    DeviceSessionStatement(hostID: hostID, deviceID: deviceID, connectionID: connectionID, protocolMajor: protocolMajor,
                           schemaRevision: schemaRevision, bridgeChallenge: bridgeChallenge, hostIdentityChallenge: hostIdentityChallenge)
}

/// A proof stands for the one session it was signed in: change any field the statement binds and
/// the same signature no longer verifies, nor does it verify with another device's key.
@Test func aSessionProofHoldsForItsOwnStatementAndNoOther() throws {
    let signer = try ClientDeviceSigner()
    let host = HostID(), connection = ConnectionID()
    let signed = statement(hostID: host, deviceID: signer.deviceID, connectionID: connection)
    let signature = try signer.prove(signed)
    #expect(signed.isSigned(signature, by: signer.publicKey))

    let others = [
        statement(hostID: HostID(), deviceID: signer.deviceID, connectionID: connection),
        statement(hostID: host, deviceID: ClientDeviceID(), connectionID: connection),
        statement(hostID: host, deviceID: signer.deviceID, connectionID: ConnectionID()),
        statement(hostID: host, deviceID: signer.deviceID, connectionID: connection, protocolMajor: 2),
        statement(hostID: host, deviceID: signer.deviceID, connectionID: connection, schemaRevision: 19),
        statement(hostID: host, deviceID: signer.deviceID, connectionID: connection, bridgeChallenge: Data(repeating: 3, count: 32)),
        statement(hostID: host, deviceID: signer.deviceID, connectionID: connection, hostIdentityChallenge: Data(repeating: 4, count: 32)),
    ]
    for other in others { #expect(!other.isSigned(signature, by: signer.publicKey)) }
    #expect(!signed.isSigned(signature, by: try ClientDeviceSigner().publicKey))
}

/// Each field is behind its length, so bytes moved from the end of one field to the start of the
/// next make a different statement, not the same one read another way.
@Test func bytesMovedFromOneFieldIntoTheNextMakeAnotherStatement() {
    let host = HostID(), device = ClientDeviceID(), connection = ConnectionID()
    let one = statement(hostID: host, deviceID: device, connectionID: connection, bridgeChallenge: Data([1, 2]), hostIdentityChallenge: Data([3]))
    let two = statement(hostID: host, deviceID: device, connectionID: connection, bridgeChallenge: Data([1]), hostIdentityChallenge: Data([2, 3]))
    #expect(one.payload != two.payload)
}

@Test func theAuthorityVerifiesASessionOnlyForADeviceItPaired() async throws {
    let authority = try PairingAuthority()
    let signer = try ClientDeviceSigner()
    let session = statement(hostID: authority.identity.hostID, deviceID: signer.deviceID, connectionID: ConnectionID())
    await #expect(throws: PairingError.revoked) { _ = try await authority.verifySession(session, signature: try signer.prove(session)) }

    _ = try await authority.pair(signer.prove(await authority.issueChallenge()))
    #expect(try await authority.verifySession(session, signature: try signer.prove(session)).deviceID == signer.deviceID)
    let impostor = try ClientDeviceSigner(deviceID: signer.deviceID)
    await #expect(throws: PairingError.invalidSignature) { _ = try await authority.verifySession(session, signature: try impostor.prove(session)) }

    await authority.revoke(signer.deviceID)
    await #expect(throws: PairingError.revoked) { _ = try await authority.verifySession(session, signature: try signer.prove(session)) }
}

/// Pairing is open to whoever reaches the Bridge, so it cannot be the way to take a paired device's
/// identity: another key for the same ID is refused, and the same key pairing again keeps the grants.
@Test func pairingKeepsAPairedDevicesKeyAndItsGrants() async throws {
    let authority = try PairingAuthority()
    let owner = try ClientDeviceSigner()
    _ = try await authority.pair(owner.prove(await authority.issueChallenge()))
    try await authority.updateGrant(DeviceGrant(grants: [.observation, .standardControl, .authorizationBroker]), for: owner.deviceID)

    let again = try await authority.pair(owner.prove(await authority.issueChallenge()), requiresSessionProof: true)
    #expect(again.grant.grants.contains(.authorizationBroker))
    #expect(again.requiresSessionProof)

    let impostor = try ClientDeviceSigner(deviceID: owner.deviceID)
    await #expect(throws: PairingError.keyConflict) { _ = try await authority.pair(impostor.prove(await authority.issueChallenge())) }
    #expect(await authority.pairedDevice(owner.deviceID)?.publicKey == owner.publicKey)
}

@Test func aPairingWrittenBeforeRevision20DoesNotRequireTheSessionProof() throws {
    let device = PairedDevice(deviceID: ClientDeviceID(), publicKey: try ClientDeviceSigner().publicKey,
                              grant: .standard, pairedAt: Date(), requiresSessionProof: true)
    let encoded = try JSONEncoder().encode(device)
    #expect(try JSONDecoder().decode(PairedDevice.self, from: encoded).requiresSessionProof)

    var older = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    older.removeValue(forKey: "requiresSessionProof")
    let decoded = try JSONDecoder().decode(PairedDevice.self, from: try JSONSerialization.data(withJSONObject: older))
    #expect(!decoded.requiresSessionProof)
    #expect(decoded.deviceID == device.deviceID)
}

@Test func theFilesVersionMovesWithEverySave() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-pairing-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "paired-devices.json")
    let host = HostID()
    #expect(HostPairingFile.version(at: url) == nil)
    try HostPairingFile.save([], hostID: host, at: url)
    let first = HostPairingFile.version(at: url)
    let device = PairedDevice(deviceID: ClientDeviceID(), publicKey: try ClientDeviceSigner().publicKey, grant: .standard, pairedAt: Date())
    try HostPairingFile.save([device], hostID: host, at: url)
    #expect(first != nil)
    #expect(HostPairingFile.version(at: url) != first)
}

/// Every Bridge connection is a process of its own: one changing the pairings waits for the one
/// already changing them.
@Test func theLockOnThePairingsWaitsForItsHolder() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-lock-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "paired-devices.json")
    let held = try HostPairingFile.lock(at: url)
    let acquired = Mutex(false)
    // The waiter blocks a thread of its own: a blocked cooperative thread can stall a small pool.
    Thread.detachNewThread {
        guard let lock = try? HostPairingFile.lock(at: url) else { return }
        acquired.withLock { $0 = true }
        lock.unlock()
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(!acquired.withLock { $0 })
    held.unlock()
    for _ in 0..<250 where !acquired.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
    #expect(acquired.withLock { $0 })
}
