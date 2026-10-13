#if os(macOS) || os(Linux)
import Foundation
import Testing
import NorthpaneRuntimeIPC
import NorthpaneProtocol
@testable import NorthpaneNativeRuntime
#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite struct NativeRuntimeProcessTests {
    private func temporary() -> URL {
        URL(fileURLWithPath: "/tmp/np-" + UUID().uuidString.prefix(12), isDirectory: true)
    }

    private func withServer(workspaceModelEnabled: Bool = true, liveProcesses: Bool = false, _ body: (URL, NativeRuntimeServer) async throws -> Void) async throws {
        let directory = temporary()
        let configuration: NativeProcessConfiguration?
        if liveProcesses {
            let home = directory.appending(path: "home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            configuration = NativeProcessConfiguration(shell: "/bin/sh", arguments: ["-i"],
                environment: ["HOME": home.path, "ENV": "/dev/null", "PATH": "/usr/bin:/bin", "PS1": "probe$ "])
        } else { configuration = nil }
        let server = try NativeRuntimeServer(stateDirectory: directory, version: "test", workspaceModelEnabled: workspaceModelEnabled, processConfiguration: configuration)
        // run() owns a blocking accept loop. A detached Swift task still runs
        // on the cooperative pool and starves async clients on small runners.
        let completed = AsyncStream<Result<Void, any Error>>.makeStream()
        Thread.detachNewThread {
            do { try server.run(); completed.continuation.yield(.success(())) }
            catch { completed.continuation.yield(.failure(error)) }
            completed.continuation.finish()
        }
        var completion = completed.stream.makeAsyncIterator()
        do {
            try await body(directory, server)
            server.stop()
            if let result = await completion.next() { try result.get() }
        } catch {
            server.stop(); _ = await completion.next()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        try FileManager.default.removeItem(at: directory)
    }

    @Test func terminalIpcOwnsTheSamePtyAcrossDisconnectedBridgeConnections() async throws {
        try await withServer(liveProcesses: true) { directory, _ in
            let first = try await NativeRuntimeConnection.connect(stateDirectory: directory)
            let second = try await NativeRuntimeConnection.connect(stateDirectory: directory)
            defer { first.close(); second.close() }
            #expect(first.status.terminalFrames)
            let host = HostID(rawValue: UUID())
            let pane = try await first.createWorkspace(hostID: host, label: "Project", workingDirectory: directory.path)
            let a = try first.openTerminal(paneID: pane.paneID, mode: .control, columns: 80, rows: 24)
            let observer = try second.openTerminal(paneID: pane.paneID, mode: .observe, columns: 40, rows: 12)
            #expect(observer.processProof == a.processProof && !observer.controlling)
            #expect(throws: NativeRuntimeProcessError.rejected("control_required")) {
                try second.inputTerminal(attachmentID: observer.attachmentID, bytes: Data("must not arrive".utf8))
            }
            try first.inputTerminal(attachmentID: a.attachmentID, bytes: Data("printf '\\151\\160\\143\\055\\162\\145\\163\\165\\154\\164\\012'\r".utf8))
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var received = false
            repeat {
                let view = try first.pollTerminal(attachmentID: a.attachmentID, afterRevision: -1)
                if String(decoding: view.bytes, as: UTF8.self).contains("ipc-result") { received = true; break }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
            #expect(received)
            first.close()
            let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            var reopened: NativeTerminalView?
            repeat {
                do { reopened = try second.openTerminal(paneID: pane.paneID, mode: .control, columns: 80, rows: 24) }
                catch NativeRuntimeProcessError.rejected("control_owned_elsewhere") { try await Task.sleep(for: .milliseconds(10)) }
            } while reopened == nil && ContinuousClock.now < releaseDeadline
            let b = try #require(reopened)
            #expect(b.processProof == a.processProof && !b.ended)
            #expect(String(decoding: b.bytes, as: UTF8.self).contains("ipc-result"))
            #expect(try second.observedRevision() > 0)
            #expect(try await second.paneInformation(paneID: pane.paneID).lastActivity != nil)
            try await second.closeWorkspace(hostID: host, workspaceID: pane.workspaceID)
        }
    }

    @Test func workspaceGraphIsSharedPersistedAndSurvivesClientDetach() async throws {
        try await withServer { directory, server in
            let host = HostID(rawValue: UUID())
            let first = try await NativeRuntimeConnection.connect(stateDirectory: directory)
            let second = try await NativeRuntimeConnection.connect(stateDirectory: directory)
            defer { first.close(); second.close() }
            #expect(first.status.workspaceModel)
            let created = try await first.createWorkspace(hostID: host, label: "Project", workingDirectory: "/tmp")
            #expect(created.workspaceID == "w1" && created.paneID == "w1:p1")
            _ = try await second.createTab(hostID: host, workspaceID: created.workspaceID, workingDirectory: "/tmp")
            _ = try await first.splitPane(hostID: host, paneID: "w1:p2", direction: .down, workingDirectory: "/tmp")
            try await second.renameWorkspace(hostID: host, workspaceID: "w1", label: "Renamed")
            let expected = try await first.currentSnapshot(hostID: host)
            #expect(expected.workspaces.first?.label == "Renamed")
            #expect(expected.tabs.count == 2 && expected.panes.count == 3)
            #expect(expected.capabilities.isEmpty)
            first.close()
            #expect(try await second.currentSnapshot(hostID: host) == expected)
            let saved = try NativeWorkspaceStore(fileURL: directory.appending(path: "runtime/layout-v1.json"), incarnationID: server.status.incarnationID)
            #expect(saved.snapshot(hostID: host).panes.map(\.id) == expected.panes.map(\.id))
            let reconnected = try await NativeRuntimeConnection.connect(stateDirectory: directory)
            defer { reconnected.close() }
            #expect(try await reconnected.currentSnapshot(hostID: host) == expected)
            try await reconnected.closeWorkspace(hostID: host, workspaceID: "w1")
            #expect(try await second.currentSnapshot(hostID: host).panes.isEmpty)
        }
    }

    @Test func rejectedWorkspaceEditsKeepTheGraphAndConnectionUsable() async throws {
        try await withServer { directory, _ in
            let client = try await NativeRuntimeConnection.connect(stateDirectory: directory)
            defer { client.close() }
            let host = HostID(rawValue: UUID())
            _ = try await client.createWorkspace(hostID: host, label: "Project", workingDirectory: "/tmp")
            let before = try await client.currentSnapshot(hostID: host)
            await #expect(throws: NativeRuntimeProcessError.rejected("unknown_workspace")) {
                try await client.createTab(hostID: host, workspaceID: "w99", workingDirectory: "/tmp")
            }
            await #expect(throws: NativeRuntimeProcessError.rejected("invalid_working_directory")) {
                try await client.createWorkspace(hostID: host, label: "Invalid", workingDirectory: "relative")
            }
            #expect(try await client.currentSnapshot(hostID: host) == before)
            #expect(try await client.ping() == client.status)
        }
    }

    @Test func olderHealthyOwnerIsReusedWithoutWorkspaceCommandsOrRestart() async throws {
        try await withServer(workspaceModelEnabled: false) { directory, server in
            let connection = try await NativeRuntimeLauncher.ensureRunning(stateDirectory: directory,
                executableURL: URL(fileURLWithPath: "/not-an-executable"))
            defer { connection.close() }
            #expect(connection.status == server.status && !connection.status.workspaceModel)
            await #expect(throws: NativeRuntimeProcessError.rejected("workspace_model_unavailable")) {
                try await connection.currentSnapshot(hostID: HostID(rawValue: UUID()))
            }
            #expect(try await connection.ping() == server.status)
        }
    }

    @Test func simultaneousClientsCannotLoseWorkspaceMutations() async throws {
        try await withServer { directory, _ in
            let host = HostID(rawValue: UUID())
            var connections: [NativeRuntimeConnection] = []
            for _ in 0..<8 { connections.append(try await NativeRuntimeConnection.connect(stateDirectory: directory)) }
            defer { connections.forEach { $0.close() } }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, client) in connections.enumerated() {
                    group.addTask { _ = try await client.createWorkspace(hostID: host, label: "Project \(index)", workingDirectory: "/tmp") }
                }
                try await group.waitForAll()
            }
            let snapshot = try await connections[0].currentSnapshot(hostID: host)
            #expect(snapshot.workspaces.count == 8 && Set(snapshot.workspaces.map(\.id)).count == 8)
        }
    }

    @Test func connectionsShareOneIncarnationAndDetachIndependently() async throws {
        try await withServer { directory, server in
            let first = try await NativeRuntimeConnection.connect(stateDirectory: directory)
            let second = try await NativeRuntimeConnection.connect(stateDirectory: directory)
            defer { first.close(); second.close() }
            #expect(first.status == second.status)
            #expect(first.status == server.status)
            first.close()
            #expect(try await second.ping() == server.status)
            let reconnected = try await NativeRuntimeConnection.connect(stateDirectory: directory)
            defer { reconnected.close() }
            #expect(reconnected.status == server.status)
        }
    }

    @Test func processDirectorySocketAndLockArePrivateAndSingleton() async throws {
        try await withServer { directory, _ in
            for (path, mode) in [("runtime", 0o700), ("runtime/runtime.sock", 0o600), ("runtime/runtime.lock", 0o600)] {
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: path).path)
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == mode)
                #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid())
            }
            #expect(throws: NativeRuntimeProcessError.systemCall(EWOULDBLOCK)) {
                _ = try NativeRuntimeServer(stateDirectory: directory, version: "newer")
            }
            #expect(np_runtime_same_user(geteuid()) != 0)
            #expect(np_runtime_same_user(geteuid() == 0 ? 1 : 0) == 0)
        }
    }

    @Test func aLinkedRuntimeDirectoryIsRefusedWithoutChangingItsTarget() throws {
        let directory = temporary(), target = temporary()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "runtime"), withDestinationURL: target)
        #expect(throws: NativeRuntimeProcessError.self) {
            _ = try NativeRuntimeServer(stateDirectory: directory, version: "test")
        }
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test func lockAndSocketLinksOrRegularFilesAreNeverReplaced() throws {
        for name in ["runtime.lock", "runtime.sock"] {
            let directory = temporary(), target = temporary()
            defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: target) }
            try FileManager.default.createDirectory(at: directory.appending(path: "runtime"), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: target)
            let protected = directory.appending(path: "runtime/" + name)
            try FileManager.default.createSymbolicLink(at: protected, withDestinationURL: target)
            #expect(throws: NativeRuntimeProcessError.self) {
                _ = try NativeRuntimeServer(stateDirectory: directory, version: "test")
            }
            #expect(try Data(contentsOf: target) == Data("keep".utf8))
        }
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appending(path: "runtime"), withIntermediateDirectories: true)
        let file = directory.appending(path: "runtime/runtime.sock")
        try Data("keep".utf8).write(to: file)
        #expect(throws: NativeRuntimeProcessError.systemCall(EPERM)) {
            _ = try NativeRuntimeServer(stateDirectory: directory, version: "test")
        }
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
    }

    @Test func unknownProtocolRevisionsCannotJoinOrRestartAnOwner() async throws {
        try await withServer { directory, server in
            for revision: UInt32 in [0, 2, UInt32.max] {
                await #expect(throws: NativeRuntimeProcessError.incompatibleRevision) {
                    try await NativeRuntimeConnection.connect(stateDirectory: directory, revision: revision)
                }
            }
            let healthy = try await NativeRuntimeConnection.connect(stateDirectory: directory)
            defer { healthy.close() }
            #expect(try await healthy.ping() == server.status)
        }
    }

    @Test func malformedAndOversizedFramesOnlyCloseTheirOwnConnection() async throws {
        try await withServer { directory, server in
            for bytes: [UInt8] in [[0, 0, 0, 0], [255, 255, 255, 255], [0, 0, 0, 1, 255]] {
                let fd = np_runtime_connect(directory.appending(path: "runtime/runtime.sock").path)
                #expect(fd >= 0)
                defer { np_runtime_close(fd) }
                #expect(bytes.withUnsafeBytes { np_runtime_write(fd, $0.baseAddress, $0.count, 1000) } == 0)
                var response: UInt8 = 0
                #expect(np_runtime_read(fd, &response, 1, 1000) == ECONNRESET)
            }
            let healthy = try await NativeRuntimeConnection.connect(stateDirectory: directory)
            defer { healthy.close() }
            #expect(try await healthy.ping() == server.status)
        }
    }

    @Test func stoppingDoesNotWaitForIdleClients() async throws {
        try await withServer { directory, server in
            let client = try await NativeRuntimeConnection.connect(stateDirectory: directory)
            defer { client.close() }
            let began = ContinuousClock.now
            server.stop()
            await #expect(throws: (any Error).self) { try await client.ping() }
            #expect(began.duration(to: .now) < .seconds(1))
        }
    }

    private func executable() throws -> URL {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = package.appending(path: ".build/debug/northpane-bridge")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw NativeRuntimeProcessError.invalidConfiguration }
        return url
    }

    private func runCLI(_ executable: URL, directory: URL, argument: String) async throws -> NativeRuntimeStatus {
        try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = executable; process.arguments = ["runtime", argument]
            process.environment = ["NORTHPANE_STATE_DIRECTORY": directory.path, "PATH": "/usr/bin:/bin",
                "HOME": directory.appending(path: "home").path, "SHELL": "/bin/sh", "ENV": "/dev/null", "PS1": "probe$ "]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NativeRuntimeProcessError.startupTimedOut }
            return try JSONDecoder().decode(NativeRuntimeStatus.self, from: data)
        }.value
    }

    @Test func detachedOwnerSurvivesBridgeExitIsReusedAndRecoversAfterBeingKilled() async throws {
        let directory = temporary(), binary = try executable()
        var owner: Int32 = 0
        defer { if owner > 0 { _ = kill(owner, SIGTERM) }; try? FileManager.default.removeItem(at: directory) }
        // Each CLI is a separate Bridge process which exits after its handshake.
        let first = try await runCLI(binary, directory: directory, argument: "--ensure")
        owner = first.processID
        #expect(first.processID != getpid())
        #expect(try await runCLI(binary, directory: directory, argument: "--status") == first)
        #expect(try await runCLI(binary, directory: directory, argument: "--ensure") == first)
        // A different/new executable must not be launched while an owner is healthy.
        let reused = try await NativeRuntimeLauncher.ensureRunning(stateDirectory: directory,
            executableURL: URL(fileURLWithPath: "/missing/new-version"))
        #expect(reused.status == first)
        let host = HostID(rawValue: UUID())
        let created = try await reused.createWorkspace(hostID: host, label: "Persistent", workingDirectory: "/tmp")
        reused.close()
        #expect(kill(owner, SIGKILL) == 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            let fd = np_runtime_connect(directory.appending(path: "runtime/runtime.sock").path)
            if fd == -ECONNREFUSED { break }
            if fd >= 0 { np_runtime_close(fd) }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        let replacement = try await runCLI(binary, directory: directory, argument: "--ensure")
        owner = replacement.processID
        #expect(replacement.incarnationID != first.incarnationID)
        #expect(replacement.processID != first.processID)
        #expect(try await runCLI(binary, directory: directory, argument: "--status") == replacement)
        let recovered = try await NativeRuntimeConnection.connect(stateDirectory: directory)
        defer { recovered.close() }
        let snapshot = try await recovered.currentSnapshot(hostID: host)
        #expect(snapshot.incarnationID == replacement.incarnationID)
        #expect(snapshot.workspaces.map(\.id) == [created.workspaceID])
        #expect(snapshot.panes.map(\.id) == [created.paneID])
        #expect(try await recovered.createWorkspace(hostID: host, label: "Next", workingDirectory: "/tmp").workspaceID == "w2")
    }

    @Test func detachedExecFailureIsReportedInsteadOfLeavingAFalseOwner() async throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: NativeRuntimeProcessError.systemCall(ENOENT)) {
            try await NativeRuntimeLauncher.ensureRunning(stateDirectory: directory,
                executableURL: URL(fileURLWithPath: "/missing/runtime"), environment: [:])
        }
    }

    @Test func simultaneousBridgeStartsConvergeOnOneOwner() async throws {
        let directory = temporary(), binary = try executable()
        var owner: Int32 = 0
        defer { if owner > 0 { _ = kill(owner, SIGTERM) }; try? FileManager.default.removeItem(at: directory) }
        async let a = runCLI(binary, directory: directory, argument: "--ensure")
        async let b = runCLI(binary, directory: directory, argument: "--ensure")
        let first = try await a
        owner = first.processID
        let second = try await b
        #expect(first == second)
        #expect(try await runCLI(binary, directory: directory, argument: "--status") == first)
    }

    @Test func serviceSetupNeverCompetesWithAnAlreadyHealthyOwner() async throws {
        try await withServer { directory, server in
            let managed = try await NativeRuntimeUserService.ensureRunning(stateDirectory: directory,
                executableURL: URL(fileURLWithPath: "/missing/new-version"))
            defer { managed.connection.close() }
            #expect(managed.connection.status == server.status)
            #expect(!managed.persistence.managedByUserService)
            #expect(managed.persistence.survivesUserLogout == nil)
            #expect(try await managed.connection.ping() == server.status)
        }
    }
}
#endif
