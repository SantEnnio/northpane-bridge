#if canImport(Darwin)
import Darwin
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NorthpaneProtocol

/// Why `ssh` never reached the Host. A closed set: the Operator is told which route problem
/// occurred without any standard-error text reaching the interface.
public enum SSHReachabilityFailure: String, Equatable, Sendable, CaseIterable {
    /// No route reaches the Host's address from the network this device is on. Whether this
    /// device has a network at all is a separate question, answered by its own network path.
    case hostUnreachable
    /// The address is routed and nothing answered before the connection timeout.
    case timedOut
    /// Something answered and refused the connection: the Host is up but SSH is not serving.
    case connectionRefused
    /// The Host name has no address on this network.
    case nameNotResolved
}

public enum SystemTransportError: Error, Equatable, Sendable {
    case missingEndpoint
    case invalidEndpoint
    case launchFailed
    case endOfStream
    case ioFailure
    case unsupportedPlatform
    case hostKeyMismatch(expected: String, actual: String)
    case sshAuthenticationFailed
    case sshHostVerificationFailed
    case sshUnreachable(SSHReachabilityFailure)
    case remoteBridgeUnavailable
    /// The Host's SSH session answers in a different shell from the one the command was written
    /// for: a Windows Host lands in `cmd.exe`, which cannot run the POSIX launch command.
    case remoteShellMismatch(HostShell)
    case processFailed(exitCode: Int32)
}

public final class ByteStreamBridgeTransport: BridgeTransport, @unchecked Sendable {
    public nonisolated let kind: TransportKind
    private let input: FileHandle
    private let output: FileHandle
    private let closeHandles: Bool
    public let verifiedLocalPeerProcessID: Int32?
    public let unpairedLocalObservationAllowed: Bool
    private let stateLock = NSLock()
    private let readLock = NSLock()
    private let writeLock = NSLock()
    private var isClosed = false

    public init(kind: TransportKind, input: FileHandle, output: FileHandle, closeHandles: Bool = true,
                verifiedLocalPeerProcessID: Int32? = nil, unpairedLocalObservationAllowed: Bool = false) {
        self.kind = kind; self.input = input; self.output = output; self.closeHandles = closeHandles
        self.verifiedLocalPeerProcessID = verifiedLocalPeerProcessID
        self.unpairedLocalObservationAllowed = unpairedLocalObservationAllowed
    }

    public func send(_ envelope: Envelope) async throws {
        let closed = stateLock.withLock { isClosed }
        guard !closed else { throw Problem.closedTransport }
        try writeLock.withLock {
            do { try output.write(contentsOf: FrameCodec.encode(envelope)) }
            catch let problem as Problem { throw problem }
            catch { throw SystemTransportError.ioFailure }
        }
    }

    public func receive() async throws -> Envelope {
        try await Task.detached { [self] in try blockingReceive() }.value
    }

    public func close() async {
        let shouldClose = stateLock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        guard shouldClose else { return }
        if closeHandles { try? input.close(); if output !== input { try? output.close() } }
    }

    private func blockingReceive() throws -> Envelope {
        let closed = stateLock.withLock { isClosed }
        guard !closed else { throw Problem.closedTransport }
        readLock.lock()
        defer { readLock.unlock() }
        let prefix = try readExactly(4)
        let size = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard size <= BridgeProtocol.maximumFrameBytes else { throw Problem.oversizedFrame }
        var frame = prefix
        frame.append(try readExactly(Int(size)))
        return try FrameCodec.decode(frame)
    }

    private func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            let next: Data
            do { next = try input.read(upToCount: count - result.count) ?? Data() }
            catch { throw SystemTransportError.ioFailure }
            guard !next.isEmpty else { throw SystemTransportError.endOfStream }
            result.append(next)
        }
        return result
    }
}

#if os(macOS) || os(Linux) || os(Windows)
public actor ProcessBridgeTransport: BridgeTransport {
    public nonisolated let kind: TransportKind
    private let process: Process
    private let stream: ByteStreamBridgeTransport
    private let errorOutput: FileHandle

    public init(kind: TransportKind, executableURL: URL, arguments: [String], environment: [String: String]? = nil) throws {
        self.kind = kind
        let process = Process()
        let input = Pipe(); let output = Pipe(); let errors = Pipe()
        process.executableURL = executableURL; process.arguments = arguments
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        do { try process.run() } catch { throw SystemTransportError.launchFailed }
        self.process = process
        self.stream = ByteStreamBridgeTransport(kind: kind, input: output.fileHandleForReading, output: input.fileHandleForWriting)
        self.errorOutput = errors.fileHandleForReading
    }

    public func send(_ envelope: Envelope) async throws { try await stream.send(envelope) }
    public func receive() async throws -> Envelope {
        do {
            return try await stream.receive()
        } catch SystemTransportError.endOfStream {
            // Never block the actor: `waitUntilExit` would stall every other call on this
            // transport (`close()` included) and a cooperative-pool thread with it. Poll briefly
            // for the exit status, then give up on the process rather than on the caller.
            var waited: Duration = .zero
            while process.isRunning, waited < .seconds(5) {
                try? await Task.sleep(for: .milliseconds(50))
                waited += .milliseconds(50)
            }
            if process.isRunning { process.terminate() }
            let errorData = process.isRunning ? nil : ((try? errorOutput.readToEnd()) ?? nil)
            throw Self.classifyFailure(kind: kind, exitCode: process.isRunning ? -1 : process.terminationStatus, errorData: errorData ?? Data())
        }
    }
    public func close() async { await stream.close(); if process.isRunning { process.terminate() } }

    /// Key-only, non-interactive connection through the system `ssh`. The user's own
    /// configuration, keys and agent apply; `identityFile` adds the device key on top.
    public static func ssh(profile: ConnectionProfile, bridgeCommand: String = "northpane-bridge", identityFile: URL? = nil, shell: HostShell? = nil) throws -> ProcessBridgeTransport {
        guard let endpoint = profile.endpoint, !endpoint.isEmpty else { throw SystemTransportError.missingEndpoint }
        return try ProcessBridgeTransport(
            kind: .ssh,
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: sshArguments(endpoint: endpoint, bridgeCommand: bridgeCommand, identityFile: identityFile, shell: shell ?? profile.hostShell ?? .posix)
        )
    }

    public static func sshArguments(endpoint: String, bridgeCommand: String = "northpane-bridge", identityFile: URL? = nil, shell: HostShell = .posix) -> [String] {
        var arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        // With the device key, use only that identity: otherwise `ssh` offers every key and agent
        // identity first and can exhaust the Host's MaxAuthTries before reaching it, especially
        // across the several connections an install makes in a row.
        if let identityFile { arguments += ["-o", "IdentitiesOnly=yes", "-i", identityFile.path] }
        return arguments + [endpoint, remoteBridgeCommand(bridgeCommand, shell: shell)]
    }

    /// Directories a non-interactive SSH shell omits but where the Bridge and Herdr actually
    /// live: the user-scoped install dir and the two common Homebrew prefixes. Prepending them
    /// lets the remote command find the Bridge, and lets the Bridge find `herdr` in turn.
    static let remoteSearchPath = RemoteBridgeLaunch.searchPath

    /// The remote command; see `RemoteBridgeLaunch`.
    public static func remoteBridgeCommand(_ bridgeCommand: String = "northpane-bridge", shell: HostShell = .posix) -> String {
        RemoteBridgeLaunch.command(bridgeCommand, shell: shell)
    }

    static func classifyFailure(kind: TransportKind, exitCode: Int32, errorData: Data) -> SystemTransportError {
        guard kind == .ssh else {
            return exitCode == 0 ? .endOfStream : .processFailed(exitCode: exitCode)
        }
        let detail = String(decoding: errorData.prefix(16_384), as: UTF8.self).lowercased()
        if detail.contains("permission denied") || detail.contains("authentication failed") {
            return .sshAuthenticationFailed
        }
        if detail.contains("host key verification failed") || detail.contains("remote host identification has changed") {
            return .sshHostVerificationFailed
        }
        // Reachability comes before every generic reading: a Host that cannot be reached from this
        // network is a route problem, and reporting it as an exit code sends the Operator looking
        // for a fault on the Host instead of at the network they are on.
        if let reachability = reachabilityFailure(in: detail) { return .sshUnreachable(reachability) }
        // 127 = command not found; 126 = found-but-not-executable, which on macOS `sh` also
        // covers `exec` of a missing path (the ~/.local/bin fallback). Both mean the Host has
        // no usable Bridge, and the remedy is the same: install it. Generic messages are only
        // trusted when they name the Bridge, so an unrelated failure keeps its real reason.
        // cmd.exe on a Windows Host cannot run the POSIX launch command and says so in the
        // system's own language *and* its own code page, which is not UTF-8 (measured on a real
        // Windows Host: the accented letter arrives as a replacement character). So the match is on
        // the plain-ASCII part of the message; 9009 is cmd's own "command not found". The Bridge may
        // be installed there perfectly well, so this asks for the Windows command, not for an install.
        // cmd.exe answers a POSIX command either with "not recognized" or, once the command carries a
        // path, with "cannot find the path specified" — in the Host's language and code page, so the
        // match is on plain-ASCII fragments only (both seen on a real Windows Host). 9009 is cmd's
        // own "command not found". The Bridge may be installed there perfectly well, so this asks
        // for the Windows command rather than for an install.
        if exitCode == 9009 || detail.contains("is not recognized as an internal")
            || detail.contains("riconosciuto come comando") || detail.contains("erkannt")
            || detail.contains("cannot find the path") || detail.contains("cannot find the file")
            || detail.contains("trovare il percorso") || detail.contains("trovare il file") {
            return .remoteShellMismatch(.windows)
        }
        if exitCode == 126 || exitCode == 127
            || detail.contains("command not found") || detail.contains("northpane-bridge: not found") {
            return .remoteBridgeUnavailable
        }
        return .processFailed(exitCode: exitCode)
    }

    /// Reads `ssh`'s own reason for never opening the connection. The strings are OpenSSH's,
    /// emitted before any remote command runs; anything else keeps its exit code.
    static func reachabilityFailure(in detail: String) -> SSHReachabilityFailure? {
        if detail.contains("could not resolve hostname") || detail.contains("name or service not known")
            || detail.contains("nodename nor servname") || detail.contains("no address associated with") {
            return .nameNotResolved
        }
        if detail.contains("network is unreachable") || detail.contains("network is down")
            || detail.contains("no route to host") || detail.contains("host is unreachable") || detail.contains("host is down") {
            return .hostUnreachable
        }
        if detail.contains("connection refused") { return .connectionRefused }
        if detail.contains("timed out") || detail.contains("connection timeout") { return .timedOut }
        return nil
    }
}

#endif

#if os(macOS)
public actor UnixSocketBridgeTransport: BridgeTransport {
    public nonisolated let kind: TransportKind = .localIPC
    private let stream: ByteStreamBridgeTransport

    public init(path: String) throws {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw SystemTransportError.invalidEndpoint }
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
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(length)) }
        }
        guard result == 0 else { Darwin.close(descriptor); throw SystemTransportError.ioFailure }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.stream = ByteStreamBridgeTransport(kind: .localIPC, input: handle, output: handle)
    }

    public func send(_ envelope: Envelope) async throws { try await stream.send(envelope) }
    public func receive() async throws -> Envelope { try await stream.receive() }
    public func close() async { await stream.close() }
}
#endif

public actor WebSocketBridgeTransport: BridgeTransport {
    public nonisolated let kind: TransportKind = .privateEndpoint
    private let task: URLSessionWebSocketTask
    private var isClosed = false

    public init(url: URL, session: URLSession = .shared) throws {
        guard url.scheme == "wss" else { throw SystemTransportError.invalidEndpoint }
        self.task = session.webSocketTask(with: url)
        self.task.resume()
    }

    public func send(_ envelope: Envelope) async throws {
        guard !isClosed else { throw Problem.closedTransport }
        try await task.send(.data(EnvelopeCodec.encodeBody(envelope)))
    }

    public func receive() async throws -> Envelope {
        guard !isClosed else { throw Problem.closedTransport }
        switch try await task.receive() {
        case let .data(data): return try EnvelopeCodec.decodeBody(data)
        case .string: throw Problem.malformedFrame
        @unknown default: throw Problem.malformedFrame
        }
    }

    public func close() { isClosed = true; task.cancel(with: .goingAway, reason: nil) }
}

public protocol BridgeTransportFactory: Sendable {
    func open(_ profile: ConnectionProfile) async throws -> any BridgeTransport
}

public struct SystemBridgeTransportFactory: BridgeTransportFactory {
    public init() {}
    public func open(_ profile: ConnectionProfile) async throws -> any BridgeTransport {
        switch profile.kind {
        case .localIPC:
            #if os(macOS)
            guard let path = profile.endpoint else { throw SystemTransportError.missingEndpoint }
            return try UnixSocketBridgeTransport(path: path)
            #else
            throw SystemTransportError.unsupportedPlatform
            #endif
        case .ssh:
            #if os(macOS)
            return try ProcessBridgeTransport.ssh(profile: profile)
            #else
            throw SystemTransportError.unsupportedPlatform
            #endif
        case .privateEndpoint:
            guard let endpoint = profile.endpoint, let url = URL(string: endpoint) else { throw SystemTransportError.missingEndpoint }
            return try WebSocketBridgeTransport(url: url)
        }
    }
}

public struct LoopbackBridgeTransportFactory: BridgeTransportFactory {
    public init() {}
    public func open(_ profile: ConnectionProfile) async throws -> any BridgeTransport { LoopbackTransport(kind: profile.kind) }
}
