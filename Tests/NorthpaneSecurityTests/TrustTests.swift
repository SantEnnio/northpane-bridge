import Foundation
import Testing
@testable import NorthpaneProtocol
@testable import NorthpaneSecurity

@Test func pairingProofIsSingleUseAndGrantIsEnforced() async throws {
    let authority = try PairingAuthority()
    let client = try ClientDeviceSigner()
    let challenge = await authority.issueChallenge()
    let proof = try client.prove(challenge)

    _ = try await authority.pair(proof)
    try await authority.authorize(deviceID: client.deviceID, capability: .terminalControl)
    await authority.revoke(client.deviceID)
    await #expect(throws: PairingError.revoked) { try await authority.authorize(deviceID: client.deviceID, capability: .terminalControl) }
    await #expect(throws: PairingError.unknownChallenge) { try await authority.pair(proof) }
}

@Test func changedHostIdentityCannotBeAcknowledgedAway() throws {
    let expected = try PairingAuthority()
    let changed = try PairingAuthority(hostID: expected.identity.hostID)
    #expect(throws: PairingError.identityMismatch) {
        try verifyHostIdentity(expectedFingerprint: expected.identity.fingerprint, presented: changed.identity)
    }
}

@Test func secureMaterialStoreReturnsOnlyOpaqueReferences() async throws {
    let store = InMemorySecureMaterialStore()
    let reference = CredentialReference(rawValue: "host-key")
    try await store.store(Data([1, 2, 3]), as: reference)
    #expect(try await store.load(reference) == Data([1, 2, 3]))
    try await store.delete(reference)
    await #expect(throws: SecureMaterialError.notFound) { try await store.load(reference) }
}
