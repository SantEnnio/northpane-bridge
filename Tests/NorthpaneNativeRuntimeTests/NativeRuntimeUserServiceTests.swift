#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import NorthpaneNativeRuntime

@Suite struct NativeRuntimeUserServiceTests {
    @Test func registrationPreservesLiteralPathsAndUserEnvironment() throws {
        let definition = try RuntimeServiceDefinition(
            stateDirectory: URL(fileURLWithPath: "/tmp/state space/$HOME/%n/é"),
            executableURL: URL(fileURLWithPath: "/tmp/Bridge \"quoted\"/$agent/%i/northpane-bridge"),
            homeDirectory: URL(fileURLWithPath: "/tmp/cert-home"))
        let plist = try #require(PropertyListSerialization.propertyList(from: definition.macPropertyList(), format: nil) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == [definition.executableURL.path, "runtime"])
        #expect(plist["EnvironmentVariables"] as? [String: String] == ["NORTHPANE_STATE_DIRECTORY": definition.stateDirectory.path])
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["StandardOutPath"] as? String == "/dev/null")
        let unit = definition.linuxUnit()
        #expect(unit.contains("ExecStart=:\"/tmp/Bridge \\\"quoted\\\"/$agent/%%i/northpane-bridge\" runtime"))
        #expect(unit.contains("Environment=\"NORTHPANE_STATE_DIRECTORY=/tmp/state space/$HOME/%%n/é\""))
        #expect(unit.contains("Restart=on-failure"))
        #expect(!unit.contains("restart "))
    }

    @Test func registrationRejectsDirectiveInjectionAndRelativeEndpoints() throws {
        for path in ["/tmp/file\nEnvironment=BAD", "/tmp/file\rBAD", "/tmp/file\tBAD"] {
            #expect(throws: NativeRuntimeProcessError.invalidConfiguration) {
                _ = try RuntimeServiceDefinition(stateDirectory: URL(fileURLWithPath: path),
                    executableURL: URL(fileURLWithPath: "/tmp/bridge"), homeDirectory: URL(fileURLWithPath: "/tmp/home"))
            }
        }
        #expect(throws: NativeRuntimeProcessError.invalidConfiguration) {
            _ = try RuntimeServiceDefinition(stateDirectory: URL(string: "https://example.invalid/state")!,
                executableURL: URL(fileURLWithPath: "/tmp/bridge"), homeDirectory: URL(fileURLWithPath: "/tmp/home"))
        }
    }

    @Test func repeatedRegistrationIsIdempotentAndDoesNotRunAServiceManager() throws {
        let home = URL(fileURLWithPath: "/tmp/np-service-" + UUID().uuidString.prefix(12))
        defer { try? FileManager.default.removeItem(at: home) }
        let definition = try RuntimeServiceDefinition(stateDirectory: home.appending(path: "state"),
            executableURL: home.appending(path: "bridge"), homeDirectory: home)
        #expect(try definition.writeLinuxRegistration())
        #expect(try !definition.writeLinuxRegistration())
        try definition.writeMacRegistration()
        #expect(try Data(contentsOf: definition.macRegistration) == definition.macPropertyList())
        #expect(try String(contentsOf: definition.linuxRegistration, encoding: .utf8) == definition.linuxUnit())
    }

    @Test func aVersionedInstallerUsesCurrentForTheNextServiceStart() throws {
        let home = URL(fileURLWithPath: "/tmp/np-current-" + UUID().uuidString.prefix(12))
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appending(path: ".local/share/northpane/bridge/versions/test/northpane-bridge")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let current = home.appending(path: ".local/share/northpane/bridge/current")
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: executable.deletingLastPathComponent())
        let definition = try RuntimeServiceDefinition(stateDirectory: home.appending(path: "state"),
            executableURL: executable, homeDirectory: home)
        #expect(definition.executableURL == current.appending(path: "northpane-bridge"))
        let app = try RuntimeServiceDefinition(stateDirectory: home.appending(path: "state"),
            executableURL: URL(fileURLWithPath: "/Applications/Example.app/Contents/MacOS/northpane-bridge"), homeDirectory: home)
        #expect(app.executableURL.path == "/Applications/Example.app/Contents/MacOS/northpane-bridge")
    }
}
#endif
