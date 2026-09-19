import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import NorthpaneProtocol

/// Secure material kept in files only their owner can read, the way `sshd` keeps a host key.
///
/// This is where a Host's identity lives, on every platform and in every build. A Bridge is a
/// command started over SSH and replaced by a download: on a Mac its ad-hoc signature changes with
/// every version, and the Keychain answers a changed signature by asking the screen — which an SSH
/// session does not have — so an identity kept there is lost at the first update. A file does not
/// care which binary reads it, how it was built or signed, or whether anyone is logged in.
public actor FileSecureMaterialStore: SecureMaterialStore {
    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public func store(_ data: Data, as reference: CredentialReference) throws {
        let url = fileURL(for: reference)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func load(_ reference: CredentialReference) throws -> Data {
        let url = fileURL(for: reference)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SecureMaterialError.notFound }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw SecureMaterialError.unavailable(-1) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let permissions = attributes[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o077 != 0 {
            throw SecureMaterialError.unavailable(-1)
        }
        return try Data(contentsOf: url)
    }

    public func delete(_ reference: CredentialReference) throws {
        let url = fileURL(for: reference)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SecureMaterialError.notFound }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(for reference: CredentialReference) -> URL {
        let digest = SHA256.hash(data: Data(reference.rawValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: digest)
    }
}
