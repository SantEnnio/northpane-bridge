import Foundation
import NorthpaneHostRuntime
import NorthpaneProtocol

enum NativeWorkspaceStoreError: Error, Equatable {
    case invalidLayout
    case unknownWorkspace
    case unknownPane
    case limitExceeded
}

/// The daemon's shape store. It must live under the daemon's exclusive process
/// lock. Every operation publishes one coherent graph only after atomic persistence.
/// No process environment, input, terminal contents or agent credentials are stored.
final class NativeWorkspaceStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private let incarnationID: String
    private var layout: NativeLayout
    private var revision = 0
    private static let maximumFileBytes = 1_048_576

    init(fileURL: URL, incarnationID: String) throws {
        guard fileURL.isFileURL, UUID(uuidString: incarnationID) != nil else { throw NativeWorkspaceStoreError.invalidLayout }
        self.fileURL = fileURL; self.incarnationID = incarnationID
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let file = try FileHandle(forReadingFrom: fileURL)
            defer { try? file.close() }
            let bytes = try file.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
            guard bytes.count <= Self.maximumFileBytes else { throw NativeWorkspaceStoreError.limitExceeded }
            layout = try JSONDecoder().decode(NativeLayout.self, from: bytes)
            try layout.validate()
        } else { layout = NativeLayout() }
    }

    func createWorkspace(label: String, workingDirectory: String) throws -> CreatedPane {
        try validateDirectory(workingDirectory)
        return try transact { layout in
            let number = layout.nextWorkspaceNumber
            guard number < Int.max - 1 else { throw NativeWorkspaceStoreError.limitExceeded }
            layout.nextWorkspaceNumber += 1
            let id = "w\(number)", pane = "\(id):p1"
            let tab = NativeTab(number: 1, root: .pane(pane), activePaneNumber: 1,
                panes: [NativePane(number: 1, workingDirectory: workingDirectory)])
            layout.workspaces.append(NativeWorkspace(number: number, label: label.isEmpty ? id : label,
                workingDirectory: workingDirectory, nextTabNumber: 2, nextPaneNumber: 2,
                activeTabNumber: 1, tabs: [tab]))
            layout.focusedWorkspaceNumber = number
            return CreatedPane(workspaceID: id, paneID: pane)
        }
    }

    func createTab(workspaceID: String, workingDirectory: String) throws -> CreatedPane {
        try validateDirectory(workingDirectory)
        return try transact { layout in
            guard let index = layout.workspaces.firstIndex(where: { $0.id == workspaceID }) else { throw NativeWorkspaceStoreError.unknownWorkspace }
            var workspace = layout.workspaces[index]
            let paneNumber = workspace.nextPaneNumber, tabNumber = workspace.nextTabNumber
            guard paneNumber < Int.max - 1, tabNumber < Int.max - 1 else { throw NativeWorkspaceStoreError.limitExceeded }
            workspace.nextPaneNumber += 1; workspace.nextTabNumber += 1
            let pane = "\(workspaceID):p\(paneNumber)"
            workspace.tabs.append(NativeTab(number: tabNumber, root: .pane(pane), activePaneNumber: paneNumber,
                panes: [NativePane(number: paneNumber, workingDirectory: workingDirectory)]))
            workspace.activeTabNumber = tabNumber
            layout.workspaces[index] = workspace; layout.focusedWorkspaceNumber = workspace.number
            return CreatedPane(workspaceID: workspaceID, paneID: pane)
        }
    }

    func splitPane(paneID: String, direction: PaneSplitDirection, workingDirectory: String) throws -> CreatedPane {
        try validateDirectory(workingDirectory)
        return try transact { layout in
            for wi in layout.workspaces.indices {
                for ti in layout.workspaces[wi].tabs.indices {
                    let workspaceID = layout.workspaces[wi].id
                    guard layout.workspaces[wi].tabs[ti].panes.contains(where: { "\(workspaceID):p\($0.number)" == paneID }) else { continue }
                    let number = layout.workspaces[wi].nextPaneNumber
                    guard number < Int.max - 1 else { throw NativeWorkspaceStoreError.limitExceeded }
                    let created = "\(workspaceID):p\(number)"
                    let replacement = NativeSplit.branch(direction: direction, ratio: 0.5, first: .pane(paneID), second: .pane(created))
                    layout.workspaces[wi].tabs[ti].root = layout.workspaces[wi].tabs[ti].root.replacing(paneID, with: replacement)
                    layout.workspaces[wi].tabs[ti].panes.append(NativePane(number: number, workingDirectory: workingDirectory))
                    layout.workspaces[wi].tabs[ti].activePaneNumber = number
                    layout.workspaces[wi].nextPaneNumber += 1
                    layout.workspaces[wi].activeTabNumber = layout.workspaces[wi].tabs[ti].number
                    layout.focusedWorkspaceNumber = layout.workspaces[wi].number
                    return CreatedPane(workspaceID: workspaceID, paneID: created)
                }
            }
            throw NativeWorkspaceStoreError.unknownPane
        }
    }

    func renameWorkspace(workspaceID: String, label: String) throws {
        try transact { layout in
            guard let index = layout.workspaces.firstIndex(where: { $0.id == workspaceID }) else { throw NativeWorkspaceStoreError.unknownWorkspace }
            layout.workspaces[index].label = label.isEmpty ? workspaceID : label
        }
    }

    func closeWorkspace(workspaceID: String) throws {
        try transact { layout in
            guard let index = layout.workspaces.firstIndex(where: { $0.id == workspaceID }) else { throw NativeWorkspaceStoreError.unknownWorkspace }
            let removed = layout.workspaces.remove(at: index)
            if layout.focusedWorkspaceNumber == removed.number { layout.focusedWorkspaceNumber = layout.workspaces.first?.number }
        }
    }

    /// Shape only; live terminal/process metadata is added by the runtime owner.
    func snapshot(hostID: HostID) -> WireRuntimeSnapshot {
        lock.withLock {
            var workspaces: [WireWorkspace] = [], tabs: [WireTab] = [], panes: [WirePane] = []
            for workspace in layout.workspaces {
                let focused = layout.focusedWorkspaceNumber == workspace.number
                workspaces.append(WireWorkspace(id: workspace.id, label: workspace.label, number: workspace.number,
                    focused: focused, activeTabID: "\(workspace.id):t\(workspace.activeTabNumber)", worktreePath: workspace.workingDirectory))
                for tab in workspace.tabs {
                    let tabID = "\(workspace.id):t\(tab.number)", active = focused && workspace.activeTabNumber == tab.number
                    tabs.append(WireTab(id: tabID, workspaceID: workspace.id, label: "t\(tab.number)", number: tab.number, focused: active))
                    for pane in tab.panes {
                        let id = "\(workspace.id):p\(pane.number)"
                        panes.append(WirePane(id: id, title: id, workspaceID: workspace.id, tabID: tabID, revision: revision,
                            agentStatus: "unknown", focused: active && tab.activePaneNumber == pane.number, cwd: pane.workingDirectory))
                    }
                }
            }
            return WireRuntimeSnapshot(hostID: hostID, incarnationID: incarnationID, snapshotID: "\(incarnationID):\(revision)",
                nextEventSequence: revision + 1, panes: panes, capabilities: [], workspaces: workspaces, tabs: tabs)
        }
    }

    func structure() -> NativeLayout { lock.withLock { layout } }

    private func transact<T>(_ edit: (inout NativeLayout) throws -> T) throws -> T {
        try lock.withLock {
            var next = layout
            let result = try edit(&next)
            try next.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(next)
            guard data.count <= Self.maximumFileBytes, revision < Int.max - 1 else { throw NativeWorkspaceStoreError.limitExceeded }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            layout = next; revision += 1
            return result
        }
    }
    private func validateDirectory(_ directory: String) throws {
        guard directory.hasPrefix("/"), !directory.utf8.contains(0), directory.utf8.count <= 4096 else {
            throw HostRuntimeError.invalidWorkingDirectory(directory)
        }
    }
}

struct NativeLayout: Codable, Equatable, Sendable {
    var format = 1
    var nextWorkspaceNumber = 1
    var focusedWorkspaceNumber: Int?
    var workspaces: [NativeWorkspace] = []

    func validate() throws {
        guard format == 1, nextWorkspaceNumber > 0, nextWorkspaceNumber < Int.max,
              workspaces.count <= 100, Set(workspaces.map(\.number)).count == workspaces.count,
              focusedWorkspaceNumber == nil ? workspaces.isEmpty : workspaces.contains(where: { $0.number == focusedWorkspaceNumber }) else {
            throw NativeWorkspaceStoreError.invalidLayout
        }
        var count = 0
        for workspace in workspaces {
            guard workspace.number > 0, workspace.number < nextWorkspaceNumber,
                  workspace.nextTabNumber > 0, workspace.nextTabNumber < Int.max,
                  workspace.nextPaneNumber > 0, workspace.nextPaneNumber < Int.max,
                  workspace.label.utf8.count <= 1024, workspace.workingDirectory.hasPrefix("/"),
                  !workspace.workingDirectory.utf8.contains(0), workspace.workingDirectory.utf8.count <= 4096,
                  !workspace.tabs.isEmpty, workspace.tabs.contains(where: { $0.number == workspace.activeTabNumber }),
                  Set(workspace.tabs.map(\.number)).count == workspace.tabs.count else { throw NativeWorkspaceStoreError.invalidLayout }
            var paneNumbers: Set<Int> = []
            for tab in workspace.tabs {
                guard tab.number > 0, tab.number < workspace.nextTabNumber, !tab.panes.isEmpty,
                      tab.panes.contains(where: { $0.number == tab.activePaneNumber }) else { throw NativeWorkspaceStoreError.invalidLayout }
                let ids = try tab.root.paneIDs(depth: 0)
                guard ids.count == tab.panes.count, Set(ids).count == ids.count,
                      Set(ids) == Set(tab.panes.map { "\(workspace.id):p\($0.number)" }) else { throw NativeWorkspaceStoreError.invalidLayout }
                for pane in tab.panes {
                    guard pane.number > 0, pane.number < workspace.nextPaneNumber,
                          paneNumbers.insert(pane.number).inserted, pane.workingDirectory.hasPrefix("/"),
                          !pane.workingDirectory.utf8.contains(0), pane.workingDirectory.utf8.count <= 4096 else { throw NativeWorkspaceStoreError.invalidLayout }
                    count += 1
                }
            }
        }
        guard count <= 2000 else { throw NativeWorkspaceStoreError.limitExceeded }
    }
}

struct NativeWorkspace: Codable, Equatable, Sendable {
    let number: Int
    var label: String
    let workingDirectory: String
    var nextTabNumber: Int
    var nextPaneNumber: Int
    var activeTabNumber: Int
    var tabs: [NativeTab]
    var id: String { "w\(number)" }
}
struct NativeTab: Codable, Equatable, Sendable {
    let number: Int
    var root: NativeSplit
    var activePaneNumber: Int
    var panes: [NativePane]
}
struct NativePane: Codable, Equatable, Sendable {
    let number: Int
    let workingDirectory: String
}
indirect enum NativeSplit: Codable, Equatable, Sendable {
    case pane(String)
    case branch(direction: PaneSplitDirection, ratio: Double, first: NativeSplit, second: NativeSplit)
    func paneIDs(depth: Int) throws -> [String] {
        guard depth <= 64 else { throw NativeWorkspaceStoreError.limitExceeded }
        switch self {
        case let .pane(id): return [id]
        case let .branch(_, ratio, first, second):
            guard ratio.isFinite, ratio > 0, ratio < 1 else { throw NativeWorkspaceStoreError.invalidLayout }
            return try first.paneIDs(depth: depth + 1) + second.paneIDs(depth: depth + 1)
        }
    }
    func replacing(_ id: String, with replacement: NativeSplit) -> NativeSplit {
        switch self {
        case let .pane(current): return current == id ? replacement : self
        case let .branch(direction, ratio, first, second):
            return .branch(direction: direction, ratio: ratio,
                first: first.replacing(id, with: replacement), second: second.replacing(id, with: replacement))
        }
    }
}
