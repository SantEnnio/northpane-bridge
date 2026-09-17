import Foundation
import NorthpaneProtocol

public struct HerdrSessionIncarnationID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct Pane: Equatable, Codable, Sendable {
    public let id: String
    public var title: String
    public let workspaceID: String?
    public let tabID: String?
    public var revision: Int
    public var agent: String?
    public var agentStatus: String
    public var focused: Bool
    /// Working directory of the pane's foreground process on the Host, when the Bridge reports it.
    public var cwd: String?
    public init(id: String, title: String, workspaceID: String? = nil, tabID: String? = nil, revision: Int = 0, agent: String? = nil, agentStatus: String = "unknown", focused: Bool = false, cwd: String? = nil) {
        self.id = id; self.title = title; self.workspaceID = workspaceID; self.tabID = tabID; self.revision = revision; self.agent = agent; self.agentStatus = agentStatus; self.focused = focused; self.cwd = cwd
    }
}

public struct Workspace: Equatable, Codable, Sendable {
    public let id: String
    public var label: String
    public var number: Int
    public var focused: Bool
    public var activeTabID: String?
    public var worktreePath: String?
    public init(id: String, label: String, number: Int = 0, focused: Bool = false, activeTabID: String? = nil, worktreePath: String? = nil) {
        self.id = id; self.label = label; self.number = number; self.focused = focused; self.activeTabID = activeTabID; self.worktreePath = worktreePath
    }
}

public struct Tab: Equatable, Codable, Sendable {
    public let id: String
    public let workspaceID: String
    public var label: String
    public var number: Int
    public var focused: Bool
    public init(id: String, workspaceID: String, label: String, number: Int = 0, focused: Bool = false) {
        self.id = id; self.workspaceID = workspaceID; self.label = label; self.number = number; self.focused = focused
    }
}

public struct ResourceTombstone: Equatable, Codable, Sendable {
    public let resourceID: String
    public let title: String
    public let removedAtSequence: Int
    public let expiresAt: Date
    public init(resourceID: String, title: String, removedAtSequence: Int, expiresAt: Date) {
        self.resourceID = resourceID; self.title = title; self.removedAtSequence = removedAtSequence; self.expiresAt = expiresAt
    }
}

public struct RuntimeSnapshot: Equatable, Codable, Sendable {
    public let hostID: HostID
    public let incarnationID: HerdrSessionIncarnationID
    public let snapshotID: String
    public let nextEventSequence: Int
    public let workspaces: [Workspace]
    public let tabs: [Tab]
    public let panes: [Pane]
    public init(hostID: HostID, incarnationID: HerdrSessionIncarnationID, snapshotID: String, nextEventSequence: Int, panes: [Pane], workspaces: [Workspace] = [], tabs: [Tab] = []) {
        self.hostID = hostID; self.incarnationID = incarnationID; self.snapshotID = snapshotID; self.nextEventSequence = nextEventSequence; self.panes = panes; self.workspaces = workspaces; self.tabs = tabs
    }

    public init(wire: WireRuntimeSnapshot) throws {
        guard let incarnation = UUID(uuidString: wire.incarnationID) else { throw ProjectionInputError.invalidIncarnation }
        self.init(
            hostID: wire.hostID,
            incarnationID: .init(rawValue: incarnation),
            snapshotID: wire.snapshotID,
            nextEventSequence: wire.nextEventSequence,
            panes: wire.panes.map { Pane(id: $0.id, title: $0.title, workspaceID: $0.workspaceID.nilIfEmpty, tabID: $0.tabID.nilIfEmpty, revision: $0.revision, agent: $0.agent, agentStatus: $0.agentStatus, focused: $0.focused, cwd: $0.cwd) },
            workspaces: wire.workspaces.map { Workspace(id: $0.id, label: $0.label, number: $0.number, focused: $0.focused, activeTabID: $0.activeTabID.nilIfEmpty, worktreePath: $0.worktreePath) },
            tabs: wire.tabs.map { Tab(id: $0.id, workspaceID: $0.workspaceID, label: $0.label, number: $0.number, focused: $0.focused) }
        )
    }
}

public enum ProjectionInputError: Error, Equatable, Sendable { case invalidIncarnation }

public enum RuntimeEvent: Equatable, Codable, Sendable {
    case paneOpened(id: String, title: String)
    case paneClosed(id: String)
    case paneRenamed(id: String, title: String)
}

public struct RuntimeEventBatch: Equatable, Codable, Sendable {
    public let incarnationID: HerdrSessionIncarnationID
    public let snapshotID: String
    public let firstSequence: Int
    public let events: [RuntimeEvent]
    public init(incarnationID: HerdrSessionIncarnationID, snapshotID: String, firstSequence: Int, events: [RuntimeEvent]) {
        self.incarnationID = incarnationID; self.snapshotID = snapshotID; self.firstSequence = firstSequence; self.events = events
    }
}

public enum IncoherenceReason: String, Codable, Sendable { case sequenceGap, snapshotMismatch, incarnationMismatch, impossibleEvent }
public enum ObservationFreshness: Equatable, Codable, Sendable {
    case empty
    case syncing
    case current(snapshotID: String, nextSequence: Int)
    case stale
    case incoherent(reason: IncoherenceReason)
}

public struct ObservationProof: Equatable, Codable, Sendable {
    public let hostID: HostID
    public let incarnationID: HerdrSessionIncarnationID
    public let snapshotID: String
    public let nextEventSequence: Int
}

public struct LiveView: Equatable, Sendable {
    public let freshness: ObservationFreshness
    public let workspaces: [Workspace]
    public let tabs: [Tab]
    public let panes: [Pane]
    public let tombstones: [ResourceTombstone]
    public init(freshness: ObservationFreshness, panes: [Pane], tombstones: [ResourceTombstone] = [], workspaces: [Workspace] = [], tabs: [Tab] = []) {
        self.freshness = freshness; self.panes = panes; self.tombstones = tombstones; self.workspaces = workspaces; self.tabs = tabs
    }
}

public struct LiveProjection: Sendable {
    private var hostID: HostID?
    private var incarnationID: HerdrSessionIncarnationID?
    private var snapshotID: String?
    private var expectedSequence: Int?
    private var workspacesByID: [String: Workspace] = [:]
    private var tabsByID: [String: Tab] = [:]
    private var panesByID: [String: Pane] = [:]
    private var tombstonesByID: [String: ResourceTombstone] = [:]
    private var lastAppliedBatch: RuntimeEventBatch?
    private var state: ObservationFreshness = .empty

    public init() {}

    public var view: LiveView {
        LiveView(freshness: state, panes: panesByID.values.sorted { $0.id < $1.id }, tombstones: tombstonesByID.values.sorted { $0.resourceID < $1.resourceID }, workspaces: workspacesByID.values.sorted { $0.number == $1.number ? $0.id < $1.id : $0.number < $1.number }, tabs: tabsByID.values.sorted { $0.number == $1.number ? $0.id < $1.id : $0.number < $1.number })
    }

    public var observationProof: ObservationProof? {
        guard case let .current(snapshotID, nextSequence) = state, let hostID, let incarnationID else { return nil }
        return ObservationProof(hostID: hostID, incarnationID: incarnationID, snapshotID: snapshotID, nextEventSequence: nextSequence)
    }

    public mutating func begin(_ snapshot: RuntimeSnapshot) {
        hostID = snapshot.hostID; incarnationID = snapshot.incarnationID; snapshotID = snapshot.snapshotID; expectedSequence = snapshot.nextEventSequence
        workspacesByID = Dictionary(snapshot.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tabsByID = Dictionary(snapshot.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        panesByID = Dictionary(snapshot.panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tombstonesByID.removeAll()
        lastAppliedBatch = nil
        guard workspacesByID.count == snapshot.workspaces.count,
              tabsByID.count == snapshot.tabs.count,
              panesByID.count == snapshot.panes.count,
              hierarchyIsCoherent else {
            state = .incoherent(reason: .impossibleEvent)
            expectedSequence = nil
            return
        }
        state = .current(snapshotID: snapshot.snapshotID, nextSequence: snapshot.nextEventSequence)
    }

    public mutating func beginSyncing() {
        hostID = nil; incarnationID = nil; snapshotID = nil; expectedSequence = nil
        workspacesByID.removeAll(); tabsByID.removeAll(); panesByID.removeAll(); tombstonesByID.removeAll(); lastAppliedBatch = nil
        state = .syncing
    }

    public mutating func markStale() {
        guard state != .empty else { return }
        state = .stale
        expectedSequence = nil
    }

    public mutating func apply(_ batch: RuntimeEventBatch) throws {
        guard let expectedSequence, let snapshotID, let incarnationID else { return invalidate(.impossibleEvent) }
        if batch == lastAppliedBatch { return }
        guard batch.incarnationID == incarnationID else { return invalidate(.incarnationMismatch) }
        guard batch.snapshotID == snapshotID else { return invalidate(.snapshotMismatch) }
        guard batch.firstSequence == expectedSequence else { return invalidate(.sequenceGap) }
        var candidatePanes = panesByID
        var candidateTombstones = tombstonesByID
        for (offset, event) in batch.events.enumerated() {
            switch event {
            case let .paneOpened(id, title):
                guard candidatePanes[id] == nil else { return invalidate(.impossibleEvent) }
                candidatePanes[id] = Pane(id: id, title: title)
                candidateTombstones.removeValue(forKey: id)
            case let .paneClosed(id):
                guard let removed = candidatePanes.removeValue(forKey: id) else { return invalidate(.impossibleEvent) }
                candidateTombstones[id] = ResourceTombstone(resourceID: id, title: removed.title, removedAtSequence: expectedSequence + offset, expiresAt: Date().addingTimeInterval(30 * 24 * 60 * 60))
            case let .paneRenamed(id, title):
                guard var pane = candidatePanes[id] else { return invalidate(.impossibleEvent) }
                pane.title = title; candidatePanes[id] = pane
            }
        }
        let next = expectedSequence + batch.events.count
        panesByID = candidatePanes
        tombstonesByID = candidateTombstones
        lastAppliedBatch = batch
        self.expectedSequence = next
        state = .current(snapshotID: snapshotID, nextSequence: next)
    }

    public mutating func invalidate(_ reason: IncoherenceReason) {
        state = .incoherent(reason: reason)
        expectedSequence = nil
    }


    public mutating func purgeExpiredTombstones(now: Date = Date()) {
        tombstonesByID = tombstonesByID.filter { $0.value.expiresAt > now }
    }

    private var hierarchyIsCoherent: Bool {
        for tab in tabsByID.values where workspacesByID[tab.workspaceID] == nil { return false }
        for workspace in workspacesByID.values {
            if let tabID = workspace.activeTabID, let tab = tabsByID[tabID], tab.workspaceID != workspace.id { return false }
            if let tabID = workspace.activeTabID, tabsByID[tabID] == nil { return false }
        }
        for pane in panesByID.values {
            if let workspaceID = pane.workspaceID, workspacesByID[workspaceID] == nil { return false }
            if let tabID = pane.tabID {
                guard let tab = tabsByID[tabID] else { return false }
                if let workspaceID = pane.workspaceID, tab.workspaceID != workspaceID { return false }
            }
        }
        return true
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
