#if canImport(Darwin)
import Darwin
import Foundation
import NorthpaneConnection

final class UnixSocketListener: @unchecked Sendable {
    private let descriptor: Int32
    private let path: String

    init(path: String) throws {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw SystemTransportError.invalidEndpoint }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SystemTransportError.ioFailure }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let length = MemoryLayout<sa_family_t>.size + bytes.count + 1
        address.sun_len = UInt8(length)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(length)) }
        }
        guard result == 0, Darwin.chmod(path, 0o600) == 0, Darwin.listen(descriptor, 16) == 0 else {
            Darwin.close(descriptor)
            throw SystemTransportError.ioFailure
        }
        self.descriptor = descriptor
        self.path = path
    }

    deinit {
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(atPath: path)
    }

    func run(handler: @escaping @Sendable (FileHandle, Int32) async -> Void) async throws {
        while !Task.isCancelled {
            let client = await Task.detached { Darwin.accept(self.descriptor, nil, nil) }.value
            guard client >= 0 else { throw SystemTransportError.ioFailure }
            var peerUser: uid_t = 0
            var peerGroup: gid_t = 0
            guard getpeereid(client, &peerUser, &peerGroup) == 0, peerUser == geteuid() else {
                Darwin.close(client)
                continue
            }
            var peerProcess: pid_t = 0
            var peerProcessSize = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peerProcess, &peerProcessSize) == 0, peerProcess > 0 else {
                Darwin.close(client)
                continue
            }
            let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
            Task { await handler(handle, peerProcess) }
        }
    }
}
#else
import Foundation
import NorthpaneConnection

final class UnixSocketListener {
    init(path: String) throws { throw SystemTransportError.unsupportedPlatform }
    func run(handler: @escaping @Sendable (FileHandle, Int32) async -> Void) async throws { throw SystemTransportError.unsupportedPlatform }
}
#endif
