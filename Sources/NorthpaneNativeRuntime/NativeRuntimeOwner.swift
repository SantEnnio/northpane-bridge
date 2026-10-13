#if os(macOS) || os(Linux)
import Foundation
import NorthpaneHostRuntime
import NorthpaneProtocol
#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct NativeProcessConfiguration: Sendable {
    let shell: String
    let arguments: [String]
    let environment: [String: String]

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let fallback = getpwuid(geteuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/sh"
        return .init(shell: environment["SHELL"] ?? fallback, arguments: ["-l"], environment: environment)
    }
}

enum NativeRuntimeOwnerError: Error, Equatable {
    case unsupported
    case invalidDimensions
    case limitExceeded
    case attachmentMissing
    case processExited
    case controlRequired
    case controlOwnedElsewhere
    case paneBusy
}

struct NativeTerminalView: Sendable {
    let attachmentID: UUID
    let processProof: String
    let revision: Int
    let bytes: Data
    let controlling: Bool
    let ended: Bool
}

/// The daemon's single owner of graph, PTYs, emulator state and terminal leases.
/// Every metadata/graph/emulator operation runs on queue. The PTY reader enters
/// synchronously, so output is backpressured instead of accumulating in a queue.
/// Input writes run outside that queue: a slow child must not prevent its own
/// output from being drained. Authorization is linearized before each write.
final class NativeRuntimeOwner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "northpane.native.owner")
    private let model: NativeWorkspaceStore
    private let stateDirectory: URL
    private let configuration: NativeProcessConfiguration?
    private var panes: [String: PaneProcess] = [:]
    private var attachments: [UUID: Attachment] = [:]
    private var controllers: [String: UUID] = [:]
    private var retiring: [String: PTYProcess] = [:]
    private let maximumProcesses = 128
    private let maximumAttachments = 128

    private final class PaneProcess {
        let proof = UUID().uuidString
        let engine: NativeTerminalEngine
        let directory: String
        let environment: [String: String]
        let agent: WorkspaceAgentKind
        var process: PTYProcess?
        var lastActivity: Date?
        var acceptsAgentStart = true
        init(directory: String, environment: [String: String], agent: WorkspaceAgentKind, columns: Int, rows: Int) {
            engine = NativeTerminalEngine(columns: columns, rows: rows, scrollback: 1000)
            self.directory = directory; self.environment = environment; self.agent = agent
        }
    }

    private final class Attachment {
        let id = UUID()
        let connectionID: UUID
        let paneID: String
        let processProof: String
        var columns: Int
        var rows: Int
        var scrollAnchor: Int?
        var paintedAlternate: Bool?
        init(connectionID: UUID, paneID: String, processProof: String, columns: Int, rows: Int) {
            self.connectionID = connectionID; self.paneID = paneID; self.processProof = processProof; self.columns = columns; self.rows = rows
        }
    }

    init(stateDirectory: URL, incarnationID: String, configuration: NativeProcessConfiguration?) throws {
        self.stateDirectory = stateDirectory; self.configuration = configuration
        model = try NativeWorkspaceStore(fileURL: stateDirectory.appending(path: "runtime/layout-v1.json"), incarnationID: incarnationID)
    }

    deinit {
        for pane in panes.values { pane.process?.terminate() }
        for process in retiring.values { process.terminate() }
    }

    var terminalFramesAvailable: Bool { configuration != nil }
    var revision: Int { queue.sync { model.currentRevision } }

    func snapshot(hostID: HostID) -> WireRuntimeSnapshot {
        queue.sync {
            let shape = model.snapshot(hostID: hostID)
            let live = shape.panes.map { pane -> WirePane in
                guard let process = panes[pane.id] else { return pane }
                return WirePane(id: pane.id, title: process.engine.title.isEmpty ? pane.title : process.engine.title,
                    workspaceID: pane.workspaceID, tabID: pane.tabID, revision: pane.revision,
                    agent: process.agent == .shell || process.process == nil ? nil : process.agent.rawValue,
                    agentStatus: "unknown", focused: pane.focused, cwd: process.directory,
                    lastActivityAt: process.lastActivity)
            }
            return WireRuntimeSnapshot(hostID: shape.hostID, incarnationID: shape.incarnationID,
                snapshotID: shape.snapshotID, nextEventSequence: shape.nextEventSequence,
                panes: live, capabilities: configuration == nil ? [] : Set(Capability.allCases),
                workspaces: shape.workspaces, tabs: shape.tabs)
        }
    }

    func createWorkspace(label: String, workingDirectory: String, environment: [String: String] = [:]) throws -> CreatedPane {
        try queue.sync {
            try creating(directory: workingDirectory, environment: environment) { prepare in
                try model.createWorkspace(label: label, workingDirectory: workingDirectory, preparePane: prepare)
            }
        }
    }

    func createTab(workspaceID: String, workingDirectory: String) throws -> CreatedPane {
        try queue.sync {
            try creating(directory: workingDirectory, environment: [:]) { prepare in
                try model.createTab(workspaceID: workspaceID, workingDirectory: workingDirectory, preparePane: prepare)
            }
        }
    }

    func splitPane(paneID: String, direction: PaneSplitDirection, workingDirectory: String) throws -> CreatedPane {
        try queue.sync {
            try creating(directory: workingDirectory, environment: [:]) { prepare in
                try model.splitPane(paneID: paneID, direction: direction, workingDirectory: workingDirectory, preparePane: prepare)
            }
        }
    }

    func renameWorkspace(workspaceID: String, label: String) throws {
        try queue.sync { try model.renameWorkspace(workspaceID: workspaceID, label: label) }
    }

    func closeWorkspace(workspaceID: String) throws {
        let closing: [PTYProcess] = try queue.sync {
            try model.closeWorkspace(workspaceID: workspaceID)
            let ids = panes.keys.filter { $0.hasPrefix(workspaceID + ":") }
            var processes: [PTYProcess] = []
            for id in ids {
                if let pane = panes.removeValue(forKey: id), let process = pane.process {
                    retiring[pane.proof] = process; processes.append(process)
                }
            }
            for id in ids { controllers.removeValue(forKey: id) }
            for id in attachments.keys.filter({ attachments[$0]?.paneID.hasPrefix(workspaceID + ":") == true }) { attachments.removeValue(forKey: id) }
            return processes
        }
        closing.forEach { $0.terminate() }
    }

    private func creating(directory: String, environment: [String: String], edit: ((CreatedPane) throws -> Void) throws -> CreatedPane) throws -> CreatedPane {
        var prepared: String?
        do {
            return try edit { created in
                guard self.configuration != nil else { return }
                let pane = try self.launch(paneID: created.paneID, directory: directory, environment: environment, agent: .shell)
                self.panes[created.paneID] = pane; prepared = created.paneID
            }
        } catch {
            if let prepared, let pane = panes.removeValue(forKey: prepared), let process = pane.process {
                retiring[pane.proof] = process; process.terminate()
            }
            throw error
        }
    }

    private func launch(paneID: String, directory: String, environment: [String: String], agent: WorkspaceAgentKind, executable: String? = nil, columns: Int = 80, rows: Int = 24) throws -> PaneProcess {
        guard let configuration else { throw NativeRuntimeOwnerError.unsupported }
        guard panes.values.filter({ $0.process != nil }).count + retiring.count < maximumProcesses else { throw NativeRuntimeOwnerError.limitExceeded }
        var variables = configuration.environment.merging(environment) { _, supplied in supplied }
        variables["TERM"] = "xterm-256color"; variables["COLORTERM"] = "truecolor"
        variables["TERM_PROGRAM"] = "Northpane"; variables["NORTHPANE_PANE_ID"] = paneID
        variables["NORTHPANE_RUNTIME_SOCKET"] = stateDirectory.appending(path: "runtime/runtime.sock").path
        let pane = PaneProcess(directory: directory, environment: environment, agent: agent, columns: columns, rows: rows)
        variables["NORTHPANE_PROCESS_PROOF"] = pane.proof
        let arguments: [String]
        if let executable {
            guard executable.hasPrefix("/"), !executable.utf8.contains(0), FileManager.default.isExecutableFile(atPath: executable) else { throw PTYError.invalidConfiguration }
            let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
            arguments = configuration.arguments + ["-c", "exec " + quoted]
        } else { arguments = configuration.arguments }
        let proof = pane.proof
        pane.process = try PTYProcess.launch(executable: configuration.shell, arguments: arguments,
            directory: directory, environment: variables, columns: columns, rows: rows,
            onOutput: { [weak self] data in self?.output(data, paneID: paneID, proof: proof) },
            onExit: { [weak self] _, _ in self?.exited(paneID: paneID, proof: proof) })
        return pane
    }

    private func output(_ data: Data, paneID: String, proof: String) {
        let response: (PTYProcess, Data)? = queue.sync {
            guard let pane = panes[paneID], pane.proof == proof, let process = pane.process else { return nil }
            pane.engine.feed(data); pane.lastActivity = Date(); model.markRuntimeChange()
            let replies = pane.engine.replies; pane.engine.replies.removeAll(keepingCapacity: true)
            return replies.isEmpty ? nil : (process, replies)
        }
        if let response { try? response.0.sendInput(response.1) }
    }

    private func exited(paneID: String, proof: String) {
        queue.sync {
            retiring.removeValue(forKey: proof)
            guard let pane = panes[paneID], pane.proof == proof else { return }
            pane.process = nil; controllers.removeValue(forKey: paneID); model.markRuntimeChange()
        }
    }

    func open(connectionID: UUID, paneID: String, mode: TerminalAttachMode, columns: Int, rows: Int) throws -> NativeTerminalView {
        try queue.sync {
            try validateDimensions(columns: columns, rows: rows)
            guard attachments.count < maximumAttachments else { throw NativeRuntimeOwnerError.limitExceeded }
            guard let pane = panes[paneID], let process = pane.process else { throw NativeRuntimeOwnerError.processExited }
            if mode == .control && controllers[paneID] != nil { throw NativeRuntimeOwnerError.controlOwnedElsewhere }
            if mode != .observe {
                try process.resize(columns: columns, rows: rows); pane.engine.terminal.resize(cols: columns, rows: rows)
            }
            let attachment = Attachment(connectionID: connectionID, paneID: paneID, processProof: pane.proof, columns: columns, rows: rows)
            attachments[attachment.id] = attachment
            let priorController = controllers[paneID]
            if mode != .observe { controllers[paneID] = attachment.id }
            model.markRuntimeChange()
            do { return try view(attachment, pane: pane) }
            catch {
                attachments.removeValue(forKey: attachment.id)
                if mode != .observe { controllers[paneID] = priorController }
                throw error
            }
        }
    }

    func poll(connectionID: UUID, attachmentID: UUID, afterRevision: Int) throws -> NativeTerminalView {
        try queue.sync {
            let attachment = try attachment(connectionID: connectionID, id: attachmentID)
            guard let pane = panes[attachment.paneID], pane.proof == attachment.processProof else { throw NativeRuntimeOwnerError.processExited }
            if model.currentRevision == afterRevision {
                return NativeTerminalView(attachmentID: attachmentID, processProof: pane.proof, revision: afterRevision, bytes: Data(), controlling: controllers[attachment.paneID] == attachmentID, ended: pane.process == nil)
            }
            return try view(attachment, pane: pane)
        }
    }

    func terminalStatus(connectionID: UUID, attachmentID: UUID) throws -> NativeTerminalView {
        try queue.sync {
            let attachment = try attachment(connectionID: connectionID, id: attachmentID)
            guard let pane = panes[attachment.paneID], pane.proof == attachment.processProof else { throw NativeRuntimeOwnerError.processExited }
            return NativeTerminalView(attachmentID: attachmentID, processProof: pane.proof,
                revision: model.currentRevision, bytes: Data(), controlling: controllers[attachment.paneID] == attachmentID,
                ended: pane.process == nil)
        }
    }

    func input(connectionID: UUID, attachmentID: UUID, bytes: Data) throws {
        let process: PTYProcess = try queue.sync {
            let attachment = try controlling(connectionID: connectionID, id: attachmentID)
            guard let pane = panes[attachment.paneID], let process = pane.process else { throw NativeRuntimeOwnerError.processExited }
            guard bytes.count <= 65_536 else { throw NativeRuntimeOwnerError.limitExceeded }
            pane.acceptsAgentStart = false; attachment.scrollAnchor = nil
            return process
        }
        try process.sendInput(bytes)
    }

    func resize(connectionID: UUID, attachmentID: UUID, columns: Int, rows: Int) throws {
        try queue.sync {
            try validateDimensions(columns: columns, rows: rows)
            let attachment = try controlling(connectionID: connectionID, id: attachmentID)
            guard let pane = panes[attachment.paneID], let process = pane.process else { throw NativeRuntimeOwnerError.processExited }
            try process.resize(columns: columns, rows: rows); pane.engine.terminal.resize(cols: columns, rows: rows)
            attachment.columns = columns; attachment.rows = rows; attachment.scrollAnchor = nil
            model.markRuntimeChange()
        }
    }

    func scroll(connectionID: UUID, attachmentID: UUID, direction: TerminalScrollDirection, lines: Int) throws {
        try queue.sync {
            let attachment = try attachment(connectionID: connectionID, id: attachmentID)
            guard let pane = panes[attachment.paneID] else { throw NativeRuntimeOwnerError.processExited }
            guard !pane.engine.terminal.isCurrentBufferAlternate else { return }
            let buffer = pane.engine.terminal.buffer
            let bottom = buffer.totalLinesTrimmed + buffer.yDisp
            let current = attachment.scrollAnchor ?? bottom
            let delta = min(max(lines, 1), 200) * (direction == .up ? -1 : 1)
            let next = min(bottom, max(buffer.totalLinesTrimmed, current + delta))
            attachment.scrollAnchor = next == bottom ? nil : next
            model.markRuntimeChange()
        }
    }

    func release(connectionID: UUID, attachmentID: UUID) throws {
        try queue.sync {
            let attachment = try controlling(connectionID: connectionID, id: attachmentID)
            controllers.removeValue(forKey: attachment.paneID); model.markRuntimeChange()
        }
    }

    func disconnect(connectionID: UUID) {
        queue.sync {
            let removed = attachments.values.filter { $0.connectionID == connectionID }
            for attachment in removed {
                attachments.removeValue(forKey: attachment.id)
                if controllers[attachment.paneID] == attachment.id { controllers.removeValue(forKey: attachment.paneID) }
            }
            if !removed.isEmpty { model.markRuntimeChange() }
        }
    }

    func scrollbackLines(paneID: String) -> Int {
        queue.sync {
            guard let pane = panes[paneID], !pane.engine.terminal.isCurrentBufferAlternate else { return 0 }
            return pane.engine.terminal.buffer.yDisp
        }
    }

    func lastActivity(paneID: String) -> Date? { queue.sync { panes[paneID]?.lastActivity } }

    func startAgent(paneID: String, kind: WorkspaceAgentKind, executable: String) throws {
        let previous: PTYProcess? = try queue.sync {
            guard let pane = panes[paneID] else { throw NativeWorkspaceStoreError.unknownPane }
            guard pane.process == nil || (pane.agent == .shell && pane.acceptsAgentStart && pane.process?.foregroundProcessID() == pane.process?.processID) else {
                throw NativeRuntimeOwnerError.paneBusy
            }
            let next = try launch(paneID: paneID, directory: pane.directory, environment: pane.environment, agent: kind,
                executable: kind == .shell ? nil : executable, columns: pane.engine.terminal.cols, rows: pane.engine.terminal.rows)
            panes[paneID] = next; model.markRuntimeChange()
            controllers.removeValue(forKey: paneID)
            if let process = pane.process { retiring[pane.proof] = process }
            return pane.process
        }
        previous?.terminate()
    }

    func conversationIdentity(paneID: String) -> RuntimeConversationIdentity? {
        queue.sync {
            guard let pane = panes[paneID], pane.process != nil, pane.agent != .shell else { return nil }
            return RuntimeConversationIdentity(agent: pane.agent.rawValue, processProof: pane.proof)
        }
    }

    private func attachment(connectionID: UUID, id: UUID) throws -> Attachment {
        guard let attachment = attachments[id], attachment.connectionID == connectionID else { throw NativeRuntimeOwnerError.attachmentMissing }
        return attachment
    }

    private func controlling(connectionID: UUID, id: UUID) throws -> Attachment {
        let attachment = try attachment(connectionID: connectionID, id: id)
        guard controllers[attachment.paneID] == id else { throw NativeRuntimeOwnerError.controlRequired }
        guard panes[attachment.paneID]?.proof == attachment.processProof else { throw NativeRuntimeOwnerError.processExited }
        return attachment
    }

    private func validateDimensions(columns: Int, rows: Int) throws {
        guard (1...500).contains(columns), (1...200).contains(rows) else { throw NativeRuntimeOwnerError.invalidDimensions }
    }

    private func view(_ attachment: Attachment, pane: PaneProcess) throws -> NativeTerminalView {
        let buffer = pane.engine.terminal.buffer
        let bottom = buffer.totalLinesTrimmed + buffer.yDisp
        let offset = attachment.scrollAnchor.map { max(0, bottom - max(buffer.totalLinesTrimmed, $0)) } ?? 0
        let bytes = pane.engine.paintFrame(columns: attachment.columns, rows: attachment.rows, scrollOffset: offset, previousAlternate: attachment.paintedAlternate)
        guard bytes.count <= 900_000 else { throw NativeRuntimeOwnerError.limitExceeded }
        attachment.paintedAlternate = pane.engine.terminal.isCurrentBufferAlternate
        return NativeTerminalView(attachmentID: attachment.id, processProof: pane.proof, revision: model.currentRevision,
            bytes: bytes, controlling: controllers[attachment.paneID] == attachment.id, ended: pane.process == nil)
    }
}
#endif
