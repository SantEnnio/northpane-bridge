import Foundation

public enum TransportKind: String, CaseIterable, Codable, Sendable { case localIPC, ssh, privateEndpoint }

public struct CredentialReference: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ConnectionProfile: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let kind: TransportKind
    public var endpoint: String?
    public var priority: Int
    public var credentialReference: CredentialReference?
    public var expectedHostFingerprint: String?
    /// Transport-level trust pin (for example an SSH SHA-256 host-key fingerprint).
    /// This is deliberately distinct from the signed Northpane Host identity pin.
    public var expectedTransportFingerprint: String?
    /// The tailnet this profile was last reached on, recorded from a connection that worked while
    /// the Client could read Tailscale's state; never inferred. Absent for Hosts outside any
    /// tailnet and on Clients that cannot read the tunnel. Lives and dies with the Host.
    public var lastReachedTailnet: String?
    /// Which shell answers an SSH session on the Host, learned from a connection that worked: a
    /// POSIX Host runs `sh`, a Windows Host `cmd.exe`, and the command that starts the Bridge is
    /// written differently for each. Absent until a connection settles it.
    public var hostShell: HostShell?
    /// The Mac that carries this device's SSH session to the Host, when the Host is reached through
    /// one; `endpoint` then holds the account to sign in with and the Host's address as that Mac
    /// reached it when the route was saved. The device names the Host to the relay by its ID, and
    /// the Mac dials it where it reaches it now. Absent for a direct route.
    public var relay: RelayProfile?

    public init(id: UUID = UUID(), kind: TransportKind, endpoint: String? = nil, priority: Int = 0, credentialReference: CredentialReference? = nil, expectedHostFingerprint: String? = nil, expectedTransportFingerprint: String? = nil, lastReachedTailnet: String? = nil, hostShell: HostShell? = nil, relay: RelayProfile? = nil) {
        self.id = id; self.kind = kind; self.endpoint = endpoint; self.priority = priority; self.credentialReference = credentialReference; self.expectedHostFingerprint = expectedHostFingerprint; self.expectedTransportFingerprint = expectedTransportFingerprint; self.lastReachedTailnet = lastReachedTailnet; self.hostShell = hostShell; self.relay = relay
    }
}

/// A Mac of the Operator's that relays this device's own SSH session to a Host the device may not
/// reach by itself: where it listens and the key it must show.
public struct RelayProfile: Equatable, Codable, Sendable {
    /// The Mac's name, for the route the device shows.
    public var name: String
    /// Where the relay listens, tried in order: the tailnet first, then the local network.
    public var addresses: [String]
    public var port: Int
    public var hostKeyFingerprint: String

    public init(name: String, addresses: [String], port: Int, hostKeyFingerprint: String) {
        self.name = name; self.addresses = addresses; self.port = port; self.hostKeyFingerprint = hostKeyFingerprint
    }
}

/// The shell an SSH session lands in on the Host.
public enum HostShell: String, Codable, Sendable, CaseIterable {
    case posix, windows
}
