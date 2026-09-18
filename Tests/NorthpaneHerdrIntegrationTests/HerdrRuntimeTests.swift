import Foundation
import NorthpaneProtocol
import Testing
@testable import NorthpaneHerdrIntegration

private actor FixtureRunner: HerdrCommandRunning {
    let responses: [Data]
    private var index = 0
    private var invocations: [[String]] = []
    init(_ responses: [Data]) { self.responses = responses }
    func run(arguments: [String]) throws -> Data {
        invocations.append(arguments)
        guard index < responses.count else { return responses.last ?? Data() }
        defer { index += 1 }
        return responses[index]
    }
    func capturedArguments() -> [[String]] { invocations }
}

private actor AgentDetectionRaceRunner: HerdrCommandRunning {
    private var waitAttempts = 0
    private var invocations: [[String]] = []

    func run(arguments: [String]) throws -> Data {
        invocations.append(arguments)
        if arguments.contains("wait") {
            waitAttempts += 1
            if waitAttempts == 1 {
                throw HerdrRuntimeError.commandFailed(#"{"error":{"code":"agent_not_found","message":"agent target wB:p1 not found"}}"#)
            }
        }
        return Data(#"{"result":{"type":"ok"}}"#.utf8)
    }

    func capturedArguments() -> [[String]] { invocations }
}

private let fullSnapshot = Data(#"{"id":"test","result":{"type":"session_snapshot","snapshot":{"version":"0.8.2","protocol":20,"workspaces":[{"workspace_id":"w1","number":1,"label":"Northpane","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"t1","agent_status":"working","worktree":{"checkout_path":"/code/northpane","is_linked_worktree":false,"repo_key":"/code/northpane/.git","repo_name":"northpane","repo_root":"/code/northpane"}}],"tabs":[{"tab_id":"t1","workspace_id":"w1","number":1,"label":"Build","focused":true,"pane_count":1,"agent_status":"working"}],"panes":[{"pane_id":"p1","terminal_id":"term1","workspace_id":"w1","tab_id":"t1","focused":true,"agent_status":"working","revision":7,"display_agent":"Codex","terminal_title_stripped":"Tests"}],"layouts":[],"agents":[]}}}"#.utf8)

/// The worktree as Herdr 0.8.2 really reports it (`checkout_path`), captured from a live server.
@Test func workspaceWorktreeComesFromHerdrsCheckoutPath() async throws {
    let runtime = HerdrRuntime(runner: FixtureRunner([fullSnapshot]), incarnationID: "worktree")
    let snapshot = try await runtime.currentSnapshot(hostID: HostID(), sessionName: nil)
    #expect(snapshot.workspaces.first?.worktreePath == "/code/northpane")
}

@Test func executableRuntimeUsesTwoEqualSnapshotsAsBarrier() async throws {
    let runtime = HerdrRuntime(runner: FixtureRunner([fullSnapshot, fullSnapshot]), incarnationID: "incarnation")
    let snapshot = try await runtime.currentSnapshot(hostID: HostID())
    #expect(snapshot.incarnationID == "incarnation")
    #expect(snapshot.workspaces.first?.id == "w1")
    #expect(snapshot.tabs.first?.workspaceID == "w1")
    #expect(snapshot.panes.first?.agent == "Codex")
    #expect(snapshot.panes.first?.revision == 7)
}

@Test func executableRuntimeRejectsAnUnstableBarrier() async throws {
    let changed = Data(String(decoding: fullSnapshot, as: UTF8.self).replacingOccurrences(of: "\"revision\":7", with: "\"revision\":8").utf8)
    let runtime = HerdrRuntime(runner: FixtureRunner([fullSnapshot, changed]), incarnationID: "incarnation")
    await #expect(throws: HerdrRuntimeError.unstableSnapshot) {
        _ = try await runtime.currentSnapshot(hostID: HostID(), attempts: 1)
    }
}

@Test func executableRuntimeCreatesAWorkspaceWithoutChangingHerdrFocus() async throws {
    let response = Data(#"{"id":"cli:workspace:create","result":{"root_pane":{"pane_id":"wB:p1","workspace_id":"wB"},"type":"workspace_created","workspace":{"workspace_id":"wB"}}}"#.utf8)
    let runner = FixtureRunner([response])
    let runtime = HerdrRuntime(runner: runner, incarnationID: "incarnation")
    let created = try await runtime.createWorkspace(label: "Preview test", workingDirectory: "/private/tmp/preview", sessionName: "default")
    #expect(created == CreatedWorkspace(workspaceID: "wB", paneID: "wB:p1"))
    #expect(await runner.capturedArguments() == [[
        "--session", "default", "workspace", "create", "--cwd", "/private/tmp/preview",
        "--label", "Preview test", "--no-focus",
    ]])
}

@Test func executableRuntimeClosesAWorkspaceInTheObservedSession() async throws {
    let runner = FixtureRunner([Data(#"{"id":"cli:workspace:close","result":{"type":"ok"}}"#.utf8)])
    let runtime = HerdrRuntime(runner: runner, incarnationID: "incarnation")

    try await runtime.closeWorkspace(workspaceID: "wB", sessionName: "default")

    #expect(await runner.capturedArguments() == [["--session", "default", "workspace", "close", "wB"]])
}

@Test func executableRuntimeRenamesAWorkspaceInTheObservedSession() async throws {
    let runner = FixtureRunner([Data(#"{"id":"cli:workspace:rename","result":{"type":"ok"}}"#.utf8)])
    let runtime = HerdrRuntime(runner: runner, incarnationID: "incarnation")

    try await runtime.renameWorkspace(workspaceID: "wB", label: "  Preview  ", sessionName: "default")

    // The name goes to Herdr trimmed, because Herdr shows it to everyone as given.
    #expect(await runner.capturedArguments() == [["--session", "default", "workspace", "rename", "wB", "Preview"]])
}

@Test func aWorkspaceCannotBeRenamedToNothing() async throws {
    let runtime = HerdrRuntime(runner: FixtureRunner([]), incarnationID: "incarnation")
    await #expect(throws: HerdrRuntimeError.self) { try await runtime.renameWorkspace(workspaceID: "wB", label: "   ") }
    await #expect(throws: HerdrRuntimeError.self) { try await runtime.renameWorkspace(workspaceID: "wB", label: "two\nlines") }
}

@Test func executableRuntimeLaunchesTheVerifiedAgentAndAcceptsBlockedReadiness() async throws {
    let response = Data(#"{"id":"cli:workspace:create","result":{"root_pane":{"pane_id":"wB:p1","workspace_id":"wB"},"type":"workspace_created","workspace":{"workspace_id":"wB"}}}"#.utf8)
    let runner = FixtureRunner([
        response,
        Data(#"{"result":{"type":"pane_input"}}"#.utf8),
        Data(#"{"result":{"type":"agent_wait","agent":{"state":"blocked"}}}"#.utf8),
        Data(#"{"result":{"type":"agent_renamed"}}"#.utf8),
    ])
    let runtime = HerdrRuntime(runner: runner, incarnationID: "incarnation")
    let created = try await runtime.createWorkspace(label: "Agent test", workingDirectory: "/private/tmp/agent",
        sessionName: "default", environment: ["PATH": "/Applications/ChatGPT.app/Contents/Resources:/usr/bin"])
    try await runtime.startAgent(.codex,
                                 executableURL: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
                                 name: HerdrAgentNaming.name(workspaceID: created.workspaceID),
                                 paneID: created.paneID, sessionName: "default")
    #expect(await runner.capturedArguments() == [
        ["--session", "default", "workspace", "create", "--cwd", "/private/tmp/agent", "--label", "Agent test",
         "--env", "PATH=/Applications/ChatGPT.app/Contents/Resources:/usr/bin", "--no-focus"],
        ["--session", "default", "pane", "run", "wB:p1", "exec '/Applications/ChatGPT.app/Contents/Resources/codex'"],
        ["--session", "default", "agent", "wait", "wB:p1", "--until", "idle", "--until", "working", "--until", "blocked", "--timeout", "30000"],
        ["--session", "default", "agent", "rename", "wB:p1", "northpane-wb"],
    ])
}

@Test func executableRuntimeRetriesTheAgentDetectionRace() async throws {
    let runner = AgentDetectionRaceRunner()
    let runtime = HerdrRuntime(runner: runner, incarnationID: "incarnation")
    try await runtime.startAgent(
        .codex,
        executableURL: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
        name: "northpane-wb",
        paneID: "wB:p1",
        timeoutMilliseconds: 1_000
    )

    let invocations = await runner.capturedArguments()
    #expect(invocations.first == ["pane", "run", "wB:p1", "exec '/Applications/ChatGPT.app/Contents/Resources/codex'"])
    #expect(invocations.filter { $0.contains("wait") }.count == 2)
    #expect(invocations.last == ["agent", "rename", "wB:p1", "northpane-wb"])
}

private struct FixtureExecutableChecker: AgentExecutableChecking {
    let working: Set<String>
    func isWorkingExecutable(_ url: URL, timeout: TimeInterval) -> Bool { working.contains(url.path) }
}

@Test func agentResolverSkipsBrokenCandidatesAndReturnsTheVerifiedExecutable() throws {
    let resolver = AgentExecutableResolver(
        checker: FixtureExecutableChecker(working: ["/tools/good/codex"]),
        environment: ["NORTHPANE_CODEX_EXECUTABLE": "/tools/broken/codex", "PATH": "/tools/broken:/tools/good:/usr/bin"],
        homeDirectory: "/Users/test"
    )
    let detected = try resolver.resolve(.codex)
    #expect(detected.url.path == "/tools/good/codex")
}

@Test func agentResolverReportsUnavailableWithoutFallingBackToAnUncheckedCommand() {
    let resolver = AgentExecutableResolver(checker: FixtureExecutableChecker(working: []), environment: ["PATH": "/empty"], homeDirectory: "/Users/test")
    #expect(throws: AgentExecutableResolutionError.unavailable(.claude)) { try resolver.resolve(.claude) }
}

@Test func executableRuntimeRejectsMismatchedWorkspaceCreationIdentities() async throws {
    let response = Data(#"{"id":"cli:workspace:create","result":{"root_pane":{"pane_id":"wB:p1","workspace_id":"other"},"type":"workspace_created","workspace":{"workspace_id":"wB"}}}"#.utf8)
    let runtime = HerdrRuntime(runner: FixtureRunner([response]), incarnationID: "incarnation")
    await #expect(throws: HerdrRuntimeError.malformedResponse) {
        _ = try await runtime.createWorkspace(label: "Preview test", workingDirectory: "/private/tmp/preview")
    }
}

@Test func realHerdr082SnapshotDecodesThroughProductionRunner() async throws {
    guard ProcessInfo.processInfo.environment["NORTHPANE_TEST_REAL_HERDR"] == "1" else { return }
    let runner = try HerdrProcessRunner()
    let runtime = HerdrRuntime(runner: runner, incarnationID: "real-herdr-diagnostic")
    let snapshot = try await runtime.currentSnapshot(hostID: HostID(), sessionName: nil)
    #expect(!snapshot.workspaces.isEmpty)
    #expect(!snapshot.tabs.isEmpty)
    #expect(!snapshot.panes.isEmpty)
}

/// Herdr's own installers put it in ~/.local/bin (install.sh) and %LOCALAPPDATA%\Programs\Herdr\bin
/// (install.ps1); a Host that used them must not look Herdr-less to the Bridge.
@Test func herdrIsFoundWhereItsInstallersPutIt() {
    let home = "/home/operator"
    func resolve(_ present: Set<String>, _ environment: [String: String] = [:], windows: Bool = false) -> String? {
        HerdrProcessRunner.resolveExecutable(environment: environment, homeDirectory: home, isExecutable: present.contains, windows: windows)
    }
    #expect(resolve(["/home/operator/.local/bin/herdr", "/usr/bin/herdr"]) == "/home/operator/.local/bin/herdr")
    #expect(resolve(["/opt/homebrew/bin/herdr"]) == "/opt/homebrew/bin/herdr")
    #expect(resolve(["/srv/tools/herdr"], ["HERDR_INSTALL_DIR": "/srv/tools/"]) == "/srv/tools/herdr")
    #expect(resolve(["/nix/profile/bin/herdr"], ["PATH": "/usr/sbin:/nix/profile/bin"]) == "/nix/profile/bin/herdr")
    #expect(resolve(["/custom/herdr", "/usr/bin/herdr"], ["NORTHPANE_HERDR_EXECUTABLE": "/custom/herdr"]) == "/custom/herdr")
    // An override that is not executable is ignored, as before, rather than hiding a working Herdr.
    #expect(resolve(["/usr/bin/herdr"], ["NORTHPANE_HERDR_EXECUTABLE": "/missing/herdr"]) == "/usr/bin/herdr")
    #expect(resolve([]) == nil)

    let local = #"C:\Users\op\AppData\Local"#
    #expect(resolve([#"C:\Users\op\AppData\Local\Programs\Herdr\bin\herdr.exe"#], ["LOCALAPPDATA": local], windows: true)
        == #"C:\Users\op\AppData\Local\Programs\Herdr\bin\herdr.exe"#)
    #expect(resolve([#"D:\bin\herdr.exe"#], ["Path": #"C:\Windows;D:\bin\"#], windows: true) == #"D:\bin\herdr.exe"#)
    #expect(resolve(["/home/operator/.local/bin/herdr"], windows: true) == nil)
}

#if os(macOS)
import Darwin

private final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Test func realHerdr082AcceptsNorthpaneEventSubscription() async throws {
    guard ProcessInfo.processInfo.environment["NORTHPANE_TEST_REAL_HERDR"] == "1" else { return }
    let subscription = HerdrEventSubscription(sessionName: nil)
    try await subscription.start(onEvent: {}, onClose: { _ in })
    subscription.stop()
}

@Test func rawHerdrSubscriptionAcknowledgesThenDeliversEvents() async throws {
    let path = "/tmp/np-herdr-\(UUID().uuidString.prefix(8)).sock"
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(descriptor >= 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let length = MemoryLayout<sa_family_t>.size + bytes.count + 1
    address.sun_len = UInt8(length)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        destination.copyBytes(from: bytes)
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(length)) }
    }
    #expect(bound == 0)
    #expect(Darwin.listen(descriptor, 1) == 0)
    defer { Darwin.close(descriptor); try? FileManager.default.removeItem(atPath: path) }

    let server = Task.detached { () throws -> [String] in
        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else { throw HerdrRuntimeError.sessionNotRunning }
        let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
        var requestBytes = [UInt8](repeating: 0, count: 65_536)
        let received = Darwin.read(client, &requestBytes, requestBytes.count)
        guard received > 0,
              let request = try JSONSerialization.jsonObject(with: Data(requestBytes.prefix(received))) as? [String: Any],
              let id = request["id"] as? String,
              let params = request["params"] as? [String: Any],
              let subscriptions = params["subscriptions"] as? [[String: Any]] else {
            throw HerdrRuntimeError.malformedResponse
        }
        var acknowledgement = try JSONSerialization.data(withJSONObject: ["id": id, "result": ["type": "events_subscribed"]])
        acknowledgement.append(0x0A)
        try handle.write(contentsOf: acknowledgement)
        var event = try JSONSerialization.data(withJSONObject: ["event": ["type": "pane.updated", "pane_id": "p1"]])
        event.append(0x0A)
        try handle.write(contentsOf: event)
        try await Task.sleep(for: .milliseconds(50))
        return subscriptions.compactMap { subscription in
            guard subscription.keys.count == 1 else { return nil }
            return subscription["type"] as? String
        }
    }

    let counter = EventCounter()
    let subscription = HerdrEventSubscription(socketPath: path)
    try await subscription.start(onEvent: { counter.increment() }, onClose: { _ in })
    for _ in 0..<50 where counter.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(counter.value == 1)
    let subscribedTypes = try await server.value
    #expect(subscribedTypes.count >= 20)
    #expect(!subscribedTypes.contains("pane.output_matched"))
    // Per-pane subscriptions need a pane_id; Herdr rejects them on the session-wide connection.
    #expect(!subscribedTypes.contains("pane.agent_status_changed"))
    #expect(!subscribedTypes.contains("pane.scroll_changed"))
    subscription.stop()
}
/// Agent status changes are per-pane subscriptions on Herdr: the agent-status scope must send one
/// `pane.agent_status_changed` entry per pane, each carrying its `pane_id`, and nothing else.
@Test func agentStatusScopeSubscribesOnePaneAtATime() async throws {
    let path = "/tmp/np-herdr-\(UUID().uuidString.prefix(8)).sock"
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(descriptor >= 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let length = MemoryLayout<sa_family_t>.size + bytes.count + 1
    address.sun_len = UInt8(length)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        destination.copyBytes(from: bytes)
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(length)) }
    }
    #expect(bound == 0)
    #expect(Darwin.listen(descriptor, 1) == 0)
    defer { Darwin.close(descriptor); try? FileManager.default.removeItem(atPath: path) }

    let server = Task.detached { () throws -> [[String: String]] in
        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else { throw HerdrRuntimeError.sessionNotRunning }
        let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
        var requestBytes = [UInt8](repeating: 0, count: 65_536)
        let received = Darwin.read(client, &requestBytes, requestBytes.count)
        guard received > 0,
              let request = try JSONSerialization.jsonObject(with: Data(requestBytes.prefix(received))) as? [String: Any],
              let id = request["id"] as? String,
              let params = request["params"] as? [String: Any],
              let subscriptions = params["subscriptions"] as? [[String: String]] else {
            throw HerdrRuntimeError.malformedResponse
        }
        var acknowledgement = try JSONSerialization.data(withJSONObject: ["id": id, "result": ["type": "subscription_started"]])
        acknowledgement.append(0x0A)
        try handle.write(contentsOf: acknowledgement)
        return subscriptions
    }

    let subscription = HerdrEventSubscription(socketPath: path, scope: .agentStatus(paneIDs: ["w1:p1", "w2:p3"]))
    try await subscription.start(onEvent: {}, onClose: { _ in })
    let subscriptions = try await server.value
    #expect(subscriptions == [
        ["type": "pane.agent_status_changed", "pane_id": "w1:p1"],
        ["type": "pane.agent_status_changed", "pane_id": "w2:p3"],
    ])
    subscription.stop()
}
#endif

/// Herdr 0.9.1 keeps its Windows config in %APPDATA%\herdr (XDG_CONFIG_HOME wins when set), and the
/// socket path there names the marker file of a named pipe.
@Test func herdrSocketPathOnWindowsFollowsHerdrsConfigDirectory() {
    func resolve(_ session: String?, _ environment: [String: String]) -> String {
        HerdrEventSubscription.resolveSocketPath(sessionName: session, environment: environment, windows: true)
    }
    let appData = #"C:\Users\op\AppData\Roaming"#
    #expect(resolve(nil, ["APPDATA": appData]) == #"C:\Users\op\AppData\Roaming\herdr\herdr.sock"#)
    #expect(resolve("work", ["APPDATA": appData + #"\"#]) == #"C:\Users\op\AppData\Roaming\herdr\sessions\work\herdr.sock"#)
    #expect(resolve(nil, ["USERPROFILE": #"C:\Users\op"#]) == #"C:\Users\op\AppData\Roaming\herdr\herdr.sock"#)
    #expect(resolve(nil, ["XDG_CONFIG_HOME": #"D:\cfg"#, "APPDATA": appData]) == #"D:\cfg\herdr\herdr.sock"#)
    #expect(resolve("work", ["HERDR_SOCKET_PATH": #"E:\s.sock"#]) == #"E:\s.sock"#)
}
