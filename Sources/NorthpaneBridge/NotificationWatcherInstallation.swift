import Foundation
import NorthpaneBridgeResources

/// Runs only after an Operator explicitly enables notifications for a paired device. The app
/// itself does not need to stay open: launchd keeps one observation process alive for the Host.
enum NotificationWatcherInstallation {
    #if os(macOS)
    private static let label = "it.ambiens.northpane.notification-watcher"

    static func install(stateDirectory: URL) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plist = directory.appending(path: "\(label).plist")
        let executable = try executablePath()
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "Label": label,
            "ProgramArguments": [executable, "watch"],
            "EnvironmentVariables": ["NORTHPANE_STATE_DIRECTORY": stateDirectory.path],
            "RunAtLoad": true,
            "KeepAlive": true,
        ] as [String: Any], format: .xml, options: 0)
        let changed = (try? Data(contentsOf: plist)) != data
        if changed { try data.write(to: plist, options: .atomic) }
        let target = "gui/\(getuid())"
        if try command("/bin/launchctl", ["print", "\(target)/\(label)"]) == 0 {
            guard changed else { return }
            _ = try command("/bin/launchctl", ["bootout", "\(target)/\(label)"])
        }
        guard try command("/bin/launchctl", ["bootstrap", target, plist.path]) == 0 else {
            throw NotificationError.routeUnavailable
        }
    }

    static func uninstallIfUnused(stateDirectory: URL, routesRemain: Bool) throws {
        guard !routesRemain else { return }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return }
        _ = try command("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try FileManager.default.removeItem(at: plist)
    }

    #elseif os(Linux)
    private static let unit = "northpane-notification-watcher.service"

    static func install(stateDirectory: URL) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/systemd/user", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = directory.appending(path: unit)
        let executable = try executablePath()
        guard !executable.contains("\n"), !stateDirectory.path.contains("\n") else { throw NotificationError.routeUnavailable }
        let body = """
        [Unit]
        Description=Northpane Attention watcher
        After=default.target

        [Service]
        Type=simple
        ExecStart=\(executable.replacingOccurrences(of: " ", with: "\\x20")) watch
        Environment="NORTHPANE_STATE_DIRECTORY=\(stateDirectory.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
        Restart=always
        RestartSec=5

        [Install]
        WantedBy=default.target
        """
        let changed = (try? String(contentsOf: service, encoding: .utf8)) != body
        if changed { try Data(body.utf8).write(to: service, options: .atomic) }
        if changed { guard try command("/usr/bin/systemctl", ["--user", "daemon-reload"]) == 0 else { throw NotificationError.routeUnavailable } }
        guard try command("/usr/bin/systemctl", ["--user", "enable", "--now", unit]) == 0 else {
            throw NotificationError.routeUnavailable
        }
        if changed { guard try command("/usr/bin/systemctl", ["--user", "restart", unit]) == 0 else { throw NotificationError.routeUnavailable } }
    }

    static func uninstallIfUnused(stateDirectory: URL, routesRemain: Bool) throws {
        guard !routesRemain else { return }
        let service = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/systemd/user/\(unit)")
        guard FileManager.default.fileExists(atPath: service.path) else { return }
        _ = try command("/usr/bin/systemctl", ["--user", "disable", "--now", unit])
        try FileManager.default.removeItem(at: service)
        _ = try command("/usr/bin/systemctl", ["--user", "daemon-reload"])
    }
    #else
    static func install(stateDirectory: URL) throws { throw NotificationError.routeUnavailable }
    static func uninstallIfUnused(stateDirectory: URL, routesRemain: Bool) throws {}
    #endif

    #if os(macOS) || os(Linux)
    private static func executablePath() throws -> String {
        guard let executable = Bundle.main.executableURL else { throw NotificationError.routeUnavailable }
        // The local Mac app carries the Bridge being registered right now. A separate remote
        // installation uses the versioned `current` symlink so its watcher follows updates.
        if executable.path.contains(".app/Contents/MacOS/") { return executable.path }
        let current = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/northpane/bridge/current/northpane-bridge")
        if FileManager.default.isExecutableFile(atPath: current.path) { return current.path }
        return executable.path
    }

    private static func command(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    #endif
}
