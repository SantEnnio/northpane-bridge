import Foundation
import NorthpaneProtocol
import NorthpaneProjection

public struct HerdrRelease: Equatable, Codable, Sendable {
    public let version: String
    public init(version: String) { self.version = version }
}

public enum HerdrCompatibility: Equatable, Sendable { case certified, unsupported, incompatible }

public struct HerdrCompatibilityPolicy: Sendable {
    public let certifiedVersions: Set<String>
    public init(certifiedVersions: Set<String> = HerdrCertifiedReleases.versions) { self.certifiedVersions = certifiedVersions }
    public func classify(_ release: HerdrRelease) -> HerdrCompatibility {
        if certifiedVersions.contains(release.version) { return .certified }
        guard let major = Int(release.version.split(separator: ".").first ?? "") else { return .incompatible }
        return major == 0 ? .unsupported : .incompatible
    }
}

public enum HerdrAdapterError: Error, Equatable, Sendable { case malformedPayload, unsupportedRelease, barrierMismatch }

public struct Herdr082Adapter: Sendable {
    private struct SnapshotPayload: Decodable {
        struct PanePayload: Decodable { let id: String; let title: String }
        let sessionIncarnation: UUID
        let snapshotID: String
        let nextSequence: Int
        let panes: [PanePayload]
    }

    private struct EventPayload: Decodable {
        let sessionIncarnation: UUID
        let snapshotID: String
        let firstSequence: Int
        let events: [Event]
        struct Event: Decodable { let type: String; let id: String; let title: String? }
    }

    public init() {}

    public func decodeSnapshot(_ data: Data, hostID: HostID) throws -> RuntimeSnapshot {
        let payload: SnapshotPayload
        do { payload = try JSONDecoder().decode(SnapshotPayload.self, from: data) }
        catch { throw HerdrAdapterError.malformedPayload }
        return RuntimeSnapshot(hostID: hostID, incarnationID: .init(rawValue: payload.sessionIncarnation), snapshotID: payload.snapshotID, nextEventSequence: payload.nextSequence, panes: payload.panes.map { Pane(id: $0.id, title: $0.title) })
    }

    public func decodeEvents(_ data: Data) throws -> RuntimeEventBatch {
        let payload: EventPayload
        do { payload = try JSONDecoder().decode(EventPayload.self, from: data) }
        catch { throw HerdrAdapterError.malformedPayload }
        let events = try payload.events.map { event -> RuntimeEvent in
            switch event.type {
            case "pane.opened": return .paneOpened(id: event.id, title: event.title ?? "")
            case "pane.closed": return .paneClosed(id: event.id)
            case "pane.renamed": guard let title = event.title else { throw HerdrAdapterError.malformedPayload }; return .paneRenamed(id: event.id, title: title)
            default: throw HerdrAdapterError.malformedPayload
            }
        }
        return RuntimeEventBatch(incarnationID: .init(rawValue: payload.sessionIncarnation), snapshotID: payload.snapshotID, firstSequence: payload.firstSequence, events: events)
    }

    public func verifyBarrier(first: RuntimeSnapshot, second: RuntimeSnapshot) throws {
        guard first.hostID == second.hostID,
              first.incarnationID == second.incarnationID,
              first.snapshotID == second.snapshotID,
              first.nextEventSequence == second.nextEventSequence,
              first.panes == second.panes else { throw HerdrAdapterError.barrierMismatch }
    }
}
