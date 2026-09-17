import Crypto
import Foundation
import Testing
@testable import NorthpaneConnection

private actor FakeDeployment: RemoteBridgeDeploymentAdapter {
    var calls: [String] = []
    let previous: String?
    init(previous: String? = "0.9.0") { self.previous = previous }
    func platformIdentifier() -> String { "macos-arm64" }
    func upload(_ data: Data, version: String) { calls.append("upload:\(version):\(data.count)") }
    func selfCheck(version: String) { calls.append("check:\(version)") }
    func activate(version: String) -> BridgeActivation { calls.append("activate:\(version)"); return .init(version: version, previousVersion: previous) }
    func rollback(_ activation: BridgeActivation) { calls.append("rollback:\(activation.previousVersion ?? "none")") }
    func prune(keeping versions: Set<String>) { calls.append("prune:\(versions.sorted().joined(separator: ","))") }
}

private func signedArtifact(data: Data) throws -> BridgeReleaseArtifact {
    let key = P256.Signing.PrivateKey()
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return .init(version: "1.0.0", downloadURL: URL(string: "https://downloads.northpane.example/bridge")!, sha256: digest, signature: try key.signature(for: data).derRepresentation, signingPublicKey: key.publicKey.x963Representation)
}

@Test func bridgeInstallerVerifiesSelfChecksActivatesAndKeepsRollback() async throws {
    let data = Data("bridge".utf8); let artifact = try signedArtifact(data: data); let deployment = FakeDeployment()
    let activation = try await RemoteBridgeInstaller().installVerified(data, artifact: artifact, using: deployment) {}
    #expect(activation == .init(version: "1.0.0", previousVersion: "0.9.0"))
    #expect(await deployment.calls == ["upload:1.0.0:6", "check:1.0.0", "activate:1.0.0", "prune:0.9.0,1.0.0"])
}

@Test func bridgeInstallerSendsTheBundledBridgeOnlyToAMatchingHost() async throws {
    let data = Data("bundled".utf8); let deployment = FakeDeployment()
    let activation = try await RemoteBridgeInstaller().installLocallyTrusted(data, version: "1.0.0", platform: "macos-arm64", using: deployment) {}
    #expect(activation == .init(version: "1.0.0", previousVersion: "0.9.0"))
    #expect(await deployment.calls == ["upload:1.0.0:7", "check:1.0.0", "activate:1.0.0", "prune:0.9.0,1.0.0"])

    let other = FakeDeployment()
    await #expect(throws: BridgeInstallationError.platformMismatch(host: "macos-arm64", bridge: "linux-x86_64")) {
        try await RemoteBridgeInstaller().installLocallyTrusted(data, version: "1.0.0", platform: "linux-x86_64", using: other) {}
    }
    #expect(await other.calls.isEmpty)
    await #expect(throws: BridgeInstallationError.invalidManifest) {
        try await RemoteBridgeInstaller().installLocallyTrusted(data, version: "../escape", platform: "macos-arm64", using: other) {}
    }
}

@Test func bridgeInstallerRollsBackWhenActivatedHandshakeFails() async throws {
    let data = Data("bridge".utf8); let artifact = try signedArtifact(data: data); let deployment = FakeDeployment()
    await #expect(throws: BridgeInstallationError.verificationFailed) {
        try await RemoteBridgeInstaller().installVerified(data, artifact: artifact, using: deployment) { throw BridgeInstallationError.verificationFailed }
    }
    #expect(await deployment.calls.contains("rollback:0.9.0"))
}

@Test func bridgeInstallerRejectsTamperedDownloadBeforeUpload() async throws {
    let artifact = try signedArtifact(data: Data("bridge".utf8)); let deployment = FakeDeployment()
    await #expect(throws: BridgeInstallationError.digestMismatch) {
        try await RemoteBridgeInstaller().installVerified(Data("tampered".utf8), artifact: artifact, using: deployment) {}
    }
    #expect(await deployment.calls.isEmpty)
}

@Test func bridgeManifestSelectsAnExactHostPlatform() throws {
    let artifact = try signedArtifact(data: Data("bridge".utf8))
    let json: [String: Any] = ["artifacts": ["linux-x86_64": [
        "version": artifact.version, "url": artifact.downloadURL.absoluteString, "sha256": artifact.sha256,
        "signature": artifact.signature.base64EncodedString(),
    ]]]
    let manifest = try JSONDecoder().decode(BridgeReleaseManifest.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(try manifest.artifact(for: "linux-x86_64", trustedSigningPublicKey: artifact.signingPublicKey) == artifact)
    #expect(throws: BridgeInstallationError.invalidManifest) { try manifest.artifact(for: "windows-x86_64", trustedSigningPublicKey: artifact.signingPublicKey) }
}
