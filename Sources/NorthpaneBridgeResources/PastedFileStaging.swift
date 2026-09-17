import Crypto
import Foundation

public enum PastedFileError: Error, Equatable, Sendable {
    /// The bytes are none of the types the Host accepts, whatever the Client claimed.
    case unsupportedType
    case tooLarge
    /// A chunk that does not continue the upload it names: wrong offset, wrong total, or an
    /// upload that was never started.
    case invalidChunk
}

/// One file the Client pasted, written on the Host where an agent can read it.
public struct StagedPastedFile: Equatable, Sendable {
    public let path: String
    public let mediaType: String
    public let byteCount: Int
    public init(path: String, mediaType: String, byteCount: Int) { self.path = path; self.mediaType = mediaType; self.byteCount = byteCount }
}

/// Where a pasted image or PDF lands on the Host so the Operator can hand its path to the agent
/// in the pane — the counterpart of a screen capture, which the agent reads the same way. The
/// directory is the Host user's temporary folder, one of the roots the confined read serves
/// from, never the Workspace: nothing pasted ever shows up in a repository's status. Files are
/// recognised by their own bytes, capped like a cited file, named by time and digest so the same
/// paste twice is the same file, and pruned by age and count on every write.
public struct PastedFileStaging: Sendable {
    public let directory: URL

    public init(directory: URL = PastedFileStaging.defaultDirectory()) { self.directory = directory }

    public static func defaultDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "northpane-pasted", directoryHint: .isDirectory)
    }

    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    public static let maximumFiles = 200

    /// What the bytes are, by their signature.
    public static func kind(of data: Data) -> (mediaType: String, fileExtension: String, limit: Int)? {
        let head = [UInt8](data.prefix(16))
        func starts(_ bytes: [UInt8]) -> Bool { head.count >= bytes.count && Array(head.prefix(bytes.count)) == bytes }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return ("image/png", "png", WorkspaceFileReader.maximumImageBytes) }
        if starts([0xFF, 0xD8, 0xFF]) { return ("image/jpeg", "jpg", WorkspaceFileReader.maximumImageBytes) }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return ("image/gif", "gif", WorkspaceFileReader.maximumImageBytes) }
        if starts(Array("RIFF".utf8)), head.count >= 12, Array(head[8..<12]) == Array("WEBP".utf8) { return ("image/webp", "webp", WorkspaceFileReader.maximumImageBytes) }
        if starts(Array("%PDF-".utf8)) { return ("application/pdf", "pdf", WorkspaceFileReader.maximumPDFBytes) }
        return nil
    }

    /// The largest upload the Host will assemble at all, before the type is known.
    public static let maximumBytes = WorkspaceFileReader.maximumPDFBytes

    /// Writes the file and answers with where it is. Same bytes, same name: a second paste of the
    /// same image overwrites an identical file instead of leaving two.
    public func store(_ data: Data, now: Date = Date()) throws -> StagedPastedFile {
        guard let kind = Self.kind(of: data) else { throw PastedFileError.unsupportedType }
        guard data.count <= kind.limit else { throw PastedFileError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let digest = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let file = directory.appending(path: "pasted-\(formatter.string(from: now))-\(digest).\(kind.fileExtension)")
        try data.write(to: file, options: .atomic)
        // The file is dated by the paste, which is also what the pruning reads.
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        prune(now: now, keeping: file)
        return StagedPastedFile(path: file.path, mediaType: kind.mediaType, byteCount: data.count)
    }

    /// Removes what is older than the retention or beyond the count, oldest first; the file just
    /// written is never among them.
    public func prune(now: Date = Date(), keeping kept: URL? = nil, retention: TimeInterval = PastedFileStaging.retention, maximumFiles: Int = PastedFileStaging.maximumFiles) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        var dated: [(url: URL, modified: Date)] = entries.compactMap { url in
            guard url.lastPathComponent.hasPrefix("pasted-"), url.lastPathComponent != kept?.lastPathComponent else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, modified)
        }
        dated.sort { $0.modified < $1.modified }
        var remaining = dated.count + (kept == nil ? 0 : 1)
        for entry in dated {
            let expired = now.timeIntervalSince(entry.modified) > retention
            guard expired || remaining > maximumFiles else { continue }
            try? fileManager.removeItem(at: entry.url)
            remaining -= 1
        }
    }
}

/// Reassembles an upload that arrives in frame-sized chunks, one upload per idempotency key.
/// Chunks must arrive in order; an upload nobody finishes is forgotten after `expiry`.
public struct PastedFileAssembly: Sendable {
    private struct Upload { var totalBytes: Int; var data: Data; var startedAt: Date }
    private var uploads: [String: Upload] = [:]
    public let expiry: TimeInterval

    public init(expiry: TimeInterval = 5 * 60) { self.expiry = expiry }

    /// Appends one chunk. Returns the whole file once the last chunk landed, nil while more is
    /// expected. The first chunk of an upload carries offset 0; every chunk repeats the total.
    public mutating func append(uploadID: String, offset: Int, totalBytes: Int, chunk: Data, now: Date = Date()) throws -> Data? {
        forgetExpired(now: now)
        guard !uploadID.isEmpty, totalBytes > 0, totalBytes <= PastedFileStaging.maximumBytes else {
            throw totalBytes > PastedFileStaging.maximumBytes ? PastedFileError.tooLarge : PastedFileError.invalidChunk
        }
        var upload = uploads[uploadID] ?? Upload(totalBytes: totalBytes, data: Data(), startedAt: now)
        guard upload.totalBytes == totalBytes, offset == upload.data.count, !chunk.isEmpty, upload.data.count + chunk.count <= totalBytes else {
            uploads[uploadID] = nil
            throw PastedFileError.invalidChunk
        }
        upload.data.append(chunk)
        if upload.data.count == totalBytes {
            uploads[uploadID] = nil
            return upload.data
        }
        uploads[uploadID] = upload
        return nil
    }

    public var pendingUploads: Int { uploads.count }

    private mutating func forgetExpired(now: Date) {
        uploads = uploads.filter { now.timeIntervalSince($0.value.startedAt) < expiry }
    }
}
