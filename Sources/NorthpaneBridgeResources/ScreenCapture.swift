#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import SystemConfiguration
import UniformTypeIdentifiers

public enum ScreenCaptureError: Error, Equatable, Sendable {
    /// macOS has not granted Screen Recording to the Bridge (or to the app that launched it).
    case notPermitted
    /// The target id did not come from a listing, or names something that no longer exists.
    case unknownTarget
    /// `screencapture` ran and produced nothing usable; the text is its own diagnosis.
    case captureFailed(String)
    /// Nobody is logged in at the Host's screen, so there is no session to capture in.
    case noGUISession
    /// The helper app could not be installed or run; the text says what failed.
    case helperFailed(String)
}

/// Lists what the Host's screen is showing and captures one item of it into the Host user's
/// temporary folder, so an operator can show an agent what an app looks like without leaving
/// Northpane.
///
/// The listing reads names and geometry only: no pixel leaves the Host until a capture is
/// asked for, and a capture is one image of one display or one window, written where
/// `WorkspaceFileReader` already serves files from. macOS gates every capture behind the
/// Screen Recording permission of the process that asks; the Bridge asks for it once and
/// otherwise reports that it is missing, it never works around it.
public enum ScreenCapture {
    public struct Target: Equatable, Sendable, Codable {
        public enum Kind: String, Equatable, Sendable, Codable { case display, window }
        /// Opaque, valid until the next listing: `display:<id>` or `window:<id>`.
        public let id: String
        public let kind: Kind
        /// The owning app of a window; empty for a display.
        public let application: String
        /// The window title when macOS lets the Bridge read it, otherwise empty. Displays have
        /// no title: the client names them.
        public let title: String
        public let width: Int
        public let height: Int
        /// The main display, or the window nearest the front.
        public let isFrontmost: Bool
    }

    public struct Capture: Equatable, Sendable, Codable {
        /// Absolute path of the PNG on the Host: what the operator hands to an agent.
        public let path: String
        public let byteCount: Int
        /// A downscaled JPEG small enough for one protocol frame; the operator's look at it.
        public let preview: Data
        public let previewMediaType: String
    }

    /// The preview must fit in one frame with room for the envelope around it.
    public static let maximumPreviewBytes = 700 * 1_024
    public static let previewMaximumPixelSize = 1_600
    /// Captures older than the newest few are deleted on the next capture, so a session of
    /// screenshots does not fill the temporary folder.
    public static let keptCaptures = 20
    /// Windows smaller than this are tooltips, status items and helper panels.
    static let minimumWindowSide = 64.0

    public static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for Screen Recording once, and afterwards only puts the switch on screen.
    ///
    /// The alert macOS raises belongs to the system, not to the process that asked: it stays on
    /// the Host's screen until somebody answers it, long after the helper has exited. Asking again
    /// for every refused capture therefore helps nobody — it stacks a second alert on a screen
    /// that may have nobody in front of it, and buries the first. (Measured on the test Host on
    /// 2026-09-09: fifteen alerts in forty minutes, one still unanswered the next morning, and the
    /// operator seeing a permission request for every screenshot they asked for.)
    ///
    /// So: the first refusal raises the alert and nothing else, because System Settings opened on
    /// top of it would take the focus the alert needs. A later refusal means the alert has been
    /// answered or dismissed and will not come back on its own, so the pane holding the switch is
    /// opened instead — once. Both facts are remembered beside the captures, and forgotten again
    /// as soon as the permission is there, so a revoked permission is asked for afresh.
    ///
    /// Nothing on the Host is changed either way: an alert is raised and a settings pane opened,
    /// and only ever right after a capture was asked for and refused.
    @discardableResult public static func requestPermission(
        directory: URL = defaultDirectory(),
        open: URL = URL(fileURLWithPath: "/usr/bin/open"),
        settings: String = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        // Named so a test can watch the bookkeeping without putting an alert on someone's screen.
        ask: () -> Bool = { CGRequestScreenCaptureAccess() }
    ) -> Bool {
        if isPermitted { forgetPermissionRequest(directory: directory); return true }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: alertRaisedMarker(directory: directory).path) {
            try? Data().write(to: alertRaisedMarker(directory: directory))
            return ask()
        }
        guard !manager.fileExists(atPath: paneOpenedMarker(directory: directory).path) else { return false }
        try? Data().write(to: paneOpenedMarker(directory: directory))
        let process = Process()
        process.executableURL = open
        process.arguments = ["-g", settings]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        return false
    }

    static func alertRaisedMarker(directory: URL) -> URL { directory.appending(path: ".permission-alert-raised") }
    static func paneOpenedMarker(directory: URL) -> URL { directory.appending(path: ".permission-pane-opened") }

    /// Forgets that macOS was asked, so a permission taken away later is asked for again.
    static func forgetPermissionRequest(directory: URL) {
        try? FileManager.default.removeItem(at: alertRaisedMarker(directory: directory))
        try? FileManager.default.removeItem(at: paneOpenedMarker(directory: directory))
    }

    public static func defaultDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "northpane-captures", directoryHint: .isDirectory)
    }

    /// Displays first (main first), then the on-screen windows front to back. The Bridge's own
    /// windows, if it ever had any, and the tiny helper windows are left out.
    public static func targets(excludingProcessID excluded: pid_t = ProcessInfo.processInfo.processIdentifier) -> [Target] {
        var targets: [Target] = []
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        if CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount) == .success {
            for display in displayIDs.prefix(Int(displayCount)) {
                let bounds = CGDisplayBounds(display)
                targets.append(Target(id: "display:\(display)", kind: .display, application: "", title: "",
                                      width: Int(bounds.width), height: Int(bounds.height), isFrontmost: CGDisplayIsMain(display) != 0))
            }
            // Main first, then left to right as they sit on the desk.
            targets.sort { ($0.isFrontmost ? 0 : 1, $0.id) < ($1.isFrontmost ? 0 : 1, $1.id) }
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        var sawWindow = false
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let number = window[kCGWindowNumber as String] as? Int,
                  let owner = window[kCGWindowOwnerName as String] as? String, !owner.isEmpty,
                  (window[kCGWindowOwnerPID as String] as? pid_t) != excluded,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsValue = window[kCGWindowBounds as String] as? [String: Any],
                  let width = boundsValue["Width"] as? Double, let height = boundsValue["Height"] as? Double,
                  width >= minimumWindowSide, height >= minimumWindowSide
            else { continue }
            let title = window[kCGWindowName as String] as? String ?? ""
            targets.append(Target(id: "window:\(number)", kind: .window, application: owner, title: title,
                                  width: Int(width), height: Int(height), isFrontmost: !sawWindow))
            sawWindow = true
        }
        return targets
    }

    /// Captures `targetID` to a PNG under `directory` and returns its path with a preview.
    /// `screencapture` is Apple's own tool and is the one path that respects every capture rule
    /// macOS applies (secure input fields, protected content, the permission itself).
    public static func capture(targetID: String, directory: URL = defaultDirectory(),
                               screencapture: URL = URL(fileURLWithPath: "/usr/sbin/screencapture"),
                               now: Date = Date()) throws -> Capture {
        guard let target = parse(targetID: targetID) else { throw ScreenCaptureError.unknownTarget }
        guard isPermitted else {
            requestPermission(directory: directory)
            throw ScreenCaptureError.notPermitted
        }
        forgetPermissionRequest(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        prune(directory: directory, keeping: keptCaptures - 1)

        let arguments: [String]
        let label: String
        switch target {
        case let .display(id):
            // Displays are captured by their global bounds: `-D` numbers displays by an order the
            // listing has no way to reproduce, while bounds name exactly one of them.
            let bounds = CGDisplayBounds(id)
            guard !bounds.isEmpty else { throw ScreenCaptureError.unknownTarget }
            arguments = ["-x", "-t", "png", "-R", "\(Int(bounds.origin.x)),\(Int(bounds.origin.y)),\(Int(bounds.width)),\(Int(bounds.height))"]
            label = "display"
        case let .window(id):
            let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
            guard let window = info.first else { throw ScreenCaptureError.unknownTarget }
            arguments = ["-x", "-t", "png", "-o", "-l", "\(id)"]
            label = (window[kCGWindowOwnerName as String] as? String) ?? "window"
        }

        let stamp = { () -> String in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            return formatter.string(from: now)
        }()
        let file = directory.appending(path: "Capture-\(stamp)-\(sanitized(label)).png")

        let process = Process()
        process.executableURL = screencapture
        process.arguments = arguments + [file.path]
        process.standardInput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do { try process.run() } catch { throw ScreenCaptureError.captureFailed(error.localizedDescription) }
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 0
        else {
            try? FileManager.default.removeItem(at: file)
            // Without the permission `screencapture` still exits 0 for a window and writes
            // nothing, or complains that it "could not create image": both mean the same thing.
            if !isPermitted || detail.localizedCaseInsensitiveContains("could not create image") { throw ScreenCaptureError.notPermitted }
            throw ScreenCaptureError.captureFailed(detail.isEmpty ? "screencapture exited \(process.terminationStatus)" : detail)
        }
        let preview = try preview(of: file)
        return Capture(path: file.path, byteCount: size, preview: preview, previewMediaType: "image/jpeg")
    }

    enum ParsedTarget: Equatable { case display(CGDirectDisplayID), window(CGWindowID) }

    static func parse(targetID: String) -> ParsedTarget? {
        let parts = targetID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let number = UInt32(parts[1]) else { return nil }
        switch parts[0] {
        case "display": return .display(number)
        case "window": return .window(number)
        default: return nil
        }
    }

    /// A JPEG of the capture no larger than `maximumPreviewBytes`, shrinking quality first and
    /// then size until it fits. A Retina display is several megabytes as PNG; the preview is
    /// what the operator looks at, and the PNG stays on the Host for the agent.
    static func preview(of file: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { throw ScreenCaptureError.captureFailed("unreadable capture") }
        var quality = 0.72
        var maximumPixelSize = previewMaximumPixelSize
        for _ in 0..<8 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { break }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { break }
            if data.count <= maximumPreviewBytes { return data as Data }
            if quality > 0.45 { quality -= 0.15 } else { quality = 0.6; maximumPixelSize = maximumPixelSize * 2 / 3 }
        }
        throw ScreenCaptureError.captureFailed("preview too large")
    }

    /// Deletes the oldest captures beyond `keeping`, by name: the stamp sorts chronologically.
    /// Answers left behind go too: the Bridge deletes the one it read, but an answer written after
    /// the Bridge stopped waiting has nobody to delete it and would sit here for good.
    static func prune(directory: URL, keeping: Int, now: Date = Date()) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("answer-") && name.hasSuffix(".json") {
            let file = directory.appending(path: name)
            let modified = (try? manager.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? nil
            guard let modified, now.timeIntervalSince(modified) > 3_600 else { continue }
            try? manager.removeItem(at: file)
        }
        let captures = names.filter { $0.hasPrefix("Capture-") && $0.hasSuffix(".png") }.sorted()
        guard captures.count > keeping else { return }
        for name in captures.prefix(captures.count - keeping) {
            try? manager.removeItem(at: directory.appending(path: name))
        }
    }

    static func sanitized(_ label: String) -> String {
        let allowed = label.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(allowed).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "capture" : String(collapsed.prefix(40))
    }
}


// MARK: - The helper app

extension ScreenCapture {
    /// The app macOS names when Northpane asks to record a Host's screen.
    ///
    /// macOS decides who may record by the process it holds *responsible*, and it will neither
    /// alert about nor list a process it cannot name. A Bridge started over SSH is the
    /// responsibility of `/usr/libexec/sshd-keygen-wrapper`, a system binary buried in
    /// `/usr/libexec`: nothing appears on the Host's screen and the operator is left hunting for
    /// a path in an Open panel. So the Bridge installs a small app bundle in the Host user's
    /// Applications folder and asks *it* to capture. Launch Services opens it inside the screen
    /// session, where macOS alerts under the name "Northpane Screen Capture" and lists it in
    /// Screen Recording like any app, one click away.
    ///
    /// The bundle carries its own copy of the Bridge, and that copy is *frozen*: it is written
    /// once and left alone while `layout` stays the same. An ad-hoc signature is a hash of the
    /// bundle, and macOS remembers the operator's decision against that hash, so a bundle
    /// rewritten with every Bridge update would lose the permission every time. A launcher
    /// script instead of a binary does not help: `/bin/sh` is a platform binary, so macOS looks
    /// straight past the bundle and holds the Bridge itself responsible again. Freezing the copy
    /// is what makes the permission a thing granted once. It is spent only when the helper's own
    /// contract changes, and `layout` is what says so.
    ///
    /// The Bridge hands the helper one command at a time and reads the answer from a file the
    /// caller names. The helper listens for nothing and outlives no command.
    public struct Helper: Sendable {
        public static let bundleName = "Northpane Screen Capture"
        public static let bundleIdentifier = "it.ambiens.northpane.screen-capture"
        /// The subcommand the Bridge answers to when the helper runs it.
        public static let command = "screen-capture-helper"
        /// What the installed helper is expected to be. Bumping it replaces the frozen copy, and
        /// with it the identity macOS remembers, so the operator has to allow the helper afresh:
        /// bump it only when the commands below change, never with the Bridge's own version.
        public static let layout = "1"

        public let bundleURL: URL

        public static func defaultLocation(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
            home.appending(path: "Applications", directoryHint: .isDirectory).appending(path: "\(bundleName).app", directoryHint: .isDirectory)
        }

        static var infoPlist: String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(bundleIdentifier)</string>
            <key>CFBundleName</key><string>\(bundleName)</string>
            <key>CFBundleDisplayName</key><string>\(bundleName)</string>
            <key>CFBundleExecutable</key><string>\(bundleName)</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleShortVersionString</key><string>1.0</string>
            <key>CFBundleVersion</key><string>\(layout)</string>
            <key>LSUIElement</key><true/>
            <key>LSMinimumSystemVersion</key><string>15.0</string>
            <key>NSHumanReadableCopyright</key><string>Takes one screenshot of this Mac for a Northpane operator, when Northpane Bridge asks.</string>
            </dict></plist>

            """
        }

        /// Installs the bundle, and leaves the one already in place alone when it carries this
        /// layout — that untouched copy is the whole point. A fresh bundle is assembled beside
        /// its final place and swapped in whole, so a capture never meets a half-written helper,
        /// and it is signed under a fixed identifier because that identity is what macOS
        /// remembers the operator's decision by.
        @discardableResult
        public static func install(bridgeExecutable: URL, at location: URL = defaultLocation(),
                                   codesign: URL = URL(fileURLWithPath: "/usr/bin/codesign")) throws -> Helper {
            let manager = FileManager.default
            let executable = location.appending(path: "Contents/MacOS/\(bundleName)")
            let stampFile = location.appending(path: "Contents/Resources/layout.txt")
            if let installed = try? String(contentsOf: stampFile, encoding: .utf8), installed == layout,
               manager.isExecutableFile(atPath: executable.path) {
                return Helper(bundleURL: location)
            }
            let parent = location.deletingLastPathComponent()
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = parent.appending(path: ".\(bundleName).\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? manager.removeItem(at: staging) }
            try manager.createDirectory(at: staging.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
            try manager.createDirectory(at: staging.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
            let stagedExecutable = staging.appending(path: "Contents/MacOS/\(bundleName)")
            try manager.copyItem(at: bridgeExecutable, to: stagedExecutable)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedExecutable.path)
            try Data(infoPlist.utf8).write(to: staging.appending(path: "Contents/Info.plist"))
            try Data(layout.utf8).write(to: staging.appending(path: "Contents/Resources/layout.txt"))
            try sign(staging, using: codesign)

            if manager.fileExists(atPath: location.path) { try manager.removeItem(at: location) }
            try manager.moveItem(at: staging, to: location)
            return Helper(bundleURL: location)
        }

        static func sign(_ bundle: URL, using codesign: URL) throws {
            let process = Process()
            process.executableURL = codesign
            process.arguments = ["--force", "--sign", "-", "--identifier", bundleIdentifier, bundle.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            do { try process.run() } catch { throw ScreenCaptureError.helperFailed("codesign could not start: \(error.localizedDescription)") }
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ScreenCaptureError.helperFailed("codesign failed: \(detail)") }
        }

        /// Whether anyone is logged in at the Host's screen. Launch Services can only open the
        /// helper into a session that exists, and there is nothing to photograph without one.
        public static var consoleUserIsPresent: Bool {
            guard let name = SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String? else { return false }
            return name != "loginwindow"
        }

        public func list(timeout: TimeInterval = 20) throws -> [Target] {
            guard let targets = try run(["list"], timeout: timeout).targets else {
                throw ScreenCaptureError.helperFailed("the helper answered without a listing")
            }
            return targets
        }

        public func capture(targetID: String, timeout: TimeInterval = 40) throws -> Capture {
            guard let capture = try run(["capture", "--target", targetID], timeout: timeout).capture else {
                throw ScreenCaptureError.helperFailed("the helper answered without a capture")
            }
            return capture
        }

        /// Opens the helper with one command and waits for the answer file it was told to write.
        /// The file, not the exit of `open`, is what is waited on: Launch Services cannot always
        /// follow a background agent to its end and returns early, saying so on standard error.
        func run(_ arguments: [String], timeout: TimeInterval,
                 open: URL = URL(fileURLWithPath: "/usr/bin/open"),
                 directory: URL = ScreenCapture.defaultDirectory()) throws -> HelperResult {
            guard Self.consoleUserIsPresent else { throw ScreenCaptureError.noGUISession }
            let token = UUID().uuidString
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let answer = Self.answerFile(token: token, directory: directory)
            try? FileManager.default.removeItem(at: answer)

            let process = Process()
            process.executableURL = open
            process.arguments = ["-W", "-n", "-g", "-a", bundleURL.path, "--args", Self.command] + arguments + ["--token", token]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            do { try process.run() } catch { throw ScreenCaptureError.helperFailed("open could not start: \(error.localizedDescription)") }
            let launched = Date()

            let deadline = launched.addingTimeInterval(timeout)
            var data: Data?
            while Date() < deadline {
                if let read = try? Data(contentsOf: answer), !read.isEmpty { data = read; break }
                // `open` returning is not the helper finishing, but a couple of seconds after it
                // has gone with nothing written means nothing is coming.
                if !process.isRunning, Date() >= launched.addingTimeInterval(2) { break }
                usleep(50_000)
            }
            if process.isRunning { process.terminate() }
            guard let data else {
                let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .split(whereSeparator: \.isNewline)
                    // Launch Services says this whenever it loses sight of a background agent; it
                    // is not why the helper failed, and repeating it would only mislead.
                    .filter { !$0.contains("Unable to block on application") }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                throw ScreenCaptureError.helperFailed(detail.isEmpty ? "the helper left no answer" : detail)
            }
            defer { try? FileManager.default.removeItem(at: answer) }
            guard let result = try? JSONDecoder().decode(HelperResult.self, from: data) else {
                throw ScreenCaptureError.helperFailed("the helper's answer could not be read")
            }
            switch result.error {
            case nil: return result
            case "notPermitted": throw ScreenCaptureError.notPermitted
            case "unknownTarget": throw ScreenCaptureError.unknownTarget
            case "noGUISession": throw ScreenCaptureError.noGUISession
            case let other?: throw ScreenCaptureError.captureFailed(result.detail ?? other)
            }
        }

        static func answerFile(token: String, directory: URL) -> URL {
            directory.appending(path: "answer-\(token).json")
        }
    }

    struct HelperResult: Codable {
        var targets: [Target]?
        var capture: Capture?
        var error: String?
        var detail: String?
    }

    /// What the Bridge runs when the helper invokes it: `list --token T`, or
    /// `capture --target ID --token T`. The answer is written to a file named by the token
    /// inside the capture folder, and nothing else about the invocation grants anything: a
    /// stray caller can make the helper photograph the screen it is already allowed to
    /// photograph, into the folder it already writes to.
    public static func runHelper(arguments: [String]) -> Int32 {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let token = value(after: "--token"),
              token.range(of: #"^[A-Fa-f0-9-]{1,64}$"#, options: .regularExpression) != nil
        else { return 64 }
        let directory = defaultDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var result = HelperResult()
        switch arguments.first {
        case "list":
            result.targets = targets()
        case "capture":
            do {
                result.capture = try capture(targetID: value(after: "--target") ?? "", directory: directory)
            } catch let error as ScreenCaptureError {
                switch error {
                case .notPermitted: result.error = "notPermitted"
                case .unknownTarget: result.error = "unknownTarget"
                case .noGUISession: result.error = "noGUISession"
                case let .captureFailed(detail): result.error = "captureFailed"; result.detail = detail
                case let .helperFailed(detail): result.error = "helperFailed"; result.detail = detail
                }
            } catch {
                result.error = "captureFailed"
                result.detail = error.localizedDescription
            }
        default:
            return 64
        }
        guard let data = try? JSONEncoder().encode(result),
              (try? data.write(to: Helper.answerFile(token: token, directory: directory), options: .atomic)) != nil
        else { return 74 }
        return 0
    }
}
#endif
