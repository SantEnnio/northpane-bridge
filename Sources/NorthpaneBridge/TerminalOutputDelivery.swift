import Foundation

/// One ordered writer per attachment. A slow transport backpressures the
/// channel's reader queue instead of retaining an unbounded Task per frame.
/// Painted frames cannot be dropped: a preceding frame may switch buffers.
final class TerminalOutputDelivery: @unchecked Sendable {
    private let condition = NSCondition()
    private let maximumBytes: Int
    private let maximumFrames: Int
    private let deliver: @Sendable (Data) async throws -> Void
    private let onFailure: @Sendable () -> Void
    private var frames: [Data] = []
    private var queuedBytes = 0
    private var worker: Task<Void, Never>?
    private var completion: (@Sendable () async -> Void)?
    private var stopped = false

    init(maximumBytes: Int = 2 * 1_024 * 1_024, maximumFrames: Int = 32,
         deliver: @escaping @Sendable (Data) async throws -> Void,
         onFailure: @escaping @Sendable () -> Void) {
        precondition(maximumBytes > 0 && maximumFrames > 0)
        self.maximumBytes = maximumBytes; self.maximumFrames = maximumFrames
        self.deliver = deliver; self.onFailure = onFailure
    }

    /// Called only on a channel's dedicated reader queue, never an async worker.
    func enqueue(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        guard bytes.count <= maximumBytes else { if failed() { onFailure() }; return }
        condition.lock()
        while !stopped && completion == nil &&
            (frames.count >= maximumFrames || queuedBytes + bytes.count > maximumBytes) {
            condition.wait()
        }
        guard !stopped && completion == nil else { condition.unlock(); return }
        frames.append(bytes); queuedBytes += bytes.count
        startWorkerLocked()
        condition.unlock()
    }

    /// Preserve the final frame before reporting a genuine stream closure.
    func finish(_ completion: @escaping @Sendable () async -> Void) {
        condition.lock()
        guard !stopped && self.completion == nil else { condition.unlock(); return }
        self.completion = completion
        condition.broadcast()
        startWorkerLocked()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true; frames.removeAll(); queuedBytes = 0; completion = nil
        let active = worker; worker = nil
        condition.broadcast()
        condition.unlock()
        active?.cancel()
    }

    private func startWorkerLocked() {
        if worker == nil { worker = Task { await drain() } }
    }

    private enum Next {
        case frame(Data), finish(@Sendable () async -> Void), idle
    }

    private func next() -> Next {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped else { worker = nil; return .idle }
        if !frames.isEmpty {
            let bytes = frames.removeFirst(); queuedBytes -= bytes.count
            condition.broadcast()
            return .frame(bytes)
        }
        worker = nil
        if let completion {
            stopped = true; self.completion = nil
            return .finish(completion)
        }
        return .idle
    }

    private func failed() -> Bool {
        condition.lock()
        let notify = !stopped
        stopped = true; frames.removeAll(); queuedBytes = 0; completion = nil; worker = nil
        condition.broadcast()
        condition.unlock()
        return notify
    }

    private func drain() async {
        while true {
            switch next() {
            case let .frame(bytes):
                do { try Task.checkCancellation(); try await deliver(bytes) }
                catch { if failed() { onFailure() }; return }
            case let .finish(completion): await completion(); return
            case .idle: return
            }
        }
    }
}
