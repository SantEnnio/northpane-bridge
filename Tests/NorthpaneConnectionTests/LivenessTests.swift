import Foundation
import NorthpaneProtocol
import Testing
@testable import NorthpaneConnection

/// A transport the test feeds one frame at a time, so `receive()` waits like a real one instead
/// of failing on an empty queue.
private actor ScriptedTransport: BridgeTransport {
    nonisolated let kind: TransportKind = .localIPC
    private var queued: [Envelope] = []
    private var waiter: CheckedContinuation<Envelope, Error>?
    private var closed = false

    func send(_ envelope: Envelope) async throws {
        guard !closed else { throw Problem.closedTransport }
    }

    func deliver(_ envelope: Envelope) {
        guard !closed else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: envelope)
        } else {
            queued.append(envelope)
        }
    }

    func receive() async throws -> Envelope {
        if !queued.isEmpty { return queued.removeFirst() }
        guard !closed else { throw Problem.closedTransport }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() {
        closed = true
        waiter?.resume(throwing: Problem.closedTransport)
        waiter = nil
    }
}

/// The regression: the app judged the connection by the heartbeat replies its own receive loop had
/// drained, so work in that loop (persisting the catalog, reloading resources) or a throttled timer
/// looked like a dead transport. Liveness belongs to the client, which stamps it where the frame is
/// read — for every frame, not only the heartbeat echo.
@Test func theClientStampsLivenessWhenAFrameArrivesNotWhenItIsDrained() async throws {
    let transport = ScriptedTransport()
    let client = NorthpaneBridgeClient(transport: transport)
    let connectionID = client.connectionID, channelID = client.controlChannelID

    // The app starts the receiver by asking for one frame; that first frame is consumed.
    await transport.deliver(.init(connectionID: connectionID, channelID: channelID, payload: .heartbeat(Heartbeat())))
    _ = try await client.receive()
    let afterDrainedFrame = await client.lastInboundFrameAt

    // Nothing consumes this one: the queue holds it, exactly as it would while the receive loop is
    // busy persisting a snapshot. It still proves the transport is alive.
    await transport.deliver(.init(connectionID: connectionID, channelID: channelID,
                                  payload: .terminalAcknowledgement(.init(attachmentID: UUID(), acceptedThroughSequence: 0))))
    var stamped = await client.lastInboundFrameAt
    for _ in 0..<200 where stamped == afterDrainedFrame {
        try await Task.sleep(for: .milliseconds(10))
        stamped = await client.lastInboundFrameAt
    }
    #expect(stamped > afterDrainedFrame)
    await client.close()
}
