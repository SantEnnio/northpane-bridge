import Foundation
import NorthpaneProtocol

public enum HostPairingFile {
    private struct Document: Codable {
        let schemaVersion: Int
        let hostID: HostID
        let devices: [PairedDevice]
    }

    public static func load(at url: URL, hostID: HostID) throws -> [PairedDevice] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1, document.hostID == hostID else { throw PairingError.identityMismatch }
        return document.devices
    }

    public static func save(_ devices: [PairedDevice], hostID: HostID, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Document(schemaVersion: 1, hostID: hostID, devices: devices)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
