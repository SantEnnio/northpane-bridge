#if os(macOS) || os(Linux)
import Foundation
import NorthpaneHostRuntime
import NorthpaneProtocol
#if os(macOS)
import Darwin
#endif

/// Reads only the foreground group's executable/launcher arguments. It neither
/// scans terminal content nor reads provider credentials or conversation files.
enum NativeForegroundAgent {
    struct Identity {
        let kind: WorkspaceAgentKind
        let birth: String
    }
    static func identify(pid: Int32) -> Identity? {
        guard let before = ProcessBirth.proof(pid: pid), let arguments = arguments(pid: pid),
              let kind = kind(arguments: arguments), ProcessBirth.proof(pid: pid) == before else { return nil }
        return Identity(kind: kind, birth: before + ":" + kind.rawValue)
    }
    static func kind(arguments: [String]) -> WorkspaceAgentKind? {
        guard let executable = arguments.first else { return nil }
        func named(_ path: String) -> WorkspaceAgentKind? {
            switch URL(fileURLWithPath: path).lastPathComponent {
            case "codex", "codex.js": .codex
            case "claude", "claude.js": .claude
            case "opencode": .openCode
            default: nil
            }
        }
        if let kind = named(executable) { return kind }
        let launcher = URL(fileURLWithPath: executable).lastPathComponent
        guard ["node", "bun", "sh", "bash", "zsh"].contains(launcher), arguments.count > 1 else { return nil }
        let script = arguments[1]
        if let kind = named(script) { return kind }
        if script.hasSuffix("/@anthropic-ai/claude-code/cli.js") { return .claude }
        return nil
    }
    private static func arguments(pid: Int32) -> [String]? {
        #if os(macOS)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0 else { return nil }
        var offset = 4
        while offset < size, bytes[offset] != 0 { offset += 1 }
        while offset < size, bytes[offset] == 0 { offset += 1 }
        var result: [String] = []
        for _ in 0..<min(Int(count), 2) {
            let begin = offset
            while offset < size, bytes[offset] != 0 { offset += 1 }
            if begin < offset { result.append(String(decoding: bytes[begin..<offset], as: UTF8.self)) }
            offset += 1
        }
        return result
        #else
        guard let file = FileHandle(forReadingAtPath: "/proc/\(pid)/cmdline") else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 65_536) else { return nil }
        return bytes.split(separator: 0).prefix(2).map { String(decoding: $0, as: UTF8.self) }
        #endif
    }
}
#endif
