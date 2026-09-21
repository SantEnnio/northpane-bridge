import Crypto
import Foundation

public enum PastedFileError: Error, Equatable, Sendable {
    /// The bytes are none of the types the Host accepts, whatever the Client claimed.
    case unsupportedType
    case tooLarge
    /// A chunk that does not continue the upload it names: wrong offset, wrong total, or an
    /// upload that was never started.
    case invalidChunk
    /// A sent file whose name leaves nothing usable once separators and control characters go.
    case invalidName
    /// The Host could not write the file where it stages it.
    case writeFailed
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
    /// written is never among them. A sent file's folder counts as one entry and goes whole.
    public func prune(now: Date = Date(), keeping kept: URL? = nil, retention: TimeInterval = PastedFileStaging.retention, maximumFiles: Int = PastedFileStaging.maximumFiles) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        var dated: [(url: URL, modified: Date)] = entries.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("pasted-") || name.hasPrefix(SentFileUploads.folderPrefix), name != kept?.lastPathComponent else { return nil }
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

/// Files the operator sent by name (revision 19): dropped on the Pane, picked with «Send File…»,
/// or copied in the Finder and pasted. Unlike a pasted image any bytes are taken — the operator
/// chose the file, and it reaches the pane as a path the agent reads, never as input — so what
/// guards the Host is the name and the size: the name loses every separator and control
/// character, the whole file is capped, and it lands in a folder of its own under the same
/// staging directory, `sent-<time>-<digest>/<name>`, so the agent sees the name it had and two
/// files called the same never collide. Chunks go to a hidden partial file as they arrive, so a
/// large file never sits in the Bridge's memory; one nobody finishes, or cancels, is removed.
public struct SentFileUploads: Sendable {
    public static let folderPrefix = "sent-"
    static let partialPrefix = ".partial-"
    /// The largest file the Host takes by name.
    public static let maximumBytes = 256 * 1_024 * 1_024
    public static let maximumNameBytes = 200

    private struct Upload: Sendable {
        var name: String
        var totalBytes: Int
        var received: Int
        var hasher: SHA256
        var mediaType: String
        var startedAt: Date
        var partial: URL
    }

    public let staging: PastedFileStaging
    public let expiry: TimeInterval
    private var uploads: [String: Upload] = [:]

    public init(staging: PastedFileStaging = PastedFileStaging(), expiry: TimeInterval = 5 * 60) {
        self.staging = staging
        self.expiry = expiry
    }

    /// The name the file keeps on the Host, or nil when nothing usable is left: the last path
    /// component only, without control characters or what Windows forbids in a name, trimmed of
    /// the spaces and dots Windows drops, and short enough for any file system.
    public static func sanitizedName(_ raw: String) -> String? {
        let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let forbidden = Set("<>:\"|?*")
        var name = String(String.UnicodeScalarView(last.unicodeScalars.map { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || forbidden.contains(Character(scalar)) ? "_" : scalar
        }))
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasSuffix(".") || name.hasSuffix(" ") { name.removeLast() }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        if name.utf8.count > maximumNameBytes {
            let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
            let suffix = dot.map { String(name[$0...]) }.flatMap { $0.utf8.count <= 16 ? $0 : nil } ?? ""
            var stem = String(name.dropLast(suffix.count))
            while stem.utf8.count + suffix.utf8.count > maximumNameBytes { stem.removeLast() }
            name = stem + suffix
        }
        return name
    }

    /// Appends one chunk of the upload `uploadID`. The first chunk carries offset 0 and every
    /// chunk repeats the name and the total. Answers with the staged file once the last chunk
    /// landed, nil while more is expected.
    public mutating func append(uploadID: String, name rawName: String, offset: Int, totalBytes: Int, chunk: Data, now: Date = Date()) throws -> StagedPastedFile? {
        forgetExpired(now: now)
        guard totalBytes <= Self.maximumBytes else {
            cancel(uploadID: uploadID)
            throw PastedFileError.tooLarge
        }
        guard !uploadID.isEmpty, totalBytes > 0, !chunk.isEmpty else { throw PastedFileError.invalidChunk }
        guard let name = Self.sanitizedName(rawName) else { throw PastedFileError.invalidName }
        let fileManager = FileManager.default
        var upload: Upload
        if let existing = uploads[uploadID] {
            upload = existing
        } else {
            guard offset == 0 else { throw PastedFileError.invalidChunk }
            removeAbandonedPartials(now: now)
            do {
                try fileManager.createDirectory(at: staging.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch { throw PastedFileError.writeFailed }
            let key = SHA256.hash(data: Data(uploadID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            let partial = staging.directory.appending(path: Self.partialPrefix + key)
            guard fileManager.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw PastedFileError.writeFailed }
            upload = Upload(name: name, totalBytes: totalBytes, received: 0, hasher: SHA256(),
                            mediaType: PastedFileStaging.kind(of: chunk)?.mediaType ?? "application/octet-stream", startedAt: now, partial: partial)
        }
        guard upload.name == name, upload.totalBytes == totalBytes, offset == upload.received, upload.received + chunk.count <= totalBytes else {
            cancel(uploadID: uploadID)
            throw PastedFileError.invalidChunk
        }
        do {
            let handle = try FileHandle(forWritingTo: upload.partial)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: chunk)
        } catch {
            uploads[uploadID] = upload
            cancel(uploadID: uploadID)
            throw PastedFileError.writeFailed
        }
        upload.hasher.update(data: chunk)
        upload.received += chunk.count
        guard upload.received == totalBytes else {
            uploads[uploadID] = upload
            return nil
        }
        uploads[uploadID] = nil
        return try finish(upload, now: now)
    }

    /// Forgets an upload the Client gave up on, and its partial file.
    public mutating func cancel(uploadID: String) {
        guard let upload = uploads.removeValue(forKey: uploadID) else { return }
        try? FileManager.default.removeItem(at: upload.partial)
    }

    public var pendingUploads: Int { uploads.count }

    private func finish(_ upload: Upload, now: Date) throws -> StagedPastedFile {
        let fileManager = FileManager.default
        let digest = upload.hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = staging.directory.appending(path: Self.folderPrefix + formatter.string(from: now) + "-" + digest, directoryHint: .isDirectory)
        let file = folder.appending(path: upload.name)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // The same file sent again at the same moment replaces the copy already there.
            if fileManager.fileExists(atPath: file.path) { try fileManager.removeItem(at: file) }
            try fileManager.moveItem(at: upload.partial, to: file)
        } catch {
            try? fileManager.removeItem(at: upload.partial)
            throw PastedFileError.writeFailed
        }
        // The folder is dated by the send, which is what the pruning reads.
        try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: folder.path)
        staging.prune(now: now, keeping: folder)
        return StagedPastedFile(path: file.path, mediaType: upload.mediaType, byteCount: upload.totalBytes)
    }

    private mutating func forgetExpired(now: Date) {
        for (id, upload) in uploads where now.timeIntervalSince(upload.startedAt) >= expiry { cancel(uploadID: id) }
    }

    /// A Host runs one Bridge per connection, so a partial file can outlive the process that
    /// was writing it; any that has not grown for the expiry is abandoned.
    private func removeAbandonedPartials(now: Date) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: staging.directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(Self.partialPrefix) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) >= expiry { try? fileManager.removeItem(at: entry) }
        }
    }
}
