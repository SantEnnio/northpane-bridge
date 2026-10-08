import Foundation
import Crypto

#if os(macOS) || os(Linux)
/// The CLI proxy transports raw socket bytes, not JSONL. Use the documented WebSocket
/// handshake and frames through it; proxy never starts or resumes a server or a thread.
final class CodexObservationSocket {
    private let pipe: AgentCLIConversation
    private var nextID = 1

    init(executable: URL, endpoint: String) throws {
        let arguments = ["app-server", "proxy"] + (endpoint.isEmpty ? [] : ["--sock", endpoint])
        pipe = try AgentCLIConversation(executable: executable, arguments: arguments, timeout: 12)
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        do {
            try pipe.sendBytes(Data(request.utf8))
            guard let first = pipe.nextLine(), String(decoding: first, as: UTF8.self).hasPrefix("HTTP/1.1 101 ") else { throw Failure.unavailable }
            var accept: String?
            var headerBytes = first.count
            while let line = pipe.nextLine() {
                headerBytes += line.count
                guard headerBytes < 16_384 else { throw Failure.unreadable }
                let value = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty { break }
                if value.lowercased().hasPrefix("sec-websocket-accept:") { accept = String(value.dropFirst(21)).trimmingCharacters(in: .whitespaces) }
            }
            let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            guard accept == expected else { throw Failure.unreadable }
            _ = try call("initialize", ["clientInfo": ["name": "northpane-observer", "version": "1"], "capabilities": ["experimentalApi": true]])
            try send(["method": "initialized", "params": [:]])
        } catch { pipe.finish(); throw error }
    }

    deinit { pipe.finish() }
    enum Failure: Error { case unavailable, unreadable, unsupported, tooLarge, unauthorized }

    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let id = nextID; nextID += 1
        try send(["id": id, "method": method, "params": params])
        while true {
            let bytes = try receive()
            guard let message = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.unreadable }
            // Notifications and server requests have no observer authority. Never answer them.
            guard (message["id"] as? Int) == id else { continue }
            if let result = message["result"] as? [String: Any] { return result }
            if let error = message["error"] as? [String: Any], error["code"] as? Int == -32601 { throw Failure.unsupported }
            throw Failure.unreadable
        }
    }

    private func send(_ message: [String: Any]) throws {
        try frame(try JSONSerialization.data(withJSONObject: message), opcode: 1)
    }
    private func frame(_ bytes: Data, opcode: UInt8) throws {
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        var header = Data([0x80 | opcode])
        if bytes.count < 126 { header.append(0x80 | UInt8(bytes.count)) }
        else if bytes.count <= 65_535 {
            header.append(0x80 | 126); header.append(UInt8(bytes.count >> 8)); header.append(UInt8(bytes.count & 255))
        } else { throw Failure.tooLarge }
        header.append(contentsOf: mask)
        header.append(contentsOf: bytes.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try pipe.sendBytes(header)
    }
    private func receive() throws -> Data {
        var result = Data()
        var fragmented = false
        while true {
            guard let header = pipe.readBytes(2) else { throw Failure.unavailable }
            let final = header[0] & 0x80 != 0, opcode = header[0] & 0x0f
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { throw Failure.unreadable }
            var length = UInt64(header[1] & 0x7f)
            if length == 126 || length == 127 {
                guard let extra = pipe.readBytes(length == 126 ? 2 : 8) else { throw Failure.unavailable }
                length = extra.reduce(0) { ($0 << 8) | UInt64($1) }
            }
            guard length <= 8 * 1_024 * 1_024, UInt64(result.count) + length <= 8 * 1_024 * 1_024 else { throw Failure.tooLarge }
            guard let bytes = pipe.readBytes(Int(length)) else { throw Failure.unavailable }
            if opcode >= 8 {
                guard final, length <= 125 else { throw Failure.unreadable }
                if opcode == 8 { throw Failure.unavailable }
                if opcode == 9 { try frame(bytes, opcode: 10) }
                else if opcode != 10 { throw Failure.unreadable }
                continue
            }
            guard (opcode == 1 && !fragmented) || (opcode == 0 && fragmented) else { throw Failure.unreadable }
            result.append(bytes)
            if final { return result }
            fragmented = true
        }
    }
}
#endif
