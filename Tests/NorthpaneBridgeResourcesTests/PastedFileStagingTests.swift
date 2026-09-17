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
