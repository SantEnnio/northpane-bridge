import Foundation
import Testing
import NorthpaneHostRuntime
import NorthpaneProtocol
@testable import NorthpaneBridge

@Test func paneConversationResolutionPersistsExplicitChoiceAndPrefersNativeReference() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = FakeHostRuntime()
    let created = await runtime.createWorkspace(label: "Fixture", workingDirectory: "/fixture", environment: [:])
    try await runtime.startAgent(.codex, executableURL: URL(fileURLWithPath: "/unused"), name: "fixture", paneID: created.paneID)
    await runtime.setConversationReference(.init(agent: "codex", processProof: "pid:birth"))
    let spy = ConversationReaderSpy()
    let context = try await BridgeHostContext(stateDirectory: directory, conversationReader: { request, _ in await spy.read(request) }, runtimeFactory: { _, _ in runtime })
    let incarnation = runtime.descriptor.incarnationID
    let missing = await context.readConversation(.init(agent: .codex, resolvePaneSession: true), paneID: created.paneID, incarnationID: incarnation, sessionName: "scope")
    #expect(missing.problem == .paneNotLinked && missing.sessions.isEmpty)
    #expect(await spy.requests.isEmpty)
    let chosen = await context.readConversation(.init(agent: .codex, endpoint: "/existing.sock", sessionID: "explicit", associatePaneSession: true), paneID: created.paneID, incarnationID: incarnation, sessionName: "scope")
    #expect(chosen.problem == nil)
    let other = try await BridgeHostContext(stateDirectory: directory, conversationReader: { request, _ in await spy.read(request) }, runtimeFactory: { _, _ in runtime })
    let resolved = await other.readConversation(.init(agent: .codex, resolvePaneSession: true), paneID: created.paneID, incarnationID: incarnation, sessionName: "scope")
    #expect(resolved.sessionID == "explicit" && resolved.problem == nil)
    #expect(await spy.requests.last?.endpoint == "/existing.sock")
    await runtime.setConversationReference(.init(agent: "codex", sessionID: "native-new", processProof: "pid:birth"))
    let native = await other.readConversation(.init(agent: .codex, resolvePaneSession: true), paneID: created.paneID, incarnationID: incarnation, sessionName: "scope")
    #expect(native.sessionID == "native-new")
    #expect(await spy.requests.last?.endpoint == "")
    await runtime.setConversationReference(.init(agent: "codex", processProof: "pid:new-birth"))
    let reused = await other.readConversation(.init(agent: .codex, resolvePaneSession: true), paneID: created.paneID, incarnationID: incarnation, sessionName: "scope")
    #expect(reused.problem == .paneNotLinked && reused.items.isEmpty)
    let stale = await other.readConversation(.init(agent: .codex, resolvePaneSession: true), paneID: created.paneID, incarnationID: "stale", sessionName: "scope")
    #expect(stale.problem != nil && stale.items.isEmpty)
}

@Test func paneConversationDoesNotSaveOrPublishReadingAfterProcessChanges() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = FakeHostRuntime()
    let created = await runtime.createWorkspace(label: "Fixture", workingDirectory: "/fixture", environment: [:])
    try await runtime.startAgent(.codex, executableURL: URL(fileURLWithPath: "/unused"), name: "fixture", paneID: created.paneID)
    await runtime.setConversationReference(.init(agent: "codex", processProof: "before"))
    let context = try await BridgeHostContext(stateDirectory: directory, conversationReader: { request, _ in
        await runtime.setConversationReference(.init(agent: "codex", processProof: "after"))
        return .init(agent: request.agent, sessionID: request.sessionID)
    }, runtimeFactory: { _, _ in runtime })
    let incarnation = runtime.descriptor.incarnationID
    let raced = await context.readConversation(.init(agent: .codex, sessionID: "explicit", associatePaneSession: true), paneID: created.paneID, incarnationID: incarnation, sessionName: nil)
    #expect(raced.problem == .paneNotLinked && raced.items.isEmpty)
    await runtime.setConversationReference(.init(agent: "codex", processProof: "before"))
    let after = await context.readConversation(.init(agent: .codex, resolvePaneSession: true), paneID: created.paneID, incarnationID: incarnation, sessionName: nil)
    #expect(after.problem == .paneNotLinked)
}

private actor ConversationReaderSpy {
    private(set) var requests: [AgentConversationRequest] = []
    func read(_ request: AgentConversationRequest) -> AgentConversationReading {
        requests.append(request)
        return .init(agent: request.agent, sessionID: request.sessionID)
    }
}
