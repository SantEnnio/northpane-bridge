import Foundation
import NorthpaneProtocol

public protocol BridgeTransport: Sendable {
    var kind: TransportKind { get }
    func send(_ envelope: Envelope) async throws
    func receive() async throws -> Envelope
    func close() async
}

/// A deterministic transport adapter used by conformance tests. Production adapters
/// bind their byte streams at this exact length-prefixed boundary.
public actor LoopbackTransport: BridgeTransport {
    public nonisolated let kind: TransportKind
    private var frames: [Data] = []
    private var isClosed = false
    public init(kind: TransportKind) { self.kind = kind }
    public func send(_ envelope: Envelope) throws {
        guard !isClosed else { throw Problem.closedTransport }
        frames.append(try FrameCodec.encode(envelope))
    }
    public func receive() throws -> Envelope {
        guard !isClosed else { throw Problem.closedTransport }
        guard !frames.isEmpty else { throw Problem.malformedFrame }
        return try FrameCodec.decode(frames.removeFirst())
    }
    public func close() { isClosed = true; frames.removeAll() }
}
