#if os(macOS) || os(Linux)
import Foundation
import NorthpaneProtocol

/// Per-process advisory hooks. This never edits a provider's global/project
/// configuration, changes permissions, or bypasses the provider's hook trust.
struct NativeAgentLaunch {
    var arguments: [String] = []
    var environment: [String: String] = [:]

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func jsonString(_ value: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func options(kind: WorkspaceAgentKind, bridgeExecutable: URL?, stateDirectory: URL,
                        environment: [String: String] = [:]) throws -> Self {
        guard let bridgeExecutable, kind != .shell else { return .init() }
        let command = shellQuote(bridgeExecutable.path) + " hook "
        let events: [(String, String)] = [
            ("SessionStart", "start"), ("UserPromptSubmit", "working"),
            ("PermissionRequest", "blocked"), ("PostToolUse", "working"),
            ("Stop", "idle"), ("SessionEnd", "end")
        ]
        switch kind {
        case .codex:
            var arguments: [String] = []
            for (event, state) in events + [("Interrupt", "idle")] {
                let value = "[{ hooks = [{ type = \"command\", command = " + (try jsonString(command + state)) + ", timeout = 2 }] }]"
                arguments += ["-c", "hooks.\(event)=" + value]
            }
            // Codex reviews these session hooks using its normal /hooks flow.
            // Disabled/untrusted hooks leave status unknown; no bypass flags.
            return .init(arguments: arguments)
        case .claude:
            var hooks: [String: [[String: Any]]] = [:]
            for (event, state) in events + [("StopFailure", "idle"), ("PostToolUseFailure", "working")] {
                hooks[event] = [["hooks": [["type": "command", "command": command + state, "timeout": 2]]]]
            }
            hooks["PreToolUse"] = [["matcher": "AskUserQuestion|ExitPlanMode", "hooks": [["type": "command", "command": command + "blocked", "timeout": 2]]]]
            let data = try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.sortedKeys, .withoutEscapingSlashes])
            return .init(arguments: ["--settings", String(decoding: data, as: UTF8.self)])
        case .openCode:
            let directory = stateDirectory.appending(path: "runtime/agent-hooks", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let plugin = directory.appending(path: "status-v1.mjs")
            let data = Data(openCodePlugin.utf8)
            if (try? Data(contentsOf: plugin)) != data {
                try data.write(to: plugin, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plugin.path)
            }
            var inline: [String: Any] = [:]
            if let existing = environment["OPENCODE_CONFIG_CONTENT"], !existing.isEmpty {
                guard let data = existing.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NativeRuntimeProcessError.invalidConfiguration
                }
                inline = object
            }
            var plugins = inline["plugin"] as? [Any] ?? []
            if !plugins.contains(where: { ($0 as? String) == plugin.absoluteString }) { plugins.append(plugin.absoluteString) }
            inline["plugin"] = plugins
            let config = try JSONSerialization.data(withJSONObject: inline, options: [.sortedKeys, .withoutEscapingSlashes])
            return .init(environment: ["OPENCODE_CONFIG_CONTENT": String(decoding: config, as: UTF8.self),
                "NORTHPANE_HOOK_EXECUTABLE": bridgeExecutable.path])
        case .shell: return .init()
        }
    }

    // Local file module; no downloaded package and no transcript/model calls.
    static let openCodePlugin = #"""
    import { spawn } from "node:child_process";
    export const NorthpaneStatus = async ({ client, directory }) => {
      let root;
      let serial = Promise.resolve();
      const report = (state, id, request) => new Promise(resolve => {
        const executable = process.env.NORTHPANE_HOOK_EXECUTABLE;
        if (!executable) return resolve();
        const child = spawn(executable, ["hook", state], { stdio: ["pipe", "ignore", "ignore"] });
        const timeout = setTimeout(() => { child.kill(); resolve(); }, 2000);
        child.on("error", () => { clearTimeout(timeout); resolve(); });
        child.on("exit", () => { clearTimeout(timeout); resolve(); });
        child.stdin.on("error", () => {});
        child.stdin.end(JSON.stringify({ session_id: id, cwd: directory, request_id: request }));
      });
      return { event: ({ event }) => {
        serial = serial.then(async () => {
          const p = event.properties ?? {};
          const id = p.sessionID ?? p.info?.id;
          if (!id) return;
          if (!root) {
            const response = p.info ? { data: p.info } : await client.session.get({ path: { id } });
            if (!response.data || response.data.parentID) return;
            root = id;
            await report("start", id);
          }
          if (id !== root) return;
          const state = event.type === "permission.asked" || event.type === "question.asked" ? "blocked"
            : event.type === "permission.replied" || event.type === "question.replied" || event.type === "question.rejected" ? "working"
            : event.type === "session.idle" || event.type === "session.error" ? "idle"
            : event.type === "session.status" ? (p.status?.type === "idle" ? "idle" : ["busy", "retry"].includes(p.status?.type) ? "working" : undefined)
            : event.type === "session.deleted" ? "end" : undefined;
          if (state) await report(state, id, p.requestID ?? p.id);
        }).catch(() => {});
        return serial;
      }};
    };
    """#
}
#endif
