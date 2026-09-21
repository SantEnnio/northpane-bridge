import Foundation
import NorthpaneProtocol
import Testing
@testable import NorthpaneBridgeResources

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// What the CLI printed on a real plan, with the account of what the user had been doing that
/// follows the meters in the same text.
private let claudeProse = """
You are currently using your subscription to power your Claude Code usage

Current session: 55% used · resets Sep 20 at 10am (UTC)
Current week (all models): 49% used · resets Sep 25 at 4:30pm (UTC)
Current week (Fable): 86% used · resets Sep 25 at 4:30pm (UTC)

What's contributing to your limits usage?
Last 24h · 1541 requests · 10 sessions
  84% of your usage was at >150k context
  Top plugins: some-plugin 10%
"""

@Test func claudeProseBecomesTheMetersOfThePlanAndNothingElse() throws {
    let meters = try ClaudeUsageProse.meters(in: claudeProse, now: utc(2026, 9, 20, 9))
    #expect(meters == [
        .init(scopeID: "subscription", scopeLabel: "All models", kind: .shortWindow, usedPercent: 55, resetsAt: utc(2026, 9, 20, 10), inForce: true),
        .init(scopeID: "subscription", scopeLabel: "All models", kind: .longWindow, usedPercent: 49, resetsAt: utc(2026, 9, 25, 16, 30), inForce: true),
        .init(scopeID: "model:fable", scopeLabel: "Fable", kind: .longWindow, usedPercent: 86, resetsAt: utc(2026, 9, 25, 16, 30)),
    ])
}

@Test func aResetAcrossNewYearTakesTheNearestYear() throws {
    let prose = "Current session: 3% used · resets Jan 1 at 12am (UTC)\nCurrent week (all models): 9% used · resets Jan 2, 1:50pm (UTC)"
    let meters = try ClaudeUsageProse.meters(in: prose, now: utc(2026, 12, 31, 22))
    #expect(meters.map(\.resetsAt) == [utc(2027, 1, 1), utc(2027, 1, 2, 13, 50)])
}

@Test func anUntouchedWindowHasNoResetAndIsStillAReading() throws {
    let meters = try ClaudeUsageProse.meters(in: "Current session: 0% used\nCurrent week (all models): 12% used · resets Sep 25 at 4pm (UTC)", now: utc(2026, 9, 20))
    #expect(meters[0].usedPercent == 0)
    #expect(meters[0].resetsAt == nil)
}

@Test(arguments: [
    // A required meter is missing: a plan that looks whole with a meter short is the lie to avoid.
    "Current session: 55% used · resets Sep 20 at 10am (UTC)",
    // Another zone means the invocation is not the one the reader believes.
    "Current session: 5% used · resets Sep 20 at 10am (Europe/Rome)\nCurrent week (all models): 4% used",
    // A time with no am or pm is one o'clock or thirteen.
    "Current session: 5% used · resets Sep 20 at 1:50 (UTC)\nCurrent week (all models): 4% used",
    "Current session: 5% used · resets Feb 30 at 1pm (UTC)\nCurrent week (all models): 4% used",
    "Current session: 140% used\nCurrent week (all models): 4% used",
    "Current session: most of it used\nCurrent week (all models): 4% used",
    "Current session: 5% used\nCurrent session: 6% used\nCurrent week (all models): 4% used",
])
func proseThatCannotBeReadToTheEndFailsTheWholeReading(prose: String) {
    #expect(throws: AgentUsageFailure.unreadable) { try ClaudeUsageProse.meters(in: prose, now: utc(2026, 9, 20)) }
}

/// A real answer of `account/rateLimits/read` on a plan that has only a weekly limit, which
/// the CLI sends in `primary`. The account id is not the real one.
private let codexAnswer = """
{"rateLimits":{"limitId":"codex","primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1789974119},"secondary":null},
 "rateLimitsByLimitId":{
  "codex":{"limitId":"codex","limitName":null,
   "primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1789974119},"secondary":null,
   "individualLimit":{"limit":"1000","used":"612.4081953287125","remainingPercent":30,"resetsAt":1790812801},
   "planType":"self_serve_business"},
  "other":{"limitId":"other","limitName":"Something new",
   "primary":{"usedPercent":12.4,"windowDurationMins":null,"resetsAt":null},
   "secondary":{"usedPercent":40,"resetsAt":1789974119}}},
 "accountId":"00000000-0000-0000-0000-000000000000"}
"""

@Test func codexRateLimitsBecomeMetersWhateverScopesArrive() throws {
    let meters = try CodexRateLimits.meters(in: JSONSerialization.jsonObject(with: Data(codexAnswer.utf8)))
    let reset = Date(timeIntervalSince1970: 1_789_974_119)
    #expect(meters == [
        // A week, whatever field it came in.
        .init(scopeID: "codex", scopeLabel: "Codex and Work", kind: .longWindow, usedPercent: 100, resetsAt: reset, windowMinutes: 10_080, inForce: true),
        .init(scopeID: "codex", scopeLabel: "Codex and Work", kind: .credits, usedPercent: 70, used: "612.4081953287125", limit: "1000",
              resetsAt: Date(timeIntervalSince1970: 1_790_812_801), inForce: true),
        // A scope nobody has seen before is read like the others; with no duration the field decides.
        .init(scopeID: "other", scopeLabel: "Something new", kind: .shortWindow, usedPercent: 12),
        .init(scopeID: "other", scopeLabel: "Something new", kind: .longWindow, usedPercent: 40, resetsAt: reset),
    ])
    #expect(throws: AgentUsageFailure.unreadable) { try CodexRateLimits.meters(in: ["unexpected": true]) }
}

/// On macOS a JSON 0 answers `is Bool`, so a week nothing was spent on in yet must still be read,
/// and a true where a percentage belongs must not.
@Test func anUntouchedWeekBesideTheCreditsIsStillAMeter() throws {
    let answer = #"{"rateLimits":{"limitId":"codex"},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1790593798},"secondary":{"usedPercent":true},"individualLimit":{"limit":"1000","used":"699.7","remainingPercent":30,"resetsAt":1790812800}}}}"#
    let meters = try CodexRateLimits.meters(in: JSONSerialization.jsonObject(with: Data(answer.utf8)))
    #expect(meters.map(\.kind) == [.longWindow, .credits])
    #expect(meters.map(\.usedPercent) == [0, 70])
}

@Test func theCodexSessionSaysWhyThereIsNothingToRead() {
    #expect(CodexRateLimits.sessionFailure(in: ["account": NSNull()]) == .signedOut)
    #expect(CodexRateLimits.sessionFailure(in: ["account": ["type": "apiKey"]]) == .noPlan)
    #expect(CodexRateLimits.sessionFailure(in: ["account": ["type": "chatgpt", "planType": "plus"]]) == nil)
}

#if !os(Windows)
private func fakeCLI(_ script: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "np-fake-cli-\(UUID().uuidString).sh")
    try Data(("#!/bin/sh\n" + script).utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private let claudeEnvelope = #"{"is_error":false,"subtype":"success","result":"Current session: 7% used · resets Sep 20 at 10am ($TZ)\nCurrent week (all models): 49% used"}"#

@Test func claudeIsInvokedQuietlyInUTCAndAnOlderCLIStillReads() throws {
    let current = try fakeCLI("case \"$*\" in *--no-session-persistence*--strict-mcp-config*) printf '%s\\n' '\(claudeEnvelope)' | sed \"s/\\$TZ/$TZ/\";; *) exit 1;; esac")
    // An older CLI refuses the flags it does not know, as commander does: exit 1, nothing printed.
    let older = try fakeCLI("case \"$*\" in *--no-session*) echo \"error: unknown option\" >&2; exit 1;; *) printf '%s\\n' '\(claudeEnvelope)' | sed \"s/\\$TZ/$TZ/\";; esac")
    defer { try? FileManager.default.removeItem(at: current); try? FileManager.default.removeItem(at: older) }
    for cli in [current, older] {
        let meters = try ClaudeUsageSurface(executable: cli).read(now: utc(2026, 9, 20))
        #expect(meters.map(\.usedPercent) == [7, 49])
        #expect(meters[0].resetsAt == utc(2026, 9, 20, 10))
    }
}

@Test(arguments: [
    (#"{"loggedIn":false}"#, AgentUsageFailure.signedOut),
    (#"{"loggedIn":true,"authMethod":"apiKey","apiProvider":"firstParty"}"#, .noPlan),
    (#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}"#, .unreachable),
    ("not json", .unreachable),
])
func aClaudeFailureIsNamedByTheSessionAndNeverGuessed(status: String, expected: AgentUsageFailure) throws {
    let cli = try fakeCLI("case \"$1\" in auth) echo '\(status)';; *) echo '{\"is_error\":true}';; esac")
    defer { try? FileManager.default.removeItem(at: cli) }
    #expect(throws: expected) { try ClaudeUsageSurface(executable: cli).read(now: Date()) }
}

@Test func codexIsGreetedAskedAndDismissed() throws {
    let cli = try fakeCLI("""
    [ "$1" = app-server ] || exit 2
    read greeting; echo '{"method":"noise/of/its/own"}'; echo '{"id":1,"result":{"userAgent":"fake"}}'
    read ready; read question
    echo '{"id":2,"result":{"rateLimits":{"limitId":"codex"},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":41,"windowDurationMins":300,"resetsAt":1789974119}}}}}'
    read goodbye
    """)
    defer { try? FileManager.default.removeItem(at: cli) }
    let meters = try CodexUsageSurface(executable: cli, timeout: 5).read(now: Date())
    #expect(meters == [.init(scopeID: "codex", scopeLabel: "Codex and Work", kind: .shortWindow, usedPercent: 41,
                             resetsAt: Date(timeIntervalSince1970: 1_789_974_119), windowMinutes: 300, inForce: true)])
}

@Test func aRefusedCodexReadingAsksTheSessionWhy() throws {
    let cli = try fakeCLI("""
    read greeting; echo '{"id":1,"result":{}}'; read ready; read question
    echo '{"id":2,"error":{"code":-32000,"message":"not logged in"}}'
    read probe; echo '{"id":3,"result":{"account":null}}'; read goodbye
    """)
    let silent = try fakeCLI("sleep 30")
    defer { try? FileManager.default.removeItem(at: cli); try? FileManager.default.removeItem(at: silent) }
    #expect(throws: AgentUsageFailure.signedOut) { try CodexUsageSurface(executable: cli, timeout: 5).read(now: Date()) }
    // A CLI that never answers is stopped at the deadline instead of holding the Reading.
    let started = Date()
    #expect(throws: AgentUsageFailure.unreachable) { try CodexUsageSurface(executable: silent, timeout: 1).read(now: Date()) }
    #expect(Date().timeIntervalSince(started) < 10)
}
#endif

private final class FakeSurface: AgentUsageSurface, @unchecked Sendable {
    let providerID: String
    let label: String
    private let lock = NSLock()
    private var outcomes: [Result<Int, AgentUsageFailure>]
    private(set) var reads = 0
    init(_ providerID: String, _ outcomes: [Result<Int, AgentUsageFailure>]) { self.providerID = providerID; label = providerID.capitalized; self.outcomes = outcomes }
    func read(now: Date) throws -> [AgentUsageMeter] {
        let outcome = lock.withLock { reads += 1; return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0] }
        return [.init(scopeID: "plan", scopeLabel: "Plan", kind: .longWindow, usedPercent: try outcome.get())]
    }
    var readCount: Int { lock.withLock { reads } }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant += seconds } }
}

private func settled(_ monitor: AgentUsageMonitor) async throws -> [AgentUsage] {
    for _ in 0..<500 {
        let answer = await monitor.current()
        if !answer.refreshing { return answer.usage }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("the monitor never settled")
    return []
}

@Test func theMonitorAnswersAtOnceAndReadsAgainOnlyWhenAReadingHasAged() async throws {
    let clock = FakeClock()
    let steady = FakeSurface("steady", [.success(10), .success(20)])
    let flaky = FakeSurface("flaky", [.success(30), .failure(.unreachable), .failure(.signedOut), .success(60)])
    let monitor = AgentUsageMonitor(discover: { [steady, flaky] }, now: { clock.now })

    // Nothing is held yet and nobody is made to wait for a CLI.
    let first = await monitor.current()
    #expect(first == .init(usage: [], refreshing: true))
    var usage = try await settled(monitor)
    #expect(usage.map(\.state) == [.measured, .measured])
    #expect(usage.map { $0.meters[0].usedPercent } == [10, 30])
    let firstReading = clock.now

    clock.advance(AgentUsageMonitor.freshness - 1)
    usage = try await settled(monitor)
    #expect(steady.readCount == 1 && flaky.readCount == 1)

    // Aged: both are read again. The one that fails keeps its numbers and their age.
    clock.advance(1)
    usage = try await settled(monitor)
    #expect(steady.readCount == 2 && flaky.readCount == 2)
    #expect(usage[0].meters[0].usedPercent == 20)
    #expect(usage[1] == .init(providerID: "flaky", label: "Flaky", state: .unreachable, readAt: firstReading,
                              meters: [.init(scopeID: "plan", scopeLabel: "Plan", kind: .longWindow, usedPercent: 30)]))

    // What may pass is tried again sooner, alone; what waits for a person is not.
    clock.advance(AgentUsageMonitor.retryAfterFailure)
    usage = try await settled(monitor)
    #expect(steady.readCount == 2 && flaky.readCount == 3)
    #expect(usage[1].state == .signedOut)
    clock.advance(AgentUsageMonitor.retryAfterFailure)
    _ = try await settled(monitor)
    #expect(flaky.readCount == 3)
}

@Test func anAgentThatIsNotInstalledDoesNotAppear() async throws {
    let installed = FakeClock()
    let surface = FakeSurface("claude", [.success(5)])
    let monitor = AgentUsageMonitor(discover: { installed.now.timeIntervalSince1970 > 1_790_000_000 ? [] : [surface] }, now: { installed.now })
    #expect(try await settled(monitor).map(\.providerID) == ["claude"])
    installed.advance(AgentUsageMonitor.freshness)
    #expect(try await settled(monitor).isEmpty)
}

/// Against the agent CLIs really installed and signed in on this machine: set
/// `NORTHPANE_LIVE_AGENT_USAGE` to the ids to read, e.g. `claude,codex`. It costs no tokens.
@Test func theRealCLIsStillSpeakTheFormsTheseReadersKnow() throws {
    guard let wanted = ProcessInfo.processInfo.environment["NORTHPANE_LIVE_AGENT_USAGE"] else { return }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for id in wanted.split(separator: ",") {
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NORTHPANE_LIVE_\(id.uppercased())"] ?? "\(home)/.local/bin/\(id)")
        let surface: any AgentUsageSurface = id == "claude" ? ClaudeUsageSurface(executable: executable) : CodexUsageSurface(executable: executable)
        let started = Date()
        let meters = try surface.read(now: Date())
        print("live \(id) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s:", meters.map { "\($0.scopeLabel) \($0.kind) \($0.usedPercent)% resets \($0.resetsAt.map(String.init(describing:)) ?? "-")" })
        #expect(!meters.isEmpty)
    }
}

/// What `agy` answered on a real plan, with one group nothing had been spent on.
private let antigravityAnswer = """
{"status":"SUCCESS","response":"","command":{"name":"usage","data":{"description":"Quota status","groups":[
 {"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[
  {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.9891999959945679,"reset_time":"2026-08-26T14:45:53Z"}]},
 {"name":"Claude and GPT models","buckets":[
  {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-08-26T15:23:08Z"}]}]}}}
"""

@Test func antigravityGroupsAreScopesAndWhatItCallsBucketsAreTheirMeters() throws {
    let meters = try AntigravityQuota.meters(in: Data(antigravityAnswer.utf8))
    #expect(meters == [
        .init(scopeID: "gemini", scopeLabel: "Gemini Models", kind: .longWindow, usedPercent: 1, resetsAt: Date(timeIntervalSince1970: 1_787_755_553), windowMinutes: 10_080),
        // Nothing spent: the reset the server sends slides with the clock, so it is not kept.
        .init(scopeID: "3p", scopeLabel: "Claude and GPT models", kind: .longWindow, usedPercent: 0, windowMinutes: 10_080),
    ])
}

@Test func anAntigravityAnswerThatChangedFailsWholeAndAnErrorMayPass() {
    for changed in [antigravityAnswer.replacingOccurrences(of: #""name":"usage""#, with: #""name":"quota""#),
                    antigravityAnswer.replacingOccurrences(of: #""window":"weekly""#, with: #""window":"daily""#),
                    antigravityAnswer.replacingOccurrences(of: "0.9891999959945679", with: "1.4"),
                    antigravityAnswer.replacingOccurrences(of: "3p-weekly", with: "gemini-weekly"),
                    "not json"] {
        #expect(throws: AgentUsageFailure.unreadable) { try AntigravityQuota.meters(in: Data(changed.utf8)) }
    }
    #expect(throws: AgentUsageFailure.unreachable) { try AntigravityQuota.meters(in: Data(#"{"status":"ERROR","response":"auth or network"}"#.utf8)) }
}

#if !os(Windows)
@Test func agyIsFoundByLookingAtFilesAndRunOnlyWhenRead() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "np-agy-\(UUID().uuidString)", directoryHint: .isDirectory)
    let bin = home.appending(path: ".local/bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(AntigravityUsageSurface.find(environment: ["PATH": bin.path], homeDirectory: home.path) == nil)

    // Every run leaves a mark, so that finding it can be seen to run nothing.
    let agy = bin.appending(path: "agy"), mark = home.appending(path: "ran")
    try Data("#!/bin/sh\necho \"$*\" >> '\(mark.path)'\ncat <<'JSON'\n\(antigravityAnswer)\nJSON\n".utf8).write(to: agy)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)
    let found = try #require(AntigravityUsageSurface.find(environment: ["PATH": "/nowhere"], homeDirectory: home.path))
    #expect(found.path == agy.path)
    #expect(!FileManager.default.fileExists(atPath: mark.path))

    let surface = AntigravityUsageSurface(executable: found)
    #expect(surface.needsConsent)
    #expect(surface.notice?.url == "https://antigravity.google/terms")
    #expect(try surface.read(now: Date()).count == 2)
    // One invocation for a Reading, and exactly the one that runs no model.
    #expect(try String(contentsOf: mark, encoding: .utf8) == "-p /usage --output-format json\n")
}
#endif

private final class ConsentSurface: AgentUsageSurface, @unchecked Sendable {
    let providerID = "guarded", label = "Guarded", needsConsent = true
    let notice: AgentUsageNotice? = .init(text: "A risk.", url: "https://example.com/terms")
    private let lock = NSLock()
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }
    func read(now: Date) throws -> [AgentUsageMeter] {
        lock.withLock { reads += 1 }
        return [.init(scopeID: "plan", scopeLabel: "Plan", kind: .longWindow, usedPercent: 42)]
    }
}

@Test func anAgentThatNeedsConsentIsNeverRunBeforeItAndTheHostRemembersTheChoice() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "np-consent-\(UUID().uuidString)/consent.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let surface = ConsentSurface()
    let monitor = AgentUsageMonitor(discover: { [surface] }, consentFile: file)

    var usage = try await settled(monitor)
    #expect(usage == [.init(providerID: "guarded", label: "Guarded", state: .needsConsent, notice: "A risk.", noticeURL: "https://example.com/terms")])
    #expect(surface.readCount == 0)

    _ = try await monitor.setConsent(true, providerID: "guarded")
    usage = try await settled(monitor)
    #expect(usage[0].state == .measured)
    #expect(usage[0].consentGiven)
    #expect(usage[0].meters[0].usedPercent == 42)
    #expect(surface.readCount == 1)

    // Another Bridge process on the same Host starts from the choice already made.
    let restarted = AgentUsageMonitor(discover: { [surface] }, consentFile: file)
    #expect(try await settled(restarted)[0].state == .measured)

    // Withdrawn: what was held goes, and the CLI is left alone again.
    let withdrawn = try await restarted.setConsent(false, providerID: "guarded")
    #expect(withdrawn.usage[0].state == .needsConsent)
    #expect(withdrawn.usage[0].meters.isEmpty)
    #expect(!withdrawn.usage[0].consentGiven)
    let reads = surface.readCount
    #expect(try await settled(AgentUsageMonitor(discover: { [surface] }, consentFile: file))[0].state == .needsConsent)
    #expect(surface.readCount == reads)
}

@Test func theBridgeProcessesOfOneHostShareWhatWasRead() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "np-readings-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: folder) }
    let clock = FakeClock()
    let surface = FakeSurface("claude", [.success(33), .success(44)])
    func bridgeProcess() -> AgentUsageMonitor {
        AgentUsageMonitor(discover: { [surface] }, readingsFile: folder.appending(path: "readings.json"), now: { clock.now })
    }
    #expect(try await settled(bridgeProcess())[0].meters[0].usedPercent == 33)

    // A client that reconnects gets a new Bridge process: the numbers are there at once and no
    // CLI is run for it.
    clock.advance(60)
    let reconnected = await bridgeProcess().current()
    #expect(!reconnected.refreshing)
    #expect(reconnected.usage[0].meters[0].usedPercent == 33)
    #expect(surface.readCount == 1)

    // Aged: whichever process is asked first reads, and the other finds what it read.
    clock.advance(AgentUsageMonitor.freshness)
    let first = bridgeProcess(), second = bridgeProcess()
    #expect(try await settled(first)[0].meters[0].usedPercent == 44)
    #expect(await second.current() == .init(usage: try await settled(first), refreshing: false))
    #expect(surface.readCount == 2)
}
