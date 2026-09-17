import Foundation
import Testing
import NorthpaneProtocol
@testable import NorthpaneConnection

private let activeSuffix = "tail1234ab.ts.net"

private func state(
    running: Bool = true,
    peers: [TailnetPeer] = [],
    profiles: [TailnetProfile] = [
        .init(id: "14ca", tailnet: "operator.github", account: "operator@github", isActive: true),
        .init(id: "68da", tailnet: "vpn.example.org", account: "operator@example.org", isActive: false),
    ]
) -> TailnetState {
    TailnetState(isRunning: running, currentTailnet: "operator.github", magicDNSSuffix: activeSuffix, peers: peers, profiles: profiles)
}

@Test func anEndpointReducesToItsHost() {
    #expect(TailnetAddress.host(inEndpoint: "dev@studio-mac") == "studio-mac")
    #expect(TailnetAddress.host(inEndpoint: "atelier.tail1234ab.ts.net:22") == "atelier.tail1234ab.ts.net")
    #expect(TailnetAddress.host(inEndpoint: " user@100.101.102.103 ") == "100.101.102.103")
    #expect(TailnetAddress.host(inEndpoint: "[fd7a:115c:a1e0::1]") == "[fd7a:115c:a1e0::1]")
}

@Test func onlyTheCarrierGradeRangeIsATailscaleAddress() {
    #expect(TailnetAddress.isTailscaleIP("100.101.102.103"))
    #expect(TailnetAddress.isTailscaleIP("100.127.255.255"))
    // 100.0.0.1 and 100.128.0.1 sit outside 100.64.0.0/10 and are ordinary public addresses.
    #expect(!TailnetAddress.isTailscaleIP("100.0.0.1"))
    #expect(!TailnetAddress.isTailscaleIP("100.128.0.1"))
    #expect(!TailnetAddress.isTailscaleIP("192.168.1.20"))
    #expect(!TailnetAddress.isTailscaleIP("studio-mac"))
}

@Test func aMagicDNSNameCarriesItsTailnetSuffix() {
    #expect(TailnetAddress.magicDNSSuffix(of: "atelier.tail1234ab.ts.net") == "tail1234ab.ts.net")
    #expect(TailnetAddress.magicDNSSuffix(of: "atelier.tail1234ab.ts.net.") == "tail1234ab.ts.net")
    #expect(TailnetAddress.magicDNSSuffix(of: "studio-mac") == nil)
    #expect(TailnetAddress.magicDNSSuffix(of: "example.com") == nil)
}

/// The Host reached over the LAN, which is how the real test Host is configured: the tailnets have
/// nothing to say about it and must stay quiet rather than offer an irrelevant switch.
@Test func anAddressThatIsNotOnATailnetGetsNoAdvice() {
    #expect(TailnetAdvisor.advice(forEndpoint: "dev@studio-mac", state: state()) == .none)
    #expect(TailnetAdvisor.advice(forEndpoint: "user@192.168.1.20", state: state()) == .none)
}

/// On iOS and iPadOS an app cannot reach the Tailscale tunnel, so the state is always absent. The
/// address still says it is a tailnet one, and naming the question beats saying nothing.
@Test func withoutTailscaleStateATailnetAddressStillNamesTheQuestion() {
    #expect(TailnetAdvisor.advice(forEndpoint: "atelier.tail1234ab.ts.net", state: nil) == .cannotTellFromHere)
    #expect(TailnetAdvisor.advice(forEndpoint: "user@100.101.102.103", state: nil) == .cannotTellFromHere)
    // An address that is not on a tailnet says nothing either way.
    #expect(TailnetAdvisor.advice(forEndpoint: "dev@studio-mac", state: nil) == .none)
}

@Test func aTailscaleAddressWithTheTunnelDownNamesThatFirst() {
    #expect(TailnetAdvisor.advice(forEndpoint: "atelier.tail1234ab.ts.net", state: state(running: false)) == .tailscaleNotRunning)
    #expect(TailnetAdvisor.advice(forEndpoint: "100.101.102.103", state: state(running: false)) == .tailscaleNotRunning)
}

/// Tailscale's own answer about a peer beats any guess about tailnets: suggesting a switch here
/// would send the Operator to the wrong place.
@Test func aPeerOfTheActiveTailnetThatIsOfflineIsNotATailnetProblem() {
    let peers = [TailnetPeer(dnsName: "tablet.\(activeSuffix)", addresses: ["100.88.247.106"], isOnline: false)]
    #expect(TailnetAdvisor.advice(forEndpoint: "tablet.\(activeSuffix)", state: state(peers: peers))
        == .peerOffline(name: "tablet.\(activeSuffix)"))
    // The short MagicDNS name and the Tailscale address reach the same peer.
    #expect(TailnetAdvisor.advice(forEndpoint: "tablet", state: state(peers: peers)) == .none)
    #expect(TailnetAdvisor.advice(forEndpoint: "100.88.247.106", state: state(peers: peers))
        == .peerOffline(name: "tablet.\(activeSuffix)"))
}

@Test func aPeerThatTailscaleReportsOnlineLeavesTheFailureUnexplained() {
    let peers = [TailnetPeer(dnsName: "atelier.\(activeSuffix)", addresses: ["100.101.102.103"], isOnline: true)]
    #expect(TailnetAdvisor.advice(forEndpoint: "atelier.\(activeSuffix)", state: state(peers: peers)) == .none)
}

@Test func anAddressOfAnotherTailnetOffersTheProfilesThisDeviceHolds() {
    let advice = TailnetAdvisor.advice(forEndpoint: "portal.tail9999.ts.net", state: state())
    guard case .addressOnAnotherTailnet(let active, let alternatives) = advice else {
        Issue.record("expected another-tailnet advice, got \(advice)"); return
    }
    #expect(active == "operator.github")
    #expect(alternatives.map(\.tailnet) == ["vpn.example.org"])
}

/// A MagicDNS name of the active tailnet that is simply not a peer: the tailnet is right, so
/// switching is not the answer and nothing is offered.
@Test func anUnknownNameOnTheActiveTailnetOffersNoSwitch() {
    #expect(TailnetAdvisor.advice(forEndpoint: "ghost.\(activeSuffix)", state: state()) == .none)
}

@Test func withNoOtherProfileThereIsNowhereToSwitch() {
    let single = [TailnetProfile(id: "14ca", tailnet: "operator.github", account: "operator@github", isActive: true)]
    #expect(TailnetAdvisor.advice(forEndpoint: "portal.tail9999.ts.net", state: state(profiles: single)) == .none)
}

#if os(macOS)
/// Decoded from the real shapes `tailscale status --json` and `tailscale switch --list --json`
/// printed on this machine on 2026-09-10, trimmed to the fields Northpane reads.
@Test func theRealCommandOutputDecodes() throws {
    let status = Data("""
    {"BackendState":"Running",
     "MagicDNSSuffix":"tail1234ab.ts.net",
     "CurrentTailnet":{"Name":"operator.github","MagicDNSSuffix":"tail1234ab.ts.net","MagicDNSEnabled":true},
     "Self":{"HostName":"192","DNSName":"192.tail1234ab.ts.net.","TailscaleIPs":["100.72.8.93"],"Online":true},
     "Peer":{"key1":{"HostName":"atelier","DNSName":"atelier.tail1234ab.ts.net.","TailscaleIPs":["100.101.102.103"],"Online":true},
             "key2":{"HostName":"localhost","DNSName":"tablet.tail1234ab.ts.net.","TailscaleIPs":["100.88.247.106"],"Online":false}}}
    """.utf8)
    let profiles = Data("""
    [{"id":"14ca","nickname":"operator@github","tailnet":"operator.github","account":"operator@github","selected":true},
     {"id":"68da","nickname":"operator@example.org","tailnet":"vpn.example.org","account":"operator@example.org","selected":false}]
    """.utf8)
    let decodedProfiles = try #require(TailscaleCommand.decodeProfiles(profiles))
    let decoded = try #require(TailscaleCommand.decodeState(status, profiles: decodedProfiles))
    #expect(decoded.isRunning)
    #expect(decoded.currentTailnet == "operator.github")
    #expect(decoded.magicDNSSuffix == "tail1234ab.ts.net")
    // The trailing dot of a MagicDNS name is dropped, so peers compare against an endpoint.
    #expect(decoded.peers.map(\.dnsName) == ["atelier.tail1234ab.ts.net", "tablet.tail1234ab.ts.net"])
    #expect(decoded.peers.map(\.isOnline) == [true, false])
    #expect(decoded.profiles.filter(\.isActive).map(\.tailnet) == ["operator.github"])
    #expect(decoded.profiles.filter { !$0.isActive }.map(\.tailnet) == ["vpn.example.org"])
}
#endif

/// A tailnet may carry a custom MagicDNS suffix instead of `<name>.ts.net`: `vpn.example.org` answers
/// as `ts.example.org` on this device. Without the active suffix such a Host reads as an ordinary name.
@Test func aCustomMagicDNSSuffixIsRecognisedThroughTheActiveTailnet() {
    #expect(!TailnetAddress.isTailnetAddress("portal.ts.example.org", activeSuffix: nil))
    #expect(TailnetAddress.isTailnetAddress("portal.ts.example.org", activeSuffix: "ts.example.org"))
    #expect(TailnetAddress.isTailnetAddress("atelier.tail1234ab.ts.net", activeSuffix: nil))
    #expect(TailnetAddress.isTailnetAddress("100.101.102.103", activeSuffix: nil))
    #expect(!TailnetAddress.isTailnetAddress("studio-mac", activeSuffix: "ts.example.org"))
}

/// A Host under the active tailnet's custom suffix that is not a peer: the tailnet is already the
/// right one, so no switch is offered.
@Test func aHostUnderTheActiveCustomSuffixOffersNoSwitch() {
    let custom = TailnetState(isRunning: true, currentTailnet: "vpn.example.org", magicDNSSuffix: "ts.example.org",
                              peers: [], profiles: [
                                .init(id: "68da", tailnet: "vpn.example.org", account: "operator@example.org", isActive: true),
                                .init(id: "14ca", tailnet: "operator.github", account: "operator@github", isActive: false),
                              ])
    #expect(TailnetAdvisor.advice(forEndpoint: "portal.ts.example.org", state: custom) == .none)
}

/// The switch that looked broken. `tailscale switch` carries each profile's own on/off state, so
/// the account changed and its tunnel stayed down — measured on this device on 2026-09-11, with
/// `BackendState: Stopped` and `LoggedOut: false`. That is one command from working, and is not the
/// same answer as a tailnet that wants a browser login.
@Test func aSwitchIsReadByWhatTailscaleActuallyReports() {
    let profile = TailnetProfile(id: "68da", tailnet: "vpn.example.org", account: "operator@example.org", isActive: true)
    func state(_ backend: String, tailnet: String = "vpn.example.org") -> TailnetState {
        TailnetState(backendState: backend, currentTailnet: tailnet, magicDNSSuffix: "ts.example.org", peers: [], profiles: [profile])
    }
    #expect(TailnetAdvisor.outcome(after: profile, state: state("Running")) == .active(tailnet: "vpn.example.org"))
    #expect(TailnetAdvisor.outcome(after: profile, state: state("Stopped")) == .stoppedAndStartable(tailnet: "vpn.example.org"))
    #expect(TailnetAdvisor.outcome(after: profile, state: state("NeedsLogin")) == .needsTailscaleLogin(tailnet: "vpn.example.org"))
    #expect(TailnetAdvisor.outcome(after: profile, state: state("NeedsMachineAuth")) == .needsTailscaleLogin(tailnet: "vpn.example.org"))
    #expect(TailnetAdvisor.outcome(after: profile, state: state("Starting")) == .notReady(tailnet: "vpn.example.org", backendState: "Starting"))
    #expect(TailnetAdvisor.outcome(after: profile, state: state("NoState")) == .notReady(tailnet: "vpn.example.org", backendState: "NoState"))
    // "On another account" has to be said by the profile list, which is what actually knows it.
    let elsewhere = TailnetState(
        backendState: "Running", currentTailnet: "operator.github", magicDNSSuffix: "tail1234ab.ts.net", peers: [],
        profiles: [
            .init(id: "14ca", tailnet: "operator.github", account: "operator@github", isActive: true),
            .init(id: "68da", tailnet: "vpn.example.org", account: "operator@example.org", isActive: false),
        ]
    )
    #expect(TailnetAdvisor.outcome(after: profile, state: elsewhere) == .notChanged)
    #expect(TailnetAdvisor.outcome(after: profile, state: nil) == .notChanged)
}

/// Only `Running` carries traffic, and only `Stopped` can be raised without a browser. Nothing else
/// may be treated as either.
@Test func theBackendStateIsNotReducedToABoolean() {
    func state(_ backend: String) -> TailnetState {
        TailnetState(backendState: backend, currentTailnet: "vpn.example.org", magicDNSSuffix: "ts.example.org", peers: [], profiles: [])
    }
    #expect(state("Running").isRunning)
    #expect(!state("Stopped").isRunning)
    #expect(state("Stopped").isStoppedButLoggedIn)
    #expect(!state("NeedsLogin").isStoppedButLoggedIn)
    #expect(state("NeedsLogin").needsTailscaleLogin)
    #expect(state("NeedsMachineAuth").needsTailscaleLogin)
    #expect(!state("NoState").isStoppedButLoggedIn)
    #expect(!state("NoState").needsTailscaleLogin)
}

/// The state measured 0.8s after switching to a profile whose tunnel is stopped: the profile list
/// already says the account changed, while `status` has no `CurrentTailnet` at all — there is no
/// netmap for a stopped profile yet. Reading the account from `currentTailnet` called this a failed
/// switch and told the Operator so, twice.
@Test func theAccountIsReadFromTheProfileListNotFromTheNetmap() {
    let profile = TailnetProfile(id: "68da", tailnet: "vpn.example.org", account: "operator@example.org", isActive: true)
    let justSwitched = TailnetState(
        backendState: "Stopped",
        currentTailnet: nil,
        magicDNSSuffix: nil,
        peers: [],
        profiles: [
            profile,
            .init(id: "14ca", tailnet: "operator.github", account: "operator@github", isActive: false),
        ]
    )
    #expect(justSwitched.activeTailnet == "vpn.example.org")
    #expect(TailnetAdvisor.outcome(after: profile, state: justSwitched) == .stoppedAndStartable(tailnet: "vpn.example.org"))
}

/// A Tailscale too old to list profiles leaves only the netmap's answer, which is still better than
/// nothing once it has settled.
@Test func withoutAProfileListTheNetmapStillNamesTheAccount() {
    let profile = TailnetProfile(id: "68da", tailnet: "vpn.example.org", account: "operator@example.org", isActive: true)
    let noList = TailnetState(backendState: "Running", currentTailnet: "vpn.example.org", magicDNSSuffix: "ts.example.org", peers: [], profiles: [])
    #expect(noList.activeTailnet == "vpn.example.org")
    #expect(TailnetAdvisor.outcome(after: profile, state: noList) == .active(tailnet: "vpn.example.org"))
}

/// This is the complete failure that happened on the Mac: the account changes, but the selected
/// profile was last left disconnected. The confirmed operation is complete only after it raises
/// that profile's tunnel and observes `Running`; a successful `switch` command alone is not enough.
@Test func switchingToAStoppedProfileRaisesItsTunnelBeforeSucceeding() async {
    let profile = TailnetProfile(id: "68da", tailnet: "vpn.example.org", account: "operator@example.com", isActive: false)
    let script = TailnetSwitchScript(profile: profile, backendStates: ["Stopped", "Starting", "Running"])

    let result = await TailnetSwitcher.perform(
        to: profile,
        switchProfile: { await script.switchProfile(id: $0) },
        readState: { await script.readState() },
        bringUp: { await script.bringUp() },
        wait: { _ in await script.wait() }
    )

    #expect(result.outcome == .active(tailnet: "vpn.example.org"))
    #expect(await script.switchCount == 1)
    #expect(await script.bringUpCount == 1)
    #expect(await script.readCount == 3)
}

/// `Starting` is a transition to wait through, not evidence that the logged-in tunnel is stopped.
/// Calling `tailscale up` in this state races Tailscale's own startup and can turn a valid switch
/// into a second command failure.
@Test func switchingWaitsThroughAStartingBackendWithoutCallingUp() async {
    let profile = TailnetProfile(id: "68da", tailnet: "vpn.example.org", account: "operator@example.com", isActive: false)
    let script = TailnetSwitchScript(profile: profile, backendStates: ["Starting", "Running"])

    let result = await TailnetSwitcher.perform(
        to: profile,
        switchProfile: { await script.switchProfile(id: $0) },
        readState: { await script.readState() },
        bringUp: { await script.bringUp() },
        wait: { _ in await script.wait() }
    )

    #expect(result.outcome == .active(tailnet: "vpn.example.org"))
    #expect(await script.bringUpCount == 0)
    #expect(await script.readCount == 2)
}

/// A selected profile that needs authentication belongs back in Tailscale. The operation reports
/// that boundary immediately and never lets `up` start a browser-backed login flow.
@Test func switchingNeverCallsUpWhenTailscaleNeedsLogin() async {
    let profile = TailnetProfile(id: "68da", tailnet: "vpn.example.org", account: "operator@example.com", isActive: false)
    let script = TailnetSwitchScript(profile: profile, backendStates: ["NeedsLogin"])

    let result = await TailnetSwitcher.perform(
        to: profile,
        switchProfile: { await script.switchProfile(id: $0) },
        readState: { await script.readState() },
        bringUp: { await script.bringUp() },
        wait: { _ in await script.wait() }
    )

    #expect(result.outcome == .needsTailscaleLogin(tailnet: "vpn.example.org"))
    #expect(await script.bringUpCount == 0)
    #expect(await script.readCount == 1)
}

/// The CLI has been observed to return non-zero after selecting a stopped profile. State read back
/// from Tailscale is the verdict, so a command error cannot override an already-running target.
@Test func anObservedRunningTargetWinsOverTheSwitchExitStatus() async {
    let profile = TailnetProfile(id: "68da", tailnet: "vpn.example.org", account: "operator@example.com", isActive: false)
    let script = TailnetSwitchScript(profile: profile, backendStates: ["Running"], switchOK: false)

    let result = await TailnetSwitcher.perform(
        to: profile,
        switchProfile: { await script.switchProfile(id: $0) },
        readState: { await script.readState() },
        bringUp: { await script.bringUp() },
        wait: { _ in await script.wait() }
    )

    #expect(!result.switchCommand.ok)
    #expect(result.outcome == .active(tailnet: "vpn.example.org"))
    #expect(await script.bringUpCount == 0)
}

private actor TailnetSwitchScript {
    let profile: TailnetProfile
    let backendStates: [String]
    let switchOK: Bool
    private(set) var switchCount = 0
    private(set) var bringUpCount = 0
    private(set) var readCount = 0

    init(profile: TailnetProfile, backendStates: [String], switchOK: Bool = true) {
        self.profile = profile
        self.backendStates = backendStates
        self.switchOK = switchOK
    }

    func switchProfile(id: String) -> TailnetCommandResult {
        switchCount += 1
        return .init(ok: switchOK && id == profile.id, detail: "")
    }

    func readState() -> TailnetState? {
        let index = min(readCount, backendStates.count - 1)
        readCount += 1
        return TailnetState(
            backendState: backendStates[index],
            currentTailnet: backendStates[index] == "Running" ? profile.tailnet : nil,
            magicDNSSuffix: backendStates[index] == "Running" ? "ts.example.com" : nil,
            peers: [],
            profiles: [
                .init(id: profile.id, tailnet: profile.tailnet, account: profile.account, isActive: true),
            ]
        )
    }

    func bringUp() -> TailnetCommandResult {
        bringUpCount += 1
        return .init(ok: true, detail: "")
    }

    func wait() {}
}

// MARK: - Placement of saved Hosts, before any attempt

private let otherProfile = TailnetProfile(id: "68da", tailnet: "vpn.example.org", account: "operator@example.org", isActive: false)

@Test func aPeerOfTheActiveTailnetIsPlacedByWhatTailscaleReports() {
    let online = state(peers: [.init(dnsName: "build-mac.\(activeSuffix)", addresses: ["100.64.0.4"], isOnline: true)])
    #expect(TailnetPlacement.placement(forEndpoint: "user@build-mac", rememberedTailnet: nil, state: online) == .reachable(tailnet: "operator.github"))
    // Memory of another tailnet does not override what the active one's peer list says.
    #expect(TailnetPlacement.placement(forEndpoint: "user@100.64.0.4", rememberedTailnet: "vpn.example.org", state: online) == .reachable(tailnet: "operator.github"))
    let offline = state(peers: [.init(dnsName: "build-mac.\(activeSuffix)", addresses: ["100.64.0.4"], isOnline: false)])
    #expect(TailnetPlacement.placement(forEndpoint: "user@build-mac", rememberedTailnet: nil, state: offline) == .offline(tailnet: "operator.github"))
}

@Test func aHostRememberedOnAnotherTailnetOffersTheProfileThatReachesIt() {
    let placement = TailnetPlacement.placement(forEndpoint: "user@studio-mac", rememberedTailnet: "vpn.example.org", state: state())
    #expect(placement == .notInActiveTailnet(active: "operator.github", remembered: "vpn.example.org", switchTo: otherProfile))
    // Remembered on a tailnet this device no longer holds: named, with nowhere to switch.
    let onlyActive = state(profiles: [.init(id: "14ca", tailnet: "operator.github", account: "operator@github", isActive: true)])
    #expect(TailnetPlacement.placement(forEndpoint: "user@studio-mac", rememberedTailnet: "vpn.example.org", state: onlyActive)
        == .notInActiveTailnet(active: "operator.github", remembered: "vpn.example.org", switchTo: nil))
}

@Test func aBareNameWithNoPeerAndNoMemorySaysNothing() {
    #expect(TailnetPlacement.placement(forEndpoint: "user@studio-mac", rememberedTailnet: nil, state: state()) == .notApplicable)
    #expect(TailnetPlacement.placement(forEndpoint: "user@192.168.1.20", rememberedTailnet: nil, state: state()) == .notApplicable)
    #expect(TailnetPlacement.placement(forEndpoint: "user@studio-mac", rememberedTailnet: "vpn.example.org", state: nil) == .notApplicable)
}

@Test func aTailscaleAddressThatIsNoPeerIsNotOnTheActiveTailnet() {
    #expect(TailnetPlacement.placement(forEndpoint: "user@100.64.0.9", rememberedTailnet: nil, state: state())
        == .notInActiveTailnet(active: "operator.github", remembered: nil, switchTo: nil))
    // Remembered on the active tailnet yet not listed there: still "not on it", without a switch.
    #expect(TailnetPlacement.placement(forEndpoint: "user@100.64.0.9", rememberedTailnet: "operator.github", state: state())
        == .notInActiveTailnet(active: "operator.github", remembered: nil, switchTo: nil))
    #expect(TailnetPlacement.placement(forEndpoint: "user@100.64.0.9", rememberedTailnet: nil, state: state(running: false)) == .tunnelDown)
}

@Test func theReachedTailnetIsRememberedOnlyForHostsThatAreActuallyOnIt() {
    let peers: [TailnetPeer] = [.init(dnsName: "build-mac.\(activeSuffix)", addresses: ["100.64.0.4"], isOnline: true)]
    #expect(TailnetPlacement.reachedTailnet(forEndpoint: "user@build-mac", state: state(peers: peers)) == "operator.github")
    #expect(TailnetPlacement.reachedTailnet(forEndpoint: "user@100.64.0.9", state: state()) == "operator.github")
    #expect(TailnetPlacement.reachedTailnet(forEndpoint: "user@192.168.1.20", state: state(peers: peers)) == nil)
    #expect(TailnetPlacement.reachedTailnet(forEndpoint: "user@build-mac", state: state(running: false, peers: peers)) == nil)
    #expect(TailnetPlacement.reachedTailnet(forEndpoint: "user@build-mac", state: nil) == nil)
}

@Test func aProfileRoundTripsItsRememberedTailnetAndDecodesWithoutIt() throws {
    var profile = ConnectionProfile(kind: .ssh, endpoint: "user@studio-mac")
    profile.lastReachedTailnet = "vpn.example.org"
    let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
    #expect(decoded.lastReachedTailnet == "vpn.example.org")
    let legacy = Data(#"{"id":"3D5C1F1E-8B6D-4B5F-9C0F-3F4B2C1D0E9A","kind":"ssh","endpoint":"user@studio-mac","priority":0}"#.utf8)
    #expect(try JSONDecoder().decode(ConnectionProfile.self, from: legacy).lastReachedTailnet == nil)
}
