import Foundation

public enum NorthpaneRelease {
    public static let version = "1.0.2"
}

public enum BridgeProtocol {
    public static let major = 1
    public static let schemaRevision = 13
    public static let maximumFrameBytes = 1_048_576
}

/// The Herdr releases the live conformance run (`liveHerdrConformance`) has certified: 0.8.2 (protocol 20,
/// the baseline), 0.9.0 and 0.9.1 (protocol 22, endpoint generation 1), against isolated headless
/// servers on macOS and Linux (2026-09-16) and on Windows (0.9.1, 2026-09-17). Any other release is
/// uncertified and needs the Operator's acknowledgement before use; adding one here means the run
/// passed, not that it looked fine.
public enum HerdrCertifiedReleases {
    public static let versions: Set<String> = ["0.8.2", "0.9.0", "0.9.1"]
}

public struct ConnectionID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct ChannelID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct MessageID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct HostID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct ClientDeviceID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum Capability: String, Codable, CaseIterable, Sendable {
    case observeRuntime
    case terminalObserve
    case terminalControl
    case attention
    case artifactPublication
    case preview
    case authorizationBroker
    case notifications
}

public enum CapabilityMaturity: String, Codable, Sendable { case stable, beta }
public enum GrantKind: String, Codable, Sendable { case observation, standardControl, authorizationBroker, trustAdministration }

public struct CapabilityDescriptor: Equatable, Codable, Sendable {
    public let capability: Capability
    public let maturity: CapabilityMaturity
    public let requiredGrant: GrantKind
    public let dependencies: Set<Capability>
}

public enum CapabilityRegistry {
    public static let descriptors: [Capability: CapabilityDescriptor] = [
        .observeRuntime: .init(capability: .observeRuntime, maturity: .stable, requiredGrant: .observation, dependencies: []),
        .terminalObserve: .init(capability: .terminalObserve, maturity: .stable, requiredGrant: .observation, dependencies: [.observeRuntime]),
        .terminalControl: .init(capability: .terminalControl, maturity: .stable, requiredGrant: .standardControl, dependencies: [.terminalObserve]),
        .attention: .init(capability: .attention, maturity: .stable, requiredGrant: .standardControl, dependencies: [.observeRuntime]),
        .artifactPublication: .init(capability: .artifactPublication, maturity: .stable, requiredGrant: .standardControl, dependencies: [.observeRuntime]),
        .preview: .init(capability: .preview, maturity: .beta, requiredGrant: .standardControl, dependencies: [.observeRuntime]),
        .authorizationBroker: .init(capability: .authorizationBroker, maturity: .beta, requiredGrant: .authorizationBroker, dependencies: [.observeRuntime]),
        .notifications: .init(capability: .notifications, maturity: .beta, requiredGrant: .standardControl, dependencies: [.observeRuntime, .attention]),
    ]

    public static func validated(_ offered: Set<Capability>) -> Set<Capability> {
        var result = offered
        while let invalid = result.first(where: { descriptor in
            guard let metadata = descriptors[descriptor] else { return true }
            return !metadata.dependencies.isSubset(of: result)
        }) { result.remove(invalid) }
        return result
    }
}

public enum ProblemLocus: String, Codable, Sendable { case client, transport, bridge, herdr, managedService }
public enum RetryClass: String, Codable, Sendable { case never, afterUserAction, afterReconnect, afterRefresh }
public enum OperationPhase: String, Codable, Sendable { case handshake, trust, pairing, discovery, compatibility, snapshot, events, mutation, terminal, resource, service }

public struct Problem: Error, Codable, Equatable, Sendable {
    public let code: String
    public let locus: ProblemLocus
    public let retry: RetryClass
    public let recoveryAction: String
    public let phase: OperationPhase?
    public let correlationID: String?

    public init(code: String, locus: ProblemLocus, retry: RetryClass, recoveryAction: String, phase: OperationPhase? = nil, correlationID: String? = nil) {
        self.code = code; self.locus = locus; self.retry = retry; self.recoveryAction = recoveryAction; self.phase = phase; self.correlationID = correlationID
    }

    public static let incompatibleProtocol = Problem(code: "incompatible_protocol", locus: .bridge, retry: .afterUserAction, recoveryAction: "updateClientOrBridge")
    public static let oversizedFrame = Problem(code: "oversized_frame", locus: .transport, retry: .never, recoveryAction: "reconnect")
    public static let malformedFrame = Problem(code: "malformed_frame", locus: .transport, retry: .afterReconnect, recoveryAction: "reconnect")
    public static let closedTransport = Problem(code: "closed_transport", locus: .transport, retry: .afterReconnect, recoveryAction: "reconnect")
    public static let invalidCapabilitySet = Problem(code: "invalid_capability_set", locus: .bridge, retry: .afterRefresh, recoveryAction: "refreshCapabilities", phase: .compatibility)
    public static let eventGap = Problem(code: "event_gap", locus: .herdr, retry: .afterRefresh, recoveryAction: "requestFullSnapshot", phase: .events)
    public static let deadlineExceeded = Problem(code: "deadline_exceeded", locus: .bridge, retry: .afterRefresh, recoveryAction: "queryReceipt", phase: .mutation)
    public static let unauthorized = Problem(code: "unauthorized", locus: .bridge, retry: .afterUserAction, recoveryAction: "reviewGrant", phase: .mutation)
}

public enum ProblemCatalog {
    public static let all: [Problem] = [.incompatibleProtocol, .oversizedFrame, .malformedFrame, .closedTransport, .invalidCapabilitySet, .eventGap, .deadlineExceeded, .unauthorized]
    public static func problem(code: String) -> Problem? { all.first { $0.code == code } }
}

public struct VersionRange: Codable, Equatable, Sendable {
    public let minimum: Int
    public let maximum: Int
    public init(minimum: Int, maximum: Int) { self.minimum = minimum; self.maximum = maximum }
    public func includes(_ value: Int) -> Bool { minimum <= value && value <= maximum }
}

public struct HandshakeHello: Codable, Equatable, Sendable {
    public let protocolRange: VersionRange
    public let schemaRange: VersionRange
    public let clientDeviceID: ClientDeviceID
    public let clientVersion: String
    public let maximumFrameBytes: Int
    public let hostIdentityChallenge: Data
    public let expectedHostFingerprint: String?
    public init(protocolRange: VersionRange, schemaRange: VersionRange, clientDeviceID: ClientDeviceID, clientVersion: String = "development", maximumFrameBytes: Int = BridgeProtocol.maximumFrameBytes, hostIdentityChallenge: Data = Data(), expectedHostFingerprint: String? = nil) {
        self.protocolRange = protocolRange; self.schemaRange = schemaRange; self.clientDeviceID = clientDeviceID; self.clientVersion = clientVersion; self.maximumFrameBytes = maximumFrameBytes; self.hostIdentityChallenge = hostIdentityChallenge; self.expectedHostFingerprint = expectedHostFingerprint
    }
}

public struct HandshakeAccepted: Codable, Equatable, Sendable {
    public let protocolMajor: Int
    public let schemaRevision: Int
    public let hostID: HostID
    public let capabilities: Set<Capability>
    public let bridgeVersion: String
    public let maximumFrameBytes: Int
    public let hostSigningPublicKey: Data
    public let hostIdentitySignature: Data
    public let herdrVersion: String
    /// Identifies the running Bridge binary, not its release (revision 9). Two Bridges that differ
    /// only in how something behaves report the same `bridgeVersion` and the same `schemaRevision`,
    /// so this is what tells them apart. Empty from a Bridge older than revision 9, which reads as
    /// "cannot tell" and never as "a different build".
    public let bridgeBuildID: String
    public init(protocolMajor: Int, schemaRevision: Int, hostID: HostID, capabilities: Set<Capability>, bridgeVersion: String = "development", maximumFrameBytes: Int = BridgeProtocol.maximumFrameBytes, hostSigningPublicKey: Data = Data(), hostIdentitySignature: Data = Data(), herdrVersion: String = "unknown", bridgeBuildID: String = "") {
        self.protocolMajor = protocolMajor; self.schemaRevision = schemaRevision; self.hostID = hostID; self.capabilities = capabilities; self.bridgeVersion = bridgeVersion; self.maximumFrameBytes = maximumFrameBytes; self.hostSigningPublicKey = hostSigningPublicKey; self.hostIdentitySignature = hostIdentitySignature; self.herdrVersion = herdrVersion; self.bridgeBuildID = bridgeBuildID
    }
}

public enum EnvelopePayload: Codable, Equatable, Sendable {
    case hello(HandshakeHello)
    case accepted(HandshakeAccepted)
    case problem(Problem)
    case openChannel(OpenChannel)
    case windowUpdate(WindowUpdate)
    case cancel(CancelChannel)
    case close(CloseChannel)
    case runtimeSnapshot(WireRuntimeSnapshot)
    case runtimeEvents(WireRuntimeEventBatch)
    case mutation(MutationRequest)
    case mutationReceipt(WireMutationReceipt)
    case terminalInput(TerminalInputFrame)
    case terminalAcknowledgement(TerminalInputAcknowledgement)
    case observeRuntime(ObserveRuntimeRequest)
    case terminalAttach(TerminalAttachRequest)
    case terminalAttached(TerminalAttached)
    case terminalOutput(TerminalOutputFrame)
    case terminalResize(TerminalResizeRequest)
    case terminalRelease(TerminalReleaseRequest)
    case heartbeat(Heartbeat)
    case pairingChallengeRequest(PairingChallengeRequest)
    case pairingChallenge(WirePairingChallenge)
    case pairingProof(WirePairingProof)
    case pairingAccepted(WirePairingAccepted)
    case resourceCommand(ResourceCommand)
    case resourceResult(ResourceResult)
    case authorizationCommand(AuthorizationCommand)
    case authorizationResult(AuthorizationResult)
    case notificationRouteCommand(NotificationRouteCommand)
    case notificationRouteResult(NotificationRouteResult)
    case terminalScroll(TerminalScrollRequest)
}

public struct Envelope: Codable, Equatable, Sendable {
    public let protocolMajor: Int
    public let schemaRevision: Int
    public let connectionID: ConnectionID
    public let channelID: ChannelID
    public let messageID: MessageID
    public let payload: EnvelopePayload
    public let preservedUnknownFields: Data
    public init(protocolMajor: Int = BridgeProtocol.major, schemaRevision: Int = BridgeProtocol.schemaRevision, connectionID: ConnectionID, channelID: ChannelID, messageID: MessageID = MessageID(), payload: EnvelopePayload, preservedUnknownFields: Data = Data()) {
        self.protocolMajor = protocolMajor; self.schemaRevision = schemaRevision; self.connectionID = connectionID; self.channelID = channelID; self.messageID = messageID; self.payload = payload; self.preservedUnknownFields = preservedUnknownFields
    }
}

public struct HandshakeNegotiator: Sendable {
    public let protocolRange: VersionRange
    public let schemaRange: VersionRange
    public let hostID: HostID
    public let capabilities: Set<Capability>
    public init(protocolRange: VersionRange, schemaRange: VersionRange, hostID: HostID, capabilities: Set<Capability>) {
        self.protocolRange = protocolRange; self.schemaRange = schemaRange; self.hostID = hostID; self.capabilities = capabilities
    }
    public func negotiate(_ hello: HandshakeHello) -> Result<HandshakeAccepted, Problem> {
        let protocolMajor = min(protocolRange.maximum, hello.protocolRange.maximum)
        let schemaRevision = min(schemaRange.maximum, hello.schemaRange.maximum)
        guard protocolRange.includes(protocolMajor), hello.protocolRange.includes(protocolMajor), schemaRange.includes(schemaRevision), hello.schemaRange.includes(schemaRevision) else { return .failure(.incompatibleProtocol) }
        guard hello.maximumFrameBytes > 0 else { return .failure(.oversizedFrame) }
        return .success(HandshakeAccepted(protocolMajor: protocolMajor, schemaRevision: schemaRevision, hostID: hostID, capabilities: CapabilityRegistry.validated(capabilities), maximumFrameBytes: min(BridgeProtocol.maximumFrameBytes, hello.maximumFrameBytes)))
    }
}
