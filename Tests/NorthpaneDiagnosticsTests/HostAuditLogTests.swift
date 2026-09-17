import Foundation
import Testing
@testable import NorthpaneDiagnostics
@testable import NorthpaneProtocol

@Test func hostAuditPersistsOnlyBoundedMetadataAndPurgesAfterThirtyDays() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-audit-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "audit-v1.bin")
    let key = Data(repeating: 9, count: 32)
    let device = ClientDeviceID(); let now = Date(timeIntervalSince1970: 4_000_000)
    let log = try HostAuditLog(fileURL: file, encryptionKey: key, now: now)
    try await log.append(.init(occurredAt: now.addingTimeInterval(-HostAuditLog.retention - 1), deviceID: device,
        category: "takeover", reference: "pane:opaque", outcome: "applied", reason: "confirmed"), now: now)
    try await log.append(.init(occurredAt: now, deviceID: device, category: "grant", reference: "authorizationBroker",
        outcome: "applied", reason: "strong-confirmation"), now: now)
    #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("authorizationBroker"))
    let reloaded = try HostAuditLog(fileURL: file, encryptionKey: key, now: now)
    #expect(try await reloaded.all(now: now).map(\.category) == ["grant"])
}
