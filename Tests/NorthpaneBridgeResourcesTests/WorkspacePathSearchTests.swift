import Foundation
import Testing
@testable import NorthpaneBridgeResources

/// A workspace whose shape exercises every rule: the same name at two depths, the same name
/// behind a pruned directory and behind a refused one, a symbolic link, and a sibling outside.
private func makeTree() throws -> URL {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(path: "northpane-search-\(UUID().uuidString)", directoryHint: .isDirectory)
    for directory in ["target-folder",
                      "Sources/Crook/Deep/Nested/target-folder",
                      "node_modules/target-folder",
                      ".ssh/target-folder",
                      "api", "apiclient", "myapi",
                      "beta-one"] {
        try manager.createDirectory(at: root.appending(path: directory), withIntermediateDirectories: true)
    }
    try Data("notes".utf8).write(to: root.appending(path: "beta-two"))
    try Data("# Guide\n".utf8).write(to: root.appending(path: "Sources/guide.md"))

    let outside = root.deletingLastPathComponent().appending(path: "outside-\(UUID().uuidString)", directoryHint: .isDirectory)
    try manager.createDirectory(at: outside.appending(path: "target-folder"), withIntermediateDirectories: true)
    try manager.createSymbolicLink(at: root.appending(path: "linked-target-folder"), withDestinationURL: outside)
    return root
}

/// Searches only the workspace: an empty home and no temporary roots keep the real disk out.
private func search(_ query: String, in root: URL, limit: Int = 120, budget: WorkspacePathSearch.Budget = .default,
                    isCancelled: () -> Bool = { false }) -> WorkspacePathSearch.Results {
    WorkspacePathSearch.search(query: query, workspaceRoot: root.path,
                              homeDirectory: root, temporaryDirectories: [],
                              limit: limit, budget: budget, isCancelled: isCancelled)
}

@Test func aShallowMatchOutranksTheSameNameDeeperDown() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let results = search("target-folder", in: root)
    let relative = results.hits.map(\.relativePath)
    #expect(relative.first == "target-folder")
    #expect(relative.contains("Sources/Crook/Deep/Nested/target-folder"))
    let shallow = try #require(relative.firstIndex(of: "target-folder"))
    let deep = try #require(relative.firstIndex(of: "Sources/Crook/Deep/Nested/target-folder"))
    #expect(shallow < deep)
}

@Test func generatedTreesAreNotDescendedIntoButRemainFindableThemselves() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(!search("target-folder", in: root).hits.contains { $0.relativePath.hasPrefix("node_modules/") })
    #expect(search("node_modules", in: root).hits.map(\.relativePath) == ["node_modules"])
}

@Test func refusedNamesAreInvisibleWithTheirWholeSubtree() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(!search("target-folder", in: root).hits.contains { $0.relativePath.contains(".ssh") })
    #expect(search("ssh", in: root).hits.isEmpty)
}

@Test func symbolicLinksAreNeitherReportedNorFollowed() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let results = search("target-folder", in: root)
    #expect(!results.hits.contains { $0.relativePath.contains("linked-target-folder") })
    #expect(results.hits.allSatisfy { $0.path.hasSuffix($0.relativePath) })
    #expect(!results.hits.contains { $0.path.contains("/outside-") })
}

@Test func everyHitLiesInsideAnAllowedRoot() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let siblings = try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path)
    let outsideName = try #require(siblings.first { $0.hasPrefix("outside-") })
    #expect(search(outsideName, in: root).hits.isEmpty)
}

@Test func anExactNameBeatsAPrefixWhichBeatsASubstring() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(search("api", in: root).hits.map(\.relativePath) == ["api", "apiclient", "myapi"])
}

@Test func directoriesComeBeforeFilesThatScoreTheSame() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let results = search("beta", in: root)
    #expect(results.hits.map(\.relativePath) == ["beta-one", "beta-two"])
    #expect(results.hits.first?.isDirectory == true)
    #expect(results.hits.last?.isDirectory == false)
}

@Test func everyTermMustMatchAndOneOfThemMustBeTheNameItself() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(search("nested target", in: root).hits.map(\.relativePath) == ["Sources/Crook/Deep/Nested/target-folder"])
    // "Sources" alone matches the directory; it must not drag every entry below it along.
    #expect(search("sources", in: root).hits.map(\.relativePath) == ["Sources"])
    #expect(search("crook missing", in: root).hits.isEmpty)
}

@Test func matchingIgnoresCase() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(search("TARGET-FOLDER", in: root).hits.first?.relativePath == "target-folder")
}

@Test func aQueryTooShortToNarrowAnythingReturnsNothing() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(search("a", in: root).hits.isEmpty)
    #expect(search("  ", in: root).hits.isEmpty)
}

@Test func theDepthCapStopsTheWalk() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    // The fixture's workspace root is also its home directory, so both caps are set: the walk
    // takes the shallower of the two for a root that covers home.
    let results = search("target-folder", in: root, budget: .init(maximumWorkspaceDepth: 2, maximumHomeDepth: 2))
    #expect(results.hits.map(\.relativePath) == ["target-folder"])
    #expect(results.truncated == false)   // the cap is the contract, not a shortfall to report
}

@Test func moreMatchesThanTheLimitAreReportedAsTruncated() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let results = search("target-folder", in: root, limit: 1)
    #expect(results.hits.count == 1)
    #expect(results.truncated)
}

@Test func cancellationStopsTheWalkAndSaysSo() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let results = search("target-folder", in: root, isCancelled: { true })
    #expect(results.hits.isEmpty)
    #expect(results.truncated)
}

@Test func aHitCarriesTheRootItCameFromAndItsMetadata() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let hit = try #require(search("guide", in: root).hits.first)
    #expect(hit.relativePath == "Sources/guide.md")
    #expect(hit.rootLabel == "workspace")
    #expect(hit.isDirectory == false)
    #expect(hit.byteCount == 8)
    #expect(hit.modified != nil)
    #expect(hit.path.hasSuffix("/Sources/guide.md"))
}
