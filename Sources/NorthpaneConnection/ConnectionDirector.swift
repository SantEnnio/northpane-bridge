import Foundation
import NorthpaneProtocol

public struct ManagedConnection: Sendable {
    public let id: ConnectionID
    public let hostID: HostID
    public let profile: ConnectionProfile
    public let transport: any BridgeTransport
}

public enum ConnectionFailure: Error, Equatable, Sendable {
    case reachability
    case transport
    case identityChanged
    case fingerprintChanged
    case authenticationDenied
    case pairingRevoked
    case incompatible

    public var allowsProfileFallback: Bool { self == .reachability || self == .transport }
}

/// Owns the one active authority chain for each Host. A replacement never carries
/// over the former transport, session, channel, or proof.
public actor ConnectionDirector {
    private var active: [HostID: ManagedConnection] = [:]
    private let factory: any BridgeTransportFactory
    public init(factory: any BridgeTransportFactory = LoopbackBridgeTransportFactory()) { self.factory = factory }
    public func establish(hostID: HostID, profile: ConnectionProfile) async throws -> ManagedConnection {
        if let previous = active[hostID] { await previous.transport.close() }
        let connection = ManagedConnection(id: ConnectionID(), hostID: hostID, profile: profile, transport: try await factory.open(profile))
        active[hostID] = connection
        return connection
    }

    public func establish(
        hostID: HostID,
        profiles: [ConnectionProfile],
        open: @Sendable (ConnectionProfile) async throws -> any BridgeTransport
    ) async throws -> ManagedConnection {
        if let previous = active.removeValue(forKey: hostID) { await previous.transport.close() }
        var lastFailure: ConnectionFailure = .reachability
        for profile in profiles.sorted(by: { $0.priority < $1.priority }) {
            do {
                let transport = try await open(profile)
                let connection = ManagedConnection(id: ConnectionID(), hostID: hostID, profile: profile, transport: transport)
                active[hostID] = connection
                return connection
            } catch let failure as ConnectionFailure {
                lastFailure = failure
                guard failure.allowsProfileFallback else { throw failure }
            }
        }
        throw lastFailure
    }
    public func activeConnection(for hostID: HostID) -> ManagedConnection? { active[hostID] }
    public func stop(hostID: HostID) async {
        guard let connection = active.removeValue(forKey: hostID) else { return }
        await connection.transport.close()
    }
}
