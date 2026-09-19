import Foundation
import Testing
@testable import NorthpaneBridgeResources

private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "np-listing-\(UUID().uuidString)", directoryHint: .isDirectory)
    for folder in ["Projects/beta", "Projects/Alpha", "Projects/item10", "Projects/item2", ".ssh", ".config/tool", "Documents"] {
        try FileManager.default.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
    }
    try Data("x".utf8).write(to: home.appending(path: "Projects/notes.txt"))
    try Data("x".utf8).write(to: home.appending(path: "secret.pem"))
    return home
}

@Test func anEmptyPathListsTheHomeFolderAndNamesOnlyFolders() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let listing = try HostDirectoryListing.list(path: "", homeDirectory: home, temporaryDirectories: [])
    #expect(listing.folders == ["Documents", "Projects"])
    #expect(listing.parent == nil)
    #expect(listing.rootLabel == "home")
}

@Test func aFolderListsItsFoldersInTheOrderAPersonReadsAndSaysWhereUpIs() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let listing = try HostDirectoryListing.list(path: home.appending(path: "Projects").path, homeDirectory: home, temporaryDirectories: [])
    #expect(listing.folders == ["Alpha", "beta", "item2", "item10"])
    #expect(listing.parent == listing.directory.replacingOccurrences(of: "/Projects", with: ""))
}

@Test func nothingOutsideTheRootsAndNoCredentialStoreIsListed() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(throws: HostDirectoryListing.Failure.outsideRoots) { try HostDirectoryListing.list(path: "/etc", homeDirectory: home, temporaryDirectories: []) }
    #expect(throws: HostDirectoryListing.Failure.outsideRoots) { try HostDirectoryListing.list(path: home.path + "/../", homeDirectory: home, temporaryDirectories: []) }
    #expect(throws: HostDirectoryListing.Failure.refused) { try HostDirectoryListing.list(path: home.appending(path: ".ssh").path, homeDirectory: home, temporaryDirectories: []) }
    #expect(throws: HostDirectoryListing.Failure.refused) { try HostDirectoryListing.list(path: home.appending(path: ".config/tool").path, homeDirectory: home, temporaryDirectories: []) }
    #expect(throws: HostDirectoryListing.Failure.notADirectory) { try HostDirectoryListing.list(path: home.appending(path: "Projects/notes.txt").path, homeDirectory: home, temporaryDirectories: []) }
}

@Test func aLongFolderIsCutAndSaysSo() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let listing = try HostDirectoryListing.list(path: home.appending(path: "Projects").path, homeDirectory: home, temporaryDirectories: [], limit: 2)
    #expect(listing.folders == ["Alpha", "beta"])
    #expect(listing.truncated)
}
