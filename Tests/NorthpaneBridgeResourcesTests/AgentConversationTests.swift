import Foundation
import NorthpaneProtocol
import Testing
@testable import NorthpaneBridgeResources

@Test func agentConversationCodexPreservesIDsAndAuthoritativeDiffCounts() {
    let items = AgentConversationReader.codexItems(turns: [["id": "turn", "status": "completed", "items": [
        ["id": "user", "type": "userMessage", "content": [["type": "text", "text": "Hello"]]],
        ["id": "change", "type": "fileChange", "status": "completed", "changes": [["path": "test.swift", "diff": "--- a\n+++ b\n@@ -1 +1,2 @@\n-old\n+new\n+extra"]]],
        ["id": "unknown", "type": "futureTool", "arguments": ["value": "safe"]]
    ]]])
    #expect(items.map(\.id) == ["user", "change:0", "unknown"])
    #expect(items[1].added == 2 && items[1].removed == 1)
    #expect(items[2].kind == .activity)
}

@Test func agentConversationDiffCountsDoNotGuessFromFullFileContents() {
    #expect(AgentConversationReader.unifiedDiffCounts("import Foundation\nlet value = 1\n") == nil)
    let counts = AgentConversationReader.unifiedDiffCounts("--- a\n+++ b\n@@ -1 +1 @@\n---old\n+++new\n")
    #expect(counts?.added == 1 && counts?.removed == 1)
}

@Test func agentConversationBoundsMetadataWithoutChangingSessionIdentity() throws {
    let sessions = (0..<50).map { AgentConversationSession(id: "session-\($0)", title: String(repeating: "\u{0}", count: 512),
        directory: String(repeating: "\u{0}", count: 4096), loaded: true) }
    let reading = AgentConversationReader.bounded(.init(agent: .codex, sessionID: "selected", sessions: sessions))
    #expect(reading.problem == .outputTooLarge)
    #expect(reading.sessionID == "selected")
    #expect(try JSONEncoder().encode(reading).count < 768 * 1_024)
}

@Test func agentConversationClaudeDoesNotPresentToolResultsAsUserMessages() {
    let items = AgentConversationReader.claudeItems(messages: [["uuid": "message", "type": "user", "message": ["content": [
        ["type": "tool_result", "tool_use_id": "tool", "content": "output"],
        ["type": "text", "text": "Continue"]
    ]]]])
    #expect(items.map(\.kind) == [.activity, .user])
}

@Test func agentConversationBoundsEscapedJSONAndKeepsNewestIdentity() throws {
    let items = (0..<100).map { AgentConversationItem(id: "item-\($0)", turnID: "turn", kind: .activity,
        text: String(repeating: "\u{0}", count: 50_000)) }
    let reading = AgentConversationReader.bounded(.init(agent: .codex, items: items + [items.last!]))
    #expect(reading.truncated)
    #expect(reading.items.last?.id == "item-99")
    #expect(Set(reading.items.map(\.id)).count == reading.items.count)
    #expect(try JSONEncoder().encode(reading).count < 768 * 1_024)
}

@Test func agentConversationRejectsRemoteEndpointsWithoutConnecting() async {
    let reading = await AgentConversationReader.read(.init(agent: .opencode, endpoint: "http://example.com:80"), directory: "")
    #if os(macOS) || os(Linux)
    #expect(reading.problem == .invalidEndpoint)
    #else
    #expect(reading.problem == .unsupportedVersion)
    #endif
}

@Test func agentConversationLiveCodexObservation() async throws {
    guard ProcessInfo.processInfo.environment["NORTHPANE_TEST_OBSERVE_CODEX"] == "1" else { return }
    let directory = ProcessInfo.processInfo.environment["NORTHPANE_TEST_CONVERSATION_DIRECTORY"] ?? ""
    let sessions = await AgentConversationReader.read(.init(agent: .codex), directory: directory)
    #expect(sessions.problem == nil)
    print("Observer candidates:", sessions.sessions.map { ($0.id, $0.title, $0.loaded) })
    guard let id = ProcessInfo.processInfo.environment["NORTHPANE_TEST_CONVERSATION_ID"] else { return }
    let request = AgentConversationRequest(agent: .codex, sessionID: id, limit: 2)
    let first = await AgentConversationReader.read(request, directory: directory)
    let second = await AgentConversationReader.read(request, directory: directory)
    #expect(first.problem == nil && second.problem == nil)
    #expect(!first.items.isEmpty)
    #expect(first.sessionID == id && second.sessionID == id)
    #expect(Set(second.items.map(\.id)).count == second.items.count)
    print("Observed items:", second.items.count, "source:", second.source)
}
