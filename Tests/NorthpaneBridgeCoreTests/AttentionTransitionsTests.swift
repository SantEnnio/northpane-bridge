import Foundation
import NorthpaneBridgeCore
import NorthpaneProtocol
import Testing

@Test func revisionsAndShortDipsDoNotRepeatOneBlockedRequest() {
    var tracker = AttentionTransitionTracker()
    let t = Date(timeIntervalSince1970: 100)
    func pane(_ revision: Int, _ status: String) -> WirePane {
        .init(id: "pane", title: "Agent", revision: revision, agent: "codex", agentStatus: status)
    }
    #expect(tracker.observe([pane(1, "working")], at: t).isEmpty)
    #expect(tracker.observe([pane(2, "blocked")], at: t.addingTimeInterval(1)).count == 1)
    #expect(tracker.observe([pane(50, "blocked")], at: t.addingTimeInterval(2)).isEmpty)
    #expect(tracker.observe([pane(51, "idle")], at: t.addingTimeInterval(3)).isEmpty)
    #expect(tracker.observe([pane(52, "blocked")], at: t.addingTimeInterval(3.5)).isEmpty)
    _ = tracker.observe([pane(53, "idle")], at: t.addingTimeInterval(4))
    _ = tracker.observe([pane(54, "idle")], at: t.addingTimeInterval(7))
    #expect(tracker.observe([pane(55, "blocked")], at: t.addingTimeInterval(8)).count == 1)
}

@Test func startupDoesNotNotifyForAlreadyBlockedPane() {
    var tracker = AttentionTransitionTracker()
    let existing = WirePane(id: "old", title: "Agent", agent: "claude", agentStatus: "blocked")
    let next = WirePane(id: "new", title: "Agent", agent: "claude", agentStatus: "blocked")
    #expect(tracker.observe([existing]).isEmpty)
    #expect(tracker.observe([existing, next]).map(\.id) == ["new"])
    tracker.reset()
    #expect(tracker.observe([existing, next]).isEmpty)
}
