import Foundation
import Testing
@testable import NorthpaneProtocol
@testable import NorthpaneSecurity

@Test func handshakeProvesThePinnedHostIdentity() async throws {
    let authority = try PairingAuthority()
    let challenge = Data((0..<32).map { UInt8($0) })
    let hello = HandshakeHello(protocolRange: .init(minimum: 1, maximum: 1), schemaRange: .init(minimum: 1, maximum: 1), clientDeviceID: ClientDeviceID(), hostIdentityChallenge: challenge, expectedHostFingerprint: authority.identity.fingerprint)
    let signature = try await authority.signHostIdentityChallenge(challenge)
    let accepted = HandshakeAccepted(protocolMajor: 1, schemaRevision: 1, hostID: authority.identity.hostID, capabilities: [.observeRuntime], hostSigningPublicKey: authority.identity.signingPublicKey, hostIdentitySignature: signature, herdrVersion: "0.8.2")
    #expect(try verifyHostHandshake(hello: hello, accepted: accepted) == authority.identity)
}

@Test func hostIdentityFileIsStableAndPrivate() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-host-identity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "identity.json")
    let store = InMemorySecureMaterialStore()
    let first = try await HostIdentityFile.loadOrCreate(at: file, secureStore: store)
    let second = try await HostIdentityFile.loadOrCreate(at: file, secureStore: store)
    #expect(first.hostID == second.hostID)
    #expect(first.privateKey == second.privateKey)
    #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(first.privateKey.base64EncodedString()))
    let permissions = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o077 == 0)
}

#if os(macOS) || os(iOS)
@Test func hostIdentityLeftAtCompleteProtectionIsReadableWhileLockedAfterTheNextLoad() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-host-identity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "identity.json")
    let store = InMemorySecureMaterialStore()
    let made = try await HostIdentityFile.loadOrCreate(at: file, secureStore: store)
    func protectionClass() throws -> FileProtectionType? {
        try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType
    }
    // An identity written by an older Bridge, as found on a Mac on 2026-10-15.
    let contents = try Data(contentsOf: file)
    try contents.write(to: file, options: [.atomic, .completeFileProtection])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    guard try protectionClass() == .complete else { return }  // a volume without data protection
    let loaded = try await HostIdentityFile.loadOrCreate(at: file, secureStore: store)
    #expect(loaded.hostID == made.hostID && loaded.privateKey == made.privateKey)
    #expect(try protectionClass() == .completeUntilFirstUserAuthentication)
    #expect(try Data(contentsOf: file) == contents)
    let permissions = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o077 == 0)
}
#endif

@Test func hostPairingFilePersistsOnlyPublicDeviceMaterialAndGrant() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-host-pairing-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let authority = try PairingAuthority()
    let signer = try ClientDeviceSigner()
    let challenge = await authority.issueChallenge()
    _ = try await authority.pair(signer.prove(challenge))
    let file = directory.appending(path: "pairings.json")
    try HostPairingFile.save(await authority.allPairedDevices(), hostID: authority.identity.hostID, at: file)
    let loaded = try HostPairingFile.load(at: file, hostID: authority.identity.hostID)
    #expect(loaded.first?.deviceID == signer.deviceID)
    #expect(loaded.first?.grant.permits(.terminalControl) == true)
    let permissions = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o077 == 0)
}
