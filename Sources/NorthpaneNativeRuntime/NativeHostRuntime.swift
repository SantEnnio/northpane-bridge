#if os(macOS) || os(Linux)
import Foundation
import NorthpaneHostRuntime
import NorthpaneProtocol

/// The Bridge sees the same interface for Herdr and the native owner. All
/// process, terminal and lease state belongs to the independently running owner.
public actor NativeHostRuntime: HostRuntime {
    private let stateDirectory: URL
    private let hostID: HostID
    private let connect: @Sendable () async throws -> NativeRuntimeConnection
    private var connection: NativeRuntimeConnection?

    public init(stateDirectory: URL, hostID: HostID, executableURL: URL) {
        self.stateDirectory = stateDirectory; self.hostID = hostID
        connect = { try await NativeRuntimeUserService.ensureRunning(stateDirectory: stateDirectory, executableURL: executableURL).connection }
    }

    /// Test seam: exercise the production adapter against an isolated owner
    /// without registering services in the user's profile.
    init(stateDirectory: URL, hostID: HostID, connect: @escaping @Sendable () async throws -> NativeRuntimeConnection) {
        self.stateDirectory = stateDirectory; self.hostID = hostID; self.connect = connect
    }
    deinit { connection?.close() }

    public var descriptor: RuntimeDescriptor {
        RuntimeDescriptor(kind: .native, version: connection?.status.version ?? "unavailable",
            incarnationID: connection?.status.incarnationID ?? "unavailable")
    }
    public func ensureRunning() async throws {
        if let connection { _ = try await connection.ping(); return }
        let candidate = try await connect()
        guard candidate.status.workspaceModel, candidate.status.terminalFrames else {
            candidate.close()
            // A newer Bridge never restarts a live older owner to acquire features.
            throw NativeRuntimeProcessError.rejected("native_owner_update_required")
        }
        // Actor reentrancy can open two harmless streams while awaiting startup.
        if connection == nil { connection = candidate } else { candidate.close() }
    }
    private func current() throws -> NativeRuntimeConnection {
        guard let connection else { throw NativeRuntimeProcessError.invalidConfiguration }
        return connection
    }
    public func currentSnapshot(hostID: HostID) async throws -> WireRuntimeSnapshot {
        guard hostID == self.hostID else { throw NativeRuntimeProcessError.invalidConfiguration }
        return try await current().currentSnapshot(hostID: hostID)
    }
    public func createWorkspace(label: String, workingDirectory: String, environment: [String: String]) async throws -> CreatedPane {
        try await current().createWorkspace(hostID: hostID, label: label, workingDirectory: workingDirectory, environment: environment)
    }
    public func createTab(workspaceID: String, workingDirectory: String) async throws -> CreatedPane {
        try await current().createTab(hostID: hostID, workspaceID: workspaceID, workingDirectory: workingDirectory)
    }
    public func splitPane(paneID: String, direction: PaneSplitDirection, workingDirectory: String) async throws -> CreatedPane {
        try await current().splitPane(hostID: hostID, paneID: paneID, direction: direction, workingDirectory: workingDirectory)
    }
    public func renameWorkspace(workspaceID: String, label: String) async throws {
        try await current().renameWorkspace(hostID: hostID, workspaceID: workspaceID, label: label)
    }
    public func closeWorkspace(workspaceID: String) async throws {
        try await current().closeWorkspace(hostID: hostID, workspaceID: workspaceID)
    }
    public func startAgent(_ kind: WorkspaceAgentKind, executableURL: URL, name: String, paneID: String) async throws {
        try await current().startAgent(paneID: paneID, kind: kind, executable: executableURL)
    }
    public func conversationIdentity(paneID: String) async throws -> RuntimeConversationIdentity? {
        try await current().paneInformation(paneID: paneID).conversation
    }
    public func hostScrollbackLines(paneID: String) async -> Int {
        (try? await current().paneInformation(paneID: paneID).scrollbackLines) ?? 0
    }
    public func paneActivity(paneIDs: [String]) async -> [String: Date] {
        var result: [String: Date] = [:]
        for id in paneIDs { if let date = try? await current().paneInformation(paneID: id).lastActivity { result[id] = date } }
        return result
    }
    public func makeTerminalChannel(paneID: String, mode: TerminalAttachMode) throws -> any TerminalChannel {
        NativeTerminalChannel(stateDirectory: stateDirectory, incarnationID: try current().status.incarnationID, paneID: paneID, mode: mode)
    }
    public func changes() -> any RuntimeChanges {
        NativeRuntimeChanges(stateDirectory: stateDirectory, incarnationID: connection?.status.incarnationID ?? "unavailable")
    }
}

private final class NativeRuntimeChanges: RuntimeChanges, @unchecked Sendable {
    private let stateDirectory: URL
    private let incarnationID: String
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "northpane.native.changes")
    private var connection: NativeRuntimeConnection?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var revision = 0

    init(stateDirectory: URL, incarnationID: String) { self.stateDirectory = stateDirectory; self.incarnationID = incarnationID }
    deinit { stop() }

    func start(onEvent: @escaping @Sendable () -> Void, onClose: @escaping @Sendable (Error?) -> Void) async throws {
        let connection = try await NativeRuntimeConnection.connect(stateDirectory: stateDirectory)
        do {
            guard connection.status.incarnationID == incarnationID else { throw NativeRuntimeProcessError.invalidFrame }
            let initial = try await Task.detached { try connection.observedRevision() }.value
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self, self.lock.withLock({ !self.stopped }) else { return }
                do {
                    let next = try connection.observedRevision()
                    let changed = self.lock.withLock {
                        guard !self.stopped, next != self.revision else { return false }
                        self.revision = next; return true
                    }
                    if changed { onEvent() }
                } catch {
                    let notify = self.lock.withLock { !self.stopped }
                    self.stop()
                    if notify { onClose(error) }
                }
            }
            let accepted = lock.withLock {
                guard !stopped, self.connection == nil else { return false }
                self.connection = connection; self.timer = timer; revision = initial; return true
            }
            timer.resume()
            guard accepted else { timer.cancel(); throw NativeRuntimeProcessError.invalidConfiguration }
        } catch { connection.close(); throw error }
    }
    func updatePaneIDs(_ paneIDs: [String]) async { /* The owner revision covers every Pane. */ }
    func stop() {
        let closing = lock.withLock { () -> NativeRuntimeConnection? in
            stopped = true; timer?.cancel(); timer = nil
            let result = connection; connection = nil; return result
        }
        closing?.close()
    }
}
#endif
