import Foundation
import Testing
@testable import NorthpaneHerdrIntegration
@testable import NorthpaneProtocol

@Test func herdr082FixtureNormalizesSnapshotAndEvents() throws {
    let host = HostID()
    let incarnation = UUID()
    let snapshot = Data("{\"sessionIncarnation\":\"\(incarnation.uuidString)\",\"snapshotID\":\"s1\",\"nextSequence\":4,\"panes\":[{\"id\":\"p1\",\"title\":\"Codex\"}]}".utf8)
    let events = Data("{\"sessionIncarnation\":\"\(incarnation.uuidString)\",\"snapshotID\":\"s1\",\"firstSequence\":4,\"events\":[{\"type\":\"pane.renamed\",\"id\":\"p1\",\"title\":\"Review\"}]}".utf8)
    let adapter = Herdr082Adapter()

    let normalizedSnapshot = try adapter.decodeSnapshot(snapshot, hostID: host)
    let normalizedEvents = try adapter.decodeEvents(events)

    #expect(normalizedSnapshot.panes.first?.title == "Codex")
    #expect(normalizedEvents.firstSequence == 4)
    #expect(normalizedEvents.events == [.paneRenamed(id: "p1", title: "Review")])
}

@Test func secondSnapshotMustMatchToActAsABarrier() throws {
    let adapter = Herdr082Adapter()
    let host = HostID()
    let incarnation = UUID()
    let first = try adapter.decodeSnapshot(Data("{\"sessionIncarnation\":\"\(incarnation.uuidString)\",\"snapshotID\":\"a\",\"nextSequence\":1,\"panes\":[]}".utf8), hostID: host)
    let second = try adapter.decodeSnapshot(Data("{\"sessionIncarnation\":\"\(incarnation.uuidString)\",\"snapshotID\":\"b\",\"nextSequence\":1,\"panes\":[]}".utf8), hostID: host)

    #expect(throws: HerdrAdapterError.barrierMismatch) { try adapter.verifyBarrier(first: first, second: second) }
}
