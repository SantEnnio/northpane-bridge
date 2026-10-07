#if os(macOS) || os(Linux)
import Foundation
import NorthpanePTY
#if os(macOS)
import Darwin
#else
import Glibc
#endif

public enum PTYError: Error, Equatable, Sendable {
    case invalidConfiguration
    case systemCall(Int32)
    case closed
    case inputTimedOut
}

/// Owns a process and its controlling terminal, independently of any client.
/// Output and exit callbacks are serialized on a dedicated reader thread;
/// the exit callback follows the last byte. Clients must not call terminate on detach.
public final class PTYProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var master: Int32
    private let child: Int32
    private var exitStatus: Int32?
    private var terminationDeadline: ContinuousClock.Instant?
    private let onOutput: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32, PTYError?) -> Void

    public static func launch(
        executable: String, arguments: [String] = [], directory: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        columns: Int, rows: Int,
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32, PTYError?) -> Void
    ) throws -> PTYProcess {
        guard executable.hasPrefix("/"), directory.hasPrefix("/"),
              (1...65535).contains(columns), (1...65535).contains(rows),
              !([executable, directory] + arguments).contains(where: { $0.utf8.contains(0) }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) })
        else { throw PTYError.invalidConfiguration }
        // Allocate C strings before fork. The child never runs a Swift closure.
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
            throw PTYError.systemCall(ENOMEM)
        }
        var master: Int32 = -1
        var child: Int32 = -1
        let error = argv.withUnsafeBufferPointer { argv in
            envp.withUnsafeBufferPointer { envp in
                np_pty_spawn(executable, argv.baseAddress, envp.baseAddress, directory,
                             UInt16(columns), UInt16(rows), &master, &child)
            }
        }
        guard error == 0 else { throw PTYError.systemCall(error) }
        let process = PTYProcess(master: master, child: child, onOutput: onOutput, onExit: onExit)
        Thread.detachNewThread { process.readUntilExit() }
        return process
    }

    private init(master: Int32, child: Int32, onOutput: @escaping @Sendable (Data) -> Void,
                 onExit: @escaping @Sendable (Int32, PTYError?) -> Void) {
        self.master = master
        self.child = child
        self.onOutput = onOutput
        self.onExit = onExit
    }

    public func resize(columns: Int, rows: Int) throws {
        guard (1...65535).contains(columns), (1...65535).contains(rows) else { throw PTYError.invalidConfiguration }
        try lock.withLock {
            guard master >= 0 else { throw PTYError.closed }
            let error = np_pty_resize(master, UInt16(columns), UInt16(rows))
            if error != 0 { throw PTYError.systemCall(error) }
        }
    }

    /// Handles short writes and backpressure without losing input. A stalled
    /// child cannot hold the lifecycle lock indefinitely.
    public func sendInput(_ data: Data) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count: Int = try lock.withLock {
                    guard master >= 0 else { throw PTYError.closed }
                    let count = write(master, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno != EINTR && errno != EAGAIN { throw PTYError.systemCall(errno) }
                    return max(count, 0)
                }
                offset += count
                if count == 0 {
                    guard ContinuousClock.now < deadline else { throw PTYError.inputTimedOut }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
        }
    }

    /// Explicit Pane closure. Normal detach has no effect on this object.
    public func terminate() {
        lock.withLock {
            guard master >= 0, terminationDeadline == nil else { return }
            terminationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            if exitStatus == nil { _ = np_pty_signal(child, SIGTERM) }
            let foreground = tcgetpgrp(master)
            if foreground > 0 { _ = kill(-foreground, SIGTERM) }
        }
    }

    private func readUntilExit() {
        var bytes = [UInt8](repeating: 0, count: 65536)
        var readFinished = false
        var failure: PTYError?
        while true {
            let state: (Int32, Bool, Bool) = lock.withLock {
                if exitStatus == nil {
                    var finished: Int32 = 0
                    var status: Int32 = 0
                    let error = np_pty_poll_exit(child, &finished, &status)
                    if finished != 0 { exitStatus = status }
                    if error != 0 { failure = .systemCall(error); exitStatus = 127 }
                }
                let forced = terminationDeadline.map { ContinuousClock.now >= $0 } ?? false
                if forced {
                    let foreground = tcgetpgrp(master)
                    if foreground > 0, foreground != getpgrp() { _ = kill(-foreground, SIGKILL) }
                    if exitStatus == nil { _ = np_pty_signal(child, SIGKILL) }
                }
                return (master, exitStatus != nil, forced)
            }
            if !readFinished {
                var descriptor = pollfd(fd: state.0, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready < 0 && errno != EINTR { failure = .systemCall(errno); readFinished = true }
                if ready > 0 {
                    let count = read(state.0, &bytes, bytes.count)
                    if count > 0 { onOutput(Data(bytes.prefix(count))) }
                    else if count == 0 || (count < 0 && errno == EIO) { readFinished = true }
                    else if errno != EINTR && errno != EAGAIN { failure = .systemCall(errno); readFinished = true }
                }
            } else if !state.1 {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if state.2 { readFinished = true }
            if readFinished && state.1 { break }
        }
        let status = lock.withLock {
            close(master)
            master = -1
            return exitStatus ?? 127
        }
        onExit(status, failure)
    }
}
#endif
