#if DEBUG
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import NorthpaneProtocol

/// A development-only secure-material store for ad-hoc builds whose changing
/// code signature cannot retain Keychain ACL access between rebuilds.
public actor DevelopmentFileSecureMaterialStore: SecureMaterialStore {
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
#endif
