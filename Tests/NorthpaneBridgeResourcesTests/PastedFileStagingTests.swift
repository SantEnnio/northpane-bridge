import Foundation
import Testing
@testable import NorthpaneBridgeResources

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "pasted-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@Test func aPastedFileIsRecognisedByItsBytesNotByAnyClaim() {
    #expect(PastedFileStaging.kind(of: png)?.mediaType == "image/png")
    #expect(PastedFileStaging.kind(of: jpeg)?.fileExtension == "jpg")
    #expect(PastedFileStaging.kind(of: Data("GIF89a".utf8) + Data([0, 0]))?.mediaType == "image/gif")
    #expect(PastedFileStaging.kind(of: Data("RIFF".utf8) + Data([1, 2, 3, 4]) + Data("WEBP".utf8))?.mediaType == "image/webp")
    #expect(PastedFileStaging.kind(of: Data("%PDF-1.7\n".utf8))?.mediaType == "application/pdf")
    #expect(PastedFileStaging.kind(of: Data("#!/bin/sh\nrm -rf /\n".utf8)) == nil)
    #expect(PastedFileStaging.kind(of: Data()) == nil)
}

@Test func aPastedImageLandsUnderTheStagingFolderNamedByTimeAndDigest() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let staging = PastedFileStaging(directory: directory)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let staged = try staging.store(png, now: now)
    #expect(staged.mediaType == "image/png")
    #expect(staged.byteCount == png.count)
    #expect(staged.path.hasPrefix(directory.path + "/pasted-"))
    #expect(staged.path.hasSuffix(".png"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: staged.path)) == png)
    // The same bytes pasted again at the same moment are the same file, not a second one.
    #expect(try staging.store(png, now: now).path == staged.path)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)

    #expect(throws: PastedFileError.unsupportedType) { try staging.store(Data("not an image".utf8)) }
    #expect(throws: PastedFileError.tooLarge) { try staging.store(png + Data(count: WorkspaceFileReader.maximumImageBytes)) }
}

@Test func stagedFilesArePrunedByAgeAndByCountOldestFirst() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let staging = PastedFileStaging(directory: directory)
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    var paths: [String] = []
    for index in 0 ..< 5 {
        let bytes = png + Data([UInt8(index)])
        let staged = try staging.store(bytes, now: base.addingTimeInterval(Double(index)))
        try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(Double(index))], ofItemAtPath: staged.path)
        paths.append(staged.path)
    }
    staging.prune(now: base.addingTimeInterval(10), retention: 3600, maximumFiles: 3)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(remaining.count == 3)
    #expect(!remaining.contains(URL(fileURLWithPath: paths[0]).lastPathComponent))
    #expect(remaining.contains(URL(fileURLWithPath: paths[4]).lastPathComponent))

    staging.prune(now: base.addingTimeInterval(PastedFileStaging.retention + 60), maximumFiles: 200)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

@Test func anUploadIsAssembledInOrderAndAnyOtherOrderIsRefused() throws {
    var assembly = PastedFileAssembly(expiry: 60)
    let whole = png + Data(repeating: 7, count: 100)
    let first = whole.prefix(60), second = whole.suffix(from: 60)

    #expect(try assembly.append(uploadID: "u1", offset: 0, totalBytes: whole.count, chunk: Data(first)) == nil)
    #expect(assembly.pendingUploads == 1)
    #expect(try assembly.append(uploadID: "u1", offset: 60, totalBytes: whole.count, chunk: Data(second)) == whole)
    #expect(assembly.pendingUploads == 0)

    // A chunk that skips ahead, changes the total, or starts past zero drops the upload.
    #expect(try assembly.append(uploadID: "u2", offset: 0, totalBytes: whole.count, chunk: Data(first)) == nil)
    #expect(throws: PastedFileError.invalidChunk) { try assembly.append(uploadID: "u2", offset: 61, totalBytes: whole.count, chunk: Data(second)) }
    #expect(assembly.pendingUploads == 0)
    #expect(throws: PastedFileError.invalidChunk) { try assembly.append(uploadID: "u3", offset: 10, totalBytes: whole.count, chunk: Data(first)) }
    #expect(throws: PastedFileError.tooLarge) { try assembly.append(uploadID: "u4", offset: 0, totalBytes: PastedFileStaging.maximumBytes + 1, chunk: Data(first)) }
    #expect(throws: PastedFileError.invalidChunk) { try assembly.append(uploadID: "", offset: 0, totalBytes: 10, chunk: Data(first)) }

    // An upload nobody finishes is forgotten once it expires.
    let start = Date()
    #expect(try assembly.append(uploadID: "u5", offset: 0, totalBytes: whole.count, chunk: Data(first), now: start) == nil)
    #expect(try assembly.append(uploadID: "u6", offset: 0, totalBytes: whole.count, chunk: Data(first), now: start.addingTimeInterval(120)) == nil)
    #expect(assembly.pendingUploads == 1)
}

@Test func aSentFileKeepsItsNameInAFolderOfItsOwnWhateverItsBytes() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var uploads = SentFileUploads(staging: PastedFileStaging(directory: directory))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let script = Data("#!/bin/sh\necho hello\n".utf8)

    #expect(try uploads.append(uploadID: "u1", name: "run.sh", offset: 0, totalBytes: script.count, chunk: script.prefix(10), now: now) == nil)
    // Nothing is held in memory: the bytes so far are already on disk, in a hidden partial file.
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { $0.hasPrefix(".partial-") })
    let staged = try #require(try uploads.append(uploadID: "u1", name: "run.sh", offset: 10, totalBytes: script.count, chunk: script.dropFirst(10), now: now))
    #expect(staged.path.hasPrefix(directory.path + "/sent-") && staged.path.hasSuffix("/run.sh"))
    #expect(staged.mediaType == "application/octet-stream" && staged.byteCount == script.count)
    #expect(try Data(contentsOf: URL(fileURLWithPath: staged.path)) == script)
    #expect(uploads.pendingUploads == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [URL(fileURLWithPath: staged.path).deletingLastPathComponent().lastPathComponent])

    // An image sent by name keeps its name and still says what it is.
    let image = try #require(try uploads.append(uploadID: "u2", name: "shot.png", offset: 0, totalBytes: png.count, chunk: png, now: now))
    #expect(image.mediaType == "image/png" && image.path.hasSuffix("/shot.png"))
}

@Test func aSentFileNameLosesWhatCouldLeaveTheFolder() {
    #expect(SentFileUploads.sanitizedName("report.csv") == "report.csv")
    #expect(SentFileUploads.sanitizedName("../../etc/passwd") == "passwd")
    #expect(SentFileUploads.sanitizedName("C:\\Users\\me\\notes.txt") == "notes.txt")
    #expect(SentFileUploads.sanitizedName("a\u{0}b\nc:d?.txt") == "a_b_c_d_.txt")
    #expect(SentFileUploads.sanitizedName("trailing. . ") == "trailing")
    #expect(SentFileUploads.sanitizedName("..") == nil)
    #expect(SentFileUploads.sanitizedName("/") == nil)
    #expect(SentFileUploads.sanitizedName("") == nil)
    let long = String(repeating: "è", count: 300) + ".tar.gz"
    let kept = SentFileUploads.sanitizedName(long)
    #expect(kept?.hasSuffix(".gz") == true && (kept?.utf8.count ?? .max) <= SentFileUploads.maximumNameBytes)
}

@Test func aSentFileThatIsCancelledTooLargeOrOutOfOrderLeavesNothing() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var uploads = SentFileUploads(staging: PastedFileStaging(directory: directory), expiry: 60)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let chunk = Data(repeating: 7, count: 100)

    _ = try uploads.append(uploadID: "c", name: "big.bin", offset: 0, totalBytes: 300, chunk: chunk, now: now)
    uploads.cancel(uploadID: "c")
    #expect(uploads.pendingUploads == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

    #expect(throws: PastedFileError.tooLarge) { try uploads.append(uploadID: "t", name: "huge.bin", offset: 0, totalBytes: SentFileUploads.maximumBytes + 1, chunk: chunk, now: now) }
    #expect(throws: PastedFileError.invalidName) { try uploads.append(uploadID: "n", name: "..", offset: 0, totalBytes: 100, chunk: chunk, now: now) }
    #expect(throws: PastedFileError.invalidChunk) { try uploads.append(uploadID: "o", name: "a.bin", offset: 50, totalBytes: 300, chunk: chunk, now: now) }

    _ = try uploads.append(uploadID: "s", name: "skip.bin", offset: 0, totalBytes: 300, chunk: chunk, now: now)
    #expect(throws: PastedFileError.invalidChunk) { try uploads.append(uploadID: "s", name: "skip.bin", offset: 200, totalBytes: 300, chunk: chunk, now: now) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

    // One nobody finishes is dropped with its partial file once the expiry passes.
    _ = try uploads.append(uploadID: "e", name: "left.bin", offset: 0, totalBytes: 300, chunk: chunk, now: now)
    #expect(throws: PastedFileError.invalidChunk) { try uploads.append(uploadID: "e", name: "left.bin", offset: 100, totalBytes: 300, chunk: chunk, now: now.addingTimeInterval(61)) }
    #expect(uploads.pendingUploads == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}
