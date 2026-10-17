import Foundation
import NorthpaneProtocol
import Testing
@testable import NorthpaneBridgeResources

@Suite struct WorkspacePathInspectionTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "inspection-\(UUID())")
        try FileManager.default.createDirectory(at: root.appending(path: "folder/empty"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appending(path: "folder/readme.md"))
        try Data([0, 1, 2, 255]).write(to: root.appending(path: "folder/blob.bin"))
        try Data("secret".utf8).write(to: root.appending(path: "folder/.env"))
        return root.resolvingSymlinksInPath()
    }

    @Test func listsImmediateChildrenAndReportsExclusions() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "folder/alias"), withDestinationURL: root.appending(path: "folder/empty"))
        let listing = try WorkspacePathInspection.list(path: "folder", cwd: root.path, workspaceRoot: root.path,
            homeDirectory: root, temporaryDirectories: [])
        #expect(listing.path == root.appending(path: "folder").path)
        #expect(listing.parentPath == root.path)
        #expect(listing.entries.map(\.relativePath) == ["empty", "blob.bin", "readme.md"])
        #expect(listing.entries.first?.isDirectory == true)
        #expect(listing.omittedEntries == 2)
        #expect(!listing.truncated)
        #expect(try WorkspacePathInspection.list(path: root.path, cwd: nil, workspaceRoot: root.path, homeDirectory: root, temporaryDirectories: []).parentPath == nil)
    }

    @Test func refusesIntermediateLinksSecretsAndPathsOutsideRoots() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "alias"), withDestinationURL: root.appending(path: "folder"))
        #expect(throws: WorkspaceFileError.symbolicLink) {
            try WorkspacePathInspection.list(path: "alias/empty", cwd: root.path, workspaceRoot: root.path, homeDirectory: root, temporaryDirectories: [])
        }
        #expect(throws: WorkspaceFileError.secretMaterial) {
            try WorkspacePathInspection.list(path: "folder/.env", cwd: root.path, workspaceRoot: root.path, homeDirectory: root, temporaryDirectories: [])
        }
        #expect(throws: WorkspaceFileError.outsideWorkspace) {
            try WorkspacePathInspection.list(path: root.deletingLastPathComponent().path, cwd: nil, workspaceRoot: root.path, homeDirectory: root, temporaryDirectories: [])
        }
    }

    @Test func aConfiguredRootCannotExposeACredentialStore() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = root.appending(path: ".aws")
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        #expect(throws: WorkspaceFileError.secretMaterial) {
            try WorkspacePathInspection.list(path: credentials.path, cwd: nil, workspaceRoot: credentials.path,
                homeDirectory: root.appending(path: "unavailable-home"), temporaryDirectories: [])
        }
        for name in ["auth.json", ".credentials.json", "credentials.db", "application_default_credentials.json"] {
            #expect(WorkspaceFileReader.isRefusedComponent(name))
        }
    }

    @Test func listingBudgetIsVisible() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = try WorkspacePathInspection.list(path: "folder", cwd: root.path, workspaceRoot: root.path,
            homeDirectory: root, temporaryDirectories: [], limit: 1)
        #expect(listing.entries.count == 1)
        #expect(listing.truncated)
    }

    @Test func downloadChunksKeepTheirOriginalBytesAndContext() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "folder/blob.bin")
        let downloads = WorkspaceFileDownloads()
        let first = try await downloads.chunk(.init(kind: .downloadWorkspaceFile, path: file.path, length: 2, paneID: "p1"),
            cwd: root.path, workspaceRoot: root.path, incarnation: "one", homeDirectory: root, temporaryDirectories: [])
        #expect(first.body == Data([0, 1]))
        #expect(!first.isFinal)
        try Data([9, 9, 9, 9]).write(to: file)
        await #expect(throws: Problem.self) {
            try await downloads.chunk(.init(kind: .downloadWorkspaceFile, path: file.path, offset: 2, length: 2, streamID: first.streamID, paneID: "p2"),
                cwd: root.path, workspaceRoot: root.path, incarnation: "one", homeDirectory: root, temporaryDirectories: [])
        }
        let second = try await downloads.chunk(.init(kind: .downloadWorkspaceFile, path: file.path, offset: 2, length: 2, streamID: first.streamID, paneID: "p1"),
            cwd: root.path, workspaceRoot: root.path, incarnation: "one", homeDirectory: root, temporaryDirectories: [])
        #expect(second.body == Data([2, 255]))
        #expect(second.isFinal)
        let anotherSession = WorkspaceFileDownloads()
        await #expect(throws: Problem.self) {
            try await anotherSession.chunk(.init(kind: .downloadWorkspaceFile, path: file.path, streamID: first.streamID, paneID: "p1"),
                cwd: root.path, workspaceRoot: root.path, incarnation: "one", homeDirectory: root, temporaryDirectories: [])
        }
    }

    @Test func downloadsScanBeyondTheFirstMegabyteAndStaySizeBounded() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "folder/secret.bin")
        var bytes = Data(repeating: 0, count: 1_100_000)
        bytes.append(Data(("-----BEGIN " + "OPENSSH PRIVATE KEY-----").utf8))
        try bytes.write(to: file)
        let downloads = WorkspaceFileDownloads()
        await #expect(throws: WorkspaceFileError.secretMaterial) {
            try await downloads.chunk(.init(kind: .downloadWorkspaceFile, path: file.path), cwd: root.path, workspaceRoot: root.path,
                incarnation: "one", homeDirectory: root, temporaryDirectories: [])
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(WorkspacePathInspection.maximumFileBytes + 1)); try handle.close()
        await #expect(throws: WorkspaceFileError.tooLarge) {
            try await downloads.chunk(.init(kind: .downloadWorkspaceFile, path: file.path), cwd: root.path, workspaceRoot: root.path,
                incarnation: "one", homeDirectory: root, temporaryDirectories: [])
        }
    }

    @Test func cancelledAndExpiredHandlesDoNotSurvive() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = WorkspaceFileDownloads(), now = Date()
        let command = ResourceCommand(kind: .downloadWorkspaceFile, path: root.appending(path: "folder/blob.bin").path, length: 1)
        let first = try await downloads.chunk(command, cwd: root.path, workspaceRoot: root.path, incarnation: "one", homeDirectory: root, temporaryDirectories: [], now: now)
        _ = try await downloads.chunk(.init(kind: .downloadWorkspaceFile, path: command.path, method: "DELETE", streamID: first.streamID),
            cwd: root.path, workspaceRoot: root.path, incarnation: "one", homeDirectory: root, temporaryDirectories: [], now: now)
        await #expect(throws: Problem.self) {
            try await downloads.chunk(.init(kind: .downloadWorkspaceFile, path: command.path, streamID: first.streamID),
                cwd: root.path, workspaceRoot: root.path, incarnation: "one", homeDirectory: root, temporaryDirectories: [], now: now)
        }
        let second = try await downloads.chunk(command, cwd: root.path, workspaceRoot: root.path, incarnation: "one", homeDirectory: root, temporaryDirectories: [], now: now)
        await #expect(throws: Problem.self) {
            try await downloads.chunk(.init(kind: .downloadWorkspaceFile, path: command.path, streamID: second.streamID),
                cwd: root.path, workspaceRoot: root.path, incarnation: "one", homeDirectory: root, temporaryDirectories: [], now: now.addingTimeInterval(121))
        }
    }
}
