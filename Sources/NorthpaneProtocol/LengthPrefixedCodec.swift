import Foundation
import SwiftProtobuf

public enum FrameCodec {
    public static func encode(_ envelope: Envelope) throws -> Data {
        let body = try EnvelopeCodec.encodeBody(envelope)
        guard body.count <= BridgeProtocol.maximumFrameBytes else { throw Problem.oversizedFrame }
        var byteCount = UInt32(body.count).bigEndian
        var frame = Data(bytes: &byteCount, count: MemoryLayout<UInt32>.size)
        frame.append(body)
        return frame
    }

    public static func decode(_ frame: Data) throws -> Envelope {
        guard frame.count >= 4 else { throw Problem.malformedFrame }
        let declared: UInt32 = frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard declared <= BridgeProtocol.maximumFrameBytes else { throw Problem.oversizedFrame }
        guard Int(declared) == frame.count - 4 else { throw Problem.malformedFrame }
        return try EnvelopeCodec.decodeBody(Data(frame.dropFirst(4)))
    }
}

public enum EnvelopeCodec {
    public static func encodeBody(_ envelope: Envelope) throws -> Data {
        var body = try BridgeWireMapper.encode(envelope).serializedData()
        body.append(envelope.preservedUnknownFields)
        guard body.count <= BridgeProtocol.maximumFrameBytes else { throw Problem.oversizedFrame }
        return body
    }

    public static func decodeBody(_ body: Data) throws -> Envelope {
        guard body.count <= BridgeProtocol.maximumFrameBytes else { throw Problem.oversizedFrame }
        do { return try BridgeWireMapper.decode(Northpane_Bridge_V1_Envelope(serializedBytes: body)) }
        catch let problem as Problem { throw problem }
        catch { throw Problem.malformedFrame }
    }
}
