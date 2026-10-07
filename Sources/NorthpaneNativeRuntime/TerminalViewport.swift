import Foundation
import SwiftTerm

/// Feasibility probe for ANSI viewport replay. Not yet a terminal attachment:
/// Soft-wrap history and several terminal modes still need coverage before this
/// becomes an attachment API. Keeping it internal prevents production use.
final class TerminalViewport: TerminalDelegate {
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
    private var stringSequence = [UInt8]()
    private var utf8Tail = [UInt8]()
    private var utf8Remaining = 0
    private var normalBuffer: Buffer!
    private var alternateBuffer: Buffer?
    var replies = Data()

    init(columns: Int, rows: Int, scrollback: Int = 1000) {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: columns, rows: rows, scrollback: scrollback, enableSixelReported: false, kittyImageCacheLimitBytes: 0))
        normalBuffer = terminal.buffer
    }

    func feed(_ data: Data) {
        for byte in data { observe(byte) }
        terminal.feed(byteArray: Array(data))
        if !terminal.isCurrentBufferAlternate { normalBuffer = terminal.buffer }
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) { replies.append(contentsOf: data) }
    func setTerminalTitle(source: Terminal, title: String) { self.title = title }
    func setTerminalIconTitle(source: Terminal, title: String) { iconTitle = title }
    func showCursor(source: Terminal) { cursorVisible = true }
    func hideCursor(source: Terminal) { cursorVisible = false }
    func bufferActivated(source: Terminal) {
        if source.isCurrentBufferAlternate { alternateBuffer = source.buffer }
        else { normalBuffer = source.buffer }
    }
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

    /// Draws the active viewport and restores the publicly available cursor,
    /// attributes and basic modes. This deliberately makes no claim to restore
    /// scrollback, soft-wrap flags or all subsequent parser behavior.
    func replayViewport() -> Data {
        var result = "\u{1b}c\u{1b}[?7l\u{1b}[?6l\u{1b}[4l"
        result += draw(normalBuffer)
        if terminal.isCurrentBufferAlternate, let alternateBuffer {
            // 1049 saves the normal cursor before entering the alternate screen.
            // Other entry modes preserve the saved cursor already drawn below.
            result += sgr(normalBuffer.savedAttr)
            result += cursor(normalBuffer)
            let entry = [1049, 1047, 47].first(where: { privateModes[$0] == true }) ?? 1049
            result += "\u{1b}[?\(entry)h\u{1b}[?7l\u{1b}[?6l\u{1b}[4l"
            result += draw(alternateBuffer)
        }
        result += "\u{1b}[\(terminal.buffer.scrollTop + 1);\(terminal.buffer.scrollBottom + 1)r"
        let mouseTracking = [9, 1000, 1002, 1003]
        let mouseEncoding = [1005, 1006, 1015, 1016]
        for mode in privateModes.keys.sorted() where !([47, 1047, 1048, 1049, 6] + mouseTracking + mouseEncoding).contains(mode) {
            result += "\u{1b}[?\(mode)" + (privateModes[mode] == true ? "h" : "l")
        }
        // These modes are mutually exclusive. A later reset clears the selection;
        // replaying historical flags in numerical order would change its meaning.
        for group in [mouseTracking, mouseEncoding] {
            for mode in group where privateModes[mode] == true { result += "\u{1b}[?\(mode)h" }
        }
        for mode in standardModes.keys.sorted() {
            result += "\u{1b}[\(mode)" + (standardModes[mode] == true ? "h" : "l")
        }
        result += applicationKeypad ? "\u{1b}=" : "\u{1b}>"
        result += "\u{1b}[\(cursorStyle) q"
        result += "\u{1b}[?25" + (cursorVisible ? "h" : "l")
        let origin = privateModes[6] == true
        result += "\u{1b}[?6" + (origin ? "h" : "l")
        result += cursor(terminal.buffer, origin: origin)
        result += sgr(terminal.currentAttribute)
        result += "\u{1b}]2;" + safeTitle(title) + "\u{1b}\\"
        result += "\u{1b}]1;" + safeTitle(iconTitle) + "\u{1b}\\"
        var data = Data(result.utf8)
        data.append(contentsOf: inString ? stringSequence : sequence)
        data.append(contentsOf: utf8Tail)
        return data
    }

    private func draw(_ buffer: Buffer) -> String {
        var result = sgr(buffer.savedAttr)
        result += position(x: buffer.savedX, y: buffer.savedY) + "\u{1b}7"
        for row in 0..<terminal.rows {
            result += position(x: 0, y: row)
            var lastAttribute: Attribute?
            var lastLink: String?
            for col in 0..<terminal.cols {
                let cell = buffer.getChar(at: Position(col: col, row: row))
                guard cell.width != 0 else { continue }
                if cell.attribute != lastAttribute { result += sgr(cell.attribute); lastAttribute = cell.attribute }
                let link = cell.getPayload() as? String
                if link != lastLink {
                    if lastLink != nil { result += "\u{1b}]8;;\u{1b}\\" }
                    if let link { result += "\u{1b}]8;" + link + "\u{1b}\\" }
                    lastLink = link
                }
                let character = terminal.getCharacter(for: cell)
                result += character == "\0" ? " " : String(character)
            }
            if lastLink != nil { result += "\u{1b}]8;;\u{1b}\\" }
        }
        return result
    }

    private func cursor(_ buffer: Buffer, origin: Bool = false) -> String {
        let y = buffer.y - (origin ? buffer.scrollTop : 0)
        guard buffer.x >= terminal.cols else { return position(x: buffer.x, y: y) }
        // CUP clamps x to cols-1. Reprint the final leading cell with autowrap
        // enabled to restore the pending-wrap state without adding a row.
        var col = terminal.cols - 1
        if buffer.getChar(at: Position(col: col, row: buffer.y)).width == 0 { col -= 1 }
        let cell = buffer.getChar(at: Position(col: col, row: buffer.y))
        let character = terminal.getCharacter(for: cell)
        return position(x: col, y: y) + "\u{1b}[?7h" + sgr(cell.attribute) + (character == "\0" ? " " : String(character))
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
                utf8Tail.append(byte); utf8Remaining -= 1
                if utf8Remaining == 0 { utf8Tail.removeAll() }
                // String payloads still need their raw UTF-8 bytes below.
                if !inString { return }
            } else { utf8Tail.removeAll(); utf8Remaining = 0 }
        } else if !inString && (0xc2...0xf4).contains(byte) {
            utf8Tail = [byte]
            utf8Remaining = byte < 0xe0 ? 1 : (byte < 0xf0 ? 2 : 3)
            return
        }
        if inString {
            if stringSequence.count < 65536 { stringSequence.append(byte) }
            if byte == 7 || (stringEscape && byte == 92) { inString = false; stringSequence.removeAll() }
            stringEscape = byte == 27
            return
        }
        if byte == 27 { sequence = [27]; parsingCSI = false; return }
        if sequence == [27] {
            switch byte {
            case 91: parsingCSI = true; sequence.append(byte)
            case 93, 80, 94, 95: inString = true; stringEscape = false; stringSequence = [27, byte]; sequence.removeAll()
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
