#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import NorthpaneProtocol

public struct ArtifactPublication: Equatable, Codable, Sendable {
    public let id: UUID
    public let revision: Int
    public let contentDigest: String
    public let byteCount: Int
    public let fileCount: Int
    public let isDirectory: Bool
    public let mediaType: String
    public let createdAt: Date
    public let expiresAt: Date
}

public enum ArtifactError: Error, Equatable, Sendable {
    case outsideAllowedRoot, symbolicLink, mountEscape, secretMaterial, tooManyFiles, tooLarge, hostQuotaExceeded
    case unsupportedFile, notFound, invalidRelativePath, corruptStore
}

public struct ArtifactLimits: Equatable, Sendable {
    public let maximumFileCount: Int
    public let maximumTotalBytes: Int
    public let maximumFileBytes: Int
    public let maximumHostBytes: Int
    public let retention: TimeInterval
    public let maximumRetention: TimeInterval

    public init(
        maximumFileCount: Int = 5_000,
        maximumTotalBytes: Int = 100 * 1_024 * 1_024,
        maximumFileBytes: Int = 50 * 1_024 * 1_024,
        maximumHostBytes: Int = 1_024 * 1_024 * 1_024,
        retention: TimeInterval = 7 * 24 * 60 * 60,
        maximumRetention: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.maximumFileCount = maximumFileCount
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumFileBytes = maximumFileBytes
        self.maximumHostBytes = maximumHostBytes
        self.retention = retention
        self.maximumRetention = maximumRetention
    }

    /// Backward-compatible shorthand used by focused tests and integrations.
    public init(maximumBytes: Int, retention: TimeInterval = 7 * 24 * 60 * 60) {
        self.init(maximumTotalBytes: maximumBytes, maximumFileBytes: maximumBytes, retention: retention)
    }
}

public struct ArtifactEntry: Equatable, Codable, Sendable {
    public let relativePath: String
    public let byteCount: Int
    public let contentDigest: String
}

public actor ArtifactStore {
    private struct Record: Codable {
        let publication: ArtifactPublication
        let entries: [ArtifactEntry]
        let idempotencyKey: String?
    }
    private struct Document: Codable { let schemaVersion: Int; let records: [Record] }

    private let allowedRoot: URL
    private let storageRoot: URL
    private let objectsRoot: URL
    private let metadataURL: URL
    private let limits: ArtifactLimits
    private let allowedVolume: String?
    private var records: [UUID: Record] = [:]
    private var idempotency: [String: UUID] = [:]

    public init(allowedRoot: URL, storageRoot: URL, limits: ArtifactLimits = ArtifactLimits()) throws {
        let canonicalRoot = allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.allowedRoot = canonicalRoot
        self.storageRoot = storageRoot.standardizedFileURL
        self.objectsRoot = storageRoot.standardizedFileURL.appending(path: "objects", directoryHint: .isDirectory)
        self.metadataURL = storageRoot.standardizedFileURL.appending(path: "publications-v1.json")
        self.limits = limits
        self.allowedVolume = try canonicalRoot.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier.map { String(describing: $0) }
        try FileManager.default.createDirectory(at: objectsRoot, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            do {
                let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: metadataURL))
                guard document.schemaVersion == 1 else { throw ArtifactError.corruptStore }
                self.records = Dictionary(uniqueKeysWithValues: document.records.map { ($0.publication.id, $0) })
                self.idempotency = Dictionary(uniqueKeysWithValues: document.records.compactMap { record in
                    record.idempotencyKey.map { ($0, record.publication.id) }
                })
            } catch let error as ArtifactError { throw error }
            catch { throw ArtifactError.corruptStore }
        }
    }

    public func publish(
        file source: URL,
        mediaType: String,
        idempotencyKey: String? = nil,
        requestedRetention: TimeInterval? = nil,
        now: Date = Date()
    ) throws -> ArtifactPublication {
        if let idempotencyKey, let id = idempotency[idempotencyKey], let prior = records[id], prior.publication.expiresAt >= now {
            return prior.publication
        }
        let retention = min(max(1, requestedRetention ?? limits.retention), limits.maximumRetention)
        let source = try validateSource(source)
        let temporary = storageRoot.appending(path: ".publication-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        var entries: [ArtifactEntry] = []
        var totalBytes = 0
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        do {
            if isDirectory.boolValue {
                let content = temporary.appending(path: "content", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
                let files = try regularFiles(beneath: source)
                guard files.count <= limits.maximumFileCount else { throw ArtifactError.tooManyFiles }
                let sourceComponents = source.standardizedFileURL.pathComponents
                for file in files {
                    let fileComponents = file.standardizedFileURL.pathComponents
                    guard fileComponents.count > sourceComponents.count,
                          Array(fileComponents.prefix(sourceComponents.count)) == sourceComponents
                    else { throw ArtifactError.mountEscape }
                    let relative = fileComponents.dropFirst(sourceComponents.count).joined(separator: "/")
                    guard Self.isSafeRelativePath(relative) else { throw ArtifactError.invalidRelativePath }
                    let data = try validatedData(at: file)
                    totalBytes += data.count
                    guard totalBytes <= limits.maximumTotalBytes else { throw ArtifactError.tooLarge }
                    let destination = content.appending(path: relative)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: destination, options: protectedAtomicWriteOptions)
                    entries.append(.init(relativePath: relative, byteCount: data.count, contentDigest: Self.digest(data)))
                }
            } else {
                let data = try validatedData(at: source)
                totalBytes = data.count
                try data.write(to: temporary.appending(path: "content"), options: protectedAtomicWriteOptions)
                entries = [.init(relativePath: source.lastPathComponent, byteCount: data.count, contentDigest: Self.digest(data))]
            }

            entries.sort { $0.relativePath < $1.relativePath }
            let digest = try treeDigest(entries: entries, isDirectory: isDirectory.boolValue)
            let destination = objectsRoot.appending(path: digest, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: temporary)
            } else {
                let currentBytes = Set(records.values.map { $0.publication.contentDigest }).reduce(into: 0) { total, digest in
                    total += records.values.first(where: { $0.publication.contentDigest == digest })?.publication.byteCount ?? 0
                }
                guard currentBytes + totalBytes <= limits.maximumHostBytes else { throw ArtifactError.hostQuotaExceeded }
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            let publication = ArtifactPublication(
                id: UUID(), revision: 1, contentDigest: digest, byteCount: totalBytes,
                fileCount: entries.count, isDirectory: isDirectory.boolValue, mediaType: mediaType,
                createdAt: now, expiresAt: now.addingTimeInterval(retention)
            )
            let record = Record(publication: publication, entries: entries, idempotencyKey: idempotencyKey)
            records[publication.id] = record
            if let idempotencyKey { idempotency[idempotencyKey] = publication.id }
            try persist()
            return publication
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public func publication(id: UUID, now: Date = Date()) throws -> ArtifactPublication {
        guard let record = records[id], record.publication.expiresAt >= now else { throw ArtifactError.notFound }
        return record.publication
    }

    public func list(now: Date = Date()) -> [ArtifactPublication] {
        records.values.map(\.publication).filter { $0.expiresAt >= now }.sorted { $0.createdAt > $1.createdAt }
    }

    public func entries(for id: UUID, now: Date = Date()) throws -> [ArtifactEntry] {
        guard let record = records[id], record.publication.expiresAt >= now else { throw ArtifactError.notFound }
        return record.entries
    }

    public func data(for id: UUID, relativePath: String? = nil, now: Date = Date()) throws -> Data {
        guard let record = records[id], record.publication.expiresAt >= now else { throw ArtifactError.notFound }
        let object = objectsRoot.appending(path: record.publication.contentDigest, directoryHint: .isDirectory)
        if !record.publication.isDirectory {
            guard relativePath == nil || relativePath == record.entries.first?.relativePath else { throw ArtifactError.notFound }
            return try Data(contentsOf: object.appending(path: "content"))
        }
        guard let relativePath, Self.isSafeRelativePath(relativePath), record.entries.contains(where: { $0.relativePath == relativePath }) else {
            throw ArtifactError.invalidRelativePath
        }
        return try Data(contentsOf: object.appending(path: "content", directoryHint: .isDirectory).appending(path: relativePath))
    }

    public func remove(_ id: UUID) throws {
        guard let removed = records.removeValue(forKey: id) else { throw ArtifactError.notFound }
        if let key = removed.idempotencyKey { idempotency.removeValue(forKey: key) }
        try persist()
        removeUnreferencedObject(removed.publication.contentDigest)
    }

    public func purgeExpired(now: Date = Date()) {
        let expired = records.values.filter { $0.publication.expiresAt < now }
        for record in expired {
            records.removeValue(forKey: record.publication.id)
            if let key = record.idempotencyKey { idempotency.removeValue(forKey: key) }
        }
        try? persist()
        for digest in Set(expired.map { $0.publication.contentDigest }) { removeUnreferencedObject(digest) }
    }

    private func validateSource(_ source: URL) throws -> URL {
        let standardized = source.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        guard standardized.path == resolved.path else { throw ArtifactError.symbolicLink }
        let root = allowedRoot.path
        guard resolved.path == root || resolved.path.hasPrefix(root + "/") else { throw ArtifactError.outsideAllowedRoot }
        guard FileManager.default.fileExists(atPath: resolved.path) else { throw ArtifactError.notFound }
        try validateComponentNames(resolved.pathComponents)
        return resolved
    }

    private func regularFiles(beneath directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .volumeIdentifierKey],
            options: [], errorHandler: { _, _ in false }
        ) else { throw ArtifactError.unsupportedFile }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .volumeIdentifierKey])
            if values.isSymbolicLink == true { throw ArtifactError.symbolicLink }
            if let volume = values.volumeIdentifier.map({ String(describing: $0) }), let allowedVolume, volume != allowedVolume { throw ArtifactError.mountEscape }
            try validateComponentNames([url.lastPathComponent])
            if values.isRegularFile == true { files.append(url) }
            else if values.isDirectory != true { throw ArtifactError.unsupportedFile }
            if files.count > limits.maximumFileCount { throw ArtifactError.tooManyFiles }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func validatedData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .volumeIdentifierKey])
        guard values.isRegularFile == true else { throw ArtifactError.unsupportedFile }
        guard values.isSymbolicLink != true else { throw ArtifactError.symbolicLink }
        if let volume = values.volumeIdentifier.map({ String(describing: $0) }), let allowedVolume, volume != allowedVolume { throw ArtifactError.mountEscape }
        guard let size = values.fileSize, size <= limits.maximumFileBytes else { throw ArtifactError.tooLarge }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= limits.maximumFileBytes else { throw ArtifactError.tooLarge }
        guard !containsSecret(data: data, filename: url.lastPathComponent) else { throw ArtifactError.secretMaterial }
        return data
    }

    private func validateComponentNames(_ components: [String]) throws {
        for name in components {
            let lowered = name.lowercased()
            if lowered == ".git" || lowered.hasPrefix(".env") || ["id_rsa", "id_ed25519", ".netrc", "credentials", "credentials.json"].contains(lowered) {
                throw ArtifactError.secretMaterial
            }
        }
    }

    private func containsSecret(data: Data, filename: String) -> Bool {
        if (try? validateComponentNames([filename])) == nil { return true }
        let text = String(decoding: data.prefix(1_000_000), as: UTF8.self)
        return text.range(of: #"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#, options: .regularExpression) != nil
            || text.range(of: #"gh[pousr]_[A-Za-z0-9]{30,}"#, options: .regularExpression) != nil
            || text.range(of: #"AKIA[0-9A-Z]{16}"#, options: .regularExpression) != nil
    }

    private func treeDigest(entries: [ArtifactEntry], isDirectory: Bool) throws -> String {
        let descriptor = entries.map { "\($0.relativePath.utf8.count):\($0.relativePath):\($0.byteCount):\($0.contentDigest)" }.joined(separator: "\n")
        return Self.digest(Data("\(isDirectory ? "directory" : "file")\n\(descriptor)".utf8))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
    }

    private func persist() throws {
        let document = Document(schemaVersion: 1, records: records.values.sorted { $0.publication.id.uuidString < $1.publication.id.uuidString })
        try JSONEncoder().encode(document).write(to: metadataURL, options: protectedAtomicWriteOptions)
    }

    private func removeUnreferencedObject(_ digest: String) {
        guard !records.values.contains(where: { $0.publication.contentDigest == digest }) else { return }
        try? FileManager.default.removeItem(at: objectsRoot.appending(path: digest, directoryHint: .isDirectory))
    }

    /// Protection until first user authentication, not complete protection: the Bridge writes this
    /// unattended, often over SSH to a Mac whose screen is locked, where complete protection makes
    /// every write fail with a permission error (the catalog made the same choice, see Catalog.swift).
    private var protectedAtomicWriteOptions: Data.WritingOptions {
#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
#else
        [.atomic]
#endif
    }
}

public enum ArtifactViewerPolicy {
    public static let contentSecurityPolicy = "default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; sandbox"
    public static let allowsPrivilegedAPIAccess = false
    public static let allowsNetworkAccess = false

    public static func mayRenderInline(mediaType: String, filename: String) -> Bool {
        if mediaType.hasPrefix("image/") || mediaType == "application/pdf" || mediaType.hasPrefix("text/") { return true }
        let lowered = filename.lowercased()
        return [".md", ".markdown", ".mermaid", ".mmd"].contains { lowered.hasSuffix($0) }
    }
}
