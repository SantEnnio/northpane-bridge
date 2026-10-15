#if os(macOS) || os(Linux)
import Foundation
import Crypto
import NorthpaneEmbeddedReader

/// The helper and its JS runtime are bytes inside this exact Bridge binary.
/// Content-addressed extraction keeps updates and rollback independent. Nothing
/// is fetched from the network or loaded from a Workspace at runtime.
enum BundledClaudeReader {
    private static let lock = NSLock()
    static var isEmbedded: Bool { np_claude_reader_size() > 0 }
    static var environment: [String: String] {
        ["BUN_BE_BUN": linuxRuntime ? "1" : "0", "BUN_OPTIONS": "", "NODE_OPTIONS": "",
         "BUN_JSC_useJIT": "1", "LD_PRELOAD": "", "LD_LIBRARY_PATH": ""]
    }
    private static var linuxRuntime: Bool {
        #if os(Linux)
        true
        #else
        false
        #endif
    }

    fileprivate static var companions: [String: Data] {
        var result: [String: Data] = [:]
        for (index, name) in ["reader.mjs", "ld-musl.so", "libgcc_s.so.1", "libstdc++.so.6"].enumerated() {
            guard let pointer = np_claude_reader_asset_data(Int32(index)), np_claude_reader_asset_size(Int32(index)) > 0 else { continue }
            result[name] = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer),
                                count: np_claude_reader_asset_size(Int32(index)), deallocator: .none)
        }
        #if arch(x86_64)
        result["libc.musl-x86_64.so.1"] = result["ld-musl.so"]
        #else
        result["libc.musl-aarch64.so.1"] = result["ld-musl.so"]
        #endif
        return result
    }

    static func invocation(_ reader: URL, arguments: [String]) -> (executable: URL, arguments: [String]) {
        guard linuxRuntime else { return (reader, arguments) }
        let directory = reader.deletingLastPathComponent()
        // In CLI mode Bun does not look for its compiled graph through
        // /proc/self/exe, which points to the musl loader in this invocation.
        return (directory.appendingPathComponent("ld-musl.so"),
            ["--library-path", directory.path, reader.path, "--no-env-file", "--config=/dev/null", "--no-install",
             directory.appendingPathComponent("reader.mjs").path] + arguments)
    }

    static func executable() throws -> URL? {
        guard isEmbedded, let pointer = np_claude_reader_data() else { return nil }
        let payload = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer),
                           count: np_claude_reader_size(), deallocator: .none)
        let state = ProcessInfo.processInfo.environment["NORTHPANE_STATE_DIRECTORY"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".northpane", isDirectory: true)
        let root = state.appendingPathComponent("integrations/claude-reader/bundled", isDirectory: true)
        return try lock.withLock { try install(payload: payload, root: root, companions: companions) }
    }

    static func install(payload: Data, root: URL, companions: [String: Data] = [:]) throws -> URL {
        let files = companions.merging(["northpane-claude-reader": payload]) { _, reader in reader }
        var fingerprint = SHA256()
        for name in files.keys.sorted() {
            fingerprint.update(data: Data(name.utf8))
            fingerprint.update(data: Data(SHA256.hash(data: files[name]!)))
        }
        let digest = fingerprint.finalize().map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        for (name, bytes) in files {
            try installFile(bytes, at: directory.appendingPathComponent(name))
        }
        return directory.appendingPathComponent("northpane-claude-reader")
    }

    private static func installFile(_ payload: Data, at file: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        // Do not follow a symlink or accept corrupted cached code. Atomic writes
        // also recover an interrupted extraction without touching other versions.
        if attributes?[.type] as? FileAttributeType == .typeRegular,
           attributes?[.size] as? Int == payload.count,
           let existing = try? Data(contentsOf: file, options: .mappedIfSafe),
           SHA256.hash(data: existing) == SHA256.hash(data: payload) {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return
        }
        try payload.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
}

public extension AgentConversationReader {
    /// Packaging gate: runs only the embedded helper's version probe in a fresh
    /// temporary directory, without reading sessions or changing Host state.
    static func checkBundledClaudeReader() -> Bool {
        guard BundledClaudeReader.isEmbedded, let pointer = np_claude_reader_data() else { return false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let payload = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer),
                               count: np_claude_reader_size(), deallocator: .none)
            let reader = try BundledClaudeReader.install(payload: payload, root: directory, companions: BundledClaudeReader.companions)
            let invocation = BundledClaudeReader.invocation(reader, arguments: ["--version"])
            let environment = BundledClaudeReader.environment.merging(["PATH": "/nonexistent"]) { _, value in value }
            let pipe = try AgentCLIConversation(executable: invocation.executable, arguments: invocation.arguments,
                                                environment: environment, timeout: 12)
            defer { pipe.finish() }
            guard let line = pipe.nextLine(), let version = try JSONSerialization.jsonObject(with: line) as? [String: String] else { return false }
            return version["sdk"] == "0.3.293" && version["runtime"] == "1.3.10"
        } catch { return false }
    }
}
#endif
