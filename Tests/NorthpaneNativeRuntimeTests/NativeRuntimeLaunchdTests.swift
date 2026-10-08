#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import NorthpaneNativeRuntime

@Suite struct NativeRuntimeLaunchdTests {
    private func command(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }
    private func waitForOwner(_ directory: URL, excluding incarnation: String? = nil) async throws -> NativeRuntimeStatus {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        repeat {
            do {
                let connection = try await NativeRuntimeConnection.connect(stateDirectory: directory)
                defer { connection.close() }
                if connection.status.incarnationID != incarnation { return connection.status }
            } catch NativeRuntimeProcessError.systemCall(let error) where error == ENOENT || error == ECONNREFUSED || error == ECONNRESET {}
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        throw NativeRuntimeProcessError.startupTimedOut
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NORTHPANE_RUNTIME_SERVICE_CERT"] == "1"))
    func isolatedLaunchAgentStartsAndRestartsItsOwner() async throws {
        let root = URL(fileURLWithPath: "/tmp/np-launch-" + UUID().uuidString.prefix(10))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let definition = try RuntimeServiceDefinition(stateDirectory: root,
            executableURL: package.appending(path: ".build/debug/northpane-bridge"), homeDirectory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let label = RuntimeServiceDefinition.label + ".cert." + UUID().uuidString.prefix(10)
        var plist = try #require(PropertyListSerialization.propertyList(from: definition.macPropertyList(), format: nil) as? [String: Any])
        plist["Label"] = label
        let file = root.appending(path: "cert.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file)
        let domain = "gui/\(geteuid())", target = domain + "/" + label
        defer {
            _ = try? command(["bootout", target])
            try? FileManager.default.removeItem(at: root)
        }
        #expect(try command(["bootstrap", domain, file.path]) == 0)
        let first = try await waitForOwner(root)
        #expect(first.processID != getpid())
        #expect(kill(first.processID, SIGKILL) == 0)
        let replacement = try await waitForOwner(root, excluding: first.incarnationID)
        #expect(replacement.processID != first.processID)
        #expect(replacement.incarnationID != first.incarnationID)
        #expect(try command(["print", target]) == 0)
        print("Isolated launchd runtime: owner started and restarted, certification service removed on exit")
    }
}
#endif
