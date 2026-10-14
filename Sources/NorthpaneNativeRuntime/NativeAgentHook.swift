#if os(macOS) || os(Linux)
import Foundation
import Crypto

/// Only the bounded identity/status subset of a provider hook is decoded. Tool
/// input, prompts, messages and transcript paths are never sent or persisted.
public enum NativeAgentHook {
    public static func report(event: String, input: Data,
                              environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard input.count <= 65_536, let pane = environment["NORTHPANE_PANE_ID"],
              let proof = environment["NORTHPANE_PROCESS_PROOF"], UUID(uuidString: proof) != nil,
              let path = environment["NORTHPANE_RUNTIME_SOCKET"], path.hasPrefix("/"),
              let object = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let session = object["session_id"] as? String else { throw NativeRuntimeProcessError.invalidConfiguration }
        // Provider subagents inherit the parent's environment, but cannot report
        // their own lifecycle as the root conversation's lifecycle.
        if let agent = object["agent_id"] as? String, !agent.isEmpty { return }
        if let parent = object["parent_session_id"] as? String, !parent.isEmpty { return }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
        let connection = try NativeRuntimeConnection.connectSynchronously(stateDirectory: directory)
        defer { connection.close() }
        let phase = event == "start" && object["source"] as? String == "compact" ? "working" : event
        try connection.reportHook(paneID: pane, proof: proof, event: phase, sessionID: session,
            directory: object["cwd"] as? String ?? "", requestProof: requestProof(object))
    }

    private static func requestProof(_ object: [String: Any]) -> String {
        let data: Data?
        if let id = (object["request_id"] ?? object["tool_use_id"]) as? String, !id.isEmpty {
            data = Data(("id:" + id).utf8)
        } else if let tool = object["tool_name"] as? String, let input = object["tool_input"] {
            data = try? JSONSerialization.data(withJSONObject: ["tool": tool, "input": input], options: [.sortedKeys])
        } else { data = nil }
        guard let data else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension NativeRuntimeConnection {
    func reportHook(paneID: String, proof: String, event: String, sessionID: String, directory: String = "", requestProof: String = "") throws {
        guard status.agentHooks else { throw NativeRuntimeProcessError.rejected("agent_hooks_unavailable") }
        var request = Northpane_Runtime_V1_Request(); request.id = 8
        request.agentHook.paneID = paneID; request.agentHook.processProof = proof
        request.agentHook.event = event; request.agentHook.sessionID = sessionID; request.agentHook.workingDirectory = directory; request.agentHook.requestProof = requestProof
        let response = try socket.exchange(request)
        if case let .failure(failure) = response.outcome { throw NativeRuntimeProcessError.rejected(failure.code) }
        guard case .acknowledged = response.outcome else { throw NativeRuntimeProcessError.invalidFrame }
    }
}
#endif
