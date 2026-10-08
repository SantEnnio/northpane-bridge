#if os(macOS) || os(Linux)
import Foundation
#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct NativeRuntimePersistence: Equatable, Sendable {
    public let managedByUserService: Bool
    /// nil means the Host has not established survival across a full user logout.
    public let survivesUserLogout: Bool?
}

public struct ManagedNativeRuntime: Sendable {
    public let connection: NativeRuntimeConnection
    public let persistence: NativeRuntimePersistence
}

/// Used only by the forthcoming native adapter. Existing Herdr connections and the
/// explicit certification launcher do not register a service in the user's profile.
public enum NativeRuntimeUserService {
    public static func ensureRunning(stateDirectory: URL, executableURL: URL) async throws -> ManagedNativeRuntime {
        let definition = try RuntimeServiceDefinition(stateDirectory: stateDirectory, executableURL: executableURL,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        // Never restart or register a competing owner just because a Bridge was updated.
        do {
            let existing = try await NativeRuntimeConnection.connect(stateDirectory: stateDirectory)
            let persistence = await Task.detached { inspectOwner(existing.status.processID) }.value
            return ManagedNativeRuntime(connection: existing, persistence: persistence)
        } catch NativeRuntimeProcessError.systemCall(let error) where error == ENOENT || error == ECONNREFUSED {}

        let started = await Task.detached { registerAndStart(definition) }.value
        if started {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            repeat {
                do {
                    let connection = try await NativeRuntimeConnection.connect(stateDirectory: stateDirectory)
                    let persistence = await Task.detached { inspectOwner(connection.status.processID) }.value
                    return ManagedNativeRuntime(connection: connection, persistence: persistence)
                } catch NativeRuntimeProcessError.systemCall(let error) where error == ENOENT || error == ECONNREFUSED {}
                try await Task.sleep(for: .milliseconds(25))
            } while ContinuousClock.now < deadline
        }
        // A host without a working service manager can still survive SSH disconnection.
        // Its full-user-logout continuity remains explicitly unconfirmed.
        let connection = try await NativeRuntimeLauncher.ensureRunning(stateDirectory: stateDirectory, executableURL: executableURL)
        return ManagedNativeRuntime(connection: connection,
            persistence: NativeRuntimePersistence(managedByUserService: false, survivesUserLogout: nil))
    }

    private static func registerAndStart(_ definition: RuntimeServiceDefinition) -> Bool {
        do {
            #if os(macOS)
            let domain = launchDomain()
            // Do not replace or boot out a loaded runtime even if it is still starting.
            if command("/bin/launchctl", ["print", "\(domain)/\(RuntimeServiceDefinition.label)"]).code == 0 { return true }
            try definition.writeMacRegistration()
            return command("/bin/launchctl", ["bootstrap", domain, definition.macRegistration.path]).code == 0
            #elseif os(Linux)
            let changed = try definition.writeLinuxRegistration()
            if changed, command("/usr/bin/systemctl", ["--user", "daemon-reload"]).code != 0 { return false }
            // Never restart: a reload changes future starts, not live PTYs.
            let started = command("/usr/bin/systemctl", ["--user", "enable", "--now", RuntimeServiceDefinition.unit]).code == 0
            if started { _ = command("/usr/bin/loginctl", ["enable-linger", String(geteuid())]) }
            return started
            #endif
        } catch { return false }
    }

    private static func inspectOwner(_ pid: Int32) -> NativeRuntimePersistence {
        #if os(macOS)
        let result = command("/bin/launchctl", ["print", "\(launchDomain())/\(RuntimeServiceDefinition.label)"])
        let managed = result.code == 0 && result.output.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "pid = \(pid)" }
        return NativeRuntimePersistence(managedByUserService: managed, survivesUserLogout: nil)
        #elseif os(Linux)
        let result = command("/usr/bin/systemctl", ["--user", "show", RuntimeServiceDefinition.unit, "--property=MainPID", "--value"])
        let managed = result.code == 0 && Int32(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) == pid
        let linger = command("/usr/bin/loginctl", ["show-user", String(geteuid()), "--property=Linger", "--value"])
        let survives = managed && linger.code == 0 ? linger.output.trimmingCharacters(in: .whitespacesAndNewlines) == "yes" : nil
        return NativeRuntimePersistence(managedByUserService: managed, survivesUserLogout: survives)
        #endif
    }

    #if os(macOS)
    private static func launchDomain() -> String {
        let gui = "gui/\(geteuid())"
        return command("/bin/launchctl", ["print", gui]).code == 0 ? gui : "user/\(geteuid())"
    }
    #endif

    private static func command(_ executable: String, _ arguments: [String]) -> (code: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        // Known service-manager commands write small status replies; poll output while waiting
        // so a full pipe cannot defeat the deadline. Never invoke a shell.
        let capture = ServiceCommandCapture()
        output.fileHandleForReading.readabilityHandler = { handle in capture.append(handle.availableData) }
        defer { output.fileHandleForReading.readabilityHandler = nil; try? output.fileHandleForReading.close() }
        do { try process.run() } catch { return (-1, "") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while process.isRunning, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            let grace = ContinuousClock.now.advanced(by: .milliseconds(250))
            while process.isRunning, ContinuousClock.now < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        // Remove the callback before consuming any final bytes. Its capture is locked.
        output.fileHandleForReading.readabilityHandler = nil
        capture.append(output.fileHandleForReading.readDataToEndOfFile())
        return (process.terminationStatus, capture.text())
    }
}

private final class ServiceCommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) { lock.withLock { data.append(bytes.prefix(max(0, 65_536 - data.count))) } }
    func text() -> String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

struct RuntimeServiceDefinition {
    static let label = "it.ambiens.northpane.runtime"
    static let unit = "northpane-runtime.service"
    let stateDirectory: URL
    let executableURL: URL
    let homeDirectory: URL
    init(stateDirectory: URL, executableURL: URL, homeDirectory: URL) throws {
        for url in [stateDirectory, executableURL, homeDirectory] {
            guard url.isFileURL, url.path.hasPrefix("/"), !url.path.unicodeScalars.contains(where: { $0.value < 32 }) else {
                throw NativeRuntimeProcessError.invalidConfiguration
            }
        }
        self.stateDirectory = stateDirectory; self.homeDirectory = homeDirectory
        let installedRoot = homeDirectory.appending(path: ".local/share/northpane/bridge", directoryHint: .isDirectory)
        let current = installedRoot.appending(path: "current/northpane-bridge")
        // A package update moves current; keep the next service start on that pointer,
        // while preserving embedded app and explicit certification executables.
        if executableURL.path.hasPrefix(installedRoot.path + "/"),
           FileManager.default.isExecutableFile(atPath: current.path) {
            self.executableURL = current
        } else { self.executableURL = executableURL }
    }
    var macRegistration: URL { homeDirectory.appending(path: "Library/LaunchAgents/\(Self.label).plist") }
    var linuxRegistration: URL { homeDirectory.appending(path: ".config/systemd/user/\(Self.unit)") }

    func macPropertyList() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "Label": Self.label,
            "ProgramArguments": [executableURL.path, "runtime"],
            "EnvironmentVariables": ["NORTHPANE_STATE_DIRECTORY": stateDirectory.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ] as [String: Any], format: .xml, options: 0)
    }
    func linuxUnit() -> String {
        // ':' disables environment expansion in ExecStart; '%' still needs escaping.
        // Environment values have no dollar expansion, and both directives are quoted.
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "%", with: "%%") + "\""
        }
        return """
        [Unit]
        Description=Northpane user runtime
        After=default.target

        [Service]
        Type=simple
        ExecStart=:\(quoted(executableURL.path)) runtime
        Environment=\(quoted("NORTHPANE_STATE_DIRECTORY=" + stateDirectory.path))
        Restart=on-failure
        RestartSec=5
        StandardOutput=null
        StandardError=null

        [Install]
        WantedBy=default.target

        """
    }

    func writeMacRegistration() throws { _ = try write(macPropertyList(), to: macRegistration) }
    func writeLinuxRegistration() throws -> Bool { try write(Data(linuxUnit().utf8), to: linuxRegistration) }
    private func write(_ data: Data, to path: URL) throws -> Bool {
        if (try? Data(contentsOf: path)) == data { return false }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
        return true
    }
}
#endif
