#if os(macOS) || os(Linux)
import Foundation
import NorthpaneHostRuntime
import NorthpaneProtocol

/// An attachment owns one RPC stream, never the daemon or the Pane process.
/// Polling coalesces output into bounded authoritative frames; no transcript is
/// buffered on a disconnected Bridge. Callbacks run serially on the poll queue.
final class NativeTerminalChannel: TerminalChannel, @unchecked Sendable {
    private let stateDirectory: URL
    private let incarnationID: String
    private let paneID: String
    private let mode: TerminalAttachMode
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "northpane.native.terminal")
    private var connection: NativeRuntimeConnection?
    private var attachment: NativeTerminalView?
    private var timer: DispatchSourceTimer?
    private var stopped = false

    init(stateDirectory: URL, incarnationID: String, paneID: String, mode: TerminalAttachMode) {
        self.stateDirectory = stateDirectory; self.incarnationID = incarnationID
        self.paneID = paneID; self.mode = mode
    }
    deinit { stop() }

    func start(columns: Int, rows: Int, onOutput: @escaping @Sendable (Data) -> Void,
               onClose: @escaping @Sendable (Error?) -> Void) throws {
        let connection = try NativeRuntimeConnection.connectSynchronously(stateDirectory: stateDirectory)
        do {
            guard connection.status.incarnationID == incarnationID else { throw NativeRuntimeProcessError.invalidFrame }
            let view = try connection.openTerminal(paneID: paneID, mode: mode, columns: columns, rows: rows)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(75), repeating: .milliseconds(75))
            timer.setEventHandler { [weak self] in
                guard let self, let previous = self.lock.withLock({ self.stopped ? nil : self.attachment }) else { return }
                do {
                    let next = try connection.pollTerminal(attachmentID: previous.attachmentID, afterRevision: previous.revision)
                    guard next.processProof == previous.processProof else { throw NativeRuntimeProcessError.invalidFrame }
                    guard self.lock.withLock({ !self.stopped }) else { return }
                    if !next.bytes.isEmpty { onOutput(next.bytes) }
                    self.lock.withLock { self.attachment = next }
                    if next.ended { self.stop(); onClose(nil) }
                    else if self.mode != .observe && !next.controlling {
                        self.stop(); onClose(NativeRuntimeProcessError.rejected("control_required"))
                    }
                } catch {
                    let notify = self.lock.withLock { !self.stopped }
                    self.stop()
                    if notify { onClose(error) }
                }
            }
            let accepted = lock.withLock {
                guard !stopped, self.connection == nil else { return false }
                self.connection = connection; attachment = view; self.timer = timer; return true
            }
            guard accepted else { timer.resume(); timer.cancel(); throw NativeRuntimeProcessError.invalidConfiguration }
            // The timer starts only after the full first frame was delivered.
            onOutput(view.bytes)
            timer.resume()
        } catch { connection.close(); throw error }
    }

    private func current() throws -> (NativeRuntimeConnection, NativeTerminalView) {
        try lock.withLock {
            guard !stopped, let connection, let attachment else { throw NativeRuntimeProcessError.invalidConfiguration }
            return (connection, attachment)
        }
    }
    func sendInput(_ data: Data) throws {
        let (connection, view) = try current()
        // Public input frames may be larger than the local RPC bound. Each
        // piece is separately authorized by the daemon's global control lease.
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + 65_536)
            try connection.inputTerminal(attachmentID: view.attachmentID, bytes: data.subdata(in: offset..<end))
            offset = end
        }
    }
    func resize(columns: Int, rows: Int) throws {
        let (connection, view) = try current()
        try connection.resizeTerminal(attachmentID: view.attachmentID, columns: columns, rows: rows)
    }
    func scroll(direction: TerminalScrollDirection, lines: Int) throws {
        let (connection, view) = try current()
        try connection.scrollTerminal(attachmentID: view.attachmentID, direction: direction, lines: lines)
    }
    func release() throws {
        let (connection, view) = try current()
        try connection.releaseTerminal(attachmentID: view.attachmentID)
        stop()
    }
    func stop() {
        let closing = lock.withLock { () -> NativeRuntimeConnection? in
            stopped = true; timer?.cancel(); timer = nil
            let result = connection; connection = nil; attachment = nil; return result
        }
        closing?.close()
    }
}
#endif
