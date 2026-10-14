import Foundation
import Testing
@testable import NorthpaneBridge

private actor SlowTerminalTransport {
    var received: [Data] = []
    var continuation: CheckedContinuation<Void, Never>?
    var blocked = false
    func send(_ data: Data) async {
        received.append(data)
        if received.count == 1 {
            await withCheckedContinuation { continuation = $0; blocked = true }
        }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

private final class DeliveryProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite struct TerminalOutputDeliveryTests {
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await predicate()) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func slowConsumerBackpressuresWithoutReorderingAndDrainsBeforeClosure() async throws {
        let transport = SlowTerminalTransport()
        let produced = DeliveryProgress(), closed = DeliveryProgress()
        let delivery = TerminalOutputDelivery(maximumBytes: 8, maximumFrames: 2,
            deliver: { await transport.send($0) }, onFailure: {})
        defer { delivery.stop() }
        delivery.enqueue(Data([0]))
        try await wait { await transport.blocked }
        DispatchQueue(label: "terminal-test-producer").async {
            for byte in UInt8(1)...5 { delivery.enqueue(Data([byte])); produced.increment() }
            delivery.finish { closed.increment() }
        }
        try await wait { produced.count == 2 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(produced.count == 2)
        #expect(closed.count == 0)
        #expect(await transport.received == [Data([0])])
        await transport.resume()
        try await wait { closed.count == 1 }
        #expect(await transport.received == (UInt8(0)...5).map { Data([$0]) })
    }

    @Test func releaseWakesABlockedReaderAndDiscardsUnsentFrames() async throws {
        let transport = SlowTerminalTransport()
        let produced = DeliveryProgress(), failed = DeliveryProgress()
        let delivery = TerminalOutputDelivery(maximumBytes: 2, maximumFrames: 1,
            deliver: { await transport.send($0) }, onFailure: { failed.increment() })
        delivery.enqueue(Data([0]))
        try await wait { await transport.blocked }
        DispatchQueue(label: "terminal-test-release").async {
            delivery.enqueue(Data([1])); produced.increment()
            delivery.enqueue(Data([2])); produced.increment()
        }
        try await wait { produced.count == 1 }
        delivery.stop()
        try await wait { produced.count == 2 }
        await transport.resume()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await transport.received == [Data([0])])
        #expect(failed.count == 0)
    }

    @Test func transportFailureTerminatesTheQueueOnce() async throws {
        struct Disconnected: Error {}
        let failed = DeliveryProgress(), sent = DeliveryProgress()
        let delivery = TerminalOutputDelivery(deliver: { _ in sent.increment(); throw Disconnected() },
            onFailure: { failed.increment() })
        defer { delivery.stop() }
        delivery.enqueue(Data([1]))
        try await wait { failed.count == 1 }
        delivery.enqueue(Data([2]))
        try await Task.sleep(for: .milliseconds(30))
        #expect(sent.count == 1)
        #expect(failed.count == 1)
    }
}
