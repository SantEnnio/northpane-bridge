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
// And a device reaching the Mac that runs the relay: a session of the relay's own, joined to a
// real Bridge that the directory starts as the app would.

/// How these tests start the real Bridge, with the fake Herdr and a state of its own.
private func bridgeLaunch(state: URL) -> [String] {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return [
        "NORTHPANE_HERDR_EXECUTABLE=\(repository.appending(path: "Tests/Fixtures/fake-herdr.sh").path)",
        "NORTHPANE_HERDR_EVENT_SOCKET_OPTIONAL=1",
        "HERDR_SOCKET_PATH=\(state.appending(path: "missing-herdr.sock").path)",
        "NORTHPANE_STATE_DIRECTORY=\(state.path)",
        repository.appending(path: ".build/debug/northpane-bridge").path, "serve", "--stdio",
    ]
}

private final class TestDirectory: SSHRelayDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var enrolled: Set<String>
    private var token: String?
    private let permitted: Set<String>
    /// How the Bridge of the Mac itself is started, when this relay offers one.
    private let bridge: [String]?
    private var opened: [String] = []
    private var ended = 0
    private var names: [String: String] = [:]

    init(enrolled: Set<String> = [], token: String? = nil, permitted: [(String, Int)] = [], bridge: [String]? = nil) {
        self.enrolled = enrolled; self.token = token
        self.permitted = Set(permitted.map { "\($0.0):\($0.1)" })
        self.bridge = bridge
    }

    /// The keys this Mac's Bridge was started for, in order, and how many of those sessions are over.
    var bridgesOpened: [String] { lock.withLock { opened } }
    var bridgesEnded: Int { lock.withLock { ended } }

    func bridge(for publicKey: String) -> SSHRelayBridge? {
        guard let bridge else { return nil }
        lock.withLock { opened.append(publicKey) }
        return try? SSHRelayBridge.process(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: bridge) { [self] in
            lock.withLock { ended += 1 }
        }
    }

    /// What the device with this key last called itself.
    func name(of publicKey: String) -> String? { lock.withLock { names[publicKey] } }

    func device(_ publicKey: String, calledItself name: String) { lock.withLock { names[publicKey] = name } }

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
    let arguments = bridgeLaunch(state: state)
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
    /// The state of the Bridge of the Mac that runs the relay: a Host of its own, apart from the one behind it.
    let macState = FileManager.default.temporaryDirectory.appending(path: "northpane-relay-mac-\(UUID().uuidString)")
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

    /// A session with the Bridge of the Mac that runs the relay, as `signer`'s device.
    func connectToMac(_ relay: SSHRelayServer, port: Int, as signer: ClientDeviceSigner, token: String? = nil) async throws -> NorthpaneBridgeClient {
        let route = SSHRelayRoute(host: "127.0.0.1", port: port, hostKeyFingerprint: relay.hostKeyFingerprint, enrollmentToken: token)
        return NorthpaneBridgeClient(transport: try await NativeSSHBridgeTransport.connect(toBridgeOf: route, credential: credential), deviceID: signer.deviceID)
    }

    func tearDown() async {
        try? await host.close().get()
        try? FileManager.default.removeItem(at: state)
        try? FileManager.default.removeItem(at: macState)
    }
}

/// Whether the relay closed this session by itself. One it left open is given up after a few
/// seconds, so that a relay that started something fails the test instead of holding it.
private func closedByTheRelay(_ transport: NativeSSHBridgeTransport) async -> Bool {
    let patience = Duration.seconds(5)
    let giveUp = Task { try await Task.sleep(for: patience); await transport.close() }
    defer { giveUp.cancel() }
    let asked = ContinuousClock.now
    do {
        _ = try await transport.receive()
        return false
    } catch {
        return ContinuousClock.now - asked < patience
    }
}

/// Waits a few seconds at most for what the relay does on its own thread, a moment after a
/// session closes.
private func eventually(_ happened: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, !happened() { try? await Task.sleep(for: .milliseconds(20)) }
    return happened()
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

/// A session on the relay takes the relay's own two commands and nothing else: no command of the
/// device's choosing runs on the Mac.
@Test func theRelayRunsNoCommandOfTheDevicesChoosing() async throws {
    let fixture = try await RelayFixture()
    let (relay, port) = try await fixture.relay(TestDirectory(enrolled: [fixture.deviceKey], permitted: [("127.0.0.1", fixture.hostPort)]))
    defer { Task { await relay.stop(); await fixture.tearDown() } }
    // The relay as if it were a Host: a session asking it for a command gets nothing back.
    let deployment = try NativeSFTPBridgeDeployment(host: "127.0.0.1", port: port, username: SSHRelayRoute.username,
                                                    credential: fixture.credential, expectedHostKeyFingerprint: relay.hostKeyFingerprint)
    let result = try? await deployment.runInstallerShellScript("echo hello", arguments: [])
    #expect(result?.output.contains("hello") != true)
}

/// The Mac that runs the relay is a Host too, with no SSH server to log in to: an enrolled device
/// reaches its Bridge on a session of the relay's own, and pairs and proves itself there as on any Host.
@Test func anEnrolledDeviceReachesTheBridgeOfTheMacItself() async throws {
    let fixture = try await RelayFixture()
    let directory = TestDirectory(enrolled: [fixture.deviceKey], bridge: bridgeLaunch(state: fixture.macState))
    let (relay, port) = try await fixture.relay(directory)
    defer { Task { await relay.stop(); await fixture.tearDown() } }

    let signer = try ClientDeviceSigner()
    let client = try await fixture.connectToMac(relay, port: port, as: signer)
    _ = try await client.handshake(signer: signer)
    _ = try await client.pair(using: signer)
    #expect(await client.deviceProven)
    #expect(try await client.observe().panes.map(\.id) == ["pane-1"])
    await client.close()

    // A later session is the same device's: it proves its key again, and has no need to pair.
    let again = try await fixture.connectToMac(relay, port: port, as: signer)
    _ = try await again.handshake(signer: signer)
    #expect(await again.deviceProven)
    #expect(try await again.observe().panes.map(\.id) == ["pane-1"])
    await again.close()
    #expect(directory.bridgesOpened == [fixture.deviceKey, fixture.deviceKey])
    // Both Bridges are gone before their state is removed, or one could write it back.
    #expect(await eventually { directory.bridgesEnded == 2 })
}

/// The Mac's Bridge is for enrolled devices: a key the relay does not know is turned away at the
/// door, and no Bridge is started for it.
@Test func aDeviceTheRelayDoesNotKnowReachesNoBridgeOfTheMac() async throws {
    let fixture = try await RelayFixture()
    let directory = TestDirectory(token: "the-real-one", bridge: bridgeLaunch(state: fixture.macState))
    let (relay, port) = try await fixture.relay(directory)
    defer { Task { await relay.stop(); await fixture.tearDown() } }

    let signer = try ClientDeviceSigner()
    await expectRelayError(.deviceNotEnrolled) { _ = try await fixture.connectToMac(relay, port: port, as: signer) }
    await expectRelayError(.deviceNotEnrolled) { _ = try await fixture.connectToMac(relay, port: port, as: signer, token: "a-guess") }
    #expect(directory.bridgesOpened.isEmpty)
}

/// A relay offers the Mac it runs on only when the app says so. Without that an enrolled device
/// is told the relay will not open it, as for a Host the Operator did not enable.
@Test func aRelayWhoseAppOffersNoBridgeRefusesTheSession() async throws {
    let fixture = try await RelayFixture()
    let (relay, port) = try await fixture.relay(TestDirectory(enrolled: [fixture.deviceKey], permitted: [("127.0.0.1", fixture.hostPort)]))
    defer { Task { await relay.stop(); await fixture.tearDown() } }
    await expectRelayError(.targetRefused) { _ = try await fixture.connectToMac(relay, port: port, as: try ClientDeviceSigner()) }
}

/// The Bridge is started for the relay's own command, spelled exactly: a command line that only
/// contains it, as a Host's shell would be sent, starts nothing and closes the session.
@Test func theRelayStartsTheBridgeForItsOwnCommandAndNoOther() async throws {
    let fixture = try await RelayFixture()
    let directory = TestDirectory(enrolled: [fixture.deviceKey], bridge: bridgeLaunch(state: fixture.macState))
    let (relay, port) = try await fixture.relay(directory)
    defer { Task { await relay.stop(); await fixture.tearDown() } }

    for command in ["northpane-bridge serve --stdio", "northpane-bridge;id", " northpane-bridge", "sh -c northpane-bridge", "NORTHPANE-BRIDGE"] {
        // The relay as if it were a Host, asked for a Bridge the way a Host's shell is.
        let transport = try await NativeSSHBridgeTransport.connect(
            host: "127.0.0.1", port: port, username: SSHRelayRoute.username, credential: fixture.credential,
            expectedHostKeyFingerprint: relay.hostKeyFingerprint, bridgeCommand: command)
        #expect(await closedByTheRelay(transport), "\(command)")
        await transport.close()
    }
    #expect(directory.bridgesOpened.isEmpty)
}

/// The Bridge the app started lives as long as the session it was started for: when the device
/// closes the session the app is told, once, with the key it was started for.
@Test func theAppIsToldWhenADevicesSessionWithItsBridgeIsOver() async throws {
    let fixture = try await RelayFixture()
    let directory = TestDirectory(enrolled: [fixture.deviceKey], bridge: bridgeLaunch(state: fixture.macState))
    let (relay, port) = try await fixture.relay(directory)
    defer { Task { await relay.stop(); await fixture.tearDown() } }

    let signer = try ClientDeviceSigner()
    let client = try await fixture.connectToMac(relay, port: port, as: signer)
    _ = try await client.handshake(signer: signer)
    #expect(directory.bridgesOpened == [fixture.deviceKey])
    #expect(directory.bridgesEnded == 0)
    await client.close()
    #expect(await eventually { directory.bridgesEnded == 1 })
}

/// Removing a device from the relay ends what it is doing on the Mac itself too, not only on the
/// Hosts behind it.
@Test func removingADeviceFromTheRelayEndsItsSessionWithTheMac() async throws {
    let fixture = try await RelayFixture()
    let directory = TestDirectory(enrolled: [fixture.deviceKey], bridge: bridgeLaunch(state: fixture.macState))
    let (relay, port) = try await fixture.relay(directory)
    defer { Task { await relay.stop(); await fixture.tearDown() } }

    let signer = try ClientDeviceSigner()
    let client = try await fixture.connectToMac(relay, port: port, as: signer)
    defer { Task { await client.close() } }
    _ = try await client.handshake(signer: signer)
    await relay.disconnect(device: fixture.deviceKey)
    await #expect(throws: (any Error).self) { _ = try await client.pair(using: signer) }
    #expect(await eventually { directory.bridgesEnded == 1 })
}

/// The app's Bridge is a process of its own, and it does not outlive its session: when the
/// session is over it is told to stop, even one that would never stop by itself.
@Test func theBridgeProcessIsToldToStopWhenItsSessionIsOver() async throws {
    let fixture = try await RelayFixture()
    try FileManager.default.createDirectory(at: fixture.macState, withIntermediateDirectories: true)
    let ready = fixture.macState.appending(path: "ready"), stopped = fixture.macState.appending(path: "stopped")
    // Stands in for a Bridge that reads nothing and never ends: only being told to stop ends it.
    let standIn = ["/bin/sh", "-c", #"trap ': > "$1"; exit 0' TERM; : > "$0"; while :; do sleep 0.05; done"#, ready.path, stopped.path]
    let directory = TestDirectory(enrolled: [fixture.deviceKey], bridge: standIn)
    let (relay, port) = try await fixture.relay(directory)
    defer { Task { await relay.stop(); await fixture.tearDown() } }

    let route = SSHRelayRoute(host: "127.0.0.1", port: port, hostKeyFingerprint: relay.hostKeyFingerprint)
    let transport = try await NativeSSHBridgeTransport.connect(toBridgeOf: route, credential: fixture.credential)
    #expect(await eventually { FileManager.default.fileExists(atPath: ready.path) })
    #expect(!FileManager.default.fileExists(atPath: stopped.path))
    await transport.close()
    #expect(await eventually { FileManager.default.fileExists(atPath: stopped.path) })
    #expect(directory.bridgesEnded == 1)
}

/// A Bridge that ends by itself — it could not start, or it failed — ends the device's session
/// with it: the device is not left waiting on a Bridge that is gone.
@Test func theSessionEndsWhenTheBridgeOfTheMacDoes() async throws {
    let fixture = try await RelayFixture()
    let directory = TestDirectory(enrolled: [fixture.deviceKey], bridge: ["/bin/sh", "-c", "exit 1"])
    let (relay, port) = try await fixture.relay(directory)
    defer { Task { await relay.stop(); await fixture.tearDown() } }

    let route = SSHRelayRoute(host: "127.0.0.1", port: port, hostKeyFingerprint: relay.hostKeyFingerprint)
    let transport = try await NativeSSHBridgeTransport.connect(toBridgeOf: route, credential: fixture.credential)
    #expect(await closedByTheRelay(transport))
    await transport.close()
    #expect(await eventually { directory.bridgesEnded == 1 })
}

/// A device says what it is called as it opens a session, for the Mac to show beside its key:
/// when it enrolls, and again whenever it reaches the Mac's Bridge. Nothing checks the name, so
/// what the app is told is one short line of characters that show, and a name with none is not told.
@Test func aDeviceTellsTheRelayWhatItIsCalled() async throws {
    let fixture = try await RelayFixture()
    // Nothing is said to the Bridge here: anything that reads its input stands in for it.
    let directory = TestDirectory(token: "from-the-qr-code", bridge: ["/bin/cat"])
    let (relay, port) = try await fixture.relay(directory)
    defer { Task { await relay.stop(); await fixture.tearDown() } }

    let enrolling = SSHRelayRoute(host: "127.0.0.1", port: port, hostKeyFingerprint: relay.hostKeyFingerprint, enrollmentToken: "from-the-qr-code")
    _ = try await SSHRelayEnrollment.hosts(enrolling, credential: fixture.credential, deviceName: "iPhone 16 Pro")
    #expect(directory.name(of: fixture.deviceKey) == "iPhone 16 Pro")

    // A line break, a direction override and two hundred letters too many, on the way to the Bridge.
    let route = SSHRelayRoute(host: "127.0.0.1", port: port, hostKeyFingerprint: relay.hostKeyFingerprint)
    let renamed = try await NativeSSHBridgeTransport.connect(toBridgeOf: route, credential: fixture.credential,
                                                             deviceName: "  Studio\u{202E} iPad\nmini " + String(repeating: "x", count: 200))
    await renamed.close()
    #expect(directory.name(of: fixture.deviceKey) == "Studio iPad mini xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
    #expect(directory.name(of: fixture.deviceKey)?.count == 64)

    let unnamed = try await NativeSSHBridgeTransport.connect(toBridgeOf: route, credential: fixture.credential, deviceName: " \u{202E}\n")
    await unnamed.close()
    #expect(directory.name(of: fixture.deviceKey)?.hasPrefix("Studio iPad mini ") == true)
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
