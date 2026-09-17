import Foundation

enum BridgeWireMapper {
    static func encode(_ value: Envelope) throws -> Northpane_Bridge_V1_Envelope {
        var result = Northpane_Bridge_V1_Envelope()
        result.protocolMajor = try uint32(value.protocolMajor)
        result.schemaRevision = try uint32(value.schemaRevision)
        result.connectionID = value.connectionID.rawValue.uuidString
        result.channelID = value.channelID.rawValue.uuidString
        result.messageID = value.messageID.rawValue.uuidString
        switch value.payload {
        case let .hello(message): result.payload = .handshakeHello(try encode(message))
        case let .accepted(message): result.payload = .handshakeAccepted(try encode(message))
        case let .problem(message): result.payload = .problem(encode(message))
        case let .openChannel(message): result.payload = .openChannel(try encode(message))
        case let .windowUpdate(message): result.payload = .windowUpdate(try encode(message))
        case let .cancel(message): result.payload = .cancelChannel(encode(message))
        case let .close(message): result.payload = .closeChannel(encode(message))
        case let .runtimeSnapshot(message): result.payload = .runtimeSnapshot(try encode(message))
        case let .runtimeEvents(message): result.payload = .runtimeEvents(try encode(message))
        case let .mutation(message): result.payload = .mutation(try encode(message))
        case let .mutationReceipt(message): result.payload = .mutationReceipt(encode(message))
        case let .terminalInput(message): result.payload = .terminalInput(try encode(message))
        case let .terminalAcknowledgement(message): result.payload = .terminalAcknowledgement(try encode(message))
        case let .observeRuntime(message): result.payload = .observeRuntime(encode(message))
        case let .terminalAttach(message): result.payload = .terminalAttach(try encode(message))
        case let .terminalAttached(message): result.payload = .terminalAttached(encode(message))
        case let .terminalOutput(message): result.payload = .terminalOutput(try encode(message))
        case let .terminalResize(message): result.payload = .terminalResize(try encode(message))
        case let .terminalRelease(message): result.payload = .terminalRelease(encode(message))
        case let .heartbeat(message): result.payload = .heartbeat(encode(message))
        case .pairingChallengeRequest: result.payload = .pairingChallengeRequest(Northpane_Bridge_V1_PairingChallengeRequest())
        case let .pairingChallenge(message): result.payload = .pairingChallenge(encode(message))
        case let .pairingProof(message): result.payload = .pairingProof(encode(message))
        case let .pairingAccepted(message): result.payload = .pairingAccepted(encode(message))
        case let .resourceCommand(message): result.payload = .resourceCommand(try encode(message))
        case let .resourceResult(message): result.payload = .resourceResult(try encode(message))
        case let .authorizationCommand(message): result.payload = .authorizationCommand(try encode(message))
        case let .authorizationResult(message): result.payload = .authorizationResult(try encode(message))
        case let .notificationRouteCommand(message): result.payload = .notificationRouteCommand(try encode(message))
        case let .terminalScroll(message): result.payload = .terminalScroll(try encode(message))
        case let .notificationRouteResult(message): result.payload = .notificationRouteResult(try encode(message))
        }
        return result
    }

    static func decode(_ value: Northpane_Bridge_V1_Envelope) throws -> Envelope {
        guard let protocolMajor = Int(exactly: value.protocolMajor),
              let schemaRevision = Int(exactly: value.schemaRevision),
              let connection = UUID(uuidString: value.connectionID),
              let channel = UUID(uuidString: value.channelID),
              let message = UUID(uuidString: value.messageID),
              let payload = value.payload else { throw Problem.malformedFrame }
        let decoded: EnvelopePayload
        switch payload {
        case let .handshakeHello(wire): decoded = .hello(try decode(wire))
        case let .handshakeAccepted(wire): decoded = .accepted(try decode(wire))
        case let .problem(wire): decoded = .problem(try decode(wire))
        case let .openChannel(wire): decoded = .openChannel(try decode(wire))
        case let .windowUpdate(wire): decoded = .windowUpdate(try decode(wire))
        case let .cancelChannel(wire): decoded = .cancel(try decode(wire))
        case let .closeChannel(wire): decoded = .close(try decode(wire))
        case let .runtimeSnapshot(wire): decoded = .runtimeSnapshot(try decode(wire))
        case let .runtimeEvents(wire): decoded = .runtimeEvents(try decode(wire))
        case let .mutation(wire): decoded = .mutation(try decode(wire))
        case let .mutationReceipt(wire): decoded = .mutationReceipt(try decode(wire))
        case let .terminalInput(wire): decoded = .terminalInput(try decode(wire))
        case let .terminalAcknowledgement(wire): decoded = .terminalAcknowledgement(try decode(wire))
        case let .observeRuntime(wire): decoded = .observeRuntime(decode(wire))
        case let .terminalAttach(wire): decoded = .terminalAttach(try decode(wire))
        case let .terminalAttached(wire): decoded = .terminalAttached(try decode(wire))
        case let .terminalOutput(wire): decoded = .terminalOutput(try decode(wire))
        case let .terminalResize(wire): decoded = .terminalResize(try decode(wire))
        case let .terminalRelease(wire): decoded = .terminalRelease(try decode(wire))
        case let .heartbeat(wire): decoded = .heartbeat(decode(wire))
        case .pairingChallengeRequest: decoded = .pairingChallengeRequest(PairingChallengeRequest())
        case let .pairingChallenge(wire): decoded = .pairingChallenge(try decode(wire))
        case let .pairingProof(wire): decoded = .pairingProof(try decode(wire))
        case let .pairingAccepted(wire): decoded = .pairingAccepted(try decode(wire))
        case let .resourceCommand(wire): decoded = .resourceCommand(try decode(wire))
        case let .resourceResult(wire): decoded = .resourceResult(try decode(wire))
        case let .authorizationCommand(wire): decoded = .authorizationCommand(try decode(wire))
        case let .authorizationResult(wire): decoded = .authorizationResult(try decode(wire))
        case let .terminalScroll(wire): decoded = .terminalScroll(try decode(wire))
        case let .notificationRouteCommand(wire): decoded = .notificationRouteCommand(try decode(wire))
        case let .notificationRouteResult(wire): decoded = .notificationRouteResult(try decode(wire))
        }
        return Envelope(protocolMajor: protocolMajor, schemaRevision: schemaRevision, connectionID: .init(rawValue: connection), channelID: .init(rawValue: channel), messageID: .init(rawValue: message), payload: decoded, preservedUnknownFields: value.unknownFields.data)
    }

    private static func encode(_ value: HandshakeHello) throws -> Northpane_Bridge_V1_HandshakeHello {
        var result = Northpane_Bridge_V1_HandshakeHello()
        result.minimumProtocolMajor = try uint32(value.protocolRange.minimum)
        result.maximumProtocolMajor = try uint32(value.protocolRange.maximum)
        result.minimumSchemaRevision = try uint32(value.schemaRange.minimum)
        result.maximumSchemaRevision = try uint32(value.schemaRange.maximum)
        result.clientDeviceID = value.clientDeviceID.rawValue.uuidString
        result.clientVersion = value.clientVersion
        result.maximumFrameBytes = try uint32(value.maximumFrameBytes)
        result.hostIdentityChallenge = value.hostIdentityChallenge
        result.expectedHostFingerprint = value.expectedHostFingerprint ?? ""
        return result
    }

    private static func decode(_ value: Northpane_Bridge_V1_HandshakeHello) throws -> HandshakeHello {
        guard let device = UUID(uuidString: value.clientDeviceID) else { throw Problem.malformedFrame }
        return HandshakeHello(protocolRange: .init(minimum: try integer(value.minimumProtocolMajor), maximum: try integer(value.maximumProtocolMajor)), schemaRange: .init(minimum: try integer(value.minimumSchemaRevision), maximum: try integer(value.maximumSchemaRevision)), clientDeviceID: .init(rawValue: device), clientVersion: value.clientVersion, maximumFrameBytes: try integer(value.maximumFrameBytes), hostIdentityChallenge: value.hostIdentityChallenge, expectedHostFingerprint: value.expectedHostFingerprint.isEmpty ? nil : value.expectedHostFingerprint)
    }

    private static func encode(_ value: HandshakeAccepted) throws -> Northpane_Bridge_V1_HandshakeAccepted {
        var result = Northpane_Bridge_V1_HandshakeAccepted()
        result.protocolMajor = try uint32(value.protocolMajor)
        result.schemaRevision = try uint32(value.schemaRevision)
        result.hostID = value.hostID.rawValue.uuidString
        result.capabilities = value.capabilities.map(encode)
        result.bridgeVersion = value.bridgeVersion
        result.maximumFrameBytes = try uint32(value.maximumFrameBytes)
        result.hostSigningPublicKey = value.hostSigningPublicKey
        result.hostIdentitySignature = value.hostIdentitySignature
        result.herdrVersion = value.herdrVersion
        result.bridgeBuildID = value.bridgeBuildID
        return result
    }

    private static func decode(_ value: Northpane_Bridge_V1_HandshakeAccepted) throws -> HandshakeAccepted {
        guard let host = UUID(uuidString: value.hostID) else { throw Problem.malformedFrame }
        return HandshakeAccepted(protocolMajor: try integer(value.protocolMajor), schemaRevision: try integer(value.schemaRevision), hostID: .init(rawValue: host), capabilities: Set(try value.capabilities.map(decode)), bridgeVersion: value.bridgeVersion, maximumFrameBytes: try integer(value.maximumFrameBytes), hostSigningPublicKey: value.hostSigningPublicKey, hostIdentitySignature: value.hostIdentitySignature, herdrVersion: value.herdrVersion, bridgeBuildID: value.bridgeBuildID)
    }

    private static func encode(_ value: Problem) -> Northpane_Bridge_V1_Problem {
        var result = Northpane_Bridge_V1_Problem()
        result.code = value.code; result.locus = encode(value.locus); result.retryClass = encode(value.retry); result.recoveryAction = value.recoveryAction
        result.phase = value.phase.map(encode) ?? .unspecified
        result.correlationID = value.correlationID ?? ""
        return result
    }

    private static func decode(_ value: Northpane_Bridge_V1_Problem) throws -> Problem {
        Problem(code: value.code, locus: try decode(value.locus), retry: try decode(value.retryClass), recoveryAction: value.recoveryAction, phase: try decodeOptional(value.phase), correlationID: value.correlationID.isEmpty ? nil : value.correlationID)
    }

    private static func encode(_ value: OpenChannel) throws -> Northpane_Bridge_V1_OpenChannel {
        var result = Northpane_Bridge_V1_OpenChannel(); result.channelID = value.channelID.rawValue.uuidString; result.purpose = encode(value.purpose); result.initialWindowBytes = try uint64(value.initialWindowBytes); return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_OpenChannel) throws -> OpenChannel {
        guard let id = UUID(uuidString: value.channelID) else { throw Problem.malformedFrame }
        return OpenChannel(channelID: .init(rawValue: id), purpose: try decode(value.purpose), initialWindowBytes: try integer(value.initialWindowBytes))
    }
    private static func encode(_ value: WindowUpdate) throws -> Northpane_Bridge_V1_WindowUpdate {
        var result = Northpane_Bridge_V1_WindowUpdate(); result.channelID = value.channelID.rawValue.uuidString; result.additionalBytes = try uint64(value.additionalBytes); return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_WindowUpdate) throws -> WindowUpdate {
        guard let id = UUID(uuidString: value.channelID) else { throw Problem.malformedFrame }
        return WindowUpdate(channelID: .init(rawValue: id), additionalBytes: try integer(value.additionalBytes))
    }
    private static func encode(_ value: CancelChannel) -> Northpane_Bridge_V1_CancelChannel { var result = Northpane_Bridge_V1_CancelChannel(); result.channelID = value.channelID.rawValue.uuidString; result.reasonCode = value.reasonCode; return result }
    private static func decode(_ value: Northpane_Bridge_V1_CancelChannel) throws -> CancelChannel { guard let id = UUID(uuidString: value.channelID) else { throw Problem.malformedFrame }; return CancelChannel(channelID: .init(rawValue: id), reasonCode: value.reasonCode) }
    private static func encode(_ value: CloseChannel) -> Northpane_Bridge_V1_CloseChannel { var result = Northpane_Bridge_V1_CloseChannel(); result.channelID = value.channelID.rawValue.uuidString; return result }
    private static func decode(_ value: Northpane_Bridge_V1_CloseChannel) throws -> CloseChannel { guard let id = UUID(uuidString: value.channelID) else { throw Problem.malformedFrame }; return CloseChannel(channelID: .init(rawValue: id)) }

    private static func encode(_ value: WireRuntimeSnapshot) throws -> Northpane_Bridge_V1_RuntimeSnapshot {
        var result = Northpane_Bridge_V1_RuntimeSnapshot(); result.hostID = value.hostID.rawValue.uuidString; result.incarnationID = value.incarnationID; result.snapshotID = value.snapshotID; result.nextEventSequence = try uint64(value.nextEventSequence); result.panes = try value.panes.map { pane in var result = Northpane_Bridge_V1_Pane(); result.id = pane.id; result.title = pane.title; result.workspaceID = pane.workspaceID; result.tabID = pane.tabID; result.revision = try uint64(pane.revision); result.agent = pane.agent ?? ""; result.agentStatus = pane.agentStatus; result.focused = pane.focused; result.cwd = pane.cwd ?? ""; return result }; result.capabilities = value.capabilities.map(encode); result.workspaces = try value.workspaces.map { workspace in var result = Northpane_Bridge_V1_Workspace(); result.id = workspace.id; result.label = workspace.label; result.number = try uint32(workspace.number); result.focused = workspace.focused; result.activeTabID = workspace.activeTabID; result.worktreePath = workspace.worktreePath ?? ""; return result }; result.tabs = try value.tabs.map { tab in var result = Northpane_Bridge_V1_Tab(); result.id = tab.id; result.workspaceID = tab.workspaceID; result.label = tab.label; result.number = try uint32(tab.number); result.focused = tab.focused; return result }; return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_RuntimeSnapshot) throws -> WireRuntimeSnapshot {
        guard let host = UUID(uuidString: value.hostID) else { throw Problem.malformedFrame }
        return WireRuntimeSnapshot(hostID: .init(rawValue: host), incarnationID: value.incarnationID, snapshotID: value.snapshotID, nextEventSequence: try integer(value.nextEventSequence), panes: try value.panes.map { WirePane(id: $0.id, title: $0.title, workspaceID: $0.workspaceID, tabID: $0.tabID, revision: try integer($0.revision), agent: $0.agent.isEmpty ? nil : $0.agent, agentStatus: $0.agentStatus, focused: $0.focused, cwd: $0.cwd.isEmpty ? nil : $0.cwd) }, capabilities: Set(try value.capabilities.map(decode)), workspaces: try value.workspaces.map { WireWorkspace(id: $0.id, label: $0.label, number: try integer($0.number), focused: $0.focused, activeTabID: $0.activeTabID, worktreePath: $0.worktreePath.isEmpty ? nil : $0.worktreePath) }, tabs: try value.tabs.map { WireTab(id: $0.id, workspaceID: $0.workspaceID, label: $0.label, number: try integer($0.number), focused: $0.focused) })
    }
    private static func encode(_ value: WireRuntimeEventBatch) throws -> Northpane_Bridge_V1_RuntimeEventBatch {
        var result = Northpane_Bridge_V1_RuntimeEventBatch(); result.incarnationID = value.incarnationID; result.snapshotID = value.snapshotID; result.firstSequence = try uint64(value.firstSequence); result.events = value.events.map { event in var wire = Northpane_Bridge_V1_RuntimeEvent(); switch event { case let .paneOpened(pane): wire.type = .paneOpened; wire.paneID = pane.id; wire.title = pane.title; case let .paneClosed(id): wire.type = .paneClosed; wire.paneID = id; case let .paneRenamed(id, title): wire.type = .paneRenamed; wire.paneID = id; wire.title = title }; return wire }; return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_RuntimeEventBatch) throws -> WireRuntimeEventBatch {
        let events = try value.events.map { event -> WireRuntimeEvent in switch event.type { case .paneOpened: return .paneOpened(.init(id: event.paneID, title: event.title)); case .paneClosed: return .paneClosed(id: event.paneID); case .paneRenamed: return .paneRenamed(id: event.paneID, title: event.title); default: throw Problem.malformedFrame } }
        return WireRuntimeEventBatch(incarnationID: value.incarnationID, snapshotID: value.snapshotID, firstSequence: try integer(value.firstSequence), events: events)
    }

    private static func encode(_ value: MutationRequest) throws -> Northpane_Bridge_V1_MutationRequest {
        var result = Northpane_Bridge_V1_MutationRequest()
        result.commandID = value.commandID.uuidString; result.clientDeviceID = value.clientDeviceID.rawValue.uuidString
        result.capability = encode(value.capability); result.targetID = value.targetID
        result.expectedRevision = try uint64(value.expectedRevision)
        result.deadlineUnixMillis = Int64(value.deadline.timeIntervalSince1970 * 1_000)
        result.workspaceLabel = value.workspaceLabel; result.workingDirectory = value.workingDirectory
        result.workspaceAgentKind = encode(value.workspaceAgentKind)
        return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_MutationRequest) throws -> MutationRequest {
        guard let command = UUID(uuidString: value.commandID), let device = UUID(uuidString: value.clientDeviceID) else { throw Problem.malformedFrame }
        return MutationRequest(commandID: command, clientDeviceID: .init(rawValue: device), capability: try decode(value.capability),
            targetID: value.targetID, expectedRevision: try integer(value.expectedRevision),
            deadline: Date(timeIntervalSince1970: Double(value.deadlineUnixMillis) / 1_000), workspaceLabel: value.workspaceLabel,
            workingDirectory: value.workingDirectory, workspaceAgentKind: try decode(value.workspaceAgentKind))
    }
    private static func encode(_ value: WireMutationReceipt) -> Northpane_Bridge_V1_MutationReceipt {
        var result = Northpane_Bridge_V1_MutationReceipt()
        result.commandID = value.commandID.uuidString; result.outcome = encode(value.outcome)
        if let problem = value.problem { result.problem = encode(problem) }
        result.workspaceID = value.workspaceID; result.paneID = value.paneID
        result.workspaceAgentKind = encode(value.workspaceAgentKind); result.workspaceAgentStarted = value.workspaceAgentStarted
        return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_MutationReceipt) throws -> WireMutationReceipt {
        guard let command = UUID(uuidString: value.commandID) else { throw Problem.malformedFrame }
        return WireMutationReceipt(commandID: command, outcome: try decode(value.outcome),
            problem: value.hasProblem ? try decode(value.problem) : nil, workspaceID: value.workspaceID, paneID: value.paneID,
            workspaceAgentKind: try decode(value.workspaceAgentKind), workspaceAgentStarted: value.workspaceAgentStarted)
    }
    private static func encode(_ value: TerminalInputFrame) throws -> Northpane_Bridge_V1_TerminalInput { var result = Northpane_Bridge_V1_TerminalInput(); result.attachmentID = value.attachmentID.uuidString; result.sequence = try uint64(value.sequence); result.data = value.bytes; return result }
    private static func decode(_ value: Northpane_Bridge_V1_TerminalInput) throws -> TerminalInputFrame { guard let id = UUID(uuidString: value.attachmentID) else { throw Problem.malformedFrame }; return TerminalInputFrame(attachmentID: id, sequence: try integer(value.sequence), bytes: value.data) }
    private static func encode(_ value: TerminalInputAcknowledgement) throws -> Northpane_Bridge_V1_TerminalInputAcknowledgement { var result = Northpane_Bridge_V1_TerminalInputAcknowledgement(); result.attachmentID = value.attachmentID.uuidString; result.acceptedThroughSequence = try uint64(value.acceptedThroughSequence); return result }
    private static func decode(_ value: Northpane_Bridge_V1_TerminalInputAcknowledgement) throws -> TerminalInputAcknowledgement { guard let id = UUID(uuidString: value.attachmentID) else { throw Problem.malformedFrame }; return TerminalInputAcknowledgement(attachmentID: id, acceptedThroughSequence: try integer(value.acceptedThroughSequence)) }

    private static func encode(_ value: ObserveRuntimeRequest) -> Northpane_Bridge_V1_ObserveRuntimeRequest { var result = Northpane_Bridge_V1_ObserveRuntimeRequest(); result.sessionName = value.sessionName ?? ""; return result }
    private static func decode(_ value: Northpane_Bridge_V1_ObserveRuntimeRequest) -> ObserveRuntimeRequest { ObserveRuntimeRequest(sessionName: value.sessionName.isEmpty ? nil : value.sessionName) }
    private static func encode(_ value: TerminalAttachRequest) throws -> Northpane_Bridge_V1_TerminalAttachRequest { var result = Northpane_Bridge_V1_TerminalAttachRequest(); result.paneID = value.paneID; result.mode = encode(value.mode); result.columns = try uint32(value.columns); result.rows = try uint32(value.rows); result.incarnationID = value.incarnationID; result.snapshotID = value.snapshotID; result.nextEventSequence = try uint64(value.nextEventSequence); return result }
    private static func decode(_ value: Northpane_Bridge_V1_TerminalAttachRequest) throws -> TerminalAttachRequest { TerminalAttachRequest(paneID: value.paneID, mode: try decode(value.mode), columns: try integer(value.columns), rows: try integer(value.rows), incarnationID: value.incarnationID, snapshotID: value.snapshotID, nextEventSequence: try integer(value.nextEventSequence)) }
    private static func encode(_ value: TerminalAttached) -> Northpane_Bridge_V1_TerminalAttached { var result = Northpane_Bridge_V1_TerminalAttached(); result.attachmentID = value.attachmentID.uuidString; result.paneID = value.paneID; result.mode = encode(value.mode); result.controllerDeviceID = value.controllerDeviceID?.rawValue.uuidString ?? ""; return result }
    private static func decode(_ value: Northpane_Bridge_V1_TerminalAttached) throws -> TerminalAttached { guard let attachment = UUID(uuidString: value.attachmentID) else { throw Problem.malformedFrame }; let device = value.controllerDeviceID.isEmpty ? nil : UUID(uuidString: value.controllerDeviceID); if !value.controllerDeviceID.isEmpty, device == nil { throw Problem.malformedFrame }; return TerminalAttached(attachmentID: attachment, paneID: value.paneID, mode: try decode(value.mode), controllerDeviceID: device.map { ClientDeviceID(rawValue: $0) }) }
    private static func encode(_ value: TerminalOutputFrame) throws -> Northpane_Bridge_V1_TerminalOutput { var result = Northpane_Bridge_V1_TerminalOutput(); result.attachmentID = value.attachmentID.uuidString; result.sequence = try uint64(value.sequence); result.data = value.bytes; return result }
    private static func decode(_ value: Northpane_Bridge_V1_TerminalOutput) throws -> TerminalOutputFrame { guard let attachment = UUID(uuidString: value.attachmentID) else { throw Problem.malformedFrame }; return TerminalOutputFrame(attachmentID: attachment, sequence: try integer(value.sequence), bytes: value.data) }
    private static func encode(_ value: TerminalResizeRequest) throws -> Northpane_Bridge_V1_TerminalResize { var result = Northpane_Bridge_V1_TerminalResize(); result.attachmentID = value.attachmentID.uuidString; result.columns = try uint32(value.columns); result.rows = try uint32(value.rows); return result }
    private static func encode(_ value: TerminalScrollRequest) throws -> Northpane_Bridge_V1_TerminalScroll { var result = Northpane_Bridge_V1_TerminalScroll(); result.attachmentID = value.attachmentID.uuidString; result.direction = value.direction == .up ? .terminalScrollUp : .terminalScrollDown; result.lines = try uint32(value.lines); return result }
    private static func decode(_ value: Northpane_Bridge_V1_TerminalScroll) throws -> TerminalScrollRequest {
        guard let attachment = UUID(uuidString: value.attachmentID) else { throw Problem.malformedFrame }
        let direction: TerminalScrollDirection = switch value.direction { case .terminalScrollUp: .up; case .terminalScrollDown: .down; default: throw Problem.malformedFrame }
        return TerminalScrollRequest(attachmentID: attachment, direction: direction, lines: try integer(value.lines))
    }
    private static func decode(_ value: Northpane_Bridge_V1_TerminalResize) throws -> TerminalResizeRequest { guard let attachment = UUID(uuidString: value.attachmentID) else { throw Problem.malformedFrame }; return TerminalResizeRequest(attachmentID: attachment, columns: try integer(value.columns), rows: try integer(value.rows)) }
    private static func encode(_ value: TerminalReleaseRequest) -> Northpane_Bridge_V1_TerminalRelease { var result = Northpane_Bridge_V1_TerminalRelease(); result.attachmentID = value.attachmentID.uuidString; return result }
    private static func decode(_ value: Northpane_Bridge_V1_TerminalRelease) throws -> TerminalReleaseRequest { guard let attachment = UUID(uuidString: value.attachmentID) else { throw Problem.malformedFrame }; return TerminalReleaseRequest(attachmentID: attachment) }
    private static func encode(_ value: Heartbeat) -> Northpane_Bridge_V1_Heartbeat { var result = Northpane_Bridge_V1_Heartbeat(); result.sentUnixMillis = Int64(value.sentAt.timeIntervalSince1970 * 1_000); return result }
    private static func decode(_ value: Northpane_Bridge_V1_Heartbeat) -> Heartbeat { Heartbeat(sentAt: Date(timeIntervalSince1970: Double(value.sentUnixMillis) / 1_000)) }
    private static func encode(_ value: WirePairingChallenge) -> Northpane_Bridge_V1_PairingChallenge { var result = Northpane_Bridge_V1_PairingChallenge(); result.challengeID = value.challengeID.uuidString; result.hostID = value.hostID.rawValue.uuidString; result.nonce = value.nonce; result.expiresUnixMillis = Int64(value.expiresAt.timeIntervalSince1970 * 1_000); return result }
    private static func decode(_ value: Northpane_Bridge_V1_PairingChallenge) throws -> WirePairingChallenge { guard let challenge = UUID(uuidString: value.challengeID), let host = UUID(uuidString: value.hostID) else { throw Problem.malformedFrame }; return WirePairingChallenge(challengeID: challenge, hostID: HostID(rawValue: host), nonce: value.nonce, expiresAt: Date(timeIntervalSince1970: Double(value.expiresUnixMillis) / 1_000)) }
    private static func encode(_ value: WirePairingProof) -> Northpane_Bridge_V1_PairingProof { var result = Northpane_Bridge_V1_PairingProof(); result.clientDeviceID = value.clientDeviceID.rawValue.uuidString; result.challengeID = value.challengeID.uuidString; result.publicKey = value.publicKey; result.signature = value.signature; return result }
    private static func decode(_ value: Northpane_Bridge_V1_PairingProof) throws -> WirePairingProof { guard let device = UUID(uuidString: value.clientDeviceID), let challenge = UUID(uuidString: value.challengeID) else { throw Problem.malformedFrame }; return WirePairingProof(clientDeviceID: ClientDeviceID(rawValue: device), challengeID: challenge, publicKey: value.publicKey, signature: value.signature) }
    private static func encode(_ value: WirePairingAccepted) -> Northpane_Bridge_V1_PairingAccepted { var result = Northpane_Bridge_V1_PairingAccepted(); result.clientDeviceID = value.clientDeviceID.rawValue.uuidString; result.observation = value.observation; result.standardControl = value.standardControl; return result }
    private static func decode(_ value: Northpane_Bridge_V1_PairingAccepted) throws -> WirePairingAccepted { guard let device = UUID(uuidString: value.clientDeviceID) else { throw Problem.malformedFrame }; return WirePairingAccepted(clientDeviceID: ClientDeviceID(rawValue: device), observation: value.observation, standardControl: value.standardControl) }

    private static func encode(_ value: ResourceCommand) throws -> Northpane_Bridge_V1_ResourceCommand {
        var result = Northpane_Bridge_V1_ResourceCommand()
        result.kind = encode(value.kind); result.commandID = value.commandID.uuidString; result.workspaceID = value.workspaceID
        result.resourceID = value.resourceID?.uuidString ?? ""; result.expectedRevision = try uint64(value.expectedRevision)
        result.path = value.path; result.origin = value.origin; result.title = value.title; result.healthPath = value.healthPath
        result.ttlSeconds = try uint64(value.ttlSeconds); result.mediaType = value.mediaType; result.method = value.method
        result.headers = value.headers.map(encode); result.body = value.body; result.idempotencyKey = value.idempotencyKey
        result.offset = try uint64(value.offset); result.length = try uint64(value.length); result.streamID = value.streamID?.uuidString ?? ""; result.paneID = value.paneID; result.query = value.query
        result.targetID = value.targetID
        return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_ResourceCommand) throws -> ResourceCommand {
        guard let commandID = UUID(uuidString: value.commandID) else { throw Problem.malformedFrame }
        let resourceID = value.resourceID.isEmpty ? nil : UUID(uuidString: value.resourceID)
        let streamID = value.streamID.isEmpty ? nil : UUID(uuidString: value.streamID)
        if (!value.resourceID.isEmpty && resourceID == nil) || (!value.streamID.isEmpty && streamID == nil) { throw Problem.malformedFrame }
        return ResourceCommand(kind: try decode(value.kind), commandID: commandID, workspaceID: value.workspaceID, resourceID: resourceID,
            expectedRevision: try integer(value.expectedRevision), path: value.path, origin: value.origin, title: value.title,
            healthPath: value.healthPath, ttlSeconds: try integer(value.ttlSeconds), mediaType: value.mediaType,
            method: value.method, headers: value.headers.map(decode), body: value.body, idempotencyKey: value.idempotencyKey,
            offset: try integer(value.offset), length: try integer(value.length), streamID: streamID, paneID: value.paneID,
            query: value.query, targetID: value.targetID)
    }
    private static func encode(_ value: HTTPHeader) -> Northpane_Bridge_V1_HTTPHeader { var result = Northpane_Bridge_V1_HTTPHeader(); result.name = value.name; result.value = value.value; return result }
    private static func decode(_ value: Northpane_Bridge_V1_HTTPHeader) -> HTTPHeader { HTTPHeader(name: value.name, value: value.value) }
    private static func encode(_ value: ResourceDescriptor) throws -> Northpane_Bridge_V1_ResourceDescriptor {
        var result = Northpane_Bridge_V1_ResourceDescriptor(); result.kind = encode(value.kind); result.resourceID = value.resourceID.uuidString
        result.workspaceID = value.workspaceID; result.revision = try uint64(value.revision); result.title = value.title; result.mediaType = value.mediaType
        result.entrypoint = value.entrypoint; result.expiresUnixMillis = Int64(value.expiresAt.timeIntervalSince1970 * 1_000)
        result.healthy = value.healthy; result.viewerAvailability = encode(value.viewerAvailability); result.paneID = value.paneID; return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_ResourceDescriptor) throws -> ResourceDescriptor {
        guard let id = UUID(uuidString: value.resourceID) else { throw Problem.malformedFrame }
        return ResourceDescriptor(kind: try decode(value.kind), resourceID: id, workspaceID: value.workspaceID, revision: try integer(value.revision),
            title: value.title, mediaType: value.mediaType, entrypoint: value.entrypoint,
            expiresAt: Date(timeIntervalSince1970: Double(value.expiresUnixMillis) / 1_000), healthy: value.healthy,
            viewerAvailability: try decode(value.viewerAvailability), paneID: value.paneID)
    }
    private static func encode(_ value: ResourceResult) throws -> Northpane_Bridge_V1_ResourceResult {
        var result = Northpane_Bridge_V1_ResourceResult(); result.commandID = value.commandID.uuidString
        result.resources = try value.resources.map(encode); result.statusCode = try uint32(value.statusCode); result.headers = value.headers.map(encode)
        result.body = value.body; result.relativePath = value.relativePath; result.mediaType = value.mediaType; result.deleted = value.deleted
        result.totalBytes = try uint64(value.totalBytes); result.files = try value.files.map(encode); result.streamID = value.streamID?.uuidString ?? ""
        result.sequence = try uint64(value.sequence); result.isFinal = value.isFinal; result.isText = value.isText
        result.pathHits = try value.pathHits.map(encode); result.truncated = value.truncated
        result.captureTargets = try value.captureTargets.map(encode); return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_ResourceResult) throws -> ResourceResult {
        guard let command = UUID(uuidString: value.commandID) else { throw Problem.malformedFrame }
        let streamID = value.streamID.isEmpty ? nil : UUID(uuidString: value.streamID)
        if !value.streamID.isEmpty, streamID == nil { throw Problem.malformedFrame }
        return ResourceResult(commandID: command, resources: try value.resources.map(decode), statusCode: try integer(value.statusCode),
            headers: value.headers.map(decode), body: value.body, relativePath: value.relativePath, mediaType: value.mediaType, deleted: value.deleted,
            totalBytes: try integer(value.totalBytes), files: try value.files.map(decode), streamID: streamID,
            sequence: try integer(value.sequence), isFinal: value.isFinal, isText: value.isText,
            pathHits: try value.pathHits.map(decode), truncated: value.truncated,
            captureTargets: try value.captureTargets.map(decode))
    }
    private static func encode(_ value: ResourceFile) throws -> Northpane_Bridge_V1_ResourceFile { var result = Northpane_Bridge_V1_ResourceFile(); result.relativePath = value.relativePath; result.byteCount = try uint64(value.byteCount); result.contentDigest = value.contentDigest; return result }
    private static func decode(_ value: Northpane_Bridge_V1_ResourceFile) throws -> ResourceFile { ResourceFile(relativePath: value.relativePath, byteCount: try integer(value.byteCount), contentDigest: value.contentDigest) }
    private static func encode(_ value: ResourcePathHit) throws -> Northpane_Bridge_V1_ResourcePathHit {
        var result = Northpane_Bridge_V1_ResourcePathHit(); result.path = value.path; result.relativePath = value.relativePath
        result.rootLabel = value.rootLabel; result.isDirectory = value.isDirectory; result.byteCount = try uint64(value.byteCount)
        // Zero means "unknown": a Host that cannot stat an entry still reports the name.
        result.modifiedUnixMillis = value.modified.map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0
        return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_ResourcePathHit) throws -> ResourcePathHit {
        ResourcePathHit(path: value.path, relativePath: value.relativePath, rootLabel: value.rootLabel,
            isDirectory: value.isDirectory, byteCount: try integer(value.byteCount),
            modified: value.modifiedUnixMillis == 0 ? nil : Date(timeIntervalSince1970: Double(value.modifiedUnixMillis) / 1_000))
    }

    private static func encode(_ value: ResourceCaptureTarget) throws -> Northpane_Bridge_V1_ResourceCaptureTarget {
        var result = Northpane_Bridge_V1_ResourceCaptureTarget(); result.id = value.id; result.application = value.application; result.title = value.title
        result.kind = switch value.kind { case .display: .captureTargetDisplay; case .window: .captureTargetWindow }
        result.width = try uint32(value.width); result.height = try uint32(value.height); result.isFrontmost = value.isFrontmost
        return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_ResourceCaptureTarget) throws -> ResourceCaptureTarget {
        let kind: ResourceCaptureTargetKind = switch value.kind { case .captureTargetDisplay: .display; case .captureTargetWindow: .window; default: throw Problem.malformedFrame }
        return ResourceCaptureTarget(id: value.id, kind: kind, application: value.application, title: value.title,
            width: try integer(value.width), height: try integer(value.height), isFrontmost: value.isFrontmost)
    }

    private static func encode(_ value: AuthorizationCommand) throws -> Northpane_Bridge_V1_AuthorizationCommand {
        var result = Northpane_Bridge_V1_AuthorizationCommand(); result.kind = encode(value.kind); result.commandID = value.commandID.uuidString
        result.requestID = value.requestID?.uuidString ?? ""; result.expectedRevision = try uint64(value.expectedRevision)
        result.hostname = value.hostname; result.scopes = value.scopes; result.provenance = value.provenance; return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_AuthorizationCommand) throws -> AuthorizationCommand {
        guard let commandID = UUID(uuidString: value.commandID) else { throw Problem.malformedFrame }
        let requestID = value.requestID.isEmpty ? nil : UUID(uuidString: value.requestID)
        if !value.requestID.isEmpty, requestID == nil { throw Problem.malformedFrame }
        return AuthorizationCommand(kind: try decode(value.kind), commandID: commandID, requestID: requestID,
            expectedRevision: try integer(value.expectedRevision), hostname: value.hostname, scopes: value.scopes, provenance: value.provenance)
    }
    private static func encode(_ value: AuthorizationRequestDescriptor) throws -> Northpane_Bridge_V1_AuthorizationRequestDescriptor {
        var result = Northpane_Bridge_V1_AuthorizationRequestDescriptor(); result.requestID = value.requestID.uuidString
        result.revision = try uint64(value.revision); result.state = encode(value.state); result.hostID = value.hostID.rawValue.uuidString
        result.processID = Int64(value.processID); result.hostname = value.hostname; result.scopes = value.scopes; result.provenance = value.provenance
        result.createdUnixMillis = Int64(value.createdAt.timeIntervalSince1970 * 1_000); result.expiresUnixMillis = Int64(value.expiresAt.timeIntervalSince1970 * 1_000)
        result.userCode = value.userCode; result.verificationURL = value.verificationURL?.absoluteString ?? ""; result.account = value.account; result.problemCode = value.problemCode
        return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_AuthorizationRequestDescriptor) throws -> AuthorizationRequestDescriptor {
        guard let requestID = UUID(uuidString: value.requestID), let hostID = UUID(uuidString: value.hostID),
              let processID = Int32(exactly: value.processID) else { throw Problem.malformedFrame }
        let url = value.verificationURL.isEmpty ? nil : URL(string: value.verificationURL)
        if !value.verificationURL.isEmpty, url == nil { throw Problem.malformedFrame }
        return AuthorizationRequestDescriptor(requestID: requestID, revision: try integer(value.revision), state: try decode(value.state),
            hostID: HostID(rawValue: hostID), processID: processID, hostname: value.hostname, scopes: value.scopes, provenance: value.provenance,
            createdAt: Date(timeIntervalSince1970: Double(value.createdUnixMillis) / 1_000),
            expiresAt: Date(timeIntervalSince1970: Double(value.expiresUnixMillis) / 1_000), userCode: value.userCode,
            verificationURL: url, account: value.account, problemCode: value.problemCode)
    }
    private static func encode(_ value: AuthorizationResult) throws -> Northpane_Bridge_V1_AuthorizationResult {
        var result = Northpane_Bridge_V1_AuthorizationResult(); result.commandID = value.commandID.uuidString; result.requests = try value.requests.map(encode); return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_AuthorizationResult) throws -> AuthorizationResult {
        guard let commandID = UUID(uuidString: value.commandID) else { throw Problem.malformedFrame }
        return AuthorizationResult(commandID: commandID, requests: try value.requests.map(decode))
    }

    private static func encode(_ value: NotificationRouteCommand) throws -> Northpane_Bridge_V1_NotificationRouteCommand {
        var result = Northpane_Bridge_V1_NotificationRouteCommand(); result.kind = encode(value.kind)
        result.commandID = value.commandID.uuidString; result.routeID = value.routeID?.uuidString ?? ""
        result.encryptionPublicKey = value.encryptionPublicKey; result.publisherCapability = value.publisherCapability
        result.gatewayURL = value.gatewayURL?.absoluteString ?? ""
        if let expiresAt = value.expiresAt { result.expiresUnixMillis = Int64(expiresAt.timeIntervalSince1970 * 1_000) }
        return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_NotificationRouteCommand) throws -> NotificationRouteCommand {
        guard let commandID = UUID(uuidString: value.commandID) else { throw Problem.malformedFrame }
        let routeID = value.routeID.isEmpty ? nil : UUID(uuidString: value.routeID)
        if !value.routeID.isEmpty, routeID == nil { throw Problem.malformedFrame }
        let gatewayURL = value.gatewayURL.isEmpty ? nil : URL(string: value.gatewayURL)
        if !value.gatewayURL.isEmpty, gatewayURL == nil { throw Problem.malformedFrame }
        return NotificationRouteCommand(kind: try decode(value.kind), commandID: commandID, routeID: routeID,
            encryptionPublicKey: value.encryptionPublicKey, publisherCapability: value.publisherCapability,
            gatewayURL: gatewayURL, expiresAt: value.expiresUnixMillis == 0 ? nil : Date(timeIntervalSince1970: Double(value.expiresUnixMillis) / 1_000))
    }
    private static func encode(_ value: NotificationRouteDescriptor) -> Northpane_Bridge_V1_NotificationRouteDescriptor {
        var result = Northpane_Bridge_V1_NotificationRouteDescriptor(); result.routeID = value.routeID.uuidString
        result.clientDeviceID = value.clientDeviceID.rawValue.uuidString; result.gatewayURL = value.gatewayURL.absoluteString
        result.expiresUnixMillis = Int64(value.expiresAt.timeIntervalSince1970 * 1_000)
        result.lastUsedUnixMillis = Int64(value.lastUsedAt.timeIntervalSince1970 * 1_000)
        if let revokedAt = value.revokedAt { result.revokedUnixMillis = Int64(revokedAt.timeIntervalSince1970 * 1_000) }
        return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_NotificationRouteDescriptor) throws -> NotificationRouteDescriptor {
        guard let routeID = UUID(uuidString: value.routeID), let deviceID = UUID(uuidString: value.clientDeviceID),
              let gatewayURL = URL(string: value.gatewayURL), value.expiresUnixMillis > 0, value.lastUsedUnixMillis > 0 else { throw Problem.malformedFrame }
        return NotificationRouteDescriptor(routeID: routeID, clientDeviceID: .init(rawValue: deviceID), gatewayURL: gatewayURL,
            expiresAt: Date(timeIntervalSince1970: Double(value.expiresUnixMillis) / 1_000),
            lastUsedAt: Date(timeIntervalSince1970: Double(value.lastUsedUnixMillis) / 1_000),
            revokedAt: value.revokedUnixMillis == 0 ? nil : Date(timeIntervalSince1970: Double(value.revokedUnixMillis) / 1_000))
    }
    private static func encode(_ value: NotificationRouteResult) throws -> Northpane_Bridge_V1_NotificationRouteResult {
        var result = Northpane_Bridge_V1_NotificationRouteResult(); result.commandID = value.commandID.uuidString
        result.routes = value.routes.map(encode); return result
    }
    private static func decode(_ value: Northpane_Bridge_V1_NotificationRouteResult) throws -> NotificationRouteResult {
        guard let commandID = UUID(uuidString: value.commandID) else { throw Problem.malformedFrame }
        return NotificationRouteResult(commandID: commandID, routes: try value.routes.map(decode))
    }

    private static func encode(_ value: Capability) -> Northpane_Bridge_V1_Capability { switch value { case .observeRuntime: .observeRuntime; case .terminalObserve: .terminalObserve; case .terminalControl: .terminalControl; case .attention: .attention; case .artifactPublication: .artifactPublication; case .preview: .preview; case .authorizationBroker: .authorizationBroker; case .notifications: .notifications } }
    private static func decode(_ value: Northpane_Bridge_V1_Capability) throws -> Capability { switch value { case .observeRuntime: .observeRuntime; case .terminalObserve: .terminalObserve; case .terminalControl: .terminalControl; case .attention: .attention; case .artifactPublication: .artifactPublication; case .preview: .preview; case .authorizationBroker: .authorizationBroker; case .notifications: .notifications; default: throw Problem.malformedFrame } }
    private static func encode(_ value: ProblemLocus) -> Northpane_Bridge_V1_ProblemLocus { switch value { case .client: .client; case .transport: .transport; case .bridge: .bridge; case .herdr: .herdr; case .managedService: .managedService } }
    private static func decode(_ value: Northpane_Bridge_V1_ProblemLocus) throws -> ProblemLocus { switch value { case .client: .client; case .transport: .transport; case .bridge: .bridge; case .herdr: .herdr; case .managedService: .managedService; default: throw Problem.malformedFrame } }
    private static func encode(_ value: RetryClass) -> Northpane_Bridge_V1_RetryClass { switch value { case .never: .never; case .afterUserAction: .afterUserAction; case .afterReconnect: .afterReconnect; case .afterRefresh: .afterRefresh } }
    private static func decode(_ value: Northpane_Bridge_V1_RetryClass) throws -> RetryClass { switch value { case .never: .never; case .afterUserAction: .afterUserAction; case .afterReconnect: .afterReconnect; case .afterRefresh: .afterRefresh; default: throw Problem.malformedFrame } }
    private static func encode(_ value: OperationPhase) -> Northpane_Bridge_V1_OperationPhase { switch value { case .handshake: .handshake; case .trust: .trust; case .pairing: .pairing; case .discovery: .discovery; case .compatibility: .compatibility; case .snapshot: .snapshot; case .events: .events; case .mutation: .mutation; case .terminal: .terminal; case .resource: .resource; case .service: .service } }
    private static func decodeOptional(_ value: Northpane_Bridge_V1_OperationPhase) throws -> OperationPhase? { if value == .unspecified { return nil }; return try decode(value) }
    private static func decode(_ value: Northpane_Bridge_V1_OperationPhase) throws -> OperationPhase { switch value { case .handshake: .handshake; case .trust: .trust; case .pairing: .pairing; case .discovery: .discovery; case .compatibility: .compatibility; case .snapshot: .snapshot; case .events: .events; case .mutation: .mutation; case .terminal: .terminal; case .resource: .resource; case .service: .service; default: throw Problem.malformedFrame } }
    private static func encode(_ value: ChannelPurpose) -> Northpane_Bridge_V1_ChannelPurpose { switch value { case .control: .control; case .runtimeEvents: .runtimeEvents; case .terminal: .terminalChannel; case .preview: .previewChannel; case .artifact: .artifactChannel; case .authorization: .authorizationChannel; case .notification: .notificationChannel } }
    private static func decode(_ value: Northpane_Bridge_V1_ChannelPurpose) throws -> ChannelPurpose { switch value { case .control: .control; case .runtimeEvents: .runtimeEvents; case .terminalChannel: .terminal; case .previewChannel: .preview; case .artifactChannel: .artifact; case .authorizationChannel: .authorization; case .notificationChannel: .notification; default: throw Problem.malformedFrame } }
    private static func encode(_ value: WireMutationOutcome) -> Northpane_Bridge_V1_MutationOutcome { switch value { case .applied: .applied; case .rejected: .rejected; case .notApplied: .notApplied } }
    private static func decode(_ value: Northpane_Bridge_V1_MutationOutcome) throws -> WireMutationOutcome { switch value { case .applied: .applied; case .rejected: .rejected; case .notApplied: .notApplied; default: throw Problem.malformedFrame } }
    private static func encode(_ value: WorkspaceAgentKind) -> Northpane_Bridge_V1_WorkspaceAgentKind { switch value { case .shell: .workspaceAgentShell; case .codex: .workspaceAgentCodex; case .claude: .workspaceAgentClaude; case .openCode: .workspaceAgentOpencode } }
    private static func decode(_ value: Northpane_Bridge_V1_WorkspaceAgentKind) throws -> WorkspaceAgentKind { switch value { case .workspaceAgentUnspecified, .workspaceAgentShell: .shell; case .workspaceAgentCodex: .codex; case .workspaceAgentClaude: .claude; case .workspaceAgentOpencode: .openCode; default: throw Problem.malformedFrame } }
    private static func encode(_ value: TerminalAttachMode) -> Northpane_Bridge_V1_TerminalAttachMode { switch value { case .observe: .terminalAttachObserve; case .control: .terminalAttachControl; case .takeover: .terminalAttachTakeover } }
    private static func decode(_ value: Northpane_Bridge_V1_TerminalAttachMode) throws -> TerminalAttachMode { switch value { case .terminalAttachObserve: .observe; case .terminalAttachControl: .control; case .terminalAttachTakeover: .takeover; default: throw Problem.malformedFrame } }
    private static func encode(_ value: ResourceCommandKind) -> Northpane_Bridge_V1_ResourceCommandKind { switch value { case .listResources: .listResources; case .registerPreview: .registerPreview; case .updatePreview: .updatePreview; case .closePreview: .closePreview; case .fetchPreviewHTTP: .fetchPreviewHTTP; case .publishArtifact: .publishArtifact; case .readArtifact: .readArtifact; case .deleteArtifact: .deleteArtifact; case .listArtifactEntries: .listArtifactEntries; case .streamPreviewHTTP: .streamPreviewHTTP; case .openPreviewWebSocket: .openPreviewWebsocket; case .sendPreviewWebSocket: .sendPreviewWebsocket; case .closePreviewWebSocket: .closePreviewWebsocket; case .readWorkspaceFile: .readWorkspaceFile; case .searchWorkspacePaths: .searchWorkspacePaths; case .listScreenCaptureTargets: .listScreenCaptureTargets; case .captureScreen: .captureScreen; case .stagePastedFile: .stagePastedFile } }
    private static func decode(_ value: Northpane_Bridge_V1_ResourceCommandKind) throws -> ResourceCommandKind { switch value { case .listResources: .listResources; case .registerPreview: .registerPreview; case .updatePreview: .updatePreview; case .closePreview: .closePreview; case .fetchPreviewHTTP: .fetchPreviewHTTP; case .publishArtifact: .publishArtifact; case .readArtifact: .readArtifact; case .deleteArtifact: .deleteArtifact; case .listArtifactEntries: .listArtifactEntries; case .streamPreviewHTTP: .streamPreviewHTTP; case .openPreviewWebsocket: .openPreviewWebSocket; case .sendPreviewWebsocket: .sendPreviewWebSocket; case .closePreviewWebsocket: .closePreviewWebSocket; case .readWorkspaceFile: .readWorkspaceFile; case .searchWorkspacePaths: .searchWorkspacePaths; case .listScreenCaptureTargets: .listScreenCaptureTargets; case .captureScreen: .captureScreen; case .stagePastedFile: .stagePastedFile; default: throw Problem.malformedFrame } }
    private static func encode(_ value: ResourceKind) -> Northpane_Bridge_V1_ResourceKind { switch value { case .preview: .previewResource; case .artifact: .artifactResource } }
    private static func decode(_ value: Northpane_Bridge_V1_ResourceKind) throws -> ResourceKind { switch value { case .previewResource: .preview; case .artifactResource: .artifact; default: throw Problem.malformedFrame } }
    private static func encode(_ value: ViewerAvailability) -> Northpane_Bridge_V1_ViewerAvailability { switch value { case .available: .viewerAvailable; case .none: .viewerNone; case .unknown: .viewerUnknown } }
    private static func decode(_ value: Northpane_Bridge_V1_ViewerAvailability) throws -> ViewerAvailability { switch value { case .viewerAvailable: .available; case .viewerNone: .none; case .viewerUnknown: .unknown; default: throw Problem.malformedFrame } }
    private static func encode(_ value: AuthorizationCommandKind) -> Northpane_Bridge_V1_AuthorizationCommandKind { switch value { case .create: .createAuthorization; case .list: .listAuthorizations; case .approve: .approveAuthorization; case .status: .authorizationStatus; case .cancel: .cancelAuthorization } }
    private static func decode(_ value: Northpane_Bridge_V1_AuthorizationCommandKind) throws -> AuthorizationCommandKind { switch value { case .createAuthorization: .create; case .listAuthorizations: .list; case .approveAuthorization: .approve; case .authorizationStatus: .status; case .cancelAuthorization: .cancel; default: throw Problem.malformedFrame } }
    private static func encode(_ value: AuthorizationWireState) -> Northpane_Bridge_V1_AuthorizationWireState { switch value { case .pending: .authorizationPending; case .awaitingUser: .authorizationAwaitingUser; case .polling: .authorizationPolling; case .completed: .authorizationCompleted; case .cancelled: .authorizationCancelled; case .expired: .authorizationExpired; case .failed: .authorizationFailed } }
    private static func decode(_ value: Northpane_Bridge_V1_AuthorizationWireState) throws -> AuthorizationWireState { switch value { case .authorizationPending: .pending; case .authorizationAwaitingUser: .awaitingUser; case .authorizationPolling: .polling; case .authorizationCompleted: .completed; case .authorizationCancelled: .cancelled; case .authorizationExpired: .expired; case .authorizationFailed: .failed; default: throw Problem.malformedFrame } }
    private static func encode(_ value: NotificationRouteCommandKind) -> Northpane_Bridge_V1_NotificationRouteCommandKind { switch value { case .put: .putNotificationRoute; case .list: .listNotificationRoutes; case .revoke: .revokeNotificationRoute; case .deleteAll: .deleteAllNotificationRoutes } }
    private static func decode(_ value: Northpane_Bridge_V1_NotificationRouteCommandKind) throws -> NotificationRouteCommandKind { switch value { case .putNotificationRoute: .put; case .listNotificationRoutes: .list; case .revokeNotificationRoute: .revoke; case .deleteAllNotificationRoutes: .deleteAll; default: throw Problem.malformedFrame } }

    private static func uint32(_ value: Int) throws -> UInt32 { guard let result = UInt32(exactly: value) else { throw Problem.malformedFrame }; return result }
    private static func uint64(_ value: Int) throws -> UInt64 { guard let result = UInt64(exactly: value) else { throw Problem.malformedFrame }; return result }
    private static func integer(_ value: UInt32) throws -> Int { guard let result = Int(exactly: value) else { throw Problem.malformedFrame }; return result }
    private static func integer(_ value: UInt64) throws -> Int { guard let result = Int(exactly: value) else { throw Problem.malformedFrame }; return result }
}
