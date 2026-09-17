import Testing
@testable import NorthpaneConnection
import NorthpaneProtocol

@Test func aStoppedHerdrCanBeStartedAfterEitherDiscoveryProbeFails() {
    let failures = [
        Problem(code: "herdr_event_subscription_failed", locus: .herdr, retry: .afterRefresh,
                recoveryAction: "restartHerdrOrRetry", phase: .events),
        Problem(code: "herdr_snapshot_failed", locus: .herdr, retry: .afterRefresh,
                recoveryAction: "startHerdrOrRetry", phase: .snapshot),
    ]

    for failure in failures {
        #expect(HerdrRecovery.canOfferStart(after: failure, detectedVersion: "0.8.2"))
    }
    #expect(!HerdrRecovery.canOfferStart(after: failures[0], detectedVersion: "unavailable"))
    #expect(!HerdrRecovery.canOfferStart(after: .unauthorized, detectedVersion: "0.8.2"))
}

@Test func anIncompatibleSSHBridgeCanBeReplacedByTheAppWithoutOfferingThatForOtherFailures() {
    #expect(BridgeRecovery.canOfferBundledInstall(after: Problem.incompatibleProtocol, isSSHHost: true))
    #expect(BridgeRecovery.canOfferBundledInstall(after: SystemTransportError.remoteBridgeUnavailable, isSSHHost: true))
    #expect(!BridgeRecovery.canOfferBundledInstall(after: Problem.incompatibleProtocol, isSSHHost: false))
    #expect(!BridgeRecovery.canOfferBundledInstall(after: SystemTransportError.sshAuthenticationFailed, isSSHHost: true))
}

@Test func retryDelayIsBounded() {
    #expect(RetrySchedule().delay(forAttempt: 99, jitter: 0.2) == 30)
    #expect(RetrySchedule().delay(forAttempt: 0) == 1)
}

@Test func aRouteThatReturnsOrChangesEarnsAnImmediateRetryAndNoRouteEarnsNone() {
    let wifi = NetworkPath(isSatisfied: true, routeSignature: ["en0", "192.168.1.1"])
    let otherWiFi = NetworkPath(isSatisfied: true, routeSignature: ["en0", "10.0.0.1"])
    let none = NetworkPath(isSatisfied: false)

    // The first observation says nothing new: a connection attempt is already under way.
    #expect(wifi.reaction(after: nil) == .ignore)
    #expect(wifi.reaction(after: wifi) == .ignore)
    #expect(none.reaction(after: wifi) == .suspendRetries)
    #expect(none.reaction(after: nil) == .suspendRetries)
    #expect(wifi.reaction(after: none) == .retryImmediately)
    // Same interface, different network: the backoff was earned against a route that is gone.
    #expect(otherWiFi.reaction(after: wifi) == .retryImmediately)
}
