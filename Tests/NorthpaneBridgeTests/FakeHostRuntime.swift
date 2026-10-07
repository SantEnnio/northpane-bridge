import Foundation
import NorthpaneHostRuntime
import NorthpaneProtocol

/// An independent adapter for Bridge contract tests. Runtime state belongs to
/// this actor, so replacing a Bridge connection cannot erase Workspace or Pane state.
actor FakeHostRuntime: HostRuntime {
    let descriptor = RuntimeDescriptor(kind: .native, version: "test", incarnationID: UUID().uuidString)
    private var workspaces: [WireWorkspace] = []
    private var tabs: [WireTab] = []
    private var panes: [WirePane] = []
    private var terminals: [String: FakeTerminal] = [:]
    private var observers: [FakeRuntimeChanges] = []
    private var nextWorkspace = 1
    private var nextPane = 1
    private var nextTab = 1
    private(set) var running = false

    func ensureRunning() { running = true }

    func currentSnapshot(hostID: HostID) -> WireRuntimeSnapshot {
        WireRuntimeSnapshot(hostID: hostID, incarnationID: descriptor.incarnationID, snapshotID: UUID().uuidString,
                            nextEventSequence: 0, panes: panes, capabilities: Set(Capability.allCases),
                            workspaces: workspaces, tabs: tabs)
    }

    func changes() -> any RuntimeChanges {
        let observer = FakeRuntimeChanges()
        observers.append(observer)
        return observer
    }

    func createWorkspace(label: String, workingDirectory: String, environment: [String: String]) -> CreatedPane {
        let id = "w\(nextWorkspace)"
        nextWorkspace += 1
        let created = addPane(workspaceID: id, tabID: addTab(workspaceID: id), directory: workingDirectory)
        workspaces.append(WireWorkspace(id: id, label: label, number: nextWorkspace - 1, focused: false,
                                       activeTabID: panes.last!.tabID, worktreePath: workingDirectory))
        changed()
        return created
    }

    func createTab(workspaceID: String, workingDirectory: String) throws -> CreatedPane {
        guard workspaces.contains(where: { $0.id == workspaceID }) else { throw Problem.malformedFrame }
        let created = addPane(workspaceID: workspaceID, tabID: addTab(workspaceID: workspaceID), directory: workingDirectory)
        changed()
        return created
    }

    func splitPane(paneID: String, direction: PaneSplitDirection, workingDirectory: String) throws -> CreatedPane {
        guard let source = panes.first(where: { $0.id == paneID }) else { throw Problem.malformedFrame }
        let created = addPane(workspaceID: source.workspaceID, tabID: source.tabID, directory: workingDirectory)
        changed()
        return created
    }

    func renameWorkspace(workspaceID: String, label: String) throws {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { throw Problem.malformedFrame }
        let previous = workspaces[index]
        workspaces[index] = WireWorkspace(id: previous.id, label: label, number: previous.number, focused: previous.focused,
                                         activeTabID: previous.activeTabID, worktreePath: previous.worktreePath)
        changed()
    }

    func closeWorkspace(workspaceID: String) {
        for pane in panes where pane.workspaceID == workspaceID { terminals.removeValue(forKey: pane.id)?.close() }
        panes.removeAll { $0.workspaceID == workspaceID }
        tabs.removeAll { $0.workspaceID == workspaceID }
        workspaces.removeAll { $0.id == workspaceID }
        changed()
    }

    func startAgent(_ kind: WorkspaceAgentKind, executableURL: URL, name: String, paneID: String) throws {
        guard let index = panes.firstIndex(where: { $0.id == paneID }) else { throw Problem.malformedFrame }
        let previous = panes[index]
        panes[index] = WirePane(id: previous.id, title: name, workspaceID: previous.workspaceID, tabID: previous.tabID,
                                agent: kind.rawValue, agentStatus: "idle", cwd: previous.cwd)
        changed()
    }

    func hostScrollbackLines(paneID: String) -> Int { terminals[paneID]?.scrollbackLines ?? 0 }
    func paneActivity(paneIDs: [String]) -> [String: Date] { [:] }

    func makeTerminalChannel(paneID: String, mode: TerminalAttachMode) throws -> any TerminalChannel {
        guard let terminal = terminals[paneID] else { throw Problem.malformedFrame }
        return FakeTerminalChannel(terminal: terminal, mode: mode)
    }

    private func addTab(workspaceID: String) -> String {
        let id = "\(workspaceID):t\(nextTab)"
        tabs.append(WireTab(id: id, workspaceID: workspaceID, label: "", number: nextTab, focused: false))
        nextTab += 1
        return id
    }

    private func addPane(workspaceID: String, tabID: String, directory: String) -> CreatedPane {
        let id = "\(workspaceID):p\(nextPane)"
        nextPane += 1
        panes.append(WirePane(id: id, title: "Shell", workspaceID: workspaceID, tabID: tabID, cwd: directory))
        terminals[id] = FakeTerminal()
        return CreatedPane(workspaceID: workspaceID, paneID: id)
    }

    private func changed() { for observer in observers { observer.changed() } }
}

private final class FakeRuntimeChanges: RuntimeChanges, @unchecked Sendable {
    private let lock = NSLock()
    private var onEvent: (@Sendable () -> Void)?
    func start(onEvent: @escaping @Sendable () -> Void, onClose: @escaping @Sendable (Error?) -> Void) async throws {
        lock.withLock { self.onEvent = onEvent }
    }
    func updatePaneIDs(_ paneIDs: [String]) async {}
    func stop() { lock.withLock { onEvent = nil } }
    func changed() { lock.withLock { onEvent }?() }
}

private final class FakeTerminal: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var outputs: [UUID: @Sendable (Data) -> Void] = [:]
    private var endings: [UUID: @Sendable (Error?) -> Void] = [:]
    private var controller: UUID?
    private var closed = false
    var scrollbackLines: Int { lock.withLock { bytes.filter { $0 == 10 }.count } }

    func attach(id: UUID, mode: TerminalAttachMode, output: @escaping @Sendable (Data) -> Void,
                close: @escaping @Sendable (Error?) -> Void) throws {
        let initial = try lock.withLock {
            guard !closed, mode == .observe || controller == nil || mode == .takeover else { throw Problem.unauthorized }
            if mode != .observe { controller = id }
            outputs[id] = output
            endings[id] = close
            return Data("\u{1b}[2J".utf8) + bytes
        }
        output(initial)
    }

    func send(_ data: Data, from id: UUID) throws {
        let callbacks = try lock.withLock {
            guard !closed, controller == id else { throw Problem.unauthorized }
            bytes.append(data)
            return Array(outputs.values)
        }
        for callback in callbacks { callback(data) }
    }

    func checkControl(_ id: UUID) throws {
        try lock.withLock { guard !closed, controller == id else { throw Problem.unauthorized } }
    }

    func detach(_ id: UUID) {
        lock.withLock {
            outputs.removeValue(forKey: id); endings.removeValue(forKey: id)
            if controller == id { controller = nil }
        }
    }

    func close() {
        let callbacks = lock.withLock {
            closed = true
            let callbacks = Array(endings.values)
            outputs.removeAll(); endings.removeAll(); controller = nil
            return callbacks
        }
        for callback in callbacks { callback(nil) }
    }
}

private struct FakeTerminalChannel: TerminalChannel {
    let terminal: FakeTerminal
    let mode: TerminalAttachMode
    private let id = UUID()
    init(terminal: FakeTerminal, mode: TerminalAttachMode) { self.terminal = terminal; self.mode = mode }
    func start(columns: Int, rows: Int, onOutput: @escaping @Sendable (Data) -> Void,
               onClose: @escaping @Sendable (Error?) -> Void) throws {
        try terminal.attach(id: id, mode: mode, output: onOutput, close: onClose)
    }
    func sendInput(_ data: Data) throws { try terminal.send(data, from: id) }
    func resize(columns: Int, rows: Int) throws { try terminal.checkControl(id) }
    func scroll(direction: TerminalScrollDirection, lines: Int) throws { try terminal.checkControl(id) }
    func release() throws { terminal.detach(id) }
    func stop() { terminal.detach(id) }
}
