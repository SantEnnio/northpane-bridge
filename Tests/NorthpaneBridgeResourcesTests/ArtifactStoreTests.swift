import Foundation
import Testing
@testable import NorthpaneBridgeResources

@Test func artifactPublicationIsImmutableAndRejectsSymlinks() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "northpane-artifact-\(UUID().uuidString)")
    let sourceRoot = base.appending(path: "source")
    let storageRoot = base.appending(path: "store")
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = sourceRoot.appending(path: "report.txt")
    try Data("first".utf8).write(to: source)
    let store = try ArtifactStore(allowedRoot: sourceRoot, storageRoot: storageRoot)
    let publication = try await store.publish(file: source, mediaType: "text/plain")
    try Data("second".utf8).write(to: source)
    #expect(try await store.data(for: publication.id) == Data("first".utf8))

    let link = sourceRoot.appending(path: "link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    await #expect(throws: ArtifactError.symbolicLink) { try await store.publish(file: link, mediaType: "text/plain") }
}

@Test func artifactRejectsSecretMaterialAndViewerHasNoPrivileges() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "northpane-secret-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let secret = base.appending(path: ".env")
    try Data("TOKEN=secret".utf8).write(to: secret)
    let store = try ArtifactStore(allowedRoot: base, storageRoot: base.appending(path: "store"))
    await #expect(throws: ArtifactError.secretMaterial) { try await store.publish(file: secret, mediaType: "text/plain") }
    #expect(!ArtifactViewerPolicy.allowsNetworkAccess)
    #expect(!ArtifactViewerPolicy.allowsPrivilegedAPIAccess)
    #expect(ArtifactViewerPolicy.mayRenderInline(mediaType: "text/html", filename: "index.html"))
    #expect(!ArtifactViewerPolicy.mayRenderInline(mediaType: "application/zip", filename: "source.zip"))
}

@Test func directoryPublicationIsAtomicAddressedAndReloadable() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "northpane-directory-\(UUID().uuidString)")
    let sourceRoot = base.appending(path: "source")
    let directory = sourceRoot.appending(path: "site")
    let storage = base.appending(path: "store")
    try FileManager.default.createDirectory(at: directory.appending(path: "assets"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try Data("<h1>Northpane</h1>".utf8).write(to: directory.appending(path: "index.html"))
    try Data([0, 1, 2]).write(to: directory.appending(path: "assets/icon.bin"))
    let store = try ArtifactStore(allowedRoot: sourceRoot, storageRoot: storage)
    let first = try await store.publish(file: directory, mediaType: "text/html", idempotencyKey: "build-1")
    let duplicate = try await store.publish(file: directory, mediaType: "text/html", idempotencyKey: "build-1")
    #expect(first == duplicate)
    #expect(first.fileCount == 2)
    #expect(try await store.data(for: first.id, relativePath: "index.html") == Data("<h1>Northpane</h1>".utf8))
    await #expect(throws: ArtifactError.invalidRelativePath) {
        try await store.data(for: first.id, relativePath: "../index.html")
    }

    let reloaded = try ArtifactStore(allowedRoot: sourceRoot, storageRoot: storage)
    #expect(try await reloaded.publication(id: first.id) == first)
    #expect(try await reloaded.entries(for: first.id).map(\.relativePath) == ["assets/icon.bin", "index.html"])
}

@Test func artifactEnforcesPerPublicationAndHostQuotas() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "northpane-quota-\(UUID().uuidString)")
    let source = base.appending(path: "source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try Data(repeating: 1, count: 6).write(to: source.appending(path: "one.bin"))
    let store = try ArtifactStore(
        allowedRoot: source,
        storageRoot: base.appending(path: "store"),
        limits: .init(maximumFileCount: 5_000, maximumTotalBytes: 10, maximumFileBytes: 10, maximumHostBytes: 5, retention: 60, maximumRetention: 120)
    )
    await #expect(throws: ArtifactError.hostQuotaExceeded) {
        try await store.publish(file: source.appending(path: "one.bin"), mediaType: "application/octet-stream")
    }
}
