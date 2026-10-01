#if os(iOS) || os(macOS)
@preconcurrency import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// How a device reaches a Host through a Mac of the Operator's that relays it: the relay's address,
/// the fingerprint of its SSH host key, and the enrollment token the device presents once, the first
/// time. The relay carries the device's own SSH session to the Host and sees none of it.
public struct SSHRelayRoute: Equatable, Sendable {
    /// The name every device logs in to the relay with; who it is, is its key.
    public static let username = "northpane-relay"
    public let host: String
    public let port: Int
    public let hostKeyFingerprint: String
    public let enrollmentToken: String?

    public init(host: String, port: Int, hostKeyFingerprint: String, enrollmentToken: String? = nil) {
        self.host = host; self.port = port; self.hostKeyFingerprint = hostKeyFingerprint; self.enrollmentToken = enrollmentToken
    }
}

public enum SSHRelayError: Error, Equatable, Sendable {
    /// The relay does not know this device, and no valid enrollment token came with it.
    case deviceNotEnrolled
    /// The relay will not open a connection to that Host.
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

enum SSHRelayClient {
    struct Opened {
        /// The SSH connection to the relay.
        let relay: Channel
        /// The `direct-tcpip` channel to the Host, carrying whatever `configure` put on it.
        let forward: Channel
    }

    /// Logs in to the relay with the device's key, with its pinned host key, and opens a channel to
    /// the Host's SSH port; `configure` sets up that channel's pipeline — the device's own SSH
    /// session with the Host. The relay's key is always pinned: a device never takes a relay on
    /// first sight.
    static func open(
        _ route: SSHRelayRoute, deviceKey: P256.Signing.PrivateKey, targetHost: String, targetPort: Int,
        configure: @escaping @Sendable (Channel) throws -> Void
    ) async throws -> Opened {
        let authentication = RelayClientAuthentication(privateKey: NIOSSHPrivateKey(p256Key: deviceKey), enrollmentToken: route.enrollmentToken)
        let relayKeys = PinnedHostKeyDelegate(expectedFingerprint: route.hostKeyFingerprint)
        let relay: Channel
        do {
            relay = try await NativeSSHReachability.named {
                try await ClientBootstrap(group: SSHEventLoopGroup.shared)
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
        } catch is SystemTransportError {
            throw SSHRelayError.relayUnreachable
        }
        do {
            let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            let forward = try await relay.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                let promise = relay.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(promise, channelType: .directTCPIP(.init(targetHost: targetHost, targetPort: targetPort, originatorAddress: originator))) { channel, _ in
                    channel.eventLoop.makeCompletedFuture { try configure(channel) }
                }
                return promise.futureResult
            }.get()
            return Opened(relay: relay, forward: forward)
        } catch {
            try? await relay.close().get()
            if let mismatch = relayKeys.mismatch { throw mismatch }
            if authentication.wasRejected { throw SSHRelayError.deviceNotEnrolled }
            if relayKeys.observedFingerprint == nil { throw SSHRelayError.relayUnreachable }
            throw SSHRelayError.targetRefused
        }
    }
}
#endif
