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
}

/// The SSH server inside the Mac app that carries an enrolled device's own SSH session to a Host
/// the Mac can reach. It takes a device's key and nothing else, opens `direct-tcpip` channels to the
/// Hosts the Operator enabled and nothing else, and never runs a shell or a command on the Mac. The
/// session it carries is the device's with the Host, end to end: the relay sees where it goes and
/// how much, not what.
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
    /// to a new connection to that Host; a session may ask for the list of those Hosts and for
    /// nothing else; anything else is refused.
    private static func forward(_ child: Channel, type: SSHChannelType, authentication: RelayServerAuthentication,
                                directory: any SSHRelayDirectory) -> EventLoopFuture<Void> {
        if type == .session, authentication.authenticatedKey != nil {
            return child.pipeline.addHandler(RelayHostsSession(directory: directory))
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

/// The one thing a session on the relay may do: read the Hosts it reaches, with the command
/// `SSHRelayRoute.hostsCommand`. A shell, any other command or a subsystem closes the session.
final class RelayHostsSession: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    private let directory: any SSHRelayDirectory

    init(directory: any SSHRelayDirectory) { self.directory = directory }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let exec as SSHChannelRequestEvent.ExecRequest where exec.command == SSHRelayRoute.hostsCommand:
            var buffer = context.channel.allocator.buffer(capacity: 0)
            buffer.writeBytes(directory.hostsDocument())
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.init(type: .channel, data: .byteBuffer(buffer)))).whenComplete { _ in
                channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0)).whenComplete { _ in
                    channel.close(promise: nil)
                }
            }
        case is SSHChannelRequestEvent.ExecRequest, is SSHChannelRequestEvent.ShellRequest, is SSHChannelRequestEvent.SubsystemRequest:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
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
