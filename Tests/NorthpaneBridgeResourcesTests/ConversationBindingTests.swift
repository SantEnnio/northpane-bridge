import Foundation
import Testing
import NorthpaneProtocol
@testable import NorthpaneBridgeResources

@Test func conversationChoiceSurvivesConnectionsButNotProcessOrScopeReuse() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = Data(repeating: 7, count: 32)
    let first = ConversationBindingStore(directory: directory, encryptionKey: key)
    let choice = ConversationBindingStore.Binding(sessionID: "explicit-session", endpoint: "/existing.sock")
    try first.save(choice, scope: "scope", paneID: "pane", agent: "codex", processProof: "pid:birth")
    let otherConnection = ConversationBindingStore(directory: directory, encryptionKey: key)
    #expect(try otherConnection.read(scope: "scope", paneID: "pane", agent: "codex", processProof: "pid:birth") == choice)
    #expect(try otherConnection.read(scope: "scope", paneID: "pane", agent: "codex", processProof: "pid:new-birth") == nil)
    #expect(try otherConnection.read(scope: "other", paneID: "pane", agent: "codex", processProof: "pid:birth") == nil)
    #expect(try otherConnection.read(scope: "scope", paneID: "pane", agent: "claude", processProof: "pid:birth") == nil)
    #expect(try otherConnection.read(scope: "scope", paneID: "pane", agent: "codex", processProof: "") == nil)
    #expect(try otherConnection.read(scope: "scope", paneID: "pane", agent: "codex", processProof: "pid:birth", now: choice.savedAt.addingTimeInterval(31 * 86_400)) == nil)
    let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
    #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("explicit-session"))
}

@Test func oldConversationJSONDoesNotOptIntoPaneBinding() throws {
    let old = try JSONDecoder().decode(AgentConversationRequest.self, from: Data(#"{"agent":"codex","endpoint":"","sessionID":"chosen","limit":5}"#.utf8))
    #expect(old.resolvePaneSession == nil && old.associatePaneSession == nil)
    let next = AgentConversationRequest(agent: .codex, resolvePaneSession: true)
    #expect(try JSONDecoder().decode(AgentConversationRequest.self, from: JSONEncoder().encode(next)) == next)
}
