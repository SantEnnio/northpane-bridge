import Foundation
#if os(macOS)
import Darwin
#endif

public enum ProcessBirth {
    /// When the process started, to the second or better; nil when it cannot be read.
    public static func startTime(pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        #if os(macOS)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, UInt32(mib.count), &process, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size, process.kp_proc.p_pid == pid else { return nil }
        let birth = process.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(birth.tv_sec) + Double(birth.tv_usec) / 1_000_000)
        #elseif os(Linux)
        guard let system = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let line = system.split(separator: "\n").first(where: { $0.hasPrefix("btime ") }),
              let boot = Double(line.dropFirst(6).trimmingCharacters(in: .whitespaces)),
              let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let end = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: end)...].split(separator: " ")
        let ticks = Double(sysconf(Int32(_SC_CLK_TCK)))
        guard fields.count > 19, let started = Double(fields[19]), ticks > 0 else { return nil }
        return Date(timeIntervalSince1970: boot + started / ticks)
        #else
        return nil
        #endif
    }

    public static func proof(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        #if os(macOS)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, UInt32(mib.count), &process, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size, process.kp_proc.p_pid == pid else { return nil }
        let birth = process.kp_proc.p_starttime
        return "\(pid):\(birth.tv_sec):\(birth.tv_usec)"
        #elseif os(Linux)
        guard let boot = try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8),
              let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let end = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: end)...].split(separator: " ")
        guard fields.count > 19, UInt64(fields[19]) != nil else { return nil }
        return "\(boot.trimmingCharacters(in: .whitespacesAndNewlines)):\(pid):\(fields[19])"
        #else
        return nil
        #endif
    }
}
