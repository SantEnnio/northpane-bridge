import Crypto
import Foundation
import Testing
@testable import NorthpaneConnection
@testable import NorthpaneProtocol

@Test func signedUpdateFeedEnforcesSignatureRolloutRevokeAndMinimumSafeVersion() throws {
    let key = P256.Signing.PrivateKey(); let device = ClientDeviceID()
    let artifact = UpdateFeedArtifact(version: "1.1.0", platform: "macos-universal", downloadURL: URL(string: "https://downloads.northpane.example/Northpane.dmg")!,
        sha256: String(repeating: "a", count: 64), rolloutPercent: 100, publishedAt: Date(timeIntervalSince1970: 1_000))
    let now = Date(timeIntervalSince1970: 1_000)
    let document = UpdateFeedDocument(channel: .stable, generatedAt: now, expiresAt: now.addingTimeInterval(86_400), minimumSafeVersion: "1.0.1", revokedVersions: ["1.0.0"], artifacts: [artifact])
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let payload = try encoder.encode(document)
    let signed = SignedUpdateFeed(payload: payload, signature: try key.signature(for: payload).derRepresentation)
    let verified = try UpdateFeedVerifier.verify(signed, trustedSigningPublicKey: key.publicKey.x963Representation, now: now)
    let decision = UpdateFeedVerifier.decide(document: verified, currentVersion: "1.0.0", platform: "macos-universal", deviceID: device)
    #expect(decision.artifact == artifact); #expect(decision.currentVersionRevoked); #expect(decision.belowMinimumSafeVersion)
    var tampered = payload; tampered.append(0)
    #expect(throws: UpdateFeedError.invalidSignature) { try UpdateFeedVerifier.verify(.init(payload: tampered, signature: signed.signature), trustedSigningPublicKey: key.publicKey.x963Representation, now: now) }
}
