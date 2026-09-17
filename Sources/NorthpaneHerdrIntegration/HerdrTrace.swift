import Foundation

/// Diagnostic lines on standard error, only when NORTHPANE_TRACE=1. For following the Bridge's
/// conversation with Herdr on a Host where no debugger is at hand; never on by default, and never
/// carrying terminal content.
public enum HerdrTrace {
    public static let enabled = ProcessInfo.processInfo.environment["NORTHPANE_TRACE"] == "1"

    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("northpane-trace \(stamp) \(message())\n".utf8))
    }
}
