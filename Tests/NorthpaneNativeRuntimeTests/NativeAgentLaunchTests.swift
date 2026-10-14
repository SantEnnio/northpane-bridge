#if os(macOS) || os(Linux)
import Foundation
import Testing
import NorthpaneProtocol
@testable import NorthpaneNativeRuntime

@Suite struct NativeAgentLaunchTests {
    @Test func hooksAreScopedToTheLaunchAndPreserveProviderTrustAndPermissions() throws {
        let directory = URL(fileURLWithPath: "/tmp/np-hooks-" + UUID().uuidString.prefix(10))
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = URL(fileURLWithPath: "/tmp/path with 'quote/bridge")
        let codex = try NativeAgentLaunch.options(kind: .codex, bridgeExecutable: executable, stateDirectory: directory)
        #expect(codex.arguments.contains(where: { $0.hasPrefix("hooks.PermissionRequest=") }))
        #expect(codex.environment.isEmpty)
        #expect(!codex.arguments.contains(where: { $0.contains("bypass") || $0.contains("approval_policy") || $0.contains("allow_managed") }))
        let claude = try NativeAgentLaunch.options(kind: .claude, bridgeExecutable: executable, stateDirectory: directory)
        #expect(claude.arguments.first == "--settings")
        let settings = try #require(JSONSerialization.jsonObject(with: Data(claude.arguments[1].utf8)) as? [String: Any])
        #expect(settings["disableAllHooks"] == nil && settings["permissions"] == nil)
        #expect(settings["hooks"] != nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let existing = #"{"permission":{"bash":"ask"},"plugin":["file:///existing.mjs"]}"#
        let openCode = try NativeAgentLaunch.options(kind: .openCode, bridgeExecutable: executable, stateDirectory: directory,
            environment: ["OPENCODE_CONFIG_CONTENT": existing])
        let config = try #require(JSONSerialization.jsonObject(with: Data(openCode.environment["OPENCODE_CONFIG_CONTENT"]!.utf8)) as? [String: Any])
        #expect((config["permission"] as? [String: String])?["bash"] == "ask")
        #expect((config["plugin"] as? [String])?.first == "file:///existing.mjs")
        #expect((config["plugin"] as? [String])?.count == 2)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "runtime/agent-hooks/status-v1.mjs").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "home/.config").path))
        #expect(try NativeAgentLaunch.options(kind: .codex, bridgeExecutable: nil, stateDirectory: directory).arguments.isEmpty)
    }

    @Test func foregroundAgentNamesDoNotComeFromArbitraryCommandArguments() {
        #expect(NativeForegroundAgent.kind(arguments: ["/usr/bin/echo", "codex"]) == nil)
        #expect(NativeForegroundAgent.kind(arguments: ["/usr/bin/node", "/tools/codex.js"]) == .codex)
        #expect(NativeForegroundAgent.kind(arguments: ["/usr/bin/node", "/tools/@anthropic-ai/claude-code/cli.js"]) == .claude)
        #expect(NativeForegroundAgent.kind(arguments: ["/tools/opencode"]) == .openCode)
        #expect(NativeForegroundAgent.kind(arguments: ["/bin/sh", "-c", "codex"]) == nil)
    }

    @Test(.enabled(if: NativeAgentLaunchTests.nodePath != nil))
    func openCodePluginSerializesRootEventsAndIgnoresChildSessions() throws {
        let directory = URL(fileURLWithPath: "/tmp/np-plugin-" + UUID().uuidString.prefix(10))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reporter = directory.appending(path: "reporter.sh")
        try Data("#!/bin/sh\ncat > /dev/null\nprintf '%s\\n' \"$2\" >> \"$NORTHPANE_TEST_CAPTURE\"\n".utf8).write(to: reporter)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reporter.path)
        let options = try NativeAgentLaunch.options(kind: .openCode, bridgeExecutable: reporter, stateDirectory: directory)
        let plugin = directory.appending(path: "runtime/agent-hooks/status-v1.mjs")
        let harness = directory.appending(path: "harness.mjs")
        let code = """
        import { NorthpaneStatus } from "\(plugin.absoluteString)";
        const plugin = await NorthpaneStatus({
          directory: "/tmp", client: { session: { get: async ({ path }) => ({ data: { id: path.id, parentID: path.id === "child" ? "root" : undefined } }) } }
        });
        const emit = (type, sessionID, extra = {}) => plugin.event({ event: { type, properties: { sessionID, ...extra } } });
        await emit("session.status", "child", { status: { type: "busy" } });
        await emit("session.status", "root", { status: { type: "busy" } });
        await emit("permission.asked", "root");
        await emit("permission.asked", "root");
        await emit("permission.replied", "root");
        await emit("session.idle", "root");
        await emit("permission.asked", "child");
        await emit("session.deleted", "root");
        """
        try Data(code.utf8).write(to: harness)
        let capture = directory.appending(path: "events.txt")
        let process = Process(); process.executableURL = URL(fileURLWithPath: try #require(Self.nodePath))
        process.arguments = [harness.path]; process.currentDirectoryURL = directory
        process.environment = options.environment.merging(["PATH": "/usr/bin:/bin", "HOME": directory.path,
            "NORTHPANE_TEST_CAPTURE": capture.path]) { _, value in value }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let events = try String(contentsOf: capture, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(events == ["start", "working", "blocked", "blocked", "working", "idle", "end"])
    }

    private static let nodePath = [ProcessInfo.processInfo.environment["NORTHPANE_TEST_NODE"], "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test func absentOrOversizedHookInputsCannotChangeAnyRuntime() {
        #expect(throws: NativeRuntimeProcessError.invalidConfiguration) {
            try NativeAgentHook.report(event: "blocked", input: Data("{}".utf8), environment: [:])
        }
        #expect(throws: NativeRuntimeProcessError.invalidConfiguration) {
            try NativeAgentHook.report(event: "blocked", input: Data(repeating: 65, count: 65_537), environment: [:])
        }
    }
}
#endif
