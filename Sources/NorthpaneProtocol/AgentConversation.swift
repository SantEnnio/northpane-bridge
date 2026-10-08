import Foundation

/// Revision 23. Observation only: no prompt, resume, approval or lifecycle operation.
public struct AgentConversationRequest: Codable, Equatable, Sendable {
    public enum Agent: String, Codable, CaseIterable, Sendable { case codex, claude, opencode }
    public var agent: Agent
    /// Existing Host-local socket (Codex) or loopback HTTP origin (OpenCode). Empty uses the
    /// existing Codex daemon. Claude uses the Host's installed Agent SDK session reader.
    public var endpoint: String
    public var sessionID: String
    /// Re-read the complete visible window on every poll. Never append incremental snapshots.
    public var limit: Int
    /// Revision 24: resolve the current Pane's native or process-bound session on the Host.
    public var resolvePaneSession: Bool?
    /// Revision 24: remember an explicit selection after a successful, revalidated read.
    /// Stores identity/endpoint only; never writes to or resumes the agent session.
    public var associatePaneSession: Bool?
    public init(agent: Agent, endpoint: String = "", sessionID: String = "", limit: Int = 5,
                resolvePaneSession: Bool? = nil, associatePaneSession: Bool? = nil) {
        self.agent = agent; self.endpoint = endpoint; self.sessionID = sessionID; self.limit = limit
        self.resolvePaneSession = resolvePaneSession; self.associatePaneSession = associatePaneSession
    }
}

public struct AgentConversationSession: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let directory: String
    /// Loaded by this exact executor, not merely present in its history store.
    public let loaded: Bool
    public init(id: String, title: String, directory: String, loaded: Bool) {
        self.id = id; self.title = title; self.directory = directory; self.loaded = loaded
    }
}

public struct AgentConversationItem: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case user, assistant, activity, fileChange, notice }
    public let id: String
    public let turnID: String
    public let kind: Kind
    public let title: String
    public let text: String
    public let status: String
    public let added: Int?
    public let removed: Int?
    public init(id: String, turnID: String, kind: Kind, title: String = "", text: String,
                status: String = "", added: Int? = nil, removed: Int? = nil) {
        self.id = id; self.turnID = turnID; self.kind = kind; self.title = title; self.text = text
        self.status = status; self.added = added; self.removed = removed
    }
}

public struct AgentConversationReading: Codable, Equatable, Sendable {
    public enum Problem: String, Codable, Sendable {
        case sourceUnavailable, unsupportedVersion, sdkMissing, sessionNotLoaded, invalidEndpoint
        case unauthorized, outputTooLarge, unreadable
        case paneNotLinked
    }
    public var agent: AgentConversationRequest.Agent
    public var sessionID: String
    public var source: String
    public var version: String
    public var observedAt: Date
    public var sessions: [AgentConversationSession]
    public var items: [AgentConversationItem]
    public var hasOlder: Bool
    public var truncated: Bool
    public var problem: Problem?
    public init(agent: AgentConversationRequest.Agent, sessionID: String = "", source: String = "",
                version: String = "", observedAt: Date = Date(), sessions: [AgentConversationSession] = [],
                items: [AgentConversationItem] = [], hasOlder: Bool = false, truncated: Bool = false,
                problem: Problem? = nil) {
        self.agent = agent; self.sessionID = sessionID; self.source = source; self.version = version
        self.observedAt = observedAt; self.sessions = sessions; self.items = items
        self.hasOlder = hasOlder; self.truncated = truncated; self.problem = problem
    }
}
