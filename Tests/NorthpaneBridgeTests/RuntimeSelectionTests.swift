import Foundation
import Testing
import NorthpaneHostRuntime
import NorthpaneHerdrIntegration
import NorthpaneProtocol
@testable import NorthpaneBridge

@Suite struct RuntimeSelectionTests {
    @Test func installedHerdrRemainsTheDefaultAndErrorsCannotTriggerSelectionAgain() throws {
        let directory = HerdrProcessRunner.isWindows ? #"C:\tools"# : "/tools"
        let executable = HerdrProcessRunner.isWindows ? #"C:\tools\herdr.exe"# : "/tools/herdr"
        let selected = try RuntimeSelection.resolve(environment: ["PATH": directory], homeDirectory: "/home/operator",
            nativeSupported: true, isExecutable: { $0 == executable })
        #expect(selected.kind == .herdr)
        #expect(selected.herdrExecutable == URL(fileURLWithPath: executable))
    }
    @Test func aMissingHerdrSelectsNativeOnlyOnSupportedHosts() throws {
        #expect(try RuntimeSelection.resolve(environment: [:], homeDirectory: "/home/operator", nativeSupported: true,
            isExecutable: { _ in false }).kind == .native)
        let unavailable = try RuntimeSelection.resolve(environment: [:], homeDirectory: "/home/operator", nativeSupported: false,
            isExecutable: { _ in false })
        #expect(unavailable.kind == .herdr && unavailable.herdrExecutable == nil)
    }
    @Test func explicitChoicesAreHonoredAndInvalidValuesFail() throws {
        #expect(try RuntimeSelection.resolve(environment: ["NORTHPANE_RUNTIME": "native"], homeDirectory: "/home/operator",
            nativeSupported: true, isExecutable: { _ in true }).kind == .native)
        let unavailable = try RuntimeSelection.resolve(environment: ["NORTHPANE_RUNTIME": "herdr"], homeDirectory: "/home/operator",
            nativeSupported: true, isExecutable: { _ in false })
        #expect(unavailable.kind == .herdr && unavailable.herdrExecutable == nil)
        #expect(throws: NativeSelectionError.invalidOverride) {
            try RuntimeSelection.resolve(environment: ["NORTHPANE_RUNTIME": "typo"], homeDirectory: "/home/operator")
        }
        #expect(throws: NativeSelectionError.unsupportedPlatform) {
            try RuntimeSelection.resolve(environment: ["NORTHPANE_RUNTIME": "native"], homeDirectory: "/home/operator", nativeSupported: false)
        }
    }
}

@Test func runtimeDiscoveryRemainsAvailableWithoutAnExecutable() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-runtime-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try await BridgeHostContext(stateDirectory: directory, runtimeFactory: { sessionName, incarnationID in
        try HerdrHostRuntime(executableURL: URL(fileURLWithPath: "/not-an-executable"), sessionName: sessionName,
                             incarnationID: incarnationID)
    })
    // Discovery is allowed before the Host has a runtime executable installed.
    #expect(await context.detectedHerdrVersion() == "unavailable")
}

@Test func runtimeScopesUseSeparateAdaptersAndKeepTheirState() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-runtime-scopes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try await BridgeHostContext(stateDirectory: directory, runtimeFactory: { _, _ in FakeHostRuntime() })
    let created = try await context.createWorkspace(label: "First", workingDirectory: directory.appending(path: "work").path,
                                                   agentKind: .shell, sessionName: "first")
    let first = try await context.currentSnapshot(sessionName: "first")
    let second = try await context.currentSnapshot(sessionName: "second")
    #expect(first.workspaces.first?.id == created.workspaceID)
    #expect(second.workspaces.isEmpty)
    #expect(first.incarnationID != second.incarnationID)
    let firstAgain = try await context.currentSnapshot(sessionName: "first")
    #expect(firstAgain.incarnationID == first.incarnationID)
    #expect(firstAgain.workspaces == first.workspaces)
}
