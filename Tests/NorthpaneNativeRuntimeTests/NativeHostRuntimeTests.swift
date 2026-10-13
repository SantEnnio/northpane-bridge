#if os(macOS) || os(Linux)
import Foundation
import Testing
import NorthpaneHostRuntime
import NorthpaneProtocol
@testable import NorthpaneNativeRuntime

@Suite struct NativeHostRuntimeTests {
    private func isolated(_ body: (URL, NativeRuntimeServer, NativeHostRuntime, HostID) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: "/tmp/np-adapt-" + UUID().uuidString.prefix(10))
        let home = directory.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = NativeProcessConfiguration(shell: "/bin/sh", arguments: ["-i"],
            environment: ["HOME": home.path, "ENV": "/dev/null", "PATH": "/usr/bin:/bin", "PS1": "probe$ "])
        let server = try NativeRuntimeServer(stateDirectory: directory, version: "test", workspaceModelEnabled: true, processConfiguration: configuration)
        let done = AsyncStream<Void>.makeStream()
        Thread.detachNewThread { try? server.run(); done.continuation.yield(()); done.continuation.finish() }
        let host = HostID(rawValue: UUID())
        let runtime = NativeHostRuntime(stateDirectory: directory, hostID: host,
            connect: { try await NativeRuntimeConnection.connect(stateDirectory: directory) })
        do { try await body(directory, server, runtime, host) }
        catch { server.stop(); for await _ in done.stream {}; throw error }
        server.stop(); for await _ in done.stream {}
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw NativeRuntimeProcessError.startupTimedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func runtimeContractKeepsAProcessAcrossChannelDetachAndReportsMutations() async throws {
        try await isolated { directory, _, runtime, host in
            let adapter: any HostRuntime = runtime
            try await adapter.ensureRunning()
            #expect(await adapter.descriptor.kind == .native)
            let updates = NativeCallbackCapture()
            let changes = await adapter.changes()
            try await changes.start(onEvent: { updates.event() }, onClose: { updates.close($0) })
            defer { changes.stop() }
            #expect(try await adapter.currentSnapshot(hostID: host).panes.isEmpty)
            let pane = try await adapter.createWorkspace(label: "Project", workingDirectory: directory.path, environment: [:])
            try await wait { updates.events > 0 }
            let first = try await adapter.makeTerminalChannel(paneID: pane.paneID, mode: .control)
            let output = NativeCallbackCapture()
            try first.start(columns: 80, rows: 24, onOutput: { output.frame($0) }, onClose: { output.close($0) })
            try first.sendInput(Data("printf '\\141\\144\\141\\160\\164\\145\\162\\055\\162\\145\\163\\165\\154\\164\\012'\r".utf8))
            try await wait { output.text.contains("adapter-result") }
            #expect(await adapter.hostScrollbackLines(paneID: pane.paneID) >= 0)
            #expect(await adapter.paneActivity(paneIDs: [pane.paneID])[pane.paneID] != nil)
            first.stop()
            let second = try await adapter.makeTerminalChannel(paneID: pane.paneID, mode: .takeover)
            let reopened = NativeCallbackCapture()
            try second.start(columns: 80, rows: 24, onOutput: { reopened.frame($0) }, onClose: { reopened.close($0) })
            defer { second.stop() }
            #expect(reopened.text.contains("adapter-result"))
            try second.resize(columns: 50, rows: 10)
            try second.scroll(direction: .up, lines: 2)
            try second.release()
            let tab = try await adapter.createTab(workspaceID: pane.workspaceID, workingDirectory: directory.path)
            let split = try await adapter.splitPane(paneID: tab.paneID, direction: .right, workingDirectory: directory.path)
            #expect(split.workspaceID == pane.workspaceID)
            try await adapter.renameWorkspace(workspaceID: pane.workspaceID, label: "Renamed")
            #expect(try await adapter.currentSnapshot(hostID: host).panes.count == 3)
            try await adapter.closeWorkspace(workspaceID: pane.workspaceID)
            #expect(try await adapter.currentSnapshot(hostID: host).panes.isEmpty)
            #expect(updates.closes == 0)
        }
    }

    @Test func takeoverNotifiesTheOldChannelAndObserversRemainReadOnly() async throws {
        try await isolated { directory, _, runtime, _ in
            try await runtime.ensureRunning()
            let pane = try await runtime.createWorkspace(label: "Project", workingDirectory: directory.path, environment: [:])
            let old = try await runtime.makeTerminalChannel(paneID: pane.paneID, mode: .control)
            let oldEvents = NativeCallbackCapture()
            try old.start(columns: 80, rows: 24, onOutput: { oldEvents.frame($0) }, onClose: { oldEvents.close($0) })
            defer { old.stop() }
            let observer = try await runtime.makeTerminalChannel(paneID: pane.paneID, mode: .observe)
            try observer.start(columns: 30, rows: 8, onOutput: { _ in }, onClose: { _ in })
            defer { observer.stop() }
            #expect(throws: NativeRuntimeProcessError.rejected("control_required")) { try observer.sendInput(Data("no".utf8)) }
            try observer.scroll(direction: .up, lines: 4)
            let next = try await runtime.makeTerminalChannel(paneID: pane.paneID, mode: .takeover)
            try next.start(columns: 80, rows: 24, onOutput: { _ in }, onClose: { _ in })
            defer { next.stop() }
            try await wait { oldEvents.closes == 1 }
            #expect(oldEvents.lastError == .rejected("control_required"))
            try await runtime.closeWorkspace(workspaceID: pane.workspaceID)
        }
    }

    @Test func ownerExitClosesSubscriptionsAndChannelsWithoutSilentRestart() async throws {
        try await isolated { directory, server, runtime, _ in
            try await runtime.ensureRunning()
            let pane = try await runtime.createWorkspace(label: "Project", workingDirectory: directory.path, environment: [:])
            let events = NativeCallbackCapture(), frames = NativeCallbackCapture()
            let changes = await runtime.changes()
            try await changes.start(onEvent: { events.event() }, onClose: { events.close($0) })
            defer { changes.stop() }
            let channel = try await runtime.makeTerminalChannel(paneID: pane.paneID, mode: .observe)
            try channel.start(columns: 80, rows: 24, onOutput: { frames.frame($0) }, onClose: { frames.close($0) })
            defer { channel.stop() }
            server.stop()
            try await wait { events.closes == 1 && frames.closes == 1 }
            #expect(await runtime.descriptor.incarnationID == server.status.incarnationID)
        }
    }
}

private final class NativeCallbackCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = ""
    private var eventCount = 0
    private var closeCount = 0
    private var error: NativeRuntimeProcessError?
    var text: String { lock.withLock { latest } }
    var events: Int { lock.withLock { eventCount } }
    var closes: Int { lock.withLock { closeCount } }
    var lastError: NativeRuntimeProcessError? { lock.withLock { error } }
    func frame(_ data: Data) { lock.withLock { latest = String(decoding: data, as: UTF8.self) } }
    func event() { lock.withLock { eventCount += 1 } }
    func close(_ error: Error?) { lock.withLock { closeCount += 1; self.error = error as? NativeRuntimeProcessError } }
}
#endif
