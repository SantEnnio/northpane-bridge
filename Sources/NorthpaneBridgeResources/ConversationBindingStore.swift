import Foundation
import Crypto
import NorthpaneProtocol

/// Explicit Operator choices, shared by the Host's independent Bridge connections.
/// Each process birth has its own encrypted record; PID/Pane reuse cannot inherit it.
/// No transcript is stored. Atomic independent records avoid lost cross-process updates.
public struct ConversationBindingStore: Sendable {
    public struct Binding: Codable, Equatable, Sendable {
        public let sessionID: String
        public let endpoint: String
        public let savedAt: Date
        public init(sessionID: String, endpoint: String, savedAt: Date = Date()) {
            self.sessionID = sessionID; self.endpoint = endpoint; self.savedAt = savedAt
        }
    }
    private let directory: URL
    private let key: SymmetricKey
    public init(directory: URL, encryptionKey: Data) {
        self.directory = directory; key = SymmetricKey(data: encryptionKey)
    }
    private func url(scope: String, paneID: String, agent: String, processProof: String) throws -> URL {
        let bytes = try JSONEncoder().encode([scope, paneID, agent, processProof])
        let name = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".bin")
    }
    public func read(scope: String, paneID: String, agent: String, processProof: String, now: Date = Date()) throws -> Binding? {
        guard !processProof.isEmpty else { return nil }
        let file = try url(scope: scope, paneID: paneID, agent: agent, processProof: processProof)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let bytes = try Data(contentsOf: file)
        guard bytes.count < 16_384 else { return nil }
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: bytes), using: key, authenticating: Data(file.lastPathComponent.utf8))
        let binding = try JSONDecoder().decode(Binding.self, from: plain)
        guard now.timeIntervalSince(binding.savedAt) < 30 * 24 * 60 * 60 else { return nil }
        return binding
    }
    public func save(_ binding: Binding, scope: String, paneID: String, agent: String, processProof: String) throws {
        guard !processProof.isEmpty, !binding.sessionID.isEmpty, binding.sessionID.utf8.count <= 512,
              binding.endpoint.utf8.count <= 4096 else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Bound records left behind by exited processes; active choices are refreshed explicitly.
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let old = files.filter { $0.pathExtension == "bin" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for file in old.prefix(max(0, old.count - 255)) { try? FileManager.default.removeItem(at: file) }
        let file = try url(scope: scope, paneID: paneID, agent: agent, processProof: processProof)
        let data = try ChaChaPoly.seal(JSONEncoder().encode(binding), using: key, authenticating: Data(file.lastPathComponent.utf8)).combined
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
