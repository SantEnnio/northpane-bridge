import Foundation
import Testing
import NorthpaneConnection
import NorthpaneHostRuntime
import NorthpaneProtocol
import NorthpaneSecurity
@testable import NorthpaneBridge

@Suite(.timeLimit(.minutes(1)))
struct HostRuntimeContractTests {
    @Test func workspacePaneAndTerminalUseTheInjectedRuntime() async throws {
        let runtime = FakeHostRuntime()
        let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-runtime-contract-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try await RuntimeTestConnection.open(runtime: runtime, directory: directory)
        let client = session.client
        do {
            _ = try await client.observe()
            let created = try await client.createWorkspace(label: "Runtime", workingDirectory: directory.appending(path: "work").path)
            #expect(created.outcome == .applied)
            // Wait for the event-driven push, without asking for another snapshot.
            let pushed = try await snapshotContaining(created.paneID, client: client)
            #expect(pushed.workspaces.first?.label == "Runtime")

            let second = try await client.createPane(workspaceID: created.workspaceID)
            let withSecond = try await snapshotContaining(second.paneID, client: client)
            #expect(withSecond.panes.first { $0.id == second.paneID }?.tabID != withSecond.panes.first { $0.id == created.paneID }?.tabID)

            let split = try await client.splitPane(paneID: second.paneID, direction: .right)
            let withSplit = try await snapshotContaining(split.paneID, client: client)
            #expect(withSplit.panes.first { $0.id == split.paneID }?.tabID == withSplit.panes.first { $0.id == second.paneID }?.tabID)
            _ = try await client.renameWorkspace(workspaceID: created.workspaceID, label: "Renamed")
            let renamed = try await client.observe()
            #expect(renamed.workspaces.first?.label == "Renamed")

            let channel = ChannelID()
            let attached = try await client.attach(.init(paneID: created.paneID, mode: .control, columns: 100, rows: 30,
                incarnationID: renamed.incarnationID, snapshotID: renamed.snapshotID, nextEventSequence: renamed.nextEventSequence), channelID: channel)
            _ = try await terminalOutput(attached.attachmentID, client: client)
            let bytes = Data("runtime echo\n".utf8)
            try await client.sendInput(.init(attachmentID: attached.attachmentID, sequence: 0, bytes: bytes), channelID: channel)
            #expect(try await terminalOutput(attached.attachmentID, client: client) == bytes)
            try await client.resize(.init(attachmentID: attached.attachmentID, columns: 80, rows: 24), channelID: channel)
            try await client.scroll(.init(attachmentID: attached.attachmentID, direction: .up, lines: 1), channelID: channel)
            try await client.release(.init(attachmentID: attached.attachmentID), channelID: channel)

            _ = try await client.closeWorkspace(workspaceID: created.workspaceID)
            let closed = try await client.observe()
            #expect(closed.workspaces.isEmpty && closed.tabs.isEmpty && closed.panes.isEmpty)
            await session.close()
        } catch {
            await session.close()
            throw error
        }
    }

    @Test func reconnectingTheBridgeKeepsRuntimeStateAndTerminalContents() async throws {
        let runtime = FakeHostRuntime()
        let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-runtime-reconnect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await RuntimeTestConnection.open(runtime: runtime, directory: directory)
        let created: WireMutationReceipt
        let before: WireRuntimeSnapshot
        do {
            _ = try await first.client.observe()
            created = try await first.client.createWorkspace(label: "Keep running", workingDirectory: directory.appending(path: "work").path)
            before = try await snapshotContaining(created.paneID, client: first.client)
            let channel = ChannelID()
            let attached = try await first.client.attach(.init(paneID: created.paneID, mode: .control, columns: 80, rows: 24,
                incarnationID: before.incarnationID, snapshotID: before.snapshotID, nextEventSequence: before.nextEventSequence), channelID: channel)
            _ = try await terminalOutput(attached.attachmentID, client: first.client)
            try await first.client.sendInput(.init(attachmentID: attached.attachmentID, sequence: 0, bytes: Data("still here\n".utf8)), channelID: channel)
            _ = try await terminalOutput(attached.attachmentID, client: first.client)
            await first.close()
        } catch { await first.close(); throw error }

        let second = try await RuntimeTestConnection.open(runtime: runtime, directory: directory)
        do {
            let after = try await second.client.observe()
            #expect(after.incarnationID == before.incarnationID)
            #expect(after.workspaces == before.workspaces)
            #expect(after.panes == before.panes)
            let attached = try await second.client.attach(.init(paneID: created.paneID, mode: .takeover, columns: 80, rows: 24,
                incarnationID: after.incarnationID, snapshotID: after.snapshotID, nextEventSequence: after.nextEventSequence))
            let redraw = try await terminalOutput(attached.attachmentID, client: second.client)
            #expect(String(decoding: redraw, as: UTF8.self).contains("still here"))
            await second.close()
        } catch { await second.close(); throw error }
    }
}

private func snapshotContaining(_ paneID: String, client: NorthpaneBridgeClient) async throws -> WireRuntimeSnapshot {
    while true {
        let envelope = try await client.receive()
        if case let .runtimeSnapshot(snapshot) = envelope.payload, snapshot.panes.contains(where: { $0.id == paneID }) { return snapshot }
    }
}

private func terminalOutput(_ attachmentID: UUID, client: NorthpaneBridgeClient) async throws -> Data {
    while true {
        let envelope = try await client.receive()
        if case let .terminalOutput(output) = envelope.payload, output.attachmentID == attachmentID { return output.bytes }
    }
}

private struct RuntimeTestConnection {
    let client: NorthpaneBridgeClient
    let server: Task<Void, Never>
    let transport: RuntimeTestTransport

    static func open(runtime: FakeHostRuntime, directory: URL) async throws -> Self {
        let requests = RuntimeTestMailbox(), responses = RuntimeTestMailbox()
        let clientTransport = RuntimeTestTransport(input: responses, output: requests)
        let serverTransport = RuntimeTestTransport(input: requests, output: responses)
        let context = try await BridgeHostContext(stateDirectory: directory, runtimeFactory: { _, _ in runtime })
        let server = Task {
            do { try await NorthpaneBridge.serve(serverTransport, context: context) }
            catch { await serverTransport.close() }
        }
        let signer = try ClientDeviceSigner()
        let client = NorthpaneBridgeClient(transport: clientTransport, deviceID: signer.deviceID)
        do {
            _ = try await client.handshake()
            _ = try await client.pair(using: signer)
            return Self(client: client, server: server, transport: clientTransport)
        } catch {
            await clientTransport.close()
            await server.value
            throw error
        }
    }

    func close() async {
        await client.close()
        await transport.close()
        await server.value
    }
}

private struct RuntimeTestTransport: BridgeTransport {
    let kind: TransportKind = .localIPC
    let input: RuntimeTestMailbox
    let output: RuntimeTestMailbox
    func send(_ envelope: Envelope) async throws { try await output.put(envelope) }
    func receive() async throws -> Envelope { try await input.take() }
    func close() async { await input.close(); await output.close() }
}

private actor RuntimeTestMailbox {
    private var frames: [Data] = []
    private var waiter: CheckedContinuation<Envelope, Error>?
    private var timeout: Task<Void, Never>?
    private var closed = false
    func put(_ envelope: Envelope) throws {
        guard !closed else { throw Problem.closedTransport }
        // Exercise the same framing and Protobuf mapping as a real transport.
        let frame = try FrameCodec.encode(envelope)
        if let waiter {
            self.waiter = nil
            timeout?.cancel()
            timeout = nil
            waiter.resume(returning: try FrameCodec.decode(frame))
        } else { frames.append(frame) }
    }
    func take() async throws -> Envelope {
        guard !closed else { throw Problem.closedTransport }
        if !frames.isEmpty { return try FrameCodec.decode(frames.removeFirst()) }
        return try await withCheckedThrowingContinuation {
            waiter = $0
            timeout = Task {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
                expire()
            }
        }
    }
    private func expire() {
        waiter?.resume(throwing: Problem.deadlineExceeded)
        waiter = nil
        timeout = nil
    }
    func close() {
        closed = true
        timeout?.cancel()
        timeout = nil
        waiter?.resume(throwing: Problem.closedTransport)
        waiter = nil
        frames.removeAll()
    }
}
