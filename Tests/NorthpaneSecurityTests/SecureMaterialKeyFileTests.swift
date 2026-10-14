import Foundation
import Testing
@testable import NorthpaneSecurity

private final class CreatedKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [Data] = []
    private var errors = 0
    func append(_ key: Data) { lock.withLock { keys.append(key) } }
    func fail() { lock.withLock { errors += 1 } }
    var unique: Set<Data> { lock.withLock { Set(keys) } }
    var failures: Int { lock.withLock { errors } }
}

@Test func concurrentSecureStoresKeepTheSameEncryptionKey() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-key-race-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "key")
    let created = CreatedKeys()
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
        do { created.append(try SecureMaterialKeyFile.loadOrCreate(at: file)) }
        catch { created.fail() }
    }
    #expect(created.failures == 0)
    #expect(created.unique.count == 1)
    #expect(created.unique == [try Data(contentsOf: file)])
}
