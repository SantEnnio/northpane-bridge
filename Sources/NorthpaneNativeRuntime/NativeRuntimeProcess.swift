#if os(macOS) || os(Linux)
import Foundation
import NorthpaneRuntimeIPC
import SwiftProtobuf
#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum NativeRuntimeProcessError: Error, Equatable, Sendable {
    case invalidConfiguration
    case systemCall(Int32)
    case invalidFrame
    case incompatibleRevision
    case startupTimedOut
    case rejected(String)
}

/// Describes one independently running user-local process, not a Bridge connection.
public struct NativeRuntimeStatus: Equatable, Codable, Sendable {
    public let revision: UInt32
    public let incarnationID: String
    public let version: String
    public let processID: Int32
}

private enum RuntimeIPC {
    static let revision: UInt32 = 1
    static let maximumFrameBytes = 1_048_576
    static func accepts(_ revision: UInt32) -> Bool {
        revision >= max(1, self.revision - 1) && revision <= self.revision
    }
    static func directory(_ stateDirectory: URL) throws -> URL {
        guard stateDirectory.isFileURL, stateDirectory.path.hasPrefix("/"),
              !stateDirectory.path.utf8.contains(0) else { throw NativeRuntimeProcessError.invalidConfiguration }
        return stateDirectory.appending(path: "runtime", directoryHint: .isDirectory)
    }
    static func socket(_ stateDirectory: URL) throws -> String {
        try directory(stateDirectory).appending(path: "runtime.sock").path
    }
    static func descriptor(_ result: Int32) throws -> Int32 {
        guard result >= 0 else { throw NativeRuntimeProcessError.systemCall(-result) }
        return result
    }
    static func check(_ result: Int32) throws {
        if result != 0 { throw NativeRuntimeProcessError.systemCall(result) }
    }
}

/// One serial RPC connection; closing it never terminates the process it reaches.
public final class NativeRuntimeConnection: @unchecked Sendable {
    private let socket: RuntimeSocket
    public let status: NativeRuntimeStatus
    private init(socket: RuntimeSocket, status: NativeRuntimeStatus) {
        self.socket = socket; self.status = status
    }

    public static func connect(stateDirectory: URL) async throws -> NativeRuntimeConnection {
        try await connect(stateDirectory: stateDirectory, revision: RuntimeIPC.revision)
    }

    static func connect(stateDirectory: URL, revision: UInt32) async throws -> NativeRuntimeConnection {
        try await Task.detached {
            let path = try RuntimeIPC.socket(stateDirectory)
            let socket = RuntimeSocket(descriptor: try RuntimeIPC.descriptor(np_runtime_connect(path)))
            var request = Northpane_Runtime_V1_Request()
            request.id = 1
            request.hello.revision = revision
            let response = try socket.exchange(request)
            let status = try Self.status(response, expectedRevision: revision)
            return NativeRuntimeConnection(socket: socket, status: status)
        }.value
    }

    public func ping() async throws -> NativeRuntimeStatus {
        try await Task.detached { [self] in
            var request = Northpane_Runtime_V1_Request()
            request.id = 2; request.ping = .init()
            let status = try Self.status(socket.exchange(request), expectedRevision: self.status.revision)
            guard status == self.status else { throw NativeRuntimeProcessError.invalidFrame }
            return status
        }.value
    }

    public func close() { socket.close() }

    private static func status(_ response: Northpane_Runtime_V1_Response, expectedRevision: UInt32) throws -> NativeRuntimeStatus {
        if case let .failure(failure) = response.outcome {
            if failure.code == "incompatible_revision" { throw NativeRuntimeProcessError.incompatibleRevision }
            throw NativeRuntimeProcessError.rejected(failure.code)
        }
        guard case let .ready(ready) = response.outcome,
              RuntimeIPC.accepts(ready.revision), ready.revision == expectedRevision,
              UUID(uuidString: ready.incarnation) != nil, !ready.version.isEmpty,
              let pid = Int32(exactly: ready.processID), pid > 0 else {
            throw NativeRuntimeProcessError.invalidFrame
        }
        return NativeRuntimeStatus(revision: ready.revision, incarnationID: ready.incarnation,
            version: ready.version, processID: pid)
    }
}

/// Initial lifecycle/IPC foundation. It does not yet expose Workspace or terminal commands.
/// Herdr remains selected by the Bridge; this process is explicitly started for certification.
public final class NativeRuntimeServer: @unchecked Sendable {
    private let listener: Int32
    private let lockDescriptor: Int32
    private let socketPath: String
    private let stateLock = NSLock()
    private var stopping = false
    private var connections: Set<Int32> = []
    public let status: NativeRuntimeStatus

    public init(stateDirectory: URL, version: String) throws {
        guard !version.isEmpty else { throw NativeRuntimeProcessError.invalidConfiguration }
        let directory = try RuntimeIPC.directory(stateDirectory)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let lock = try RuntimeIPC.descriptor(np_runtime_lock(directory.path))
        do {
            socketPath = try RuntimeIPC.socket(stateDirectory)
            listener = try RuntimeIPC.descriptor(np_runtime_listen(socketPath))
        } catch { np_runtime_close(lock); throw error }
        lockDescriptor = lock
        status = NativeRuntimeStatus(revision: RuntimeIPC.revision, incarnationID: UUID().uuidString,
            version: version, processID: getpid())
    }

    deinit {
        np_runtime_close(listener)
        _ = np_runtime_unlink_socket(socketPath)
        np_runtime_close(lockDescriptor)
    }

    public func stop() {
        stateLock.withLock {
            stopping = true
            for fd in connections { np_runtime_shutdown(fd) }
        }
    }

    /// Blocks the calling thread until stopped. Async callers must use a
    /// dedicated thread, rather than occupy Swift's cooperative executor.
    public func run() throws {
        while !stateLock.withLock({ stopping }) {
            let fd = np_runtime_accept(listener, 250)
            if fd < 0 {
                if [-ETIMEDOUT, -EINTR, -EAGAIN, -EPERM].contains(fd) { continue }
                throw NativeRuntimeProcessError.systemCall(-fd)
            }
            let allowed = stateLock.withLock { () -> Bool in
                guard connections.count < 32, !stopping else { return false }
                connections.insert(fd); return true
            }
            guard allowed else { np_runtime_close(fd); continue }
            Thread.detachNewThread { [self] in
                let socket = RuntimeSocket(descriptor: fd)
                defer { stateLock.withLock { connections.remove(fd); socket.close() } }
                handle(socket)
            }
        }
    }

    private func handle(_ socket: RuntimeSocket) {
        var negotiated: UInt32?
        while !stateLock.withLock({ stopping }) {
            do {
                let request: Northpane_Runtime_V1_Request = try socket.receive()
                guard request.id > 0 else { return }
                var response = Northpane_Runtime_V1_Response()
                response.id = request.id
                switch request.operation {
                case let .hello(hello) where negotiated == nil:
                    guard RuntimeIPC.accepts(hello.revision) else {
                        response.failure.code = "incompatible_revision"
                        try socket.send(response); return
                    }
                    negotiated = hello.revision
                case .ping where negotiated != nil: break
                default:
                    response.failure.code = "invalid_operation"
                    try socket.send(response); return
                }
                response.ready.revision = negotiated!
                response.ready.incarnation = status.incarnationID
                response.ready.version = status.version
                response.ready.processID = Int64(status.processID)
                try socket.send(response)
            } catch { return }
        }
    }
}

/// Reuses a healthy process even if the calling Bridge has just been updated.
/// Startup races are resolved by the process lock, never by stopping an old owner.
public enum NativeRuntimeLauncher {
    public static func ensureRunning(stateDirectory: URL, executableURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> NativeRuntimeConnection {
        do { return try await NativeRuntimeConnection.connect(stateDirectory: stateDirectory) }
        catch NativeRuntimeProcessError.systemCall(let error) where error == ENOENT || error == ECONNREFUSED {}
        // Authentication/version/malformed responses are not evidence of an absent owner.
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              !executableURL.path.utf8.contains(0),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
            throw NativeRuntimeProcessError.invalidConfiguration
        }
        _ = try RuntimeIPC.directory(stateDirectory)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        // Directory and lock validation happens in the server before it removes stale sockets.
        var variables = environment
        variables["NORTHPANE_STATE_DIRECTORY"] = stateDirectory.path
        let executable = executableURL.path
        let launchEnvironment = variables
        try await Task.detached {
            let arguments: [String] = [executable, "runtime"]
            let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { $0.withCString { strdup($0) } } + [nil]
            let envp: [UnsafeMutablePointer<CChar>?] = launchEnvironment.sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)".withCString { strdup($0) } } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
                throw NativeRuntimeProcessError.systemCall(ENOMEM)
            }
            var pid: Int32 = 0
            let result = argv.withUnsafeBufferPointer { argv in
                envp.withUnsafeBufferPointer { envp in np_runtime_spawn(executable, argv.baseAddress, envp.baseAddress, &pid) }
            }
            try RuntimeIPC.check(result)
        }.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            do { return try await NativeRuntimeConnection.connect(stateDirectory: stateDirectory) }
            catch NativeRuntimeProcessError.systemCall(let error) where error == ENOENT || error == ECONNREFUSED {}
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        throw NativeRuntimeProcessError.startupTimedOut
    }
}

private final class RuntimeSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close() }
    func close() {
        lock.withLock { np_runtime_close(descriptor); descriptor = -1 }
    }
    func exchange(_ request: Northpane_Runtime_V1_Request) throws -> Northpane_Runtime_V1_Response {
        try lock.withLock {
            do {
                try send(request)
                let response: Northpane_Runtime_V1_Response = try receive()
                guard response.id == request.id else { throw NativeRuntimeProcessError.invalidFrame }
                return response
            } catch {
                // A failed/partial exchange has lost framing; never continue on that stream.
                np_runtime_close(descriptor); descriptor = -1
                throw error
            }
        }
    }
    func send<M: SwiftProtobuf.Message>(_ message: M) throws {
        let data = try message.serializedData()
        guard descriptor >= 0, !data.isEmpty, data.count <= RuntimeIPC.maximumFrameBytes else {
            throw NativeRuntimeProcessError.invalidFrame
        }
        var count = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &count) { Data($0) }; frame.append(data)
        try frame.withUnsafeBytes { try RuntimeIPC.check(np_runtime_write(descriptor, $0.baseAddress, $0.count, 2000)) }
    }
    func receive<M: SwiftProtobuf.Message>() throws -> M {
        guard descriptor >= 0 else { throw NativeRuntimeProcessError.invalidFrame }
        var header = [UInt8](repeating: 0, count: 4)
        try header.withUnsafeMutableBytes { try RuntimeIPC.check(np_runtime_read(descriptor, $0.baseAddress, 4, 10_000)) }
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= RuntimeIPC.maximumFrameBytes else { throw NativeRuntimeProcessError.invalidFrame }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { try RuntimeIPC.check(np_runtime_read(descriptor, $0.baseAddress, count, 2000)) }
        return try M(serializedBytes: data)
    }
}
#endif
