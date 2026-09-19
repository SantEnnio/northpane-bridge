import Foundation
import NorthpaneProtocol
import Testing
@testable import NorthpaneSecurity

/// A store that has the material and will not give it up, as a Mac's Keychain does to a Bridge
/// whose signature it has not seen.
private actor RefusingSecureMaterialStore: SecureMaterialStore {
    func store(_ data: Data, as reference: CredentialReference) throws { throw SecureMaterialError.unavailable(-25308) }
    func load(_ reference: CredentialReference) throws -> Data { throw SecureMaterialError.unavailable(-25308) }
    func delete(_ reference: CredentialReference) throws { throw SecureMaterialError.unavailable(-25308) }
}

@Test func layeredStoreFindsWhatAnEarlierStoreHoldsAndCopiesItForwardWithoutRemovingIt() async throws {
    let primary = InMemorySecureMaterialStore()
    let earlier = InMemorySecureMaterialStore()
    let reference = CredentialReference(rawValue: "host-identity-test")
    let key = Data("the-key".utf8)
    try await earlier.store(key, as: reference)

    let layered = LayeredSecureMaterialStore(primary: primary, earlier: [earlier])
    #expect(try await layered.load(reference) == key)
    #expect(try await primary.load(reference) == key)
    // Rolling the Host back to the Bridge that made the key must still find it.
    #expect(try await earlier.load(reference) == key)
}

@Test func layeredStoreWritesOnlyToItsPrimary() async throws {
    let primary = InMemorySecureMaterialStore()
    let earlier = InMemorySecureMaterialStore()
    let reference = CredentialReference(rawValue: "host-identity-test")
    try await LayeredSecureMaterialStore(primary: primary, earlier: [earlier]).store(Data("k".utf8), as: reference)
    #expect(try await primary.load(reference) == Data("k".utf8))
    await #expect(throws: SecureMaterialError.notFound) { try await earlier.load(reference) }
}

@Test func layeredStoreReportsARefusalRatherThanAnAbsence() async throws {
    let reference = CredentialReference(rawValue: "host-identity-test")
    let layered = LayeredSecureMaterialStore(primary: InMemorySecureMaterialStore(), earlier: [InMemorySecureMaterialStore(), RefusingSecureMaterialStore()])
    await #expect(throws: SecureMaterialError.unavailable(-25308)) { try await layered.load(reference) }
    let empty = LayeredSecureMaterialStore(primary: InMemorySecureMaterialStore(), earlier: [InMemorySecureMaterialStore()])
    await #expect(throws: SecureMaterialError.notFound) { try await empty.load(reference) }
}

/// The failure of 2026-09-18: an identity made by a development Bridge, read by a release one.
/// The standard store is the same in both, so the second Bridge is the first Host.
@Test func anIdentityMadeWithTheKeyInAFileIsTheSameHostForTheStandardStore() async throws {
    let state = FileManager.default.temporaryDirectory.appending(path: "northpane-identity-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: state) }
    let developmentStore = try FileSecureMaterialStore(directory: state.appending(path: "secure-material/host-identity", directoryHint: .isDirectory))
    let file = state.appending(path: "host-identity.json")
    let made = try await HostIdentityFile.loadOrCreate(at: file, secureStore: developmentStore)

    let found = try await HostIdentityFile.loadOrCreate(at: file, secureStore: try HostIdentityKeyStore.standard(stateDirectory: state))
    #expect(found.hostID == made.hostID)
    #expect(found.privateKey == made.privateKey)
}
