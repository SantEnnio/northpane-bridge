import Foundation
import NorthpaneProtocol
import Testing
@testable import NorthpaneHerdrIntegration

@Test func thePaneIDIsReadFromAnEnvironmentBlock() {
    let block = Array("PATH=/bin\u{0}HERDR_PANE_ID=w3:p4\u{0}HERDR_TAB_ID=w3:t1\u{0}".utf8)
    #expect(PaneActivityProbe.paneID(inEnvironment: block) == "w3:p4")
    #expect(PaneActivityProbe.paneID(inEnvironment: Array("PATH=/bin\u{0}HERDR_PANE_ID=\u{0}".utf8)) == nil)
}

@Test func theHerdrServerHoldingMostOfTheAskedPanesAnswers() {
    // A second server (another Herdr session) reuses the same Pane IDs.
    let processes: [PaneActivityProbe.PaneProcess] = [
        .init(parentID: 10, paneID: "w1:p1", terminalPath: "/dev/ttys001"),
        .init(parentID: 10, paneID: "w1:p2", terminalPath: "/dev/ttys002"),
        .init(parentID: 20, paneID: "w1:p1", terminalPath: "/dev/ttys009"),
    ]
    #expect(PaneActivityProbe.terminals(for: ["w1:p1", "w1:p2"], among: processes) == ["w1:p1": "/dev/ttys001", "w1:p2": "/dev/ttys002"])
    #expect(PaneActivityProbe.terminals(for: ["w9:p1"], among: processes).isEmpty)
}

@Test func terminalsAreStampedAtEveryCallAndTheTableIsReadAgainOnlyWhenNeeded() {
    final class Counter: @unchecked Sendable { var scans = 0; var stamp = Date(timeIntervalSince1970: 100) }
    let counter = Counter()
    let probe = PaneActivityProbe(rescanInterval: 30, scan: {
        counter.scans += 1
        return [.init(parentID: 1, paneID: "w1:p1", terminalPath: "/dev/ttys001")]
    }, stamp: { _ in counter.stamp })
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(probe.lastActivity(paneIDs: ["w1:p1"], now: start) == ["w1:p1": Date(timeIntervalSince1970: 100)])
    counter.stamp = Date(timeIntervalSince1970: 200)
    #expect(probe.lastActivity(paneIDs: ["w1:p1"], now: start.addingTimeInterval(10)) == ["w1:p1": Date(timeIntervalSince1970: 200)])
    #expect(counter.scans == 1)
    // A Pane the table does not hold is looked for again, but not at every call.
    _ = probe.lastActivity(paneIDs: ["w1:p1", "w1:p2"], now: start.addingTimeInterval(12))
    _ = probe.lastActivity(paneIDs: ["w1:p1", "w1:p2"], now: start.addingTimeInterval(13))
    #expect(counter.scans == 2)
    _ = probe.lastActivity(paneIDs: ["w1:p1"], now: start.addingTimeInterval(45))
    #expect(counter.scans == 3)
}

#if os(macOS) || os(Linux)
/// Against this machine's own process table: whatever Herdr runs here, the scan must not fail and
/// every terminal it names must be a device that can be stamped.
@Test func theLiveProcessTableYieldsStampableTerminals() {
    for process in PaneActivityProbe.paneProcesses() {
        #expect(process.terminalPath.hasPrefix("/dev/"))
        #expect(PaneActivityProbe.lastUse(ofTerminal: process.terminalPath) != nil)
    }
}
#endif

@Test func theRuntimeAddsTheActivityItIsGiven() async throws {
    struct Fixed: PaneActivityReading {
        func lastActivity(paneIDs: [String], now: Date) -> [String: Date] { ["p1": Date(timeIntervalSince1970: 42)] }
    }
    let snapshot = Data(#"{"result":{"type":"session_snapshot","snapshot":{"workspaces":[],"tabs":[],"panes":[{"pane_id":"p1","workspace_id":"w1","tab_id":"t1","focused":false,"agent_status":"idle","revision":1},{"pane_id":"p2","workspace_id":"w1","tab_id":"t1","focused":false,"agent_status":"idle","revision":1}]}}}"#.utf8)
    actor Runner: HerdrCommandRunning {
        let data: Data
        init(_ data: Data) { self.data = data }
        func run(arguments: [String]) throws -> Data { data }
    }
    let runtime = HerdrRuntime(runner: Runner(snapshot), incarnationID: "inc", activity: Fixed())
    let result = try await runtime.currentSnapshot(hostID: HostID())
    #expect(result.panes.first { $0.id == "p1" }?.lastActivityAt == Date(timeIntervalSince1970: 42))
    #expect(result.panes.first { $0.id == "p2" }?.lastActivityAt == nil)
}
