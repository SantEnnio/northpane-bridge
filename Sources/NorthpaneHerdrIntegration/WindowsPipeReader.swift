#if os(Windows)
import Foundation
import WinSDK

/// Reads a Windows pipe on a thread of its own, in pieces as they arrive, and can be stopped.
///
/// Foundation on Windows never calls a pipe's readabilityHandler, and its `availableData` ends the
/// process with a fatal error when a read is interrupted. Worse, closing a handle while another
/// thread is blocked in a synchronous ReadFile on it blocks the closing thread too (found on a real
/// Windows Host: stopping one Herdr event subscription hung the Bridge). So the reads go straight
/// to ReadFile, and `cancel()` interrupts the one in progress with CancelSynchronousIo before the
/// owner closes the handle.
final class WindowsPipeReader: @unchecked Sendable {
    private let handle: HANDLE
    private let lock = NSLock()
    private var readingThread: HANDLE?
    private var cancelled = false

    init(_ file: FileHandle) { self.handle = file._handle }

    /// Delivers each piece read until the pipe ends, a read fails or `cancel()` is called; then
    /// `onEnd` runs once, unless the reader was cancelled.
    func start(onData: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void) {
        Thread.detachNewThread { [self] in
            var thread: HANDLE?
            _ = DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(), &thread, 0, false, DWORD(DUPLICATE_SAME_ACCESS))
            lock.withLock { readingThread = thread }
            defer {
                lock.withLock {
                    if let readingThread { _ = CloseHandle(readingThread) }
                    readingThread = nil
                }
            }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while !lock.withLock({ cancelled }) {
                var count: DWORD = 0
                let succeeded = buffer.withUnsafeMutableBytes { raw in
                    ReadFile(handle, raw.baseAddress, DWORD(raw.count), &count, nil)
                }
                guard succeeded, count > 0, !lock.withLock({ cancelled }) else { break }
                onData(Data(buffer[0..<Int(count)]))
            }
            if !lock.withLock({ cancelled }) { onEnd() }
        }
    }

    /// Stops the reader, interrupting a read that is waiting for data.
    func cancel() {
        lock.withLock {
            cancelled = true
            if let readingThread { _ = CancelSynchronousIo(readingThread) }
        }
    }
}
#endif
