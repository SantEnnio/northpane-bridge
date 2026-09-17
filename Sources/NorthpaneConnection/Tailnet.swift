import Foundation

/// One Tailscale account this device is logged into. A device can hold several and use one at a
/// time, which is the whole reason this file exists.
public struct TailnetProfile: Hashable, Sendable, Identifiable {
    public let id: String
    public let tailnet: String
    public let account: String
    public let isActive: Bool
    public init(id: String, tailnet: String, account: String, isActive: Bool) {
        self.id = id; self.tailnet = tailnet; self.account = account; self.isActive = isActive
    }
}

/// A machine in the tailnet that is currently active on this device.
public struct TailnetPeer: Hashable, Sendable {
    /// The MagicDNS name, without its trailing dot.
    public let dnsName: String
    public let addresses: [String]
    public let isOnline: Bool
    public init(dnsName: String, addresses: [String], isOnline: Bool) {
        self.dnsName = dnsName; self.addresses = addresses; self.isOnline = isOnline
    }
}

/// What this device's Tailscale currently is. Read, never written, and absent whenever Tailscale
/// is not installed — which is the normal case, since Tailscale is external to Northpane.
public struct TailnetState: Hashable, Sendable {
    /// Tailscale's own `BackendState`, kept raw because its cases are not interchangeable: a
    /// `Stopped` tunnel is logged in and one command from running, while `NeedsLogin` needs a
    /// browser and is not Northpane's to drive.
    public let backendState: String
    /// True only when the tunnel actually carries traffic.
    public var isRunning: Bool { backendState == "Running" }
    /// True when the tunnel is down but the profile is still logged in, so raising it needs no
    /// login flow — the case a profile lands in when it was left disconnected.
    public var isStoppedButLoggedIn: Bool { backendState == "Stopped" }
    public var needsTailscaleLogin: Bool { backendState == "NeedsLogin" || backendState == "NeedsMachineAuth" }
    /// The tailnet `status` names, which comes from the netmap and is therefore **absent right
    /// after a switch to a profile whose tunnel is stopped** — there is no netmap yet.
    public let currentTailnet: String?
    /// Which account this device is actually on. The profile list carries the selected flag and is
    /// answered from local state, so it is right immediately; `currentTailnet` is the fallback for
    /// a Tailscale too old to list profiles.
    public var activeTailnet: String? { profiles.first(where: \.isActive)?.tailnet ?? currentTailnet }
    /// The MagicDNS suffix of the active tailnet, without a leading dot (`tail1234ab.ts.net`).
    public let magicDNSSuffix: String?
    public let peers: [TailnetPeer]
    public let profiles: [TailnetProfile]
    public init(backendState: String, currentTailnet: String?, magicDNSSuffix: String?, peers: [TailnetPeer], profiles: [TailnetProfile]) {
        self.backendState = backendState; self.currentTailnet = currentTailnet
        self.magicDNSSuffix = magicDNSSuffix; self.peers = peers; self.profiles = profiles
    }

    public init(isRunning: Bool, currentTailnet: String?, magicDNSSuffix: String?, peers: [TailnetPeer], profiles: [TailnetProfile]) {
        self.init(backendState: isRunning ? "Running" : "Stopped", currentTailnet: currentTailnet,
                  magicDNSSuffix: magicDNSSuffix, peers: peers, profiles: profiles)
    }
}

/// What Northpane can honestly say about a Host it could not reach, once the tailnets are taken
/// into account. Every case is evidence about the route; none of them authorises anything.
public enum TailnetAdvice: Equatable, Sendable {
    /// The tailnets explain nothing: the address is not a Tailscale one.
    case none
    /// The address is a Tailscale one and this device cannot see Tailscale's state at all — the
    /// normal case on iOS and iPadOS, where an app does not reach the tunnel. All that can be said
    /// is which question to go and answer, and it is said rather than guessed at.
    case cannotTellFromHere
    /// The address is a Tailscale one and the tunnel is not running.
    case tailscaleNotRunning
    /// The Host is on the active tailnet and Tailscale itself reports it offline. Switching
    /// tailnets would not help, and saying so stops the Operator chasing the wrong thing.
    case peerOffline(name: String)
    /// The address belongs to a tailnet that is not the active one. `alternatives` are the other
    /// profiles this device is logged into; which of them owns the address cannot be told from
    /// here, because only the active tailnet's MagicDNS suffix is knowable.
    case addressOnAnotherTailnet(active: String?, alternatives: [TailnetProfile])
}

public enum TailnetAddress {
    /// The Tailscale CGNAT range, 100.64.0.0/10.
    public static func isTailscaleIP(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]) else { return false }
        guard parts.allSatisfy({ Int($0).map { 0 ... 255 ~= $0 } == true }) else { return false }
        return first == 100 && 64 ... 127 ~= second
    }

    /// Whether an address belongs to some tailnet.
    ///
    /// Three things can say so, and the third is why this takes the active suffix: a tailnet may
    /// carry a **custom** MagicDNS suffix instead of `<name>.ts.net` — `vpn.example.org` answers as
    /// `ts.example.org` — and no pattern can recognise a custom
    /// suffix belonging to a tailnet that is not the active one. That limit is real and is why an
    /// address on another custom-domain tailnet gets no advice rather than a wrong one.
    public static func isTailnetAddress(_ host: String, activeSuffix: String?) -> Bool {
        if isTailscaleIP(host) { return true }
        if magicDNSSuffix(of: host) != nil { return true }
        guard let activeSuffix, !activeSuffix.isEmpty else { return false }
        let name = (host.hasSuffix(".") ? String(host.dropLast()) : host).lowercased()
        return name.hasSuffix("." + activeSuffix.lowercased())
    }

    /// A default MagicDNS name ends in `.ts.net`, and the label before it names the tailnet.
    public static func magicDNSSuffix(of host: String) -> String? {
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard name.lowercased().hasSuffix(".ts.net") else { return nil }
        let labels = name.split(separator: ".")
        guard labels.count >= 3 else { return nil }
        return labels.suffix(3).joined(separator: ".").lowercased()
    }

    /// The host part of a Northpane endpoint: `user@host`, `host:port` and bare `host` all reduce
    /// to `host`, and an IPv6 literal in brackets is left alone.
    public static func host(inEndpoint endpoint: String) -> String {
        var value = endpoint.trimmingCharacters(in: .whitespaces)
        if let at = value.lastIndex(of: "@") { value = String(value[value.index(after: at)...]) }
        if value.hasPrefix("[") { return value }
        // Exactly one colon is a port; more than one is a bare IPv6 literal, which keeps its colons.
        if value.filter({ $0 == ":" }).count == 1, let colon = value.lastIndex(of: ":") {
            value = String(value[value.startIndex ..< colon])
        }
        return value
    }
}

/// How a requested tailnet change ended. Asking only whether the tunnel is running conflates two
/// different outcomes, and told the Operator the switch had failed when the account had in fact
/// changed and only the tunnel was stopped (measured 2026-09-11).
public enum TailnetSwitchOutcome: Equatable, Sendable {
    /// The account changed and its tunnel is up: the Host can be tried again.
    case active(tailnet: String)
    /// The account changed and its tunnel is stopped, but the profile is still logged in, so one
    /// command raises it. `tailscale switch` carries each profile's own on/off state, so a profile
    /// last left disconnected lands here every time (measured 2026-09-11) — which is why finishing
    /// the job belongs to the gesture the Operator already confirmed.
    case stoppedAndStartable(tailnet: String)
    /// The account changed but Tailscale wants a login or machine authorisation. That flow is
    /// Tailscale's, needs a browser, and Northpane does not drive it.
    case needsTailscaleLogin(tailnet: String)
    /// The account changed and Tailscale is in a state that must only be observed. In particular,
    /// `Starting` is not interchangeable with `Stopped`: issuing `up` while Tailscale is already
    /// starting races the transition the switch just initiated.
    case notReady(tailnet: String, backendState: String)
    /// Tailscale is not on this account: the command failed, or something changed it back.
    case notChanged
}

public enum TailnetAdvisor {
    /// Reads the state reached after asking Tailscale to change account.
    public static func outcome(after profile: TailnetProfile, state: TailnetState?) -> TailnetSwitchOutcome {
        guard let state, state.activeTailnet == profile.tailnet else { return .notChanged }
        if state.isRunning { return .active(tailnet: profile.tailnet) }
        if state.isStoppedButLoggedIn { return .stoppedAndStartable(tailnet: profile.tailnet) }
        if state.needsTailscaleLogin { return .needsTailscaleLogin(tailnet: profile.tailnet) }
        return .notReady(tailnet: profile.tailnet, backendState: state.backendState)
    }

    /// Read the tailnets against one endpoint that could not be reached.
    ///
    /// Only called after a route failure: a Host that answers needs no advice, and a Host that
    /// refuses the connection is reachable — something answered — so its tailnet is fine.
    public static func advice(forEndpoint endpoint: String, state: TailnetState?) -> TailnetAdvice {
        let host = TailnetAddress.host(inEndpoint: endpoint)
        let suffix = TailnetAddress.magicDNSSuffix(of: host)
        guard TailnetAddress.isTailnetAddress(host, activeSuffix: state?.magicDNSSuffix) else { return .none }
        guard let state else { return .cannotTellFromHere }
        guard state.isRunning else { return .tailscaleNotRunning }

        // A peer of the active tailnet: Tailscale already knows whether it is up, and its own
        // answer beats any guess about which tailnet the Operator should be on.
        let name = host.lowercased()
        if let peer = state.peers.first(where: {
            $0.dnsName.lowercased() == name
                || $0.dnsName.lowercased().split(separator: ".").first.map(String.init) == name
                || $0.addresses.contains(host)
        }) {
            return peer.isOnline ? .none : .peerOffline(name: peer.dnsName)
        }

        // A name under the active tailnet's own suffix, but no such peer: the tailnet is right and
        // the machine is simply not in it. Nothing to advise about switching.
        if let active = state.magicDNSSuffix, !active.isEmpty {
            if suffix == active.lowercased() { return .none }
            if name.hasSuffix("." + active.lowercased()) { return .none }
        }

        let alternatives = state.profiles.filter { !$0.isActive }
        guard !alternatives.isEmpty else { return .none }
        return .addressOnAnotherTailnet(active: state.activeTailnet, alternatives: alternatives)
    }
}

/// What a local Tailscale command reported. The command status is diagnostic evidence; the state
/// read back from Tailscale remains authoritative for whether a switch actually succeeded.
public struct TailnetCommandResult: Equatable, Sendable {
    public let ok: Bool
    public let detail: String

    public init(ok: Bool, detail: String) {
        self.ok = ok
        self.detail = detail
    }
}

/// The complete result of one confirmed tailnet change, including the last state Tailscale
/// reported and both command results. This keeps UI wording and diagnostics out of the switching
/// state machine while making the full operation deterministic to test.
public struct TailnetSwitchResult: Equatable, Sendable {
    public let outcome: TailnetSwitchOutcome
    public let state: TailnetState?
    public let switchCommand: TailnetCommandResult
    public let bringUpCommand: TailnetCommandResult?

    public init(
        outcome: TailnetSwitchOutcome,
        state: TailnetState?,
        switchCommand: TailnetCommandResult,
        bringUpCommand: TailnetCommandResult?
    ) {
        self.outcome = outcome
        self.state = state
        self.switchCommand = switchCommand
        self.bringUpCommand = bringUpCommand
    }
}

/// Performs the stateful part of a confirmed tailnet switch. It deliberately judges commands by
/// subsequent Tailscale state: both `switch` and `up` can report failure after already changing
/// local state, while a zero exit status does not prove that the tunnel carries traffic yet.
public enum TailnetSwitcher {
    public static func perform(
        to profile: TailnetProfile,
        selectionPollLimit: Int = 20,
        runningPollLimit: Int = 20,
        switchProfile: @escaping @Sendable (String) async -> TailnetCommandResult,
        readState: @escaping @Sendable () async -> TailnetState?,
        bringUp: @escaping @Sendable () async -> TailnetCommandResult,
        wait: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) async -> TailnetSwitchResult {
        let switchCommand = await switchProfile(profile.id)
        var state = await readState()
        var outcome = TailnetAdvisor.outcome(after: profile, state: state)

        // Profile selection is asynchronous. Wait through both an unchanged profile list and
        // transient backend states, but do not delay once the selected profile is known to be
        // stopped: that state is stable until someone explicitly raises it.
        var selectionPolls = 0
        while selectionPolls < max(0, selectionPollLimit), shouldWaitForSelection(outcome) {
            await wait(.milliseconds(500))
            state = await readState()
            outcome = TailnetAdvisor.outcome(after: profile, state: state)
            selectionPolls += 1
        }

        var bringUpCommand: TailnetCommandResult?
        if case .stoppedAndStartable = outcome {
            bringUpCommand = await bringUp()
            state = await readState()
            outcome = TailnetAdvisor.outcome(after: profile, state: state)

            // A bare `tailscale up` retains the selected profile and starts its tunnel, but the
            // backend may pass through `Starting` before it is usable. Never reconnect before the
            // state read back is `Running`.
            var runningPolls = 0
            while runningPolls < max(0, runningPollLimit), shouldWaitForRunning(outcome) {
                await wait(.milliseconds(500))
                state = await readState()
                outcome = TailnetAdvisor.outcome(after: profile, state: state)
                runningPolls += 1
            }
        }

        return TailnetSwitchResult(
            outcome: outcome,
            state: state,
            switchCommand: switchCommand,
            bringUpCommand: bringUpCommand
        )
    }

    private static func shouldWaitForSelection(_ outcome: TailnetSwitchOutcome) -> Bool {
        switch outcome {
        case .notChanged, .notReady: true
        case .active, .stoppedAndStartable, .needsTailscaleLogin: false
        }
    }

    private static func shouldWaitForRunning(_ outcome: TailnetSwitchOutcome) -> Bool {
        switch outcome {
        case .active, .needsTailscaleLogin: false
        case .notChanged, .notReady, .stoppedAndStartable: true
        }
    }
}

/// Where a saved Host stands relative to the tailnet active on this device, read from what
/// Tailscale already exposes and from what an earlier success recorded — before any attempt, so
/// the Operator does not have to fail a connection to learn that the Host is on another tailnet.
/// Evidence about the route only: it never decides trust, and it never guesses which tailnet owns
/// an address (spec §6.1); the remembered tailnet comes from a connection that actually worked.
public enum HostTailnetPlacement: Equatable, Sendable {
    /// Not a Tailscale matter, or nothing readable here: the row says nothing.
    case notApplicable
    /// A Tailscale Host, but this device's tunnel is not running.
    case tunnelDown
    /// A peer of the active tailnet that Tailscale reports online.
    case reachable(tailnet: String?)
    /// A peer of the active tailnet that Tailscale reports offline: changing tailnet would not help.
    case offline(tailnet: String?)
    /// Not among the peers of the active tailnet. `remembered` names the tailnet on which this
    /// Host was last reached, when one was recorded; `switchTo` the profile that reaches it, when
    /// this device holds that account.
    case notInActiveTailnet(active: String?, remembered: String?, switchTo: TailnetProfile?)
}

public enum TailnetPlacement {
    public static func placement(forEndpoint endpoint: String, rememberedTailnet: String?, state: TailnetState?) -> HostTailnetPlacement {
        guard let state else { return .notApplicable }
        let host = TailnetAddress.host(inEndpoint: endpoint)
        // The peer list wins over memory: Tailscale knows its own tailnet better than a record
        // of the last success, and a Host shared into several tailnets is a peer in each.
        if let peer = peer(named: host, in: state) {
            return peer.isOnline ? .reachable(tailnet: state.activeTailnet) : .offline(tailnet: state.activeTailnet)
        }
        // A bare name that is no peer and was never reached through a tailnet could be anything
        // — a LAN host, an SSH alias — so nothing is claimed about it.
        guard TailnetAddress.isTailnetAddress(host, activeSuffix: state.magicDNSSuffix) || rememberedTailnet != nil else { return .notApplicable }
        guard state.isRunning else { return .tunnelDown }
        if let remembered = rememberedTailnet, remembered != state.activeTailnet {
            let profile = state.profiles.first { $0.tailnet == remembered && !$0.isActive }
            return .notInActiveTailnet(active: state.activeTailnet, remembered: remembered, switchTo: profile)
        }
        return .notInActiveTailnet(active: state.activeTailnet, remembered: nil, switchTo: nil)
    }

    /// The tailnet a Host was just reached on, to be remembered with its profile: the active one,
    /// and only when the Host is actually a peer of it or carries a tailnet address. A Host on
    /// the LAN reached while Tailscale happens to run gets nothing recorded, or every later
    /// placement would send the Operator to the wrong tailnet.
    public static func reachedTailnet(forEndpoint endpoint: String, state: TailnetState?) -> String? {
        guard let state, state.isRunning, let active = state.activeTailnet else { return nil }
        let host = TailnetAddress.host(inEndpoint: endpoint)
        guard peer(named: host, in: state) != nil || TailnetAddress.isTailnetAddress(host, activeSuffix: state.magicDNSSuffix) else { return nil }
        return active
    }

    static func peer(named host: String, in state: TailnetState) -> TailnetPeer? {
        let name = host.lowercased()
        return state.peers.first {
            $0.dnsName.lowercased() == name
                || $0.dnsName.lowercased().split(separator: ".").first.map(String.init) == name
                || $0.addresses.contains(host)
        }
    }
}
