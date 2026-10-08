#if os(macOS) || os(Linux)
import Foundation
import NorthpaneHostRuntime
import NorthpaneProtocol
import Testing
@testable import NorthpaneNativeRuntime

@Suite struct NativeWorkspaceStoreTests {
    private let host = HostID(rawValue: UUID())
    private func temporary() -> URL { URL(fileURLWithPath: "/tmp/np-layout-" + UUID().uuidString.prefix(12)) }
    private func store(_ root: URL, incarnation: String = UUID().uuidString) throws -> NativeWorkspaceStore {
        try NativeWorkspaceStore(fileURL: root.appending(path: "layout-v1.json"), incarnationID: incarnation)
    }

    @Test func workspaceTabsAndNestedSplitsHaveCoherentStableIdentities() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try store(root)
        let first = try model.createWorkspace(label: "Project", workingDirectory: "/tmp/project")
        #expect(first == CreatedPane(workspaceID: "w1", paneID: "w1:p1"))
        let second = try model.createTab(workspaceID: "w1", workingDirectory: "/tmp/worktree")
        #expect(second.paneID == "w1:p2")
        #expect(try model.splitPane(paneID: "w1:p2", direction: .right, workingDirectory: "/tmp/worktree").paneID == "w1:p3")
        #expect(try model.splitPane(paneID: "w1:p3", direction: .down, workingDirectory: "/tmp/worktree").paneID == "w1:p4")
        try model.renameWorkspace(workspaceID: "w1", label: "Renamed")
        let snapshot = model.snapshot(hostID: host)
        #expect(snapshot.workspaces.count == 1 && snapshot.tabs.count == 2 && snapshot.panes.count == 4)
        #expect(snapshot.workspaces.first?.label == "Renamed")
        #expect(snapshot.workspaces.first?.activeTabID == "w1:t2")
        #expect(snapshot.panes.filter(\.focused).map(\.id) == ["w1:p4"])
        #expect(snapshot.panes.last?.tabID == "w1:t2")
        #expect(snapshot.panes.last?.cwd == "/tmp/worktree")
        #expect(snapshot.panes.allSatisfy { $0.agent == nil && $0.agentStatus == "unknown" })
        #expect(snapshot.capabilities.isEmpty)
        #expect(try model.structure().workspaces[0].tabs[1].root.paneIDs(depth: 0) == ["w1:p2", "w1:p3", "w1:p4"])
    }

    @Test func atomicPersistenceKeepsShapeAcrossANewIncarnationAndNeverReusesClosedIDs() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try store(root)
        _ = try original.createWorkspace(label: "One", workingDirectory: "/tmp/one")
        _ = try original.createWorkspace(label: "Two", workingDirectory: "/tmp/two")
        try original.closeWorkspace(workspaceID: "w1")
        let replacement = try store(root)
        #expect(replacement.structure() == original.structure())
        #expect(replacement.snapshot(hostID: host).incarnationID != original.snapshot(hostID: host).incarnationID)
        #expect(replacement.snapshot(hostID: host).panes.map(\.id) == ["w2:p1"])
        #expect(try replacement.createWorkspace(label: "Three", workingDirectory: "/tmp/three").workspaceID == "w3")
        try replacement.closeWorkspace(workspaceID: "w2")
        try replacement.closeWorkspace(workspaceID: "w3")
        #expect(replacement.snapshot(hostID: host).panes.isEmpty)
        #expect(try replacement.createWorkspace(label: "", workingDirectory: "/tmp/four").workspaceID == "w4")
    }

    @Test func rejectedMutationsLeaveRevisionLayoutAndDiskUnchanged() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try store(root), file = root.appending(path: "layout-v1.json")
        _ = try model.createWorkspace(label: "One", workingDirectory: "/tmp")
        let before = model.snapshot(hostID: host), bytes = try Data(contentsOf: file)
        #expect(throws: NativeWorkspaceStoreError.unknownWorkspace) { try model.createTab(workspaceID: "w99", workingDirectory: "/tmp") }
        #expect(throws: NativeWorkspaceStoreError.unknownPane) { try model.splitPane(paneID: "w1:p99", direction: .down, workingDirectory: "/tmp") }
        #expect(throws: HostRuntimeError.invalidWorkingDirectory("relative")) { try model.createWorkspace(label: "bad", workingDirectory: "relative") }
        #expect(throws: NativeWorkspaceStoreError.invalidLayout) { try model.renameWorkspace(workspaceID: "w1", label: String(repeating: "x", count: 1025)) }
        #expect(model.snapshot(hostID: host) == before)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func aPersistenceFailureNeverPublishesTheMutationOrConsumesAnIdentity() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try store(root), file = root.appending(path: "layout-v1.json")
        _ = try model.createWorkspace(label: "One", workingDirectory: "/tmp")
        let before = model.snapshot(hostID: host), bytes = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: root)
        try Data("not a directory".utf8).write(to: root)
        #expect(throws: (any Error).self) { try model.createWorkspace(label: "Two", workingDirectory: "/tmp") }
        #expect(model.snapshot(hostID: host) == before)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: file)
        #expect(try model.createWorkspace(label: "Two", workingDirectory: "/tmp").workspaceID == "w2")
    }

    @Test func brokenReferencesVersionsAndSplitRatiosAreRefusedInsteadOfReset() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try store(root), file = root.appending(path: "layout-v1.json")
        _ = try model.createWorkspace(label: "One", workingDirectory: "/tmp")
        let valid = model.structure()
        for index in 0..<6 {
            var invalid = valid
            switch index {
            case 0: invalid.format = 99
            case 1: invalid.focusedWorkspaceNumber = 99
            case 2: invalid.workspaces[0].tabs[0].root = .pane("w9:p99")
            case 3: invalid.workspaces[0].nextPaneNumber = 1
            case 4: invalid.workspaces[0].tabs[0].root = .branch(direction: .right, ratio: 0, first: .pane("w1:p1"), second: .pane("w1:p1"))
            default:
                let original = invalid.workspaces[0]
                invalid.workspaces[0] = NativeWorkspace(number: original.number, label: original.label,
                    workingDirectory: "/" + String(repeating: "x", count: 4096),
                    nextTabNumber: original.nextTabNumber, nextPaneNumber: original.nextPaneNumber,
                    activeTabNumber: original.activeTabNumber, tabs: original.tabs)
            }
            let bytes = try JSONEncoder().encode(invalid); try bytes.write(to: file)
            #expect(throws: NativeWorkspaceStoreError.invalidLayout) { try store(root) }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func oversizedSavedLayoutIsBoundedBeforeDecoding() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1_048_577).write(to: root.appending(path: "layout-v1.json"))
        #expect(throws: NativeWorkspaceStoreError.limitExceeded) { try store(root) }
    }

    @Test func simultaneousCreatesPublishWholeGraphsWithoutLosingChanges() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try store(root)
        let identifiers = try await withThrowingTaskGroup(of: String.self) { tasks in
            for index in 1...20 { tasks.addTask { try model.createWorkspace(label: "Project \(index)", workingDirectory: "/tmp").workspaceID } }
            var results: [String] = []
            for try await id in tasks { results.append(id) }
            return results
        }
        #expect(Set(identifiers).count == 20)
        #expect(model.snapshot(hostID: host).workspaces.count == 20)
        #expect(try store(root).structure() == model.structure())
    }
}
#endif
