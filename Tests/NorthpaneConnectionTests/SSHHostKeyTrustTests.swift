import Foundation
import Testing
@testable import NorthpaneConnection

private let vectorKey = SSHHostKey(
    hostPattern: "build-box",
    keyType: "ssh-ed25519",
    base64Key: "AAAAC3NzaC1lZDI1NTE5AAAAIFWeoRLN5FreSVpf47TaEjvukaX6jZ2YYDImU6sejAjN"
)

@Test func aHostKeyFingerprintReadsAsSSHKeygenPrintsIt() {
    // `ssh-keygen -lf` on this key prints exactly this line's fingerprint.
    #expect(vectorKey.fingerprint == "SHA256:6kiF3EpIvyaXEjnGGeKKfp4fBw8skqbvd8+yfaaOBv8")
    #expect(vectorKey.algorithmLabel == "ED25519")
    #expect(vectorKey.knownHostsLine == "build-box ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFWeoRLN5FreSVpf47TaEjvukaX6jZ2YYDImU6sejAjN")
    #expect(SSHHostKey(hostPattern: "h", keyType: "ssh-ed25519", base64Key: "not base64!").fingerprint == nil)
}

@Test func keyscanOutputIsParsedWithoutCommentsAndInTheOrderSSHPrefers() {
    let printed = """
    # build-box:22 SSH-2.0-OpenSSH_9.9
    build-box ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7
    
    build-box ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAI
    build-box ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFWeoRLN5FreSVpf47TaEjvukaX6jZ2YYDImU6sejAjN
    garbage
    """
    let keys = SSHHostKeys.preferredOrder(SSHHostKeys.parseKeyscanOutput(printed))
    #expect(keys.map(\.algorithmLabel) == ["ED25519", "ECDSA", "RSA"])
    #expect(keys.first == vectorKey)
}

@Test func theHostPatternCarriesOnlyANonDefaultPort() {
    #expect(SSHHostKeys.hostPattern(host: "build-box", port: 22) == "build-box")
    #expect(SSHHostKeys.hostPattern(host: "build-box", port: 2222) == "[build-box]:2222")
}

#if os(macOS) || os(Linux)
@Test func anUnknownHostBecomesKnownOnceAcceptedAndOnlyOnThatPort() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "hostkey-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = SSHHostKeyTrust(knownHostsFile: directory.appending(path: "ssh/known_hosts"))

    #expect(await trust.isKnown(host: "build-box", port: 22) == false)
    try trust.accept([vectorKey])
    #expect(await trust.isKnown(host: "build-box", port: 22))
    #expect(await trust.isKnown(host: "build-box", port: 2222) == false)
    #expect(await trust.isKnown(host: "other-box", port: 22) == false)

    let attributes = try FileManager.default.attributesOfItem(atPath: trust.knownHostsFile.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: trust.knownHostsFile.deletingLastPathComponent().path)
    #expect((directoryAttributes[.posixPermissions] as? Int) == 0o700)

    // A second acceptance appends: the first line stays intact and the file still ends in a newline.
    let onPort = SSHHostKey(hostPattern: "[build-box]:2222", keyType: "ssh-ed25519", base64Key: vectorKey.base64Key)
    try trust.accept([onPort])
    let text = try String(contentsOf: trust.knownHostsFile, encoding: .utf8)
    #expect(text == vectorKey.knownHostsLine + "\n" + onPort.knownHostsLine + "\n")
    #expect(await trust.isKnown(host: "build-box", port: 2222))
}

@Test func aHostThatCouldReadAsAnOptionIsRefused() async {
    let trust = SSHHostKeyTrust(knownHostsFile: FileManager.default.temporaryDirectory.appending(path: "never-\(UUID().uuidString)"))
    await #expect(throws: SSHHostKeyTrustError.invalidHost) { try await trust.scan(host: "-oProxyCommand=evil", port: 22) }
    #expect(await trust.isKnown(host: "-oProxyCommand=evil", port: 22) == false)
}
#endif

#if os(macOS) || os(Linux)
@Test func anSSHConfigAliasResolvesToWhatSSHWouldConnectTo() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "sshcfg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appending(path: "config")
    try "Host build-box\n    HostName 10.0.0.5\n    Port 2222\n".write(to: config, atomically: true, encoding: .utf8)
    let trust = SSHHostKeyTrust(knownHostsFile: directory.appending(path: "known_hosts"), sshConfigFile: config)

    let aliased = await trust.resolve(endpoint: "dev@build-box")
    #expect(aliased.host == "10.0.0.5")
    #expect(aliased.port == 2222)
    // A plain name is what it is; the port on the endpoint still counts.
    let plain = await trust.resolve(endpoint: "dev@other-box:2200")
    #expect(plain.host == "other-box")
    #expect(plain.port == 2200)
}
#endif

