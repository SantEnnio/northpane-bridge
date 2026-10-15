import Foundation
import Testing
@testable import NorthpaneHostRuntime
import NorthpaneProtocol
@testable import NorthpaneHerdrIntegration

@Test func herdrAdapterBindsEveryOperationToItsSession() async throws {
    let runner = ScopedHerdrRunner()
    let runtime: any HostRuntime = HerdrHostRuntime(runner: runner, executableURL: URL(fileURLWithPath: "/unused/herdr"),
                                                   sessionName: "scope", incarnationID: "incarnation")
    let hostID = HostID()
    let snapshot = try await runtime.currentSnapshot(hostID: hostID)
    #expect(snapshot.hostID == hostID)
    #expect(snapshot.incarnationID == "incarnation")
    #expect(try await runtime.createWorkspace(label: "Work", workingDirectory: "/work", environment: ["TEST": "value"]) == CreatedPane(workspaceID: "w1", paneID: "w1:p1"))
    #expect(try await runtime.createTab(workspaceID: "w1", workingDirectory: "/work").paneID == "w1:p2")
    #expect(try await runtime.splitPane(paneID: "w1:p1", direction: .down, workingDirectory: "/work").paneID == "w1:p3")
    try await runtime.renameWorkspace(workspaceID: "w1", label: "Renamed")
    try await runtime.startAgent(.codex, executableURL: URL(fileURLWithPath: "/bin/codex"), name: "test-agent", paneID: "w1:p1")
    try await runtime.closeWorkspace(workspaceID: "w1")
    let calls = await runner.calls
    #expect(calls.allSatisfy { Array($0.prefix(2)) == ["--session", "scope"] })
    #expect(calls.contains(["--session", "scope", "workspace", "create", "--cwd", "/work", "--label", "Work", "--env", "TEST=value", "--no-focus"]))
    #expect(calls.contains(["--session", "scope", "pane", "split", "w1:p1", "--direction", "down", "--cwd", "/work", "--no-focus"]))
    #expect(calls.contains(["--session", "scope", "agent", "rename", "w1:p1", "test-agent"]))
}

private actor ScopedHerdrRunner: HerdrCommandRunning {
    private(set) var calls: [[String]] = []
    func run(arguments: [String]) -> Data {
        calls.append(arguments)
        let command = Array(arguments.dropFirst(2))
        let response: String
        switch Array(command.prefix(2)) {
        case ["api", "snapshot"]:
            response = #"{"result":{"type":"session_snapshot","snapshot":{"workspaces":[],"tabs":[],"panes":[]}}}"#
        case ["workspace", "create"]:
            response = #"{"result":{"type":"workspace_created","workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1","workspace_id":"w1"}}}"#
        case ["tab", "create"]:
            response = #"{"result":{"type":"tab_created","root_pane":{"pane_id":"w1:p2","workspace_id":"w1"}}}"#
        case ["pane", "split"]:
            response = #"{"result":{"type":"pane_info","pane":{"pane_id":"w1:p3","workspace_id":"w1"}}}"#
        default: response = "{}"
        }
        return Data(response.utf8)
    }
}

@Test func herdrConversationUsesOnlyExactPaneNativeIDAndKeepsScope() async throws {
    let runner = ConversationHerdrRunner()
    let runtime = HerdrHostRuntime(runner: runner, executableURL: URL(fileURLWithPath: "/unused/herdr"), sessionName: "scope", incarnationID: "inc")
    #expect(try await runtime.conversationIdentity(paneID: "pane")?.sessionID == "native-id")
    await runner.setReference(agent: "claude", kind: "id")
    #expect(try await runtime.conversationIdentity(paneID: "pane")?.sessionID == nil)
    await runner.setReference(agent: "codex", kind: "path")
    #expect(try await runtime.conversationIdentity(paneID: "pane")?.sessionID == nil)
    #expect(try await runtime.conversationIdentity(paneID: "other-pane") == nil)
    #expect(await runner.calls.allSatisfy { Array($0.prefix(2)) == ["--session", "scope"] })
}

@Test func processBirthIsStableForTheLiveProcessAndRejectsUnknownPID() {
    #if os(macOS) || os(Linux)
    let pid = ProcessInfo.processInfo.processIdentifier
    #expect(ProcessBirth.proof(pid: pid) != nil)
    #expect(ProcessBirth.proof(pid: pid) == ProcessBirth.proof(pid: pid))
    #endif
    #expect(ProcessBirth.proof(pid: 0) == nil)
    #expect(ProcessBirth.proof(pid: -1) == nil)
}

private actor ConversationHerdrRunner: HerdrCommandRunning {
    private var agent = "codex", kind = "id"
    private(set) var calls: [[String]] = []
    func setReference(agent: String, kind: String) { self.agent = agent; self.kind = kind }
    func run(arguments: [String]) -> Data {
        calls.append(arguments)
        return Data("{\"result\":{\"pane\":{\"pane_id\":\"pane\",\"agent\":\"codex\",\"agent_session\":{\"source\":\"herdr:codex\",\"agent\":\"\(agent)\",\"kind\":\"\(kind)\",\"value\":\"native-id\"}}}}".utf8)
    }
}

#if os(macOS) || os(Linux)
private func claudeRecord(_ directory: URL, pid: Int32, session: String, procStart: String? = nil,
                          startedAt: Double? = nil, kind: String = "interactive") throws {
    var record: [String: Any] = ["pid": pid, "sessionId": session, "kind": kind, "cwd": "/synthetic"]
    if let procStart { record["procStart"] = procStart }
    if let startedAt { record["startedAt"] = startedAt }
    try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("\(pid).json"))
}

private func lstart(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return formatter.string(from: date)
}

@Test func claudeSessionRecordIsAcceptedOnlyForTheExactProcess() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("np-claude-records-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = ClaudeSessionRecords(directory: directory)
    let pid = ProcessInfo.processInfo.processIdentifier
    let birth = try #require(ProcessBirth.startTime(pid: pid))
    let id = UUID().uuidString.lowercased()

    try claudeRecord(directory, pid: pid, session: id, procStart: lstart(birth))
    #expect(records.sessionID(pid: pid) == id)
    // Same PID, another process' start: a reused PID never inherits the chat.
    try claudeRecord(directory, pid: pid, session: id, procStart: lstart(birth.addingTimeInterval(-3_600)))
    #expect(records.sessionID(pid: pid) == nil)
    // No start in a known form: Claude's own start time must follow the birth closely.
    try claudeRecord(directory, pid: pid, session: id, procStart: "boot:12345", startedAt: (birth.timeIntervalSince1970 + 1.3) * 1_000)
    #expect(records.sessionID(pid: pid) == id)
    try claudeRecord(directory, pid: pid, session: id, startedAt: (birth.timeIntervalSince1970 + 600) * 1_000)
    #expect(records.sessionID(pid: pid) == nil)
    try claudeRecord(directory, pid: pid, session: id)
    #expect(records.sessionID(pid: pid) == nil)
    // Other shapes and other processes.
    try claudeRecord(directory, pid: pid, session: id, procStart: lstart(birth), kind: "sdk")
    #expect(records.sessionID(pid: pid) == nil)
    try claudeRecord(directory, pid: pid, session: "not-a-uuid", procStart: lstart(birth))
    #expect(records.sessionID(pid: pid) == nil)
    try JSONSerialization.data(withJSONObject: ["pid": pid + 1, "sessionId": id, "kind": "interactive", "procStart": lstart(birth)])
        .write(to: directory.appendingPathComponent("\(pid).json"))
    #expect(records.sessionID(pid: pid) == nil)
    try Data("{\"pid\": \(pid), \"sessionId\": \"\(id)\", \"kind\": \"interactive\", \"pad\": \"\(String(repeating: "x", count: 70_000))\"}".utf8)
        .write(to: directory.appendingPathComponent("\(pid).json"))
    #expect(records.sessionID(pid: pid) == nil)
    try Data("not json".utf8).write(to: directory.appendingPathComponent("\(pid).json"))
    #expect(records.sessionID(pid: pid) == nil)
    #expect(records.sessionID(pid: 0) == nil)
    // Whitespace as `ps` pads single-digit days.
    #expect(ClaudeSessionRecords.processStart("Mon Oct  5 07:08:09 2026") != nil)
}

@Test func claudePaneFollowsTheChatItsProcessRecordsAndFallsBackToHerdr() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("np-claude-records-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pid = ProcessInfo.processInfo.processIdentifier
    let birth = try #require(ProcessBirth.startTime(pid: pid))
    let runner = ClaudePaneRunner(pid: pid)
    let runtime = HerdrHostRuntime(runner: runner, executableURL: URL(fileURLWithPath: "/unused/herdr"), sessionName: "scope",
                                   incarnationID: "inc", claudeSessions: ClaudeSessionRecords(directory: directory))
    // No record and no Herdr hook: nothing is guessed.
    #expect(try await runtime.conversationIdentity(paneID: "pane")?.sessionID == nil)
    // Herdr's hook alone.
    await runner.setHerdrReference("hook-id")
    #expect(try await runtime.conversationIdentity(paneID: "pane")?.sessionID == "hook-id")
    // The process' own record wins, and follows /clear immediately.
    let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
    try claudeRecord(directory, pid: pid, session: first, procStart: lstart(birth))
    #expect(try await runtime.conversationIdentity(paneID: "pane")?.sessionID == first)
    try claudeRecord(directory, pid: pid, session: second, procStart: lstart(birth))
    #expect(try await runtime.conversationIdentity(paneID: "pane")?.sessionID == second)
    // Another agent in the Pane never reads Claude's records: Codex keeps its own Herdr reference.
    await runner.setAgent("codex")
    #expect(try await runtime.conversationIdentity(paneID: "pane")?.sessionID == "hook-id")
    #expect(await runner.calls.allSatisfy { Array($0.prefix(2)) == ["--session", "scope"] })
}

private actor ClaudePaneRunner: HerdrCommandRunning {
    let pid: Int32
    private var agent = "claude", reference: String?
    private(set) var calls: [[String]] = []
    init(pid: Int32) { self.pid = pid }
    func setHerdrReference(_ value: String) { reference = value }
    func setAgent(_ value: String) { agent = value }
    func run(arguments: [String]) -> Data {
        calls.append(arguments)
        if arguments.contains("process-info") {
            return Data("{\"result\":{\"process_info\":{\"pane_id\":\"pane\",\"foreground_process_group_id\":\(pid),\"foreground_processes\":[{\"pid\":\(pid),\"name\":\"2.1.301\"}]}}}".utf8)
        }
        let session = reference.map { ",\"agent_session\":{\"agent\":\"\(agent)\",\"kind\":\"id\",\"value\":\"\($0)\"}" } ?? ""
        return Data("{\"result\":{\"pane\":{\"pane_id\":\"pane\",\"terminal_id\":\"term\",\"agent\":\"\(agent)\"\(session)}}}".utf8)
    }
}
#endif
