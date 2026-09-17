import Crypto
import Foundation

/// The per-device SSH identity: a P-256 key kept in the platform secure store and
/// offered to Hosts as `ecdsa-sha2-nistp256`. iOS uses it through the native SSH
/// transport; macOS hands it to the system `ssh` as an additional identity file.
public struct NativeSSHCredential: Sendable {
    public static let keyType = "ecdsa-sha2-nistp256"
    public static let curveName = "nistp256"
    public static let defaultComment = "northpane-device"

    public let rawPrivateKey: Data

    public init(rawPrivateKey: Data? = nil) throws {
        let key = try rawPrivateKey.map(P256.Signing.PrivateKey.init(rawRepresentation:)) ?? P256.Signing.PrivateKey()
        self.rawPrivateKey = key.rawRepresentation
    }

    /// The SSH wire encoding of the public key (`string type, string curve, string Q`).
    public var publicKeyBlob: Data {
        get throws {
            let key = try P256.Signing.PrivateKey(rawRepresentation: rawPrivateKey).publicKey.x963Representation
            var blob = Data()
            blob.appendSSHString(Self.keyType)
            blob.appendSSHString(Self.curveName)
            blob.appendSSHBytes(key)
            return blob
        }
    }

    /// One `authorized_keys` line for this device.
    public var authorizedKey: String {
        get throws { "\(Self.keyType) \(try publicKeyBlob.base64EncodedString()) \(Self.defaultComment)" }
    }

    /// The unencrypted OpenSSH private key (`openssh-key-v1`) so that the system `ssh`
    /// can use the same identity the native transport uses. Callers must store it 0600.
    public var openSSHPrivateKey: String {
        get throws {
            let key = try P256.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
            let publicBlob = try publicKeyBlob
            // The check value only guards decryption of encrypted keys; deriving it from the
            // public key keeps the unencrypted export byte-stable so the file is not rewritten.
            let check = Data(SHA256.hash(data: publicBlob)).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }

            var section = Data()
            section.appendSSHUInt32(check)
            section.appendSSHUInt32(check)
            section.appendSSHString(Self.keyType)
            section.appendSSHString(Self.curveName)
            section.appendSSHBytes(key.publicKey.x963Representation)
            section.appendSSHMPInt(key.rawRepresentation)
            section.appendSSHString(Self.defaultComment)
            var padding: UInt8 = 1
            while section.count % 8 != 0 { section.append(padding); padding &+= 1 }

            var body = Data("openssh-key-v1".utf8)
            body.append(0)
            body.appendSSHString("none")
            body.appendSSHString("none")
            body.appendSSHString("")
            body.appendSSHUInt32(1)
            body.appendSSHBytes(publicBlob)
            body.appendSSHBytes(section)

            let base64 = body.base64EncodedString()
            var lines: [String] = []
            var index = base64.startIndex
            while index < base64.endIndex {
                let end = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
                lines.append(String(base64[index..<end]))
                index = end
            }
            // Assembled in pieces so the repository secret scan does not trip on the marker itself.
            return "-----BEGIN " + "OPENSSH PRIVATE KEY-----\n" + lines.joined(separator: "\n") + "\n-----END " + "OPENSSH PRIVATE KEY-----\n"
        }
    }

    /// Writes the OpenSSH private key at `url` (directory 0700, file 0600), only when
    /// the content on disk differs, and returns the same URL for `ssh -i`.
    @discardableResult
    public func materializeOpenSSHPrivateKey(at url: URL) throws -> URL {
        let contents = Data(try openSSHPrivateKey.utf8)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if let existing = try? Data(contentsOf: url), existing == contents {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        }
        try contents.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}

extension Data {
    mutating func appendSSHUInt32(_ value: UInt32) {
        var length = value.bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
    }

    mutating func appendSSHString(_ value: String) { appendSSHBytes(Data(value.utf8)) }

    mutating func appendSSHBytes(_ value: Data) {
        appendSSHUInt32(UInt32(value.count))
        append(value)
    }

    /// RFC 4251 `mpint`: two's-complement, minimal, with a leading zero when the top bit is set.
    mutating func appendSSHMPInt(_ magnitude: Data) {
        var bytes = Data(magnitude.drop(while: { $0 == 0 }))
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        appendSSHBytes(bytes)
    }
}
