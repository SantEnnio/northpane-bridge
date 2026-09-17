#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NorthpaneBridgeResources

private func scratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-capture-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A PNG the size of a Retina display, full of noise so it does not compress away.
private func writeLargePNG(to file: URL, width: Int = 3_024, height: Int = 1_964) throws {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var state: UInt32 = 0x9E37_79B9
    for index in stride(from: 0, to: pixels.count, by: 4) {
        state = state &* 1_664_525 &+ 1_013_904_223
        pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
        pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 16)
        pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 8)
        pixels[index + 3] = 255
    }
    let data = Data(pixels)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw ScreenCaptureError.captureFailed("fixture") }
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

@Test func targetIDsNameOneDisplayOrOneWindowAndNothingElse() {
    #expect(ScreenCapture.parse(targetID: "display:1") == .display(1))
    #expect(ScreenCapture.parse(targetID: "window:25634") == .window(25_634))
    #expect(ScreenCapture.parse(targetID: "window:") == nil)
    #expect(ScreenCapture.parse(targetID: "window:-1") == nil)
    #expect(ScreenCapture.parse(targetID: "screen:1") == nil)
    #expect(ScreenCapture.parse(targetID: "/tmp/x.png") == nil)
}

@Test func theListingDescribesDisplaysFirstAndOnlyRealWindows() {
    let targets = ScreenCapture.targets()
    // A headless test runner may have no display at all; the shape still has to hold.
    let displays = targets.filter { $0.kind == .display }
    let windows = targets.filter { $0.kind == .window }
    #expect(targets.prefix(displays.count).allSatisfy { $0.kind == .display })
    #expect(displays.allSatisfy { $0.id.hasPrefix("display:") && $0.application.isEmpty && $0.width > 0 && $0.height > 0 })
    #expect(displays.filter(\.isFrontmost).count <= 1)
    #expect(windows.allSatisfy { $0.id.hasPrefix("window:") && !$0.application.isEmpty && $0.width >= 64 && $0.height >= 64 })
    #expect(windows.filter(\.isFrontmost).count <= 1)
    // The test process itself never appears.
    #expect(windows.allSatisfy { $0.application != ProcessInfo.processInfo.processName })
}

@Test func thePreviewOfARetinaCaptureFitsInOneFrameAsJPEG() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let png = directory.appending(path: "Capture-20260909-050000-display.png")
    try writeLargePNG(to: png)
    let pngSize = try FileManager.default.attributesOfItem(atPath: png.path)[.size] as? Int ?? 0
    #expect(pngSize > ScreenCapture.maximumPreviewBytes)

    let preview = try ScreenCapture.preview(of: png)

    #expect(preview.count <= ScreenCapture.maximumPreviewBytes)
    #expect(preview.prefix(2) == Data([0xFF, 0xD8]))
    let source = try #require(CGImageSourceCreateWithData(preview as CFData, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    #expect(width > 0 && width <= ScreenCapture.previewMaximumPixelSize)
}

@Test func oldCapturesArePrunedByStampKeepingTheNewest() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<25 {
        try Data("x".utf8).write(to: directory.appending(path: String(format: "Capture-20260909-%06d-app.png", index)))
    }
    try Data("keep".utf8).write(to: directory.appending(path: "notes.txt"))

    ScreenCapture.prune(directory: directory, keeping: 20)

    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(names.filter { $0.hasPrefix("Capture-") }.count == 20)
    #expect(!names.contains("Capture-20260909-000000-app.png"))
    #expect(names.contains("Capture-20260909-000024-app.png"))
    #expect(names.contains("notes.txt"))
}

/// The alert macOS raises is the system's, and it stays on the Host's screen until somebody
/// answers it. Asking again for every refused capture buries it under a fresh one instead, on a
/// screen that may have nobody in front of it — which is exactly what an operator saw as "it asks
/// permission every single time". So the ask happens once, and afterwards only the pane that
/// holds the switch is opened, once.
@Test func macOSIsAskedForTheScreenRecordingPermissionOnceAndNotOncePerCapture() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // A stand-in for `open`, which records every settings pane it was asked to show.
    let opened = directory.appending(path: "opened.txt")
    let fakeOpen = directory.appending(path: "fake-open")
    try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(opened.path)\n".utf8).write(to: fakeOpen)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path)

    // The ask is stood in for: a test must not put a real alert on whoever's screen this runs on.
    var asked = 0
    func request() -> Bool { ScreenCapture.requestPermission(directory: directory, open: fakeOpen, ask: { asked += 1; return false }) }
    guard !ScreenCapture.isPermitted else { return }   // nothing to ask for here
    #expect(!FileManager.default.fileExists(atPath: ScreenCapture.alertRaisedMarker(directory: directory).path))

    // The first refusal raises the alert and opens nothing on top of it.
    _ = request()
    #expect(asked == 1)
    #expect(FileManager.default.fileExists(atPath: ScreenCapture.alertRaisedMarker(directory: directory).path))
    #expect(!FileManager.default.fileExists(atPath: opened.path))

    // The next one leaves the switch on screen instead of stacking a second alert. The pane is
    // opened without waiting for it, so give the stand-in a moment to say it was asked.
    _ = request()
    func linesShown() -> [String] {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: opened, encoding: .utf8), !text.isEmpty {
                return text.split(whereSeparator: \.isNewline).map(String.init)
            }
            usleep(20_000)
        }
        return []
    }
    var shown = linesShown()
    #expect(shown.count == 1)
    #expect(shown.first?.contains("Privacy_ScreenCapture") == true)

    // And every one after that leaves the Host alone: no second alert, no second pane.
    _ = request()
    _ = request()
    #expect(asked == 1)
    usleep(200_000)
    shown = linesShown()
    #expect(shown.count == 1)

    // Once the permission is there the memory is dropped, so taking it away asks again.
    ScreenCapture.forgetPermissionRequest(directory: directory)
    #expect(!FileManager.default.fileExists(atPath: ScreenCapture.alertRaisedMarker(directory: directory).path))
    #expect(!FileManager.default.fileExists(atPath: ScreenCapture.paneOpenedMarker(directory: directory).path))
}

/// An answer written after the Bridge stopped waiting for it has nobody left to delete it.
@Test func answersAbandonedByTheBridgeArePrunedWithTheCaptures() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stale = ScreenCapture.Helper.answerFile(token: UUID().uuidString, directory: directory)
    let fresh = ScreenCapture.Helper.answerFile(token: UUID().uuidString, directory: directory)
    try Data("{}".utf8).write(to: stale)
    try Data("{}".utf8).write(to: fresh)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: stale.path)

    ScreenCapture.prune(directory: directory, keeping: 20)

    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
}

@Test func aCaptureWithoutTheScreenRecordingPermissionIsRefusedNotFaked() throws {
    // `screencapture` is stood in for by a script that behaves as the real one does without the
    // permission: it prints the diagnosis and writes no file.
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fake = directory.appending(path: "fake-screencapture")
    try Data("#!/bin/sh\necho 'could not create image from display' >&2\nexit 1\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)

    // Without the permission the refusal comes before anything runs; with it, the fake's own
    // diagnosis is read as the same refusal. Either way no capture is invented.
    let target = ScreenCapture.isPermitted ? ScreenCapture.targets().first { $0.kind == .window }?.id : "window:1"
    if let target {
        #expect(throws: ScreenCaptureError.notPermitted) {
            _ = try ScreenCapture.capture(targetID: target, directory: directory, screencapture: fake)
        }
    }
    #expect(throws: ScreenCaptureError.unknownTarget) {
        _ = try ScreenCapture.capture(targetID: "bogus", directory: directory, screencapture: fake)
    }
}

@Test func captureLabelsAreSafeFileNames() {
    #expect(ScreenCapture.sanitized("Safari") == "Safari")
    #expect(ScreenCapture.sanitized("Visual Studio Code") == "Visual-Studio-Code")
    #expect(ScreenCapture.sanitized("../etc/passwd") == "etc-passwd")
    #expect(ScreenCapture.sanitized("   ") == "capture")
}

/// The permission an operator grants on the Host is remembered against the helper's ad-hoc
/// signature, which is a hash of the bundle. So the copy of the Bridge inside it is frozen:
/// installing again with the same layout must not touch a byte, or every Bridge update would
/// cost the operator the permission they already gave. This is the whole reason it lasts.
@Test func theInstalledHelperIsFrozenSoTheGrantOutlivesBridgeUpdates() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = directory.appending(path: "\(ScreenCapture.Helper.bundleName).app", directoryHint: .isDirectory)
    let firstBridge = directory.appending(path: "northpane-bridge-1")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: firstBridge)

    let helper = try ScreenCapture.Helper.install(bridgeExecutable: firstBridge, at: location)
    #expect(helper.bundleURL == location)

    let executable = location.appending(path: "Contents/MacOS/\(ScreenCapture.Helper.bundleName)")
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
    // macOS remembers the operator's decision by this identity, so it is fixed and the whole
    // bundle really is signed.
    #expect(try codesignIdentity(of: location) == ScreenCapture.Helper.bundleIdentifier)

    let signature = location.appending(path: "Contents/_CodeSignature/CodeResources")
    let sealed = try Data(contentsOf: signature)
    let frozen = try Data(contentsOf: executable)

    // The Bridge is updated and asks again: nothing about the helper may move.
    let secondBridge = directory.appending(path: "northpane-bridge-2")
    try Data("#!/bin/sh\necho a newer Bridge\nexit 0\n".utf8).write(to: secondBridge)
    _ = try ScreenCapture.Helper.install(bridgeExecutable: secondBridge, at: location)

    #expect(try Data(contentsOf: executable) == frozen)
    #expect(try Data(contentsOf: signature) == sealed)
}

@Test func aDamagedHelperIsReplacedRatherThanTrusted() throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = directory.appending(path: "\(ScreenCapture.Helper.bundleName).app", directoryHint: .isDirectory)
    let bridge = directory.appending(path: "northpane-bridge")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bridge)
    _ = try ScreenCapture.Helper.install(bridgeExecutable: bridge, at: location)

    // Whatever went missing — an interrupted install, a half-deleted bundle — the next capture
    // must meet a whole helper rather than a stump.
    try FileManager.default.removeItem(at: location.appending(path: "Contents/MacOS"))
    _ = try ScreenCapture.Helper.install(bridgeExecutable: bridge, at: location)

    let executable = location.appending(path: "Contents/MacOS/\(ScreenCapture.Helper.bundleName)")
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
    #expect(try codesignIdentity(of: location) == ScreenCapture.Helper.bundleIdentifier)
    // Nothing is left beside it: staging directories are swapped in, never abandoned.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(siblings == ["Northpane Screen Capture.app", "northpane-bridge"])
}

/// The helper answers one command and writes it where it was told; an invocation it cannot
/// trust is refused before anything is captured.
@Test func theHelperOnlyAnswersAWellFormedCommand() throws {
    #expect(ScreenCapture.runHelper(arguments: ["list"]) == 64)                              // no token
    #expect(ScreenCapture.runHelper(arguments: ["list", "--token", "../../etc/passwd"]) == 64)
    #expect(ScreenCapture.runHelper(arguments: ["list", "--token", "not a uuid"]) == 64)
    #expect(ScreenCapture.runHelper(arguments: ["serve", "--stdio", "--token", UUID().uuidString]) == 64)

    let token = UUID().uuidString
    #expect(ScreenCapture.runHelper(arguments: ["list", "--token", token]) == 0)
    let answer = ScreenCapture.Helper.answerFile(token: token, directory: ScreenCapture.defaultDirectory())
    defer { try? FileManager.default.removeItem(at: answer) }
    let result = try JSONDecoder().decode(ScreenCapture.HelperResult.self, from: Data(contentsOf: answer))
    #expect(result.error == nil)
    #expect(result.targets != nil)
}

private func codesignIdentity(of bundle: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["-d", "-vv", bundle.path]
    let output = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = output
    try process.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return text.split(whereSeparator: \.isNewline)
        .first { $0.hasPrefix("Identifier=") }
        .map { String($0.dropFirst("Identifier=".count)) } ?? ""
}
#endif
