import Foundation
import Testing
@testable import NorthpaneBridgeCore
@testable import NorthpaneProjection
@testable import NorthpaneProtocol

@Test func terminalLeaseIsExclusiveAndInputIsDeliveredOnce() throws {
    let host = HostID()
    let proof = ObservationProof(hostID: host, incarnationID: HerdrSessionIncarnationID(), snapshotID: "s", nextEventSequence: 1)
    var terminal = TerminalCoordinator()
    terminal.registerCurrent(proof)
    let first = try terminal.attach(connectionID: ConnectionID(), paneID: "p", deviceID: ClientDeviceID(), proof: proof)
    let second = try terminal.attach(connectionID: ConnectionID(), paneID: "p", deviceID: ClientDeviceID(), proof: proof)
    try terminal.acquire(first.id, proof: proof)
    #expect(throws: TerminalError.leaseOwnedElsewhere) { try terminal.acquire(second.id, proof: proof) }

    let frame = TerminalInputFrame(attachmentID: first.id.rawValue, sequence: 0, bytes: Data("help\n".utf8))
    #expect(try terminal.acceptInput(frame, proof: proof).acceptedThroughSequence == 0)
    #expect(try terminal.acceptInput(frame, proof: proof).acceptedThroughSequence == 0)
    #expect(terminal.deliveredInput == [Data("help\n".utf8)])
}

@Test func aNewObservationInvalidatesAttachmentsAndLeases() throws {
    let host = HostID()
    let incarnation = HerdrSessionIncarnationID()
    let firstProof = ObservationProof(hostID: host, incarnationID: incarnation, snapshotID: "a", nextEventSequence: 1)
    let secondProof = ObservationProof(hostID: host, incarnationID: incarnation, snapshotID: "b", nextEventSequence: 1)
    var terminal = TerminalCoordinator()
    terminal.registerCurrent(firstProof)
    let attachment = try terminal.attach(connectionID: ConnectionID(), paneID: "p", deviceID: ClientDeviceID(), proof: firstProof)
    try terminal.acquire(attachment.id, proof: firstProof)
    terminal.registerCurrent(secondProof)
    #expect(terminal.leaseState(for: attachment.id) == .unknown)
    #expect(throws: TerminalError.staleObservation) { try terminal.acquire(attachment.id, proof: firstProof) }
}

/// The scroll that would not scroll: an OpenCode pane reported by Herdr as holding nothing above
/// its viewport. `terminal.scroll` is dropped there without a word, so the scroll has to reach the
/// pane as the wheel it asked for — and only there, because those same bytes typed at a shell are
/// rubbish on its command line.
@Test func aPaneHoldingNoHostScrollbackIsScrolledThroughItsOwnMouse() {
    // An agent drawing on the alternate screen: nothing above the viewport, ever.
    #expect(TerminalScrollRouting.choose(heldOnHost: 0, paneRunsAnAgent: true) == .paneWheel)
    // The same agent once it writes into the normal buffer (Codex, Claude Code): Herdr has it.
    #expect(TerminalScrollRouting.choose(heldOnHost: 1_025, paneRunsAnAgent: true) == .hostScrollback)
    // A shell keeps paging the Host even before it has printed enough to have scrollback.
    #expect(TerminalScrollRouting.choose(heldOnHost: 0, paneRunsAnAgent: false) == .hostScrollback)
    #expect(TerminalScrollRouting.choose(heldOnHost: 120, paneRunsAnAgent: false) == .hostScrollback)
}

/// The wheel is SGR, one event per line, aimed at the middle of the viewport, and never longer than
/// a screenful however hard the flick was.
@Test func theWheelSentToAPaneIsSGRAtTheMiddleOfItsViewport() {
    #expect(String(decoding: TerminalScrollRouting.wheel(.up, lines: 2, columns: 80, rows: 24), as: UTF8.self)
            == "\u{1b}[<64;40;12M\u{1b}[<64;40;12M")
    #expect(String(decoding: TerminalScrollRouting.wheel(.down, lines: 1, columns: 80, rows: 24), as: UTF8.self)
            == "\u{1b}[<65;40;12M")
    let flick = String(decoding: TerminalScrollRouting.wheel(.up, lines: 400, columns: 80, rows: 24), as: UTF8.self)
    #expect(flick.components(separatedBy: "\u{1b}").count - 1 == 20)
    // A degenerate viewport still names a cell that exists.
    #expect(String(decoding: TerminalScrollRouting.wheel(.up, lines: 1, columns: 0, rows: 0), as: UTF8.self)
            == "\u{1b}[<64;1;1M")
}
