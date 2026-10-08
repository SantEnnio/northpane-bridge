import Foundation
import NorthpaneProtocol

public enum RuntimeKind: String, Sendable { case herdr, native }

public struct RuntimeDescriptor: Equatable, Sendable {
    public let kind: RuntimeKind
    public let version: String
    public let incarnationID: String

    public init(kind: RuntimeKind, version: String, incarnationID: String) {
        self.kind = kind; self.version = version; self.incarnationID = incarnationID
    }
}

public struct CreatedPane: Equatable, Sendable {
    public let workspaceID: String
    public let paneID: String

    public init(workspaceID: String, paneID: String) {
        self.workspaceID = workspaceID; self.paneID = paneID
    }
}

public enum HostRuntimeError: Error, Equatable, Sendable {
    case invalidWorkingDirectory(String)
}

/// A native session reference, or an opaque proof of the process occupying a Pane.
/// A proof must include process birth, not just a reusable PID or Pane identifier.
public struct RuntimeConversationIdentity: Equatable, Sendable {
    public let agent: String
    public let sessionID: String?
    public let processProof: String?
    public init(agent: String, sessionID: String? = nil, processProof: String? = nil) {
        self.agent = agent; self.sessionID = sessionID; self.processProof = processProof
    }
}

/// One runtime scope on a Host. Session selection belongs to adapter construction;
/// every operation and subscription on this instance addresses that same scope.
/// The adapter returns complete observations and reports changes only as invalidation
/// signals. The Bridge retains authentication, observation proofs and mutation receipts.
public protocol HostRuntime: Actor {
    var descriptor: RuntimeDescriptor { get async }
    func ensureRunning() async throws
    func currentSnapshot(hostID: HostID) async throws -> WireRuntimeSnapshot
    func conversationIdentity(paneID: String) async throws -> RuntimeConversationIdentity?
    func changes() -> any RuntimeChanges
    func createWorkspace(label: String, workingDirectory: String, environment: [String: String]) async throws -> CreatedPane
    func createTab(workspaceID: String, workingDirectory: String) async throws -> CreatedPane
    func splitPane(paneID: String, direction: PaneSplitDirection, workingDirectory: String) async throws -> CreatedPane
    func renameWorkspace(workspaceID: String, label: String) async throws
    func closeWorkspace(workspaceID: String) async throws
    func startAgent(_ kind: WorkspaceAgentKind, executableURL: URL, name: String, paneID: String) async throws
    func hostScrollbackLines(paneID: String) async -> Int
    func paneActivity(paneIDs: [String]) async -> [String: Date]
    func makeTerminalChannel(paneID: String, mode: TerminalAttachMode) throws -> any TerminalChannel
}

public extension HostRuntime {
    func conversationIdentity(paneID: String) async throws -> RuntimeConversationIdentity? { nil }
}

/// Start before reading the first snapshot, so changes during that read are retained
/// by the caller. Updating the observed Pane set includes agent-status changes in
/// this same subscription. Stop detaches the observer and must not stop the runtime.
public protocol RuntimeChanges: Sendable {
    func start(onEvent: @escaping @Sendable () -> Void, onClose: @escaping @Sendable (Error?) -> Void) async throws
    func updatePaneIDs(_ paneIDs: [String]) async
    func stop()
}

/// An attachment to a runtime-owned terminal. Start delivers a full redraw followed
/// by terminal bytes. Release/stop detach this channel; they do not end the Pane's
/// process. Input and viewport changes are allowed only on control attachments.
public protocol TerminalChannel: Sendable {
    func start(columns: Int, rows: Int, onOutput: @escaping @Sendable (Data) -> Void,
               onClose: @escaping @Sendable (Error?) -> Void) throws
    func sendInput(_ data: Data) throws
    func resize(columns: Int, rows: Int) throws
    func scroll(direction: TerminalScrollDirection, lines: Int) throws
    func release() throws
    func stop()
}

public enum RuntimeAgentNaming {
    public static func name(resourceID: String) -> String {
        let body = resourceID.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return String(("northpane-" + (body.isEmpty ? "agent" : body)).prefix(32))
    }
}
