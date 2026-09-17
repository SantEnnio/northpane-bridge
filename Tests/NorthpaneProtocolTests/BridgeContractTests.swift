import Foundation
import Testing
@testable import NorthpaneProtocol

@Test func incompatibleMajorIsRejected() {
    let negotiator = HandshakeNegotiator(protocolRange: .init(minimum: 1, maximum: 1), schemaRange: .init(minimum: 1, maximum: 1), hostID: HostID(), capabilities: [.observeRuntime])
    let hello = HandshakeHello(protocolRange: .init(minimum: 2, maximum: 2), schemaRange: .init(minimum: 1, maximum: 1), clientDeviceID: ClientDeviceID())
    #expect(negotiator.negotiate(hello) == .failure(.incompatibleProtocol))
}

@Test func sameEnvelopeSurvivesLengthPrefixedTransport() throws {
    let envelope = Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: .problem(.incompatibleProtocol))
    #expect(try FrameCodec.decode(FrameCodec.encode(envelope)) == envelope)
}

@Test func protobufGoldenHandshakeFrameIsStable() throws {
    let envelope = Envelope(
        schemaRevision: 1,
        connectionID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        channelID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
        messageID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!),
        payload: .hello(.init(protocolRange: .init(minimum: 1, maximum: 1), schemaRange: .init(minimum: 1, maximum: 1), clientDeviceID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!), clientVersion: "1.0.0"))
    )
    let encoded = try FrameCodec.encode(envelope)
    let fixtureURL = try #require(Bundle.module.url(forResource: "handshake-v1", withExtension: "base64", subdirectory: "Fixtures"))
    let fixture = try String(contentsOf: fixtureURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(encoded.base64EncodedString() == fixture)
    #expect(encoded.dropFirst(4).first != Character("{").asciiValue)
}

@Test func unknownTopLevelProtobufFieldsSurviveDecodeAndReencode() throws {
    let envelope = Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: .problem(.incompatibleProtocol))
    var frame = try FrameCodec.encode(envelope)
    let unknown = Data([0xA0, 0x06, 0x07]) // field 100, varint 7
    frame.append(unknown)
    var size = UInt32(frame.count - 4).bigEndian
    frame.replaceSubrange(0..<4, with: Data(bytes: &size, count: 4))
    let decoded = try FrameCodec.decode(frame)
    #expect(decoded.preservedUnknownFields == unknown)
    #expect(try FrameCodec.encode(decoded).suffix(unknown.count) == unknown)
}

@Test func terminalAndObservationMessagesRoundTripThroughProtobuf() throws {
    let connectionID = ConnectionID()
    let channelID = ChannelID()
    let messages: [EnvelopePayload] = [
        .observeRuntime(.init(sessionName: "work")),
        .terminalAttach(.init(paneID: "pane", mode: .takeover, columns: 80, rows: 24, incarnationID: "inc", snapshotID: "snap", nextEventSequence: 4)),
        .terminalAttached(.init(attachmentID: UUID(), paneID: "pane", mode: .control, controllerDeviceID: ClientDeviceID())),
        .terminalOutput(.init(attachmentID: UUID(), sequence: 2, bytes: Data([0x1B, 0x5B, 0x48]))),
        .terminalResize(.init(attachmentID: UUID(), columns: 120, rows: 40)),
        .terminalScroll(.init(attachmentID: UUID(), direction: .up, lines: 12)),
        .terminalScroll(.init(attachmentID: UUID(), direction: .down, lines: 1)),
        .terminalRelease(.init(attachmentID: UUID())),
        .heartbeat(.init(sentAt: Date(timeIntervalSince1970: 1_000))),
        .pairingChallengeRequest(.init()),
        .pairingChallenge(.init(challengeID: UUID(), hostID: HostID(), nonce: Data([1, 2, 3]), expiresAt: Date(timeIntervalSince1970: 1_100))),
        .pairingProof(.init(clientDeviceID: ClientDeviceID(), challengeID: UUID(), publicKey: Data([4]), signature: Data([5]))),
        .pairingAccepted(.init(clientDeviceID: ClientDeviceID(), observation: true, standardControl: true)),
    ]
    for payload in messages {
        let envelope = Envelope(connectionID: connectionID, channelID: channelID, payload: payload)
        #expect(try FrameCodec.decode(FrameCodec.encode(envelope)) == envelope)
    }
}

@Test func typedResourceCommandsRoundTripThroughSchemaRevisionTwo() throws {
    let id = UUID()
    let payloads: [EnvelopePayload] = [
        .resourceCommand(.init(kind: .publishArtifact, workspaceID: "workspace", path: "build/site", ttlSeconds: 3_600, mediaType: "text/html", idempotencyKey: "build-42")),
        .resourceCommand(.init(kind: .fetchPreviewHTTP, resourceID: id, expectedRevision: 2, path: "/events", method: "GET", headers: [.init(name: "Accept", value: "text/event-stream")], body: Data())),
        .resourceResult(.init(commandID: UUID(), resources: [.init(kind: .preview, resourceID: id, workspaceID: "workspace", revision: 1, title: "Pane Preview", expiresAt: Date(timeIntervalSince1970: 1_000), viewerAvailability: .available, paneID: "pane-1")])),
    ]
    for payload in payloads {
        let envelope = Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: payload)
        #expect(try FrameCodec.decode(FrameCodec.encode(envelope)) == envelope)
    }
}

/// Revision 11 keeps the optional agent and partial launch result typed as well as the Workspace
/// identities, so a successful create cannot disappear behind a later startup failure.
@Test func workspaceCreationAndAgentLaunchRoundTripThroughSchemaRevisionEleven() throws {
    let commandID = UUID()
    let deviceID = ClientDeviceID()
    let payloads: [EnvelopePayload] = [
        .mutation(.init(commandID: commandID, clientDeviceID: deviceID, capability: .terminalControl,
                        targetID: "workspace:create", expectedRevision: 0,
                        deadline: Date(timeIntervalSince1970: 2_000), workspaceLabel: "Preview demo",
                        workingDirectory: "/private/tmp/preview-demo", workspaceAgentKind: .codex)),
        .mutationReceipt(.init(commandID: commandID, outcome: .applied,
                               workspaceID: "workspace-created", paneID: "workspace-created:p1",
                               workspaceAgentKind: .codex, workspaceAgentStarted: true)),
    ]
    for payload in payloads {
        let envelope = Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: payload)
        #expect(try FrameCodec.decode(FrameCodec.encode(envelope)) == envelope)
    }
}

@Test func typedAuthorizationRequestsRoundTripThroughSchemaRevisionThree() throws {
    let requestID = UUID()
    let descriptor = AuthorizationRequestDescriptor(requestID: requestID, revision: 2, state: .awaitingUser,
        hostID: HostID(), processID: 42, hostname: "github.com", scopes: ["read:org", "repo"], provenance: "northpane-cli",
        createdAt: Date(timeIntervalSince1970: 1_000), expiresAt: Date(timeIntervalSince1970: 1_900),
        userCode: "ABCD-EFGH", verificationURL: URL(string: "https://github.com/login/device"))
    let payloads: [EnvelopePayload] = [
        .authorizationCommand(.init(kind: .approve, requestID: requestID, expectedRevision: 1)),
        .authorizationResult(.init(commandID: UUID(), requests: [descriptor])),
    ]
    for payload in payloads {
        let envelope = Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: payload)
        #expect(try FrameCodec.decode(FrameCodec.encode(envelope)) == envelope)
    }
}

@Test func typedNotificationRoutesRoundTripThroughSchemaRevisionThree() throws {
    let routeID = UUID(); let deviceID = ClientDeviceID(); let gateway = URL(string: "https://notifications.northpane.example/")!
    let payloads: [EnvelopePayload] = [
        .notificationRouteCommand(.init(kind: .put, routeID: routeID, encryptionPublicKey: Data(repeating: 1, count: 32),
            publisherCapability: Data(repeating: 2, count: 32), gatewayURL: gateway, expiresAt: Date(timeIntervalSince1970: 2_000))),
        .notificationRouteResult(.init(commandID: UUID(), routes: [.init(routeID: routeID, clientDeviceID: deviceID,
            gatewayURL: gateway, expiresAt: Date(timeIntervalSince1970: 2_000), lastUsedAt: Date(timeIntervalSince1970: 1_000))])),
    ]
    for payload in payloads {
        let envelope = Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: payload)
        #expect(try FrameCodec.decode(FrameCodec.encode(envelope)) == envelope)
    }
}

/// Revision 9 carries the Bridge's own build id, because the version and the revision cannot tell
/// two Bridges apart when one only fixes how something behaves. A Bridge older than revision 9
/// sends nothing there, and nothing must read as "cannot tell", never as "a different build".
@Test func theBridgeBuildIDSurvivesTheWireAndIsEmptyWhenTheBridgeIsOlder() throws {
    let hostID = HostID()
    let named = HandshakeAccepted(protocolMajor: 1, schemaRevision: BridgeProtocol.schemaRevision, hostID: hostID,
                                  capabilities: [.observeRuntime], bridgeVersion: "1.0.0", bridgeBuildID: String(repeating: "a1", count: 32))
    let envelope = Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: .accepted(named))
    guard case let .accepted(decoded) = try FrameCodec.decode(FrameCodec.encode(envelope)).payload else {
        Issue.record("Expected the handshake back")
        return
    }
    #expect(decoded.bridgeBuildID == named.bridgeBuildID)
    #expect(decoded.bridgeVersion == "1.0.0")

    let silent = HandshakeAccepted(protocolMajor: 1, schemaRevision: 8, hostID: hostID, capabilities: [.observeRuntime], bridgeVersion: "1.0.0")
    guard case let .accepted(older) = try FrameCodec.decode(FrameCodec.encode(Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: .accepted(silent)))).payload else {
        Issue.record("Expected the handshake back")
        return
    }
    #expect(older.bridgeBuildID.isEmpty)
}
