import Testing
@testable import NorthpaneConnection
@testable import NorthpaneProtocol

@Test func replacingAHostConnectionClosesTheFormerConnection() async throws {
    let director = ConnectionDirector()
    let host = HostID()
    let first = try await director.establish(hostID: host, profile: .init(kind: .localIPC))
    let second = try await director.establish(hostID: host, profile: .init(kind: .ssh))

    #expect(first.id != second.id)
    #expect(await director.activeConnection(for: host)?.id == second.id)
    do {
        try await first.transport.send(Envelope(connectionID: ConnectionID(), channelID: ChannelID(), payload: .problem(.incompatibleProtocol)))
        Issue.record("The superseded connection remained writable")
    } catch let problem as Problem {
        #expect(problem == .closedTransport)
    }
}


@Test func failoverContinuesOnlyForReachabilityOrTransportFailures() async throws {
    let director = ConnectionDirector()
    let host = HostID()
    let profiles = [ConnectionProfile(kind: .localIPC, priority: 0), ConnectionProfile(kind: .ssh, priority: 1)]
    let selected = try await director.establish(hostID: host, profiles: profiles) { profile in
        if profile.kind == .localIPC { throw ConnectionFailure.reachability }
        return LoopbackTransport(kind: profile.kind)
    }
    #expect(selected.profile.kind == .ssh)

    await #expect(throws: ConnectionFailure.identityChanged) {
        try await director.establish(hostID: host, profiles: profiles) { profile in
            if profile.kind == .localIPC { throw ConnectionFailure.identityChanged }
            return LoopbackTransport(kind: profile.kind)
        }
    }
}
