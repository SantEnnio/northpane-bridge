import Foundation
import SwiftTerm
import Testing
@testable import NorthpaneNativeRuntime

struct Cell: Equatable {
    let text: String
    let width: Int8
    let attribute: Attribute
}

func cells(_ terminal: Terminal) -> [Cell] {
    (0..<terminal.rows).flatMap { row in
        (0..<terminal.cols).map { column in
            let cell = terminal.getCharData(col: column, row: row)!
            let character = terminal.getCharacter(for: cell)
            return Cell(text: character == "\0" ? " " : String(character), width: cell.width, attribute: cell.attribute)
        }
    }
}

private func roundTrip(_ input: String, columns: Int = 40, rows: Int = 10) -> (TerminalViewport, TerminalViewport) {
    let source = TerminalViewport(columns: columns, rows: rows)
    source.feed(Data(input.utf8))
    let replay = TerminalViewport(columns: columns, rows: rows)
    replay.feed(source.replayViewport())
    return (source, replay)
}

@Suite(.serialized) struct TerminalViewportTests {
@Test(arguments: [
    "shell$ printf hello\r\nhello\r\nshell$ ",
    "\u{1b}[38;2;10;20;30mtruecolor\u{1b}[48;5;123m background\u{1b}[0m\r\nplain",
    "\u{1b}[1;2;3;5;7;8;9mstyles\u{1b}[0m\u{1b}[4:3;58;2;12;34;56munderline",
    "caffè e\u{301} 漢字 👩‍💻 🇮🇹\r\nnext",
    "\u{1b}[?1049h\u{1b}[2J\u{1b}[2;4Heditor\u{1b}[8;1Hstatus\u{1b}[4;8H",
    "\u{1b}[3;8r\u{1b}[?6h\u{1b}[2;5Hmargin",
]) func visibleCellsAttributesAndCursorRoundTrip(input: String) {
    let (source, replay) = roundTrip(input)
    #expect(cells(source.terminal) == cells(replay.terminal))
    #expect(source.terminal.buffer.x == replay.terminal.buffer.x)
    #expect(source.terminal.buffer.y == replay.terminal.buffer.y)
    #expect(source.terminal.currentAttribute == replay.terminal.currentAttribute)
    #expect(source.terminal.buffer.scrollTop == replay.terminal.buffer.scrollTop)
    #expect(source.terminal.buffer.scrollBottom == replay.terminal.buffer.scrollBottom)
    #expect(source.terminal.isCurrentBufferAlternate == replay.terminal.isCurrentBufferAlternate)
}

@Test func modesAndTitlesSurviveFragmentedSequences() {
    let source = TerminalViewport(columns: 40, rows: 10)
    let data = Data("\u{1b}[?1;1003;1006;2004h\u{1b}=\u{1b}[?25l\u{1b}[5 q\u{1b}]2;build title\u{1b}\\\u{1b}]1;icon\u{7}".utf8)
    for byte in data { source.feed(Data([byte])) }
    let replay = TerminalViewport(columns: 40, rows: 10)
    replay.feed(source.replayViewport())
    #expect(replay.terminal.applicationCursor)
    #expect(replay.terminal.bracketedPasteMode)
    #expect(replay.applicationKeypad)
    #expect(!replay.cursorVisible)
    #expect(replay.cursorStyle == 5)
    #expect(replay.privateModes[1003] == true)
    #expect(replay.privateModes[1006] == true)
    #expect(replay.title == "build title")
    #expect(replay.iconTitle == "icon")
    source.feed(Data("\u{1b}]2;do not parse \u{1b}[?2004l\u{7}".utf8))
    #expect(source.privateModes[2004] == true)
}

@Test func alternateBufferExitRestoresNormalScreen() {
    let (source, replay) = roundTrip("shell history\r\nprompt$ \u{1b}[?1049hfull screen")
    #expect(cells(source.terminal) == cells(replay.terminal))
    source.feed(Data("\u{1b}[?1049l".utf8))
    replay.feed(Data("\u{1b}[?1049l".utf8))
    #expect(cells(source.terminal) == cells(replay.terminal))
    #expect(source.terminal.buffer.x == replay.terminal.buffer.x)
    #expect(source.terminal.buffer.y == replay.terminal.buffer.y)
}

@Test func replayRestoresPendingWrap() {
    let (source, replay) = roundTrip("12345678", columns: 8, rows: 3)
    #expect(cells(source.terminal) == cells(replay.terminal))
    #expect(source.terminal.buffer.x == 8)
    #expect(replay.terminal.buffer.x == 8)
    source.feed(Data("X".utf8))
    replay.feed(Data("X".utf8))
    #expect(cells(source.terminal) == cells(replay.terminal))
}

@Test func replayRestoresParserContinuation() {
    let (source, replay) = roundTrip("text\u{1b}[38;2;10;")
    source.feed(Data("20;30mX".utf8))
    replay.feed(Data("20;30mX".utf8))
    #expect(cells(source.terminal) == cells(replay.terminal))
}

@Test func replayRestoresSplitUnicodeAndOSCTitle() {
    let source = TerminalViewport(columns: 40, rows: 10)
    let unicode = Array("漢".utf8)
    source.feed(Data(unicode.prefix(2)))
    let replay = TerminalViewport(columns: 40, rows: 10)
    replay.feed(source.replayViewport())
    source.feed(Data(unicode.suffix(1))); replay.feed(Data(unicode.suffix(1)))
    #expect(cells(source.terminal) == cells(replay.terminal))
    source.feed(Data("\u{1b}]2;unfinished".utf8))
    let second = TerminalViewport(columns: 40, rows: 10)
    second.feed(source.replayViewport())
    source.feed(Data(" title\u{7}".utf8)); second.feed(Data(" title\u{7}".utf8))
    #expect(source.title == second.title)
}

@Test func replayDoesNotTransferScrollback() {
    let (source, replay) = roundTrip((0..<40).map { "line\($0)\r\n" }.joined(), columns: 20, rows: 4)
    #expect(cells(source.terminal) == cells(replay.terminal))
    #expect(source.terminal.getBufferAsData().count > replay.terminal.getBufferAsData().count)
}

@Test func replayDoesNotYetPreserveSoftWrapReflow() {
    let (source, replay) = roundTrip("0123456789ABCDEF\u{1b}[4;1H", columns: 8, rows: 4)
    #expect(cells(source.terminal) == cells(replay.terminal))
    source.terminal.resize(cols: 16, rows: 4)
    replay.terminal.resize(cols: 16, rows: 4)
    #expect(cells(source.terminal) != cells(replay.terminal))
}

@Test func mouseTrackingUsesFinalSelectionInsteadOfHistoricalOrder() {
    let (source, replay) = roundTrip("\u{1b}[?1003h\u{1b}[?1002l\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?1005l")
    #expect(source.terminal.mouseMode == replay.terminal.mouseMode)
    #expect(source.terminal.mouseMode == .vt200)
    #expect(replay.privateModes[1006] != true)
}

@Test func replayCanPreserveAClosedHyperlinkTarget() {
    let (source, replay) = roundTrip("\u{1b}]8;id=sample;https://example.org/docs\u{1b}\\documentation\u{1b}]8;;\u{1b}\\")
    let location = Terminal.LinkLookupLocation.screen(Position(col: 2, row: 0))
    #expect(source.terminal.link(at: location, mode: .explicitOnly) == "https://example.org/docs")
    #expect(source.terminal.link(at: location, mode: .explicitOnly) == replay.terminal.link(at: location, mode: .explicitOnly))
}

@Test func ordinaryOutputContinuesFromReplayedViewport() {
    let (source, replay) = roundTrip("\u{1b}[32mhello\r\nworld\u{1b}[2;3H")
    let tail = Data("XX\u{1b}[0m\r\nnext".utf8)
    source.feed(tail); replay.feed(tail)
    #expect(cells(source.terminal) == cells(replay.terminal))
    #expect(source.terminal.buffer.x == replay.terminal.buffer.x)
    #expect(source.terminal.buffer.y == replay.terminal.buffer.y)
}

@Test(arguments: ["shell", "vim", "less"])
func recordedCorpusReplaysAndExits(name: String) throws {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "ansi", subdirectory: "Fixtures/Terminal"))
    let exitURL = try #require(Bundle.module.url(forResource: name + "-exit", withExtension: "ansi", subdirectory: "Fixtures/Terminal"))
    let recording = try Data(contentsOf: url)
    let tail = try Data(contentsOf: exitURL)
    let source = TerminalViewport(columns: 80, rows: 24)
    source.feed(recording)
    let replay = TerminalViewport(columns: 80, rows: 24)
    replay.feed(source.replayViewport())
    #expect(cells(source.terminal) == cells(replay.terminal))
    #expect(source.terminal.buffer.x == replay.terminal.buffer.x)
    #expect(source.terminal.buffer.y == replay.terminal.buffer.y)
    #expect(source.terminal.mouseMode == replay.terminal.mouseMode)
    #expect(source.applicationKeypad == replay.applicationKeypad)
    #expect(source.terminal.bracketedPasteMode == replay.terminal.bracketedPasteMode)
    source.feed(tail); replay.feed(tail)
    #expect(cells(source.terminal) == cells(replay.terminal))
    #expect(source.terminal.buffer.x == replay.terminal.buffer.x)
    #expect(source.terminal.buffer.y == replay.terminal.buffer.y)
}
}
