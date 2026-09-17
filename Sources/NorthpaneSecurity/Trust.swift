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
}

public enum PairingError: Error, Equatable, Sendable { case unknownChallenge, expiredChallenge, invalidSignature, revoked, identityMismatch }

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

public struct ClientDeviceSigner {
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

    public func pair(_ proof: ClientPairingProof, grant: DeviceGrant = .standard, now: Date = Date()) throws -> PairedDevice {
        guard let challenge = pending.removeValue(forKey: proof.challengeID) else { throw PairingError.unknownChallenge }
        guard challenge.expiresAt >= now else { throw PairingError.expiredChallenge }
        let publicKey = try P256.Signing.PublicKey(rawRepresentation: proof.publicKey)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: proof.signature)
        guard publicKey.isValidSignature(signature, for: challengePayload(challenge)) else { throw PairingError.invalidSignature }
        revoked.remove(proof.deviceID)
        let device = PairedDevice(deviceID: proof.deviceID, publicKey: proof.publicKey, grant: grant, pairedAt: now)
        paired[proof.deviceID] = device
        return device
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
