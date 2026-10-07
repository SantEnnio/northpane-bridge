#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import NorthpaneNativeRuntime
#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var count = 0
    private var allZero = true
    private var exit: (Int32, PTYError?)?
    let retainOutput: Bool
    init(retainOutput: Bool = true) { self.retainOutput = retainOutput }
    func output(_ bytes: Data) {
        lock.withLock {
            count += bytes.count
            if retainOutput { data.append(bytes) }
            else { allZero = allZero && bytes.allSatisfy { $0 == 0 } }
        }
    }
    func ended(_ status: Int32, _ error: PTYError?) { lock.withLock { exit = (status, error) } }
    func snapshot() -> (Data, Int, Bool, (Int32, PTYError?)?) { lock.withLock { (data, count, allZero, exit) } }
    func waitForExit(seconds: Int = 10) async throws -> (Data, Int, Bool, (Int32, PTYError?)) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            let value = snapshot()
            if let exit = value.3 { return (value.0, value.1, value.2, exit) }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PTYError.inputTimedOut
    }
    func waitForText(_ text: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if String(decoding: snapshot().0, as: UTF8.self).contains(text) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PTYError.inputTimedOut
    }
}

private func usage() -> (cpuSeconds: Double, peakRSSMiB: Double) {
    var value = rusage()
#if os(macOS)
    _ = getrusage(RUSAGE_SELF, &value)
    let rss = Double(value.ru_maxrss) / (1024 * 1024)
#elseif canImport(Glibc)
    _ = getrusage(Int32(RUSAGE_SELF.rawValue), &value)
    let rss = Double(value.ru_maxrss) / 1024
#else
    _ = getrusage(RUSAGE_SELF, &value)
    let rss = Double(value.ru_maxrss) / 1024
#endif
    let cpu = Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    return (cpu, rss)
}

@Suite(.serialized) struct PTYProcessTests {
    @Test func controllingTerminalDirectoryEnvironmentAndExit() async throws {
        let capture = Capture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = try PTYProcess.launch(executable: "/bin/sh", arguments: ["-c", "test -t 0 && test -t 1 && test -t 2 || exit 99; pwd; printf '%s\\n' \"$NORTHPANE_TEST\"; stty size; exit 7"], directory: directory.path,
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "NORTHPANE_TEST": "pty-value"], columns: 91, rows: 37,
            onOutput: capture.output, onExit: capture.ended)
        defer { process.terminate() }
        let result = try await capture.waitForExit()
        let text = String(decoding: result.0, as: UTF8.self)
        #expect(text.contains(directory.resolvingSymlinksInPath().path))
        #expect(text.contains("pty-value\r\n"))
        #expect(text.contains("37 91\r\n"))
        #expect(result.3.0 == 7)
        #expect(result.3.1 == nil)
        #expect(throws: PTYError.closed) { try process.sendInput(Data("after exit".utf8)) }
    }

    @Test func inputResizeAndClientDetachLeaveProcessAlive() async throws {
        let capture = Capture()
        let process = try PTYProcess.launch(executable: "/bin/sh", arguments: ["-c", "stty -echo; printf 'ready\\n'; read first; stty size; printf 'first:%s\\n' \"$first\"; read second; printf 'second:%s\\n' \"$second\""], directory: "/tmp", columns: 80, rows: 24,
            onOutput: capture.output, onExit: capture.ended)
        defer { process.terminate() }
        try await capture.waitForText("ready")
        try process.resize(columns: 120, rows: 41)
        try process.sendInput(Data("one\n".utf8))
        try await capture.waitForText("first:one")
        // No client exists during this interval. Only the runtime's PTY owner remains.
        try await Task.sleep(for: .milliseconds(150))
        #expect(capture.snapshot().3 == nil)
        try process.sendInput(Data("two\n".utf8))
        let result = try await capture.waitForExit()
        #expect(String(decoding: result.0, as: UTF8.self).contains("41 120\r\n"))
        #expect(String(decoding: result.0, as: UTF8.self).contains("second:two\r\n"))
        #expect(result.3.0 == 0)
    }

    @Test func launchFailuresAreSynchronousAndReaped() throws {
        let capture = Capture()
        #expect(throws: PTYError.systemCall(ENOENT)) {
            _ = try PTYProcess.launch(executable: "/nonexistent-northpane-executable", directory: "/tmp", columns: 80, rows: 24, onOutput: capture.output, onExit: capture.ended)
        }
        #expect(throws: PTYError.systemCall(ENOENT)) {
            _ = try PTYProcess.launch(executable: "/bin/sh", directory: "/nonexistent-northpane-directory", columns: 80, rows: 24, onOutput: capture.output, onExit: capture.ended)
        }
        #expect(throws: PTYError.invalidConfiguration) {
            _ = try PTYProcess.launch(executable: "/bin/sh", directory: "/tmp", columns: 0, rows: 24, onOutput: capture.output, onExit: capture.ended)
        }
    }

    @Test func inheritedDescriptorsAreClosedBeforeExec() async throws {
        let capture = Capture()
        let descriptor = open("/dev/null", O_RDONLY)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        let inherited = fcntl(descriptor, F_DUPFD, 100)
        #expect(inherited >= 100)
        defer { close(inherited) }
        let process = try PTYProcess.launch(executable: "/bin/sh", arguments: ["-c", "if [ -e /dev/fd/\(inherited) ]; then exit 91; fi"], directory: "/tmp", columns: 80, rows: 24,
            onOutput: capture.output, onExit: capture.ended)
        defer { process.terminate() }
        let result = try await capture.waitForExit()
        #expect(result.3.0 == 0)
    }

    @Test func terminationEscalatesWhenChildIgnoresTerm() async throws {
        let capture = Capture()
        let process = try PTYProcess.launch(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; printf 'ready\\n'; while :; do sleep 1; done"], directory: "/tmp", columns: 80, rows: 24,
            onOutput: capture.output, onExit: capture.ended)
        defer { process.terminate() }
        try await capture.waitForText("ready")
        process.terminate()
        let result = try await capture.waitForExit()
        #expect(result.3.0 >= 128)
    }

    @Test func fiftyMiBWithoutLossOrRetainedOutput() async throws {
        let capture = Capture(retainOutput: false)
        let start = ContinuousClock.now
        let before = usage()
        let process = try PTYProcess.launch(executable: "/bin/sh", arguments: ["-c", "dd if=/dev/zero bs=1048576 count=50 2>/dev/null"], directory: "/tmp", columns: 80, rows: 24,
            onOutput: capture.output, onExit: capture.ended)
        defer { process.terminate() }
        let result = try await capture.waitForExit(seconds: 30)
        #expect(result.1 == 50 * 1024 * 1024)
        #expect(result.2)
        #expect(result.0.isEmpty)
        #expect(result.3.0 == 0)
        #expect(result.3.1 == nil)
        let after = usage()
        print("PTY: 50 MiB verified, elapsed \(start.duration(to: .now)), reader/test CPU \(after.cpuSeconds - before.cpuSeconds)s, test-process peak RSS \(after.peakRSSMiB) MiB")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NORTHPANE_TERMINAL_BENCHMARK"] == "1"))
    func fiftyMiBThroughTerminalEmulator() {
        let screen = TerminalViewport(columns: 80, rows: 24, scrollback: 1000)
        let pattern = Array("benchmark line 0123456789\r\n".utf8)
        let chunk = Data((0..<65536).map { pattern[$0 % pattern.count] })
        let before = usage()
        let start = ContinuousClock.now
        for _ in 0..<800 { screen.feed(chunk) }
        let after = usage()
        // 1000 retained history rows plus 24 visible rows, independent of the
        // amount of terminal output. No transcript or disk journal is retained.
        let first = screen.terminal.buffer.totalLinesTrimmed
        #expect(screen.terminal.getScrollInvariantLine(row: first + 1024) == nil)
        #expect(screen.terminal.getScrollInvariantLine(row: first + 1023) != nil)
        let replay = TerminalViewport(columns: 80, rows: 24, scrollback: 1000)
        replay.feed(screen.replayViewport())
        #expect(cells(screen.terminal) == cells(replay.terminal))
        print("Terminal: 50 MiB parsed, elapsed \(start.duration(to: .now)), CPU \(after.cpuSeconds - before.cpuSeconds)s, test-process peak RSS \(after.peakRSSMiB) MiB (before \(before.peakRSSMiB))")
    }

    /// Opt-in local recording. Use a temporary, empty HOME and never provide
    /// credentials. Recordings are reviewed before becoming public fixtures.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NORTHPANE_TERMINAL_CORPUS"] != nil))
    func recordLocalTerminalCorpus() async throws {
        guard let configuration = ProcessInfo.processInfo.environment["NORTHPANE_TERMINAL_CORPUS"],
              let paths = try JSONSerialization.jsonObject(with: Data(configuration.utf8)) as? [String: String],
              let output = ProcessInfo.processInfo.environment["NORTHPANE_TERMINAL_CORPUS_OUTPUT"] else { return }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data((1...100).map { "line \($0): text 漢字\n" }.joined().utf8).write(to: root.appendingPathComponent("example.txt"))
        for (name, executable) in paths.sorted(by: { $0.key < $1.key }) {
            let arguments: [String]
            switch name {
            case "vim": arguments = ["-Nu", "NONE", "-n", "-i", "NONE", "example.txt"]
            case "less": arguments = ["-R", "example.txt"]
            case "shell": arguments = ["-i"]
            default: arguments = []
            }
            let capture = Capture()
            let process = try PTYProcess.launch(executable: executable, arguments: arguments, directory: root.path,
                environment: ["HOME": home.path, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "PS1": "probe$ "], columns: 80, rows: 24,
                onOutput: capture.output, onExit: capture.ended)
            defer { process.terminate() }
            let terminal = TerminalViewport(columns: 80, rows: 24)
            var offset = 0
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while ContinuousClock.now < deadline && capture.snapshot().3 == nil {
                let data = capture.snapshot().0
                terminal.feed(data.dropFirst(offset)); offset = data.count
                if !terminal.replies.isEmpty {
                    try process.sendInput(terminal.replies)
                    terminal.replies.removeAll()
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let initial = capture.snapshot().0
            try initial.write(to: root.appendingPathComponent("\(name).ansi"))
            let replay = TerminalViewport(columns: 80, rows: 24)
            terminal.feed(initial.dropFirst(offset)); offset = initial.count
            replay.feed(terminal.replayViewport())
            var mismatches = 0
            for row in 0..<24 {
                for col in 0..<80 {
                    let lhs = terminal.terminal.getCharData(col: col, row: row)!
                    let rhs = replay.terminal.getCharData(col: col, row: row)!
                    let left = terminal.terminal.getCharacter(for: lhs)
                    let right = replay.terminal.getCharacter(for: rhs)
                    if (left == "\0" ? " " : left) != (right == "\0" ? " " : right) || lhs.width != rhs.width || lhs.attribute != rhs.attribute { mismatches += 1 }
                }
            }
            print("Corpus \(name): \(initial.count) bytes, viewport mismatches \(mismatches), alternate \(terminal.terminal.isCurrentBufferAlternate), cursor source \(terminal.terminal.buffer.x),\(terminal.terminal.buffer.y) replay \(replay.terminal.buffer.x),\(replay.terminal.buffer.y)")
            #expect(mismatches == 0)
            if capture.snapshot().3 == nil {
                if name == "vim" { try process.sendInput(Data(":q!\r".utf8)) }
                else if name == "less" { try process.sendInput(Data("q".utf8)) }
                else { process.terminate() }
                _ = try await capture.waitForExit()
            }
            let full = capture.snapshot().0
            let tail = full.dropFirst(offset)
            terminal.feed(tail); replay.feed(tail)
            #expect(cells(terminal.terminal) == cells(replay.terminal))
            try Data(tail).write(to: root.appendingPathComponent("\(name)-exit.ansi"))
        }
    }
}
#endif
