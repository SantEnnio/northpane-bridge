#if DEBUG
import Foundation
import NorthpaneProtocol
import Testing
@testable import NorthpaneSecurity

@Test func developmentFileSecureMaterialStorePersistsPrivateOpaqueReferences() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "northpane-development-material-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DevelopmentFileSecureMaterialStore(directory: directory)
    let reference = CredentialReference(rawValue: "private-reference")
    let material = Data("development-secret".utf8)

    try await store.store(material, as: reference)
    #expect(try await store.load(reference) == material)

    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(files.count == 1)
    #expect(!files[0].contains(reference.rawValue))
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: files[0]).path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    try await store.delete(reference)
    await #expect(throws: SecureMaterialError.notFound) {
        try await store.load(reference)
    }
}
#endif
