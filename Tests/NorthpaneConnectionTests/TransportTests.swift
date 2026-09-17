import Foundation
import Testing
@testable import NorthpaneConnection
@testable import NorthpaneProtocol

@Test(arguments: TransportKind.allCases)
func everyTransportPreservesTheBridgeEnvelope(_ kind: TransportKind) async throws {
    let transport = LoopbackTransport(kind: kind)
    let expected = Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: .problem(.incompatibleProtocol))

    try await transport.send(expected)

    #expect(try await transport.receive() == expected)
}

@Test func aClosedTransportCannotAcceptAFrame() async throws {
    let transport = LoopbackTransport(kind: .ssh)
    await transport.close()
    do {
        try await transport.send(Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: .problem(.incompatibleProtocol)))
        Issue.record("A closed transport accepted a frame")
    } catch let problem as Problem {
        #expect(problem == .closedTransport)
    }
}

@Test(arguments: TransportKind.allCases)
func handshakeSnapshotAndEventsUseTheSameEnvelopeOnEveryTransport(_ kind: TransportKind) async throws {
    let transport = LoopbackTransport(kind: kind)
    let connection = ConnectionID()
    let control = ChannelID()
    let host = HostID()
    let hello = Envelope(connectionID: connection, channelID: control, payload: .hello(.init(protocolRange: .init(minimum: 1, maximum: 1), schemaRange: .init(minimum: 1, maximum: 1), clientDeviceID: ClientDeviceID())))
    let snapshot = Envelope(connectionID: connection, channelID: control, payload: .runtimeSnapshot(.init(hostID: host, incarnationID: "incarnation", snapshotID: "snapshot", nextEventSequence: 1, panes: [.init(id: "p", title: "Codex")], capabilities: [.observeRuntime])))
    let events = Envelope(connectionID: connection, channelID: control, payload: .runtimeEvents(.init(incarnationID: "incarnation", snapshotID: "snapshot", firstSequence: 1, events: [.paneRenamed(id: "p", title: "Review")])))

    for expected in [hello, snapshot, events] {
        try await transport.send(expected)
        #expect(try await transport.receive() == expected)
    }
}

@Test func processByteStreamTransportCarriesRealLengthPrefixedProtobuf() async throws {
    let transport = try ProcessBridgeTransport(kind: .ssh, executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [])
    let expected = Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: .problem(.incompatibleProtocol))
    try await transport.send(expected)
    #expect(try await transport.receive() == expected)
    await transport.close()
}

@Test func sshProcessSurfacesAuthenticationFailureWithoutLeakingStandardError() async throws {
    let transport = try ProcessBridgeTransport(
        kind: .ssh,
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf 'Permission denied (publickey).\\n' >&2; exit 255"]
    )
    await #expect(throws: SystemTransportError.sshAuthenticationFailed) {
        _ = try await transport.receive()
    }
    await transport.close()
}

@Test func sshExitCodes126And127MeanTheBridgeIsMissingOnTheHost() async throws {
    for (code, stderr) in [(127, "zsh:1: command not found: northpane-bridge"), (126, "sh: line 0: exec: .../northpane-bridge: cannot execute: No such file or directory")] {
        let transport = try ProcessBridgeTransport(
            kind: .ssh,
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' \"\(stderr)\" >&2; exit \(code)"]
        )
        await #expect(throws: SystemTransportError.remoteBridgeUnavailable) {
            _ = try await transport.receive()
        }
        await transport.close()
    }
}

@Test(arguments: [
    ("ssh: connect to host studio-mac port 22: Network is unreachable", SSHReachabilityFailure.hostUnreachable),
    ("ssh: connect to host 192.168.1.20 port 22: No route to host", SSHReachabilityFailure.hostUnreachable),
    ("ssh: connect to host studio-mac port 22: Operation timed out", SSHReachabilityFailure.timedOut),
    ("ssh: connect to host studio-mac port 22: Connection refused", SSHReachabilityFailure.connectionRefused),
    ("ssh: Could not resolve hostname studio-mac: nodename nor servname provided, or not known", SSHReachabilityFailure.nameNotResolved),
])
func sshThatNeverReachedTheHostReportsTheRouteProblemRatherThanAnExitCode(_ scenario: (stderr: String, expected: SSHReachabilityFailure)) async throws {
    let transport = try ProcessBridgeTransport(
        kind: .ssh,
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf '%s\\n' \"\(scenario.stderr)\" >&2; exit 255"]
    )
    await #expect(throws: SystemTransportError.sshUnreachable(scenario.expected)) {
        _ = try await transport.receive()
    }
    await transport.close()
}

@Test func anUnrecognizedSSHFailureKeepsItsExitCodeRatherThanClaimingAnUnreachableHost() {
    let failure = ProcessBridgeTransport.classifyFailure(
        kind: .ssh, exitCode: 255,
        errorData: Data("ssh_exchange_identification: Connection closed by remote host\n".utf8)
    )
    #expect(failure == .processFailed(exitCode: 255))
}

@Test func websocketBodyUsesOneUnprefixedProtobufMessage() throws {
    let expected = Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: .problem(.eventGap))
    let body = try EnvelopeCodec.encodeBody(expected)
    #expect(body.first != Character("{").asciiValue)
    #expect(try EnvelopeCodec.decodeBody(body) == expected)
}
