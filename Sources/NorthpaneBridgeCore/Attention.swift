import Foundation
import NorthpaneProtocol
import NorthpaneProjection

public enum AttentionKind: String, Codable, Sendable { case confirmation, choice, text, secret }
public enum AttentionPriority: Int, Codable, Sendable { case normal, high }

public struct AttentionItem: Equatable, Codable, Sendable {
    public let hostID: HostID
    public let id: String
    public let revision: Int
    public let proof: ObservationProof
    public let agentIncarnationID: String
    public let kind: AttentionKind
    public let priority: AttentionPriority
    public let createdAt: Date
    public let expiresAt: Date

    public init(hostID: HostID, id: String, revision: Int, proof: ObservationProof, agentIncarnationID: String = "unknown", kind: AttentionKind = .text, priority: AttentionPriority = .normal, createdAt: Date = Date(), expiresAt: Date = .distantFuture) {
        self.hostID = hostID; self.id = id; self.revision = revision; self.proof = proof; self.agentIncarnationID = agentIncarnationID; self.kind = kind; self.priority = priority; self.createdAt = createdAt; self.expiresAt = expiresAt
    }
}

public enum AttentionActionability: Equatable, Sendable { case actionable, superseded, staleObservation, expired, resolved, unknown }
public enum AttentionResolution: Equatable, Sendable { case resolved, rejected(AttentionActionability) }

public struct ActivityUpdate: Equatable, Codable, Sendable {
    public let agentIncarnationID: String
    public let summary: String
    public let occurredAt: Date
    public init(agentIncarnationID: String, summary: String, occurredAt: Date = Date()) { self.agentIncarnationID = agentIncarnationID; self.summary = summary; self.occurredAt = occurredAt }
}

public struct AttentionStore: Sendable {
    public let hostID: HostID
    private var current: [String: AttentionItem] = [:]
    private var resolved: Set<String> = []
    private var activity: [ActivityUpdate] = []
    public init(hostID: HostID) { self.hostID = hostID }
    public var items: [AttentionItem] { current.values.sorted {
        if $0.priority != $1.priority { return $0.priority.rawValue > $1.priority.rawValue }
        return $0.createdAt < $1.createdAt
    } }
    public var recentActivity: [ActivityUpdate] { activity }
    @discardableResult public mutating func publish(id: String, revision: Int, proof: ObservationProof, agentIncarnationID: String = "unknown", kind: AttentionKind = .text, priority: AttentionPriority = .normal, createdAt: Date = Date(), expiresAt: Date = .distantFuture) -> AttentionItem {
        if let existing = current[id], existing.revision >= revision { return existing }
        let item = AttentionItem(hostID: hostID, id: id, revision: revision, proof: proof, agentIncarnationID: agentIncarnationID, kind: kind, priority: priority, createdAt: createdAt, expiresAt: expiresAt)
        current[id] = item
        resolved.remove(id)
        return item
    }
    public func actionability(of item: AttentionItem, against proof: ObservationProof, now: Date = Date()) -> AttentionActionability {
        guard item.hostID == hostID else { return .unknown }
        if resolved.contains(item.id) { return .resolved }
        guard let canonical = current[item.id] else { return .unknown }
        guard item.proof == proof else { return .staleObservation }
        guard canonical.revision == item.revision else { return .superseded }
        return canonical.expiresAt >= now ? .actionable : .expired
    }
    public mutating func resolve(_ item: AttentionItem, against proof: ObservationProof, now: Date = Date()) -> AttentionResolution {
        let state = actionability(of: item, against: proof, now: now)
        guard state == .actionable else { return .rejected(state) }
        current.removeValue(forKey: item.id)
        resolved.insert(item.id)
        return .resolved
    }
    public mutating func endAgentIncarnation(_ id: String) {
        current = current.filter { $0.value.agentIncarnationID != id }
    }
    public mutating func recordActivity(_ update: ActivityUpdate, maximumCount: Int = 100) {
        activity.append(update)
        if activity.count > maximumCount { activity.removeFirst(activity.count - maximumCount) }
    }
}
