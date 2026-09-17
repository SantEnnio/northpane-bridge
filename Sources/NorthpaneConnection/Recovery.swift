import Foundation
import NorthpaneProtocol

/// Decides whether a failed Herdr discovery can be recovered by asking the already-authenticated
/// Bridge to start Herdr on the Host. Installation remains a separate recovery: a Bridge that
/// reported `unavailable` did not find a Herdr executable to start.
public enum HerdrRecovery {
    public static func canOfferStart(after problem: Problem, detectedVersion: String) -> Bool {
        guard detectedVersion != "unavailable" else { return false }
        return problem.code == "herdr_event_subscription_failed"
            || problem.code == "herdr_snapshot_failed"
    }
}

/// Decides when the bundled, locally trusted Bridge is the recovery for a failed connection.
/// Only SSH Hosts are installable by the app: a private endpoint is operated elsewhere, and an
/// authentication failure must never be disguised as a software-version problem.
public enum BridgeRecovery {
    public static func canOfferBundledInstall(after error: Error, isSSHHost: Bool) -> Bool {
        guard isSSHHost else { return false }
        if let problem = error as? Problem {
            return problem.code == Problem.incompatibleProtocol.code
        }
        return error as? SystemTransportError == .remoteBridgeUnavailable
    }
}

public struct RetrySchedule: Equatable, Sendable {
    public let delays: [TimeInterval]
    public init(delays: [TimeInterval] = [1, 2, 5, 10, 30]) { self.delays = delays }
    public func delay(forAttempt attempt: Int, jitter: Double = 0) -> TimeInterval {
        guard !delays.isEmpty else { return 0 }
        let base = delays[min(max(attempt, 0), delays.count - 1)]
        return max(0, min(30, base * (1 + max(-0.2, min(0.2, jitter)))))
    }
}

/// One observation of the network path this Client device would use to reach a Host. It says
/// nothing about the Host: only whether this device has a route at all, and which route it is.
public struct NetworkPath: Equatable, Sendable {
    public let isSatisfied: Bool
    /// The route's identity, used only to notice that the device moved network. Interface names
    /// and gateway addresses change together with the network even when connectivity never drops.
    public let routeSignature: [String]

    public init(isSatisfied: Bool, routeSignature: [String] = []) {
        self.isSatisfied = isSatisfied
        self.routeSignature = routeSignature
    }
}

/// What an observed path change means for a Connection that is waiting on its retry backoff.
/// Reachability is evidence about the route and never about trust: it decides when to try again,
/// never which Host, profile or identity to accept.
public enum NetworkPathReaction: Equatable, Sendable {
    case ignore
    /// The device has no route out. Attempts would fail without telling the Operator anything new.
    case suspendRetries
    /// The device reached a network, or moved to a different one: the backoff earned against the
    /// former route no longer describes this one, so the next attempt is worth making now.
    case retryImmediately
}

extension NetworkPath {
    public func reaction(after previous: NetworkPath?) -> NetworkPathReaction {
        guard isSatisfied else { return .suspendRetries }
        guard let previous else { return .ignore }
        guard previous.isSatisfied else { return .retryImmediately }
        return previous.routeSignature == routeSignature ? .ignore : .retryImmediately
    }
}
