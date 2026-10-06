import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reads when a Pane last did something.
public protocol PaneActivityReading: Sendable {
    /// The last activity of each Pane that can be told, by Pane ID. A Pane missing from the result
    /// has no known activity, which is not the same as none.
    func lastActivity(paneIDs: [String], now: Date) -> [String: Date]
}

/// When each Pane's terminal was last written to or read from, from the Host's own process table.
///
/// Herdr reports no times, but every process it starts in a Pane carries `HERDR_PANE_ID` and the
/// Pane's terminal. The system stamps a terminal device when output is written to it and when input
/// is read from it, the same evidence `w` uses for idle time, so it survives the Bridge, which runs
/// one process per connection, and needs nothing kept on disk. Herdr servers are told apart by the
/// Panes they hold: the one holding most of the asked Panes answers. On Windows there is no
/// terminal device to read, and every Pane stays unknown.
public final class PaneActivityProbe: PaneActivityReading, @unchecked Sendable {
    /// A Herdr server's direct child: the shell of one Pane, and the terminal it runs on.
    struct PaneProcess: Equatable {
        let parentID: Int32
        let paneID: String
        let terminalPath: String
    }

    private let lock = NSLock()
    private var terminals: [String: String] = [:]
    private var scannedAt: Date?
    private let rescanInterval: TimeInterval
    private let scan: @Sendable () -> [PaneProcess]
    private let stamp: @Sendable (String) -> Date?

    public convenience init() {
        self.init(rescanInterval: 30, scan: { PaneActivityProbe.paneProcesses() }, stamp: { PaneActivityProbe.lastUse(ofTerminal: $0) })
    }

    init(rescanInterval: TimeInterval, scan: @escaping @Sendable () -> [PaneProcess], stamp: @escaping @Sendable (String) -> Date?) {
        self.rescanInterval = rescanInterval
        self.scan = scan
        self.stamp = stamp
    }

    public func lastActivity(paneIDs: [String], now: Date = Date()) -> [String: Date] {
        lock.lock()
        defer { lock.unlock() }
        // The process table is read again now and then, and sooner when a Pane it does not know
        // appears; the terminals themselves are stamped at every call, which is cheap.
        let stale = scannedAt.map { now.timeIntervalSince($0) > rescanInterval } ?? true
        let unknown = paneIDs.contains { terminals[$0] == nil } && (scannedAt.map { now.timeIntervalSince($0) > 5 } ?? true)
        if stale || unknown {
            terminals = Self.terminals(for: paneIDs, among: scan())
            scannedAt = now
        }
        var result: [String: Date] = [:]
        for id in paneIDs {
            if let path = terminals[id], let date = stamp(path) { result[id] = date }
        }
        return result
    }

    /// The terminals of the asked Panes, taken from the Herdr server that holds most of them.
    static func terminals(for paneIDs: [String], among processes: [PaneProcess]) -> [String: String] {
        let wanted = Set(paneIDs)
        let byServer = Dictionary(grouping: processes.filter { wanted.contains($0.paneID) }, by: \.parentID)
        guard let best = byServer.max(by: { lhs, rhs in
            lhs.value.count != rhs.value.count ? lhs.value.count < rhs.value.count : lhs.key > rhs.key
        }) else { return [:] }
        var result: [String: String] = [:]
        for process in best.value where result[process.paneID] == nil { result[process.paneID] = process.terminalPath }
        return result
    }

    /// The later of the terminal's last write and last read, to the second.
    static func lastUse(ofTerminal path: String) -> Date? {
        #if os(Windows)
        return nil
        #else
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let latest = max(info.st_mtimespec.tv_sec, info.st_atimespec.tv_sec)
        #else
        let latest = max(info.st_mtim.tv_sec, info.st_atim.tv_sec)
        #endif
        return Date(timeIntervalSince1970: TimeInterval(latest))
        #endif
    }

    /// The `HERDR_PANE_ID` in a block of `NAME=value` strings separated by NUL bytes.
    static func paneID(inEnvironment bytes: [UInt8]) -> String? {
        let key = Array("HERDR_PANE_ID=".utf8)
        for entry in bytes.split(separator: 0, omittingEmptySubsequences: true) where entry.starts(with: key) {
            let value = String(decoding: entry.dropFirst(key.count), as: UTF8.self)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    #if canImport(Darwin)
    static func paneProcesses() -> [PaneProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = table.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &table, &size, nil, 0) == 0 else { return [] }
        table.removeLast(table.count - size / MemoryLayout<kinfo_proc>.stride)

        func name(_ process: kinfo_proc) -> String {
            withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        let servers = Set(table.filter { name($0) == "herdr" }.map(\.kp_proc.p_pid))
        guard !servers.isEmpty else { return [] }
        return table.compactMap { process in
            let parent = process.kp_eproc.e_ppid
            let device = process.kp_eproc.e_tdev
            guard servers.contains(parent), device != -1, let deviceName = devname(device, S_IFCHR) else { return nil }
            guard let paneID = paneID(inEnvironment: environment(of: process.kp_proc.p_pid)) else { return nil }
            return PaneProcess(parentID: parent, paneID: paneID, terminalPath: "/dev/" + String(cString: deviceName))
        }
    }

    /// The environment block of a process of the same user, from `KERN_PROCARGS2`: the argument
    /// count, the executable path, the arguments, then the environment.
    private static func environment(of pid: Int32) -> [UInt8] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        buffer.removeLast(buffer.count - size)
        let argumentCount = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // The executable path, then the padding after it.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var skipped: Int32 = 0
        while index < buffer.count, skipped < argumentCount {
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            index += 1
            skipped += 1
        }
        return index < buffer.count ? Array(buffer[index...]) : []
    }
    #elseif os(Linux)
    static func paneProcesses() -> [PaneProcess] {
        let proc = URL(fileURLWithPath: "/proc")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: proc.path) else { return [] }
        let uid = getuid()
        var parents: [Int32: Int32] = [:]
        var servers = Set<Int32>()
        for entry in entries {
            guard let pid = Int32(entry), let status = try? String(contentsOfFile: "/proc/\(entry)/stat", encoding: .utf8),
                  let open = status.firstIndex(of: "("), let close = status.lastIndex(of: ")") else { continue }
            var info = stat()
            guard stat("/proc/\(entry)", &info) == 0, info.st_uid == uid else { continue }
            let command = status[status.index(after: open)..<close]
            let fields = status[status.index(after: close)...].split(separator: " ")
            guard fields.count > 2, let parent = Int32(fields[1]) else { continue }
            parents[pid] = parent
            if command == "herdr" { servers.insert(pid) }
        }
        guard !servers.isEmpty else { return [] }
        return parents.compactMap { pid, parent in
            guard servers.contains(parent),
                  let terminal = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/fd/0"),
                  terminal.hasPrefix("/dev/pts/") || terminal.hasPrefix("/dev/tty"),
                  let environment = FileManager.default.contents(atPath: "/proc/\(pid)/environ"),
                  let paneID = paneID(inEnvironment: Array(environment)) else { return nil }
            return PaneProcess(parentID: parent, paneID: paneID, terminalPath: terminal)
        }
    }
    #else
    static func paneProcesses() -> [PaneProcess] { [] }
    #endif
}
