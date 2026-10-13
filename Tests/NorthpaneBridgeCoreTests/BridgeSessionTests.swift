import Foundation
import Testing
@testable import NorthpaneBridgeCore
@testable import NorthpaneProtocol
@testable import NorthpaneSecurity

@Test func bridgeHandshakeNegotiatesAndProvesHostIdentity() async throws {
    let authority = try PairingAuthority()
    let responder = BridgeSessionResponder(authority: authority, capabilities: [.observeRuntime], bridgeVersion: "1.0.0", herdrVersion: "0.8.2")
    let hello = HandshakeHello(protocolRange: .init(minimum: 1, maximum: 1), schemaRange: .init(minimum: 1, maximum: 1), clientDeviceID: ClientDeviceID(), clientVersion: "1.0.0", hostIdentityChallenge: Data(repeating: 9, count: 32), expectedHostFingerprint: authority.identity.fingerprint)
    let request = Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: .hello(hello))
    let response = await responder.respond(to: request)
    guard case let .accepted(accepted) = response.payload else { Issue.record("Handshake was not accepted"); return }
    #expect(accepted.herdrVersion == "0.8.2")
    #expect(try verifyHostHandshake(hello: hello, accepted: accepted) == authority.identity)
}


@Test func nativeHandshakeDescribesTheRuntimeAndRejectsLegacyClients() async throws {
    let authority = try PairingAuthority()
    let responder = BridgeSessionResponder(authority: authority, capabilities: [.observeRuntime],
        bridgeVersion: "test", herdrVersion: "", runtimeKind: "native", runtimeVersion: "test")
    for maximum in [24, 25] {
        let hello = HandshakeHello(protocolRange: .init(minimum: 1, maximum: 1), schemaRange: .init(minimum: 1, maximum: maximum),
            clientDeviceID: ClientDeviceID(), hostIdentityChallenge: Data(repeating: 9, count: 32))
        let response = await responder.respond(to: Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: .hello(hello)))
        if maximum == 24 { #expect(response.payload == .problem(.incompatibleProtocol)) }
        else {
            guard case let .accepted(accepted) = response.payload else { Issue.record("Missing native handshake"); continue }
            #expect(accepted.usesNativeRuntime && accepted.runtimeVersion == "test" && accepted.herdrVersion.isEmpty)
            #expect(try verifyHostHandshake(hello: hello, accepted: accepted) == authority.identity)
            #expect(try FrameCodec.decode(FrameCodec.encode(response)) == response)
        }
    }
}
