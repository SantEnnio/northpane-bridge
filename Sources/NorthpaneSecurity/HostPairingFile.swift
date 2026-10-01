import Foundation
import NorthpaneProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif

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

    /// What tells one version of the file from the next without reading it: a save replaces the
    /// file, so its identity, size or modification time moves. Nil while there is no file.
    public struct Version: Equatable, Sendable {
        let modified: Date?
        let size: Int?
        let fileNumber: Int?
    }

    public static func version(at url: URL) -> Version? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Version(modified: attributes[.modificationDate] as? Date,
                       size: (attributes[.size] as? NSNumber)?.intValue,
                       fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.intValue)
    }

    /// The lock every Bridge process on this Host takes before it changes the pairing file: each
    /// connection is a process of its own, and two that read, changed and wrote the file at once
    /// used to lose one of the two changes. Waits for the process holding it; the lock goes with
    /// that process, should it die.
    public static func lock(at url: URL) throws -> CrossProcessLock {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try CrossProcessLock(path: url.appendingPathExtension("lock"))
    }
}

/// An exclusive lock other processes respect, on a file beside what it guards.
public final class CrossProcessLock {
    #if os(Windows)
    private let handle: FileHandle
    #else
    private let descriptor: Int32
    #endif

    init(path: URL) throws {
        #if os(Windows)
        if !FileManager.default.fileExists(atPath: path.path) {
            _ = FileManager.default.createFile(atPath: path.path, contents: Data())
        }
        guard let handle = FileHandle(forUpdatingAtPath: path.path) else { throw CocoaError(.fileWriteNoPermission) }
        var overlapped = OVERLAPPED()
        guard LockFileEx(handle._handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK), 0, DWORD.max, DWORD.max, &overlapped) else {
            try? handle.close()
            throw CocoaError(.fileLocking)
        }
        self.handle = handle
        #else
        let descriptor = open(path.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                close(descriptor)
                throw CocoaError(.fileLocking)
            }
        }
        self.descriptor = descriptor
        #endif
    }

    public func unlock() {
        #if os(Windows)
        var overlapped = OVERLAPPED()
        _ = UnlockFileEx(handle._handle, 0, DWORD.max, DWORD.max, &overlapped)
        try? handle.close()
        #else
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        #endif
    }
}
