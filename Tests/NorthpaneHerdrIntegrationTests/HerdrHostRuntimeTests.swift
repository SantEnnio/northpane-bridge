import Foundation
import Testing
import NorthpaneHostRuntime
import NorthpaneProtocol
@testable import NorthpaneHerdrIntegration

@Test func herdrAdapterBindsEveryOperationToItsSession() async throws {
    let runner = ScopedHerdrRunner()
    let runtime: any HostRuntime = HerdrHostRuntime(runner: runner, executableURL: URL(fileURLWithPath: "/unused/herdr"),
                                                   sessionName: "scope", incarnationID: "incarnation")
    let hostID = HostID()
    let snapshot = try await runtime.currentSnapshot(hostID: hostID)
    #expect(snapshot.hostID == hostID)
    #expect(snapshot.incarnationID == "incarnation")
    #expect(try await runtime.createWorkspace(label: "Work", workingDirectory: "/work", environment: ["TEST": "value"]) == CreatedPane(workspaceID: "w1", paneID: "w1:p1"))
    #expect(try await runtime.createTab(workspaceID: "w1", workingDirectory: "/work").paneID == "w1:p2")
    #expect(try await runtime.splitPane(paneID: "w1:p1", direction: .down, workingDirectory: "/work").paneID == "w1:p3")
    try await runtime.renameWorkspace(workspaceID: "w1", label: "Renamed")
    try await runtime.startAgent(.codex, executableURL: URL(fileURLWithPath: "/bin/codex"), name: "test-agent", paneID: "w1:p1")
    try await runtime.closeWorkspace(workspaceID: "w1")
    let calls = await runner.calls
    #expect(calls.allSatisfy { Array($0.prefix(2)) == ["--session", "scope"] })
    #expect(calls.contains(["--session", "scope", "workspace", "create", "--cwd", "/work", "--label", "Work", "--env", "TEST=value", "--no-focus"]))
    #expect(calls.contains(["--session", "scope", "pane", "split", "w1:p1", "--direction", "down", "--cwd", "/work", "--no-focus"]))
    #expect(calls.contains(["--session", "scope", "agent", "rename", "w1:p1", "test-agent"]))
}

private actor ScopedHerdrRunner: HerdrCommandRunning {
    private(set) var calls: [[String]] = []
    func run(arguments: [String]) -> Data {
        calls.append(arguments)
        let command = Array(arguments.dropFirst(2))
        let response: String
        switch Array(command.prefix(2)) {
        case ["api", "snapshot"]:
            response = #"{"result":{"type":"session_snapshot","snapshot":{"workspaces":[],"tabs":[],"panes":[]}}}"#
        case ["workspace", "create"]:
            response = #"{"result":{"type":"workspace_created","workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1","workspace_id":"w1"}}}"#
        case ["tab", "create"]:
            response = #"{"result":{"type":"tab_created","root_pane":{"pane_id":"w1:p2","workspace_id":"w1"}}}"#
        case ["pane", "split"]:
            response = #"{"result":{"type":"pane_info","pane":{"pane_id":"w1:p3","workspace_id":"w1"}}}"#
        default: response = "{}"
        }
        return Data(response.utf8)
    }
}
