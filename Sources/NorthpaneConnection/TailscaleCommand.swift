#if os(macOS)
import Foundation

/// Reads this device's Tailscale through its own CLI, and switches account only when the Operator
/// asks for it.
///
/// Tailscale stays external (spec §6.1): Northpane never installs it, never logs in, and treats its
/// absence as the normal case. Reading is unconditional; changing account and raising a selected,
/// logged-in profile are separate calls because they change the whole machine's network, not one
/// connection.
public enum TailscaleCommand {
    /// Where the CLI lives, in the order worth trying: Homebrew, the standalone package, and the
    /// copy inside the App Store app, whose sandbox puts it out of the usual paths.
    static let searchPaths = [
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    public static func executable(fileManager: FileManager = .default) -> URL? {
        searchPaths.first { fileManager.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// The current state, or nil when Tailscale is not installed or does not answer. Never throws
    /// at the caller: a missing tailnet is not a Northpane failure.
    public static func readState(fileManager: FileManager = .default) -> TailnetState? {
        guard let executable = executable(fileManager: fileManager) else { return nil }
        guard let statusData = run(executable, ["status", "--json"]) else { return nil }
        let profiles = run(executable, ["switch", "--list", "--json"]).flatMap(decodeProfiles) ?? []
        return decodeState(statusData, profiles: profiles)
    }

    /// Switches this device to another account. The caller confirms with the Operator first: every
    /// connection over the current tailnet drops.
    ///
    /// The exit status is a **hint, not a verdict**: switching to a profile whose tunnel is stopped
    /// exits non-zero while having changed the account perfectly well (measured 2026-09-11). Only
    /// reading the state back says what happened, so the caller does that and keeps this to explain
    /// itself in a log. Both streams are returned because the command talks on stdout.
    public static func switchTo(profileID: String, fileManager: FileManager = .default) -> TailnetCommandResult {
        guard let executable = executable(fileManager: fileManager) else {
            return .init(ok: false, detail: "tailscale not installed")
        }
        let result = runCapturing(executable, ["switch", profileID])
        let said = [String(decoding: result.output, as: UTF8.self), result.error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        return .init(ok: result.status == 0, detail: said)
    }

    /// Raises the tunnel of the account this device is already on.
    ///
    /// Only ever called to finish a switch the Operator confirmed, and only when Tailscale reports
    /// `Stopped` — logged in, tunnel off — so no login flow can be triggered. Bare `up` keeps the
    /// profile's existing settings; the timeout is there so a Tailscale that does want a browser
    /// fails quickly instead of holding the app.
    public static func bringUp(fileManager: FileManager = .default) -> TailnetCommandResult {
        guard let executable = executable(fileManager: fileManager) else {
            return .init(ok: false, detail: "tailscale not installed")
        }
        let result = runCapturing(executable, ["up", "--timeout=15s"])
        let said = [String(decoding: result.output, as: UTF8.self), result.error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        return .init(ok: result.status == 0, detail: said)
    }

    static func decodeState(_ statusData: Data, profiles: [TailnetProfile]) -> TailnetState? {
        struct Status: Decodable {
            struct Tailnet: Decodable { let name: String?; let magicDNSSuffix: String?
                enum CodingKeys: String, CodingKey { case name = "Name", magicDNSSuffix = "MagicDNSSuffix" } }
            struct Node: Decodable {
                let dnsName: String?; let tailscaleIPs: [String]?; let online: Bool?
                enum CodingKeys: String, CodingKey { case dnsName = "DNSName", tailscaleIPs = "TailscaleIPs", online = "Online" }
            }
            let backendState: String?
            let currentTailnet: Tailnet?
            let magicDNSSuffix: String?
            let peer: [String: Node]?
            enum CodingKeys: String, CodingKey {
                case backendState = "BackendState", currentTailnet = "CurrentTailnet"
                case magicDNSSuffix = "MagicDNSSuffix", peer = "Peer"
            }
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: statusData) else { return nil }
        let peers = (status.peer ?? [:]).values.compactMap { node -> TailnetPeer? in
            guard let dnsName = node.dnsName, !dnsName.isEmpty else { return nil }
            return TailnetPeer(
                dnsName: dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName,
                addresses: node.tailscaleIPs ?? [],
                isOnline: node.online ?? false
            )
        }
        let suffix = status.currentTailnet?.magicDNSSuffix ?? status.magicDNSSuffix
        return TailnetState(
            backendState: status.backendState ?? "",
            currentTailnet: status.currentTailnet?.name,
            magicDNSSuffix: suffix?.isEmpty == true ? nil : suffix,
            peers: peers.sorted { $0.dnsName < $1.dnsName },
            profiles: profiles
        )
    }

    static func decodeProfiles(_ data: Data) -> [TailnetProfile]? {
        struct Row: Decodable { let id: String; let tailnet: String?; let account: String?; let selected: Bool? }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        return rows.map {
            TailnetProfile(id: $0.id, tailnet: $0.tailnet ?? $0.id, account: $0.account ?? "", isActive: $0.selected ?? false)
        }
    }

    private static func run(_ executable: URL, _ arguments: [String]) -> Data? {
        let result = runCapturing(executable, arguments)
        return result.status == 0 ? result.output : nil
    }

    private static func runCapturing(_ executable: URL, _ arguments: [String]) -> (status: Int32, output: Data, error: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return (-1, Data(), "\(error)") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data, String(decoding: errorData, as: UTF8.self))
    }
}
#endif
