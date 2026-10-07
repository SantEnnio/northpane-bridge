import Foundation
import Testing
#if os(Windows)
import WinSDK
#endif
@testable import NorthpaneBridgeResources

@Test func largeWorkspaceFilesCanBeListedButAreRefusedBeforeReading() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(path: "northpane-large-files-\(UUID().uuidString)", directoryHint: .isDirectory)
    try manager.createDirectory(at: root.appending(path: "assets"), withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let file = root.appending(path: "large-icon.md")
    #expect(manager.createFile(atPath: file.path, contents: Data()))
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    #if os(Windows)
    // SetEndOfFile on NTFS would otherwise allocate the whole range. Never fill the disk
    // merely to exercise metadata that Foundation used to narrow to a 32-bit integer.
    var returned: DWORD = 0
    // FSCTL_SET_SPARSE = CTL_CODE(FILE_DEVICE_FILE_SYSTEM, 49, METHOD_BUFFERED, 0).
    // The SDK's function-like CTL_CODE macro is not imported by Swift.
    let setSparse: DWORD = 0x0009_00c4
    try #require(DeviceIoControl(handle._handle, setSparse, nil, 0, nil, 0, &returned, nil))
    #endif
    let size = 3_355_443_200
    try handle.truncate(atOffset: UInt64(size))
    try handle.close()

    let metadata = try #require(HostFileMetadata.read(file))
    #expect(metadata.isRegularFile && !metadata.isDirectory && !metadata.isSymbolicLink)
    #expect(metadata.byteCount == size)
    let modified = try #require(metadata.modified)
    #expect(abs(modified.timeIntervalSinceNow) < 30)
    let matches = WorkspacePathSearch.search(query: "icon", workspaceRoot: root.path,
        homeDirectory: root, temporaryDirectories: [])
    let hit = try #require(matches.hits.first { $0.relativePath == "large-icon.md" })
    #expect(hit.byteCount == size && !hit.isDirectory)
    #expect(throws: WorkspaceFileError.tooLarge) {
        try WorkspaceFileReader.read(path: "large-icon.md", cwd: nil, workspaceRoot: root.path,
            homeDirectory: root, temporaryDirectories: [])
    }
    let folders = try HostDirectoryListing.list(path: root.path, homeDirectory: root,
        temporaryDirectories: [], volumeDirectories: [])
    #expect(folders.folders == ["assets"])
    // Preserve the existing confinement: a link to even an allowed large file is not a hit.
    try manager.createSymbolicLink(at: root.appending(path: "linked-icon.md"), withDestinationURL: file)
    #expect(!WorkspacePathSearch.search(query: "icon", workspaceRoot: root.path,
        homeDirectory: root, temporaryDirectories: []).hits.contains { $0.relativePath == "linked-icon.md" })
}
