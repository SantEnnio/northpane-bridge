import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import NorthpaneDiagnostics
import NorthpaneBridgeCore
import NorthpaneBridgeResources
import NorthpaneConnection
import NorthpaneHerdrIntegration
import NorthpaneProtocol
import NorthpaneSecurity

@main
struct NorthpaneBridge {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        #if os(macOS)
        // The same binary, opened by Launch Services as "Northpane Screen Capture" inside the
        // Host user's screen session, where macOS will name it and let it be allowed.
        if arguments.first == ScreenCapture.Helper.command {
            Foundation.exit(ScreenCapture.runHelper(arguments: Array(arguments.dropFirst())))
        }
        #endif
        if arguments == ["serve", "--local-stdio"] {
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
            let transport = ByteStreamBridgeTransport(kind: .localIPC, input: .standardInput, output: .standardOutput,
                closeHandles: false, verifiedLocalPeerProcessID: getppid(), unpairedLocalObservationAllowed: true)
            do { try await serve(transport, context: BridgeHostContext()) }
            catch { Foundation.exit(1) }
            #elseif os(Windows)
            // The CLI owns both anonymous pipes, so this server is reachable only
            // through its direct child-process channel.
            let transport = ByteStreamBridgeTransport(kind: .localIPC, input: .standardInput, output: .standardOutput,
                closeHandles: false, verifiedLocalPeerProcessID: 0, unpairedLocalObservationAllowed: true)
            do { try await serve(transport, context: BridgeHostContext()) }
            catch { Foundation.exit(1) }
            #else
            Foundation.exit(1)
            #endif
            return
        }
        if arguments.count == 3, arguments[0] == "serve", arguments[1] == "--socket" {
            do {
                let context = try await BridgeHostContext()
                let listener = try UnixSocketListener(path: arguments[2])
                try await listener.run { handle, peerProcessID in
                    let transport = ByteStreamBridgeTransport(kind: .localIPC, input: handle, output: handle, verifiedLocalPeerProcessID: peerProcessID)
                    try? await serve(transport, context: context)
                }
            } catch {
                FileHandle.standardError.write(Data("northpane-bridge: socket server failed\n".utf8))
                Foundation.exit(1)
            }
            return
        }
        if arguments.count == 8,
           arguments[0] == "serve", arguments[1] == "--private",
           arguments[4] == "--certificate", arguments[6] == "--key",
           let port = Int(arguments[3]), (1...65_535).contains(port) {
            do {
                let context = try await BridgeHostContext()
                let server = try PrivateWebSocketServer(
                    host: arguments[2], port: port,
                    certificatePath: arguments[5], privateKeyPath: arguments[7]
                ) { transport in
                    try? await serve(transport, context: context)
                }
                try PrivateEndpointPolicy.validate(.init(
                    enabled: true,
                    bindAddress: arguments[2],
                    port: UInt16(port),
                    certificateFingerprint: server.certificateFingerprint
                ))
                FileHandle.standardError.write(Data("northpane-bridge: private endpoint certificate \(server.certificateFingerprint)\n".utf8))
                try await server.run()
            } catch {
                FileHandle.standardError.write(Data("northpane-bridge: private endpoint failed\n".utf8))
                Foundation.exit(1)
            }
            return
        }
        switch arguments {
        case ["--version"], ["version"]:
            print("northpane-bridge \(NorthpaneRelease.version) (protocol \(BridgeProtocol.major), schema \(BridgeProtocol.schemaRevision))")
        case ["self-check"], ["self-check", "--json"]:
            let report = BridgeSelfCheck(protocolMajor: BridgeProtocol.major, schemaRevision: BridgeProtocol.schemaRevision, capabilityRegistry: CapabilityRegistry.validated(Set(Capability.allCases)).count == Capability.allCases.count ? .passed : .failed, problemCatalog: Set(ProblemCatalog.all.map(\.code)).count == ProblemCatalog.all.count ? .passed : .failed)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(report) else { Foundation.exit(2) }
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
            if report.capabilityRegistry != .passed || report.problemCatalog != .passed { Foundation.exit(1) }
        case ["serve", "--stdio"]:
            do { try await serveStandardIO() }
            catch SystemTransportError.endOfStream { return }
            catch {
                FileHandle.standardError.write(Data("northpane-bridge: serve failed\n".utf8))
                Foundation.exit(1)
            }
        default:
            print("Usage: northpane-bridge [--version | self-check --json | serve --stdio | serve --local-stdio | serve --socket PATH | serve --private ADDRESS PORT --certificate CERT.pem --key KEY.pem]")
        }
    }

    private static func serveStandardIO() async throws {
        try await serve(ByteStreamBridgeTransport(kind: .ssh, input: .standardInput, output: .standardOutput, closeHandles: false), context: BridgeHostContext())
    }

    /// What this Bridge binary is, as opposed to what release it belongs to: the SHA-256 of the
    /// executable running right now, in hex. A Bridge that only fixes how something behaves carries
    /// the same version and the same schema as the one it replaces, so this is the only thing that
    /// tells a client the Bridge it is talking to is not the Bridge it carries. Read once — the
    /// file does not change under a running process — and empty if it cannot be read, which reads
    /// as "cannot tell" rather than as a difference.
    private static let buildID: String = {
        guard let executable = Bundle.main.executableURL,
              let handle = try? FileHandle(forReadingFrom: executable)
        else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }()

    private static func serve(_ transport: any BridgeTransport, context: BridgeHostContext) async throws {
        let authority = context.authority
        let responder = BridgeSessionResponder(authority: authority, capabilities: Set(Capability.allCases),
            bridgeVersion: ProcessInfo.processInfo.environment["NORTHPANE_BRIDGE_VERSION"] ?? NorthpaneRelease.version,
            herdrVersion: await context.detectedHerdrVersion(),
            bridgeBuildID: buildID)
        var authenticatedDevice: ClientDeviceID?
        var presentedDevice: ClientDeviceID?
        let observation = BridgeConnectionObservation()
        var eventSubscription: HerdrEventSubscription?
        let agentStatusSubscriptions = AgentStatusSubscriptions()
        let terminalRegistry = TerminalRegistry()
        let previewTunnels = PreviewTunnelRegistry()
        defer {
            eventSubscription?.stop()
            Task { await agentStatusSubscriptions.stop() }
            Task { await terminalRegistry.stopAll() }
            Task { await previewTunnels.stopAll() }
        }
        while true {
            let request = try await transport.receive()
            let responsePayload: EnvelopePayload
            switch request.payload {
            case let .hello(hello):
                let response = await responder.respond(to: request)
                if case .accepted = response.payload {
                    presentedDevice = hello.clientDeviceID
                    do {
                        try await authority.authorize(deviceID: hello.clientDeviceID, capability: .observeRuntime)
                        authenticatedDevice = hello.clientDeviceID
                    } catch { authenticatedDevice = nil }
                }
                try await transport.send(response)
                continue
            case .pairingChallengeRequest:
                guard presentedDevice != nil else {
                    responsePayload = .problem(Problem(code: "handshake_required", locus: .bridge, retry: .afterReconnect, recoveryAction: "restartHandshake", phase: .handshake))
                    break
                }
                let challenge = await authority.issueChallenge()
                responsePayload = .pairingChallenge(.init(challengeID: challenge.id, hostID: challenge.hostID, nonce: challenge.nonce, expiresAt: challenge.expiresAt))
            case let .pairingProof(proof):
                guard proof.clientDeviceID == presentedDevice else {
                    responsePayload = .problem(Problem(code: "pairing_device_mismatch", locus: .bridge, retry: .afterUserAction, recoveryAction: "restartPairing", phase: .pairing))
                    break
                }
                do {
                    let paired = try await authority.pair(.init(deviceID: proof.clientDeviceID, challengeID: proof.challengeID, publicKey: proof.publicKey, signature: proof.signature), grant: .standard)
                    try await context.persistPairing()
                    try? await context.audit(deviceID: paired.deviceID, category: "pairing", reference: "device", outcome: "applied", reason: "proof-verified")
                    authenticatedDevice = paired.deviceID
                    responsePayload = .pairingAccepted(.init(clientDeviceID: paired.deviceID, observation: paired.grant.grants.contains(.observation), standardControl: paired.grant.grants.contains(.standardControl)))
                } catch {
                    try? await context.audit(deviceID: proof.clientDeviceID, category: "pairing", reference: "device", outcome: "rejected", reason: "invalid-proof")
                    responsePayload = .problem(Problem(code: "pairing_proof_invalid", locus: .bridge, retry: .afterUserAction, recoveryAction: "restartPairing", phase: .pairing))
                }
            case let .observeRuntime(observe):
                let verifiedLocalProcess = (transport as? ByteStreamBridgeTransport)?.verifiedLocalPeerProcessID
                let unpairedLocalObservation = (transport as? ByteStreamBridgeTransport)?.unpairedLocalObservationAllowed == true
                guard authenticatedDevice != nil || (transport.kind == .localIPC && verifiedLocalProcess != nil && unpairedLocalObservation) else {
                    responsePayload = .problem(.unauthorized)
                    break
                }
                eventSubscription?.stop()
                await observation.begin(sessionName: observe.sessionName)
                let subscription = HerdrEventSubscription(sessionName: observe.sessionName)
                do {
                    try await subscription.start(
                        onEvent: {
                            Task {
                                await observation.receivedEvent(
                                    context: context,
                                    sessionName: observe.sessionName,
                                    transport: transport,
                                    connectionID: request.connectionID,
                                    channelID: request.channelID
                                )
                            }
                        },
                        onClose: { error in
                            Task {
                                await observation.subscriptionClosed()
                                let problem = Problem(code: "herdr_event_subscription_closed", locus: .herdr, retry: .afterRefresh, recoveryAction: "requestFullSnapshot", phase: .events)
                                try? await transport.send(Envelope(connectionID: request.connectionID, channelID: request.channelID, payload: .problem(problem)))
                            }
                        }
                    )
                    eventSubscription = subscription
                    // Agent status changes are per-pane subscriptions: keep one connection for the
                    // current pane set and rebuild it whenever the snapshot's panes change.
                    let connectionID = request.connectionID, channelID = request.channelID, sessionName = observe.sessionName
                    await observation.setPaneObserver { paneIDs in
                        await agentStatusSubscriptions.update(paneIDs: paneIDs, sessionName: sessionName, onEvent: {
                            Task {
                                await observation.receivedEvent(context: context, sessionName: sessionName, transport: transport, connectionID: connectionID, channelID: channelID)
                            }
                        })
                    }
                } catch {
                    subscription.stop()
                    guard ProcessInfo.processInfo.environment["NORTHPANE_HERDR_EVENT_SOCKET_OPTIONAL"] == "1" else {
                        responsePayload = .problem(Problem(code: "herdr_event_subscription_failed", locus: .herdr, retry: .afterRefresh, recoveryAction: "restartHerdrOrRetry", phase: .events))
                        break
                    }
                }
                do {
                    let snapshot = try await context.currentSnapshot(sessionName: observe.sessionName)
                    await observation.install(snapshot)
                    responsePayload = .runtimeSnapshot(snapshot)
                    await observation.flushPendingEvent(
                        context: context,
                        sessionName: observe.sessionName,
                        transport: transport,
                        connectionID: request.connectionID,
                        channelID: request.channelID
                    )
                } catch {
                    responsePayload = .problem(Problem(code: "herdr_snapshot_failed", locus: .herdr, retry: .afterRefresh, recoveryAction: "startHerdrOrRetry", phase: .snapshot))
                }
            case let .terminalAttach(attach):
                // A terminal attach needs the same Herdr instance and a pane that still exists;
                // it does NOT need event-log continuity, because the terminal stream opens with a
                // full frame that repaints the screen. Requiring an exact snapshot/event-sequence
                // match made attach lose a race against any active pane: every Herdr event advances
                // the bridge's sequence, so a busy pane was never attachable. The incarnation guard
                // still blocks attaching across a Herdr restart, and pane existence is checked
                // against the bridge's current snapshot.
                guard let device = authenticatedDevice, let snapshot = await observation.snapshot,
                      attach.incarnationID == snapshot.incarnationID,
                      snapshot.panes.contains(where: { $0.id == attach.paneID }) else {
                    responsePayload = .problem(Problem(code: "stale_terminal_attachment", locus: .bridge, retry: .afterRefresh, recoveryAction: "refreshSnapshot", phase: .terminal))
                    break
                }
                let attachmentID = UUID()
                let mode: HerdrTerminalSession.Mode = switch attach.mode { case .observe: .observe; case .control: .control; case .takeover: .takeover }
                let session: HerdrTerminalSession
                let observedSessionName = await observation.sessionName
                do { session = try await context.makeTerminalSession(paneID: attach.paneID, sessionName: observedSessionName, mode: mode) }
                catch {
                    responsePayload = .problem(Problem(code: "herdr_unavailable", locus: .herdr, retry: .afterUserAction, recoveryAction: "installOrStartHerdr", phase: .discovery))
                    break
                }
                await terminalRegistry.add(session, mode: attach.mode, id: attachmentID, paneID: attach.paneID,
                                           columns: attach.columns, rows: attach.rows)
                if attach.mode == .takeover {
                    try? await context.audit(deviceID: device, category: "takeover", reference: "pane", outcome: "applied", reason: "current-observation")
                }
                    try await transport.send(Envelope(protocolMajor: request.protocolMajor, schemaRevision: request.schemaRevision, connectionID: request.connectionID, channelID: request.channelID, messageID: request.messageID, payload: .terminalAttached(TerminalAttached(attachmentID: attachmentID, paneID: attach.paneID, mode: attach.mode, controllerDeviceID: attach.mode == .observe ? nil : device))))
                do {
                    try session.start(columns: attach.columns, rows: attach.rows, onOutput: { bytes in
                        Task {
                            let sequence = await terminalRegistry.nextOutputSequence(for: attachmentID)
                            let frame = TerminalOutputFrame(attachmentID: attachmentID, sequence: sequence, bytes: bytes)
                            try? await transport.send(Envelope(connectionID: request.connectionID, channelID: request.channelID, payload: .terminalOutput(frame)))
                        }
                    }, onClose: { error in
                        Task {
                            // A client release (or a connection teardown) removes the attachment before stopping
                            // the Herdr stream, so the stream ending afterwards is expected and is not reported.
                            // A pane that genuinely closes is reported on the attach channel with `phase: .terminal`;
                            // the client releases only that attachment and keeps the connection.
                            guard await terminalRegistry.remove(attachmentID) != nil else { return }
                            let problem = Problem(code: error == nil ? "terminal_closed" : "terminal_stream_failed", locus: .herdr, retry: .afterRefresh, recoveryAction: "reattachReadOnly", phase: .terminal)
                            try? await transport.send(Envelope(connectionID: request.connectionID, channelID: request.channelID, payload: .problem(problem)))
                        }
                    })
                } catch {
                    _ = await terminalRegistry.remove(attachmentID)
                    try await transport.send(Envelope(protocolMajor: request.protocolMajor, schemaRevision: request.schemaRevision, connectionID: request.connectionID, channelID: request.channelID, messageID: request.messageID, payload: .problem(Problem(code: "terminal_attach_failed", locus: .herdr, retry: .afterRefresh, recoveryAction: "reattachReadOnly", phase: .terminal))))
                }
                continue
            case let .terminalInput(frame):
                guard let entry = await terminalRegistry.entry(frame.attachmentID), entry.mode != .observe else {
                    responsePayload = .problem(Problem(code: "terminal_control_required", locus: .bridge, retry: .afterUserAction, recoveryAction: "acquireControl", phase: .terminal))
                    break
                }
                let prior = entry.acceptedInputSequence
                if frame.sequence <= prior {
                    responsePayload = .terminalAcknowledgement(.init(attachmentID: frame.attachmentID, acceptedThroughSequence: prior))
                } else if frame.sequence == prior + 1 {
                    do {
                        try entry.session.sendInput(frame.bytes)
                        await terminalRegistry.acceptInput(frame.sequence, for: frame.attachmentID)
                        responsePayload = .terminalAcknowledgement(.init(attachmentID: frame.attachmentID, acceptedThroughSequence: frame.sequence))
                    } catch {
                        responsePayload = .problem(Problem(code: "terminal_input_failed", locus: .herdr, retry: .afterRefresh, recoveryAction: "reattachReadOnly", phase: .terminal))
                    }
                } else {
                    responsePayload = .problem(Problem(code: "terminal_input_gap", locus: .bridge, retry: .never, recoveryAction: "discardPendingInput", phase: .terminal))
                }
            case let .terminalResize(resize):
                guard let entry = await terminalRegistry.entry(resize.attachmentID), entry.mode != .observe else {
                    responsePayload = .problem(Problem(code: "terminal_control_required", locus: .bridge, retry: .afterUserAction, recoveryAction: "acquireControl", phase: .terminal))
                    break
                }
                do {
                    try entry.session.resize(columns: resize.columns, rows: resize.rows)
                    await terminalRegistry.setViewport(columns: resize.columns, rows: resize.rows, for: resize.attachmentID)
                    responsePayload = .heartbeat(Heartbeat())
                }
                catch { responsePayload = .problem(Problem(code: "terminal_resize_failed", locus: .herdr, retry: .afterRefresh, recoveryAction: "reattachReadOnly", phase: .terminal)) }
            case let .terminalScroll(scroll):
                // Herdr streams a rendered viewport, so scrollback is paged on the Host. Only a control
                // stream honours the command; observe streams silently ignore it, so require control.
                guard let entry = await terminalRegistry.entry(scroll.attachmentID), entry.mode != .observe else {
                    responsePayload = .problem(Problem(code: "terminal_control_required", locus: .bridge, retry: .afterUserAction, recoveryAction: "acquireControl", phase: .terminal))
                    break
                }
                // Which scrolling a pane understands is something only the Host can say, and it
                // says it here: Herdr reports how many lines it is holding above each pane, and
                // holding none is what an alternate-screen agent looks like. See TerminalScrollRouting.
                let sessionName = await observation.sessionName
                let routing = TerminalScrollRouting.choose(
                    heldOnHost: await context.hostScrollbackLines(paneID: entry.paneID, sessionName: sessionName),
                    paneRunsAnAgent: await observation.snapshot?.panes.first { $0.id == entry.paneID }?.agent != nil)
                do {
                    switch routing {
                    case .hostScrollback:
                        try entry.session.scroll(direction: scroll.direction == .up ? .up : .down, lines: scroll.lines)
                    case .paneWheel:
                        try entry.session.sendInput(TerminalScrollRouting.wheel(scroll.direction, lines: scroll.lines, columns: entry.columns, rows: entry.rows))
                    }
                    responsePayload = .heartbeat(Heartbeat())
                }
                catch { responsePayload = .problem(Problem(code: "terminal_scroll_failed", locus: .herdr, retry: .afterRefresh, recoveryAction: "reattachReadOnly", phase: .terminal)) }
            case let .terminalRelease(release):
                guard let session = await terminalRegistry.remove(release.attachmentID) else {
                    responsePayload = .problem(Problem(code: "terminal_attachment_missing", locus: .bridge, retry: .afterRefresh, recoveryAction: "refreshSnapshot", phase: .terminal))
                    break
                }
                try? session.release(); session.stop()
                responsePayload = .heartbeat(Heartbeat())
            case let .mutation(mutation):
                guard let device = authenticatedDevice, mutation.clientDeviceID == device else {
                    responsePayload = .mutationReceipt(.init(commandID: mutation.commandID, outcome: .rejected, problem: .unauthorized))
                    break
                }
                if let prior = await context.receipt(for: mutation.commandID) {
                    responsePayload = .mutationReceipt(prior)
                    break
                }
                guard mutation.deadline >= Date() else {
                    let receipt = WireMutationReceipt(commandID: mutation.commandID, outcome: .notApplied, problem: .deadlineExceeded)
                    await context.remember(receipt)
                    responsePayload = .mutationReceipt(receipt)
                    break
                }
                if mutation.targetID == "herdr:start" || mutation.targetID.hasPrefix("herdr:start:") {
                    do {
                        guard mutation.capability == .observeRuntime else { throw Problem.unauthorized }
                        try await authority.authorize(deviceID: device, capability: .observeRuntime)
                        let sessionName = mutation.targetID == "herdr:start" ? nil : String(mutation.targetID.dropFirst("herdr:start:".count))
                        try await context.startHerdr(sessionName: sessionName)
                        try? await context.audit(deviceID: device, category: "herdr", reference: "server", outcome: "applied", reason: "client-requested-start")
                        let receipt = WireMutationReceipt(commandID: mutation.commandID, outcome: .applied)
                        await context.remember(receipt)
                        responsePayload = .mutationReceipt(receipt)
                    } catch let problem as Problem {
                        responsePayload = .mutationReceipt(.init(commandID: mutation.commandID, outcome: .rejected, problem: problem))
                    } catch {
                        let problem = Problem(code: "herdr_start_failed", locus: .herdr, retry: .afterUserAction, recoveryAction: "openHerdrGuideOrRetry", phase: .discovery)
                        responsePayload = .mutationReceipt(.init(commandID: mutation.commandID, outcome: .notApplied, problem: problem))
                    }
                    break
                }
                if mutation.targetID == "workspace:create" {
                    do {
                        guard mutation.capability == .terminalControl else { throw Problem.unauthorized }
                        try await authority.authorize(deviceID: device, capability: .terminalControl)
                        guard mutation.workspaceAgentKind == .shell || request.schemaRevision >= 11 else {
                            throw Problem.incompatibleProtocol
                        }
                        let label = mutation.workspaceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                        let directory = mutation.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !label.isEmpty, label.count <= 128,
                              !directory.isEmpty, directory.count <= 1_024,
                              (directory as NSString).isAbsolutePath,
                              !label.contains("\n"), !label.contains("\r"), !label.contains("\0"),
                              !directory.contains("\n"), !directory.contains("\r"), !directory.contains("\0")
                        else { throw Problem.malformedFrame }
                        let created = try await context.createWorkspace(
                            label: label,
                            workingDirectory: directory,
                            agentKind: mutation.workspaceAgentKind,
                            sessionName: await observation.sessionName
                        )
                        try? await context.audit(deviceID: device, category: "workspace", reference: created.workspaceID,
                                                 outcome: "applied", reason: created.agentStartFailed ? "client-requested-create-agent-failed" : "client-requested-create")
                        let launchProblem = created.agentStartFailed
                            ? Problem(code: "workspace_agent_start_failed", locus: .herdr, retry: .afterUserAction,
                                      recoveryAction: "openWorkspaceAndStartAgent", phase: .mutation)
                            : nil
                        let receipt = WireMutationReceipt(commandID: mutation.commandID, outcome: .applied,
                                                          problem: launchProblem, workspaceID: created.workspaceID, paneID: created.paneID,
                                                          workspaceAgentKind: mutation.workspaceAgentKind,
                                                          workspaceAgentStarted: created.agentStarted)
                        await context.remember(receipt)
                        responsePayload = .mutationReceipt(receipt)
                    } catch let problem as Problem {
                        responsePayload = .mutationReceipt(.init(commandID: mutation.commandID, outcome: .rejected, problem: problem))
                    } catch AgentExecutableResolutionError.unavailable {
                        let problem = Problem(code: "workspace_agent_unavailable", locus: .herdr, retry: .afterUserAction,
                                              recoveryAction: "installAgentOrChooseShell", phase: .mutation)
                        responsePayload = .mutationReceipt(.init(commandID: mutation.commandID, outcome: .notApplied, problem: problem,
                                                                 workspaceAgentKind: mutation.workspaceAgentKind))
                    } catch {
                        let problem = Problem(code: "workspace_create_failed", locus: .herdr, retry: .afterUserAction,
                                              recoveryAction: "reviewWorkspaceAndRetry", phase: .mutation)
                        responsePayload = .mutationReceipt(.init(commandID: mutation.commandID, outcome: .notApplied, problem: problem))
                    }
                    break
                }
                if mutation.targetID.hasPrefix("workspace:close:") {
                    do {
                        guard request.schemaRevision >= 11 else { throw Problem.incompatibleProtocol }
                        guard mutation.capability == .terminalControl else { throw Problem.unauthorized }
                        try await authority.authorize(deviceID: device, capability: .terminalControl)
                        let workspaceID = String(mutation.targetID.dropFirst("workspace:close:".count))
                        guard workspaceID.range(of: #"^[A-Za-z0-9._:-]{1,128}$"#, options: .regularExpression) != nil else {
                            throw Problem.malformedFrame
                        }
                        guard await observation.snapshot?.workspaces.contains(where: { $0.id == workspaceID }) == true else {
                            throw Problem(code: "workspace_not_found", locus: .herdr, retry: .afterRefresh,
                                          recoveryAction: "refreshSnapshot", phase: .mutation)
                        }
                        try await context.closeWorkspace(workspaceID: workspaceID, sessionName: await observation.sessionName)
                        try? await context.audit(deviceID: device, category: "workspace", reference: workspaceID,
                                                 outcome: "applied", reason: "client-requested-close")
                        let receipt = WireMutationReceipt(commandID: mutation.commandID, outcome: .applied,
                                                          workspaceID: workspaceID)
                        await context.remember(receipt)
                        responsePayload = .mutationReceipt(receipt)
                    } catch let problem as Problem {
                        responsePayload = .mutationReceipt(.init(commandID: mutation.commandID, outcome: .rejected,
                                                                  problem: problem))
                    } catch {
                        let problem = Problem(code: "workspace_close_failed", locus: .herdr, retry: .afterRefresh,
                                              recoveryAction: "refreshWorkspaceAndRetry", phase: .mutation)
                        responsePayload = .mutationReceipt(.init(commandID: mutation.commandID, outcome: .notApplied,
                                                                  problem: problem))
                    }
                    break
                }
                if mutation.targetID == "device:\(device.rawValue.uuidString):grant:authorizationBroker" {
                    do {
                        guard var paired = await authority.allPairedDevices().first(where: { $0.deviceID == device }) else { throw PairingError.revoked }
                        paired.grant.grants.insert(.authorizationBroker)
                        try await authority.updateGrant(paired.grant, for: device)
                        try await context.persistPairing()
                        try? await context.audit(deviceID: device, category: "grant", reference: "authorizationBroker", outcome: "applied", reason: "client-confirmed")
                        let receipt = WireMutationReceipt(commandID: mutation.commandID, outcome: .applied)
                        await context.remember(receipt)
                        responsePayload = .mutationReceipt(receipt)
                    } catch {
                        responsePayload = .mutationReceipt(.init(commandID: mutation.commandID, outcome: .rejected, problem: .unauthorized))
                    }
                    break
                }
                guard mutation.targetID == "device:\(device.rawValue.uuidString):revoke" else {
                    let problem = Problem(code: "unsupported_mutation", locus: .bridge, retry: .never, recoveryAction: "updateClientOrBridge", phase: .mutation)
                    let receipt = WireMutationReceipt(commandID: mutation.commandID, outcome: .rejected, problem: problem)
                    await context.remember(receipt)
                    responsePayload = .mutationReceipt(receipt)
                    break
                }
                await authority.revoke(device)
                try await context.persistPairing()
                try? await context.audit(deviceID: device, category: "revocation", reference: "device", outcome: "applied", reason: "client-requested")
                await terminalRegistry.stopAll()
                await observation.subscriptionClosed()
                eventSubscription?.stop()
                eventSubscription = nil
                await agentStatusSubscriptions.stop()
                authenticatedDevice = nil
                let receipt = WireMutationReceipt(commandID: mutation.commandID, outcome: .applied)
                await context.remember(receipt)
                responsePayload = .mutationReceipt(receipt)
            case let .authorizationCommand(command):
                let localProcessID = (transport as? ByteStreamBridgeTransport)?.verifiedLocalPeerProcessID
                do {
                    let requests: [AuthorizationRequestDescriptor]
                    switch command.kind {
                    case .create:
                        guard transport.kind == .localIPC, let localProcessID else { throw Problem.unauthorized }
                        requests = [try await context.authorizationService.create(processID: localProcessID, hostname: command.hostname,
                            scopes: command.scopes, provenance: command.provenance)]
                        try? await context.audit(deviceID: nil, category: "authorization", reference: requests[0].requestID.uuidString, outcome: "created", reason: "verified-local-process")
                    case .list:
                        if let device = authenticatedDevice { try await authority.authorize(deviceID: device, capability: .authorizationBroker) }
                        else if localProcessID == nil { throw Problem.unauthorized }
                        requests = await context.authorizationService.list()
                    case .approve:
                        guard let device = authenticatedDevice, let requestID = command.requestID else { throw Problem.unauthorized }
                        try await authority.authorize(deviceID: device, capability: .authorizationBroker)
                        requests = [try await context.authorizationService.approve(id: requestID, expectedRevision: command.expectedRevision)]
                        try? await context.audit(deviceID: device, category: "authorization", reference: requestID.uuidString, outcome: "approved", reason: "revision-confirmed")
                    case .status:
                        guard let requestID = command.requestID else { throw Problem.malformedFrame }
                        if let device = authenticatedDevice {
                            try await authority.authorize(deviceID: device, capability: .authorizationBroker)
                            requests = [try await context.authorizationService.status(id: requestID)]
                        } else if let localProcessID {
                            requests = [try await context.authorizationService.status(id: requestID, processID: localProcessID)]
                        } else { throw Problem.unauthorized }
                    case .cancel:
                        guard let requestID = command.requestID else { throw Problem.malformedFrame }
                        if let device = authenticatedDevice {
                            try await authority.authorize(deviceID: device, capability: .authorizationBroker)
                            requests = [try await context.authorizationService.cancel(id: requestID, expectedRevision: command.expectedRevision)]
                            try? await context.audit(deviceID: device, category: "authorization", reference: requestID.uuidString, outcome: "cancelled", reason: "client-requested")
                        } else if let localProcessID {
                            requests = [try await context.authorizationService.cancel(id: requestID, expectedRevision: command.expectedRevision, processID: localProcessID)]
                        } else { throw Problem.unauthorized }
                    }
                    responsePayload = .authorizationResult(.init(commandID: command.commandID, requests: requests))
                } catch let problem as Problem {
                    responsePayload = .problem(problem)
                } catch {
                    responsePayload = .problem(Problem(code: "authorization_request_rejected", locus: .bridge, retry: .afterUserAction, recoveryAction: "reviewAuthorizationRequest", phase: .service))
                }
            case let .notificationRouteCommand(command):
                do {
                    guard let device = authenticatedDevice else { throw Problem.unauthorized }
                    try await authority.authorize(deviceID: device, capability: .notifications)
                    responsePayload = .notificationRouteResult(try await context.handleNotificationRoute(command, deviceID: device))
                    try? await context.audit(deviceID: device, category: "notification-route", reference: command.routeID?.uuidString ?? "all",
                        outcome: "applied", reason: command.kind.rawValue)
                } catch let problem as Problem {
                    responsePayload = .problem(problem)
                } catch {
                    responsePayload = .problem(Problem(code: "notification_route_rejected", locus: .managedService, retry: .afterUserAction, recoveryAction: "retryNotificationSetup", phase: .service))
                }
            case let .resourceCommand(command):
                let localPublisherProcessID = (transport as? ByteStreamBridgeTransport)?.verifiedLocalPeerProcessID
                let snapshot: WireRuntimeSnapshot
                if let observed = await observation.snapshot, authenticatedDevice != nil {
                    snapshot = observed
                } else if transport.kind == .localIPC, localPublisherProcessID != nil {
                    do { snapshot = try await context.currentSnapshot(sessionName: nil) }
                    catch {
                        responsePayload = .problem(Problem(code: "herdr_snapshot_failed", locus: .herdr, retry: .afterRefresh, recoveryAction: "startHerdrOrRetry", phase: .snapshot))
                        break
                    }
                } else {
                    responsePayload = .problem(.unauthorized)
                    break
                }
                let capability: Capability = switch command.kind {
                case .publishArtifact, .readArtifact, .deleteArtifact, .listArtifactEntries: .artifactPublication
                case .registerPreview, .updatePreview, .closePreview, .fetchPreviewHTTP, .streamPreviewHTTP,
                     .openPreviewWebSocket, .sendPreviewWebSocket, .closePreviewWebSocket: .preview
                case .listResources: .observeRuntime
                // Reading a file the terminal cited is an operator action on the workspace, so it
                // needs the same grant as typing into it. Searching those same roots by name
                // reveals strictly less than reading does, and the answer is normally pasted
                // into the pane, so it is held to the same grant rather than a weaker one.
                case .readWorkspaceFile, .searchWorkspacePaths: .terminalControl
                // A screenshot shows whatever the Host's screen shows, which is more than any
                // file the roots hold: nothing weaker than the grant to type into the pane.
                case .listScreenCaptureTargets, .captureScreen: .terminalControl
                // A pasted file is typed into the pane as a path the agent then reads: the same
                // grant as typing, and nothing weaker.
                case .stagePastedFile: .terminalControl
                }
                do {
                    if let device = authenticatedDevice {
                        try await authority.authorize(deviceID: device, capability: capability)
                    } else if localPublisherProcessID == nil {
                        throw Problem.unauthorized
                    }
                    switch command.kind {
                    case .streamPreviewHTTP:
                        let opened = try await context.openPreviewStream(command)
                        try await transport.send(Envelope(protocolMajor: request.protocolMajor, schemaRevision: request.schemaRevision, connectionID: request.connectionID, channelID: request.channelID, messageID: request.messageID, payload: .resourceResult(opened.initial)))
                        Task {
                            var sequence = 0
                            do {
                                for try await chunk in opened.stream {
                                    let result = ResourceResult(commandID: command.commandID, body: chunk.bytes, streamID: opened.streamID, sequence: sequence, isFinal: chunk.isFinal)
                                    try await transport.send(Envelope(connectionID: request.connectionID, channelID: request.channelID, payload: .resourceResult(result)))
                                    sequence += 1
                                }
                            } catch {
                                let result = ResourceResult(commandID: command.commandID, statusCode: 0, streamID: opened.streamID, sequence: sequence, isFinal: true)
                                try? await transport.send(Envelope(connectionID: request.connectionID, channelID: request.channelID, payload: .resourceResult(result)))
                            }
                        }
                        continue
                    case .openPreviewWebSocket:
                        let opened = try await context.openPreviewWebSocket(command)
                        await previewTunnels.add(opened.tunnel, id: opened.streamID)
                        try await transport.send(Envelope(protocolMajor: request.protocolMajor, schemaRevision: request.schemaRevision, connectionID: request.connectionID, channelID: request.channelID, messageID: request.messageID, payload: .resourceResult(.init(commandID: command.commandID, streamID: opened.streamID))))
                        Task {
                            var sequence = 0
                            do {
                                while true {
                                    let message = try await opened.tunnel.receiveMessage()
                                    try await transport.send(Envelope(connectionID: request.connectionID, channelID: request.channelID, payload: .resourceResult(.init(commandID: command.commandID, body: message.data, streamID: opened.streamID, sequence: sequence, isText: message.isText))))
                                    sequence += 1
                                }
                            } catch {
                                await previewTunnels.remove(opened.streamID)
                                try? await transport.send(Envelope(connectionID: request.connectionID, channelID: request.channelID, payload: .resourceResult(.init(commandID: command.commandID, streamID: opened.streamID, sequence: sequence, isFinal: true))))
                            }
                        }
                        continue
                    case .sendPreviewWebSocket:
                        guard let streamID = command.streamID else { throw Problem.malformedFrame }
                        try await previewTunnels.send(command.body, isText: command.method == "TEXT", id: streamID)
                        responsePayload = .resourceResult(.init(commandID: command.commandID, streamID: streamID))
                    case .closePreviewWebSocket:
                        guard let streamID = command.streamID else { throw Problem.malformedFrame }
                        await previewTunnels.remove(streamID)
                        responsePayload = .resourceResult(.init(commandID: command.commandID, streamID: streamID, isFinal: true))
                    default:
                        responsePayload = .resourceResult(try await context.handleResource(command, transportKind: transport.kind, snapshot: snapshot))
                    }
                } catch let problem as Problem {
                    responsePayload = .problem(problem)
                } catch {
                    responsePayload = .problem(Problem(code: "resource_operation_failed", locus: .bridge, retry: .afterUserAction, recoveryAction: "reviewResourceAndRetry", phase: .resource))
                }
            case let .heartbeat(heartbeat): responsePayload = .heartbeat(heartbeat)
            default: responsePayload = .problem(Problem(code: "unsupported_message", locus: .bridge, retry: .never, recoveryAction: "updateClientOrBridge"))
            }
            try await transport.send(Envelope(protocolMajor: request.protocolMajor, schemaRevision: request.schemaRevision, connectionID: request.connectionID, channelID: request.channelID, messageID: request.messageID, payload: responsePayload))
        }
    }
}

private actor BridgeConnectionObservation {
    private(set) var snapshot: WireRuntimeSnapshot?
    private(set) var sessionName: String?
    private var ready = false
    private var refreshing = false
    private var pendingEvent = false
    private var observedPaneIDs: [String] = []
    private var onPanesChanged: (@Sendable ([String]) async -> Void)?
    /// The last snapshot the client was sent, and when: revision-only churn is rate-limited.
    private var lastPushed: WireRuntimeSnapshot?
    private var lastPushedAt = Date.distantPast
    private var deferredPush: Task<Void, Never>?
    /// Herdr emits dozens of events per second while an agent works (focus, layout and pane
    /// ticks); one snapshot after a short pause covers a whole burst.
    static let coalescingInterval: Duration = .milliseconds(150)
    /// A snapshot whose only change is pane revisions is still published, at most this often,
    /// so a client never keeps a stale revision for long.
    static let revisionOnlyInterval: TimeInterval = 1.0

    func begin(sessionName: String?) {
        snapshot = nil
        self.sessionName = sessionName
        ready = false
        refreshing = false
        pendingEvent = false
        observedPaneIDs = []
        lastPushed = nil
        lastPushedAt = .distantPast
        deferredPush?.cancel()
        deferredPush = nil
    }

    func install(_ snapshot: WireRuntimeSnapshot) async {
        self.snapshot = snapshot
        lastPushed = snapshot
        lastPushedAt = Date()
        ready = true
        await notifyPanesIfChanged()
    }

    func setPaneObserver(_ observer: @escaping @Sendable ([String]) async -> Void) async {
        onPanesChanged = observer
        await notifyPanesIfChanged(force: true)
    }

    private func notifyPanesIfChanged(force: Bool = false) async {
        let paneIDs = (snapshot?.panes.map(\.id) ?? []).sorted()
        guard force || paneIDs != observedPaneIDs else { return }
        observedPaneIDs = paneIDs
        await onPanesChanged?(paneIDs)
    }

    func subscriptionClosed() {
        ready = false
        snapshot = nil
        deferredPush?.cancel()
        deferredPush = nil
    }

    func receivedEvent(
        context: BridgeHostContext,
        sessionName: String?,
        transport: any BridgeTransport,
        connectionID: ConnectionID,
        channelID: ChannelID
    ) async {
        pendingEvent = true
        await refreshIfNeeded(context: context, sessionName: sessionName, transport: transport, connectionID: connectionID, channelID: channelID)
    }

    func flushPendingEvent(
        context: BridgeHostContext,
        sessionName: String?,
        transport: any BridgeTransport,
        connectionID: ConnectionID,
        channelID: ChannelID
    ) async {
        await refreshIfNeeded(context: context, sessionName: sessionName, transport: transport, connectionID: connectionID, channelID: channelID)
    }

    private func deferredRefresh(
        context: BridgeHostContext,
        sessionName: String?,
        transport: any BridgeTransport,
        connectionID: ConnectionID,
        channelID: ChannelID
    ) async {
        deferredPush = nil
        pendingEvent = true
        await refreshIfNeeded(context: context, sessionName: sessionName, transport: transport, connectionID: connectionID, channelID: channelID)
    }

    private func refreshIfNeeded(
        context: BridgeHostContext,
        sessionName: String?,
        transport: any BridgeTransport,
        connectionID: ConnectionID,
        channelID: ChannelID
    ) async {
        guard ready, pendingEvent, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        while pendingEvent, ready {
            // Coalesce the burst: events arriving during the pause are covered by this read.
            try? await Task.sleep(for: Self.coalescingInterval)
            pendingEvent = false
            do {
                let replacement = try await context.currentSnapshot(sessionName: sessionName)
                await context.publishNewAttention(previous: snapshot, replacement: replacement)
                snapshot = replacement
                let shapeChanged = !(lastPushed?.hasSameShape(as: replacement) ?? false)
                let elapsed = Date().timeIntervalSince(lastPushedAt)
                if shapeChanged || elapsed >= Self.revisionOnlyInterval {
                    deferredPush?.cancel()
                    deferredPush = nil
                    try await transport.send(Envelope(connectionID: connectionID, channelID: channelID, payload: .runtimeSnapshot(replacement)))
                    lastPushed = replacement
                    lastPushedAt = Date()
                    await notifyPanesIfChanged()
                } else if deferredPush == nil {
                    // Revision-only churn: publish it once the interval has passed, even if Herdr
                    // goes quiet, so the client's revisions catch up.
                    let wait = max(0.05, Self.revisionOnlyInterval - elapsed)
                    deferredPush = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(wait))
                        guard !Task.isCancelled else { return }
                        await self?.deferredRefresh(context: context, sessionName: sessionName, transport: transport, connectionID: connectionID, channelID: channelID)
                    }
                }
            } catch {
                ready = false
                snapshot = nil
                let problem = Problem(code: "herdr_event_reconciliation_failed", locus: .herdr, retry: .afterRefresh, recoveryAction: "requestFullSnapshot", phase: .events)
                try? await transport.send(Envelope(connectionID: connectionID, channelID: channelID, payload: .problem(problem)))
            }
        }
    }
}

/// One Herdr connection subscribed to `pane.agent_status_changed` for every current pane. Rebuilt
/// when the pane set changes; a refresh is requested right after, so a change that landed between
/// the old and the new subscription is not lost. Missing sockets are tolerated (test harness).
private actor AgentStatusSubscriptions {
    private var current: HerdrEventSubscription?
    private var paneIDs: [String] = []

    func update(paneIDs: [String], sessionName: String?, onEvent: @escaping @Sendable () -> Void) async {
        guard paneIDs != self.paneIDs || current == nil else { return }
        current?.stop()
        current = nil
        self.paneIDs = paneIDs
        guard !paneIDs.isEmpty else { return }
        let subscription = HerdrEventSubscription(sessionName: sessionName, scope: .agentStatus(paneIDs: paneIDs))
        do {
            try await subscription.start(onEvent: onEvent, onClose: { [weak self] _ in Task { await self?.closed(subscription) } })
            current = subscription
            onEvent()
        } catch {
            subscription.stop()
        }
    }

    private func closed(_ subscription: HerdrEventSubscription) {
        guard current === subscription else { return }
        current = nil
        paneIDs = []
    }

    func stop() {
        current?.stop()
        current = nil
        paneIDs = []
    }
}

private struct BridgeSelfCheck: Codable {
    let protocolMajor: Int
    let schemaRevision: Int
    let capabilityRegistry: SelfCheckResult
    let problemCatalog: SelfCheckResult
}

private actor TerminalRegistry {
    struct Entry: Sendable {
        let session: HerdrTerminalSession
        let mode: TerminalAttachMode
        /// The pane behind the attachment: a scroll has to know what it is scrolling.
        let paneID: String
        var columns: Int
        var rows: Int
        var outputSequence: Int
        var acceptedInputSequence: Int
    }

    private var entries: [UUID: Entry] = [:]

    func add(_ session: HerdrTerminalSession, mode: TerminalAttachMode, id: UUID, paneID: String, columns: Int, rows: Int) {
        entries[id] = Entry(session: session, mode: mode, paneID: paneID, columns: columns, rows: rows,
                            outputSequence: 0, acceptedInputSequence: -1)
    }

    func setViewport(columns: Int, rows: Int, for id: UUID) {
        guard var entry = entries[id] else { return }
        entry.columns = columns
        entry.rows = rows
        entries[id] = entry
    }

    func entry(_ id: UUID) -> Entry? { entries[id] }

    func nextOutputSequence(for id: UUID) -> Int {
        guard var entry = entries[id] else { return 0 }
        let sequence = entry.outputSequence
        entry.outputSequence += 1
        entries[id] = entry
        return sequence
    }

    func acceptInput(_ sequence: Int, for id: UUID) {
        guard var entry = entries[id] else { return }
        entry.acceptedInputSequence = sequence
        entries[id] = entry
    }

    func remove(_ id: UUID) -> HerdrTerminalSession? { entries.removeValue(forKey: id)?.session }

    func stopAll() {
        let sessions = entries.values.map(\.session)
        entries.removeAll()
        for session in sessions { try? session.release(); session.stop() }
    }
}

private actor PreviewTunnelRegistry {
    private var tunnels: [UUID: PreviewWebSocketTunnel] = [:]
    func add(_ tunnel: PreviewWebSocketTunnel, id: UUID) { tunnels[id] = tunnel }
    func send(_ data: Data, isText: Bool, id: UUID) async throws {
        guard let tunnel = tunnels[id] else { throw Problem.closedTransport }
        try await tunnel.send(data, isText: isText)
    }
    func remove(_ id: UUID) async { if let tunnel = tunnels.removeValue(forKey: id) { await tunnel.close() } }
    func stopAll() async {
        let active = tunnels.values; tunnels.removeAll()
        for tunnel in active { await tunnel.close() }
    }
}

private struct WorkspaceCreationResult: Sendable {
    let workspaceID: String
    let paneID: String
    let agentStarted: Bool
    let agentStartFailed: Bool
}

private actor BridgeHostContext {
    nonisolated let authority: PairingAuthority
    nonisolated let authorizationService: GitHubAuthorizationService
    private let pairingFile: URL
    private let stateDirectory: URL
    private let previewStore: PreviewStore
    private let notificationRoutes: NotificationRouteRegistry
    private let notificationDeliveries: NotificationDeliveryLedger
    private let notificationPublisher = NotificationPublisher()
    private let notificationGateway = HTTPSNotificationGatewayTransport()
    private let auditLog: HostAuditLog
    private let previewProxy = PreviewProxyClient(maximumResponseBytes: 768 * 1_024)
    private var artifactStores: [String: ArtifactStore] = [:]
    /// Uploads of pasted files in flight, one per idempotency key, and where the finished ones land.
    private var pastedUploads = PastedFileAssembly()
    private let pastedFiles = PastedFileStaging()
    private var runtime: HerdrRuntime?
    private var herdrServerProcess: Process?
    private var herdrExecutable: URL?
    private var cachedHerdrVersion: String?
    private var receipts: [UUID: (receipt: WireMutationReceipt, expiresAt: Date)] = [:]

    init() async throws {
        let environment = ProcessInfo.processInfo.environment
        let stateDirectory = environment["NORTHPANE_STATE_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".northpane", directoryHint: .isDirectory)
        self.stateDirectory = stateDirectory
        #if DEBUG
        let identityStore: any SecureMaterialStore = try DevelopmentFileSecureMaterialStore(
            directory: stateDirectory.appending(path: "secure-material/host-identity", directoryHint: .isDirectory)
        )
        #else
        let identityStore: any SecureMaterialStore = KeychainSecureMaterialStore(service: "it.ambiens.northpane.host-identity")
        #endif
        let stored = try await HostIdentityFile.loadOrCreate(
            at: stateDirectory.appending(path: "host-identity.json"),
            secureStore: identityStore
        )
        pairingFile = stateDirectory.appending(path: "paired-devices.json")
        previewStore = try PreviewStore(fileURL: stateDirectory.appending(path: "resources/previews-v1.json"))
        let notificationKey = Data(SHA256.hash(data: stored.privateKey + Data("northpane-notification-routes-v1".utf8)))
        notificationRoutes = try NotificationRouteRegistry(fileURL: stateDirectory.appending(path: "services/notification-routes-v1.bin"), encryptionKey: notificationKey)
        let deliveryKey = Data(SHA256.hash(data: stored.privateKey + Data("northpane-notification-deliveries-v1".utf8)))
        notificationDeliveries = try NotificationDeliveryLedger(
            fileURL: stateDirectory.appending(path: "services/notification-deliveries-v1.bin"),
            encryptionKey: deliveryKey
        )
        let auditKey = Data(SHA256.hash(data: stored.privateKey + Data("northpane-host-audit-v1".utf8)))
        auditLog = try HostAuditLog(
            fileURL: stateDirectory.appending(path: "audit/host-audit-v1.bin"),
            encryptionKey: auditKey,
            legacyPlaintextURL: stateDirectory.appending(path: "audit/host-audit-v1.json")
        )
        authority = try PairingAuthority(hostID: stored.hostID, rawPrivateKey: stored.privateKey, pairedDevices: HostPairingFile.load(at: pairingFile, hostID: stored.hostID))
        authorizationService = GitHubAuthorizationService(hostID: stored.hostID,
            clientID: environment["NORTHPANE_GITHUB_CLIENT_ID"],
            secureStore: KeychainSecureMaterialStore(service: "it.ambiens.northpane.github"))
    }

    func detectedHerdrVersion() async -> String {
        if let cachedHerdrVersion { return cachedHerdrVersion }
        if let configured = ProcessInfo.processInfo.environment["NORTHPANE_HERDR_VERSION"], !configured.isEmpty {
            cachedHerdrVersion = configured
            return configured
        }
        do {
            let runner = try HerdrProcessRunner()
            herdrExecutable = runner.executableURL
            let output = String(decoding: try await runner.run(arguments: ["--version"]), as: UTF8.self)
            let match = output.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression)
            let version = match.map { String(output[$0]) } ?? "unknown"
            cachedHerdrVersion = version
            return version
        } catch {
            cachedHerdrVersion = "unavailable"
            return "unavailable"
        }
    }

    func currentSnapshot(sessionName: String?) async throws -> WireRuntimeSnapshot {
        if runtime == nil {
            let runner = try HerdrProcessRunner()
            herdrExecutable = runner.executableURL
            runtime = HerdrRuntime(runner: runner)
        }
        return try await runtime!.currentSnapshot(hostID: authority.identity.hostID, sessionName: sessionName)
    }

    func createWorkspace(label: String, workingDirectory: String, agentKind: WorkspaceAgentKind, sessionName: String?) async throws -> WorkspaceCreationResult {
        let resolver = AgentExecutableResolver()
        let detected: DetectedAgentExecutable? = if agentKind == .shell {
            nil
        } else {
            try await Task.detached(priority: .userInitiated) { try resolver.resolve(agentKind) }.value
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw HerdrRuntimeError.commandFailed("the workspace path is not a directory") }
        } else {
            try FileManager.default.createDirectory(atPath: workingDirectory, withIntermediateDirectories: true)
        }
        if runtime == nil {
            let runner = try HerdrProcessRunner()
            herdrExecutable = runner.executableURL
            runtime = HerdrRuntime(runner: runner)
        }
        let created = try await runtime!.createWorkspace(label: label, workingDirectory: workingDirectory,
                                                         sessionName: sessionName)
        guard agentKind != .shell else {
            return WorkspaceCreationResult(workspaceID: created.workspaceID, paneID: created.paneID,
                                           agentStarted: false, agentStartFailed: false)
        }
        do {
            try await runtime!.startAgent(agentKind, executableURL: detected!.url,
                                          name: HerdrAgentNaming.name(workspaceID: created.workspaceID),
                                          paneID: created.paneID, sessionName: sessionName)
            return WorkspaceCreationResult(workspaceID: created.workspaceID, paneID: created.paneID,
                                           agentStarted: true, agentStartFailed: false)
        } catch {
            return WorkspaceCreationResult(workspaceID: created.workspaceID, paneID: created.paneID,
                                           agentStarted: false, agentStartFailed: true)
        }
    }

    func closeWorkspace(workspaceID: String, sessionName: String?) async throws {
        if runtime == nil {
            let runner = try HerdrProcessRunner()
            herdrExecutable = runner.executableURL
            runtime = HerdrRuntime(runner: runner)
        }
        try await runtime!.closeWorkspace(workspaceID: workspaceID, sessionName: sessionName)
    }

    func startHerdr(sessionName: String?) throws {
        if herdrServerProcess?.isRunning == true { return }
        if let sessionName {
            guard sessionName.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil else {
                throw HerdrRuntimeError.commandFailed("invalid session name")
            }
        }
        let executable = try herdrExecutable ?? HerdrProcessRunner().executableURL
        herdrExecutable = executable
        let process = Process()
        process.executableURL = executable
        process.arguments = (sessionName.map { ["--session", $0] } ?? []) + ["server"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        herdrServerProcess = process
    }

    /// Lines Herdr is holding above a pane's viewport; zero when it holds none, and when Herdr has
    /// not been reached at all — in which case the scroll goes to the Host as it always did.
    func hostScrollbackLines(paneID: String, sessionName: String?) async -> Int {
        guard let runtime else { return 0 }
        return await runtime.hostScrollbackLines(paneID: paneID, sessionName: sessionName)
    }

    func makeTerminalSession(paneID: String, sessionName: String?, mode: HerdrTerminalSession.Mode) throws -> HerdrTerminalSession {
        let executable = try herdrExecutable ?? HerdrProcessRunner().executableURL
        herdrExecutable = executable
        return HerdrTerminalSession(executableURL: executable, paneID: paneID, sessionName: sessionName, mode: mode)
    }

    func persistPairing() async throws {
        try HostPairingFile.save(await authority.allPairedDevices(), hostID: authority.identity.hostID, at: pairingFile)
    }

    func receipt(for commandID: UUID, now: Date = Date()) -> WireMutationReceipt? {
        receipts = receipts.filter { $0.value.expiresAt >= now }
        return receipts[commandID]?.receipt
    }

    func remember(_ receipt: WireMutationReceipt, now: Date = Date()) {
        receipts[receipt.commandID] = (receipt, now.addingTimeInterval(24 * 60 * 60))
    }

    func audit(deviceID: ClientDeviceID?, category: String, reference: String, outcome: String, reason: String) async throws {
        try await auditLog.append(.init(deviceID: deviceID, category: category, reference: reference, outcome: outcome, reason: reason))
    }

    func handleNotificationRoute(_ command: NotificationRouteCommand, deviceID: ClientDeviceID) async throws -> NotificationRouteResult {
        switch command.kind {
        case .put:
            guard let id = command.routeID, let gatewayURL = command.gatewayURL, gatewayURL.scheme == "https",
                  let expiresAt = command.expiresAt, expiresAt > Date(), expiresAt <= Date().addingTimeInterval(90 * 24 * 60 * 60),
                  command.encryptionPublicKey.count == 32, command.publisherCapability.count >= 32 else { throw Problem.malformedFrame }
            let route = NotificationRoute(id: id, deviceID: deviceID, encryptionPublicKey: command.encryptionPublicKey,
                publisherCapability: command.publisherCapability, gatewayURL: gatewayURL, expiresAt: expiresAt)
            try await notificationRoutes.put(route)
        case .list:
            break
        case .revoke:
            guard let id = command.routeID else { throw Problem.malformedFrame }
            let route = try await notificationRoutes.route(id: id)
            guard route.deviceID == deviceID else { throw Problem.unauthorized }
            try await notificationRoutes.revoke(id)
        case .deleteAll:
            try await notificationRoutes.removeAll(deviceID: deviceID)
            try await notificationDeliveries.removeAll(deviceID: deviceID)
        }
        let routes = await notificationRoutes.active(deviceID: deviceID).map {
            NotificationRouteDescriptor(routeID: $0.id, clientDeviceID: $0.deviceID, gatewayURL: $0.gatewayURL,
                expiresAt: $0.expiresAt, lastUsedAt: $0.lastUsedAt, revokedAt: $0.revokedAt)
        }
        return NotificationRouteResult(commandID: command.commandID, routes: routes)
    }

    func publishNewAttention(previous: WireRuntimeSnapshot?, replacement: WireRuntimeSnapshot) async {
        let previousBlocked = Set(previous?.panes.filter { $0.agentStatus == "blocked" }.map { "\($0.id):\($0.revision)" } ?? [])
        let additions = replacement.panes.filter { $0.agentStatus == "blocked" && !previousBlocked.contains("\($0.id):\($0.revision)") }
        guard !additions.isEmpty else { return }
        let routes = await notificationRoutes.active()
        let workspaces = Dictionary(uniqueKeysWithValues: replacement.workspaces.map { ($0.id, $0.label) })
        for pane in additions {
            let metadata = AttentionNotificationMetadata(attentionID: pane.id, revision: pane.revision,
                opaqueHostReference: replacement.hostID.rawValue.uuidString,
                agentLabel: pane.agent ?? pane.title,
                workspaceLabel: workspaces[pane.workspaceID] ?? pane.workspaceID)
            for route in routes {
                do {
                    guard try await notificationDeliveries.claim(routeID: route.id, metadata: metadata, deviceID: route.deviceID) else { continue }
                    if let encrypted = try await notificationPublisher.publish(metadata, route: route) {
                        try await notificationGateway.publish(encrypted, using: route)
                        try await notificationRoutes.markUsed(route.id)
                    }
                } catch {
                    // Notification delivery is deliberately best effort and never changes the authoritative runtime path.
                }
            }
        }
    }

    func handleResource(_ command: ResourceCommand, transportKind: TransportKind, snapshot: WireRuntimeSnapshot) async throws -> ResourceResult {
        switch command.kind {
        case .listResources:
            var descriptors = await previewStore.list().map(previewDescriptor)
            for workspace in snapshot.workspaces {
                guard workspaceRoot(workspace, in: snapshot) != nil else { continue }
                let store = try artifactStore(for: workspace, in: snapshot)
                let publications = await store.list()
                for publication in publications { descriptors.append(try await artifactDescriptor(publication, workspaceID: workspace.id, store: store)) }
            }
            return .init(commandID: command.commandID, resources: descriptors.sorted { $0.expiresAt < $1.expiresAt })

        case .registerPreview:
            let pane = command.paneID.isEmpty ? nil : snapshot.panes.first(where: { $0.id == command.paneID })
            let workspaceExists = snapshot.workspaces.contains(where: { $0.id == command.workspaceID })
            // A local workload may publish for its Workspace without Pane provenance. A paired
            // Client may publish only for one current Pane, and that Pane must belong to the named
            // Workspace: this is the explicit "open this Host-local URL as a Preview" gesture.
            guard !command.idempotencyKey.isEmpty, workspaceExists, let origin = URL(string: command.origin),
                  (transportKind == .localIPC || (pane != nil && pane?.workspaceID == command.workspaceID)),
                  (pane == nil || pane?.workspaceID == command.workspaceID)
            else { throw resourceProblem("local_publication_required") }
            let registration = try await previewStore.register(hostID: snapshot.hostID, workspaceID: command.workspaceID,
                paneID: pane?.id, origin: origin, title: command.title.isEmpty ? nil : command.title, healthPath: command.healthPath,
                ttl: TimeInterval(command.ttlSeconds == 0 ? 8 * 60 * 60 : command.ttlSeconds), idempotencyKey: command.idempotencyKey)
            try await previewProxy.probe(store: previewStore, id: registration.id)
            return .init(commandID: command.commandID, resources: [previewDescriptor(try await previewStore.registration(id: registration.id))])

        case .updatePreview:
            guard transportKind == .localIPC, let id = command.resourceID else { throw resourceProblem("local_publication_required") }
            let current = try await previewStore.registration(id: id, requireHealthy: false)
            guard current.revision == command.expectedRevision else { throw resourceProblem("resource_revision_changed") }
            _ = try await previewStore.update(id: id, title: command.title.isEmpty ? nil : command.title, healthPath: command.healthPath,
                ttl: TimeInterval(command.ttlSeconds == 0 ? 8 * 60 * 60 : command.ttlSeconds))
            try await previewProxy.probe(store: previewStore, id: id)
            return .init(commandID: command.commandID, resources: [previewDescriptor(try await previewStore.registration(id: id))])

        case .closePreview:
            guard let id = command.resourceID else { throw resourceProblem("resource_not_found") }
            let current = try await previewStore.registration(id: id, requireHealthy: false)
            guard current.revision == command.expectedRevision else { throw resourceProblem("resource_revision_changed") }
            try await previewStore.close(id)
            return .init(commandID: command.commandID, deleted: true)

        case .fetchPreviewHTTP:
            guard let id = command.resourceID else { throw resourceProblem("resource_not_found") }
            let registration = try await previewStore.registration(id: id)
            guard registration.revision == command.expectedRevision,
                  let target = URL(string: command.path.isEmpty ? "/" : command.path, relativeTo: registration.origin)?.absoluteURL
            else { throw resourceProblem("resource_revision_changed") }
            let headers = try uniqueHeaders(command.headers)
            let response = try await previewProxy.fetch(store: previewStore, id: id, target: target, method: command.method, headers: headers, body: command.body.isEmpty ? nil : command.body)
            return .init(commandID: command.commandID, statusCode: response.statusCode,
                headers: response.headers.map { HTTPHeader(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }, body: response.body)

        case .publishArtifact:
            guard transportKind == .localIPC, !command.idempotencyKey.isEmpty,
                  let workspace = snapshot.workspaces.first(where: { $0.id == command.workspaceID }), let rootPath = workspaceRoot(workspace, in: snapshot),
                  !command.path.isEmpty, !command.path.hasPrefix("/"), !command.mediaType.isEmpty
            else { throw resourceProblem("local_publication_required") }
            let store = try artifactStore(for: workspace, in: snapshot)
            let source = URL(fileURLWithPath: rootPath, isDirectory: true).appending(path: command.path)
            let publication = try await store.publish(file: source, mediaType: command.mediaType, idempotencyKey: command.idempotencyKey,
                requestedRetention: command.ttlSeconds == 0 ? nil : TimeInterval(command.ttlSeconds))
            return .init(commandID: command.commandID, resources: [try await artifactDescriptor(publication, workspaceID: workspace.id, store: store)])

        case .readArtifact:
            guard let id = command.resourceID else { throw resourceProblem("resource_not_found") }
            for workspace in snapshot.workspaces where workspaceRoot(workspace, in: snapshot) != nil {
                let store = try artifactStore(for: workspace, in: snapshot)
                if let publication = try? await store.publication(id: id) {
                    let path = command.path.isEmpty ? try await defaultArtifactEntrypoint(publication, store: store) : command.path
                    let data = try await store.data(for: id, relativePath: publication.isDirectory ? path : (command.path.isEmpty ? nil : path))
                    let offset = command.offset
                    let length = command.length == 0 ? 768 * 1_024 : command.length
                    guard offset >= 0, offset <= data.count, length > 0, length <= 768 * 1_024 else { throw resourceProblem("invalid_artifact_range") }
                    let end = min(data.count, offset + length)
                    return .init(commandID: command.commandID, body: Data(data[offset..<end]), relativePath: path, mediaType: publication.mediaType, totalBytes: data.count)
                }
            }
            throw resourceProblem("resource_not_found")

        case .deleteArtifact:
            guard let id = command.resourceID else { throw resourceProblem("resource_not_found") }
            for workspace in snapshot.workspaces where workspaceRoot(workspace, in: snapshot) != nil {
                let store = try artifactStore(for: workspace, in: snapshot)
                if let publication = try? await store.publication(id: id) {
                    guard publication.revision == command.expectedRevision else { throw resourceProblem("resource_revision_changed") }
                    try await store.remove(id)
                    return .init(commandID: command.commandID, deleted: true)
                }
            }
            throw resourceProblem("resource_not_found")

        case .listArtifactEntries:
            guard let id = command.resourceID else { throw resourceProblem("resource_not_found") }
            for workspace in snapshot.workspaces where workspaceRoot(workspace, in: snapshot) != nil {
                let store = try artifactStore(for: workspace, in: snapshot)
                if (try? await store.publication(id: id)) != nil {
                    let entries = try await store.entries(for: id)
                    return .init(commandID: command.commandID, files: entries.map { .init(relativePath: $0.relativePath, byteCount: $0.byteCount, contentDigest: $0.contentDigest) })
                }
            }
            throw resourceProblem("resource_not_found")
        case .readWorkspaceFile:
            // Confined by construction: resolved against the pane's working directory, served only
            // from inside the workspace root, the user's home or temporary directories, text,
            // image or PDF only, capped, never secret material. Read in chunks like an Artifact.
            let workspace = snapshot.workspaces.first(where: { $0.id == command.workspaceID })
            let rootPath = workspace.flatMap { workspaceRoot($0, in: snapshot) }
            let cwd = snapshot.panes.first(where: { $0.id == command.paneID })?.cwd
            do {
                let file = try WorkspaceFileReader.read(path: command.path, cwd: cwd, workspaceRoot: rootPath)
                let offset = command.offset
                let length = command.length == 0 ? 768 * 1_024 : command.length
                guard offset >= 0, offset <= file.data.count, length > 0, length <= 768 * 1_024 else { throw resourceProblem("invalid_artifact_range") }
                let end = min(file.data.count, offset + length)
                return .init(commandID: command.commandID, body: Data(file.data[offset..<end]), relativePath: file.relativePath, mediaType: file.mediaType, totalBytes: file.data.count, isText: file.isText)
            } catch let error as WorkspaceFileError {
                let code = switch error {
                case .invalidPath: "workspace_file_invalid_path"
                case .outsideWorkspace: "workspace_file_outside_workspace"
                case .symbolicLink: "workspace_file_symbolic_link"
                case .notAFile: "workspace_file_not_a_file"
                case .notFound: "workspace_file_not_found"
                case .tooLarge: "workspace_file_too_large"
                case .notText: "workspace_file_not_text"
                case .secretMaterial: "workspace_file_secret_material"
                }
                throw resourceProblem(code)
            }
        case .searchWorkspacePaths:
            // Names only, from the same roots `readWorkspaceFile` serves contents from, under a
            // walk the Host bounds by depth, time and directories visited.
            let workspace = snapshot.workspaces.first(where: { $0.id == command.workspaceID })
            let rootPath = workspace.flatMap { workspaceRoot($0, in: snapshot) }
            let query = command.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.count >= WorkspacePathSearch.minimumQueryLength else { throw resourceProblem("workspace_search_invalid_query") }
            let limit = command.length == 0 ? WorkspacePathSearch.defaultLimit : min(command.length, WorkspacePathSearch.defaultLimit)
            let results = WorkspacePathSearch.search(query: query, workspaceRoot: rootPath, limit: limit)
            return .init(commandID: command.commandID,
                pathHits: results.hits.map { .init(path: $0.path, relativePath: $0.relativePath, rootLabel: $0.rootLabel, isDirectory: $0.isDirectory, byteCount: $0.byteCount, modified: $0.modified) },
                truncated: results.truncated)
        case .listScreenCaptureTargets:
            #if os(macOS)
            // Names and geometry only: the listing reads no pixel. Missing permission is not an
            // error here — the list still tells the operator what could be captured.
            return .init(commandID: command.commandID, captureTargets: listScreenCaptureTargets(transportKind: transportKind).map {
                .init(id: $0.id, kind: $0.kind == .display ? .display : .window, application: $0.application, title: $0.title,
                      width: $0.width, height: $0.height, isFrontmost: $0.isFrontmost)
            })
            #else
            throw resourceProblem("screen_capture_unavailable")
            #endif
        case .captureScreen:
            #if os(macOS)
            // One image of one listed target, written under the Host user's temporary folder —
            // one of the roots `readWorkspaceFile` serves from — so the path can be handed to an
            // agent and the image read back through the same confined read.
            do {
                let capture = try captureScreen(targetID: command.targetID, transportKind: transportKind)
                return .init(commandID: command.commandID, body: capture.preview, relativePath: capture.path,
                             mediaType: capture.previewMediaType, totalBytes: capture.byteCount)
            } catch let error as ScreenCaptureError {
                switch error {
                case .notPermitted: throw resourceProblem("screen_capture_not_permitted")
                case .unknownTarget: throw resourceProblem("screen_capture_unknown_target")
                case .captureFailed: throw resourceProblem("screen_capture_failed")
                case .noGUISession: throw resourceProblem("screen_capture_no_session")
                case .helperFailed: throw resourceProblem("screen_capture_helper_failed")
                }
            }
            #else
            throw resourceProblem("screen_capture_unavailable")
            #endif
        case .stagePastedFile:
            // Bytes the operator pasted on the Client, reassembled here in order and written under
            // the Host user's temporary folder — a root the confined read serves from, never the
            // workspace — so the path typed into the pane is one the agent reads and the app can
            // read back. The type comes from the bytes, whatever the Client claimed.
            do {
                guard let whole = try pastedUploads.append(uploadID: command.idempotencyKey, offset: command.offset, totalBytes: command.length, chunk: command.body) else {
                    return .init(commandID: command.commandID, totalBytes: command.offset + command.body.count)
                }
                let staged = try pastedFiles.store(whole)
                return .init(commandID: command.commandID, relativePath: staged.path, mediaType: staged.mediaType, totalBytes: staged.byteCount, isFinal: true)
            } catch let error as PastedFileError {
                let code = switch error {
                case .unsupportedType: "pasted_file_unsupported_type"
                case .tooLarge: "pasted_file_too_large"
                case .invalidChunk: "pasted_file_invalid_chunk"
                }
                throw resourceProblem(code)
            }
        case .streamPreviewHTTP, .openPreviewWebSocket, .sendPreviewWebSocket, .closePreviewWebSocket:
            throw resourceProblem("invalid_resource_routing")
        }
    }

    func openPreviewStream(_ command: ResourceCommand) async throws -> (initial: ResourceResult, streamID: UUID, stream: AsyncThrowingStream<PreviewBodyChunk, Error>) {
        guard let id = command.resourceID else { throw resourceProblem("resource_not_found") }
        let registration = try await previewStore.registration(id: id)
        guard registration.revision == command.expectedRevision,
              let target = URL(string: command.path.isEmpty ? "/" : command.path, relativeTo: registration.origin)?.absoluteURL
        else { throw resourceProblem("resource_revision_changed") }
        let stream = try await previewProxy.stream(store: previewStore, id: id, target: target, headers: try uniqueHeaders(command.headers))
        let streamID = UUID()
        let initial = ResourceResult(commandID: command.commandID, statusCode: stream.statusCode,
            headers: stream.headers.map { .init(name: $0.key, value: $0.value) }, streamID: streamID)
        return (initial, streamID, stream.chunks)
    }

    func openPreviewWebSocket(_ command: ResourceCommand) async throws -> (streamID: UUID, tunnel: PreviewWebSocketTunnel) {
        guard let id = command.resourceID else { throw resourceProblem("resource_not_found") }
        let registration = try await previewStore.registration(id: id)
        guard registration.revision == command.expectedRevision,
              let target = URL(string: command.path, relativeTo: registration.origin)?.absoluteURL
        else { throw resourceProblem("resource_revision_changed") }
        return (UUID(), try await previewProxy.openWebSocket(store: previewStore, id: id, target: target))
    }

    /// A worktree workspace names its root; a plain Herdr workspace is confined to the common
    /// ancestor of its panes' working directories.
    #if os(macOS)
    /// Whether this Bridge may capture on its own. A Bridge the app launched is the app's
    /// responsibility in macOS's eyes, so the app is what gets named and allowed; a Bridge that
    /// already holds the permission needs nobody's help. Anything else — chiefly a Bridge
    /// started by sshd — goes through the helper app, the only process macOS will name.
    private func capturesDirectly(_ transportKind: TransportKind) -> Bool {
        transportKind == .localIPC || ScreenCapture.isPermitted
    }

    private func screenCaptureHelper() throws -> ScreenCapture.Helper {
        guard let executable = Bundle.main.executableURL else {
            throw ScreenCaptureError.helperFailed("the Bridge does not know its own path")
        }
        return try ScreenCapture.Helper.install(bridgeExecutable: executable)
    }

    private func listScreenCaptureTargets(transportKind: TransportKind) -> [ScreenCapture.Target] {
        if capturesDirectly(transportKind) { return ScreenCapture.targets() }
        // The helper is the process macOS will let read window titles; a bare listing is still
        // an answer when it cannot run (nobody at the screen, no codesign).
        return (try? screenCaptureHelper().list()) ?? ScreenCapture.targets()
    }

    private func captureScreen(targetID: String, transportKind: TransportKind) throws -> ScreenCapture.Capture {
        if capturesDirectly(transportKind) { return try ScreenCapture.capture(targetID: targetID) }
        return try screenCaptureHelper().capture(targetID: targetID)
    }
    #endif

    private func workspaceRoot(_ workspace: WireWorkspace, in snapshot: WireRuntimeSnapshot) -> String? {
        WorkspaceRootResolver.root(worktreePath: workspace.worktreePath, paneDirectories: snapshot.panes.filter { $0.workspaceID == workspace.id }.compactMap(\.cwd))
    }

    private func artifactStore(for workspace: WireWorkspace, in snapshot: WireRuntimeSnapshot) throws -> ArtifactStore {
        if let existing = artifactStores[workspace.id] { return existing }
        guard let path = workspaceRoot(workspace, in: snapshot) else { throw resourceProblem("workspace_root_unavailable") }
        let storageName = Data(workspace.id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        let store = try ArtifactStore(allowedRoot: URL(fileURLWithPath: path, isDirectory: true), storageRoot: stateDirectory.appending(path: "resources/artifacts/\(storageName)", directoryHint: .isDirectory))
        artifactStores[workspace.id] = store
        return store
    }

    private func previewDescriptor(_ value: PreviewRegistration) -> ResourceDescriptor {
        .init(kind: .preview, resourceID: value.id, workspaceID: value.workspaceID, revision: value.revision,
              title: value.title ?? "Preview", expiresAt: value.expiresAt, healthy: value.isHealthy,
              viewerAvailability: .unknown, paneID: value.paneID ?? "")
    }
    private func artifactDescriptor(_ value: ArtifactPublication, workspaceID: String, store: ArtifactStore) async throws -> ResourceDescriptor {
        .init(kind: .artifact, resourceID: value.id, workspaceID: workspaceID, revision: value.revision,
              title: try await defaultArtifactEntrypoint(value, store: store), mediaType: value.mediaType,
              entrypoint: try await defaultArtifactEntrypoint(value, store: store), expiresAt: value.expiresAt,
              viewerAvailability: ArtifactViewerPolicy.mayRenderInline(mediaType: value.mediaType, filename: try await defaultArtifactEntrypoint(value, store: store)) ? .available : .none)
    }
    private func defaultArtifactEntrypoint(_ publication: ArtifactPublication, store: ArtifactStore) async throws -> String {
        let entries = try await store.entries(for: publication.id)
        if publication.isDirectory, entries.contains(where: { $0.relativePath == "index.html" }) { return "index.html" }
        return entries.first?.relativePath ?? ""
    }
    private func uniqueHeaders(_ headers: [HTTPHeader]) throws -> [String: String] {
        var result: [String: String] = [:]
        for header in headers {
            let key = header.name.lowercased()
            guard !key.isEmpty, result[key] == nil else { throw resourceProblem("invalid_http_headers") }
            result[header.name] = header.value
        }
        return result
    }
    private func resourceProblem(_ code: String) -> Problem {
        Problem(code: code, locus: .bridge, retry: .afterUserAction, recoveryAction: "reviewResourceAndRetry", phase: .resource)
    }
}
