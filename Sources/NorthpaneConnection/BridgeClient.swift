import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import NorthpaneProtocol
import NorthpaneSecurity

/// One file the terminal referenced, read through the Bridge.
public struct WorkspaceFileDownload: Equatable, Sendable {
    public let relativePath: String
    public let mediaType: String
    public let isText: Bool
    public let data: Data
    public init(relativePath: String, mediaType: String, isText: Bool, data: Data) { self.relativePath = relativePath; self.mediaType = mediaType; self.isText = isText; self.data = data }
}

/// One entry a Host path search matched. `path` is absolute on the Host: it is what gets
/// pasted into the pane, or handed back to `readWorkspaceFile` to open.
public struct HostPathHit: Equatable, Hashable, Sendable, Identifiable {
    public let path: String
    public let relativePath: String
    public let rootLabel: String
    public let isDirectory: Bool
    public let byteCount: Int
    public let modified: Date?
    public var id: String { path }
    /// The entry's own name, which is what the operator was typing.
    public var name: String { (path as NSString).lastPathComponent }
    public init(path: String, relativePath: String, rootLabel: String, isDirectory: Bool, byteCount: Int, modified: Date?) {
        self.path = path; self.relativePath = relativePath; self.rootLabel = rootLabel
        self.isDirectory = isDirectory; self.byteCount = byteCount; self.modified = modified
    }
}

public struct HostPathSearchResults: Equatable, Sendable {
    public let hits: [HostPathHit]
    /// The Host stopped early: these are the best of what it had seen, not everything there is.
    public let truncated: Bool
    public init(hits: [HostPathHit], truncated: Bool) { self.hits = hits; self.truncated = truncated }
}

/// One thing the Host's screen can show. `id` is opaque and valid until the next listing.
public struct ScreenCaptureTarget: Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: Equatable, Hashable, Sendable { case display, window }
    public let id: String
    public let kind: Kind
    /// The owning app of a window; empty for a display.
    public let application: String
    /// The window title when the Host was allowed to read it; empty for a display.
    public let title: String
    public let width: Int
    public let height: Int
    /// The main display, or the window nearest the front.
    public let isFrontmost: Bool
    public init(id: String, kind: Kind, application: String, title: String, width: Int, height: Int, isFrontmost: Bool) {
        self.id = id; self.kind = kind; self.application = application; self.title = title
        self.width = width; self.height = height; self.isFrontmost = isFrontmost
    }
}

/// A screenshot the Host took. The PNG stays on the Host at `path`, which is what gets pasted
/// into the pane for an agent to read; `preview` is the operator's downscaled look at it.
/// A file the operator pasted, now on the Host where an agent can read it (schema revision 12).
public struct StagedHostFile: Equatable, Sendable {
    /// Absolute on the Host; what gets typed into the pane.
    public let path: String
    public let mediaType: String
    public let byteCount: Int
    public init(path: String, mediaType: String, byteCount: Int) { self.path = path; self.mediaType = mediaType; self.byteCount = byteCount }
}

public struct HostScreenshot: Equatable, Sendable {
    public let path: String
    public let byteCount: Int
    public let preview: Data
    public let previewMediaType: String
    public init(path: String, byteCount: Int, preview: Data, previewMediaType: String) {
        self.path = path; self.byteCount = byteCount; self.preview = preview; self.previewMediaType = previewMediaType
    }
}

public actor NorthpaneBridgeClient {
    public nonisolated let connectionID: ConnectionID
    public nonisolated let controlChannelID: ChannelID
    public nonisolated let deviceID: ClientDeviceID
    private let transport: any BridgeTransport
    private var accepted: HandshakeAccepted?
    private var receiverTask: Task<Void, Never>?
    private var pendingResponses: [MessageID: EnvelopePromise] = [:]
    private var resourceQueues: [UUID: ResourceResultQueue] = [:]
    private let unsolicited = EnvelopeQueue(limit: 512)
    private var lastInboundAt = Date()

    public init(transport: any BridgeTransport, deviceID: ClientDeviceID = ClientDeviceID(), connectionID: ConnectionID = ConnectionID(), controlChannelID: ChannelID = ChannelID()) {
        self.transport = transport; self.deviceID = deviceID; self.connectionID = connectionID; self.controlChannelID = controlChannelID
    }

    @discardableResult
    public func handshake(expectedHostFingerprint: String? = nil, clientVersion: String = "development") async throws -> HandshakeAccepted {
        let challenge = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let hello = HandshakeHello(protocolRange: .init(minimum: 1, maximum: BridgeProtocol.major), schemaRange: .init(minimum: max(1, BridgeProtocol.schemaRevision - 1), maximum: BridgeProtocol.schemaRevision), clientDeviceID: deviceID, clientVersion: clientVersion, hostIdentityChallenge: challenge, expectedHostFingerprint: expectedHostFingerprint)
        let response = try await request(.hello(hello))
        switch response.payload {
        case let .accepted(accepted):
            _ = try verifyHostHandshake(hello: hello, accepted: accepted)
            self.accepted = accepted
            return accepted
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
    }

    public func observe(sessionName: String? = nil) async throws -> WireRuntimeSnapshot {
        guard accepted != nil else { throw Problem.unauthorized }
        let response = try await request(.observeRuntime(.init(sessionName: sessionName)))
        switch response.payload {
        case let .runtimeSnapshot(snapshot): return snapshot
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
    }

    @discardableResult
    public func pair(using signer: ClientDeviceSigner) async throws -> WirePairingAccepted {
        guard accepted != nil, signer.deviceID == deviceID else { throw Problem.unauthorized }
        let challengeEnvelope = try await request(.pairingChallengeRequest(.init()))
        let challenge: WirePairingChallenge
        switch challengeEnvelope.payload {
        case let .pairingChallenge(value): challenge = value
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
        let proof = try signer.prove(PairingChallenge(id: challenge.challengeID, hostID: challenge.hostID, nonce: challenge.nonce, expiresAt: challenge.expiresAt))
        let result = try await request(.pairingProof(.init(clientDeviceID: proof.deviceID, challengeID: proof.challengeID, publicKey: proof.publicKey, signature: proof.signature)))
        switch result.payload {
        case let .pairingAccepted(accepted): return accepted
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
    }

    public func attach(_ request: TerminalAttachRequest, channelID: ChannelID = ChannelID()) async throws -> TerminalAttached {
        guard accepted != nil else { throw Problem.unauthorized }
        let response = try await self.request(.terminalAttach(request), channelID: channelID)
        switch response.payload {
        case let .terminalAttached(attachment): return attachment
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
    }

    public func sendInput(_ frame: TerminalInputFrame, channelID: ChannelID) async throws {
        try await transport.send(envelope(.terminalInput(frame), channelID: channelID))
    }

    public func resize(_ request: TerminalResizeRequest, channelID: ChannelID) async throws {
        try await transport.send(envelope(.terminalResize(request), channelID: channelID))
    }

    /// Pages the Host-rendered viewport of a controlled terminal. Needs schema revision 4; an older
    /// Bridge has no scrollback paging, so the call is refused rather than sent as an unknown frame.
    public func scroll(_ request: TerminalScrollRequest, channelID: ChannelID) async throws {
        guard let accepted, accepted.schemaRevision >= 4 else { throw Problem.incompatibleProtocol }
        try await transport.send(envelope(.terminalScroll(request), channelID: channelID))
    }

    public func release(_ request: TerminalReleaseRequest, channelID: ChannelID) async throws {
        try await transport.send(envelope(.terminalRelease(request), channelID: channelID))
    }

    public func heartbeat() async throws {
        try await transport.send(envelope(.heartbeat(Heartbeat())))
    }

    public func performResourceCommand(_ command: ResourceCommand, channelID: ChannelID = ChannelID()) async throws -> ResourceResult {
        guard let accepted, accepted.schemaRevision >= 2 else { throw Problem.incompatibleProtocol }
        let response = try await request(.resourceCommand(command), channelID: channelID)
        switch response.payload {
        case let .resourceResult(result) where result.commandID == command.commandID: return result
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
    }

    /// Reads one file the terminal referenced, resolved on the Host against the pane's working
    /// directory and confined to the allowed roots. Needs schema revision 6 (revision 5 read
    /// text from the workspace root only); an older Bridge is refused locally rather than
    /// sent a command it would answer under the old rules.
    public func readWorkspaceFile(path: String, paneID: String, workspaceID: String, channelID: ChannelID = ChannelID()) async throws -> WorkspaceFileDownload {
        guard let accepted, accepted.schemaRevision >= 6 else { throw Problem.incompatibleProtocol }
        var data = Data()
        var relativePath = "", mediaType = "", isText = true
        repeat {
            let result = try await performResourceCommand(.init(kind: .readWorkspaceFile, workspaceID: workspaceID, path: path, offset: data.count, length: 768 * 1_024, paneID: paneID), channelID: channelID)
            if data.isEmpty { relativePath = result.relativePath; mediaType = result.mediaType; isText = result.isText; data.reserveCapacity(result.totalBytes) }
            guard result.totalBytes >= data.count + result.body.count, !result.body.isEmpty || result.totalBytes == 0 else { throw Problem.malformedFrame }
            data.append(result.body)
            if result.totalBytes == data.count { break }
        } while data.count < 64 * 1_024 * 1_024
        return .init(relativePath: relativePath, mediaType: mediaType, isText: isText, data: data)
    }

    /// Searches the Host for entries whose name matches `query`, inside the same roots
    /// `readWorkspaceFile` reads from. Needs schema revision 7; an older Bridge has no such
    /// command and is refused locally rather than sent one it would reject as malformed.
    public func searchWorkspacePaths(query: String, paneID: String, workspaceID: String, limit: Int = 120, channelID: ChannelID = ChannelID()) async throws -> HostPathSearchResults {
        guard let accepted, accepted.schemaRevision >= 7 else { throw Problem.incompatibleProtocol }
        // The Host refuses a query too short to narrow anything. Mirroring that rule here keeps
        // the call total for a caller typing into a search field, and saves a doomed round trip.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return .init(hits: [], truncated: false) }
        let result = try await performResourceCommand(.init(kind: .searchWorkspacePaths, workspaceID: workspaceID, length: limit, paneID: paneID, query: trimmed), channelID: channelID)
        return .init(hits: result.pathHits.map { .init(path: $0.path, relativePath: $0.relativePath, rootLabel: $0.rootLabel, isDirectory: $0.isDirectory, byteCount: $0.byteCount, modified: $0.modified) },
                     truncated: result.truncated)
    }

    /// Stages a file the operator pasted on the Host, sent in frame-sized chunks under one
    /// upload id, and answers with the absolute path an agent reads it from. Needs schema
    /// revision 12; an older Bridge has no such command and is refused locally.
    public func stagePastedFile(_ data: Data, paneID: String, workspaceID: String, channelID: ChannelID = ChannelID()) async throws -> StagedHostFile {
        guard let accepted, accepted.schemaRevision >= 12 else { throw Problem.incompatibleProtocol }
        guard !data.isEmpty else { throw Problem.malformedFrame }
        let uploadID = UUID().uuidString
        let chunkSize = 512 * 1_024
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunkSize)
            let result = try await performResourceCommand(.init(kind: .stagePastedFile, workspaceID: workspaceID, body: Data(data[offset..<end]), idempotencyKey: uploadID, offset: offset, length: data.count, paneID: paneID), channelID: channelID)
            offset = end
            if offset == data.count {
                guard result.isFinal, !result.relativePath.isEmpty else { throw Problem.malformedFrame }
                return StagedHostFile(path: result.relativePath, mediaType: result.mediaType, byteCount: result.totalBytes)
            }
            guard result.totalBytes == offset else { throw Problem.malformedFrame }
        }
        throw Problem.malformedFrame
    }

    /// Lists the Host's displays and on-screen windows, names and sizes only. Needs schema
    /// revision 8; an older Bridge has no such command and is refused locally.
    public func listScreenCaptureTargets(paneID: String, workspaceID: String, channelID: ChannelID = ChannelID()) async throws -> [ScreenCaptureTarget] {
        guard let accepted, accepted.schemaRevision >= 8 else { throw Problem.incompatibleProtocol }
        let result = try await performResourceCommand(.init(kind: .listScreenCaptureTargets, workspaceID: workspaceID, paneID: paneID), channelID: channelID)
        return result.captureTargets.map {
            .init(id: $0.id, kind: $0.kind == .display ? .display : .window, application: $0.application, title: $0.title,
                  width: $0.width, height: $0.height, isFrontmost: $0.isFrontmost)
        }
    }

    /// Captures one listed target. The Host writes the PNG to its user's temporary folder and
    /// answers with that path and a preview that fits in one frame.
    public func captureScreen(targetID: String, paneID: String, workspaceID: String, channelID: ChannelID = ChannelID()) async throws -> HostScreenshot {
        guard let accepted, accepted.schemaRevision >= 8 else { throw Problem.incompatibleProtocol }
        let result = try await performResourceCommand(.init(kind: .captureScreen, workspaceID: workspaceID, paneID: paneID, targetID: targetID), channelID: channelID)
        guard !result.relativePath.isEmpty, !result.body.isEmpty else { throw Problem.malformedFrame }
        return .init(path: result.relativePath, byteCount: result.totalBytes, preview: result.body, previewMediaType: result.mediaType)
    }

    public func performAuthorizationCommand(_ command: AuthorizationCommand, channelID: ChannelID = ChannelID()) async throws -> AuthorizationResult {
        guard let accepted, accepted.schemaRevision >= 3 else { throw Problem.incompatibleProtocol }
        let response = try await request(.authorizationCommand(command), channelID: channelID)
        switch response.payload {
        case let .authorizationResult(result) where result.commandID == command.commandID: return result
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
    }

    public func performNotificationRouteCommand(_ command: NotificationRouteCommand, channelID: ChannelID = ChannelID()) async throws -> NotificationRouteResult {
        guard let accepted, accepted.schemaRevision >= 3, accepted.capabilities.contains(.notifications) else { throw Problem.incompatibleProtocol }
        let response = try await request(.notificationRouteCommand(command), channelID: channelID)
        switch response.payload {
        case let .notificationRouteResult(result) where result.commandID == command.commandID: return result
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
    }

    @discardableResult
    public func requestAuthorizationGrant(deadline: Date = Date().addingTimeInterval(15)) async throws -> WireMutationReceipt {
        guard accepted != nil else { throw Problem.unauthorized }
        let commandID = UUID()
        let mutation = MutationRequest(commandID: commandID, clientDeviceID: deviceID, capability: .authorizationBroker,
            targetID: "device:\(deviceID.rawValue.uuidString):grant:authorizationBroker", expectedRevision: 0, deadline: deadline)
        let response = try await request(.mutation(mutation))
        switch response.payload {
        case let .mutationReceipt(receipt) where receipt.commandID == commandID:
            if let problem = receipt.problem { throw problem }
            return receipt
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
    }

    @discardableResult
    public func startHerdr(sessionName: String? = nil, deadline: Date = Date().addingTimeInterval(15)) async throws -> WireMutationReceipt {
        guard accepted != nil else { throw Problem.unauthorized }
        let normalized = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard normalized.range(of: #"^[A-Za-z0-9._-]{0,64}$"#, options: .regularExpression) != nil else {
            throw Problem.malformedFrame
        }
        let commandID = UUID()
        let target = normalized.isEmpty ? "herdr:start" : "herdr:start:\(normalized)"
        let mutation = MutationRequest(commandID: commandID, clientDeviceID: deviceID, capability: .observeRuntime,
            targetID: target, expectedRevision: 0, deadline: deadline)
        let response = try await request(.mutation(mutation))
        switch response.payload {
        case let .mutationReceipt(receipt) where receipt.commandID == commandID:
            if let problem = receipt.problem { throw problem }
            return receipt
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
    }

    /// Creates one Workspace in the currently observed Herdr session. Schema revision 10 returns
    /// the authoritative Workspace and root Pane identities so the caller can open it immediately.
    @discardableResult
    public func createWorkspace(label: String, workingDirectory: String, agentKind: WorkspaceAgentKind = .shell, deadline: Date? = nil) async throws -> WireMutationReceipt {
        guard let accepted, accepted.schemaRevision >= 10, accepted.capabilities.contains(.terminalControl),
              agentKind == .shell || accepted.schemaRevision >= 11 else {
            throw Problem.incompatibleProtocol
        }
        let commandID = UUID()
        let deadline = deadline ?? Date().addingTimeInterval(agentKind == .shell ? 15 : 40)
        let mutation = MutationRequest(
            commandID: commandID,
            clientDeviceID: deviceID,
            capability: .terminalControl,
            targetID: "workspace:create",
            expectedRevision: 0,
            deadline: deadline,
            workspaceLabel: label,
            workingDirectory: workingDirectory,
            workspaceAgentKind: agentKind
        )
        let response = try await request(.mutation(mutation))
        switch response.payload {
        case let .mutationReceipt(receipt) where receipt.commandID == commandID:
            if receipt.outcome != .applied, let problem = receipt.problem { throw problem }
            guard receipt.outcome == .applied, !receipt.workspaceID.isEmpty, !receipt.paneID.isEmpty else {
                throw Problem.malformedFrame
            }
            return receipt
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
    }

    /// Opens a new Pane — a new tab — in a Workspace the client is observing (schema revision 15),
    /// optionally with an agent already started in it. The Bridge chooses the directory: the
    /// Workspace's own.
    @discardableResult
    public func createPane(workspaceID: String, agentKind: WorkspaceAgentKind = .shell, deadline: Date? = nil) async throws -> WireMutationReceipt {
        guard let accepted, accepted.schemaRevision >= 15, accepted.capabilities.contains(.terminalControl) else {
            throw Problem.incompatibleProtocol
        }
        let normalized = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(of: #"^[A-Za-z0-9._:-]{1,128}$"#, options: .regularExpression) != nil else {
            throw Problem.malformedFrame
        }
        let commandID = UUID()
        let mutation = MutationRequest(
            commandID: commandID,
            clientDeviceID: deviceID,
            capability: .terminalControl,
            targetID: "pane:create:\(normalized)",
            expectedRevision: 0,
            deadline: deadline ?? Date().addingTimeInterval(agentKind == .shell ? 15 : 40),
            workspaceAgentKind: agentKind
        )
        let response = try await request(.mutation(mutation))
        switch response.payload {
        case let .mutationReceipt(receipt) where receipt.commandID == commandID:
            if receipt.outcome != .applied, let problem = receipt.problem { throw problem }
            guard receipt.outcome == .applied, receipt.workspaceID == normalized, !receipt.paneID.isEmpty else {
                throw Problem.malformedFrame
            }
            return receipt
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
    }

    /// Closes one Workspace in the currently observed Herdr session. The Workspace identity is
    /// carried in the mutation target because revision 11 already has an idempotent, authenticated
    /// mutation envelope; no shell command is ever constructed by the client.
    @discardableResult
    public func closeWorkspace(workspaceID: String, deadline: Date = Date().addingTimeInterval(15)) async throws -> WireMutationReceipt {
        guard let accepted, accepted.schemaRevision >= 11, accepted.capabilities.contains(.terminalControl) else {
            throw Problem.incompatibleProtocol
        }
        let normalized = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(of: #"^[A-Za-z0-9._:-]{1,128}$"#, options: .regularExpression) != nil else {
            throw Problem.malformedFrame
        }
        let commandID = UUID()
        let mutation = MutationRequest(
            commandID: commandID,
            clientDeviceID: deviceID,
            capability: .terminalControl,
            targetID: "workspace:close:\(normalized)",
            expectedRevision: 0,
            deadline: deadline
        )
        let response = try await request(.mutation(mutation))
        switch response.payload {
        case let .mutationReceipt(receipt) where receipt.commandID == commandID:
            if receipt.outcome != .applied, let problem = receipt.problem { throw problem }
            guard receipt.outcome == .applied, receipt.workspaceID == normalized else {
                throw Problem.malformedFrame
            }
            return receipt
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
    }

    /// Renames a Workspace. The name is Herdr's own label, so it reaches every client and outlives
    /// this connection; an empty one is refused here rather than on the Host.
    public func renameWorkspace(workspaceID: String, label: String, deadline: Date = Date().addingTimeInterval(15)) async throws -> WireMutationReceipt {
        guard let accepted, accepted.schemaRevision >= 13, accepted.capabilities.contains(.terminalControl) else {
            throw Problem.incompatibleProtocol
        }
        let normalized = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(of: #"^[A-Za-z0-9._:-]{1,128}$"#, options: .regularExpression) != nil,
              !name.isEmpty, name.count <= 128, !name.contains(where: \.isNewline)
        else { throw Problem.malformedFrame }
        let commandID = UUID()
        let mutation = MutationRequest(
            commandID: commandID,
            clientDeviceID: deviceID,
            capability: .terminalControl,
            targetID: "workspace:rename:\(normalized)",
            expectedRevision: 0,
            deadline: deadline,
            workspaceLabel: name
        )
        let response = try await request(.mutation(mutation))
        switch response.payload {
        case let .mutationReceipt(receipt) where receipt.commandID == commandID:
            if receipt.outcome != .applied, let problem = receipt.problem { throw problem }
            guard receipt.outcome == .applied, receipt.workspaceID == normalized else { throw Problem.malformedFrame }
            return receipt
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
    }

    public func openResourceStream(_ command: ResourceCommand, channelID: ChannelID = ChannelID()) async throws -> (initial: ResourceResult, stream: AsyncThrowingStream<ResourceResult, Error>) {
        guard command.kind == .streamPreviewHTTP || command.kind == .openPreviewWebSocket else { throw Problem.malformedFrame }
        let queue = ResourceResultQueue(limit: 32)
        resourceQueues[command.commandID] = queue
        do {
            let initial = try await performResourceCommand(command, channelID: channelID)
            let stream = AsyncThrowingStream<ResourceResult, Error> { continuation in
                let task = Task {
                    do {
                        while let result = try await queue.next() {
                            continuation.yield(result)
                            if result.isFinal { break }
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { [weak self] _ in
                    task.cancel()
                    Task { await self?.cancelResourceStream(command.commandID) }
                }
            }
            return (initial, stream)
        } catch {
            resourceQueues.removeValue(forKey: command.commandID)
            queue.finish(error: error)
            throw error
        }
    }

    public func downloadArtifact(_ descriptor: ResourceDescriptor, channelID: ChannelID = ChannelID()) async throws -> DownloadedArtifact {
        guard descriptor.kind == .artifact else { throw Problem.malformedFrame }
        let listing = try await performResourceCommand(.init(kind: .listArtifactEntries, resourceID: descriptor.resourceID, expectedRevision: descriptor.revision), channelID: channelID)
        var files: [String: Data] = [:]
        for entry in listing.files {
            var data = Data(); data.reserveCapacity(entry.byteCount)
            while data.count < entry.byteCount {
                let result = try await performResourceCommand(.init(kind: .readArtifact, resourceID: descriptor.resourceID, expectedRevision: descriptor.revision, path: entry.relativePath, offset: data.count, length: 768 * 1_024), channelID: channelID)
                guard result.totalBytes == entry.byteCount, !result.body.isEmpty else { throw Problem.malformedFrame }
                data.append(result.body)
            }
            guard data.count == entry.byteCount else { throw Problem.malformedFrame }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == entry.contentDigest else { throw Problem.malformedFrame }
            files[entry.relativePath] = data
        }
        return .init(descriptor: descriptor, files: files)
    }

    @discardableResult
    public func revokeThisDevice(deadline: Date = Date().addingTimeInterval(15)) async throws -> WireMutationReceipt {
        guard accepted != nil else { throw Problem.unauthorized }
        let commandID = UUID()
        let mutation = MutationRequest(commandID: commandID, clientDeviceID: deviceID, capability: .observeRuntime, targetID: "device:\(deviceID.rawValue.uuidString):revoke", expectedRevision: 0, deadline: deadline)
        let response = try await request(.mutation(mutation))
        switch response.payload {
        case let .mutationReceipt(receipt) where receipt.commandID == commandID:
            if let problem = receipt.problem { throw problem }
            return receipt
        case let .problem(problem): throw problem
        default: throw Problem.malformedFrame
        }
    }

    public func receive() async throws -> Envelope {
        ensureReceiver()
        guard let envelope = try await unsolicited.next() else { throw SystemTransportError.endOfStream }
        return envelope
    }

    public func close() async {
        receiverTask?.cancel()
        receiverTask = nil
        await transport.close()
        accepted = nil
        finishReceiver(with: Problem.closedTransport)
    }

    private func request(_ payload: EnvelopePayload, channelID: ChannelID? = nil) async throws -> Envelope {
        ensureReceiver()
        let message = envelope(payload, channelID: channelID)
        let promise = EnvelopePromise()
        pendingResponses[message.messageID] = promise
        do {
            try await transport.send(message)
            return try await promise.wait()
        } catch {
            if pendingResponses.removeValue(forKey: message.messageID) != nil { promise.fail(error) }
            throw error
        }
    }

    private func ensureReceiver() {
        guard receiverTask == nil else { return }
        receiverTask = Task { [weak self, transport] in
            do {
                while !Task.isCancelled {
                    let envelope = try await transport.receive()
                    await self?.route(envelope)
                }
            } catch {
                await self?.finishReceiver(with: error)
            }
        }
    }

    /// When a frame last arrived from the transport, of any kind and whoever it was for. This is
    /// the client's liveness signal: it is stamped where the frame is read, so a caller that is
    /// slow to drain `receive()` cannot make a live connection look closed.
    public var lastInboundFrameAt: Date { lastInboundAt }

    private func route(_ envelope: Envelope) {
        lastInboundAt = Date()
        if let promise = pendingResponses.removeValue(forKey: envelope.messageID) {
            promise.succeed(envelope)
        } else if case let .resourceResult(result) = envelope.payload, let queue = resourceQueues[result.commandID] {
            queue.push(result)
            if result.isFinal { resourceQueues.removeValue(forKey: result.commandID) }
        } else {
            unsolicited.push(envelope)
        }
    }

    private func cancelResourceStream(_ commandID: UUID) {
        guard let queue = resourceQueues.removeValue(forKey: commandID) else { return }
        queue.finish()
    }

    private func finishReceiver(with error: Error) {
        let pending = pendingResponses.values
        pendingResponses.removeAll()
        for promise in pending { promise.fail(error) }
        let resourceQueues = self.resourceQueues.values
        self.resourceQueues.removeAll()
        for queue in resourceQueues { queue.finish(error: error) }
        unsolicited.finish(error: error)
    }

    private func envelope(_ payload: EnvelopePayload, channelID: ChannelID? = nil) -> Envelope {
        Envelope(connectionID: connectionID, channelID: channelID ?? controlChannelID, payload: payload)
    }
}

private final class ResourceResultQueue: @unchecked Sendable {
    private let lock = NSLock(); private let limit: Int
    private var values: [ResourceResult] = []
    private var waiters: [CheckedContinuation<ResourceResult?, Error>] = []
    private var terminal: Result<Void, Error>?
    init(limit: Int) { self.limit = limit }
    func push(_ value: ResourceResult) {
        var overflow = false
        let waiter = lock.withLock { () -> CheckedContinuation<ResourceResult?, Error>? in
            guard terminal == nil else { return nil }
            if waiters.isEmpty { if values.count >= limit { overflow = true } else { values.append(value) }; return nil }
            return waiters.removeFirst()
        }
        waiter?.resume(returning: value)
        if overflow { finish(error: Problem.oversizedFrame) }
    }
    func finish(error: Error? = nil) {
        let pending = lock.withLock { () -> [CheckedContinuation<ResourceResult?, Error>] in
            guard terminal == nil else { return [] }
            terminal = error.map(Result.failure) ?? .success(())
            let pending = waiters; waiters.removeAll(); return pending
        }
        for waiter in pending { if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) } }
    }
    func next() async throws -> ResourceResult? {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> Result<ResourceResult?, Error>? in
                if !values.isEmpty { return .success(values.removeFirst()) }
                if let terminal { switch terminal { case .success: return .success(nil); case let .failure(error): return .failure(error) } }
                waiters.append(continuation); return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }
}

public struct DownloadedArtifact: Sendable {
    public let descriptor: ResourceDescriptor
    public let files: [String: Data]
    public init(descriptor: ResourceDescriptor, files: [String: Data]) { self.descriptor = descriptor; self.files = files }
}

private final class EnvelopePromise: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Envelope, Error>?
    private var waiter: CheckedContinuation<Envelope, Error>?

    func succeed(_ envelope: Envelope) { resolve(.success(envelope)) }
    func fail(_ error: Error) { resolve(.failure(error)) }

    func wait() async throws -> Envelope {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> Result<Envelope, Error>? in
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    private func resolve(_ value: Result<Envelope, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Envelope, Error>? in
            guard result == nil else { return nil }
            result = value
            let continuation = waiter
            waiter = nil
            return continuation
        }
        continuation?.resume(with: value)
    }
}

private final class EnvelopeQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var queued: [Envelope] = []
    private var waiters: [CheckedContinuation<Envelope?, Error>] = []
    private var terminal: Result<Void, Error>?

    init(limit: Int) { self.limit = limit }

    func push(_ envelope: Envelope) {
        var overflow = false
        let waiter = lock.withLock { () -> CheckedContinuation<Envelope?, Error>? in
            guard terminal == nil else { return nil }
            if waiters.isEmpty {
                if queued.count >= limit { overflow = true } else { queued.append(envelope) }
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.resume(returning: envelope)
        if overflow { finish(error: Problem.eventGap) }
    }

    func finish(error: Error? = nil) {
        let pending = lock.withLock { () -> [CheckedContinuation<Envelope?, Error>] in
            guard terminal == nil else { return [] }
            terminal = error.map(Result.failure) ?? .success(())
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) }
        }
    }

    func next() async throws -> Envelope? {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> Result<Envelope?, Error>? in
                if !queued.isEmpty { return .success(queued.removeFirst()) }
                if let terminal {
                    switch terminal {
                    case .success: return .success(nil)
                    case let .failure(error): return .failure(error)
                    }
                }
                waiters.append(continuation)
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }
}
