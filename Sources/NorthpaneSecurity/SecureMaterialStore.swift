import Foundation
import NorthpaneProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security)
import Security
#endif

public enum SecureMaterialError: Error, Equatable, Sendable { case notFound, duplicate, unavailable(Int32) }

public protocol SecureMaterialStore: Sendable {
    func store(_ data: Data, as reference: CredentialReference) async throws
    func load(_ reference: CredentialReference) async throws -> Data
    func delete(_ reference: CredentialReference) async throws
}

public actor InMemorySecureMaterialStore: SecureMaterialStore {
    private var values: [CredentialReference: Data] = [:]
    public init() {}
    public func store(_ data: Data, as reference: CredentialReference) throws { values[reference] = data }
    public func load(_ reference: CredentialReference) throws -> Data {
        guard let value = values[reference] else { throw SecureMaterialError.notFound }
        return value
    }
    public func delete(_ reference: CredentialReference) throws {
        guard values.removeValue(forKey: reference) != nil else { throw SecureMaterialError.notFound }
    }
}

#if canImport(Security)
public actor KeychainSecureMaterialStore: SecureMaterialStore {
    private let service: String
    private let accessGroup: String?
    public init(service: String = "com.northpane.secure-material", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func store(_ data: Data, as reference: CredentialReference) throws {
        let base = query(reference)
        let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw map(updateStatus) }
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw map(status) }
    }

    public func load(_ reference: CredentialReference) throws -> Data {
        var lookup = query(reference)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw map(status) }
        return data
    }

    public func delete(_ reference: CredentialReference) throws {
        let status = SecItemDelete(query(reference) as CFDictionary)
        guard status == errSecSuccess else { throw map(status) }
    }

    private func query(_ reference: CredentialReference) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.rawValue,
        ]
        if let accessGroup, !accessGroup.isEmpty { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func map(_ status: OSStatus) -> SecureMaterialError {
        status == errSecItemNotFound ? .notFound : status == errSecDuplicateItem ? .duplicate : .unavailable(status)
    }
}
#else
public actor KeychainSecureMaterialStore: SecureMaterialStore {
    private let directory: URL
    private let key: SymmetricKey?

    public init(service: String = "com.northpane.secure-material", accessGroup: String? = nil) {
        let serviceHash = SHA256.hash(data: Data(service.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/northpane/secure-material/\(serviceHash)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let keyURL = directory.appending(path: "key")
            let bytes: Data
            if FileManager.default.fileExists(atPath: keyURL.path) {
                let values = try keyURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw SecureMaterialError.unavailable(-1) }
                bytes = try Data(contentsOf: keyURL)
            } else {
                bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
                try bytes.write(to: keyURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            }
            guard bytes.count == 32 else { throw SecureMaterialError.unavailable(-1) }
            key = SymmetricKey(data: bytes)
        } catch {
            // Secure storage is fail-closed. A predictable fallback key would turn
            // an unavailable user store into silently plaintext-equivalent storage.
            key = nil
        }
    }

    public func store(_ data: Data, as reference: CredentialReference) throws {
        guard let key else { throw SecureMaterialError.unavailable(-1) }
        let sealed = try AES.GCM.seal(data, using: key).combined!
        let url = fileURL(reference)
        try sealed.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func load(_ reference: CredentialReference) throws -> Data {
        guard let key else { throw SecureMaterialError.unavailable(-1) }
        let url = fileURL(reference)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SecureMaterialError.notFound }
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key) }
        catch { throw SecureMaterialError.unavailable(-1) }
    }
    public func delete(_ reference: CredentialReference) throws {
        guard key != nil else { throw SecureMaterialError.unavailable(-1) }
        let url = fileURL(reference)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SecureMaterialError.notFound }
        try FileManager.default.removeItem(at: url)
    }
    private func fileURL(_ reference: CredentialReference) -> URL {
        let digest = SHA256.hash(data: Data(reference.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest)
    }
}
#endif
