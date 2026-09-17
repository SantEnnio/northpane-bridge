import Foundation
import Testing
@testable import NorthpaneProtocol

private func snapshot(revision: Int, status: String = "idle", id: String = UUID().uuidString) -> WireRuntimeSnapshot {
    WireRuntimeSnapshot(hostID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), incarnationID: "inc-1", snapshotID: id, nextEventSequence: revision,
        panes: [WirePane(id: "w1:p1", title: "shell", workspaceID: "w1", tabID: "w1:t1", revision: revision, agent: "codex", agentStatus: status, focused: true, cwd: "/tmp")],
        capabilities: [.observeRuntime], workspaces: [WireWorkspace(id: "w1", label: "one", number: 1, focused: true, activeTabID: "w1:t1")], tabs: [WireTab(id: "w1:t1", workspaceID: "w1", label: "t", number: 1, focused: true)])
}

@Test func revisionOnlyChurnKeepsTheSnapshotShape() {
    #expect(snapshot(revision: 1).hasSameShape(as: snapshot(revision: 57)))
}

@Test func statusOrMembershipChangesAlterTheShape() {
    #expect(!snapshot(revision: 1).hasSameShape(as: snapshot(revision: 1, status: "blocked")))
    let base = snapshot(revision: 1)
    let extra = WireRuntimeSnapshot(hostID: base.hostID, incarnationID: base.incarnationID, snapshotID: "x", nextEventSequence: 1, panes: base.panes + [WirePane(id: "w1:p2", title: "two", workspaceID: "w1", tabID: "w1:t1")], capabilities: base.capabilities, workspaces: base.workspaces, tabs: base.tabs)
    #expect(!base.hasSameShape(as: extra))
}
