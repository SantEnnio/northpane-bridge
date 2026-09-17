import Foundation
import NorthpaneProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct HostAuditRecord: Equatable, Codable, Sendable {
    public let occurredAt: Date
    public let deviceID: ClientDeviceID?
    public let category: String
    public let reference: String
    public let outcome: String
    public let reason: String

    public init(occurredAt: Date = Date(), deviceID: ClientDeviceID?, category: String, reference: String,
                outcome: String, reason: String) {
        self.occurredAt = occurredAt; self.deviceID = deviceID; self.category = category
        self.reference = reference; self.outcome = outcome; self.reason = reason
    }
}

public actor HostAuditLog {
    private struct Document: Codable { let schemaVersion: Int; let records: [HostAuditRecord] }
    public static let retention: TimeInterval = 30 * 24 * 60 * 60
    private let fileURL: URL
    private let encryptionKey: SymmetricKey
    private var records: [HostAuditRecord]

    public init(fileURL: URL, encryptionKey: Data, legacyPlaintextURL: URL? = nil, now: Date = Date()) throws {
        guard encryptionKey.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        self.fileURL = fileURL
        self.encryptionKey = SymmetricKey(data: encryptionKey)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let stored = try Data(contentsOf: fileURL)
                let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: stored), using: self.encryptionKey)
                let document = try JSONDecoder().decode(Document.self, from: clear)
                guard document.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
                records = document.records.filter { now.timeIntervalSince($0.occurredAt) <= Self.retention }
            } catch { throw error }
        } else if let legacyPlaintextURL, FileManager.default.fileExists(atPath: legacyPlaintextURL.path) {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: legacyPlaintextURL))
            guard document.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
            records = document.records.filter { now.timeIntervalSince($0.occurredAt) <= Self.retention }
            let clear = try JSONEncoder().encode(Document(schemaVersion: 1, records: records))
            let stored = try AES.GCM.seal(clear, using: self.encryptionKey).combined!
            try stored.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            try FileManager.default.removeItem(at: legacyPlaintextURL)
        } else { records = [] }
    }

    public func append(_ record: HostAuditRecord, now: Date = Date()) throws {
        guard Self.valid(record.category), Self.valid(record.reference), Self.valid(record.outcome), Self.valid(record.reason) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        records = records.filter { now.timeIntervalSince($0.occurredAt) <= Self.retention }
        records.append(record)
        if records.count > 10_000 { records.removeFirst(records.count - 10_000) }
        try persist()
    }

    public func all(now: Date = Date()) throws -> [HostAuditRecord] {
        let retained = records.filter { now.timeIntervalSince($0.occurredAt) <= Self.retention }
        if retained.count != records.count { records = retained; try persist() }
        return records
    }

    private func persist() throws {
        let clear = try JSONEncoder().encode(Document(schemaVersion: 1, records: records))
        let stored = try AES.GCM.seal(clear, using: encryptionKey).combined!
        try stored.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains("\n") && !value.contains("\r")
    }
}
