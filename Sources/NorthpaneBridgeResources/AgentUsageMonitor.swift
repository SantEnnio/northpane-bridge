import Foundation
import NorthpaneProtocol

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Holds the last Reading of every agent subscription on the Host and decides when a CLI is run
/// again. The Bridge serves each connection from one loop, and a CLI takes seconds: so a client
/// is always answered at once from what is held, and a Reading that has aged is refreshed
/// behind the answer. Nothing runs while no client asks.
///
/// A Host runs one Bridge process per connection, so what is held lives in a file they share:
/// a client that reconnects finds the numbers already there, and two clients do not make the
/// CLIs run twice. The file holds what a client is sent and nothing more.
public actor AgentUsageMonitor {
    public struct Answer: Equatable, Sendable {
        public let usage: [AgentUsage]
        /// A fresher Reading is on its way: asking again a moment later collects it.
        public let refreshing: Bool
    }

    /// A Reading is reused for five minutes: 288 a day at most for a Host whose clients never
    /// stop asking, which is what a usage surface read on someone else's terms can bear.
    public static let freshness: TimeInterval = 300
    /// A failure that may pass is tried again sooner. One that waits for a person is not.
    public static let retryAfterFailure: TimeInterval = 60
    /// How long another Bridge process is believed when it says it is reading. Past this it
    /// died in the middle, and the Reading is taken over.
    public static let readingPatience: TimeInterval = 120

    private struct Shared: Codable {
        var usage: [AgentUsage] = []
        var attempted: [String: Date] = [:]
        var discoveredAt: Date?
        var readingSince: Date?
    }

    private let discover: @Sendable () -> [any AgentUsageSurface]
    private let readingsFile: URL?
    private let consentFile: URL?
    private let now: @Sendable () -> Date
    /// The agents someone accepted the notice of, for this Host. Kept on the Host so it holds
    /// for every client, and so that no client can be the one that forgot.
    private var consented: Set<String> = []
    private var shared = Shared()
    /// This process is the one reading, and so the one that writes the shared file.
    private var refreshing = false

    /// `discover` finds the agent CLIs installed on the Host. It may block, and is called again
    /// at each refresh: an agent installed or removed while the Bridge runs appears or goes.
    public init(discover: @escaping @Sendable () -> [any AgentUsageSurface], readingsFile: URL? = nil, consentFile: URL? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.discover = discover
        self.readingsFile = readingsFile
        self.consentFile = consentFile
        self.now = now
    }

    /// Accepts or withdraws what reading one agent implies. Withdrawing stops the Readings and
    /// drops what was held; accepting makes the first Reading due.
    public func setConsent(_ granted: Bool, providerID: String) throws -> Answer {
        adopt()
        if granted { consented.insert(providerID) } else { consented.remove(providerID) }
        if let consentFile {
            try FileManager.default.createDirectory(at: consentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(consented.sorted()).write(to: consentFile, options: .atomic)
        }
        shared.attempted[providerID] = nil
        if let index = shared.usage.firstIndex(where: { $0.providerID == providerID && ($0.state == .needsConsent) == granted }) {
            let known = shared.usage[index]
            shared.usage[index] = AgentUsage(providerID: known.providerID, label: known.label, state: granted ? .pending : .needsConsent,
                                             notice: known.notice, noticeURL: known.noticeURL, consentGiven: granted)
        }
        save()
        return current()
    }

    public func current() -> Answer {
        adopt()
        let readElsewhere = !refreshing && shared.readingSince.map { now().timeIntervalSince($0) < Self.readingPatience } == true
        let discoveryIsDue = shared.discoveredAt.map { now().timeIntervalSince($0) >= Self.freshness } ?? true
        if !refreshing, !readElsewhere, discoveryIsDue || shared.usage.contains(where: isDue) {
            refreshing = true
            shared.readingSince = now()
            save()
            Task { await refresh() }
        }
        return Answer(usage: shared.usage, refreshing: refreshing || readElsewhere)
    }

    /// Takes in what the other Bridge processes of this Host wrote. While this one is reading
    /// it is the writer, and only the consent is looked at again.
    private func adopt() {
        if let consentFile {
            consented = Set((try? Data(contentsOf: consentFile)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        }
        guard !refreshing, let readingsFile, let data = try? Data(contentsOf: readingsFile),
              let written = try? JSONDecoder().decode(Shared.self, from: data) else { return }
        shared = written
    }

    private func save() {
        guard let readingsFile, let data = try? JSONEncoder().encode(shared) else { return }
        try? FileManager.default.createDirectory(at: readingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: readingsFile, options: .atomic)
    }

    private func usage(of surface: any AgentUsageSurface, state: AgentUsageState, readAt: Date? = nil, meters: [AgentUsageMeter] = []) -> AgentUsage {
        AgentUsage(providerID: surface.providerID, label: surface.label, state: state, readAt: readAt, meters: meters,
                   notice: surface.notice?.text, noticeURL: surface.notice?.url,
                   consentGiven: surface.needsConsent && consented.contains(surface.providerID))
    }

    private func isDue(_ usage: AgentUsage) -> Bool {
        guard usage.state != .needsConsent else { return false }
        guard let last = shared.attempted[usage.providerID] else { return true }
        let wait = usage.state == .unreachable ? Self.retryAfterFailure : Self.freshness
        return now().timeIntervalSince(last) >= wait
    }

    private func refresh() async {
        let discover = self.discover
        let surfaces = await Self.offTheLoop { discover() }
        adopt()
        // An agent that is not installed has no state: it does not appear and is not missed.
        shared.usage = surfaces.map { surface in
            let waitsForConsent = surface.needsConsent && !consented.contains(surface.providerID)
            if let known = shared.usage.first(where: { $0.providerID == surface.providerID }), (known.state == .needsConsent) == waitsForConsent { return known }
            return usage(of: surface, state: waitsForConsent ? .needsConsent : .pending)
        }
        shared.discoveredAt = now()
        save()
        let due = surfaces.filter { surface in shared.usage.first { $0.providerID == surface.providerID }.map(isDue) ?? false }
        // Each agent has its own speed and its own failures: none waits for another, and what
        // one has read is held as soon as it is read.
        await withTaskGroup(of: Void.self) { group in
            for surface in due {
                group.addTask {
                    let instant = self.now()
                    let outcome: Result<[AgentUsageMeter], AgentUsageFailure> = await Self.offTheLoop {
                        do { return .success(try surface.read(now: instant)) }
                        catch let failure as AgentUsageFailure { return .failure(failure) }
                        catch { return .failure(.unreachable) }
                    }
                    await self.record(outcome, for: surface, at: instant)
                }
            }
        }
        shared.readingSince = nil
        save()
        refreshing = false
    }

    private func record(_ outcome: Result<[AgentUsageMeter], AgentUsageFailure>, for surface: any AgentUsageSurface, at instant: Date) {
        adopt()
        // Consent withdrawn while the CLI was running, here or from another client: what it
        // said is not kept.
        guard let index = shared.usage.firstIndex(where: { $0.providerID == surface.providerID }), shared.usage[index].state != .needsConsent,
              !surface.needsConsent || consented.contains(surface.providerID) else { return }
        shared.attempted[surface.providerID] = instant
        switch outcome {
        case let .success(meters):
            shared.usage[index] = usage(of: surface, state: .measured, readAt: instant, meters: meters)
        case let .failure(failure):
            // No data is not no usage: the older numbers stay, with their age, under the
            // reason the newer attempt failed for.
            shared.usage[index] = usage(of: surface, state: failure.state, readAt: shared.usage[index].readAt, meters: shared.usage[index].meters)
        }
        save()
    }

    /// Runs blocking work on a thread of its own, away from the threads Swift's tasks share.
    private static func offTheLoop<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                #if !os(Windows)
                // A CLI that dies while it is being written to would signal the whole Bridge;
                // on this thread the write fails instead.
                var pipeOnly = sigset_t()
                sigemptyset(&pipeOnly)
                sigaddset(&pipeOnly, SIGPIPE)
                pthread_sigmask(SIG_BLOCK, &pipeOnly, nil)
                #endif
                continuation.resume(returning: work())
            }
        }
    }
}
