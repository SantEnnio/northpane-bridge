import Crypto
import Foundation

/// One public key an SSH Host presented, as `ssh-keyscan` prints it and `known_hosts` stores it.
public struct SSHHostKey: Equatable, Hashable, Sendable {
    /// The pattern OpenSSH matches against: `host`, or `[host]:port` when the port is not 22.
    public let hostPattern: String
    /// The key type as OpenSSH names it: `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa`.
    public let keyType: String
    public let base64Key: String

    public init(hostPattern: String, keyType: String, base64Key: String) {
        self.hostPattern = hostPattern
        self.keyType = keyType
        self.base64Key = base64Key
    }

    /// The line `known_hosts` stores for this key.
    public var knownHostsLine: String { "\(hostPattern) \(keyType) \(base64Key)" }

    /// The fingerprint as `ssh-keygen -l` prints it — `SHA256:` and the unpadded base64 of the
    /// SHA-256 of the key blob — so the Operator can compare it with what the Host prints for
    /// itself. Nil when the blob is not base64.
    public var fingerprint: String? {
        guard let blob = Data(base64Encoded: base64Key) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// The algorithm as the Host prints it beside its fingerprint: `ED25519`, `ECDSA`, `RSA`.
    public var algorithmLabel: String {
        if keyType == "ssh-ed25519" || keyType == "sk-ssh-ed25519@openssh.com" { return "ED25519" }
        if keyType.hasPrefix("ecdsa-") || keyType.hasPrefix("sk-ecdsa-") { return "ECDSA" }
        if keyType == "ssh-rsa" { return "RSA" }
        if keyType == "ssh-dss" { return "DSA" }
        return keyType
    }
}

public enum SSHHostKeyTrustStatus: Equatable, Sendable {
    case known
    case unknown([SSHHostKey])
}

public enum SSHHostKeyTrustError: Error, Equatable, Sendable {
    /// The Host answered with no key at all: unreachable, no SSH server, or a name that does not resolve.
    case noKeysPresented(detail: String)
    case invalidHost
}

/// Pure helpers over Host keys: the pattern OpenSSH uses, and the parsing of what `ssh-keyscan` prints.
public enum SSHHostKeys {
    public static func hostPattern(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// `ssh-keyscan` prints one `pattern type base64` line per key on stdout and comments on
    /// stderr, but a comment can land in the same stream when the two are merged: skip it.
    public static func parseKeyscanOutput(_ text: String) -> [SSHHostKey] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { return nil }
            return SSHHostKey(hostPattern: String(parts[0]), keyType: String(parts[1]), base64Key: String(parts[2]))
        }
    }

    /// The order in which `ssh` itself prefers the key types, so the fingerprint shown first is
    /// the one the Operator sees in the terminal and the one the Host prints by default.
    public static func preferredOrder(_ keys: [SSHHostKey]) -> [SSHHostKey] {
        func rank(_ key: SSHHostKey) -> Int {
            switch key.algorithmLabel {
            case "ED25519": return 0
            case "ECDSA": return 1
            case "RSA": return 2
            default: return 3
            }
        }
        return keys.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

#if os(macOS) || os(Linux)
/// The Host-key side of "transport trust" (spec §6.2) for the system `ssh`: whether this
/// machine already knows a Host's key, which keys the Host presents when it does not, and the
/// recording of the ones the Operator accepted. Nothing here decides trust; it reads `known_hosts`
/// through `ssh-keygen -F`, asks the Host through `ssh-keyscan`, and appends to the same file
/// `ssh` consults, so what the app accepted is exactly what `ssh` will check afterwards.
public struct SSHHostKeyTrust: Sendable {
    public var knownHostsFile: URL
    public var sshExecutable: URL
    public var keygenExecutable: URL
    public var keyscanExecutable: URL
    /// An `ssh_config` to read instead of the user's own; tests point it at a private file.
    public var sshConfigFile: URL?
    /// Seconds `ssh-keyscan` waits for each Host.
    public var timeout: Int

    public init(
        knownHostsFile: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/known_hosts"),
        sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        keygenExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
        keyscanExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan"),
        sshConfigFile: URL? = nil,
        timeout: Int = 5
    ) {
        self.knownHostsFile = knownHostsFile
        self.sshExecutable = sshExecutable
        self.keygenExecutable = keygenExecutable
        self.keyscanExecutable = keyscanExecutable
        self.sshConfigFile = sshConfigFile
        self.timeout = timeout
    }

    /// The name and port `ssh` would actually connect to for an endpoint, read from its own
    /// configuration with `ssh -G`: an alias in `ssh_config` (`Host studio` → `HostName
    /// 192.168.1.20`) is what `known_hosts` and the key scan must be asked about, not the alias,
    /// which resolves nowhere on its own. Falls back to the endpoint's host part and port 22.
    public func resolve(endpoint: String) async -> (host: String, port: Int) {
        let destination = await resolveDestination(endpoint: endpoint)
        return (destination.host, destination.port)
    }

    /// The same, with the account `ssh` would log in as: the one on the endpoint, else the `User`
    /// the configuration sets for an alias. Nil when neither names one and `ssh` would fall back
    /// on the local user. What another device needs in order to dial the same Host, since it has
    /// neither this Mac's `ssh_config` nor its user name.
    public func resolveDestination(endpoint: String) async -> (user: String?, host: String, port: Int) {
        // `ssh` takes no `host:port`; the port travels as `-p` and the user stays on the name.
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        let fallbackHost = TailnetAddress.host(inEndpoint: trimmed)
        var fallbackPort = 22
        var destination = trimmed
        var explicitPort: Int?
        if !fallbackHost.hasPrefix("["), trimmed.filter({ $0 == ":" }).count == 1, let colon = trimmed.lastIndex(of: ":") {
            explicitPort = Int(trimmed[trimmed.index(after: colon)...])
            fallbackPort = explicitPort ?? 22
            destination = String(trimmed[..<colon])
        }
        let named = trimmed.firstIndex(of: "@").map { String(trimmed[..<$0]) }.flatMap { $0.isEmpty ? nil : $0 }
        guard Self.isPlausibleHost(fallbackHost) else { return (named, fallbackHost, fallbackPort) }
        // Only an explicit port goes on the command line: there it would override the one the
        // configuration sets for the alias.
        var arguments = ["-G"] + (explicitPort.map { ["-p", String($0)] } ?? [])
        if let sshConfigFile { arguments += ["-F", sshConfigFile.path] }
        let result = await Self.run(sshExecutable, arguments + [destination])
        guard result.status == 0 else { return (named, fallbackHost, fallbackPort) }
        var host = fallbackHost, port = fallbackPort, configured: String?
        for line in String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0] == "hostname", Self.isPlausibleHost(String(parts[1])) { host = String(parts[1]) }
            if parts[0] == "port", let value = Int(parts[1]) { port = value }
            if parts[0] == "user" { configured = String(parts[1]) }
        }
        // `ssh -G` always prints a user, the local one when nothing sets it: only a name the
        // endpoint or the configuration chose is worth passing on.
        let account = named ?? configured.flatMap { $0 == NSUserName() ? nil : $0 }
        return (account, host, port)
    }

    /// Whether `known_hosts` already carries a key for the Host, hashed entries included.
    public func isKnown(host: String, port: Int) async -> Bool {
        guard Self.isPlausibleHost(host), FileManager.default.fileExists(atPath: knownHostsFile.path) else { return false }
        let result = await Self.run(keygenExecutable, ["-F", SSHHostKeys.hostPattern(host: host, port: port), "-f", knownHostsFile.path])
        return result.status == 0 && !result.output.isEmpty
    }

    /// The keys `known_hosts` already holds for the Host, the type `ssh` prefers first: what this
    /// Mac has agreed to trust, as opposed to what the network presents right now. It is what one
    /// of the Operator's devices can vouch for to another.
    public func trustedKeys(host: String, port: Int) async -> [SSHHostKey] {
        guard Self.isPlausibleHost(host), FileManager.default.fileExists(atPath: knownHostsFile.path) else { return [] }
        let result = await Self.run(keygenExecutable, ["-F", SSHHostKeys.hostPattern(host: host, port: port), "-f", knownHostsFile.path])
        guard result.status == 0 else { return [] }
        return SSHHostKeys.preferredOrder(SSHHostKeys.parseKeyscanOutput(String(decoding: result.output, as: UTF8.self)))
    }

    /// The keys the Host presents right now, the type `ssh` prefers first.
    public func scan(host: String, port: Int) async throws -> [SSHHostKey] {
        guard Self.isPlausibleHost(host) else { throw SSHHostKeyTrustError.invalidHost }
        let result = await Self.run(keyscanExecutable, ["-T", String(timeout), "-p", String(port), host])
        let keys = SSHHostKeys.preferredOrder(SSHHostKeys.parseKeyscanOutput(String(decoding: result.output, as: UTF8.self)))
        guard !keys.isEmpty else {
            throw SSHHostKeyTrustError.noKeysPresented(detail: result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return keys
    }

    public func status(host: String, port: Int) async throws -> SSHHostKeyTrustStatus {
        if await isKnown(host: host, port: port) { return .known }
        return .unknown(try await scan(host: host, port: port))
    }

    /// Records the keys the Operator accepted, creating `~/.ssh` (0700) and the file (0600) when
    /// they are missing and appending in place otherwise, so an existing file keeps its mode.
    public func accept(_ keys: [SSHHostKey]) throws {
        let fileManager = FileManager.default
        let directory = knownHostsFile.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if !fileManager.fileExists(atPath: knownHostsFile.path) {
            guard fileManager.createFile(atPath: knownHostsFile.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forUpdating: knownHostsFile)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var text = ""
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if let last = try handle.read(upToCount: 1), last != Data("\n".utf8) { text = "\n" }
            try handle.seekToEnd()
        }
        text += keys.map(\.knownHostsLine).joined(separator: "\n") + "\n"
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// A name or address `ssh` would take; anything that could read as an option is refused.
    static func isPlausibleHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.range(of: #"^[A-Za-z0-9._:\[\]%-]+$"#, options: .regularExpression) != nil
    }

    private static func run(_ executable: URL, _ arguments: [String]) async -> (status: Int32, output: Data, error: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return (-1, Data(), "\(error)") }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data, String(decoding: errorData, as: UTF8.self))
        }.value
    }
}
#endif
