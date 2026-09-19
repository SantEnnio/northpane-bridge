#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct BridgeReleaseArtifact: Equatable, Sendable {
    public let version: String
    public let downloadURL: URL
    public let sha256: String
    public let signature: Data
    public let signingPublicKey: Data
    public init(version: String, downloadURL: URL, sha256: String, signature: Data, signingPublicKey: Data) {
        self.version = version; self.downloadURL = downloadURL; self.sha256 = sha256.lowercased()
        self.signature = signature; self.signingPublicKey = signingPublicKey
    }
}

public struct BridgeReleaseManifest: Decodable, Sendable {
    private struct Entry: Decodable {
        let version: String
        let url: URL
        let sha256: String
        let signature: String
    }
    private let artifacts: [String: Entry]

    public static func load(from url: URL) async throws -> BridgeReleaseManifest {
        guard url.scheme == "https" else { throw BridgeInstallationError.insecureDownload }
        let configuration = URLSessionConfiguration.ephemeral; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let (data, response) = try await URLSession(configuration: configuration).data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 1_024 * 1_024 else { throw BridgeInstallationError.invalidManifest }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func artifact(for platformIdentifier: String, trustedSigningPublicKey: Data) throws -> BridgeReleaseArtifact {
        guard let entry = artifacts[platformIdentifier], let signature = Data(base64Encoded: entry.signature),
              trustedSigningPublicKey.count == 65 else { throw BridgeInstallationError.invalidManifest }
        let artifact = BridgeReleaseArtifact(version: entry.version, downloadURL: entry.url, sha256: entry.sha256,
            signature: signature, signingPublicKey: trustedSigningPublicKey)
        try RemoteBridgeInstaller.validateManifest(artifact)
        return artifact
    }
}

public struct BridgeActivation: Equatable, Sendable {
    public let version: String
    public let previousVersion: String?
}

public enum BridgeInstallationError: Error, Equatable, Sendable {
    case invalidManifest, insecureDownload, oversizedArtifact, digestMismatch, invalidSignature
    case transferFailed, selfCheckFailed, activationFailed, verificationFailed, rollbackFailed
    /// The Host runs a different platform from the Bridge that was about to be sent.
    case platformMismatch(host: String, bridge: String)
    /// A system `ssh`/`sftp` step exited non-zero; the detail is the tail of its output.
    case commandFailed(String)
}

public protocol RemoteBridgeDeploymentAdapter: Sendable {
    func platformIdentifier() async throws -> String
    func upload(_ data: Data, version: String) async throws
    func selfCheck(version: String) async throws
    func activate(version: String) async throws -> BridgeActivation
    func rollback(_ activation: BridgeActivation) async throws
    func prune(keeping versions: Set<String>) async throws
}

public actor RemoteBridgeInstaller {
    public static let maximumArtifactBytes = 100 * 1_024 * 1_024
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    public func install(
        _ artifact: BridgeReleaseArtifact,
        using deployment: any RemoteBridgeDeploymentAdapter,
        verifyActivatedBridge: @escaping @Sendable () async throws -> Void
    ) async throws -> BridgeActivation {
        try Self.validateManifest(artifact)
        let (data, response) = try await session.data(from: artifact.downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw BridgeInstallationError.transferFailed }
        return try await installVerified(data, artifact: artifact, using: deployment, verifyActivatedBridge: verifyActivatedBridge)
    }

    public func installVerified(
        _ data: Data,
        artifact: BridgeReleaseArtifact,
        using deployment: any RemoteBridgeDeploymentAdapter,
        verifyActivatedBridge: @escaping @Sendable () async throws -> Void
    ) async throws -> BridgeActivation {
        try Self.validateManifest(artifact)
        guard data.count <= Self.maximumArtifactBytes else { throw BridgeInstallationError.oversizedArtifact }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256 else { throw BridgeInstallationError.digestMismatch }
        do {
            let key = try P256.Signing.PublicKey(x963Representation: artifact.signingPublicKey)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: artifact.signature)
            guard key.isValidSignature(signature, for: data) else { throw BridgeInstallationError.invalidSignature }
        } catch let error as BridgeInstallationError { throw error }
        catch { throw BridgeInstallationError.invalidSignature }
        return try await deploy(data, version: artifact.version, using: deployment, verifyActivatedBridge: verifyActivatedBridge)
    }

    /// Installs a Bridge the client already trusts because it ships inside its own signed
    /// bundle (no manifest, no detached signature). The Host must run the same platform the
    /// bundled Bridge was built for; the deployment, self-check, activation, verification and
    /// rollback steps are the ones the signed path uses.
    public func installLocallyTrusted(
        _ data: Data,
        version: String,
        platform: String,
        using deployment: any RemoteBridgeDeploymentAdapter,
        verifyActivatedBridge: @escaping @Sendable () async throws -> Void
    ) async throws -> BridgeActivation {
        guard version.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else { throw BridgeInstallationError.invalidManifest }
        guard !data.isEmpty, data.count <= Self.maximumArtifactBytes else { throw BridgeInstallationError.oversizedArtifact }
        let hostPlatform = try await deployment.platformIdentifier()
        guard hostPlatform == platform else { throw BridgeInstallationError.platformMismatch(host: hostPlatform, bridge: platform) }
        return try await deploy(data, version: version, using: deployment, verifyActivatedBridge: verifyActivatedBridge)
    }

    private func deploy(
        _ data: Data,
        version: String,
        using deployment: any RemoteBridgeDeploymentAdapter,
        verifyActivatedBridge: @escaping @Sendable () async throws -> Void
    ) async throws -> BridgeActivation {
        try await deployment.upload(data, version: version)
        do { try await deployment.selfCheck(version: version) }
        catch { throw BridgeInstallationError.selfCheckFailed }
        let activation: BridgeActivation
        do { activation = try await deployment.activate(version: version) }
        catch { throw BridgeInstallationError.activationFailed }
        do {
            try await verifyActivatedBridge()
        } catch {
            do { try await deployment.rollback(activation) }
            catch { throw BridgeInstallationError.rollbackFailed }
            throw BridgeInstallationError.verificationFailed
        }
        try? await deployment.prune(keeping: Set([activation.version, activation.previousVersion].compactMap { $0 }))
        return activation
    }

    fileprivate static func validateManifest(_ artifact: BridgeReleaseArtifact) throws {
        guard artifact.downloadURL.scheme == "https" else { throw BridgeInstallationError.insecureDownload }
        guard artifact.version.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil,
              artifact.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              !artifact.signature.isEmpty, artifact.signingPublicKey.count == 65
        else { throw BridgeInstallationError.invalidManifest }
    }
}

#if os(macOS)
/// Concrete user-scoped SFTP + SSH deployment. The remote script never uses
/// sudo and only switches the `current` symlink after self-check succeeds.
public struct POSIXSFTPBridgeDeployment: RemoteBridgeDeploymentAdapter {
    private let endpoint: String
    private let identityFile: URL?
    /// `identityFile` adds the device key to the identities `ssh` and `sftp` offer.
    public init(endpoint: String, identityFile: URL? = nil) throws {
        guard endpoint.range(of: #"^[A-Za-z0-9._@:\[\]-]+$"#, options: .regularExpression) != nil else { throw BridgeInstallationError.invalidManifest }
        self.endpoint = endpoint
        self.identityFile = identityFile
    }

    private var identityArguments: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15"] + (identityFile.map { ["-o", "IdentitiesOnly=yes", "-i", $0.path] } ?? [])
    }

    public func platformIdentifier() async throws -> String {
        // `ssh` joins its arguments into one command line that the Host's login shell re-splits,
        // so the probe must be a single simple command: no quoting, no substitutions.
        let posix = try? await runCapturing("/usr/bin/ssh", identityArguments + [endpoint, "uname", "-sm"], stdin: nil)
        let raw = posix.map(Self.lastLine) ?? ""
        let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        switch (parts.first ?? "", parts.count > 1 ? parts[1] : "") {
        case ("darwin", "arm64"): return "macos-arm64"
        case ("darwin", "x86_64"): return "macos-x86_64"
        case ("linux", "aarch64"), ("linux", "arm64"): return "linux-arm64"
        case ("linux", "x86_64"): return "linux-x86_64"
        default:
            let windows = try await runPowerShell("[Console]::Write($env:PROCESSOR_ARCHITECTURE)")
            let architecture = Self.lastLine(windows)
            if architecture == "amd64" { return "windows-x86_64" }
            if architecture == "arm64" { return "windows-arm64" }
            throw BridgeInstallationError.invalidManifest
        }
    }

    public func upload(_ data: Data, version: String) async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "northpane-bridge-\(UUID().uuidString)")
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let windows = try await platformIdentifier().hasPrefix("windows-")
        let remote = windows ? ".northpane/incoming/\(version).exe" : ".local/share/northpane/bridge/incoming/\(version)"
        if windows { _ = try await runPowerShell("New-Item -ItemType Directory -Force -Path \"$HOME/.northpane/incoming\" | Out-Null") }
        else { try await run("/usr/bin/ssh", identityArguments + [endpoint, "mkdir", "-p", ".local/share/northpane/bridge/incoming"], stdin: nil) }
        let batch = "put \(temporary.path) \(remote)\n"
        try await run("/usr/bin/sftp", identityArguments + ["-b", "-", endpoint], stdin: Data(batch.utf8))
    }

    public func selfCheck(version: String) async throws {
        if try await platformIdentifier().hasPrefix("windows-") {
            _ = try await runPowerShell("$root=Join-Path $env:LOCALAPPDATA 'Northpane/Bridge'; New-Item -ItemType Directory -Force -Path (Join-Path $root 'versions/\(version)') | Out-Null; Move-Item -Force \"$HOME/.northpane/incoming/\(version).exe\" (Join-Path $root 'versions/\(version)/northpane-bridge.exe'); & (Join-Path $root 'versions/\(version)/northpane-bridge.exe') self-check --json | Out-Null; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }")
            return
        }
        let script = """
        set -eu
        root="$HOME/.local/share/northpane/bridge"
        mkdir -p "$root/versions/$1"
        mv "$root/incoming/$1" "$root/versions/$1/northpane-bridge"
        chmod 700 "$root/versions/$1/northpane-bridge"
        "$root/versions/$1/northpane-bridge" self-check --json >/dev/null
        """
        try await run("/usr/bin/ssh", identityArguments + [endpoint, "sh", "-s", "--", version], stdin: Data(script.utf8))
    }

    public func activate(version: String) async throws -> BridgeActivation {
        if try await platformIdentifier().hasPrefix("windows-") {
            let priorData = try await runPowerShell("$p=Join-Path $env:LOCALAPPDATA 'Northpane/Bridge/current-version.txt'; if (Test-Path $p) { [Console]::Write((Get-Content -Raw $p).Trim()) }")
            let prior = String(decoding: priorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await runPowerShell("$root=Join-Path $env:LOCALAPPDATA 'Northpane/Bridge'; $bin=Join-Path $HOME '.local/bin'; New-Item -ItemType Directory -Force -Path $bin | Out-Null; Copy-Item -Force (Join-Path $root 'versions/\(version)/northpane-bridge.exe') (Join-Path $bin 'northpane-bridge.exe'); Set-Content -NoNewline (Join-Path $root 'current-version.txt') '\(version)'; $userPath=[Environment]::GetEnvironmentVariable('Path','User'); if (($userPath -split ';') -notcontains $bin) { [Environment]::SetEnvironmentVariable('Path', (($userPath.TrimEnd(';') + ';' + $bin).Trim(';')), 'User') }")
            return .init(version: version, previousVersion: prior.isEmpty ? nil : prior)
        }
        // One plain command (see `platformIdentifier`): the login shell runs it from the home
        // directory, and a missing link simply exits non-zero, which means no prior version.
        let query = (try? await runCapturing("/usr/bin/ssh", identityArguments + [endpoint, "readlink", ".local/share/northpane/bridge/current"], stdin: nil)) ?? Data()
        let priorPath = String(decoding: query, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let prior = priorPath.split(separator: "/").last.map(String.init)
        let script = """
        set -eu
        root="$HOME/.local/share/northpane/bridge"
        mkdir -p "$HOME/.local/bin"
        if [ -L "$root/current" ]; then ln -sfn "$(readlink "$root/current")" "$root/previous"; fi
        ln -sfn "versions/$1" "$root/current"
        ln -sfn "../share/northpane/bridge/current/northpane-bridge" "$HOME/.local/bin/northpane-bridge"
        """
        try await run("/usr/bin/ssh", identityArguments + [endpoint, "sh", "-s", "--", version], stdin: Data(script.utf8))
        return .init(version: version, previousVersion: prior)
    }

    public func rollback(_ activation: BridgeActivation) async throws {
        guard let previous = activation.previousVersion else { throw BridgeInstallationError.rollbackFailed }
        if try await platformIdentifier().hasPrefix("windows-") {
            _ = try await runPowerShell("$root=Join-Path $env:LOCALAPPDATA 'Northpane/Bridge'; Copy-Item -Force (Join-Path $root 'versions/\(previous)/northpane-bridge.exe') (Join-Path $HOME '.local/bin/northpane-bridge.exe'); Set-Content -NoNewline (Join-Path $root 'current-version.txt') '\(previous)'")
            return
        }
        let script = """
        set -eu
        root="$HOME/.local/share/northpane/bridge"
        test -x "$root/versions/$1/northpane-bridge"
        ln -sfn "versions/$1" "$root/current"
        """
        try await run("/usr/bin/ssh", identityArguments + [endpoint, "sh", "-s", "--", previous], stdin: Data(script.utf8))
    }

    public func prune(keeping versions: Set<String>) async throws {
        let arguments = versions.sorted()
        if try await platformIdentifier().hasPrefix("windows-") {
            let allowed = arguments.map { "'\($0)'" }.joined(separator: ",")
            _ = try await runPowerShell("$root=Join-Path $env:LOCALAPPDATA 'Northpane/Bridge/versions'; if (Test-Path $root) { Get-ChildItem -Directory $root | Where-Object { @(\(allowed)) -notcontains $_.Name } | Remove-Item -Recurse -Force }")
            return
        }
        let script = """
        set -eu
        root="$HOME/.local/share/northpane/bridge/versions"
        [ -d "$root" ] || exit 0
        for candidate in "$root"/*; do
          [ -d "$candidate" ] || continue
          keep=0
          for version in "$@"; do [ "$(basename "$candidate")" = "$version" ] && keep=1; done
          [ "$keep" -eq 1 ] || rm -rf -- "$candidate"
        done
        """
        try await run("/usr/bin/ssh", identityArguments + [endpoint, "sh", "-s", "--"] + arguments, stdin: Data(script.utf8))
    }

    private func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws {
        _ = try await runCapturing(executable, arguments, stdin: stdin)
    }
    /// The answer to a one-line probe: the last line of what came back, lowercased. `ssh` writes its
    /// own warnings to the same stream first (an older server earns three lines about post-quantum
    /// key exchange), and read whole they turned "amd64" into something no platform matches.
    static func lastLine(_ output: Data) -> String {
        String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }?.lowercased() ?? ""
    }

    private func runPowerShell(_ script: String) async throws -> Data {
        guard let command = script.data(using: .utf16LittleEndian) else { throw BridgeInstallationError.transferFailed }
        let encoded = command.base64EncodedString()
        return try await runCapturing("/usr/bin/ssh", identityArguments + [endpoint, "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded], stdin: nil)
    }
    private func runCapturing(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> Data {
        try await Task.detached {
            let process = Process(); let input = Pipe(); let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardInput = input; process.standardOutput = output; process.standardError = output
            try process.run()
            if let stdin { try input.fileHandleForWriting.write(contentsOf: stdin) }
            try? input.fileHandleForWriting.close()
            let result = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: result.suffix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw BridgeInstallationError.commandFailed("\(URL(fileURLWithPath: executable).lastPathComponent) exit \(process.terminationStatus): \(detail)")
            }
            return Data(result.prefix(64 * 1_024))
        }.value
    }
}
#endif
