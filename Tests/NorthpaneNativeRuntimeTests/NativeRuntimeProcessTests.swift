#if os(macOS) || os(Linux)
import Foundation
import Testing
import NorthpaneRuntimeIPC
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

    private func withServer(_ body: (URL, NativeRuntimeServer) async throws -> Void) async throws {
        let directory = temporary()
        let server = try NativeRuntimeServer(stateDirectory: directory, version: "test")
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
            process.environment = ["NORTHPANE_STATE_DIRECTORY": directory.path, "PATH": "/usr/bin:/bin"]
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
        #expect(reused.status == first); reused.close()
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
