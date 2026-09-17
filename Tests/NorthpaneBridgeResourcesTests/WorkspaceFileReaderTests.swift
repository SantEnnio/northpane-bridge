import Foundation
import Testing
@testable import NorthpaneBridgeResources

private func makeWorktree() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "northpane-files-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
    try Data("# Notes\n".utf8).write(to: root.appending(path: "docs/notes.md"))
    try Data("secret".utf8).write(to: root.appending(path: ".env"))
    try Data(("-----BEGIN " + "OPENSSH PRIVATE KEY-----\nabc").utf8).write(to: root.appending(path: "docs/key.txt"))
    try Data([0x00, 0x01, 0x02]).write(to: root.appending(path: "docs/blob.bin"))
    try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]).write(to: root.appending(path: "docs/shot.png"))
    let outside = root.deletingLastPathComponent().appending(path: "outside-\(UUID().uuidString).md")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: root.appending(path: "docs/link.md"), withDestinationURL: outside)
    return root
}

@Test func relativePathsResolveAgainstThePaneDirectoryInsideTheWorktree() throws {
    let root = try makeWorktree()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try WorkspaceFileReader.read(path: "notes.md", cwd: root.appending(path: "docs").path, workspaceRoot: root.path)
    #expect(file.relativePath == "docs/notes.md")
    #expect(file.mediaType == "text/markdown")
    #expect(file.data == Data("# Notes\n".utf8))
    let absolute = try WorkspaceFileReader.read(path: root.appending(path: "docs/notes.md").path, cwd: nil, workspaceRoot: root.path)
    #expect(absolute.relativePath == "docs/notes.md")
    let fromRoot = try WorkspaceFileReader.read(path: "./docs/notes.md", cwd: nil, workspaceRoot: root.path)
    #expect(fromRoot.relativePath == "docs/notes.md")
}

@Test func imagesAreServedAsBinaryAndTemporaryArtifactsAreAllowed() throws {
    let root = try makeWorktree()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = try WorkspaceFileReader.read(path: "docs/shot.png", cwd: nil, workspaceRoot: root.path, homeDirectory: URL(fileURLWithPath: "/nonexistent-home"), temporaryDirectories: [])
    #expect(image.mediaType == "image/png")
    #expect(!image.isText)
    #expect(image.data.count == 9)
    // An agent artifact in the temporary directory, cited with an absolute path, is readable
    // even though it is outside the workspace; the roots are the workspace, home and temp.
    let temp = FileManager.default.temporaryDirectory.appending(path: "opencode-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    try Data("# report".utf8).write(to: temp.appending(path: "report.md"))
    let artifact = try WorkspaceFileReader.read(path: temp.appending(path: "report.md").path, cwd: nil, workspaceRoot: root.path, homeDirectory: URL(fileURLWithPath: "/nonexistent-home"), temporaryDirectories: [FileManager.default.temporaryDirectory.path])
    #expect(artifact.relativePath.hasSuffix("/report.md"))
    #expect(throws: WorkspaceFileError.outsideWorkspace) { try WorkspaceFileReader.read(path: temp.appending(path: "report.md").path, cwd: nil, workspaceRoot: root.path, homeDirectory: URL(fileURLWithPath: "/nonexistent-home"), temporaryDirectories: []) }
}

@Test func readsOutsideTheWorktreeLinksBinariesAndSecretsAreRefused() throws {
    let root = try makeWorktree()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = URL(fileURLWithPath: "/nonexistent-home")
    #expect(throws: WorkspaceFileError.outsideWorkspace) { try WorkspaceFileReader.read(path: "../../etc/passwd", cwd: root.appending(path: "docs").path, workspaceRoot: root.path, homeDirectory: home, temporaryDirectories: []) }
    #expect(throws: WorkspaceFileError.outsideWorkspace) { try WorkspaceFileReader.read(path: "/etc/hosts", cwd: nil, workspaceRoot: root.path, homeDirectory: home, temporaryDirectories: []) }
    #expect(throws: WorkspaceFileError.outsideWorkspace) { try WorkspaceFileReader.read(path: "docs/link.md", cwd: nil, workspaceRoot: root.path, homeDirectory: home, temporaryDirectories: []) }
    #expect(throws: WorkspaceFileError.secretMaterial) { try WorkspaceFileReader.read(path: "~/.ssh/id_ed25519", cwd: nil, workspaceRoot: root.path, homeDirectory: root, temporaryDirectories: []) }
    #expect(throws: WorkspaceFileError.secretMaterial) { try WorkspaceFileReader.read(path: ".local/share/northpane/state.json", cwd: nil, workspaceRoot: root.path, homeDirectory: root, temporaryDirectories: []) }
    #expect(throws: WorkspaceFileError.secretMaterial) { try WorkspaceFileReader.read(path: ".env", cwd: nil, workspaceRoot: root.path) }
    #expect(throws: WorkspaceFileError.secretMaterial) { try WorkspaceFileReader.read(path: "docs/key.txt", cwd: nil, workspaceRoot: root.path) }
    #expect(throws: WorkspaceFileError.notText) { try WorkspaceFileReader.read(path: "docs/blob.bin", cwd: nil, workspaceRoot: root.path) }
    #expect(throws: WorkspaceFileError.notAFile) { try WorkspaceFileReader.read(path: "docs", cwd: nil, workspaceRoot: root.path) }
    #expect(throws: WorkspaceFileError.notFound) { try WorkspaceFileReader.read(path: "docs/missing.md", cwd: nil, workspaceRoot: root.path) }
    #expect(throws: WorkspaceFileError.invalidPath) { try WorkspaceFileReader.read(path: "https://example.com/a.md", cwd: nil, workspaceRoot: root.path) }
}

@Test func workspaceRootFallsBackToTheCommonAncestorOfThePaneDirectories() {
    #expect(WorkspaceRootResolver.root(worktreePath: "/w/tree", paneDirectories: ["/elsewhere"]) == "/w/tree")
    #expect(WorkspaceRootResolver.root(worktreePath: nil, paneDirectories: ["/Users/me/Dev/app", "/Users/me/Dev/app/src", "/Users/me/Dev/app"]) == "/Users/me/Dev/app")
    #expect(WorkspaceRootResolver.root(worktreePath: nil, paneDirectories: ["/Users/me/Dev/app", "/Users/me/Dev/lib"]) == "/Users/me/Dev")
    #expect(WorkspaceRootResolver.root(worktreePath: nil, paneDirectories: ["/Users/me", "/opt/x"]) == nil)
    #expect(WorkspaceRootResolver.root(worktreePath: nil, paneDirectories: []) == nil)
    #expect(WorkspaceRootResolver.root(worktreePath: "", paneDirectories: ["relative", "/Users/me/a"]) == "/Users/me/a")
}

@Test func aShellSittingAtHomeDoesNotDragTheWorkspaceRootUpToHome() {
    // The live case: an agent in the repository and a fresh shell at `~` in the same Workspace.
    #expect(WorkspaceRootResolver.root(worktreePath: nil, paneDirectories: ["/Users/me/Dev/app", "/Users/me"], homeDirectory: "/Users/me") == "/Users/me/Dev/app")
    #expect(WorkspaceRootResolver.root(worktreePath: nil, paneDirectories: ["/Users/me/", "/Users/me/Dev/app/src"], homeDirectory: "/Users/me") == "/Users/me/Dev/app/src")
    // Only shells at home: home it is, as before.
    #expect(WorkspaceRootResolver.root(worktreePath: nil, paneDirectories: ["/Users/me", "/Users/me"], homeDirectory: "/Users/me") == "/Users/me")
    // A shell somewhere else under home still counts, because it may well be the project.
    #expect(WorkspaceRootResolver.root(worktreePath: nil, paneDirectories: ["/Users/me/Dev/app", "/Users/me/Downloads"], homeDirectory: "/Users/me") == "/Users/me")
}
