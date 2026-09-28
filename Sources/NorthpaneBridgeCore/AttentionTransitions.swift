import Foundation
import NorthpaneProtocol

/// Follows Herdr's blocked periods rather than Pane revisions. Herdr increments revision during
/// ordinary redraws; publishing on every increment floods APNs for one unanswered question.
/// A newly started watcher uses its first complete snapshot as a baseline instead of treating
/// old requests as fresh notifications after every process restart.
public struct AttentionTransitionTracker: Sendable {
    private var observed = false
    private var blocked: Set<String> = []
    private var dips: [String: Date] = [:]
    private let grace: TimeInterval

    public init(grace: TimeInterval = 2) { self.grace = grace }

    public mutating func observe(_ panes: [WirePane], at now: Date = Date()) -> [WirePane] {
        let live = Set(panes.map(\.id))
        blocked.formIntersection(live)
        dips = dips.filter { live.contains($0.key) }
        guard observed else {
            observed = true
            blocked = Set(panes.filter { $0.agentStatus == "blocked" && $0.agent != nil }.map(\.id))
            return []
        }
        var arrived: [WirePane] = []
        for pane in panes {
            if pane.agentStatus == "blocked", pane.agent != nil {
                dips.removeValue(forKey: pane.id)
                if blocked.insert(pane.id).inserted { arrived.append(pane) }
            } else if blocked.contains(pane.id) {
                let since = dips[pane.id] ?? now
                dips[pane.id] = since
                if now.timeIntervalSince(since) >= grace {
                    blocked.remove(pane.id)
                    dips.removeValue(forKey: pane.id)
                }
            }
        }
        return arrived
    }

    public mutating func reset() {
        observed = false
        blocked.removeAll()
        dips.removeAll()
    }
}
