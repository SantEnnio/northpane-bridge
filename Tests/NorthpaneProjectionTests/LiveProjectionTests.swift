import Foundation
import Testing
@testable import NorthpaneProjection
@testable import NorthpaneProtocol

@Test func aContiguousEventBatchMakesTheProjectionCurrent() throws {
    let host = HostID()
    let incarnation = HerdrSessionIncarnationID()
    var projection = LiveProjection()
    projection.begin(RuntimeSnapshot(hostID: host, incarnationID: incarnation, snapshotID: "snapshot-1", nextEventSequence: 4, panes: []))

    try projection.apply(RuntimeEventBatch(incarnationID: incarnation, snapshotID: "snapshot-1", firstSequence: 4, events: [.paneOpened(id: "pane-a", title: "Codex")]))

    #expect(projection.view.freshness == .current(snapshotID: "snapshot-1", nextSequence: 5))
    #expect(projection.view.panes.map(\.id) == ["pane-a"])
}

@Test func eventBatchIsAtomicAndExactDuplicateIsIdempotent() throws {
    let incarnation = HerdrSessionIncarnationID()
    var projection = LiveProjection()
    projection.begin(RuntimeSnapshot(hostID: HostID(), incarnationID: incarnation, snapshotID: "s", nextEventSequence: 1, panes: [Pane(id: "p", title: "Old")]))
    let batch = RuntimeEventBatch(incarnationID: incarnation, snapshotID: "s", firstSequence: 1, events: [.paneRenamed(id: "p", title: "New")])
    try projection.apply(batch)
    try projection.apply(batch)
    #expect(projection.view.panes.first?.title == "New")

    try projection.apply(RuntimeEventBatch(incarnationID: incarnation, snapshotID: "s", firstSequence: 2, events: [.paneOpened(id: "q", title: "Q"), .paneClosed(id: "missing")]))
    #expect(projection.view.freshness == .incoherent(reason: .impossibleEvent))
    #expect(!projection.view.panes.contains { $0.id == "q" })
}

@Test func closingAPaneCreatesANonActionableTombstoneAndStaleRemovesProof() throws {
    let incarnation = HerdrSessionIncarnationID()
    var projection = LiveProjection()
    projection.begin(RuntimeSnapshot(hostID: HostID(), incarnationID: incarnation, snapshotID: "s", nextEventSequence: 1, panes: [Pane(id: "p", title: "Codex")]))
    try projection.apply(RuntimeEventBatch(incarnationID: incarnation, snapshotID: "s", firstSequence: 1, events: [.paneClosed(id: "p")]))
    #expect(projection.view.tombstones.map(\.resourceID) == ["p"])
    projection.markStale()
    #expect(projection.observationProof == nil)
    #expect(projection.view.freshness == .stale)
}

@Test func anEventGapMakesTheProjectionIncoherentAndNonActionable() throws {
    let incarnation = HerdrSessionIncarnationID()
    var projection = LiveProjection()
    projection.begin(RuntimeSnapshot(hostID: HostID(), incarnationID: incarnation, snapshotID: "snapshot-1", nextEventSequence: 4, panes: []))

    try projection.apply(RuntimeEventBatch(incarnationID: incarnation, snapshotID: "snapshot-1", firstSequence: 5, events: []))

    #expect(projection.view.freshness == .incoherent(reason: .sequenceGap))
    #expect(projection.observationProof == nil)
}

@Test func wireSnapshotBuildsTheCanonicalWorkspaceTabPaneHierarchy() throws {
    let host = HostID()
    let wire = WireRuntimeSnapshot(
        hostID: host,
        incarnationID: UUID().uuidString,
        snapshotID: "snapshot",
        nextEventSequence: 9,
        panes: [.init(id: "pane", title: "Codex", workspaceID: "workspace", tabID: "tab", revision: 7, agent: "Codex", agentStatus: "blocked", focused: true)],
        capabilities: [.observeRuntime],
        workspaces: [.init(id: "workspace", label: "Northpane", number: 1, focused: true, activeTabID: "tab", worktreePath: "/redacted")],
        tabs: [.init(id: "tab", workspaceID: "workspace", label: "Implementation", number: 1, focused: true)]
    )
    var projection = LiveProjection()
    projection.begin(try RuntimeSnapshot(wire: wire))

    #expect(projection.view.workspaces.map(\.id) == ["workspace"])
    #expect(projection.view.tabs.map(\.id) == ["tab"])
    #expect(projection.view.panes.first?.revision == 7)
    #expect(projection.observationProof?.nextEventSequence == 9)
}

@Test func invalidHierarchyNeverProducesAnObservationProof() {
    var projection = LiveProjection()
    projection.begin(RuntimeSnapshot(
        hostID: HostID(),
        incarnationID: HerdrSessionIncarnationID(),
        snapshotID: "invalid",
        nextEventSequence: 1,
        panes: [Pane(id: "pane", title: "Orphan", workspaceID: "missing", tabID: "missing")],
        workspaces: [],
        tabs: []
    ))

    #expect(projection.view.freshness == .incoherent(reason: .impossibleEvent))
    #expect(projection.observationProof == nil)
}
