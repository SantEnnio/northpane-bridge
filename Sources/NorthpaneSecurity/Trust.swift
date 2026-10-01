#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import NorthpaneProtocol

public struct HostIdentity: Equatable, Codable, Sendable {
    public let hostID: HostID
    public let signingPublicKey: Data
    public var fingerprint: String { SHA256.hash(data: signingPublicKey).map { String(format: "%02x", $0) }.joined() }
    public init(hostID: HostID, signingPublicKey: Data) { self.hostID = hostID; self.signingPublicKey = signingPublicKey }
}

public struct PairingChallenge: Equatable, Codable, Sendable {
    public let id: UUID
    public let hostID: HostID
    public let nonce: Data
    public let expiresAt: Date
    public init(id: UUID, hostID: HostID, nonce: Data, expiresAt: Date) { self.id = id; self.hostID = hostID; self.nonce = nonce; self.expiresAt = expiresAt }
}

public struct ClientPairingProof: Equatable, Codable, Sendable {
    public let deviceID: ClientDeviceID
    public let challengeID: UUID
    public let publicKey: Data
    public let signature: Data
    public init(deviceID: ClientDeviceID, challengeID: UUID, publicKey: Data, signature: Data) { self.deviceID = deviceID; self.challengeID = challengeID; self.publicKey = publicKey; self.signature = signature }
}

public struct DeviceGrant: Equatable, Codable, Sendable {
    public var grants: Set<GrantKind>
    public init(grants: Set<GrantKind>) { self.grants = grants }
    public func permits(_ capability: Capability) -> Bool {
        guard let descriptor = CapabilityRegistry.descriptors[capability] else { return false }
        return grants.contains(descriptor.requiredGrant)
    }
    public static let standard = DeviceGrant(grants: [.observation, .standardControl])
}

public struct PairedDevice: Equatable, Codable, Sendable {
    public let deviceID: ClientDeviceID
    public let publicKey: Data
    public var grant: DeviceGrant
    public let pairedAt: Date
    /// Set once the device has proved its key in a Bridge session (revision 20), or was paired in
    /// one: from then on its identity merely declared, by a client speaking an older revision, is
    /// no longer accepted. Absent from records written before revision 20, which reads as false.
    public var requiresSessionProof: Bool

    public init(deviceID: ClientDeviceID, publicKey: Data, grant: DeviceGrant, pairedAt: Date, requiresSessionProof: Bool = false) {
        self.deviceID = deviceID; self.publicKey = publicKey; self.grant = grant; self.pairedAt = pairedAt
        self.requiresSessionProof = requiresSessionProof
    }

    private enum CodingKeys: String, CodingKey { case deviceID, publicKey, grant, pairedAt, requiresSessionProof }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(ClientDeviceID.self, forKey: .deviceID)
        publicKey = try container.decode(Data.self, forKey: .publicKey)
        grant = try container.decode(DeviceGrant.self, forKey: .grant)
        pairedAt = try container.decode(Date.self, forKey: .pairedAt)
        requiresSessionProof = try container.decodeIfPresent(Bool.self, forKey: .requiresSessionProof) ?? false
    }
}

public enum PairingError: Error, Equatable, Sendable { case unknownChallenge, expiredChallenge, invalidSignature, revoked, identityMismatch, keyConflict }

/// What a Client device signs to prove, in one Bridge session, that it holds the key the Host
/// paired it with (revision 20). Each field ties the proof to this session: the Host, the device,
/// the connection, what the two ends negotiated, the challenge the Bridge made for this connection
/// and the one the Client made for the Host's identity. A proof made for any other session fails
/// on at least one of them, so it cannot be replayed, nor carried over by whoever relays the bytes.
public struct DeviceSessionStatement: Equatable, Sendable {
    public static let domain = "northpane-device-session-v1"
    public let hostID: HostID
    public let deviceID: ClientDeviceID
    public let connectionID: ConnectionID
    public let protocolMajor: Int
    public let schemaRevision: Int
    public let bridgeChallenge: Data
    public let hostIdentityChallenge: Data

    public init(hostID: HostID, deviceID: ClientDeviceID, connectionID: ConnectionID, protocolMajor: Int, schemaRevision: Int,
                bridgeChallenge: Data, hostIdentityChallenge: Data) {
        self.hostID = hostID; self.deviceID = deviceID; self.connectionID = connectionID
        self.protocolMajor = protocolMajor; self.schemaRevision = schemaRevision
        self.bridgeChallenge = bridgeChallenge; self.hostIdentityChallenge = hostIdentityChallenge
    }

    /// The bytes signed: every field behind its length, so no two statements read the same.
    public var payload: Data {
        var data = Data()
        func field(_ bytes: Data) {
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        field(Data(Self.domain.utf8))
        field(Data(hostID.rawValue.uuidString.utf8))
        field(Data(deviceID.rawValue.uuidString.utf8))
        field(Data(connectionID.rawValue.uuidString.utf8))
        field(Data(String(protocolMajor).utf8))
        field(Data(String(schemaRevision).utf8))
        field(bridgeChallenge)
        field(hostIdentityChallenge)
        return data
    }

    /// Whether `signature` is the given key's over this statement.
    public func isSigned(_ signature: Data, by publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(rawRepresentation: publicKey),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return key.isValidSignature(parsed, for: payload)
    }
}

public func verifyHostIdentity(expectedFingerprint: String, presented: HostIdentity) throws {
    guard expectedFingerprint == presented.fingerprint else { throw PairingError.identityMismatch }
}

public func verifyHostHandshake(hello: HandshakeHello, accepted: HandshakeAccepted) throws -> HostIdentity {
    let identity = HostIdentity(hostID: accepted.hostID, signingPublicKey: accepted.hostSigningPublicKey)
    if let expected = hello.expectedHostFingerprint { try verifyHostIdentity(expectedFingerprint: expected, presented: identity) }
    guard !hello.hostIdentityChallenge.isEmpty,
          let publicKey = try? P256.Signing.PublicKey(rawRepresentation: accepted.hostSigningPublicKey),
          let signature = try? P256.Signing.ECDSASignature(derRepresentation: accepted.hostIdentitySignature),
          publicKey.isValidSignature(signature, for: hello.hostIdentityChallenge) else { throw PairingError.invalidSignature }
    return identity
}

public struct ClientDeviceSigner: Sendable {
    public let deviceID: ClientDeviceID
    private let key: P256.Signing.PrivateKey
    public init(deviceID: ClientDeviceID = ClientDeviceID(), rawPrivateKey: Data? = nil) throws {
        self.deviceID = deviceID
        self.key = try rawPrivateKey.map(P256.Signing.PrivateKey.init(rawRepresentation:)) ?? P256.Signing.PrivateKey()
    }
    public var privateKey: Data { key.rawRepresentation }
    public var publicKey: Data { key.publicKey.rawRepresentation }
    public func prove(_ challenge: PairingChallenge) throws -> ClientPairingProof {
        let signature = try key.signature(for: challengePayload(challenge)).derRepresentation
        return ClientPairingProof(deviceID: deviceID, challengeID: challenge.id, publicKey: publicKey, signature: signature)
    }

    /// Signs one Bridge session's statement (revision 20).
    public func prove(_ statement: DeviceSessionStatement) throws -> Data {
        try key.signature(for: statement.payload).derRepresentation
    }
}

public actor PairingAuthority {
    public nonisolated let identity: HostIdentity
    private let hostKey: P256.Signing.PrivateKey
    private var pending: [UUID: PairingChallenge] = [:]
    private var paired: [ClientDeviceID: PairedDevice] = [:]
    private var revoked: Set<ClientDeviceID> = []

    public init(hostID: HostID = HostID(), rawPrivateKey: Data? = nil, pairedDevices: [PairedDevice] = []) throws {
        let key = try rawPrivateKey.map(P256.Signing.PrivateKey.init(rawRepresentation:)) ?? P256.Signing.PrivateKey()
        self.hostKey = key
        self.identity = HostIdentity(hostID: hostID, signingPublicKey: key.publicKey.rawRepresentation)
        self.paired = Dictionary(uniqueKeysWithValues: pairedDevices.map { ($0.deviceID, $0) })
    }

    public var privateKey: Data { hostKey.rawRepresentation }

    public func signHostIdentityChallenge(_ challenge: Data) throws -> Data {
        try hostKey.signature(for: challenge).derRepresentation
    }

    public func issueChallenge(now: Date = Date(), lifetime: TimeInterval = 120) -> PairingChallenge {
        let challenge = PairingChallenge(id: UUID(), hostID: identity.hostID, nonce: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }), expiresAt: now.addingTimeInterval(lifetime))
        pending[challenge.id] = challenge
        return challenge
    }

    /// Pairs the device that signed the challenge. Pairing is open to whoever reaches the Bridge,
    /// so a device already paired keeps its key: a proof for its ID made with any other key is
    /// refused, or it would hand that device's identity, and its grants, to someone else. The same
    /// key pairing again changes nothing, grants included, except to require the session proof
    /// from then on when asked to.
    public func pair(_ proof: ClientPairingProof, grant: DeviceGrant = .standard, requiresSessionProof: Bool = false, now: Date = Date()) throws -> PairedDevice {
        guard let challenge = pending.removeValue(forKey: proof.challengeID) else { throw PairingError.unknownChallenge }
        guard challenge.expiresAt >= now else { throw PairingError.expiredChallenge }
        let publicKey = try P256.Signing.PublicKey(rawRepresentation: proof.publicKey)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: proof.signature)
        guard publicKey.isValidSignature(signature, for: challengePayload(challenge)) else { throw PairingError.invalidSignature }
        if var existing = paired[proof.deviceID] {
            guard existing.publicKey == proof.publicKey else { throw PairingError.keyConflict }
            if requiresSessionProof { existing.requiresSessionProof = true }
            paired[proof.deviceID] = existing
            revoked.remove(proof.deviceID)
            return existing
        }
        revoked.remove(proof.deviceID)
        let device = PairedDevice(deviceID: proof.deviceID, publicKey: proof.publicKey, grant: grant, pairedAt: now,
                                  requiresSessionProof: requiresSessionProof)
        paired[proof.deviceID] = device
        return device
    }

    /// The paired device whose key signed this session's statement (revision 20).
    public func verifySession(_ statement: DeviceSessionStatement, signature: Data) throws -> PairedDevice {
        guard !revoked.contains(statement.deviceID), let device = paired[statement.deviceID] else { throw PairingError.revoked }
        guard statement.hostID == identity.hostID, statement.isSigned(signature, by: device.publicKey) else { throw PairingError.invalidSignature }
        return device
    }

    /// From now on this device's identity needs the session proof.
    public func requireSessionProof(for deviceID: ClientDeviceID) throws {
        guard var device = paired[deviceID] else { throw PairingError.revoked }
        device.requiresSessionProof = true
        paired[deviceID] = device
    }

    public func pairedDevice(_ deviceID: ClientDeviceID) -> PairedDevice? {
        revoked.contains(deviceID) ? nil : paired[deviceID]
    }

    /// What the pairing file says now: another Bridge process may have paired or revoked a device
    /// since this one read it.
    public func replacePairedDevices(_ devices: [PairedDevice]) {
        paired = Dictionary(devices.map { ($0.deviceID, $0) }, uniquingKeysWith: { first, _ in first })
        revoked.subtract(paired.keys)
    }

    public func authorize(deviceID: ClientDeviceID, capability: Capability) throws {
        guard !revoked.contains(deviceID) else { throw PairingError.revoked }
        guard let device = paired[deviceID] else { throw PairingError.revoked }
        guard device.grant.permits(capability) else { throw PairingError.revoked }
    }

    public func updateGrant(_ grant: DeviceGrant, for deviceID: ClientDeviceID) throws {
        guard var device = paired[deviceID] else { throw PairingError.revoked }
        device.grant = grant
        paired[deviceID] = device
    }

    public func revoke(_ deviceID: ClientDeviceID) { paired.removeValue(forKey: deviceID); revoked.insert(deviceID) }
    public func allPairedDevices() -> [PairedDevice] { paired.values.sorted { $0.deviceID.rawValue.uuidString < $1.deviceID.rawValue.uuidString } }
}

private func challengePayload(_ challenge: PairingChallenge) -> Data {
    var payload = Data(challenge.id.uuidString.utf8)
    payload.append(Data(challenge.hostID.rawValue.uuidString.utf8))
    payload.append(challenge.nonce)
    return payload
}
