import Foundation

/// Claude Code keeps one record per running interactive process, `<config>/sessions/<pid>.json`,
/// with the ID of the chat that process shows. Claude rewrites it itself on `/clear` and
/// `/resume`, before any new input (observed with Claude Code 2.1.300–2.1.301 on macOS, on a
/// synthetic session that sent no prompt).
///
/// The file is not a documented interface. It is accepted only for the exact process: same PID
/// and a recorded start that matches the process' own birth, so a reused PID never inherits a
/// chat. Anything else (missing, malformed, another shape, another process) reads as no record.
public struct ClaudeSessionRecords: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `CLAUDE_CONFIG_DIR` of this Bridge if set, else `~/.claude`.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeSessionRecords {
        let base = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        return .init(directory: base.appendingPathComponent("sessions", isDirectory: true))
    }

    public func sessionID(pid: Int32) -> String? {
        guard pid > 0, let birth = ProcessBirth.startTime(pid: pid) else { return nil }
        let file = directory.appendingPathComponent("\(pid).json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.size] as? NSNumber)?.intValue ?? .max <= 64 * 1_024,
              let data = try? Data(contentsOf: file),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Self.sessionID(record: record, pid: pid, birth: birth)
    }

    static func sessionID(record: [String: Any], pid: Int32, birth: Date) -> String? {
        guard (record["pid"] as? NSNumber)?.int32Value == pid, record["kind"] as? String == "interactive",
              let id = record["sessionId"] as? String, UUID(uuidString: id) != nil else { return nil }
        if let recorded = record["procStart"] as? String, let start = Self.processStart(recorded) {
            return abs(start.timeIntervalSince(birth)) < 1.5 ? id : nil
        }
        // Without a start in a known form, Claude's own start time must fall just after the birth.
        guard let started = (record["startedAt"] as? NSNumber)?.doubleValue else { return nil }
        let offset = started / 1_000 - birth.timeIntervalSince1970
        return offset > -2 && offset < 120 ? id : nil
    }

    /// `ps -o lstart` in UTC, as Claude records it on macOS: `Thu Oct 15 19:17:21 2026`.
    static func processStart(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
}
