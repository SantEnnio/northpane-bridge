import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import NorthpaneProtocol

public struct StoredHostIdentity: Codable, Sendable {
    public let hostID: HostID
    public let privateKey: Data
}

public enum HostIdentityFileError: Error, Equatable, Sendable { case symbolicLink, insecurePermissions, corrupt }

public enum HostIdentityFile {
    private struct Document: Codable {
        let schemaVersion: Int
        let hostID: HostID
        let privateKeyReference: CredentialReference
    }

    public static func loadOrCreate(at fileURL: URL, secureStore: any SecureMaterialStore) async throws -> StoredHostIdentity {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw HostIdentityFileError.symbolicLink }
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 != 0 { throw HostIdentityFileError.insecurePermissions }
            do {
                let data = try Data(contentsOf: fileURL)
                if let document = try? JSONDecoder().decode(Document.self, from: data) {
                    guard document.schemaVersion == 2 else { throw HostIdentityFileError.corrupt }
                    let privateKey = try await secureStore.load(document.privateKeyReference)
                    _ = try P256.Signing.PrivateKey(rawRepresentation: privateKey)
                    return .init(hostID: document.hostID, privateKey: privateKey)
                }
                // One-time migration from the original file, which contained the
                // private key directly under mode 0600.
                let legacy = try JSONDecoder().decode(StoredHostIdentity.self, from: data)
                _ = try P256.Signing.PrivateKey(rawRepresentation: legacy.privateKey)
                let reference = reference(for: legacy.hostID)
                try await secureStore.store(legacy.privateKey, as: reference)
                try write(.init(schemaVersion: 2, hostID: legacy.hostID, privateKeyReference: reference), to: fileURL)
                return legacy
            }
            // A Keychain that refuses this binary is not a corrupt file, and saying so sent a real
            // Host down the wrong path (2026-09-18): that error keeps its own identity.
            catch let error as SecureMaterialError { throw error }
            catch { throw HostIdentityFileError.corrupt }
        }
        let key = P256.Signing.PrivateKey()
        let record = StoredHostIdentity(hostID: HostID(), privateKey: key.rawRepresentation)
        let reference = reference(for: record.hostID)
        do { try await secureStore.store(record.privateKey, as: reference) }
        catch let error as SecureMaterialError { throw error }
        catch { throw HostIdentityFileError.corrupt }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try write(.init(schemaVersion: 2, hostID: record.hostID, privateKeyReference: reference), to: fileURL)
        return record
    }

    private static func reference(for hostID: HostID) -> CredentialReference {
        .init(rawValue: "host-identity-\(hostID.rawValue.uuidString)")
    }

    private static func write(_ document: Document, to fileURL: URL) throws {
        try JSONEncoder().encode(document).write(to: fileURL, options: protectedAtomicWriteOptions)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Protection until first user authentication, not complete protection: the Bridge writes this
    /// unattended, often over SSH to a Mac whose screen is locked, where complete protection makes
    /// every write fail with a permission error (the catalog made the same choice, see Catalog.swift).
    private static var protectedAtomicWriteOptions: Data.WritingOptions {
#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
#else
        [.atomic]
#endif
    }
}
