import Foundation
#if os(macOS)
import Darwin
#endif

enum ProcessBirth {
    static func proof(pid: Int32) -> String? {
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
