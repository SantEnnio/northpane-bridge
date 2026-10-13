import Foundation
import SwiftTerm

/// Host-authoritative terminal engine and atomic rendering projection.
/// The owner serializes feed, resize and painting. Clients receive painted frames,
/// never parser checkpoints or subsequent raw PTY output.
final class NativeTerminalEngine: TerminalDelegate {
    private(set) var terminal: Terminal!
    private(set) var title = ""
    private(set) var iconTitle = ""
    private(set) var cursorVisible = true
    private(set) var cursorStyle = 1
    private(set) var applicationKeypad = false
    private(set) var privateModes: [Int: Bool] = [7: true, 25: true]
    private(set) var standardModes: [Int: Bool] = [:]
    private var sequence = [UInt8]()
    private var parsingCSI = false
    private var inString = false
    private var stringEscape = false
    private var utf8Remaining = 0
    var replies = Data()

    init(columns: Int, rows: Int, scrollback: Int = 1000) {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: columns, rows: rows, scrollback: scrollback, enableSixelReported: false, kittyImageCacheLimitBytes: 0))
    }

    func feed(_ data: Data) {
        for byte in data { observe(byte) }
        terminal.feed(byteArray: Array(data))
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) { replies.append(contentsOf: data) }
    func setTerminalTitle(source: Terminal, title: String) { self.title = String(title.prefix(1024)) }
    func setTerminalIconTitle(source: Terminal, title: String) { iconTitle = String(title.prefix(1024)) }
    func showCursor(source: Terminal) { cursorVisible = true }
    func hideCursor(source: Terminal) { cursorVisible = false }
    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        switch newStyle {
        case .blinkBlock: cursorStyle = 1
        case .steadyBlock: cursorStyle = 2
        case .blinkUnderline: cursorStyle = 3
        case .steadyUnderline: cursorStyle = 4
        case .blinkBar: cursorStyle = 5
        case .steadyBar: cursorStyle = 6
        }
    }

    /// Paints an authoritative view, never a resumable terminal checkpoint.
    /// Subsequent PTY bytes are interpreted only on the Host; the Client receives
    /// a new complete paint. That keeps parser continuations and query replies
    /// out of the Client. Soft wraps are reconstructed with real autowrap, using
    /// SwiftTerm's public line metadata so selection/copy retain logical lines.
    func paintFrame(columns: Int? = nil, rows: Int? = nil, scrollOffset: Int = 0, previousAlternate: Bool? = nil) -> Data {
        let width = max(1, columns ?? terminal.cols), height = max(1, rows ?? terminal.rows)
        let visibleTop = terminal.buffer.yDisp
        let history = terminal.isCurrentBufferAlternate ? 0 : visibleTop
        let offset = min(max(scrollOffset, 0), history)
        let displayTop = visibleTop - offset
        let originalDisplayTop = terminal.buffer.yDisp
        terminal.buffer.yDisp = displayTop
        let render = terminal.makeRenderSnapshot(scope: .full)
        terminal.buffer.yDisp = originalDisplayTop
        let lines = Array(render.lines.prefix(height))
        // RIS is needed only for a newly attached Client. Reusing the same
        // buffer on later paints preserves a selection of unchanged cells.
        var result = previousAlternate == nil ? "\u{1b}c" : "\u{1b}[!p"
        if render.isAlternateScreen != (previousAlternate ?? false) {
            result += render.isAlternateScreen ? "\u{1b}[?1049h" : "\u{1b}[?1049l"
        }
        result += "\u{1b}[?6l\u{1b}[?7l\u{1b}[?5l\u{1b}[2J\u{1b}[H"
        result += colorSequence(render.foregroundColor, code: 10)
        result += colorSequence(render.backgroundColor, code: 11)
        if let color = render.cursorColor { result += colorSequence(color, code: 12) }
        for (index, color) in render.palette.enumerated() { result += colorSequence(color, code: 4, index: index) }
        let drawnWidth = min(width, terminal.cols)
        let blankAttribute = terminal.buffer.getNullCell().attribute
        for (row, line) in lines.enumerated() {
            let rowWidth: Int
            let mode: String
            switch line.renderMode {
            case .single: rowWidth = drawnWidth; mode = "5"
            case .doubleWidth: rowWidth = min(drawnWidth, width / 2); mode = "6"
            case .doubledTop: rowWidth = min(drawnWidth, width / 2); mode = "3"
            case .doubledDown: rowWidth = min(drawnWidth, width / 2); mode = "4"
            }
            result += position(x: 0, y: row) + "\u{1b}#" + mode
            var firstColumn = 0
            if row > 0, line.isWrapped, rowWidth == width {
                let prior = lines[row - 1]
                var last = drawnWidth - 1
                var spacerHead = false
                if case .spacerHead = prior.cells[last].widthState { spacerHead = true }
                if !spacerHead { while last > 0 && prior.cells[last].width == 0 { last -= 1 } }
                result += position(x: last, y: row - 1) + "\u{1b}[?7h"
                if !spacerHead { result += sgr(prior.cells[last].attribute) + linkedGlyph(prior.cells[last], row: row - 1, column: last, top: displayTop) }
                // The next printable glyph completes the pending wrap. CUP alone
                // cannot mark a line as a continuation in the Client's buffer.
                if line.cells[0].width != 0 {
                    result += sgr(line.cells[0].attribute) + linkedGlyph(line.cells[0], row: row, column: 0, top: displayTop)
                    firstColumn = 1
                }
                result += "\u{1b}[?7l"
                if prior.cells[last].text.isEmpty && !spacerHead {
                    result += position(x: last, y: row - 1) + sgr(prior.cells[last].attribute) + "\u{1b}[1X"
                }
                if line.cells[0].text.isEmpty {
                    result += position(x: 0, y: row) + sgr(line.cells[0].attribute) + "\u{1b}[1X"
                }
            }
            var lastAttribute: Attribute?
            var lastLink: String?
            var nextColumn = -1
            for column in firstColumn..<rowWidth {
                let cell = line.cells[column]
                guard cell.width != 0 else { continue }
                let empty = cell.text.isEmpty
                if empty && cell.attribute == blankAttribute && column >= nextColumn { continue }
                // Usually adjacent cells can be printed together. Reposition when
                // overwriting the trailing half of an older wide glyph left a
                // wide leader followed by a narrow cell in the Host buffer.
                if column != nextColumn { result += position(x: column, y: row) }
                if cell.attribute != lastAttribute { result += sgr(cell.attribute); lastAttribute = cell.attribute }
                let link = cell.payloadID == nil ? nil : terminal.link(at: .buffer(Position(col: column, row: displayTop + row)), mode: .explicitOnly)
                if link != lastLink {
                    if lastLink != nil { result += "\u{1b}]8;;\u{1b}\\" }
                    if let link { result += "\u{1b}]8;;" + safeTitle(link) + "\u{1b}\\" }
                    lastLink = link
                }
                result += empty ? "\u{1b}[1X" : cell.text
                nextColumn = empty ? column : column + Int(cell.width)
            }
            if lastLink != nil { result += "\u{1b}]8;;\u{1b}\\" }
        }
        // Only input-encoding modes matter on a painted Client. Margins,
        // charsets, tab stops and saved parser state remain authoritative on Host.
        for group in [[1, 7, 9, 1000, 1002, 1003, 1005, 1006, 1015, 1016, 2004]] {
            for mode in group { result += "\u{1b}[?\(mode)" + (privateModes[mode] == true ? "h" : "l") }
        }
        if applicationKeypad { result += "\u{1b}=" }
        result += "\u{1b}[=\(terminal.keyboardEnhancementFlags.rawValue)u"
        result += terminal.mouseShiftCapture ? "\u{1b}[>1s" : "\u{1b}[>0s"
        if render.reverseVideo { result += "\u{1b}[?5h" }
        if offset == 0 && render.cursor.y < height {
            result += position(x: min(render.cursor.x, width - 1), y: render.cursor.y)
            result += "\u{1b}[\(cursorStyle) q\u{1b}[?25" + (render.cursor.hidden ? "l" : "h")
        } else { result += "\u{1b}[?25l" }
        result += "\u{1b}]2;" + safeTitle(title) + "\u{1b}\\"
        return Data(result.utf8)
    }

    private func linkedGlyph(_ cell: RenderSnapshotCell, row: Int, column: Int, top: Int) -> String {
        let glyph = cell.text.isEmpty ? " " : cell.text
        guard cell.payloadID != nil,
              let link = terminal.link(at: .buffer(Position(col: column, row: top + row)), mode: .explicitOnly) else { return glyph }
        return "\u{1b}]8;;" + safeTitle(link) + "\u{1b}\\" + glyph + "\u{1b}]8;;\u{1b}\\"
    }

    private func colorSequence(_ color: Color, code: Int, index: Int? = nil) -> String {
        "\u{1b}]\(code);" + (index.map { "\($0);" } ?? "") + "rgb:" + String(format: "%04x/%04x/%04x", color.red, color.green, color.blue) + "\u{1b}\\"
    }

    private func safeTitle(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 && !($0.value >= 128 && $0.value <= 159) })
    }

    private func position(x: Int, y: Int) -> String { "\u{1b}[\(y + 1);\(x + 1)H" }

    private func sgr(_ attribute: Attribute) -> String {
        var codes = ["0"]
        for (style, code) in [(CharacterStyle.bold, 1), (.dim, 2), (.italic, 3), (.blink, 5), (.inverse, 7), (.invisible, 8), (.crossedOut, 9)] {
            if attribute.style.contains(style) { codes.append(String(code)) }
        }
        if attribute.style.contains(.underline) {
            codes.append("4:\(max(1, attribute.underlineStyle.rawValue))")
        }
        func color(_ color: Attribute.Color, prefix: Int, fallback: Int) -> String {
            switch color {
            case .ansi256(let code): return "\(prefix);5;\(code)"
            case .trueColor(let red, let green, let blue): return "\(prefix);2;\(red);\(green);\(blue)"
            case .defaultColor, .defaultInvertedColor: return String(fallback)
            }
        }
        codes.append(color(attribute.fg, prefix: 38, fallback: 39))
        codes.append(color(attribute.bg, prefix: 48, fallback: 49))
        if let underline = attribute.underlineColor { codes.append(color(underline, prefix: 58, fallback: 59)) }
        return "\u{1b}[" + codes.joined(separator: ";") + "m"
    }

    /// Small, bounded observer. It never interprets printable content and keeps
    /// OSC/DCS payloads out of the mode parser (including fragmented strings).
    private func observe(_ byte: UInt8) {
        if utf8Remaining > 0 {
            if (0x80...0xbf).contains(byte) {
                utf8Remaining -= 1
                // String payloads still need their raw UTF-8 bytes below.
                if !inString { return }
            } else { utf8Remaining = 0 }
        } else if !inString && (0xc2...0xf4).contains(byte) {
            utf8Remaining = byte < 0xe0 ? 1 : (byte < 0xf0 ? 2 : 3)
            return
        }
        if inString {
            if byte == 7 || (stringEscape && byte == 92) { inString = false }
            stringEscape = byte == 27
            return
        }
        if byte == 27 { sequence = [27]; parsingCSI = false; return }
        if sequence == [27] {
            switch byte {
            case 91: parsingCSI = true; sequence.append(byte)
            case 93, 80, 94, 95: inString = true; stringEscape = false; sequence.removeAll()
            case 61: applicationKeypad = true; sequence.removeAll()
            case 62: applicationKeypad = false; sequence.removeAll()
            case 99:
                applicationKeypad = false; privateModes = [7: true, 25: true]; standardModes = [:]
                sequence.removeAll()
            default: sequence.removeAll()
            }
            return
        }
        guard parsingCSI else { return }
        sequence.append(byte)
        if sequence.count > 1024 { sequence.removeAll(); parsingCSI = false; return }
        guard (0x40...0x7e).contains(byte) else { return }
        if byte == 104 || byte == 108 {
            let parameters = String(decoding: sequence.dropFirst(2).dropLast(), as: UTF8.self)
            let isPrivate = parameters.hasPrefix("?")
            for token in (isPrivate ? String(parameters.dropFirst()) : parameters).split(separator: ";") {
                if let mode = Int(token) {
                    if isPrivate {
                        for group in [[9, 1000, 1002, 1003], [1005, 1006, 1015, 1016]] where group.contains(mode) {
                            for previous in group { privateModes.removeValue(forKey: previous) }
                        }
                        privateModes[mode] = byte == 104
                    }
                    else { standardModes[mode] = byte == 104 }
                }
            }
        }
        sequence.removeAll(); parsingCSI = false
    }
}
