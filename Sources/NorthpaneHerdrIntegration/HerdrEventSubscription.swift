import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public final class HerdrEventSubscription: @unchecked Sendable {
    private static let eventTypes = [
        "workspace.created", "workspace.updated", "workspace.metadata_updated", "workspace.renamed",
        "workspace.moved", "workspace.reordered", "workspace.closed", "workspace.focused",
        "worktree.created", "worktree.opened", "worktree.removed",
        "tab.created", "tab.closed", "tab.focused", "tab.renamed", "tab.moved",
        "pane.created", "pane.updated", "pane.closed", "pane.focused", "pane.moved", "pane.exited",
        "pane.agent_detected",
        "layout.updated",
    ]

    /// What a connection subscribes to. Herdr's runtime events are session-wide, but agent status
    /// changes (idle → blocked → done, the signal Attention lives on) are per-pane subscriptions
    /// that need a `pane_id`, so they get their own connection rebuilt when the pane set changes.
    public enum Scope: Sendable, Equatable {
        case runtime
        case agentStatus(paneIDs: [String])
    }

    private let socketPath: String
    private let scope: Scope
    private let requestID = "northpane-\(UUID().uuidString)"
    private let lock = NSLock()
    private var handle: FileHandle?
    private var buffered = Data()
    private var acknowledged = false
    private var stopped = false
    private var terminalError: Error?
    private var acknowledgement: CheckedContinuation<Void, Error>?
    private var onEvent: (@Sendable () -> Void)?
    private var onClose: (@Sendable (Error?) -> Void)?

    public init(socketPath: String, scope: Scope = .runtime) { self.socketPath = socketPath; self.scope = scope }

    public convenience init(sessionName: String? = nil, scope: Scope = .runtime, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(socketPath: Self.resolveSocketPath(sessionName: sessionName, environment: environment), scope: scope)
    }

    public static func resolveSocketPath(sessionName: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let explicit = environment["HERDR_SOCKET_PATH"], !explicit.isEmpty { return explicit }
        let base = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config", directoryHint: .isDirectory)
        var directory = base.appending(path: "herdr", directoryHint: .isDirectory)
        if let sessionName, !sessionName.isEmpty {
            directory.append(path: "sessions", directoryHint: .isDirectory)
            directory.append(path: sessionName, directoryHint: .isDirectory)
        }
        return directory.appending(path: "herdr.sock").path
    }

    public func start(
        onEvent: @escaping @Sendable () -> Void,
        onClose: @escaping @Sendable (Error?) -> Void
    ) async throws {
        let file = try Self.connect(path: socketPath)
        lock.withLock {
            self.handle = file
            self.onEvent = onEvent
            self.onClose = onClose
        }
        file.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { self?.finish(nil); return }
            self?.consume(data)
        }

        let request: [String: Any] = [
            "id": requestID,
            "method": "events.subscribe",
            "params": ["subscriptions": subscriptions],
        ]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        do { try Self.writeAll(data, to: file.fileDescriptor) }
        catch { finish(error); throw error }

        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> Result<Void, Error>? in
                if acknowledged { return .success(()) }
                if stopped { return .failure(terminalError ?? HerdrRuntimeError.sessionNotRunning) }
                acknowledgement = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    private var subscriptions: [[String: Any]] {
        switch scope {
        case .runtime: Self.eventTypes.map { ["type": $0] }
        case let .agentStatus(paneIDs): paneIDs.map { ["type": "pane.agent_status_changed", "pane_id": $0] }
        }
    }

    public func stop() { finish(nil, notify: false) }

    private func consume(_ data: Data) {
        var lines: [Data] = []
        var overflow = false
        lock.withLock {
            guard !stopped else { return }
            buffered.append(data)
            if buffered.count > 1_048_576 { overflow = true; return }
            while let newline = buffered.firstIndex(of: 0x0A) {
                let line = Data(buffered[..<newline])
                buffered.removeSubrange(...newline)
                if !line.isEmpty { lines.append(line) }
            }
        }
        if overflow { finish(HerdrRuntimeError.malformedResponse); return }
        for line in lines { consumeLine(line) }
    }

    private func consumeLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            finish(HerdrRuntimeError.malformedResponse)
            return
        }
        var ack: CheckedContinuation<Void, Error>?
        var callback: (@Sendable () -> Void)?
        var failed = false
        lock.withLock {
            guard !stopped else { return }
            if !acknowledged {
                guard object["id"] as? String == requestID, object["error"] == nil, object["result"] != nil else {
                    failed = true
                    return
                }
                acknowledged = true
                ack = acknowledgement
                acknowledgement = nil
            } else {
                callback = onEvent
            }
        }
        if failed { finish(HerdrRuntimeError.malformedResponse) }
        else if let ack { ack.resume() }
        else { callback?() }
    }

    private func finish(_ error: Error?, notify: Bool = true) {
        let state = lock.withLock { () -> (FileHandle?, CheckedContinuation<Void, Error>?, (@Sendable (Error?) -> Void)?) in
            guard !stopped else { return (nil, nil, nil) }
            stopped = true
            terminalError = error
            let state = (handle, acknowledgement, onClose)
            handle = nil; acknowledgement = nil; onEvent = nil; onClose = nil
            return state
        }
        try? state.0?.close()
        if let waiter = state.1 { waiter.resume(throwing: error ?? HerdrRuntimeError.sessionNotRunning) }
        if notify { state.2?(error) }
    }

    private static func connect(path: String) throws -> FileHandle {
#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw HerdrRuntimeError.malformedResponse
        }
        let descriptor = socket(AF_UNIX, streamSocketType, 0)
        guard descriptor >= 0 else { throw HerdrRuntimeError.sessionNotRunning }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let length = MemoryLayout<sa_family_t>.size + bytes.count + 1
#if canImport(Darwin)
        address.sun_len = UInt8(length)
#endif
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(descriptor, $0, socklen_t(length))
            }
        }
        guard result == 0 else {
            _ = Foundation.close(descriptor)
            throw HerdrRuntimeError.sessionNotRunning
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
#else
        throw HerdrRuntimeError.executableUnavailable
#endif
    }

#if canImport(Glibc)
    /// Glibc imports the socket type as an enum; Darwin and Musl as a plain constant.
    private static let streamSocketType = Int32(SOCK_STREAM.rawValue)
#elseif canImport(Darwin) || canImport(Musl)
    private static let streamSocketType = SOCK_STREAM
#endif

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                let written = Foundation.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
#else
                let written = -1
#endif
                guard written > 0 else { throw HerdrRuntimeError.sessionNotRunning }
                offset += written
            }
        }
    }
}
