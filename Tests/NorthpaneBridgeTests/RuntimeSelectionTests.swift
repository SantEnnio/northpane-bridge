import Foundation
import Testing
import NorthpaneHostRuntime
import NorthpaneHerdrIntegration
import NorthpaneProtocol
@testable import NorthpaneBridge

@Test func runtimeDiscoveryRemainsAvailableWithoutAnExecutable() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-runtime-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try await BridgeHostContext(stateDirectory: directory, runtimeFactory: { sessionName, incarnationID in
        try HerdrHostRuntime(executableURL: URL(fileURLWithPath: "/not-an-executable"), sessionName: sessionName,
                             incarnationID: incarnationID)
    })
    // Discovery is allowed before the Host has a runtime executable installed.
    #expect(await context.detectedHerdrVersion() == "unavailable")
}

@Test func runtimeScopesUseSeparateAdaptersAndKeepTheirState() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-runtime-scopes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try await BridgeHostContext(stateDirectory: directory, runtimeFactory: { _, _ in FakeHostRuntime() })
    let created = try await context.createWorkspace(label: "First", workingDirectory: directory.appending(path: "work").path,
                                                   agentKind: .shell, sessionName: "first")
    let first = try await context.currentSnapshot(sessionName: "first")
    let second = try await context.currentSnapshot(sessionName: "second")
    #expect(first.workspaces.first?.id == created.workspaceID)
    #expect(second.workspaces.isEmpty)
    #expect(first.incarnationID != second.incarnationID)
    let firstAgain = try await context.currentSnapshot(sessionName: "first")
    #expect(firstAgain.incarnationID == first.incarnationID)
    #expect(firstAgain.workspaces == first.workspaces)
}
