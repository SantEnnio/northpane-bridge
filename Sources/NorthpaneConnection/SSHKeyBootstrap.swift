#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// One-time, password-authenticated installation of the device key on a Host, so that
/// every later connection is key-only. The password is handed to the system `ssh`
/// through `SSH_ASKPASS` reading a private FIFO: it never touches the disk, the command
/// line or the environment, and it is not kept after the run.
public struct SSHKeyBootstrap: Sendable {
    public var sshExecutable: URL
    public var timeout: TimeInterval

    /// Where the askpass helper and its per-prompt FIFOs live; tests point it at a private directory.
    let temporaryRoot: URL

    public init(sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"), timeout: TimeInterval = 60, temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.temporaryRoot = temporaryRoot
        self.sshExecutable = sshExecutable
        self.timeout = timeout
    }

    /// The remote POSIX command that installs `authorizedKey`; see `SSHAuthorizedKeyInstall`.
    public static func remoteInstallCommand(authorizedKey: String) throws -> String {
        try SSHAuthorizedKeyInstall.remoteCommand(authorizedKey: authorizedKey)
    }

    /// Options that make this run password-only, single-attempt and non-interactive. An unknown
    /// or changed Host key fails: the app has the Operator accept the key before this runs
    /// (`SSHHostKeyTrust`), so nothing here records a key nobody looked at.
    public static func sshArguments(endpoint: String, remoteCommand: String) -> [String] {
        [
            "-o", "BatchMode=no",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=keyboard-interactive,password",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=10",
            "--", endpoint, remoteCommand,
        ]
    }

    public func installAuthorizedKey(endpoint: String, authorizedKey: String, password: String) async throws {
        guard endpoint.range(of: #"^[A-Za-z0-9._@:\[\]-]+$"#, options: .regularExpression) != nil, !endpoint.hasPrefix("-") else {
            throw SSHKeyBootstrapError.invalidEndpoint
        }
        guard !password.isEmpty, !password.contains("\n") else { throw SSHKeyBootstrapError.emptyPassword }
        let remoteCommand = try Self.remoteInstallCommand(authorizedKey: authorizedKey)

        let workspace = try PrivateWorkspace(root: temporaryRoot)
        defer { workspace.remove() }

        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = workspace.helper.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["NORTHPANE_ASKPASS_DIR"] = workspace.directory.path
        if environment["DISPLAY"] == nil { environment["DISPLAY"] = "northpane:0" }

        let process = Process()
        process.executableURL = sshExecutable
        process.arguments = Self.sshArguments(endpoint: endpoint, remoteCommand: remoteCommand)
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Both streams are drained to EOF by their own thread rather than by a readability
        // handler: clearing a handler does not cancel one already in flight, so `ssh`'s diagnosis
        // could still be arriving while it is being classified, and the run would be reported as
        // a plain command failure instead of a rejected password.
        let captured = CapturedOutput()
        let drainedStderr = DispatchSemaphore(value: 0)
        drain(stdout.fileHandleForReading, into: nil, signalling: nil)
        drain(stderr.fileHandleForReading, into: captured, signalling: drainedStderr)

        let feeder = PasswordFeeder(workspace: workspace, password: password)
        do { try process.run() } catch { throw SystemTransportError.launchFailed }
        try? stdin.fileHandleForWriting.close()
        feeder.start(while: { process.isRunning })

        let exitCode = await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    // The process can exit between installing the handler and the liveness check,
                    // in which case both paths fire; the latch keeps the continuation single-use.
                    // Neither path alone is enough: a handler installed after the exit never runs.
                    let exited = OneShotLatch { continuation.resume() }
                    process.terminationHandler = { _ in exited.signal() }
                    if !process.isRunning { exited.signal() }
                }
                return process.terminationStatus
            }
            group.addTask { [timeout] in
                try? await Task.sleep(for: .seconds(timeout))
                if process.isRunning { process.terminate() }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        feeder.stop()
        // A child that outlives `ssh` could hold the pipe open, so do not wait on EOF forever.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = drainedStderr.wait(timeout: .now() + .seconds(2))
                continuation.resume()
            }
        }
        let errorData = captured.data

        guard let exitCode else { throw SSHKeyBootstrapError.timedOut }
        guard exitCode == 0 else {
            let failure = ProcessBridgeTransport.classifyFailure(kind: .ssh, exitCode: exitCode, errorData: errorData)
            if case .processFailed = failure {
                let detail = String(decoding: errorData.prefix(2_048), as: UTF8.self)
                    .replacingOccurrences(of: password, with: "•••")
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
                    .prefix(4)
                    .joined(separator: " ")
                throw SSHKeyBootstrapError.commandFailed(exitCode: exitCode, detail: String(detail.prefix(300)))
            }
            throw failure
        }
    }
}

/// Reads `handle` until EOF on its own thread, keeping the child from blocking on a full pipe.
private func drain(_ handle: FileHandle, into captured: CapturedOutput?, signalling done: DispatchSemaphore?) {
    Thread.detachNewThread {
        while let chunk = try? handle.read(upToCount: 16_384), !chunk.isEmpty {
            captured?.append(chunk)
        }
        done?.signal()
    }
}

/// A 0700 directory holding the askpass helper and one FIFO per prompt.
///
/// A single shared FIFO cannot say which prompt a write answers: the helper for the next
/// prompt can open it before the feeder has noticed that the previous helper is gone, so a
/// second write is appended to an answer still being read ("pw\npw") and the Host rejects the
/// login. Giving every prompt its own FIFO removes the ambiguity — each one has exactly one
/// reader for its whole lifetime, and the feeder writes to each at most once.
private struct PrivateWorkspace {
    /// Enough for the handful of prompts a Host can ask under `NumberOfPasswordPrompts=1`;
    /// past this the helper's `cat` fails on a missing FIFO instead of hanging.
    static let promptCount = 8

    let directory: URL
    let helper: URL

    init(root: URL) throws {
        let directory = root.appending(path: "northpane-ssh-bootstrap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for index in 0..<Self.promptCount {
            guard mkfifo(directory.appending(path: "prompt.\(index)").path, 0o600) == 0 else { throw SystemTransportError.launchFailed }
        }
        // Each helper claims the next free index with `mkdir`, which is atomic, then reads only
        // that FIFO. Prompts are therefore served 0, 1, 2, … in the order `ssh` asks them.
        let helper = directory.appending(path: "askpass.sh")
        try Data("""
        #!/bin/sh
        n=0
        while ! mkdir "$NORTHPANE_ASKPASS_DIR/turn.$n" 2>/dev/null; do n=$((n+1)); done
        exec cat "$NORTHPANE_ASKPASS_DIR/prompt.$n"

        """.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        self.directory = directory; self.helper = helper
    }

    func fifo(prompt index: Int) -> URL { directory.appending(path: "prompt.\(index)") }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Answers each prompt's FIFO once, as soon as its askpass helper opens it for reading, and
/// gives up when `ssh` exits without asking.
private final class PasswordFeeder: @unchecked Sendable {
    private let workspace: PrivateWorkspace
    private var password: Data
    private let lock = NSLock()
    private var stopped = false

    init(workspace: PrivateWorkspace, password: String) {
        self.workspace = workspace
        self.password = Data((password + "\n").utf8)
    }

    func start(while running: @escaping @Sendable () -> Bool) {
        Thread.detachNewThread { [self] in
            // A reader that goes away mid-write turns into SIGPIPE, which would kill the whole
            // process; on this thread the write reports EPIPE instead.
            var pipeOnly = sigset_t()
            sigemptyset(&pipeOnly)
            sigaddset(&pipeOnly, SIGPIPE)
            pthread_sigmask(SIG_BLOCK, &pipeOnly, nil)

            defer { lock.withLock { password.resetBytes(in: 0..<password.count) } }
            // `ssh` invokes the askpass helper once per prompt. macOS Hosts offer both
            // keyboard-interactive and password, so the helper runs more than once: the feeder
            // must answer every prompt, not just the first, or the later prompt hangs and the
            // Host closes the connection (exit 255). Index `prompt` is never reopened once it
            // has been written to, so no helper can ever be handed the password twice.
            var prompt = 0
            while prompt < PrivateWorkspace.promptCount, !isStopped, running() {
                let fd = open(workspace.fifo(prompt: prompt).path, O_WRONLY | O_NONBLOCK)
                if fd >= 0 {
                    var flags = fcntl(fd, F_GETFL)
                    flags &= ~O_NONBLOCK
                    _ = fcntl(fd, F_SETFL, flags)
                    lock.withLock { writeAll(fd, password) }
                    close(fd)
                    prompt += 1
                    continue
                }
                // ENXIO: this prompt's helper has not opened its FIFO yet. Any other error means
                // the workspace is gone; stop.
                guard errno == ENXIO else { return }
                usleep(5_000)
            }
        }
    }

    private func writeAll(_ fd: Int32, _ bytes: Data) {
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                return
            }
        }
    }

    func stop() { lock.withLock { stopped = true } }
    private var isStopped: Bool { lock.withLock { stopped } }
}

/// Runs its action on the first `signal()` and ignores every later one.
private final class OneShotLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    init(_ action: @escaping @Sendable () -> Void) { self.action = action }

    func signal() {
        let action = lock.withLock { let taken = self.action; self.action = nil; return taken }
        action?()
    }
}

private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ data: Data) { lock.withLock { if buffer.count < 65_536 { buffer.append(data) } } }
    var data: Data { lock.withLock { buffer } }
}
#endif
