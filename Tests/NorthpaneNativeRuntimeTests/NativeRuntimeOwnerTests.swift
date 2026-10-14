#if os(macOS) || os(Linux)
import Foundation
import Testing
import NorthpaneHostRuntime
import NorthpaneBridgeCore
#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import NorthpaneProtocol
@testable import NorthpaneNativeRuntime

@Suite struct NativeRuntimeOwnerTests {
    private func withOwner(_ body: (URL, NativeRuntimeOwner) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: "/tmp/np-own-" + UUID().uuidString.prefix(12))
        try FileManager.default.createDirectory(at: directory.appending(path: "home"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = NativeProcessConfiguration(shell: "/bin/sh", arguments: ["-i"],
            environment: ["HOME": directory.appending(path: "home").path, "ENV": "/dev/null", "PATH": "/usr/bin:/bin", "PS1": "probe$ "])
        let owner = try NativeRuntimeOwner(stateDirectory: directory, incarnationID: UUID().uuidString, configuration: configuration)
        try await body(directory, owner)
    }

    private func waitFor(_ text: String, owner: NativeRuntimeOwner, connection: UUID, attachment: UUID) async throws -> NativeTerminalView {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            let view = try owner.poll(connectionID: connection, attachmentID: attachment, afterRevision: -1)
            if String(decoding: view.bytes, as: UTF8.self).contains(text) { return view }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw NativeRuntimeProcessError.startupTimedOut
    }

    @Test func disconnectLeavesTheSameLivePtyAndAllowsNewControl() async throws {
        try await withOwner { directory, owner in
            let pane = try owner.createWorkspace(label: "Project", workingDirectory: directory.path)
            let first = UUID()
            let attachment = try owner.open(connectionID: first, paneID: pane.paneID, mode: .control, columns: 80, rows: 24)
            // Octal escapes keep the expected result out of the echoed command.
            try owner.input(connectionID: first, attachmentID: attachment.attachmentID,
                bytes: Data("printf '\\156\\160\\055\\162\\145\\163\\165\\154\\164\\012'\r".utf8))
            _ = try await waitFor("np-result", owner: owner, connection: first, attachment: attachment.attachmentID)
            owner.disconnect(connectionID: first)
            let second = UUID()
            let reopened = try owner.open(connectionID: second, paneID: pane.paneID, mode: .control, columns: 80, rows: 24)
            #expect(reopened.processProof == attachment.processProof && !reopened.ended)
            #expect(String(decoding: reopened.bytes, as: UTF8.self).contains("np-result"))
            #expect(throws: NativeRuntimeOwnerError.attachmentMissing) {
                try owner.input(connectionID: first, attachmentID: attachment.attachmentID, bytes: Data("must not arrive".utf8))
            }
            try owner.closeWorkspace(workspaceID: pane.workspaceID)
        }
    }

    @Test func leasesAreGlobalAndTakeoverImmediatelyRevokesThePreviousController() async throws {
        try await withOwner { directory, owner in
            let pane = try owner.createWorkspace(label: "Project", workingDirectory: directory.path)
            let first = UUID(), second = UUID()
            let a = try owner.open(connectionID: first, paneID: pane.paneID, mode: .control, columns: 80, rows: 24)
            #expect(throws: NativeRuntimeOwnerError.controlOwnedElsewhere) {
                try owner.open(connectionID: second, paneID: pane.paneID, mode: .control, columns: 40, rows: 12)
            }
            let observer = try owner.open(connectionID: second, paneID: pane.paneID, mode: .observe, columns: 40, rows: 12)
            #expect(!observer.controlling && observer.processProof == a.processProof)
            #expect(throws: NativeRuntimeOwnerError.controlRequired) {
                try owner.resize(connectionID: second, attachmentID: observer.attachmentID, columns: 100, rows: 30)
            }
            #expect(throws: NativeRuntimeOwnerError.attachmentMissing) {
                try owner.input(connectionID: second, attachmentID: a.attachmentID, bytes: Data("must not arrive".utf8))
            }
            let b = try owner.open(connectionID: second, paneID: pane.paneID, mode: .takeover, columns: 40, rows: 12)
            #expect(b.controlling && b.processProof == a.processProof)
            #expect(!((try owner.poll(connectionID: first, attachmentID: a.attachmentID, afterRevision: -1)).controlling))
            #expect(throws: NativeRuntimeOwnerError.controlRequired) {
                try owner.input(connectionID: first, attachmentID: a.attachmentID, bytes: Data("must not arrive".utf8))
            }
            try owner.release(connectionID: second, attachmentID: b.attachmentID)
            #expect(try owner.open(connectionID: first, paneID: pane.paneID, mode: .control, columns: 80, rows: 24).controlling)
            try owner.closeWorkspace(workspaceID: pane.workspaceID)
        }
    }

    @Test func failedProcessLaunchCannotPublishShapeOrConsumeAnIdentity() async throws {
        try await withOwner { directory, owner in
            let host = HostID(rawValue: UUID())
            let before = owner.snapshot(hostID: host)
            #expect(throws: PTYError.self) {
                try owner.createWorkspace(label: "Missing", workingDirectory: directory.appending(path: "missing").path)
            }
            #expect(owner.snapshot(hostID: host) == before)
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "runtime/layout-v1.json").path))
            let created = try owner.createWorkspace(label: "Valid", workingDirectory: directory.path,
                environment: ["TEST_TRANSIENT_VALUE": "never persist"])
            #expect(created.workspaceID == "w1")
            let saved = try Data(contentsOf: directory.appending(path: "runtime/layout-v1.json"))
            let layout = String(decoding: saved, as: UTF8.self)
            #expect(!layout.contains("TEST_TRANSIENT_VALUE") && !layout.contains("never persist"))
            try owner.closeWorkspace(workspaceID: created.workspaceID)
        }
    }

    @Test func modelReloadDoesNotPretendToRestoreExitedProcesses() async throws {
        try await withOwner { directory, owner in
            let created = try owner.createWorkspace(label: "Project", workingDirectory: directory.path)
            let replacement = try NativeRuntimeOwner(stateDirectory: directory, incarnationID: UUID().uuidString, configuration: nil)
            let host = HostID(rawValue: UUID())
            #expect(replacement.snapshot(hostID: host).panes.map(\.id) == [created.paneID])
            #expect(replacement.snapshot(hostID: host).incarnationID != owner.snapshot(hostID: host).incarnationID)
            #expect(throws: NativeRuntimeOwnerError.processExited) {
                try replacement.open(connectionID: UUID(), paneID: created.paneID, mode: .control, columns: 80, rows: 24)
            }
            try owner.closeWorkspace(workspaceID: created.workspaceID)
        }
    }

    @Test func replacingAFreshShellInvalidatesItsAttachmentsAndOldExitCallbacks() async throws {
        try await withOwner { directory, owner in
            let pane = try owner.createWorkspace(label: "Project", workingDirectory: directory.path)
            let connection = UUID()
            let old = try owner.open(connectionID: connection, paneID: pane.paneID, mode: .control, columns: 80, rows: 24)
            // A local synthetic process stands in for an agent; no provider is run.
            try owner.startAgent(paneID: pane.paneID, kind: .codex, executable: "/bin/cat")
            #expect(throws: NativeRuntimeOwnerError.processExited) {
                try owner.poll(connectionID: connection, attachmentID: old.attachmentID, afterRevision: -1)
            }
            let fresh = try owner.open(connectionID: connection, paneID: pane.paneID, mode: .control, columns: 80, rows: 24)
            #expect(fresh.processProof != old.processProof)
            #expect(owner.conversationIdentity(paneID: pane.paneID)?.processProof == fresh.processProof)
            try await Task.sleep(for: .milliseconds(2300))
            #expect(!((try owner.poll(connectionID: connection, attachmentID: fresh.attachmentID, afterRevision: -1)).ended))
            #expect(throws: NativeRuntimeOwnerError.paneBusy) {
                try owner.startAgent(paneID: pane.paneID, kind: .claude, executable: "/bin/cat")
            }
            try owner.closeWorkspace(workspaceID: pane.workspaceID)
        }
    }

    @Test func lifecycleEvidenceIsBoundToTheProcessAndRootSessionAndDeduplicatesAttention() async throws {
        try await withOwner { directory, owner in
            let host = HostID()
            let created = try owner.createWorkspace(label: "Project", workingDirectory: directory.path)
            try owner.startAgent(paneID: created.paneID, kind: .codex, executable: "/bin/cat")
            let identity = try #require(owner.conversationIdentity(paneID: created.paneID))
            let proof = try #require(identity.processProof)
            #expect(owner.snapshot(hostID: host).panes.first?.agentStatus == "unknown")
            // Hooks may be trusted after SessionStart has already been skipped.
            try owner.agentHook(paneID: created.paneID, proof: proof, event: "working", sessionID: "root", directory: "")
            #expect(owner.snapshot(hostID: host).panes.first?.agentStatus == "working")
            try owner.agentHook(paneID: created.paneID, proof: proof, event: "start", sessionID: "root", directory: directory.path)
            var attention = AttentionTransitionTracker(grace: 0)
            #expect(attention.observe(owner.snapshot(hostID: host).panes).isEmpty)
            try owner.agentHook(paneID: created.paneID, proof: proof, event: "working", sessionID: "root", directory: "")
            #expect(attention.observe(owner.snapshot(hostID: host).panes).isEmpty)
            try owner.agentHook(paneID: created.paneID, proof: proof, event: "blocked", sessionID: "root", directory: "")
            #expect(attention.observe(owner.snapshot(hostID: host).panes).map(\.id) == [created.paneID])
            let revision = owner.revision
            try owner.agentHook(paneID: created.paneID, proof: proof, event: "blocked", sessionID: "root", directory: "")
            #expect(owner.revision == revision)
            #expect(attention.observe(owner.snapshot(hostID: host).panes).isEmpty)
            #expect(throws: NativeRuntimeOwnerError.processExited) {
                try owner.agentHook(paneID: created.paneID, proof: UUID().uuidString, event: "idle", sessionID: "root", directory: "")
            }
            #expect(throws: NativeRuntimeProcessError.rejected("hook_session_mismatch")) {
                try owner.agentHook(paneID: created.paneID, proof: proof, event: "idle", sessionID: "subagent", directory: "")
            }
            try owner.agentHook(paneID: created.paneID, proof: proof, event: "working", sessionID: "root", directory: "")
            #expect(attention.observe(owner.snapshot(hostID: host).panes).isEmpty)
            try owner.agentHook(paneID: created.paneID, proof: proof, event: "blocked", sessionID: "root", directory: "")
            #expect(attention.observe(owner.snapshot(hostID: host).panes).count == 1)
            try owner.agentHook(paneID: created.paneID, proof: proof, event: "idle", sessionID: "root", directory: "")
            try owner.agentHook(paneID: created.paneID, proof: proof, event: "blocked", sessionID: "root", directory: "", requestProof: "one")
            try owner.agentHook(paneID: created.paneID, proof: proof, event: "blocked", sessionID: "root", directory: "", requestProof: "two")
            try owner.agentHook(paneID: created.paneID, proof: proof, event: "working", sessionID: "root", directory: "", requestProof: "one")
            #expect(owner.snapshot(hostID: host).panes.first?.agentStatus == "blocked")
            try owner.agentHook(paneID: created.paneID, proof: proof, event: "working", sessionID: "root", directory: "", requestProof: "two")
            #expect(owner.snapshot(hostID: host).panes.first?.agentStatus == "working")
            #expect(owner.conversationIdentity(paneID: created.paneID)?.sessionID == "root")
            try owner.agentHook(paneID: created.paneID, proof: proof, event: "start", sessionID: "new-root", directory: "")
            #expect(owner.conversationIdentity(paneID: created.paneID)?.sessionID == "new-root")
            let layout = try String(contentsOf: directory.appending(path: "runtime/layout-v1.json"), encoding: .utf8)
            #expect(!layout.contains("sessionID") && !layout.contains(proof))
            try owner.closeWorkspace(workspaceID: created.workspaceID)
        }
    }

    @Test func manualAgentsHaveBirthProofsButNoInventedStatusAndCwdFollowsTheProcess() async throws {
        try await withOwner { directory, owner in
            let home = directory.appending(path: "next")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let executable = home.appending(path: "codex")
            // A harmless local cat copy exercises kernel process identity.
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/cat"), to: executable)
            let created = try owner.createWorkspace(label: "Project", workingDirectory: directory.path)
            let connection = UUID()
            let attached = try owner.open(connectionID: connection, paneID: created.paneID, mode: .control, columns: 80, rows: 24)
            try owner.input(connectionID: connection, attachmentID: attached.attachmentID,
                bytes: Data(("cd " + NativeAgentLaunch.shellQuote(home.path) + "; printf '\\143\\167\\144\\055\\162\\145\\141\\144\\171\\012'\r").utf8))
            _ = try await waitFor("cwd-ready", owner: owner, connection: connection, attachment: attached.attachmentID)
            let canonical = try #require(realpath(home.path, nil))
            defer { free(canonical) }
            #expect(owner.snapshot(hostID: HostID()).panes.first?.cwd == String(cString: canonical))
            try owner.input(connectionID: connection, attachmentID: attached.attachmentID,
                bytes: Data((NativeAgentLaunch.shellQuote(executable.path) + "\r").utf8))
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while owner.conversationIdentity(paneID: created.paneID) == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let identity = try #require(owner.conversationIdentity(paneID: created.paneID))
            #expect(identity.agent == "codex" && identity.sessionID == nil && identity.processProof != nil)
            #expect(owner.conversationIdentity(paneID: created.paneID) == identity)
            #expect(owner.snapshot(hostID: HostID()).panes.first?.agentStatus == "unknown")
            try owner.input(connectionID: connection, attachmentID: attached.attachmentID, bytes: Data([3]))
            let exited = ContinuousClock.now.advanced(by: .seconds(3))
            while owner.conversationIdentity(paneID: created.paneID) != nil && ContinuousClock.now < exited {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(owner.conversationIdentity(paneID: created.paneID) == nil)
            try owner.closeWorkspace(workspaceID: created.workspaceID)
        }
    }

}
#endif
