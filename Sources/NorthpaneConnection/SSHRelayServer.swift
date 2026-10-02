#if os(macOS)
@preconcurrency import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// What the relay asks of the app that hosts it. Called from the relay's own thread, so an
/// implementation keeps its answers behind a lock.
public protocol SSHRelayDirectory: Sendable {
    /// Whether this device key — an OpenSSH public key line — may use the relay.
    func isEnrolled(_ publicKey: String) -> Bool
    /// Enrolls the key when `token` is the enrollment token open now, and spends the token.
    func enroll(_ publicKey: String, token: String) -> Bool
    /// Whether the relay may connect to this Host's SSH port.
    func permits(host: String, port: Int) -> Bool
    /// What an enrolled device is told about the Hosts it can reach through the relay, in whatever
    /// form the app reads: the relay passes it on unread.
    func hostsDocument() -> Data
    /// The Bridge of this Mac, started for one session of the device with this key, or nil when the
    /// app offers none. Which Bridge that is and how it is started is the app's business; the relay
    /// joins the device's session to what it is handed and reads none of it.
    func bridge(for publicKey: String) -> SSHRelayBridge?
    /// What the device with this key says it is called — "iPhone 16 Pro" —, told whenever it
    /// opens a session and says so. It is the device's own word: one line to show beside the key,
    /// and nothing to decide anything by.
    func device(_ publicKey: String, calledItself name: String)
}

extension SSHRelayDirectory {
    /// A relay offers the Hosts behind it and not the Mac it runs on, unless the app says otherwise.
    public func bridge(for publicKey: String) -> SSHRelayBridge? { nil }
    public func device(_ publicKey: String, calledItself name: String) {}
}

/// The Bridge of the Mac the relay runs on, started for one session of a device's: the two ends of
/// its standard streams, which the relay takes over, and what is owed when the session is over.
public struct SSHRelayBridge: Sendable {
    /// Where what the Bridge writes is read from.
    let output: CInt
    /// Where what the device sends is written to.
    let input: CInt
    /// Called once the session is over, whichever side ended it.
    let ended: @Sendable () -> Void

    /// Starts `executableURL` as that Bridge — the app's own, with `serve --stdio` and the app's
    /// state, so that it is the Host the Mac already is — and hands its standard input and output
    /// to the relay. `ended` is called once, from the relay's thread, when the session is over; by
    /// then the process has been told to stop.
    public static func process(executableURL: URL, arguments: [String], environment: [String: String]? = nil,
                               ended: @escaping @Sendable () -> Void = {}) throws -> SSHRelayBridge {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        do { try process.run() } catch { throw SystemTransportError.launchFailed }
        // The relay closes the descriptors it is given, so it gets its own, which no other process
        // this one starts inherits; the pipes close theirs here.
        let read = fcntl(output.fileHandleForReading.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        let write = fcntl(input.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        try? output.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()
        guard read >= 0, write >= 0 else {
            if read >= 0 { close(read) }
            if write >= 0 { close(write) }
            process.terminate()
            throw SystemTransportError.launchFailed
        }
        return SSHRelayBridge(output: read, input: write) {
            if process.isRunning { process.terminate() }
            ended()
        }
    }

    /// Gives up a Bridge the relay could not join to its session.
    func abandon() {
        close(output)
        close(input)
        ended()
    }
}

/// The SSH server inside the Mac app that carries an enrolled device's own SSH session to a Host
/// the Mac can reach, and joins a device to the Bridge of the Mac itself when the app offers it. It
/// takes a device's key and nothing else, opens `direct-tcpip` channels to the Hosts the Operator
/// enabled and nothing else, and never runs a shell or a command of the device's on the Mac: all
/// it starts there is the Bridge the app hands it. A session it carries to a Host is the device's
/// with that Host, end to end: the relay sees where it goes and how much, not what. One with the
/// Mac's own Bridge ends on this Mac, and there the Bridge asks of the device what it asks over
/// SSH: to pair, and to prove its key in every session.
public final class SSHRelayServer: @unchecked Sendable {
    public let hostKeyFingerprint: String
    private let hostKey: NIOSSHPrivateKey
    private let directory: any SSHRelayDirectory
    private let lock = NSLock()
    private var listeners: [Channel] = []
    /// Every open connection, by the key that logged in on it, to close them when a device goes.
    private var connections: [ObjectIdentifier: (channel: Channel, authentication: RelayServerAuthentication)] = [:]

    public init(hostKey: P256.Signing.PrivateKey, directory: any SSHRelayDirectory) throws {
        let key = NIOSSHPrivateKey(p256Key: hostKey)
        guard let fingerprint = SSHKeyFingerprint.of(key.publicKey) else { throw SystemTransportError.invalidEndpoint }
        self.hostKey = key
        self.hostKeyFingerprint = fingerprint
        self.directory = directory
    }

    /// Whether an address is one the relay may listen on: loopback, the tailnet, or a private
    /// network. A relay on a public address would offer the Operator's Hosts to the Internet.
    public static func isPrivate(_ address: String) -> Bool {
        if address == "127.0.0.1" || address == "::1" { return true }
        let parts = address.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            switch (parts[0], parts[1]) {
            case (10, _), (192, 168): return true
            case (172, 16...31): return true
            case (100, 64...127): return true // the shared address space a tailnet uses
            default: return false
            }
        }
        let lowered = address.lowercased()
        return lowered.contains(":") && (lowered.hasPrefix("fd") || lowered.hasPrefix("fc"))
    }

    /// Listens on `address` and answers the port it bound (`port` 0 lets the system choose).
    public func start(address: String, port: Int = 0) async throws -> Int {
        try await start(addresses: [address], port: port)
    }

    /// Listens on each of `addresses` — the tailnet and the local network, say — on one port, and
    /// answers that port (`port` 0 lets the system choose it for the first address).
    public func start(addresses: [String], port: Int) async throws -> Int {
        guard !addresses.isEmpty, addresses.allSatisfy(Self.isPrivate) else { throw SystemTransportError.invalidEndpoint }
        var bound = port
        do {
            for address in addresses {
                let channel = try await listen(on: address, port: bound)
                lock.withLock { listeners.append(channel) }
                if bound == 0 { bound = channel.localAddress?.port ?? 0 }
            }
        } catch {
            await stop()
            throw error
        }
        return bound
    }

    private func listen(on address: String, port: Int) async throws -> Channel {
        let hostKey = self.hostKey, directory = self.directory
        return try await ServerBootstrap(group: SSHEventLoopGroup.shared)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                let authentication = RelayServerAuthentication(directory: directory)
                var configuration = SSHServerConfiguration(hostKeys: [hostKey], userAuthDelegate: authentication)
                configuration.maxAuthAttempts = 8
                self?.track(channel, authentication)
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers(
                        NIOSSHHandler(role: .server(configuration), allocator: channel.allocator,
                                      inboundChildChannelInitializer: { child, type in
                                          Self.forward(child, type: type, authentication: authentication, directory: directory)
                                      }),
                        SSHParentErrorHandler()
                    )
                }
            }
            .bind(host: address, port: port)
            .get()
    }

    public func stop() async {
        let (listeners, open) = lock.withLock { () -> ([Channel], [Channel]) in
            defer { self.listeners.removeAll(); connections.removeAll() }
            return (self.listeners, connections.values.map(\.channel))
        }
        for listener in listeners { try? await listener.close().get() }
        for channel in open { try? await channel.close().get() }
    }

    /// Closes every connection the device with this key has open: removing a device from the
    /// relay ends what it is doing through it, not only what it will do.
    public func disconnect(device publicKey: String) async {
        let doomed = lock.withLock { connections.values.filter { $0.authentication.authenticatedKey == publicKey }.map(\.channel) }
        for channel in doomed { try? await channel.close().get() }
    }

    private func track(_ channel: Channel, _ authentication: RelayServerAuthentication) {
        let id = ObjectIdentifier(channel)
        lock.withLock { connections[id] = (channel, authentication) }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.lock.withLock { _ = self?.connections.removeValue(forKey: id) }
        }
    }

    /// A channel the device opened: a `direct-tcpip` one to a Host the Operator enabled is joined
    /// to a new connection to that Host; a session may ask for the list of those Hosts or for the
    /// Bridge of this Mac, and for nothing else; anything else is refused.
    private static func forward(_ child: Channel, type: SSHChannelType, authentication: RelayServerAuthentication,
                                directory: any SSHRelayDirectory) -> EventLoopFuture<Void> {
        if type == .session, let device = authentication.authenticatedKey {
            return child.pipeline.addHandler(RelaySession(device: device, directory: directory))
        }
        guard case let .directTCPIP(request) = type, authentication.authenticatedKey != nil,
              directory.permits(host: request.targetHost, port: request.targetPort) else {
            return child.eventLoop.makeFailedFuture(SSHRelayError.targetRefused)
        }
        let (device, host) = RelayJoint.pair()
        let hostSide = NIOLoopBound(host, eventLoop: child.eventLoop)
        return child.eventLoop.makeCompletedFuture {
            try child.pipeline.syncOperations.addHandlers(SSHChannelByteStream(), device)
        }.flatMap {
            ClientBootstrap(group: child.eventLoop)
                .channelInitializer { target in
                    target.eventLoop.makeCompletedFuture { try target.pipeline.syncOperations.addHandler(hostSide.value) }
                }
                .connect(host: request.targetHost, port: request.targetPort)
                .map { _ in () }
        }
    }
}

/// The two things a session on the relay may do, each with one command: read the Hosts the relay
/// reaches (`SSHRelayRoute.hostsCommand`), or be joined to the Bridge of this Mac
/// (`SSHRelayRoute.bridgeCommand`) when the app offers it. No shell runs either, and neither takes
/// arguments. A shell, any other command or a subsystem closes the session. Before its command
/// the device may say what it is called (`SSHRelayRoute.deviceNameVariable`); no other variable
/// is read, and none is set anywhere.
final class RelaySession: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private enum Stage {
        /// No command yet.
        case waiting
        /// The Bridge is being joined to the session, and the device has not been told it is there.
        case joining
        /// The session's bytes are the Bridge's.
        case joined
        /// The command is done with: the session only has to close.
        case over
    }

    private let device: String
    private let directory: any SSHRelayDirectory
    private var stage = Stage.waiting

    init(device: String, directory: any SSHRelayDirectory) {
        self.device = device
        self.directory = directory
    }

    /// What the app is told of the name a device gives itself: one line of at most 64 code points
    /// that show. Line breaks and tabs become spaces, and what does not show — controls, the marks
    /// that turn the direction of the text around — is dropped, so that the name cannot make the
    /// line it is shown in say something else. Nil when nothing is left.
    private static func shownName(_ declared: String) -> String? {
        var line = String.UnicodeScalarView()
        for scalar in declared.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { line.append(" ") }
            else if !CharacterSet.controlCharacters.contains(scalar) { line.append(scalar) }
        }
        let whole = String(line).trimmingCharacters(in: .whitespaces)
        let name = String(whole.unicodeScalars.prefix(64)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let variable as SSHChannelRequestEvent.EnvironmentRequest where stage == .waiting && variable.name == SSHRelayRoute.deviceNameVariable:
            if let name = Self.shownName(variable.value) { directory.device(device, calledItself: name) }
        case let exec as SSHChannelRequestEvent.ExecRequest where stage == .waiting && exec.command == SSHRelayRoute.hostsCommand:
            stage = .over
            var buffer = context.channel.allocator.buffer(capacity: 0)
            buffer.writeBytes(directory.hostsDocument())
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.init(type: .channel, data: .byteBuffer(buffer)))).whenComplete { _ in
                channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0)).whenComplete { _ in
                    channel.close(promise: nil)
                }
            }
        case let exec as SSHChannelRequestEvent.ExecRequest where stage == .waiting && exec.command == SSHRelayRoute.bridgeCommand:
            join(context: context, wantReply: exec.wantReply)
        case is SSHChannelRequestEvent.ExecRequest, is SSHChannelRequestEvent.ShellRequest, is SSHChannelRequestEvent.SubsystemRequest:
            stage = .over
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch stage {
        case .joined:
            context.fireChannelRead(data)
        case .joining:
            // The device spoke before it was told the Bridge was there: nothing carries those bytes,
            // and a session that lost some cannot go on.
            stage = .over
            context.close(promise: nil)
        case .waiting, .over:
            break
        }
    }

    /// Joins the session to the Bridge the app starts for this device, and only then tells the
    /// device to go on, so that not a byte of its is sent before there is a Bridge to read it.
    private func join(context: ChannelHandlerContext, wantReply: Bool) {
        let channel = context.channel
        // Asked again here, and not only at the login: a device the Operator has just removed may
        // hold its connection a moment longer, and gets no Bridge on it.
        guard directory.isEnrolled(device), let bridge = directory.bridge(for: device) else {
            stage = .over
            Self.refuse(channel, wantReply: wantReply)
            return
        }
        stage = .joining
        let (deviceSide, bridgeSide) = RelayJoint.pair()
        let bridgeEnd = NIOLoopBound(bridgeSide, eventLoop: context.eventLoop)
        let session = NIOLoopBound(self, eventLoop: context.eventLoop)
        do {
            try context.pipeline.syncOperations.addHandlers(SSHChannelByteStream(), deviceSide)
        } catch {
            stage = .over
            bridge.abandon()
            Self.refuse(channel, wantReply: wantReply)
            return
        }
        NIOPipeBootstrap(group: context.eventLoop)
            .channelInitializer { pipes in
                pipes.eventLoop.makeCompletedFuture { try pipes.pipeline.syncOperations.addHandler(bridgeEnd.value) }
            }
            .takingOwnershipOfDescriptors(input: bridge.output, output: bridge.input)
            .whenComplete { result in
                let session = session.value
                switch result {
                case let .success(pipes):
                    pipes.closeFuture.whenComplete { _ in bridge.ended() }
                    // The device may have gone, or its session been closed, while the Bridge was
                    // starting: nothing else would close the Bridge's side then.
                    guard session.stage == .joining, channel.isActive else {
                        pipes.close(promise: nil)
                        return
                    }
                    session.stage = .joined
                    if wantReply { channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
                case .failure:
                    session.stage = .over
                    bridge.abandon()
                    Self.refuse(channel, wantReply: wantReply)
                }
            }
    }

    private static func refuse(_ channel: Channel, wantReply: Bool) {
        guard wantReply else {
            channel.close(promise: nil)
            return
        }
        channel.triggerUserOutboundEvent(ChannelFailureEvent()).whenComplete { _ in channel.close(promise: nil) }
    }
}

/// Who may log in: a device whose key the relay knows, or one that brings the enrollment token as
/// well, once. NIOSSH asks only after it has checked the key's signature, so a key named here is a
/// key its sender holds.
final class RelayServerAuthentication: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.publicKey, .password]
    private let directory: any SSHRelayDirectory
    private let lock = NSLock()
    private var pendingKey: String?
    private var key: String?

    init(directory: any SSHRelayDirectory) { self.directory = directory }

    var authenticatedKey: String? { lock.withLock { key } }

    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        guard request.username == SSHRelayRoute.username else {
            responsePromise.succeed(.failure)
            return
        }
        switch request.request {
        case let .publicKey(offer):
            let text = String(openSSHPublicKey: offer.publicKey)
            if directory.isEnrolled(text) {
                lock.withLock { key = text }
                responsePromise.succeed(.success)
            } else {
                // A key the relay does not know may still enroll, with the token, on this connection.
                lock.withLock { pendingKey = text }
                responsePromise.succeed(.partialSuccess(remainingMethods: .password))
            }
        case let .password(offer):
            guard let pending = lock.withLock({ pendingKey }), directory.enroll(pending, token: offer.password) else {
                responsePromise.succeed(.failure)
                return
            }
            lock.withLock { key = pending }
            responsePromise.succeed(.success)
        default:
            responsePromise.succeed(.failure)
        }
    }
}

/// Two channels joined end to end on one event loop: what one reads the other writes, a close on
/// either closes both, and a side stops reading while the other cannot take more.
final class RelayJoint: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: RelayJoint?
    private var context: ChannelHandlerContext?
    private var readWaiting = false

    static func pair() -> (RelayJoint, RelayJoint) {
        let first = RelayJoint(), second = RelayJoint()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.context?.write(data, promise: nil) }

    func channelReadComplete(context: ChannelHandlerContext) { partner?.context?.flush() }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.context?.close(promise: nil)
        context.fireChannelInactive()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable, let partner, partner.readWaiting {
            partner.readWaiting = false
            partner.context?.read()
        }
        context.fireChannelWritabilityChanged()
    }

    func read(context: ChannelHandlerContext) {
        if partner?.context?.channel.isWritable ?? false { context.read() } else { readWaiting = true }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
#endif
