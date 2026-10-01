#if os(macOS)
@preconcurrency import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import NorthpaneProtocol
import NorthpaneSecurity
import Synchronization
import Testing
@testable import NorthpaneConnection

// A device reaching a Host through the relay, end to end on this Mac: the relay, an SSH server
// standing in for the Host that runs the real Bridge (with the fake Herdr of Tests/Fixtures) for
// the session it is asked for, and the device's own SSH session to it inside the relay's channel.

private final class TestDirectory: SSHRelayDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var enrolled: Set<String>
    private var token: String?
    private let permitted: Set<String>

    init(enrolled: Set<String> = [], token: String? = nil, permitted: [(String, Int)]) {
        self.enrolled = enrolled; self.token = token
        self.permitted = Set(permitted.map { "\($0.0):\($0.1)" })
    }

    func isEnrolled(_ publicKey: String) -> Bool { lock.withLock { enrolled.contains(publicKey) } }

    func enroll(_ publicKey: String, token presented: String) -> Bool {
        lock.withLock {
            guard let token, token == presented else { return false }
            self.token = nil
            enrolled.insert(publicKey)
            return true
        }
    }

    func permits(host: String, port: Int) -> Bool { permitted.contains("\(host):\(port)") }

    func hostsDocument() -> Data { Data(#"["the hosts the app describes"]"#.utf8) }
}

/// The Host's side of a session: the Bridge, run for the `exec` the device asks for.
private final class TestBridgeExecHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    private let arguments: [String]
    private var process: Process?
    private var input: FileHandle?

    init(arguments: [String]) { self.arguments = arguments }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard event is SSHChannelRequestEvent.ExecRequest else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let channel = context.channel
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                channel.close(promise: nil)
                return
            }
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
        }
        do { try process.run() } catch { context.close(promise: nil); return }
        self.process = process
        self.input = stdin.fileHandleForWriting
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case let .byteBuffer(buffer) = unwrapInboundIn(data).data else { return }
        input?.write(Data(buffer.readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        process?.terminate()
        try? input?.close()
        context.fireChannelInactive()
    }
}

private final class TestHostAuthentication: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey
    private let device: String
    init(device: String) { self.device = device }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        guard case let .publicKey(offer) = request.request, String(openSSHPublicKey: offer.publicKey) == device else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}

/// An SSH server on loopback standing in for a Host: it lets in `device` and runs the Bridge.
private func startTestHost(device: String, state: URL) async throws -> (Channel, Int) {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let arguments = [
        "NORTHPANE_HERDR_EXECUTABLE=\(repository.appending(path: "Tests/Fixtures/fake-herdr.sh").path)",
        "NORTHPANE_HERDR_EVENT_SOCKET_OPTIONAL=1",
        "HERDR_SOCKET_PATH=\(state.appending(path: "missing-herdr.sock").path)",
        "NORTHPANE_STATE_DIRECTORY=\(state.path)",
        repository.appending(path: ".build/debug/northpane-bridge").path, "serve", "--stdio",
    ]
    let hostKey = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
    let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                    role: .server(.init(hostKeys: [hostKey], userAuthDelegate: TestHostAuthentication(device: device))),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { child, type in
                        guard type == .session else { return child.eventLoop.makeFailedFuture(SSHRelayError.targetRefused) }
                        return child.pipeline.addHandler(TestBridgeExecHandler(arguments: arguments))
                    }))
            }
        }
        .bind(host: "127.0.0.1", port: 0)
        .get()
    return (channel, channel.localAddress?.port ?? 0)
}

private struct RelayFixture {
    let state = FileManager.default.temporaryDirectory.appending(path: "northpane-relay-\(UUID().uuidString)")
    let credential: NativeSSHCredential
    let deviceKey: String
    let host: Channel
    let hostPort: Int

    init() async throws {
        credential = try NativeSSHCredential()
        let key = try P256.Signing.PrivateKey(rawRepresentation: credential.rawPrivateKey)
        deviceKey = String(openSSHPublicKey: NIOSSHPrivateKey(p256Key: key).publicKey)
        (host, hostPort) = try await startTestHost(device: deviceKey, state: state)
    }

    func relay(_ directory: TestDirectory) async throws -> (SSHRelayServer, Int) {
        let relay = try SSHRelayServer(hostKey: P256.Signing.PrivateKey(), directory: directory)
        return (relay, try await relay.start(address: "127.0.0.1"))
    }

    func connect(through relay: SSHRelayServer, port relayPort: Int, token: String? = nil, fingerprint: String? = nil) async throws -> NativeSSHBridgeTransport {
        try await NativeSSHBridgeTransport.connect(
            host: "127.0.0.1", port: hostPort, username: "operator", credential: credential,
            bridgeCommand: "northpane-bridge serve --stdio",
            relay: SSHRelayRoute(host: "127.0.0.1", port: relayPort, hostKeyFingerprint: fingerprint ?? relay.hostKeyFingerprint, enrollmentToken: token))
    }

    func tearDown() async {
        try? await host.close().get()
        try? FileManager.default.removeItem(at: state)
    }
}

private func expectRelayError(_ expected: SSHRelayError, _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("Expected the relay to refuse with \(expected)")
    } catch let error as SSHRelayError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected \(expected), got \(error)")
    }
}

@Test func anEnrolledDeviceReachesItsHostThroughTheRelay() async throws {
    let fixture = try await RelayFixture()
    let (relay, port) = try await fixture.relay(TestDirectory(enrolled: [fixture.deviceKey], permitted: [("127.0.0.1", fixture.hostPort)]))
    defer { Task { await relay.stop(); await fixture.tearDown() } }

    let signer = try ClientDeviceSigner()
    let client = NorthpaneBridgeClient(transport: try await fixture.connect(through: relay, port: port), deviceID: signer.deviceID)
    defer { Task { await client.close() } }
    _ = try await client.handshake(signer: signer)
    _ = try await client.pair(using: signer)
    #expect(await client.deviceProven)
    #expect(try await client.observe().panes.map(\.id) == ["pane-1"])
}

@Test func aDeviceEnrollsWithTheTokenOnceAndTheTokenIsSpent() async throws {
    let fixture = try await RelayFixture()
    let directory = TestDirectory(token: "enroll-me", permitted: [("127.0.0.1", fixture.hostPort)])
    let (relay, port) = try await fixture.relay(directory)
    defer { Task { await relay.stop(); await fixture.tearDown() } }

    let first = try await fixture.connect(through: relay, port: port, token: "enroll-me")
    await first.close()
    #expect(directory.isEnrolled(fixture.deviceKey))
    // Enrolled now: the key alone is enough, and the token is gone for anyone else.
    let again = try await fixture.connect(through: relay, port: port)
    await again.close()
    #expect(!directory.enroll("ecdsa-sha2-nistp256 AAAA", token: "enroll-me"))
}

@Test func aDeviceTheRelayDoesNotKnowIsRefused() async throws {
    let fixture = try await RelayFixture()
    let (relay, port) = try await fixture.relay(TestDirectory(token: "the-real-one", permitted: [("127.0.0.1", fixture.hostPort)]))
    defer { Task { await relay.stop(); await fixture.tearDown() } }
    await expectRelayError(.deviceNotEnrolled) { _ = try await fixture.connect(through: relay, port: port) }
    await expectRelayError(.deviceNotEnrolled) { _ = try await fixture.connect(through: relay, port: port, token: "a-guess") }
}

@Test func theRelayOpensNothingButTheHostsItWasGiven() async throws {
    let fixture = try await RelayFixture()
    let (relay, port) = try await fixture.relay(TestDirectory(enrolled: [fixture.deviceKey], permitted: [("127.0.0.1", 9)]))
    defer { Task { await relay.stop(); await fixture.tearDown() } }
    await expectRelayError(.targetRefused) { _ = try await fixture.connect(through: relay, port: port) }
}

@Test func aRelayShowingAnotherKeyIsRefused() async throws {
    let fixture = try await RelayFixture()
    let (relay, port) = try await fixture.relay(TestDirectory(enrolled: [fixture.deviceKey], permitted: [("127.0.0.1", fixture.hostPort)]))
    defer { Task { await relay.stop(); await fixture.tearDown() } }
    do {
        _ = try await fixture.connect(through: relay, port: port, fingerprint: "SHA256:notTheRelaysKey")
        Issue.record("A relay with another key was trusted")
    } catch SystemTransportError.hostKeyMismatch {
    } catch {
        Issue.record("Expected a host key mismatch, got \(error)")
    }
}

@Test func removingADeviceFromTheRelayEndsWhatItHasOpen() async throws {
    let fixture = try await RelayFixture()
    let (relay, port) = try await fixture.relay(TestDirectory(enrolled: [fixture.deviceKey], permitted: [("127.0.0.1", fixture.hostPort)]))
    defer { Task { await relay.stop(); await fixture.tearDown() } }

    let signer = try ClientDeviceSigner()
    let client = NorthpaneBridgeClient(transport: try await fixture.connect(through: relay, port: port), deviceID: signer.deviceID)
    defer { Task { await client.close() } }
    _ = try await client.handshake(signer: signer)
    await relay.disconnect(device: fixture.deviceKey)
    await #expect(throws: (any Error).self) { _ = try await client.pair(using: signer) }
}

@Test func enrollingWithTheTokenReadsTheHostsTheRelayReaches() async throws {
    let fixture = try await RelayFixture()
    let directory = TestDirectory(token: "from-the-qr-code", permitted: [("127.0.0.1", fixture.hostPort)])
    let (relay, port) = try await fixture.relay(directory)
    defer { Task { await relay.stop(); await fixture.tearDown() } }
    let route = SSHRelayRoute(host: "127.0.0.1", port: port, hostKeyFingerprint: relay.hostKeyFingerprint, enrollmentToken: "from-the-qr-code")

    #expect(try await SSHRelayEnrollment.hosts(route, credential: fixture.credential) == directory.hostsDocument())
    #expect(directory.isEnrolled(fixture.deviceKey))
    // Enrolled: the key alone reads them again, and the spent token enrolls no other key.
    let again = SSHRelayRoute(host: "127.0.0.1", port: port, hostKeyFingerprint: relay.hostKeyFingerprint)
    #expect(try await SSHRelayEnrollment.hosts(again, credential: fixture.credential) == directory.hostsDocument())
    await expectRelayError(.deviceNotEnrolled) { _ = try await SSHRelayEnrollment.hosts(route, credential: try NativeSSHCredential()) }
    do {
        _ = try await SSHRelayEnrollment.hosts(SSHRelayRoute(host: "127.0.0.1", port: port, hostKeyFingerprint: "SHA256:another"), credential: fixture.credential)
        Issue.record("Enrolled with a relay showing another key")
    } catch SystemTransportError.hostKeyMismatch {
    } catch {
        Issue.record("Expected a host key mismatch, got \(error)")
    }
}

/// A session on the relay reads its Hosts and does nothing else: no command of the device's
/// choosing runs on the Mac.
@Test func theRelayRunsNoCommandButItsOwnList() async throws {
    let fixture = try await RelayFixture()
    let (relay, port) = try await fixture.relay(TestDirectory(enrolled: [fixture.deviceKey], permitted: [("127.0.0.1", fixture.hostPort)]))
    defer { Task { await relay.stop(); await fixture.tearDown() } }
    // The relay as if it were a Host: a session asking it for a command gets nothing back.
    let deployment = try NativeSFTPBridgeDeployment(host: "127.0.0.1", port: port, username: SSHRelayRoute.username,
                                                    credential: fixture.credential, expectedHostKeyFingerprint: relay.hostKeyFingerprint)
    let result = try? await deployment.runInstallerShellScript("echo hello", arguments: [])
    #expect(result?.output.contains("hello") != true)
}

/// A Mac on a tailnet and on its local network listens on both, on one port, so a device saved
/// with both addresses reaches it through either.
@Test func theRelayListensOnEveryAddressItIsGivenOnOnePort() async throws {
    let fixture = try await RelayFixture()
    let directory = TestDirectory(enrolled: [fixture.deviceKey], permitted: [("127.0.0.1", fixture.hostPort)])
    let relay = try SSHRelayServer(hostKey: P256.Signing.PrivateKey(), directory: directory)
    let port = try await relay.start(addresses: ["127.0.0.1", "::1"], port: 0)
    defer { Task { await relay.stop(); await fixture.tearDown() } }
    for address in ["127.0.0.1", "::1"] {
        let route = SSHRelayRoute(host: address, port: port, hostKeyFingerprint: relay.hostKeyFingerprint)
        #expect(try await SSHRelayEnrollment.hosts(route, credential: fixture.credential) == directory.hostsDocument(), "\(address)")
    }
    // One public address among them and the relay listens nowhere.
    let refused = try SSHRelayServer(hostKey: P256.Signing.PrivateKey(), directory: directory)
    await #expect(throws: SystemTransportError.invalidEndpoint) { _ = try await refused.start(addresses: ["127.0.0.1", "8.8.8.8"], port: 0) }
}

/// A Mac that stopped relaying, or an address it no longer has, reads as a relay that does not
/// answer: what lets a device move on to the relay's next address.
@Test func aRelayThatDoesNotAnswerIsUnreachable() async throws {
    let fixture = try await RelayFixture()
    let (relay, port) = try await fixture.relay(TestDirectory(enrolled: [fixture.deviceKey], permitted: [("127.0.0.1", fixture.hostPort)]))
    await relay.stop()
    defer { Task { await fixture.tearDown() } }
    await expectRelayError(.relayUnreachable) { _ = try await fixture.connect(through: relay, port: port) }
    await expectRelayError(.relayUnreachable) {
        _ = try await SSHRelayEnrollment.hosts(SSHRelayRoute(host: "127.0.0.1", port: port, hostKeyFingerprint: relay.hostKeyFingerprint),
                                               credential: fixture.credential)
    }
}

@Test func theRelayListensOnlyWhereThePublicCannotReach() {
    for address in ["127.0.0.1", "10.1.2.3", "172.20.0.5", "192.168.1.20", "100.101.102.103", "fd7a:115c:a1e0::1"] {
        #expect(SSHRelayServer.isPrivate(address), "\(address)")
    }
    for address in ["0.0.0.0", "8.8.8.8", "172.32.0.1", "100.128.0.1", "2001:db8::1", "::"] {
        #expect(!SSHRelayServer.isPrivate(address), "\(address)")
    }
}
#endif
