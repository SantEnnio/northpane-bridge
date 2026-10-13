import Foundation
import NorthpaneProtocol
import NorthpaneSecurity

public actor BridgeSessionResponder {
    private let authority: PairingAuthority
    private let negotiator: HandshakeNegotiator
    private let bridgeVersion: String
    private let herdrVersion: String
    private let bridgeBuildID: String
    private let runtimeKind: String
    private let runtimeVersion: String

    public init(authority: PairingAuthority, capabilities: Set<Capability>, bridgeVersion: String, herdrVersion: String, bridgeBuildID: String = "", runtimeKind: String = "herdr", runtimeVersion: String? = nil) {
        self.authority = authority
        self.negotiator = HandshakeNegotiator(protocolRange: .init(minimum: 1, maximum: BridgeProtocol.major), schemaRange: .init(minimum: runtimeKind == "native" ? BridgeProtocol.nativeRuntimeRevision : 1, maximum: BridgeProtocol.schemaRevision), hostID: authority.identity.hostID, capabilities: capabilities)
        self.bridgeVersion = bridgeVersion
        self.herdrVersion = herdrVersion
        self.bridgeBuildID = bridgeBuildID
        self.runtimeKind = runtimeKind; self.runtimeVersion = runtimeVersion ?? herdrVersion
    }

    public func respond(to envelope: Envelope) async -> Envelope {
        let payload: EnvelopePayload
        switch envelope.payload {
        case let .hello(hello):
            guard !hello.hostIdentityChallenge.isEmpty else {
                payload = .problem(Problem(code: "missing_identity_challenge", locus: .bridge, retry: .afterReconnect, recoveryAction: "restartHandshake", phase: .handshake))
                break
            }
            switch negotiator.negotiate(hello) {
            case let .failure(problem): payload = .problem(problem)
            case let .success(base):
                do {
                    let signature = try await authority.signHostIdentityChallenge(hello.hostIdentityChallenge)
                    // Made for this connection alone: the paired device proves its key by signing it.
                    let deviceChallenge = base.schemaRevision >= BridgeProtocol.deviceSessionProofRevision
                        ? Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }) : Data()
                    payload = .accepted(HandshakeAccepted(protocolMajor: base.protocolMajor, schemaRevision: base.schemaRevision, hostID: base.hostID, capabilities: base.capabilities, bridgeVersion: bridgeVersion, maximumFrameBytes: base.maximumFrameBytes, hostSigningPublicKey: authority.identity.signingPublicKey, hostIdentitySignature: signature, herdrVersion: herdrVersion, bridgeBuildID: bridgeBuildID, hostPlatform: HostPlatform.current.rawValue, deviceChallenge: deviceChallenge, runtimeKind: base.schemaRevision >= BridgeProtocol.nativeRuntimeRevision ? runtimeKind : nil, runtimeVersion: base.schemaRevision >= BridgeProtocol.nativeRuntimeRevision ? runtimeVersion : nil))
                } catch {
                    payload = .problem(Problem(code: "identity_signing_failed", locus: .bridge, retry: .never, recoveryAction: "repairBridgeIdentity", phase: .trust))
                }
            }
        default:
            payload = .problem(Problem(code: "handshake_required", locus: .bridge, retry: .afterReconnect, recoveryAction: "restartHandshake", phase: .handshake))
        }
        return Envelope(protocolMajor: envelope.protocolMajor, schemaRevision: envelope.schemaRevision, connectionID: envelope.connectionID, channelID: envelope.channelID, messageID: envelope.messageID, payload: payload)
    }
}
