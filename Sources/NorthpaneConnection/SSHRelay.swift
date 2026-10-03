#if os(iOS) || os(macOS)
@preconcurrency import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import NorthpaneProtocol

/// How a device reaches a Host through a Mac of the Operator's that relays it, or the Bridge of
/// that Mac itself: the relay's address, the fingerprint of its SSH host key, and the enrollment
/// token the device presents once, the first time. The relay carries the device's own SSH session
/// to a Host and sees none of it.
public struct SSHRelayRoute: Equatable, Sendable {
    /// The name every device logs in to the relay with; who it is, is its key.
    public static let username = "northpane-relay"
    /// The command a relay answers with the Hosts the device can reach through it.
    public static let hostsCommand = "northpane-relay-hosts"
    /// The command that joins a session to the Bridge of the Mac the relay runs on. With
    /// `hostsCommand`, all a relay takes: neither is run by a shell, and neither has arguments.
    public static let bridgeCommand = "northpane-bridge"
    /// The variable a device sets on a session to say what it is called. The Mac shows the name
    /// beside the device's key; it is the device's word, and nothing is decided by it.
    public static let deviceNameVariable = "NORTHPANE_DEVICE_NAME"
    public let host: String
    public let port: Int
    public let hostKeyFingerprint: String
    public let enrollmentToken: String?
    /// The Host behind the Mac this route leads to, when it leads to one: the device names it to
    /// the relay by this ID, and the Mac dials it where it reaches it now. Nil on a route to the
    /// Mac's own Bridge, or to the relay's list of Hosts.
    public let hostID: HostID?

    public init(host: String, port: Int, hostKeyFingerprint: String, enrollmentToken: String? = nil, hostID: HostID? = nil) {
        self.host = host; self.port = port; self.hostKeyFingerprint = hostKeyFingerprint; self.enrollmentToken = enrollmentToken
        self.hostID = hostID
    }

    /// The relay of a saved route, at one of its addresses; with `hostID`, to that Host behind it.
    public init(_ profile: RelayProfile, address: String, enrollmentToken: String? = nil, hostID: HostID? = nil) {
        self.init(host: address, port: profile.port, hostKeyFingerprint: profile.hostKeyFingerprint, enrollmentToken: enrollmentToken, hostID: hostID)
    }

    /// What a `direct-tcpip` channel names as its target: the Host's ID in place of an address, and
    /// port 0, the port being the Mac's to know along with the address. The Mac resolves the ID to
    /// where it reaches that Host now, so a Host that has moved is still reached, and only a Host
    /// the Operator enabled is: a device dials no address of a Host behind the Mac, and the relay
    /// opens no address a device names.
    public static func target(for host: HostID) -> String { host.rawValue.uuidString }

    /// The Host a `direct-tcpip` target names, or nil for anything that is not a Host's ID.
    public static func host(named target: String) -> HostID? { UUID(uuidString: target).map(HostID.init(rawValue:)) }
}

public enum SSHRelayError: Error, Equatable, Sendable {
    /// The relay does not know this device, and no valid enrollment token came with it.
    case deviceNotEnrolled
    /// The relay will not open a connection to that Host, or the Bridge of its own Mac.
    case targetRefused
    /// The relay is not answering on the address it was given, or not with the key it showed.
    case relayUnreachable
}

/// The bytes of an SSH channel as plain buffers, both ways: the relay joins a `direct-tcpip` channel
/// to a TCP connection, and a device runs its own SSH session inside one.
final class SSHChannelByteStream: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard data.type == .channel, case let .byteBuffer(buffer) = data.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(.init(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}

/// A device logging in to the relay: its key first, and, when the relay does not know the key yet,
/// the enrollment token it was given for this once.
final class RelayClientAuthentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private enum Offer { case key, token(String) }
    private let privateKey: NIOSSHPrivateKey
    private let enrollmentToken: String?
    private let lock = NSLock()
    private var offeredKey = false
    private var offeredToken = false
    private var rejected = false

    init(privateKey: NIOSSHPrivateKey, enrollmentToken: String?) {
        self.privateKey = privateKey
        self.enrollmentToken = enrollmentToken
    }

    var wasRejected: Bool { lock.withLock { rejected } }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let offer = lock.withLock { () -> Offer? in
            if !offeredKey {
                offeredKey = true
                if availableMethods.contains(.publicKey) { return .key }
            }
            if !offeredToken, let enrollmentToken, availableMethods.contains(.password) {
                offeredToken = true
                return .token(enrollmentToken)
            }
            rejected = true
            return nil
        }
        switch offer {
        case .key:
            nextChallengePromise.succeed(.init(username: SSHRelayRoute.username, serviceName: "ssh-connection",
                                               offer: .privateKey(.init(privateKey: privateKey))))
        case let .token(token):
            nextChallengePromise.succeed(.init(username: SSHRelayRoute.username, serviceName: "ssh-connection",
                                               offer: .password(.init(password: token))))
        case nil:
            nextChallengePromise.fail(SSHRelayError.deviceNotEnrolled)
        }
    }
}

/// Says what the device is called on a session with the relay, before the session's command.
final class RelayDeviceName: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    private let name: String

    init(_ name: String) { self.name = name }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: SSHRelayRoute.deviceNameVariable, value: name),
                                         promise: nil)
        context.fireChannelActive()
    }
}

/// The connection that carries the Host's SSH: a TCP connection of its own or, through a relay, a
/// channel of the relay's with the device's own SSH session inside it. Every SSH operation a device
/// makes on a Host opens it here, so that none of them tries a road the device may not have.
struct HostSSHConnection: Sendable {
    /// The channel the Host's `NIOSSHHandler` sits on.
    let parent: Channel
    /// The SSH connection to the relay, when there is one.
    let relay: Channel?

    func close() async {
        try? await parent.close().get()
        try? await relay?.close().get()
    }

    /// Dials `host` and `port` itself or, with `relay`, asks the relay for a channel to the Host
    /// `relay.hostID` names, which the Mac dials where it reaches it: `host` and `port` are then
    /// the device's record of the Host, and nothing the device dials.
    static func open(
        host: String, port: Int, relay: SSHRelayRoute?, relayKey: P256.Signing.PrivateKey?,
        userAuthentication: any NIOSSHClientUserAuthenticationDelegate & Sendable, hostKeys: PinnedHostKeyDelegate
    ) async throws -> HostSSHConnection {
        if let relay {
            guard let relayKey else { throw SSHRelayError.deviceNotEnrolled }
            // A route through a Mac leads to a Host behind it or it leads nowhere.
            guard let hostID = relay.hostID else { throw SystemTransportError.invalidEndpoint }
            let opened = try await SSHRelayClient.open(relay, deviceKey: relayKey, to: hostID) { channel in
                try channel.pipeline.syncOperations.addHandlers(
                    SSHChannelByteStream(),
                    NIOSSHHandler(role: .client(.init(userAuthDelegate: userAuthentication, serverAuthDelegate: hostKeys)),
                                  allocator: channel.allocator, inboundChildChannelInitializer: nil),
                    SSHParentErrorHandler()
                )
            }
            return HostSSHConnection(parent: opened.forward, relay: opened.relay)
        }
        let parent = try await NativeSSHReachability.named {
            try await ClientBootstrap(group: SSHEventLoopGroup.shared)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers(
                            NIOSSHHandler(role: .client(.init(userAuthDelegate: userAuthentication, serverAuthDelegate: hostKeys)),
                                          allocator: channel.allocator, inboundChildChannelInitializer: nil),
                            SSHParentErrorHandler()
                        )
                    }
                }
                .connect(host: host, port: port)
                .get()
        }
        return HostSSHConnection(parent: parent, relay: nil)
    }
}

public enum SSHRelayEnrollment {
    /// Logs in to the relay with the device's key — and the enrollment token, the first time, which
    /// enrolls the device — and reads the Hosts the relay reaches for it. Nothing else is opened.
    /// With `deviceName`, the relay is told what the device is called, for the Mac to show.
    public static func hosts(_ route: SSHRelayRoute, credential: NativeSSHCredential, deviceName: String? = nil) async throws -> Data {
        let key = try P256.Signing.PrivateKey(rawRepresentation: credential.rawPrivateKey)
        let login = try await SSHRelayLogin.open(route, deviceKey: key)
        let relay = login.channel
        let inbound = SSHInboundBuffer()
        do {
            let child = try await relay.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                let promise = relay.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(promise) { channel, _ in
                    channel.eventLoop.makeCompletedFuture {
                        if let deviceName { try channel.pipeline.syncOperations.addHandler(RelayDeviceName(deviceName)) }
                        try channel.pipeline.syncOperations.addHandler(NativeSSHRawHandler(request: .exec(SSHRelayRoute.hostsCommand), inbound: inbound))
                    }
                }
                return promise.futureResult
            }.get()
            // The relay answers and closes at once: read to the end, closing nothing first, or a
            // half-close could land on a channel already gone.
            var document = Data()
            while let chunk = try await inbound.next() {
                document.append(chunk)
                guard document.count <= 1_048_576 else { throw SSHRelayError.relayUnreachable }
            }
            _ = child
            try? await relay.close().get()
            return document
        } catch {
            try? await relay.close().get()
            // What took the connection and showed no key is not the relay: the next address may be.
            throw login.refusal ?? (login.relayFingerprint == nil ? SSHRelayError.relayUnreachable : error)
        }
    }
}

/// A device's connection to the relay, logged in with its key and holding the relay to its pinned
/// one: a device never takes a relay on first sight.
struct SSHRelayLogin: Sendable {
    let channel: Channel
    private let authentication: RelayClientAuthentication
    private let relayKeys: PinnedHostKeyDelegate

    /// The key the relay showed, once it has shown one.
    var relayFingerprint: String? { relayKeys.observedFingerprint }

    /// What the relay itself refused, when what failed on this connection was the login: it showed
    /// a key other than the pinned one, or it does not know the device.
    var refusal: Error? {
        if let mismatch = relayKeys.mismatch { return mismatch }
        if authentication.wasRejected { return SSHRelayError.deviceNotEnrolled }
        return nil
    }

    /// Why a channel the device asked the relay for did not open: the login was refused, the relay
    /// went silent before it showed a key, or it will not open what it was asked for.
    var channelFailure: Error {
        refusal ?? (relayFingerprint == nil ? SSHRelayError.relayUnreachable : SSHRelayError.targetRefused)
    }

    /// Connects to the relay. The login itself happens as the first channel opens, so a refusal
    /// shows there, and `refusal` then says which it was.
    static func open(_ route: SSHRelayRoute, deviceKey: P256.Signing.PrivateKey) async throws -> SSHRelayLogin {
        let authentication = RelayClientAuthentication(privateKey: NIOSSHPrivateKey(p256Key: deviceKey), enrollmentToken: route.enrollmentToken)
        let relayKeys = PinnedHostKeyDelegate(expectedFingerprint: route.hostKeyFingerprint)
        do {
            let channel = try await NativeSSHReachability.named {
                // A relay is on the tailnet or on the local network, where an address answers at
                // once or not at all: a short wait, so that the next address is tried soon.
                try await ClientBootstrap(group: SSHEventLoopGroup.shared)
                    .connectTimeout(.seconds(5))
                    .channelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandlers(
                                NIOSSHHandler(role: .client(.init(userAuthDelegate: authentication, serverAuthDelegate: relayKeys)),
                                              allocator: channel.allocator, inboundChildChannelInitializer: nil),
                                SSHParentErrorHandler()
                            )
                        }
                    }
                    .connect(host: route.host, port: route.port)
                    .get()
            }
            return SSHRelayLogin(channel: channel, authentication: authentication, relayKeys: relayKeys)
        } catch is SystemTransportError {
            throw SSHRelayError.relayUnreachable
        }
    }
}

enum SSHRelayClient {
    struct Opened {
        /// The SSH connection to the relay.
        let relay: Channel
        /// The `direct-tcpip` channel to the Host, carrying whatever `configure` put on it.
        let forward: Channel
    }

    /// Logs in to the relay with the device's key, with its pinned host key, and opens a channel to
    /// the SSH port of the Host `host` names, where the Mac reaches it now; `configure` sets up
    /// that channel's pipeline — the device's own SSH session with the Host. The relay's key is
    /// always pinned: a device never takes a relay on first sight.
    static func open(
        _ route: SSHRelayRoute, deviceKey: P256.Signing.PrivateKey, to host: HostID,
        configure: @escaping @Sendable (Channel) throws -> Void
    ) async throws -> Opened {
        let login = try await SSHRelayLogin.open(route, deviceKey: deviceKey)
        let relay = login.channel
        do {
            let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            let target = SSHChannelType.DirectTCPIP(targetHost: SSHRelayRoute.target(for: host), targetPort: 0, originatorAddress: originator)
            let forward = try await relay.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                let promise = relay.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(promise, channelType: .directTCPIP(target)) { channel, _ in
                    channel.eventLoop.makeCompletedFuture { try configure(channel) }
                }
                return promise.futureResult
            }.get()
            return Opened(relay: relay, forward: forward)
        } catch {
            try? await relay.close().get()
            throw login.channelFailure
        }
    }
}
#endif
