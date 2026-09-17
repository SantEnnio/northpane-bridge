import Foundation
import Testing
@testable import NorthpaneBridgeResources
@testable import NorthpaneProtocol

@Test func notificationIsEncryptedDeduplicatedAndNeverActionable() async throws {
    let material = try NotificationRouteMaterial.generate(deviceID: ClientDeviceID(), gatewayURL: URL(string: "https://notifications.northpane.example/")!, lifetime: 60)
    let route = material.route
    let metadata = AttentionNotificationMetadata(attentionID: "a", revision: 3, opaqueHostReference: "opaque",
        agentLabel: "Agent", workspaceLabel: "Workspace")
    let publisher = NotificationPublisher()
    let publication = try #require(try await publisher.publish(metadata, route: route))
    #expect(!String(decoding: publication.ciphertext, as: UTF8.self).contains("opaque"))
    #expect(try await publisher.publish(metadata, route: route) == nil)
    #expect(try NotificationPublisher.decrypt(publication, secret: material.secret) == metadata)
    #expect(!AnnounceNotificationsPolicy.permitsActions)
}

@Test func notificationRoutesPersistAndRevokeExplicitly() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "northpane-routes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let file = base.appending(path: "routes.json")
    let material = try NotificationRouteMaterial.generate(deviceID: ClientDeviceID(), gatewayURL: URL(string: "https://notifications.northpane.example/")!)
    let registry = try NotificationRouteRegistry(fileURL: file)
    try await registry.put(material.route)
    #expect(try await registry.route(id: material.route.id) == material.route)
    let reloaded = try NotificationRouteRegistry(fileURL: file)
    try await reloaded.revoke(material.route.id)
    await #expect(throws: NotificationError.routeUnavailable) { try await reloaded.route(id: material.route.id) }
}

@Test func notificationRouteDeletionIsScopedToOneDevice() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "northpane-routes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let firstDevice = ClientDeviceID(); let secondDevice = ClientDeviceID()
    let first = try NotificationRouteMaterial.generate(deviceID: firstDevice, gatewayURL: URL(string: "https://notifications.northpane.example/")!)
    let second = try NotificationRouteMaterial.generate(deviceID: secondDevice, gatewayURL: URL(string: "https://notifications.northpane.example/")!)
    let registry = try NotificationRouteRegistry(fileURL: base.appending(path: "routes.json"))
    try await registry.put(first.route); try await registry.put(second.route)
    try await registry.removeAll(deviceID: firstDevice)
    #expect(await registry.active(deviceID: firstDevice).isEmpty)
    #expect(await registry.active(deviceID: secondDevice).map(\.id) == [second.route.id])
}

@Test func notificationRegistrationPreferencesAreExplicitAndLegacySafe() throws {
    let routeID = UUID()
    let legacy: [String: Any] = [
        "routeID": routeID.uuidString,
        "apnsDeviceToken": Data(repeating: 1, count: 32).base64EncodedString(),
        "encryptionPublicKey": Data(repeating: 2, count: 32).base64EncodedString(),
        "publisherCapability": Data(repeating: 3, count: 32).base64EncodedString(),
        "topic": "it.ambiens.northpane", "environment": "sandbox",
        "expiresAt": Date().timeIntervalSinceReferenceDate,
    ]
    let registration = try JSONDecoder().decode(NotificationGatewayRegistration.self,
        from: JSONSerialization.data(withJSONObject: legacy))
    #expect(registration.preferredLanguage == "en")
    #expect(!registration.timeSensitive)
}

@Test func successfulNotificationDeliveriesRemainDeduplicatedAfterRestart() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "northpane-deliveries-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let file = base.appending(path: "deliveries.bin")
    let key = Data(repeating: 7, count: 32)
    let routeID = UUID()
    let deviceID = ClientDeviceID()
    let metadata = AttentionNotificationMetadata(attentionID: "pane-1", revision: 4, opaqueHostReference: "opaque")
    let ledger = try NotificationDeliveryLedger(fileURL: file, encryptionKey: key)
    #expect(!(await ledger.contains(routeID: routeID, metadata: metadata, deviceID: deviceID)))
    #expect(try await ledger.claim(routeID: routeID, metadata: metadata, deviceID: deviceID))
    #expect(!(try await ledger.claim(routeID: routeID, metadata: metadata, deviceID: deviceID)))

    let reloaded = try NotificationDeliveryLedger(fileURL: file, encryptionKey: key)
    #expect(await reloaded.contains(routeID: routeID, metadata: metadata, deviceID: deviceID))
    #expect(!(await reloaded.contains(routeID: routeID, metadata: .init(attentionID: "pane-1", revision: 5, opaqueHostReference: "opaque"), deviceID: deviceID)))
    try await reloaded.removeAll(deviceID: deviceID)
    #expect(!(await reloaded.contains(routeID: routeID, metadata: metadata, deviceID: deviceID)))
}
