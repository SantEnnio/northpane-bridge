@preconcurrency import Crypto
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import NorthpaneConnection
import NorthpaneProtocol

final class PrivateWebSocketServer: Sendable {
    private enum UpgradeResult: Sendable {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
    }

    let certificateFingerprint: String
    private let host: String
    private let port: Int
    private let sslContext: NIOSSLContext
    private let connectionHandler: @Sendable (PrivateWebSocketBridgeTransport) async -> Void

    init(
        host: String,
        port: Int,
        certificatePath: String,
        privateKeyPath: String,
        connectionHandler: @escaping @Sendable (PrivateWebSocketBridgeTransport) async -> Void
    ) throws {
        let certificates = try NIOSSLCertificate.fromPEMFile(certificatePath)
        guard let leaf = certificates.first else { throw SystemTransportError.invalidEndpoint }
        let key = try NIOSSLPrivateKey(file: privateKeyPath, format: .pem)
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        tls.minimumTLSVersion = .tlsv12
        self.sslContext = try NIOSSLContext(configuration: tls)
        self.host = host
        self.port = port
        self.connectionHandler = connectionHandler
        self.certificateFingerprint = "SHA256:" + Data(SHA256.hash(data: Data(try leaf.toDERBytes())))
            .base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    func run() async throws {
        let server: NIOAsyncChannel<EventLoopFuture<UpgradeResult>, Never> = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) { [sslContext] channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                    let upgrader = NIOTypedWebSocketServerUpgrader<UpgradeResult>(
                        maxFrameSize: Int(BridgeProtocol.maximumFrameBytes),
                        enableAutomaticErrorHandling: true,
                        shouldUpgrade: { channel, head in
                            guard head.method == .GET, head.uri == "/" || head.uri == "/bridge" else {
                                return channel.eventLoop.makeSucceededFuture(nil)
                            }
                            return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                        },
                        upgradePipelineHandler: { channel, _ in
                            channel.eventLoop.makeCompletedFuture {
                                .websocket(try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel))
                            }
                        }
                    )
                    let upgrade = NIOTypedHTTPServerUpgradeConfiguration(
                        upgraders: [upgrader],
                        notUpgradingCompletionHandler: { channel in
                            channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandler(HTTPResponsePartAdapter())
                                return .http(try NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>(wrappingChannelSynchronously: channel))
                            }
                        }
                    )
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                        configuration: .init(upgradeConfiguration: upgrade)
                    )
                }
            }

        try await withThrowingDiscardingTaskGroup { group in
            try await server.executeThenClose { inbound in
                for try await result in inbound {
                    group.addTask { [connectionHandler] in
                        do {
                            switch try await result.get() {
                            case let .websocket(channel):
                                try await Self.handleWebSocket(channel, connectionHandler: connectionHandler)
                            case let .http(channel):
                                try await Self.rejectHTTP(channel)
                            }
                        } catch {
                            // A malformed or closed client is isolated to its own connection.
                        }
                    }
                }
            }
        }
    }

    private static func handleWebSocket(
        _ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        connectionHandler: @escaping @Sendable (PrivateWebSocketBridgeTransport) async -> Void
    ) async throws {
        try await channel.executeThenClose { inbound, outbound in
            let transport = PrivateWebSocketBridgeTransport(writer: outbound, allocator: channel.channel.allocator)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        var fragmented = Data()
                        var receivingBinary = false
                        for try await frame in inbound {
                            switch frame.opcode {
                            case .ping:
                                try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData))
                            case .binary:
                                guard !receivingBinary else { throw Problem.malformedFrame }
                                fragmented = Data(frame.unmaskedData.readableBytesView)
                                guard fragmented.count <= Int(BridgeProtocol.maximumFrameBytes) else { throw Problem.oversizedFrame }
                                if frame.fin {
                                    transport.push(try EnvelopeCodec.decodeBody(fragmented))
                                    fragmented.removeAll(keepingCapacity: true)
                                } else {
                                    receivingBinary = true
                                }
                            case .continuation:
                                guard receivingBinary else { throw Problem.malformedFrame }
                                fragmented.append(contentsOf: frame.unmaskedData.readableBytesView)
                                guard fragmented.count <= Int(BridgeProtocol.maximumFrameBytes) else { throw Problem.oversizedFrame }
                                if frame.fin {
                                    receivingBinary = false
                                    transport.push(try EnvelopeCodec.decodeBody(fragmented))
                                    fragmented.removeAll(keepingCapacity: true)
                                }
                            case .connectionClose:
                                transport.finish()
                                return
                            case .pong:
                                break
                            default:
                                throw Problem.malformedFrame
                            }
                        }
                        transport.finish()
                    } catch {
                        transport.finish(error: error)
                    }
                }
                group.addTask {
                    await connectionHandler(transport)
                    await transport.close()
                }
                await group.next()
                group.cancelAll()
                transport.finish()
            }
        }
    }

    private static func rejectHTTP(
        _ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        try await channel.executeThenClose { inbound, outbound in
            for try await part in inbound {
                guard case .head = part else { continue }
                var headers = HTTPHeaders()
                headers.add(name: "Connection", value: "close")
                headers.add(name: "Content-Length", value: "0")
                try await outbound.write(contentsOf: [
                    .head(HTTPResponseHead(version: .http1_1, status: .upgradeRequired, headers: headers)),
                    .end(nil),
                ])
                return
            }
        }
    }
}

actor PrivateWebSocketBridgeTransport: BridgeTransport {
    nonisolated let kind: TransportKind = .privateEndpoint
    private let writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    private let allocator: ByteBufferAllocator
    private let inbound = EnvelopeInboundBuffer()
    private var closed = false

    init(writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>, allocator: ByteBufferAllocator) {
        self.writer = writer
        self.allocator = allocator
    }

    nonisolated func push(_ envelope: Envelope) { inbound.push(envelope) }
    nonisolated func finish(error: Error? = nil) { inbound.finish(error: error) }

    func send(_ envelope: Envelope) async throws {
        guard !closed else { throw Problem.closedTransport }
        var data = allocator.buffer(capacity: 512)
        data.writeBytes(try EnvelopeCodec.encodeBody(envelope))
        try await writer.write(WebSocketFrame(fin: true, opcode: .binary, data: data))
    }

    func receive() async throws -> Envelope {
        guard !closed else { throw Problem.closedTransport }
        guard let envelope = try await inbound.next() else { throw SystemTransportError.endOfStream }
        return envelope
    }

    func close() {
        guard !closed else { return }
        closed = true
        inbound.finish()
        writer.finish()
    }
}

private final class EnvelopeInboundBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Envelope] = []
    private var waiters: [CheckedContinuation<Envelope?, Error>] = []
    private var terminal: Result<Void, Error>?

    func push(_ envelope: Envelope) {
        let waiter = lock.withLock { () -> CheckedContinuation<Envelope?, Error>? in
            guard terminal == nil else { return nil }
            if waiters.isEmpty { queued.append(envelope); return nil }
            return waiters.removeFirst()
        }
        waiter?.resume(returning: envelope)
    }

    func finish(error: Error? = nil) {
        let pending = lock.withLock { () -> [CheckedContinuation<Envelope?, Error>] in
            guard terminal == nil else { return [] }
            terminal = error.map(Result.failure) ?? .success(())
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) }
        }
    }

    func next() async throws -> Envelope? {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> Result<Envelope?, Error>? in
                if !queued.isEmpty { return .success(queued.removeFirst()) }
                if let terminal {
                    switch terminal {
                    case .success: return .success(nil)
                    case let .failure(error): return .failure(error)
                    }
                }
                waiters.append(continuation)
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }
}

private final class HTTPResponsePartAdapter: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch unwrapOutboundIn(data) {
        case let .head(head): context.write(wrapOutboundOut(.head(head)), promise: promise)
        case let .body(body): context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: promise)
        case let .end(trailers): context.write(wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}
