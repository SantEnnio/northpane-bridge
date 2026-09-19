#if os(iOS)
@preconcurrency import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import NorthpaneProtocol

/// Names what a NIO connect failure actually was, in the vocabulary the rest of
/// the app already speaks.
///
/// Without this a Host that cannot be reached surfaces as `NIOConnectionError`,
/// which reaches the Operator as a type name and a number. The commonest case
/// by far is a name that resolves nowhere — an `ssh_config` alias, say, which
/// works on a Mac because `ssh` expands it and means nothing to a phone.
enum NativeSSHReachability {
    static func failure(for error: Error) -> SSHReachabilityFailure? {
        guard let connection = error as? NIOConnectionError else { return nil }
        // No address was ever reached for: the name gave nothing to connect to.
        guard !connection.connectionErrors.isEmpty else { return .nameNotResolved }
        for attempt in connection.connectionErrors {
            guard let io = attempt.error as? IOError else { continue }
            switch io.errnoCode {
            case ECONNREFUSED: return .connectionRefused
            case ETIMEDOUT: return .timedOut
            case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN: return .hostUnreachable
            default: continue
            }
        }
        return .hostUnreachable
    }

    /// Runs a connect and rewrites its failure, leaving every other error alone.
    static func named<T>(_ connect: () async throws -> T) async throws -> T {
        do { return try await connect() }
        catch {
            if let reachability = failure(for: error) { throw SystemTransportError.sshUnreachable(reachability) }
            throw error
        }
    }
}

/// A native, key-only SSH transport for iOS. The first successful connection
/// records the SSH host-key fingerprint alongside the separately verified and
/// signed Northpane Host identity. All subsequent connections require both pins.
public actor NativeSSHBridgeTransport: BridgeTransport {
    public nonisolated let kind: TransportKind = .ssh
    public nonisolated let serverHostKeyFingerprint: String

    private let parentChannel: Channel
    private let childChannel: Channel
    private let inbound: SSHInboundBuffer
    private var pending = Data()
    private var isClosed = false

    public static func connect(
        host: String,
        port: Int = 22,
        username: String,
        credential: NativeSSHCredential,
        expectedHostKeyFingerprint: String? = nil,
        bridgeCommand: String = RemoteBridgeLaunch.command()  // the caller passes the Host's own shell command
    ) async throws -> NativeSSHBridgeTransport {
        guard !host.isEmpty, !username.isEmpty, (1...65_535).contains(port), !bridgeCommand.contains("\n") else {
            throw SystemTransportError.invalidEndpoint
        }

        let cryptoKey = try P256.Signing.PrivateKey(rawRepresentation: credential.rawPrivateKey)
        let authentication = KeyOnlyAuthenticationDelegate(username: username, privateKey: NIOSSHPrivateKey(p256Key: cryptoKey))
        let hostKeys = PinnedHostKeyDelegate(expectedFingerprint: expectedHostKeyFingerprint)
        let parent = try await NativeSSHReachability.named {
            try await ClientBootstrap(group: SSHEventLoopGroup.shared)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers(
                            NIOSSHHandler(
                                role: .client(.init(userAuthDelegate: authentication, serverAuthDelegate: hostKeys)),
                                allocator: channel.allocator,
                                inboundChildChannelInitializer: nil
                            ),
                            SSHParentErrorHandler()
                        )
                    }
                }
                .connect(host: host, port: port)
                .get()
        }

        let inbound = SSHInboundBuffer()
        do {
            let child = try await parent.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let promise = parent.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise) { child, type in
                    guard type == .session else {
                        return child.eventLoop.makeFailedFuture(SystemTransportError.launchFailed)
                    }
                    return child.pipeline.addHandler(SSHBridgeExecHandler(command: bridgeCommand, inbound: inbound))
                }
                return promise.futureResult
            }.get()
            guard let fingerprint = hostKeys.observedFingerprint else {
                try? await child.close().get()
                try? await parent.close().get()
                throw SystemTransportError.ioFailure
            }
            return NativeSSHBridgeTransport(parent: parent, child: child, fingerprint: fingerprint, inbound: inbound)
        } catch {
            inbound.finish(error: error)
            try? await parent.close().get()
            // A rejected key surfaces as a channel error; name it so the app can offer the
            // one-time password bootstrap instead of a raw NIO code.
            if authentication.wasRejected { throw SystemTransportError.sshAuthenticationFailed }
            throw error
        }
    }

    private init(parent: Channel, child: Channel, fingerprint: String, inbound: SSHInboundBuffer) {
        self.parentChannel = parent
        self.childChannel = child
        self.serverHostKeyFingerprint = fingerprint
        self.inbound = inbound
    }

    public func send(_ envelope: Envelope) async throws {
        guard !isClosed else { throw Problem.closedTransport }
        try await childChannel.writeAndFlush(ByteBuffer(data: FrameCodec.encode(envelope))).get()
    }

    public func receive() async throws -> Envelope {
        guard !isClosed else { throw Problem.closedTransport }
        while true {
            while pending.count < 4 {
                guard let data = try await inbound.next() else { throw SystemTransportError.endOfStream }
                pending.append(data)
            }
            let size = pending.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            guard size <= BridgeProtocol.maximumFrameBytes else { throw Problem.oversizedFrame }
            let total = 4 + Int(size)
            while pending.count < total {
                guard let data = try await inbound.next() else { throw SystemTransportError.endOfStream }
                pending.append(data)
            }
            let frame = Data(pending.prefix(total))
            pending.removeFirst(total)
            return try FrameCodec.decode(frame)
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        try? await childChannel.close().get()
        try? await parentChannel.close().get()
    }
}

/// Native iOS SFTP v3 deployment used by connection-first setup. It shares the
/// exact key-only authentication and pinned Host key policy of the live Bridge transport.
public struct NativeSFTPBridgeDeployment: RemoteBridgeDeploymentAdapter {
    private let host: String
    private let port: Int
    private let username: String
    private let credential: NativeSSHCredential
    private let expectedFingerprint: String?

    public init(host: String, port: Int = 22, username: String, credential: NativeSSHCredential, expectedHostKeyFingerprint: String?) throws {
        guard !host.isEmpty, !username.isEmpty, (1...65_535).contains(port) else { throw BridgeInstallationError.invalidManifest }
        self.host = host; self.port = port; self.username = username; self.credential = credential; expectedFingerprint = expectedHostKeyFingerprint
    }

    public func platformIdentifier() async throws -> String {
        let posix = try? await execute("printf '%s-%s' \"$(uname -s)\" \"$(uname -m)\"")
        let raw = posix.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        switch raw {
        case "darwin-arm64": return "macos-arm64"
        case "darwin-x86_64": return "macos-x86_64"
        case "linux-aarch64", "linux-arm64": return "linux-arm64"
        case "linux-x86_64": return "linux-x86_64"
        default:
            let windows = try await executePowerShell("[Console]::Write($env:PROCESSOR_ARCHITECTURE)")
            let architecture = String(decoding: windows, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if architecture == "amd64" { return "windows-x86_64" }
            if architecture == "arm64" { return "windows-arm64" }
            throw BridgeInstallationError.invalidManifest
        }
    }

    public func upload(_ data: Data, version: String) async throws {
        let windows = try await platformIdentifier().hasPrefix("windows-")
        if windows { _ = try await executePowerShell("New-Item -ItemType Directory -Force -Path \"$HOME/.northpane/incoming\" | Out-Null") }
        else { try await executeChecked("mkdir -p \"$HOME/.local/share/northpane/bridge/incoming\"") }
        let session = try await openSession(request: .subsystem("sftp"))
        defer { Task { await session.close() } }
        try await session.upload(data, path: windows ? ".northpane/incoming/\(version).exe" : ".local/share/northpane/bridge/incoming/\(version)")
    }

    public func selfCheck(version: String) async throws {
        if try await platformIdentifier().hasPrefix("windows-") {
            _ = try await executePowerShell("$root=Join-Path $env:LOCALAPPDATA 'Northpane/Bridge'; New-Item -ItemType Directory -Force -Path (Join-Path $root 'versions/\(version)') | Out-Null; Move-Item -Force \"$HOME/.northpane/incoming/\(version).exe\" (Join-Path $root 'versions/\(version)/northpane-bridge.exe'); & (Join-Path $root 'versions/\(version)/northpane-bridge.exe') self-check --json | Out-Null; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }")
            return
        }
        try await executeScript("""
        set -eu
        root="$HOME/.local/share/northpane/bridge"
        mkdir -p "$root/versions/$1"
        mv "$root/incoming/$1" "$root/versions/$1/northpane-bridge"
        chmod 700 "$root/versions/$1/northpane-bridge"
        "$root/versions/$1/northpane-bridge" self-check --json >/dev/null
        """, version: version)
    }

    public func activate(version: String) async throws -> BridgeActivation {
        if try await platformIdentifier().hasPrefix("windows-") {
            let priorData = try await executePowerShell("$p=Join-Path $env:LOCALAPPDATA 'Northpane/Bridge/current-version.txt'; if (Test-Path $p) { [Console]::Write((Get-Content -Raw $p).Trim()) }")
            let prior = String(decoding: priorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await executePowerShell("$root=Join-Path $env:LOCALAPPDATA 'Northpane/Bridge'; $bin=Join-Path $HOME '.local/bin'; New-Item -ItemType Directory -Force -Path $bin | Out-Null; Copy-Item -Force (Join-Path $root 'versions/\(version)/northpane-bridge.exe') (Join-Path $bin 'northpane-bridge.exe'); Set-Content -NoNewline (Join-Path $root 'current-version.txt') '\(version)'; $userPath=[Environment]::GetEnvironmentVariable('Path','User'); if (($userPath -split ';') -notcontains $bin) { [Environment]::SetEnvironmentVariable('Path', (($userPath.TrimEnd(';') + ';' + $bin).Trim(';')), 'User') }")
            return .init(version: version, previousVersion: prior.isEmpty ? nil : prior)
        }
        let priorPath = String(decoding: try await execute("readlink \"$HOME/.local/share/northpane/bridge/current\" 2>/dev/null || true"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prior = priorPath.split(separator: "/").last.map(String.init)
        try await executeScript("""
        set -eu
        root="$HOME/.local/share/northpane/bridge"
        mkdir -p "$HOME/.local/bin"
        if [ -L "$root/current" ]; then ln -sfn "$(readlink "$root/current")" "$root/previous"; fi
        ln -sfn "versions/$1" "$root/current.new"
        mv -f "$root/current.new" "$root/current"
        ln -sfn "../share/northpane/bridge/current/northpane-bridge" "$HOME/.local/bin/northpane-bridge"
        """, version: version)
        return .init(version: version, previousVersion: prior)
    }

    public func rollback(_ activation: BridgeActivation) async throws {
        guard let previous = activation.previousVersion else { throw BridgeInstallationError.rollbackFailed }
        if try await platformIdentifier().hasPrefix("windows-") {
            _ = try await executePowerShell("$root=Join-Path $env:LOCALAPPDATA 'Northpane/Bridge'; Copy-Item -Force (Join-Path $root 'versions/\(previous)/northpane-bridge.exe') (Join-Path $HOME '.local/bin/northpane-bridge.exe'); Set-Content -NoNewline (Join-Path $root 'current-version.txt') '\(previous)'")
            return
        }
        try await executeScript("""
        set -eu
        root="$HOME/.local/share/northpane/bridge"
        test -x "$root/versions/$1/northpane-bridge"
        ln -sfn "versions/$1" "$root/current.new"
        mv -f "$root/current.new" "$root/current"
        """, version: previous)
    }

    public func prune(keeping versions: Set<String>) async throws {
        let quoted = versions.sorted().joined(separator: " ")
        if try await platformIdentifier().hasPrefix("windows-") {
            let allowed = versions.sorted().map { "'\($0)'" }.joined(separator: ",")
            _ = try await executePowerShell("$root=Join-Path $env:LOCALAPPDATA 'Northpane/Bridge/versions'; if (Test-Path $root) { Get-ChildItem -Directory $root | Where-Object { @(\(allowed)) -notcontains $_.Name } | Remove-Item -Recurse -Force }")
            return
        }
        try await executeChecked("set -eu; root=\"$HOME/.local/share/northpane/bridge/versions\"; [ -d \"$root\" ] || exit 0; for candidate in \"$root\"/*; do [ -d \"$candidate\" ] || continue; case \" \(quoted) \" in *\" $(basename \"$candidate\") \"*) ;; *) rm -rf -- \"$candidate\" ;; esac; done")
    }

    /// Runs one of the Bridge release's installer scripts on the Host, reporting
    /// what it printed together with its exit status.
    ///
    /// The status is the point. Both installers answer with the same documented
    /// table of exit codes, and the app turns those into what it tells the
    /// Operator; a caller that only learned "it failed" could not tell a refused
    /// digest from a Host that is already served by the app's own Bridge.
    public func runInstallerShellScript(_ script: String, arguments: [String]) async throws -> (exitCode: Int32, output: String) {
        let safe = try Self.checkedArguments(arguments)
        let session = try await openSession(request: .exec(("sh -s -- " + safe.joined(separator: " "))), reportsExitStatus: true)
        let result = try await session.sendAndFinishReportingExit(Data(script.utf8))
        return (result.exitCode, String(decoding: result.output, as: UTF8.self))
    }

    /// The Windows counterpart. PowerShell reads a script from stdin only by
    /// giving up its named parameters, so the script is put on the Host over
    /// SFTP, run by path, and removed afterwards.
    public func runInstallerPowerShellScript(_ script: String, arguments: [String]) async throws -> (exitCode: Int32, output: String) {
        let safe = try Self.checkedArguments(arguments)
        let remote = ".northpane/incoming/northpane-install-\(UUID().uuidString).ps1"
        _ = try await executePowerShell("New-Item -ItemType Directory -Force -Path \"$HOME/.northpane/incoming\" | Out-Null")
        let staging = try await openSession(request: .subsystem("sftp"))
        try await staging.upload(Data(script.utf8), path: remote)
        defer { Task { _ = try? await executePowerShell("Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $HOME '\(remote)')") } }
        // A parameter name must arrive bare or it becomes positional, and the
        // trailing `exit $LASTEXITCODE` is what carries the script's own status
        // out of `powershell.exe`: a script run with `&` that ends in `exit 22`
        // otherwise leaves the caller exiting 1, flattening the whole table.
        let invocation = "& (Join-Path $HOME '\(remote)') "
            + safe.map { $0.hasPrefix("-") ? $0 : "'\($0)'" }.joined(separator: " ")
            + "; exit $LASTEXITCODE"
        guard let command = invocation.data(using: .utf16LittleEndian) else { throw BridgeInstallationError.transferFailed }
        let session = try await openSession(
            request: .exec("powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand \(command.base64EncodedString())"),
            reportsExitStatus: true)
        let result = try await session.sendAndFinishReportingExit(Data())
        return (result.exitCode, String(decoding: result.output, as: UTF8.self))
    }

    /// The Host's login shell splits the command line again, so every argument
    /// has to survive that untouched. Rather than quote for an unknown shell,
    /// refuse anything that is not a bare word — which every argument the
    /// installers take already is.
    private static func checkedArguments(_ arguments: [String]) throws -> [String] {
        for argument in arguments where argument.range(of: #"^[A-Za-z0-9._/:=-]+$"#, options: .regularExpression) == nil {
            throw BridgeInstallationError.invalidManifest
        }
        return arguments
    }

    private func executeScript(_ script: String, version: String) async throws {
        guard version.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else { throw BridgeInstallationError.invalidManifest }
        let session = try await openSession(request: .exec("sh -s -- \(version)"))
        _ = try await session.sendAndFinish(Data(script.utf8))
    }

    @discardableResult private func executeChecked(_ command: String) async throws -> Data { try await execute(command) }
    private func execute(_ command: String) async throws -> Data {
        let session = try await openSession(request: .exec(command))
        return try await session.sendAndFinish(Data())
    }

    private func executePowerShell(_ script: String) async throws -> Data {
        guard let command = script.data(using: .utf16LittleEndian) else { throw BridgeInstallationError.transferFailed }
        return try await execute("powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand \(command.base64EncodedString())")
    }

    private func openSession(request: NativeSSHRequest, reportsExitStatus: Bool = false) async throws -> NativeSSHRawSession {
        let key = try P256.Signing.PrivateKey(rawRepresentation: credential.rawPrivateKey)
        let authentication = KeyOnlyAuthenticationDelegate(username: username, privateKey: NIOSSHPrivateKey(p256Key: key))
        let hostKeys = PinnedHostKeyDelegate(expectedFingerprint: expectedFingerprint)
        let parent = try await NativeSSHReachability.named {
            try await ClientBootstrap(group: SSHEventLoopGroup.shared)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers(NIOSSHHandler(role: .client(.init(userAuthDelegate: authentication, serverAuthDelegate: hostKeys)), allocator: channel.allocator, inboundChildChannelInitializer: nil), SSHParentErrorHandler())
                    }
                }.connect(host: host, port: port).get()
        }
        let inbound = SSHInboundBuffer()
        do {
            let child = try await parent.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                let promise = parent.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(promise) { channel, type in
                    guard type == .session else { return channel.eventLoop.makeFailedFuture(SystemTransportError.launchFailed) }
                    return channel.pipeline.addHandler(NativeSSHRawHandler(request: request, inbound: inbound, reportsExitStatus: reportsExitStatus))
                }
                return promise.futureResult
            }.get()
            guard hostKeys.observedFingerprint != nil else { throw SystemTransportError.ioFailure }
            return NativeSSHRawSession(parent: parent, child: child, inbound: inbound)
        } catch { try? await parent.close().get(); throw error }
    }
}

private enum SSHEventLoopGroup {
    static let shared = MultiThreadedEventLoopGroup(numberOfThreads: 1)
}

private final class SSHInboundBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Error>] = []
    private var terminal: Result<Void, Error>?
    private var exit: Int32?

    /// The remote command's exit status, once it has sent one.
    ///
    /// A caller that only wants the output treats any non-zero status as a
    /// failure and never reads this. A caller running a script whose exit codes
    /// are a documented contract — the Bridge installers — needs the number
    /// itself, because collapsing it loses the difference between "the digest
    /// was refused" and "this Host is already served by the app's own Bridge".
    var exitStatus: Int32? {
        get { lock.withLock { exit } }
        set { lock.withLock { exit = newValue } }
    }

    func push(_ data: Data) {
        let waiter = lock.withLock { () -> CheckedContinuation<Data?, Error>? in
            guard terminal == nil else { return nil }
            if waiters.isEmpty { queued.append(data); return nil }
            return waiters.removeFirst()
        }
        waiter?.resume(returning: data)
    }

    func finish(error: Error? = nil) {
        let pending = lock.withLock { () -> [CheckedContinuation<Data?, Error>] in
            guard terminal == nil else { return [] }
            terminal = error.map(Result.failure) ?? .success(())
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) }
        }
    }

    func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> Result<Data?, Error>? in
                if !queued.isEmpty { return .success(queued.removeFirst()) }
                if let terminal {
                    switch terminal {
                    case .success: return .success(nil)
                    case let .failure(error): return .failure(error)
                    }
                }
                waiters.append(continuation)
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }
}

/// One-time, password-authenticated installation of the device key on a Host from iOS, so that
/// every later connection is key-only. The password is offered to the server exactly once and is
/// not kept; the Host key is recorded on first sight and must match afterwards.
public enum NativeSSHKeyBootstrap {
    public static func installAuthorizedKey(
        host: String,
        port: Int = 22,
        username: String,
        password: String,
        authorizedKey: String,
        expectedHostKeyFingerprint: String? = nil
    ) async throws -> String {
        guard !host.isEmpty, !username.isEmpty, (1...65_535).contains(port) else { throw SystemTransportError.invalidEndpoint }
        guard !password.isEmpty else { throw SSHKeyBootstrapError.emptyPassword }
        let command = try SSHAuthorizedKeyInstall.remoteCommand(authorizedKey: authorizedKey)
        let authentication = PasswordAuthenticationDelegate(username: username, password: password)
        let hostKeys = PinnedHostKeyDelegate(expectedFingerprint: expectedHostKeyFingerprint)
        let parent = try await ClientBootstrap(group: SSHEventLoopGroup.shared)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers(NIOSSHHandler(role: .client(.init(userAuthDelegate: authentication, serverAuthDelegate: hostKeys)), allocator: channel.allocator, inboundChildChannelInitializer: nil), SSHParentErrorHandler())
                }
            }.connect(host: host, port: port).get()
        let inbound = SSHInboundBuffer()
        do {
            let child = try await parent.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                let promise = parent.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(promise) { channel, type in
                    guard type == .session else { return channel.eventLoop.makeFailedFuture(SystemTransportError.launchFailed) }
                    return channel.pipeline.addHandler(NativeSSHRawHandler(request: .exec(command), inbound: inbound))
                }
                return promise.futureResult
            }.get()
            guard let fingerprint = hostKeys.observedFingerprint else { throw SystemTransportError.ioFailure }
            let session = NativeSSHRawSession(parent: parent, child: child, inbound: inbound)
            do { _ = try await session.sendAndFinish(Data()) }
            catch SystemTransportError.launchFailed { throw SystemTransportError.processFailed(exitCode: 1) }
            return fingerprint
        } catch {
            try? await parent.close().get()
            if authentication.wasRejected { throw SystemTransportError.sshAuthenticationFailed }
            throw error
        }
    }
}

private final class PasswordAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let password: String
    private let lock = NSLock()
    private var offered = false
    private var rejected = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    var wasRejected: Bool { lock.withLock { rejected } }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let mayOffer = lock.withLock { () -> Bool in
            guard !offered else { rejected = true; return false }
            offered = true
            return true
        }
        guard mayOffer, availableMethods.contains(.password) else {
            lock.withLock { rejected = true }
            nextChallengePromise.fail(SystemTransportError.sshAuthenticationFailed)
            return
        }
        nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: .password(.init(password: password))))
    }
}

private final class KeyOnlyAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private let lock = NSLock()
    private var offered = false
    private var rejected = false

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    /// True once the server asked again after the key was offered, or never allowed public keys.
    var wasRejected: Bool { lock.withLock { rejected } }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let mayOffer = lock.withLock { () -> Bool in
            guard !offered else { rejected = true; return false }
            offered = true
            return true
        }
        guard mayOffer, availableMethods.contains(.publicKey) else {
            lock.withLock { rejected = true }
            nextChallengePromise.fail(SystemTransportError.sshAuthenticationFailed)
            return
        }
        nextChallengePromise.succeed(.init(
            username: username,
            serviceName: "ssh-connection",
            offer: .privateKey(.init(privateKey: privateKey))
        ))
    }
}

private final class PinnedHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expectedFingerprint: String?
    private let lock = NSLock()
    private var fingerprint: String?

    init(expectedFingerprint: String?) { self.expectedFingerprint = expectedFingerprint }

    var observedFingerprint: String? { lock.withLock { fingerprint } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let openSSH = String(openSSHPublicKey: hostKey)
        let components = openSSH.split(separator: " ", maxSplits: 1)
        guard components.count == 2, let blob = Data(base64Encoded: String(components[1])) else {
            validationCompletePromise.fail(SystemTransportError.ioFailure)
            return
        }
        let actual = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        lock.withLock { fingerprint = actual }
        // The pin may name several fingerprints, separated by spaces: a Host has one key per
        // algorithm, and a pin that came from another of the Operator's devices cannot know which
        // of them this client will be shown. The connection that follows records the one it saw.
        if let expectedFingerprint, !expectedFingerprint.split(separator: " ").contains(Substring(actual)) {
            validationCompletePromise.fail(SystemTransportError.hostKeyMismatch(expected: expectedFingerprint, actual: actual))
        } else {
            validationCompletePromise.succeed(())
        }
    }
}

private final class SSHBridgeExecHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let inbound: SSHInboundBuffer

    init(command: String, inbound: SSHInboundBuffer) {
        self.command = command
        self.inbound = inbound
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { [inbound] error in
            inbound.finish(error: error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)).whenFailure { [inbound] error in
            inbound.finish(error: error)
            channel.close(promise: nil)
        }
        context.fireChannelActive()
    }

    /// Outbound frames arrive as plain `ByteBuffer`s from the transport; the SSH child channel
    /// only accepts `SSHChannelData`, so wrap here. Without this the first write after the
    /// handshake hit an assertion inside NIO and took the whole app down.
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(.init(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case var .byteBuffer(buffer) = data.data else {
            inbound.finish(error: SystemTransportError.ioFailure)
            context.close(promise: nil)
            return
        }
        if data.type == .channel, let bytes = buffer.readData(length: buffer.readableBytes), !bytes.isEmpty {
            inbound.push(bytes)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus, status.exitStatus != 0 {
            // The same reading the system `ssh` transport gives these statuses: a shell that found
            // no Bridge to run is a Host to install one on, not a connection that failed. Without
            // it a phone or a tablet could never offer a new Host its first Bridge.
            switch status.exitStatus {
            case 126, 127: inbound.finish(error: SystemTransportError.remoteBridgeUnavailable)
            case 9009: inbound.finish(error: SystemTransportError.remoteShellMismatch(.windows))
            default: inbound.finish(error: SystemTransportError.launchFailed)
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        inbound.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        inbound.finish(error: error)
        context.close(promise: nil)
    }
}

private final class SSHParentErrorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private enum NativeSSHRequest: Sendable { case exec(String), subsystem(String) }

private final class NativeSSHRawHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    private let request: NativeSSHRequest
    private let inbound: SSHInboundBuffer
    /// When true a non-zero exit is recorded and handed back instead of ending
    /// the stream with an error, so the caller can read the status itself.
    private let reportsExitStatus: Bool
    init(request: NativeSSHRequest, inbound: SSHInboundBuffer, reportsExitStatus: Bool = false) {
        self.request = request; self.inbound = inbound; self.reportsExitStatus = reportsExitStatus
    }
    func channelActive(context: ChannelHandlerContext) {
        let future: EventLoopFuture<Void> = switch request {
        case let .exec(command): context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true))
        case let .subsystem(name): context.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: name, wantReply: true))
        }
        future.whenFailure { [inbound] error in inbound.finish(error: error) }
        context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = value.data else { inbound.finish(error: SystemTransportError.ioFailure); return }
        if value.type == .channel, !buffer.readableBytesView.isEmpty { inbound.push(Data(buffer.readableBytesView)) }
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(.init(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            inbound.exitStatus = Int32(status.exitStatus)
            if status.exitStatus != 0, !reportsExitStatus { inbound.finish(error: SystemTransportError.launchFailed) }
        }
        context.fireUserInboundEventTriggered(event)
    }
    func channelInactive(context: ChannelHandlerContext) { inbound.finish(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { inbound.finish(error: error); context.close(promise: nil) }
}

private actor NativeSSHRawSession {
    private let parent: Channel
    private let child: Channel
    private let inbound: SSHInboundBuffer
    private var pending = Data()
    init(parent: Channel, child: Channel, inbound: SSHInboundBuffer) { self.parent = parent; self.child = child; self.inbound = inbound }

    func sendAndFinish(_ data: Data) async throws -> Data {
        try await collect(data)
    }

    /// Like `sendAndFinish`, but hands back the exit status instead of turning
    /// it into an error. Only meaningful on a session opened with
    /// `reportsExitStatus`; a Host that sends no status at all reads as 0, the
    /// same thing `ssh` reports for a clean channel.
    func sendAndFinishReportingExit(_ data: Data) async throws -> (exitCode: Int32, output: Data) {
        let output = try await collect(data)
        return (inbound.exitStatus ?? 0, output)
    }

    private func collect(_ data: Data) async throws -> Data {
        if !data.isEmpty { try await child.writeAndFlush(ByteBuffer(data: data)).get() }
        try await child.close(mode: .output).get()
        var output = Data()
        while let chunk = try await inbound.next() {
            guard output.count + chunk.count <= 1_024 * 1_024 else { throw BridgeInstallationError.transferFailed }
            output.append(chunk)
        }
        await close()
        return output
    }

    func upload(_ data: Data, path: String) async throws {
        try await sendSFTPPacket(type: 1, body: uint32(3))
        let version = try await receiveSFTPPacket()
        guard version.type == 2 else { throw BridgeInstallationError.transferFailed }
        var requestID: UInt32 = 1
        var open = Data(); open.append(uint32(requestID)); open.append(sshString(Data(path.utf8))); open.append(uint32(0x0000001A)); open.append(uint32(0))
        try await sendSFTPPacket(type: 3, body: open)
        let opened = try await receiveSFTPPacket()
        guard opened.type == 102 else { throw BridgeInstallationError.transferFailed }
        var reader = SFTPReader(opened.body); guard reader.uint32() == requestID, let handle = reader.string() else { throw BridgeInstallationError.transferFailed }
        var offset: UInt64 = 0
        for chunkStart in stride(from: 0, to: data.count, by: 32 * 1_024) {
            requestID += 1
            let chunk = data.subdata(in: chunkStart..<min(data.count, chunkStart + 32 * 1_024))
            var body = Data(); body.append(uint32(requestID)); body.append(sshString(handle)); body.append(uint64(offset)); body.append(sshString(chunk))
            try await sendSFTPPacket(type: 6, body: body)
            try await requireSFTPOK(requestID: requestID)
            offset += UInt64(chunk.count)
        }
        requestID += 1
        var closeBody = Data(); closeBody.append(uint32(requestID)); closeBody.append(sshString(handle))
        try await sendSFTPPacket(type: 4, body: closeBody); try await requireSFTPOK(requestID: requestID)
        await close()
    }

    func close() async { try? await child.close().get(); try? await parent.close().get() }

    private func requireSFTPOK(requestID: UInt32) async throws {
        let packet = try await receiveSFTPPacket(); guard packet.type == 101 else { throw BridgeInstallationError.transferFailed }
        var reader = SFTPReader(packet.body); guard reader.uint32() == requestID, reader.uint32() == 0 else { throw BridgeInstallationError.transferFailed }
    }
    private func sendSFTPPacket(type: UInt8, body: Data) async throws {
        var payload = Data([type]); payload.append(body)
        var packet = uint32(UInt32(payload.count)); packet.append(payload)
        try await child.writeAndFlush(ByteBuffer(data: packet)).get()
    }
    private func receiveSFTPPacket() async throws -> (type: UInt8, body: Data) {
        while pending.count < 4 { guard let data = try await inbound.next() else { throw BridgeInstallationError.transferFailed }; pending.append(data) }
        let length = pending.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length > 0, length <= 1_048_576 else { throw BridgeInstallationError.transferFailed }
        while pending.count < 4 + Int(length) { guard let data = try await inbound.next() else { throw BridgeInstallationError.transferFailed }; pending.append(data) }
        let packet = Data(pending[4..<(4 + Int(length))]); pending.removeFirst(4 + Int(length))
        guard let type = packet.first else { throw BridgeInstallationError.transferFailed }
        return (type, Data(packet.dropFirst()))
    }
    private func uint32(_ value: UInt32) -> Data { var value = value.bigEndian; return Swift.withUnsafeBytes(of: &value) { Data($0) } }
    private func uint64(_ value: UInt64) -> Data { var value = value.bigEndian; return Swift.withUnsafeBytes(of: &value) { Data($0) } }
    private func sshString(_ value: Data) -> Data { var data = uint32(UInt32(value.count)); data.append(value); return data }
}

private struct SFTPReader {
    private let data: Data
    private var offset = 0
    init(_ data: Data) { self.data = data }
    mutating func uint32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        defer { offset += 4 }
        return data[offset..<(offset + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    }
    mutating func string() -> Data? {
        guard let length = uint32(), offset + Int(length) <= data.count else { return nil }
        defer { offset += Int(length) }
        return Data(data[offset..<(offset + Int(length))])
    }
}

#endif
