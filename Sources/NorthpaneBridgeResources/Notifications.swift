#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NorthpaneProtocol

public struct NotificationRoute: Equatable, Codable, Sendable {
    public let id: UUID
    public let deviceID: ClientDeviceID
    public let encryptionPublicKey: Data
    public let publisherCapability: Data
    public let gatewayURL: URL
    public let expiresAt: Date
    public var lastUsedAt: Date
    public var revokedAt: Date?

    public init(id: UUID = UUID(), deviceID: ClientDeviceID, encryptionPublicKey: Data, publisherCapability: Data, gatewayURL: URL, expiresAt: Date, lastUsedAt: Date = Date(), revokedAt: Date? = nil) {
        self.id = id; self.deviceID = deviceID; self.encryptionPublicKey = encryptionPublicKey
        self.publisherCapability = publisherCapability; self.gatewayURL = gatewayURL
        self.expiresAt = expiresAt; self.lastUsedAt = lastUsedAt; self.revokedAt = revokedAt
    }
}

public struct NotificationRouteSecret: Equatable, Codable, Sendable {
    public let routeID: UUID
    public let privateKey: Data
    public init(routeID: UUID, privateKey: Data) { self.routeID = routeID; self.privateKey = privateKey }
}

public struct NotificationRouteMaterial: Sendable {
    public let route: NotificationRoute
    public let secret: NotificationRouteSecret

    public init(route: NotificationRoute, secret: NotificationRouteSecret) { self.route = route; self.secret = secret }

    public static func generate(deviceID: ClientDeviceID, gatewayURL: URL, lifetime: TimeInterval = 90 * 24 * 60 * 60, now: Date = Date()) throws -> NotificationRouteMaterial {
        guard gatewayURL.scheme == "https", lifetime > 0, lifetime <= 90 * 24 * 60 * 60 else { throw NotificationError.invalidRoute }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let id = UUID()
        let route = NotificationRoute(
            id: id, deviceID: deviceID, encryptionPublicKey: key.publicKey.rawRepresentation,
            publisherCapability: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }),
            gatewayURL: gatewayURL, expiresAt: now.addingTimeInterval(lifetime), lastUsedAt: now
        )
        return .init(route: route, secret: .init(routeID: id, privateKey: key.rawRepresentation))
    }
}

public struct AttentionNotificationMetadata: Equatable, Codable, Sendable {
    public let attentionID: String
    public let revision: Int
    public let opaqueHostReference: String
    public let agentLabel: String?
    public let workspaceLabel: String?
    public init(attentionID: String, revision: Int, opaqueHostReference: String,
                agentLabel: String? = nil, workspaceLabel: String? = nil) {
        self.attentionID = attentionID; self.revision = revision; self.opaqueHostReference = opaqueHostReference
        self.agentLabel = agentLabel; self.workspaceLabel = workspaceLabel
    }
}

public struct EncryptedNotification: Equatable, Codable, Sendable {
    public let routeID: UUID
    public let ephemeralPublicKey: Data
    public let ciphertext: Data
    public let publicAlert: String
    public init(routeID: UUID, ephemeralPublicKey: Data, ciphertext: Data, publicAlert: String) {
        self.routeID = routeID; self.ephemeralPublicKey = ephemeralPublicKey; self.ciphertext = ciphertext; self.publicAlert = publicAlert
    }
}

public enum NotificationError: Error, Equatable, Sendable {
    case invalidKey, invalidRoute, routeUnavailable, malformedPayload, gatewayRejected(Int), corruptStore
}

public actor NotificationRouteRegistry {
    private struct Document: Codable { let schemaVersion: Int; let routes: [NotificationRoute] }
    private let fileURL: URL
    private let encryptionKey: SymmetricKey?
    private var routes: [UUID: NotificationRoute] = [:]

    public init(fileURL: URL, encryptionKey: Data? = nil) throws {
        self.fileURL = fileURL
        guard encryptionKey == nil || encryptionKey?.count == 32 else { throw NotificationError.invalidKey }
        self.encryptionKey = encryptionKey.map(SymmetricKey.init(data:))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let stored = try Data(contentsOf: fileURL)
                let clear = if let key = self.encryptionKey {
                    try AES.GCM.open(AES.GCM.SealedBox(combined: stored), using: key)
                } else { stored }
                let document = try JSONDecoder().decode(Document.self, from: clear)
                guard document.schemaVersion == 1 else { throw NotificationError.corruptStore }
                routes = Dictionary(uniqueKeysWithValues: document.routes.map { ($0.id, $0) })
            } catch let error as NotificationError { throw error }
            catch { throw NotificationError.corruptStore }
        }
    }

    public func put(_ route: NotificationRoute) throws {
        guard route.gatewayURL.scheme == "https", route.encryptionPublicKey.count == 32, route.publisherCapability.count >= 32 else { throw NotificationError.invalidRoute }
        routes[route.id] = route
        try persist()
    }

    public func active(now: Date = Date()) -> [NotificationRoute] {
        routes.values.filter { $0.revokedAt == nil && $0.expiresAt >= now && $0.lastUsedAt.addingTimeInterval(90 * 24 * 60 * 60) >= now }
    }

    public func active(deviceID: ClientDeviceID, now: Date = Date()) -> [NotificationRoute] {
        active(now: now).filter { $0.deviceID == deviceID }
    }

    public func route(id: UUID, now: Date = Date()) throws -> NotificationRoute {
        guard let route = routes[id], route.revokedAt == nil, route.expiresAt >= now else { throw NotificationError.routeUnavailable }
        return route
    }

    public func markUsed(_ id: UUID, now: Date = Date()) throws {
        guard var route = routes[id], route.revokedAt == nil, route.expiresAt >= now else { throw NotificationError.routeUnavailable }
        route.lastUsedAt = now
        routes[id] = route
        try persist()
    }

    public func revoke(_ id: UUID, now: Date = Date()) throws {
        guard var route = routes[id] else { throw NotificationError.routeUnavailable }
        route.revokedAt = now
        routes[id] = route
        try persist()
    }

    public func revokeAll(deviceID: ClientDeviceID, now: Date = Date()) throws {
        for (id, var route) in routes where route.deviceID == deviceID && route.revokedAt == nil {
            route.revokedAt = now
            routes[id] = route
        }
        try persist()
    }

    public func removeAll(deviceID: ClientDeviceID) throws {
        routes = routes.filter { $0.value.deviceID != deviceID }
        try persist()
    }

    public func removeAll() throws { routes.removeAll(); try persist() }

    private func persist() throws {
        let document = Document(schemaVersion: 1, routes: routes.values.sorted { $0.id.uuidString < $1.id.uuidString })
        let clear = try JSONEncoder().encode(document)
        let stored = if let encryptionKey { try AES.GCM.seal(clear, using: encryptionKey).combined! } else { clear }
        try stored.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public actor NotificationPublisher {
    private var sent: Set<String> = []
    private var recentByHost: [String: [Date]] = [:]
    public init() {}

    public func publish(_ metadata: AttentionNotificationMetadata, route: NotificationRoute, now: Date = Date()) throws -> EncryptedNotification? {
        guard route.encryptionPublicKey.count == 32 else { throw NotificationError.invalidKey }
        guard route.revokedAt == nil, route.expiresAt >= now else { throw NotificationError.routeUnavailable }
        let deduplicationKey = "\(route.id.uuidString):\(metadata.attentionID):\(metadata.revision):\(route.deviceID.rawValue.uuidString)"
        guard sent.insert(deduplicationKey).inserted else { return nil }
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: route.encryptionPublicKey)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(route.id.uuidString.utf8), sharedInfo: Data("northpane-notification-v1".utf8), outputByteCount: 32)
        let sealed = try ChaChaPoly.seal(try JSONEncoder().encode(metadata), using: key)
        var times = recentByHost[metadata.opaqueHostReference, default: []].filter { now.timeIntervalSince($0) <= 60 }
        times.append(now)
        recentByHost[metadata.opaqueHostReference] = times
        let alert = times.count > 3 ? "Northpane has several new items on one Host" : "Northpane needs your attention"
        return .init(routeID: route.id, ephemeralPublicKey: ephemeral.publicKey.rawRepresentation, ciphertext: sealed.combined, publicAlert: alert)
    }

    public static func decrypt(_ notification: EncryptedNotification, secret: NotificationRouteSecret) throws -> AttentionNotificationMetadata {
        guard notification.routeID == secret.routeID, secret.privateKey.count == 32, notification.ephemeralPublicKey.count == 32 else { throw NotificationError.invalidKey }
        do {
            let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret.privateKey)
            let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: notification.ephemeralPublicKey)
            let shared = try recipient.sharedSecretFromKeyAgreement(with: ephemeral)
            let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(secret.routeID.uuidString.utf8), sharedInfo: Data("northpane-notification-v1".utf8), outputByteCount: 32)
            let clear = try ChaChaPoly.open(try ChaChaPoly.SealedBox(combined: notification.ciphertext), using: key)
            return try JSONDecoder().decode(AttentionNotificationMetadata.self, from: clear)
        } catch { throw NotificationError.malformedPayload }
    }
}

/// Persists notification publication claims so restarting the Bridge cannot
/// publish the same attention revision to the same device a second time.
public actor NotificationDeliveryLedger {
    private struct Entry: Codable, Sendable {
        let key: String
        let deliveredAt: Date
    }
    private struct Document: Codable, Sendable {
        let schemaVersion: Int
        let entries: [Entry]
    }

    private let fileURL: URL
    private let encryptionKey: SymmetricKey
    private let retention: TimeInterval
    private var entries: [String: Date]

    public init(fileURL: URL, encryptionKey: Data, retention: TimeInterval = 90 * 24 * 60 * 60) throws {
        guard encryptionKey.count == 32 else { throw NotificationError.invalidKey }
        self.fileURL = fileURL
        self.encryptionKey = SymmetricKey(data: encryptionKey)
        self.retention = retention
        self.entries = [:]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let stored = try Data(contentsOf: fileURL)
                let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: stored), using: self.encryptionKey)
                let document = try JSONDecoder().decode(Document.self, from: clear)
                guard document.schemaVersion == 1 else { throw NotificationError.corruptStore }
                self.entries = Dictionary(document.entries.map { ($0.key, $0.deliveredAt) }, uniquingKeysWith: max)
            } catch let error as NotificationError { throw error }
            catch { throw NotificationError.corruptStore }
        }
    }

    public func contains(routeID: UUID, metadata: AttentionNotificationMetadata, deviceID: ClientDeviceID,
                         now: Date = Date()) -> Bool {
        purge(before: now.addingTimeInterval(-retention))
        return entries[Self.key(routeID: routeID, metadata: metadata, deviceID: deviceID)] != nil
    }

    public func record(routeID: UUID, metadata: AttentionNotificationMetadata, deviceID: ClientDeviceID,
                       now: Date = Date()) throws {
        purge(before: now.addingTimeInterval(-retention))
        entries[Self.key(routeID: routeID, metadata: metadata, deviceID: deviceID)] = now
        try persist()
    }

    public func claim(routeID: UUID, metadata: AttentionNotificationMetadata, deviceID: ClientDeviceID,
                      now: Date = Date()) throws -> Bool {
        purge(before: now.addingTimeInterval(-retention))
        let key = Self.key(routeID: routeID, metadata: metadata, deviceID: deviceID)
        guard entries[key] == nil else { return false }
        entries[key] = now
        try persist()
        return true
    }

    public func removeAll(deviceID: ClientDeviceID) throws {
        let suffix = ":\(deviceID.rawValue.uuidString)"
        entries = entries.filter { !$0.key.hasSuffix(suffix) }
        try persist()
    }

    private static func key(routeID: UUID, metadata: AttentionNotificationMetadata, deviceID: ClientDeviceID) -> String {
        "\(routeID.uuidString):\(metadata.attentionID):\(metadata.revision):\(deviceID.rawValue.uuidString)"
    }

    private func purge(before cutoff: Date) {
        entries = entries.filter { $0.value >= cutoff }
    }

    private func persist() throws {
        let document = Document(schemaVersion: 1, entries: entries.map(Entry.init(key:deliveredAt:)).sorted { $0.key < $1.key })
        let clear = try JSONEncoder().encode(document)
        let stored = try AES.GCM.seal(clear, using: encryptionKey).combined!
        try stored.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public protocol NotificationGatewayTransport: Sendable {
    func register(_ material: NotificationRouteMaterial, apnsDeviceToken: Data, topic: String,
                  environment: APNsEnvironment, preferredLanguage: String, timeSensitive: Bool) async throws
    func publish(_ notification: EncryptedNotification, using route: NotificationRoute) async throws
    func revoke(_ route: NotificationRoute) async throws
}

public enum APNsEnvironment: String, Codable, Sendable { case sandbox, production }

public struct NotificationGatewayRegistration: Codable, Sendable {
    public let routeID: UUID
    public let apnsDeviceToken: Data
    public let encryptionPublicKey: Data
    public let publisherCapability: Data
    public let topic: String
    public let environment: APNsEnvironment
    public let expiresAt: Date
    public let preferredLanguage: String
    public let timeSensitive: Bool
    public init(routeID: UUID, apnsDeviceToken: Data, encryptionPublicKey: Data, publisherCapability: Data,
                topic: String, environment: APNsEnvironment, expiresAt: Date,
                preferredLanguage: String, timeSensitive: Bool) {
        self.routeID = routeID; self.apnsDeviceToken = apnsDeviceToken; self.encryptionPublicKey = encryptionPublicKey
        self.publisherCapability = publisherCapability; self.topic = topic; self.environment = environment; self.expiresAt = expiresAt
        self.preferredLanguage = preferredLanguage; self.timeSensitive = timeSensitive
    }

    private enum CodingKeys: String, CodingKey {
        case routeID, apnsDeviceToken, encryptionPublicKey, publisherCapability, topic, environment, expiresAt
        case preferredLanguage, timeSensitive
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        routeID = try values.decode(UUID.self, forKey: .routeID)
        apnsDeviceToken = try values.decode(Data.self, forKey: .apnsDeviceToken)
        encryptionPublicKey = try values.decode(Data.self, forKey: .encryptionPublicKey)
        publisherCapability = try values.decode(Data.self, forKey: .publisherCapability)
        topic = try values.decode(String.self, forKey: .topic)
        environment = try values.decode(APNsEnvironment.self, forKey: .environment)
        expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        preferredLanguage = try values.decodeIfPresent(String.self, forKey: .preferredLanguage) ?? "en"
        timeSensitive = try values.decodeIfPresent(Bool.self, forKey: .timeSensitive) ?? false
    }
}

public struct HTTPSNotificationGatewayTransport: NotificationGatewayTransport {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        self.session = URLSession(configuration: configuration)
    }
    public func register(_ material: NotificationRouteMaterial, apnsDeviceToken: Data, topic: String,
                         environment: APNsEnvironment, preferredLanguage: String, timeSensitive: Bool) async throws {
        guard !apnsDeviceToken.isEmpty, !topic.isEmpty else { throw NotificationError.invalidRoute }
        let route = material.route
        let registration = NotificationGatewayRegistration(routeID: route.id, apnsDeviceToken: apnsDeviceToken,
            encryptionPublicKey: route.encryptionPublicKey, publisherCapability: route.publisherCapability,
            topic: topic, environment: environment, expiresAt: route.expiresAt,
            preferredLanguage: preferredLanguage, timeSensitive: timeSensitive)
        try await send(path: "v1/routes", body: try JSONEncoder().encode(registration), route: route, includeCapability: false)
    }
    public func publish(_ notification: EncryptedNotification, using route: NotificationRoute) async throws {
        try await send(path: "v1/routes/\(route.id.uuidString)/publications", body: try JSONEncoder().encode(notification), route: route)
    }
    public func revoke(_ route: NotificationRoute) async throws {
        try await send(path: "v1/routes/\(route.id.uuidString)/revoke", body: Data(), route: route)
    }
    private func send(path: String, body: Data, route: NotificationRoute, includeCapability: Bool = true) async throws {
        guard route.gatewayURL.scheme == "https", let url = URL(string: path, relativeTo: route.gatewayURL)?.absoluteURL else { throw NotificationError.invalidRoute }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if includeCapability { request.setValue(route.publisherCapability.base64EncodedString(), forHTTPHeaderField: "Northpane-Publisher-Capability") }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw NotificationError.gatewayRejected((response as? HTTPURLResponse)?.statusCode ?? 0) }
    }
}

public enum AnnounceNotificationsPolicy {
    public static let permitsSensitiveContent = false
    public static let permitsActions = false
}
