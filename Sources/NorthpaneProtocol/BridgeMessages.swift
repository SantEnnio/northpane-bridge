import Foundation

public enum ChannelPurpose: String, Codable, Sendable { case control, runtimeEvents, terminal, preview, artifact, authorization, notification }

public struct OpenChannel: Equatable, Codable, Sendable {
    public let channelID: ChannelID
    public let purpose: ChannelPurpose
    public let initialWindowBytes: Int
    public init(channelID: ChannelID, purpose: ChannelPurpose, initialWindowBytes: Int) {
        self.channelID = channelID; self.purpose = purpose; self.initialWindowBytes = initialWindowBytes
    }
}

public struct WindowUpdate: Equatable, Codable, Sendable {
    public let channelID: ChannelID
    public let additionalBytes: Int
    public init(channelID: ChannelID, additionalBytes: Int) { self.channelID = channelID; self.additionalBytes = additionalBytes }
}

public struct CancelChannel: Equatable, Codable, Sendable {
    public let channelID: ChannelID
    public let reasonCode: String
    public init(channelID: ChannelID, reasonCode: String) { self.channelID = channelID; self.reasonCode = reasonCode }
}

public struct CloseChannel: Equatable, Codable, Sendable {
    public let channelID: ChannelID
    public init(channelID: ChannelID) { self.channelID = channelID }
}

public struct WirePane: Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    public let workspaceID: String
    public let tabID: String
    public let revision: Int
    public let agent: String?
    public let agentStatus: String
    public let focused: Bool
    /// The working directory of the pane's foreground process on the Host (schema revision 5).
    public let cwd: String?
    public init(id: String, title: String, workspaceID: String = "", tabID: String = "", revision: Int = 0, agent: String? = nil, agentStatus: String = "unknown", focused: Bool = false, cwd: String? = nil) {
        self.id = id; self.title = title; self.workspaceID = workspaceID; self.tabID = tabID; self.revision = revision; self.agent = agent; self.agentStatus = agentStatus; self.focused = focused; self.cwd = cwd
    }
}

public struct WireWorkspace: Equatable, Codable, Sendable {
    public let id: String
    public let label: String
    public let number: Int
    public let focused: Bool
    public let activeTabID: String
    public let worktreePath: String?
    public init(id: String, label: String, number: Int, focused: Bool, activeTabID: String, worktreePath: String? = nil) {
        self.id = id; self.label = label; self.number = number; self.focused = focused; self.activeTabID = activeTabID; self.worktreePath = worktreePath
    }
}

public struct WireTab: Equatable, Codable, Sendable {
    public let id: String
    public let workspaceID: String
    public let label: String
    public let number: Int
    public let focused: Bool
    public init(id: String, workspaceID: String, label: String, number: Int, focused: Bool) {
        self.id = id; self.workspaceID = workspaceID; self.label = label; self.number = number; self.focused = focused
    }
}

public struct WireRuntimeSnapshot: Equatable, Codable, Sendable {
    public let hostID: HostID
    public let incarnationID: String
    public let snapshotID: String
    public let nextEventSequence: Int
    public let panes: [WirePane]
    public let workspaces: [WireWorkspace]
    public let tabs: [WireTab]
    public let capabilities: Set<Capability>
    public init(hostID: HostID, incarnationID: String, snapshotID: String, nextEventSequence: Int, panes: [WirePane], capabilities: Set<Capability>, workspaces: [WireWorkspace] = [], tabs: [WireTab] = []) {
        self.hostID = hostID; self.incarnationID = incarnationID; self.snapshotID = snapshotID; self.nextEventSequence = nextEventSequence; self.panes = panes; self.capabilities = capabilities; self.workspaces = workspaces; self.tabs = tabs
    }

    /// True when the two snapshots describe the same tree: the same Host incarnation, panes
    /// (identity, title, placement, agent, status, focus, directory), workspaces, tabs and
    /// capabilities. Snapshot identifiers, event sequences and pane revisions are not compared:
    /// Herdr bumps a pane's revision on every title or scroll tick while an agent works, which
    /// changes nothing the operator can see.
    public func hasSameShape(as other: WireRuntimeSnapshot) -> Bool {
        hostID == other.hostID && incarnationID == other.incarnationID && capabilities == other.capabilities
            && workspaces == other.workspaces && tabs == other.tabs
            && panes.map(WirePane.Shape.init) == other.panes.map(WirePane.Shape.init)
    }
}

extension WirePane {
    /// Everything about a pane except its revision.
    struct Shape: Equatable {
        let id: String, title: String, workspaceID: String, tabID: String, agent: String?, agentStatus: String, focused: Bool, cwd: String?
        init(_ pane: WirePane) {
            id = pane.id; title = pane.title; workspaceID = pane.workspaceID; tabID = pane.tabID; agent = pane.agent; agentStatus = pane.agentStatus; focused = pane.focused; cwd = pane.cwd
        }
    }
}

public enum WireRuntimeEvent: Equatable, Codable, Sendable {
    case paneOpened(WirePane)
    case paneClosed(id: String)
    case paneRenamed(id: String, title: String)
}

public struct WireRuntimeEventBatch: Equatable, Codable, Sendable {
    public let incarnationID: String
    public let snapshotID: String
    public let firstSequence: Int
    public let events: [WireRuntimeEvent]
    public init(incarnationID: String, snapshotID: String, firstSequence: Int, events: [WireRuntimeEvent]) {
        self.incarnationID = incarnationID; self.snapshotID = snapshotID; self.firstSequence = firstSequence; self.events = events
    }
}

public enum WorkspaceAgentKind: String, CaseIterable, Codable, Sendable {
    case shell
    case codex
    case claude
    case openCode
}

public struct MutationRequest: Equatable, Codable, Sendable {
    public let commandID: UUID
    public let clientDeviceID: ClientDeviceID
    public let capability: Capability
    public let targetID: String
    public let expectedRevision: Int
    public let deadline: Date
    /// Parameters used only by the `workspace:create` mutation (schema revision 10).
    public let workspaceLabel: String
    public let workingDirectory: String
    /// Optional root-Pane program for `workspace:create` (schema revision 11).
    public let workspaceAgentKind: WorkspaceAgentKind
    public init(commandID: UUID, clientDeviceID: ClientDeviceID, capability: Capability, targetID: String, expectedRevision: Int, deadline: Date, workspaceLabel: String = "", workingDirectory: String = "", workspaceAgentKind: WorkspaceAgentKind = .shell) {
        self.commandID = commandID; self.clientDeviceID = clientDeviceID; self.capability = capability; self.targetID = targetID; self.expectedRevision = expectedRevision; self.deadline = deadline
        self.workspaceLabel = workspaceLabel; self.workingDirectory = workingDirectory; self.workspaceAgentKind = workspaceAgentKind
    }
}

public enum WireMutationOutcome: String, Codable, Sendable { case applied, rejected, notApplied }
public struct WireMutationReceipt: Equatable, Codable, Sendable {
    public let commandID: UUID
    public let outcome: WireMutationOutcome
    public let problem: Problem?
    /// Authoritative identities returned by `workspace:create` (schema revision 10).
    public let workspaceID: String
    public let paneID: String
    /// Requested root-Pane program and whether Herdr started it (schema revision 11).
    public let workspaceAgentKind: WorkspaceAgentKind
    public let workspaceAgentStarted: Bool
    public init(commandID: UUID, outcome: WireMutationOutcome, problem: Problem? = nil, workspaceID: String = "", paneID: String = "", workspaceAgentKind: WorkspaceAgentKind = .shell, workspaceAgentStarted: Bool = false) {
        self.commandID = commandID; self.outcome = outcome; self.problem = problem
        self.workspaceID = workspaceID; self.paneID = paneID; self.workspaceAgentKind = workspaceAgentKind; self.workspaceAgentStarted = workspaceAgentStarted
    }
}

public struct TerminalInputFrame: Equatable, Codable, Sendable {
    public let attachmentID: UUID
    public let sequence: Int
    public let bytes: Data
    public init(attachmentID: UUID, sequence: Int, bytes: Data) { self.attachmentID = attachmentID; self.sequence = sequence; self.bytes = bytes }
}

public struct TerminalInputAcknowledgement: Equatable, Codable, Sendable {
    public let attachmentID: UUID
    public let acceptedThroughSequence: Int
    public init(attachmentID: UUID, acceptedThroughSequence: Int) { self.attachmentID = attachmentID; self.acceptedThroughSequence = acceptedThroughSequence }
}

public struct ObserveRuntimeRequest: Equatable, Codable, Sendable {
    public let sessionName: String?
    public init(sessionName: String? = nil) { self.sessionName = sessionName }
}

public enum TerminalAttachMode: String, Codable, Sendable { case observe, control, takeover }

public struct TerminalAttachRequest: Equatable, Codable, Sendable {
    public let paneID: String
    public let mode: TerminalAttachMode
    public let columns: Int
    public let rows: Int
    public let incarnationID: String
    public let snapshotID: String
    public let nextEventSequence: Int
    public init(paneID: String, mode: TerminalAttachMode, columns: Int, rows: Int, incarnationID: String, snapshotID: String, nextEventSequence: Int) {
        self.paneID = paneID; self.mode = mode; self.columns = columns; self.rows = rows; self.incarnationID = incarnationID; self.snapshotID = snapshotID; self.nextEventSequence = nextEventSequence
    }
}

public struct TerminalAttached: Equatable, Codable, Sendable {
    public let attachmentID: UUID
    public let paneID: String
    public let mode: TerminalAttachMode
    public let controllerDeviceID: ClientDeviceID?
    public init(attachmentID: UUID, paneID: String, mode: TerminalAttachMode, controllerDeviceID: ClientDeviceID? = nil) {
        self.attachmentID = attachmentID; self.paneID = paneID; self.mode = mode; self.controllerDeviceID = controllerDeviceID
    }
}

public struct TerminalOutputFrame: Equatable, Codable, Sendable {
    public let attachmentID: UUID
    public let sequence: Int
    public let bytes: Data
    public init(attachmentID: UUID, sequence: Int, bytes: Data) { self.attachmentID = attachmentID; self.sequence = sequence; self.bytes = bytes }
}

public struct TerminalResizeRequest: Equatable, Codable, Sendable {
    public let attachmentID: UUID
    public let columns: Int
    public let rows: Int
    public init(attachmentID: UUID, columns: Int, rows: Int) { self.attachmentID = attachmentID; self.columns = columns; self.rows = rows }
}

public enum TerminalScrollDirection: String, Codable, Sendable { case up, down }

/// Scrolls the Host-rendered viewport of a controlled terminal by a number of lines.
public struct TerminalScrollRequest: Equatable, Codable, Sendable {
    public let attachmentID: UUID
    public let direction: TerminalScrollDirection
    public let lines: Int
    public init(attachmentID: UUID, direction: TerminalScrollDirection, lines: Int) { self.attachmentID = attachmentID; self.direction = direction; self.lines = lines }
}

public struct TerminalReleaseRequest: Equatable, Codable, Sendable {
    public let attachmentID: UUID
    public init(attachmentID: UUID) { self.attachmentID = attachmentID }
}

public struct Heartbeat: Equatable, Codable, Sendable {
    public let sentAt: Date
    public init(sentAt: Date = Date()) { self.sentAt = sentAt }
}

public struct PairingChallengeRequest: Equatable, Codable, Sendable {
    public init() {}
}

public struct WirePairingChallenge: Equatable, Codable, Sendable {
    public let challengeID: UUID
    public let hostID: HostID
    public let nonce: Data
    public let expiresAt: Date
    public init(challengeID: UUID, hostID: HostID, nonce: Data, expiresAt: Date) {
        self.challengeID = challengeID; self.hostID = hostID; self.nonce = nonce; self.expiresAt = expiresAt
    }
}

public struct WirePairingProof: Equatable, Codable, Sendable {
    public let clientDeviceID: ClientDeviceID
    public let challengeID: UUID
    public let publicKey: Data
    public let signature: Data
    public init(clientDeviceID: ClientDeviceID, challengeID: UUID, publicKey: Data, signature: Data) {
        self.clientDeviceID = clientDeviceID; self.challengeID = challengeID; self.publicKey = publicKey; self.signature = signature
    }
}

public struct WirePairingAccepted: Equatable, Codable, Sendable {
    public let clientDeviceID: ClientDeviceID
    public let observation: Bool
    public let standardControl: Bool
    public init(clientDeviceID: ClientDeviceID, observation: Bool, standardControl: Bool) {
        self.clientDeviceID = clientDeviceID; self.observation = observation; self.standardControl = standardControl
    }
}

public enum ResourceCommandKind: String, Codable, Sendable {
    case listResources, registerPreview, updatePreview, closePreview, fetchPreviewHTTP
    case publishArtifact, readArtifact, deleteArtifact, listArtifactEntries
    case streamPreviewHTTP, openPreviewWebSocket, sendPreviewWebSocket, closePreviewWebSocket
    /// Schema revision 5: read one file a terminal referenced, resolved against the pane's
    /// working directory and confined to the workspace root, the Host home and the temporary
    /// directories (the roots were widened in revision 6).
    case readWorkspaceFile
    /// Schema revision 7: search those same roots by name. Names and metadata only.
    case searchWorkspacePaths
    /// Schema revision 8: list the Host's displays and on-screen windows. Names and sizes only.
    case listScreenCaptureTargets
    /// Schema revision 8: capture one listed target to a PNG in the Host user's temporary
    /// folder, answering with its absolute path and a downscaled preview.
    case captureScreen
    /// Schema revision 12: stage a file the operator pasted, sent in ordered chunks under one
    /// idempotency key, under the Host user's temporary folder; the last chunk is answered with
    /// the absolute path an agent reads it from.
    case stagePastedFile
    /// Schema revision 16: list the folders inside one folder of the Host, by name, so a place
    /// for a new Workspace can be walked to instead of typed.
    case listHostDirectories
}
public enum ResourceKind: String, Codable, Sendable { case preview, artifact }
public enum ViewerAvailability: String, Codable, Sendable { case available, none, unknown }

public struct HTTPHeader: Equatable, Codable, Sendable {
    public let name: String
    public let value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

public struct ResourceCommand: Equatable, Codable, Sendable {
    public let kind: ResourceCommandKind
    public let commandID: UUID
    public let workspaceID: String
    public let resourceID: UUID?
    public let expectedRevision: Int
    public let path: String
    public let origin: String
    public let title: String
    public let healthPath: String
    public let ttlSeconds: Int
    public let mediaType: String
    public let method: String
    public let headers: [HTTPHeader]
    public let body: Data
    public let idempotencyKey: String
    public let offset: Int
    public let length: Int
    public let streamID: UUID?
    /// The pane whose working directory resolves a relative `path` (`readWorkspaceFile`).
    public let paneID: String
    /// What the operator typed (`searchWorkspacePaths`). `length` caps the number of hits.
    public let query: String
    /// The capture target chosen from the last listing (`captureScreen`).
    public let targetID: String

    public init(kind: ResourceCommandKind, commandID: UUID = UUID(), workspaceID: String = "", resourceID: UUID? = nil, expectedRevision: Int = 0, path: String = "", origin: String = "", title: String = "", healthPath: String = "/", ttlSeconds: Int = 0, mediaType: String = "", method: String = "GET", headers: [HTTPHeader] = [], body: Data = Data(), idempotencyKey: String = "", offset: Int = 0, length: Int = 0, streamID: UUID? = nil, paneID: String = "", query: String = "", targetID: String = "") {
        self.kind = kind; self.commandID = commandID; self.workspaceID = workspaceID; self.resourceID = resourceID
        self.expectedRevision = expectedRevision; self.path = path; self.origin = origin; self.title = title
        self.healthPath = healthPath; self.ttlSeconds = ttlSeconds; self.mediaType = mediaType; self.method = method
        self.headers = headers; self.body = body; self.idempotencyKey = idempotencyKey; self.offset = offset; self.length = length; self.streamID = streamID; self.paneID = paneID; self.query = query; self.targetID = targetID
    }
}

public struct ResourceDescriptor: Equatable, Codable, Sendable {
    public let kind: ResourceKind
    public let resourceID: UUID
    public let workspaceID: String
    public let revision: Int
    public let title: String
    public let mediaType: String
    public let entrypoint: String
    public let expiresAt: Date
    public let healthy: Bool
    public let viewerAvailability: ViewerAvailability
    /// Optional Pane provenance for a Preview (schema revision 10).
    public let paneID: String
    public init(kind: ResourceKind, resourceID: UUID, workspaceID: String, revision: Int, title: String = "", mediaType: String = "", entrypoint: String = "", expiresAt: Date, healthy: Bool = true, viewerAvailability: ViewerAvailability = .unknown, paneID: String = "") {
        self.kind = kind; self.resourceID = resourceID; self.workspaceID = workspaceID; self.revision = revision
        self.title = title; self.mediaType = mediaType; self.entrypoint = entrypoint; self.expiresAt = expiresAt
        self.healthy = healthy; self.viewerAvailability = viewerAvailability; self.paneID = paneID
    }
}

public struct ResourceResult: Equatable, Codable, Sendable {
    public let commandID: UUID
    public let resources: [ResourceDescriptor]
    public let statusCode: Int
    public let headers: [HTTPHeader]
    public let body: Data
    public let relativePath: String
    public let mediaType: String
    public let deleted: Bool
    public let totalBytes: Int
    public let files: [ResourceFile]
    public let streamID: UUID?
    public let sequence: Int
    public let isFinal: Bool
    public let isText: Bool
    /// The entries `searchWorkspacePaths` matched, best first.
    public let pathHits: [ResourcePathHit]
    /// Set when a budget stopped the search before it had seen everything.
    public let truncated: Bool
    /// What the Host's screen can show (`listScreenCaptureTargets`), displays first.
    public let captureTargets: [ResourceCaptureTarget]
    public init(commandID: UUID, resources: [ResourceDescriptor] = [], statusCode: Int = 0, headers: [HTTPHeader] = [], body: Data = Data(), relativePath: String = "", mediaType: String = "", deleted: Bool = false, totalBytes: Int = 0, files: [ResourceFile] = [], streamID: UUID? = nil, sequence: Int = 0, isFinal: Bool = false, isText: Bool = false, pathHits: [ResourcePathHit] = [], truncated: Bool = false, captureTargets: [ResourceCaptureTarget] = []) {
        self.commandID = commandID; self.resources = resources; self.statusCode = statusCode; self.headers = headers
        self.body = body; self.relativePath = relativePath; self.mediaType = mediaType; self.deleted = deleted; self.totalBytes = totalBytes; self.files = files
        self.streamID = streamID; self.sequence = sequence; self.isFinal = isFinal; self.isText = isText
        self.pathHits = pathHits; self.truncated = truncated; self.captureTargets = captureTargets
    }
}

public struct ResourceFile: Equatable, Codable, Sendable {
    public let relativePath: String
    public let byteCount: Int
    public let contentDigest: String
    public init(relativePath: String, byteCount: Int, contentDigest: String) { self.relativePath = relativePath; self.byteCount = byteCount; self.contentDigest = contentDigest }
}

/// One entry a path search matched. `path` is absolute on the Host and is what the operator
/// pastes into the pane; `relativePath` and `rootLabel` place the hit for a reader without
/// spelling out the whole path.
public struct ResourcePathHit: Equatable, Codable, Sendable {
    public let path: String
    public let relativePath: String
    public let rootLabel: String
    public let isDirectory: Bool
    public let byteCount: Int
    public let modified: Date?
    public init(path: String, relativePath: String, rootLabel: String, isDirectory: Bool, byteCount: Int = 0, modified: Date? = nil) {
        self.path = path; self.relativePath = relativePath; self.rootLabel = rootLabel
        self.isDirectory = isDirectory; self.byteCount = byteCount; self.modified = modified
    }
}

public enum ResourceCaptureTargetKind: String, Codable, Sendable { case display, window }

/// One thing the Host's screen can show and `captureScreen` can capture. `id` is opaque and
/// valid only until the next listing. `application` names the owning app for a window and is
/// empty for a display; `title` is the window title when the Host may read it, or a display name.
public struct ResourceCaptureTarget: Equatable, Codable, Sendable {
    public let id: String
    public let kind: ResourceCaptureTargetKind
    public let application: String
    public let title: String
    public let width: Int
    public let height: Int
    public let isFrontmost: Bool
    public init(id: String, kind: ResourceCaptureTargetKind, application: String = "", title: String = "", width: Int = 0, height: Int = 0, isFrontmost: Bool = false) {
        self.id = id; self.kind = kind; self.application = application; self.title = title
        self.width = width; self.height = height; self.isFrontmost = isFrontmost
    }
}

public enum AuthorizationCommandKind: String, Codable, Sendable {
    case create, list, approve, status, cancel
}

public enum AuthorizationWireState: String, Codable, Sendable {
    case pending, awaitingUser, polling, completed, cancelled, expired, failed
}

public struct AuthorizationCommand: Equatable, Codable, Sendable {
    public let kind: AuthorizationCommandKind
    public let commandID: UUID
    public let requestID: UUID?
    public let expectedRevision: Int
    public let hostname: String
    public let scopes: [String]
    public let provenance: String

    public init(kind: AuthorizationCommandKind, commandID: UUID = UUID(), requestID: UUID? = nil, expectedRevision: Int = 0, hostname: String = "github.com", scopes: [String] = [], provenance: String = "") {
        self.kind = kind; self.commandID = commandID; self.requestID = requestID; self.expectedRevision = expectedRevision
        self.hostname = hostname; self.scopes = scopes; self.provenance = provenance
    }
}

public struct AuthorizationRequestDescriptor: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID { requestID }
    public let requestID: UUID
    public let revision: Int
    public let state: AuthorizationWireState
    public let hostID: HostID
    public let processID: Int32
    public let hostname: String
    public let scopes: [String]
    public let provenance: String
    public let createdAt: Date
    public let expiresAt: Date
    public let userCode: String
    public let verificationURL: URL?
    public let account: String
    public let problemCode: String

    public init(requestID: UUID, revision: Int, state: AuthorizationWireState, hostID: HostID, processID: Int32, hostname: String, scopes: [String], provenance: String, createdAt: Date, expiresAt: Date, userCode: String = "", verificationURL: URL? = nil, account: String = "", problemCode: String = "") {
        self.requestID = requestID; self.revision = revision; self.state = state; self.hostID = hostID; self.processID = processID
        self.hostname = hostname; self.scopes = scopes; self.provenance = provenance; self.createdAt = createdAt; self.expiresAt = expiresAt
        self.userCode = userCode; self.verificationURL = verificationURL; self.account = account; self.problemCode = problemCode
    }
}

public struct AuthorizationResult: Equatable, Codable, Sendable {
    public let commandID: UUID
    public let requests: [AuthorizationRequestDescriptor]
    public init(commandID: UUID, requests: [AuthorizationRequestDescriptor]) { self.commandID = commandID; self.requests = requests }
}

public enum NotificationRouteCommandKind: String, Codable, Sendable {
    case put, list, revoke, deleteAll
}

public struct NotificationRouteCommand: Equatable, Codable, Sendable {
    public let kind: NotificationRouteCommandKind
    public let commandID: UUID
    public let routeID: UUID?
    public let encryptionPublicKey: Data
    public let publisherCapability: Data
    public let gatewayURL: URL?
    public let expiresAt: Date?

    public init(kind: NotificationRouteCommandKind, commandID: UUID = UUID(), routeID: UUID? = nil,
                encryptionPublicKey: Data = Data(), publisherCapability: Data = Data(), gatewayURL: URL? = nil,
                expiresAt: Date? = nil) {
        self.kind = kind; self.commandID = commandID; self.routeID = routeID
        self.encryptionPublicKey = encryptionPublicKey; self.publisherCapability = publisherCapability
        self.gatewayURL = gatewayURL; self.expiresAt = expiresAt
    }
}

public struct NotificationRouteDescriptor: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID { routeID }
    public let routeID: UUID
    public let clientDeviceID: ClientDeviceID
    public let gatewayURL: URL
    public let expiresAt: Date
    public let lastUsedAt: Date
    public let revokedAt: Date?

    public init(routeID: UUID, clientDeviceID: ClientDeviceID, gatewayURL: URL, expiresAt: Date,
                lastUsedAt: Date, revokedAt: Date? = nil) {
        self.routeID = routeID; self.clientDeviceID = clientDeviceID; self.gatewayURL = gatewayURL
        self.expiresAt = expiresAt; self.lastUsedAt = lastUsedAt; self.revokedAt = revokedAt
    }
}

public struct NotificationRouteResult: Equatable, Codable, Sendable {
    public let commandID: UUID
    public let routes: [NotificationRouteDescriptor]
    public init(commandID: UUID, routes: [NotificationRouteDescriptor]) { self.commandID = commandID; self.routes = routes }
}
