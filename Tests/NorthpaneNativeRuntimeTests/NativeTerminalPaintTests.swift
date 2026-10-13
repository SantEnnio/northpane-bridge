import Foundation
@testable import SwiftTerm
import Testing
@testable import NorthpaneNativeRuntime

@Suite struct NativeTerminalPaintTests {
    @Test func repeatedPaintPreservesSelectionAndClearsStaleWrapAndInputModes() {
        let host = NativeTerminalEngine(columns: 8, rows: 5)
        let client = NativeTerminalEngine(columns: 8, rows: 5)
        host.feed(Data("selected\r\nabcdefghijk\u{1b}[?1003;2004h\u{1b}[>3u".utf8))
        client.feed(host.paintFrame())
        let selection = SelectionService(terminal: client.terminal)
        selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 8, row: 0))
        selection.active = true
        let captured = selection.captureSelectedContent()!
        let selectedText = selection.getSelectedText()
        host.feed(Data("\u{1b}[2;1H\u{1b}[Jshort\u{1b}[?1003;2004l\u{1b}[=0u".utf8))
        client.feed(host.paintFrame(previousAlternate: false))
        selection.clearIfSelectedContentChanged(from: captured)
        #expect(selection.active)
        #expect(selection.getSelectedText() == selectedText && !selectedText.isEmpty)
        #expect(cells(host.terminal) == cells(client.terminal))
        #expect(logicalLines(host.terminal) == logicalLines(client.terminal))
        #expect(!client.terminal.bracketedPasteMode)
        #expect(client.terminal.mouseMode == host.terminal.mouseMode)
        #expect(client.terminal.keyboardEnhancementFlags == host.terminal.keyboardEnhancementFlags)
        for fragment in ["\u{1b}[?1049heditor", "\u{1b}[2;1Hnext", "\u{1b}[?1049l"] {
            let previous = host.terminal.isCurrentBufferAlternate
            host.feed(Data(fragment.utf8))
            client.feed(host.paintFrame(previousAlternate: previous))
            #expect(cells(host.terminal) == cells(client.terminal))
            #expect(client.terminal.isCurrentBufferAlternate == host.terminal.isCurrentBufferAlternate)
        }
    }

    @Test func softWrapCopyAndCellsSurvivePaintingAndNewHostFrames() {
        let host = NativeTerminalEngine(columns: 8, rows: 5)
        let client = NativeTerminalEngine(columns: 8, rows: 5)
        host.feed(Data("abcdefghijklmnopqrstuvwx\r\nnext".utf8))
        client.feed(host.paintFrame())
        #expect(cells(host.terminal) == cells(client.terminal))
        #expect((0..<5).map { host.terminal.getLine(row: $0)?.isWrapped } == (0..<5).map { client.terminal.getLine(row: $0)?.isWrapped })
        #expect(logicalLines(host.terminal) == logicalLines(client.terminal))
        host.terminal.resize(cols: 16, rows: 5)
        client.terminal.resize(cols: 16, rows: 5)
        client.feed(host.paintFrame())
        #expect(cells(host.terminal) == cells(client.terminal))
        #expect(logicalLines(host.terminal) == logicalLines(client.terminal))
    }

    @Test func historyPagesPreserveWrapsWithoutMovingTheHostCursor() {
        let host = NativeTerminalEngine(columns: 8, rows: 4, scrollback: 30)
        host.feed(Data((0..<20).map { "row \($0) abcdefghij\r\n" }.joined().utf8))
        let x = host.terminal.buffer.x, y = host.terminal.buffer.y
        for offset in [0, 3, 10, 100] {
            let client = NativeTerminalEngine(columns: 8, rows: 4)
            client.feed(host.paintFrame(scrollOffset: offset))
            let top = host.terminal.buffer.totalLinesTrimmed + max(0, host.terminal.buffer.yDisp - offset)
            for row in 0..<4 {
                let line = host.terminal.getScrollInvariantLine(row: top + row)!
                #expect(client.terminal.getLine(row: row)!.translateToString(characterProvider: { client.terminal.getCharacter(for: $0) }) == line.translateToString(characterProvider: { host.terminal.getCharacter(for: $0) }))
                if row > 0 { #expect(client.terminal.getLine(row: row)!.isWrapped == line.isWrapped) }
            }
            #expect(host.terminal.buffer.x == x && host.terminal.buffer.y == y)
            #expect(client.replies.isEmpty)
        }
    }

    @Test func onlyTheHostAnswersQueriesAndOwnsParserContinuation() {
        let host = NativeTerminalEngine(columns: 20, rows: 5)
        let client = NativeTerminalEngine(columns: 20, rows: 5)
        for fragment in ["text\u{1b}[38;2;12;", "34;56mX\u{1b}]2;partial", " title\u{7}\u{1b}[6n", "\u{1b}[?1049h\u{1b}[3;2Heditor", "\u{1b}[?1049l"] {
            host.feed(Data(fragment.utf8))
            client.feed(host.paintFrame())
            #expect(cells(host.terminal) == cells(client.terminal))
            #expect(client.replies.isEmpty)
            #expect(host.terminal.isCurrentBufferAlternate == client.terminal.isCurrentBufferAlternate)
        }
        #expect(!host.replies.isEmpty)
    }

    @Test func paintingRetainsUnicodeLinksPaletteAndKeyboardModes() {
        let host = NativeTerminalEngine(columns: 24, rows: 6)
        let client = NativeTerminalEngine(columns: 24, rows: 6)
        host.feed(Data("\u{1b}]4;1;rgb:1234/5678/9abc\u{1b}\\\u{1b}[31m漢字 café 👩‍💻\r\n\u{1b}]8;;https://example.org\u{1b}\\link\u{1b}]8;;\u{1b}\\\u{1b}[?1;1003;1006;2004h\u{1b}[>3u".utf8))
        client.feed(host.paintFrame())
        #expect(cells(host.terminal) == cells(client.terminal))
        #expect(client.terminal.applicationCursor && client.terminal.bracketedPasteMode)
        #expect(client.terminal.mouseMode == host.terminal.mouseMode)
        #expect(client.terminal.keyboardEnhancementFlags == host.terminal.keyboardEnhancementFlags)
        #expect(client.terminal.link(at: .screen(Position(col: 1, row: 1)), mode: .explicitOnly) == "https://example.org")
        #expect(client.replies.isEmpty)
    }

    @Test func overwrittenWideCellDoesNotShiftTheFollowingNarrowCell() {
        let host = NativeTerminalEngine(columns: 12, rows: 3)
        let client = NativeTerminalEngine(columns: 12, rows: 3)
        host.feed(Data("世界\u{1b}[1;2HX".utf8))
        client.feed(host.paintFrame())
        #expect(cells(host.terminal) == cells(client.terminal))
    }

    @Test(arguments: [
        "shell$ printf hello\r\nhello\r\nshell$ ",
        "\u{1b}[38;2;10;20;30mtruecolor\u{1b}[48;5;123m background\u{1b}[0m\r\nplain",
        "\u{1b}[1;2;3;5;7;8;9mstyles\u{1b}[0m\u{1b}[4:3;58;2;12;34;56munderline",
        "caffè e\u{301} 漢字 👩‍💻 🇮🇹\r\nnext",
        "\u{1b}[?1049h\u{1b}[2J\u{1b}[2;4Heditor\u{1b}[8;1Hstatus\u{1b}[4;8H",
        "\u{1b}[3;8r\u{1b}[?6h\u{1b}[2;5Hmargin",
    ]) func textAttributesAndCursorComeFromTheCurrentHostFrame(input: String) {
        let host = NativeTerminalEngine(columns: 40, rows: 10)
        let client = NativeTerminalEngine(columns: 40, rows: 10)
        host.feed(Data(input.utf8)); client.feed(host.paintFrame())
        let matches = cells(host.terminal) == cells(client.terminal)
        #expect(matches)
        let a = host.terminal.makeRenderSnapshot(scope: .full), b = client.terminal.makeRenderSnapshot(scope: .full)
        #expect(a.cursor.x == b.cursor.x && a.cursor.y == b.cursor.y)
        #expect(a.isAlternateScreen == b.isAlternateScreen)
    }

    @Test func splitUnicodeAndOversizedStringStateStaysOnlyOnTheHost() {
        let host = NativeTerminalEngine(columns: 24, rows: 5)
        let client = NativeTerminalEngine(columns: 24, rows: 5)
        let scalar = Array("漢".utf8)
        host.feed(Data(scalar.prefix(2))); client.feed(host.paintFrame())
        host.feed(Data(scalar.suffix(1))); client.feed(host.paintFrame())
        #expect(cells(host.terminal) == cells(client.terminal))
        host.feed(Data(("\u{1b}]2;" + String(repeating: "t", count: 70_000)).utf8))
        client.feed(host.paintFrame())
        host.feed(Data(" completed\u{7}next".utf8)); client.feed(host.paintFrame())
        #expect(cells(host.terminal) == cells(client.terminal))
        #expect(client.title == host.title)
        #expect(client.replies.isEmpty)
    }

    @Test func doubleWidthAndDoubleHeightRowsRetainTheirRenderingMode() {
        let host = NativeTerminalEngine(columns: 24, rows: 6)
        let client = NativeTerminalEngine(columns: 24, rows: 6)
        host.feed(Data("\u{1b}#6wide\u{1b}[2;1H\u{1b}#3TOP\u{1b}[3;1H\u{1b}#4BOTTOM".utf8))
        client.feed(host.paintFrame())
        let a = host.terminal.makeRenderSnapshot(scope: .full), b = client.terminal.makeRenderSnapshot(scope: .full)
        #expect(a.lines.map { String(describing: $0.renderMode) } == b.lines.map { String(describing: $0.renderMode) })
        let matches = cells(host.terminal) == cells(client.terminal)
        #expect(matches)
    }

    @Test func wideWrapSpacerAndWrappedHyperlinksRetainCopySemantics() {
        let host = NativeTerminalEngine(columns: 8, rows: 6)
        let client = NativeTerminalEngine(columns: 8, rows: 6)
        host.feed(Data("1234567漢字\r\n\u{1b}]8;id=test;https://example.org\u{1b}\\abcdefghijklmnop\u{1b}]8;;\u{1b}\\".utf8))
        client.feed(host.paintFrame())
        let matches = cells(host.terminal) == cells(client.terminal)
        #expect(matches)
        #expect(logicalLines(host.terminal) == logicalLines(client.terminal))
        for row in 0..<6 {
            for column in 0..<8 {
                let location = Terminal.LinkLookupLocation.screen(Position(col: column, row: row))
                #expect(host.terminal.link(at: location, mode: .explicitOnly) == client.terminal.link(at: location, mode: .explicitOnly))
            }
        }
    }

    @Test func paletteAndReverseVideoAreCopiedWithoutQueriesToThePty() {
        let host = NativeTerminalEngine(columns: 20, rows: 4)
        let client = NativeTerminalEngine(columns: 20, rows: 4)
        host.feed(Data("\u{1b}]4;1;rgb:1234/5678/9abc\u{1b}\\\u{1b}[31mcolor\u{1b}[?5h".utf8))
        client.feed(host.paintFrame())
        let a = host.terminal.makeRenderSnapshot(scope: .full), b = client.terminal.makeRenderSnapshot(scope: .full)
        #expect(a.palette[1] == b.palette[1] && a.reverseVideo == b.reverseVideo)
        #expect(host.replies.isEmpty && client.replies.isEmpty)
    }

    @Test(arguments: ["shell", "vim", "less"])
    func recordedCorpusAndExitArePaintedFromHostState(name: String) throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "ansi", subdirectory: "Fixtures/Terminal"))
        let exitURL = try #require(Bundle.module.url(forResource: name + "-exit", withExtension: "ansi", subdirectory: "Fixtures/Terminal"))
        let host = NativeTerminalEngine(columns: 80, rows: 24)
        let client = NativeTerminalEngine(columns: 80, rows: 24)
        host.feed(try Data(contentsOf: url)); client.feed(host.paintFrame())
        var matches = cells(host.terminal) == cells(client.terminal)
        if !matches {
            let frame = host.terminal.makeRenderSnapshot(scope: .full)
            print("Paint \(name): synchronized=\(frame.synchronizedOutputActive), rendered-first=\(frame.lines.first?.cells.first?.text ?? "missing")")
            let left = cells(host.terminal), right = cells(client.terminal)
            let indices = left.indices.filter { left[$0] != right[$0] }
            for index in indices.prefix(3) { print("Paint \(name) initial \(index / 80),\(index % 80): Host \(left[index]); Client \(right[index])") }
        }
        #expect(matches)
        host.feed(try Data(contentsOf: exitURL)); client.feed(host.paintFrame())
        matches = cells(host.terminal) == cells(client.terminal)
        if !matches {
            let left = cells(host.terminal), right = cells(client.terminal)
            let indices = left.indices.filter { left[$0] != right[$0] }
            for index in indices.prefix(3) { print("Paint \(name) exit \(index / 80),\(index % 80): Host \(left[index]); Client \(right[index])") }
        }
        #expect(matches)
        #expect(client.replies.isEmpty)
    }

    private func logicalLines(_ terminal: Terminal) -> String {
        var result = ""
        for row in 0..<terminal.rows {
            let line = terminal.getLine(row: row)!
            if row > 0 && !line.isWrapped { result += "\n" }
            result += line.translateToString(trimRight: true, characterProvider: { terminal.getCharacter(for: $0) })
        }
        return result
    }
}
