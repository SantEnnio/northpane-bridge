// The key bootstrap and its tests drive the system ssh, ssh-keygen and shell scripts: macOS and Linux only,
// like SSHKeyBootstrap itself.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import NorthpaneConnection

private func privateDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "northpane-ssh-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
}

@Test func deviceCredentialExportsAnOpenSSHPrivateKeyThatSSHKeygenAccepts() async throws {
    let directory = try privateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credential = try NativeSSHCredential()
    let keyFile = try credential.materializeOpenSSHPrivateKey(at: directory.appending(path: "ssh/device-key"))

    let permissions = try FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)

    let keygen = Process()
    keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    keygen.arguments = ["-y", "-f", keyFile.path]
    let output = Pipe()
    keygen.standardOutput = output
    keygen.standardError = Pipe()
    try keygen.run()
    let derived = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    keygen.waitUntilExit()
    #expect(keygen.terminationStatus == 0)

    let expected = try credential.authorizedKey.split(separator: " ").prefix(2).joined(separator: " ")
    #expect(derived.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(expected))

    // Re-materializing the same key must not rewrite the file.
    let before = try FileManager.default.attributesOfItem(atPath: keyFile.path)[.modificationDate] as? Date
    try await Task.sleep(for: .milliseconds(20))
    _ = try credential.materializeOpenSSHPrivateKey(at: keyFile)
    let after = try FileManager.default.attributesOfItem(atPath: keyFile.path)[.modificationDate] as? Date
    #expect(before == after)
}

@Test func sshTransportArgumentsAddTheDeviceIdentityWithoutReplacingTheUsersOwn() {
    let identity = URL(fileURLWithPath: "/tmp/device-key")
    let arguments = ProcessBridgeTransport.sshArguments(endpoint: "dev@build-box", identityFile: identity)
    let remote = ProcessBridgeTransport.remoteBridgeCommand()
    #expect(arguments == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "IdentitiesOnly=yes", "-i", "/tmp/device-key", "dev@build-box", remote])
    // Without a device key we leave the user's own identities and agent in play.
    let plain = ProcessBridgeTransport.sshArguments(endpoint: "build-box")
    #expect(plain == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "build-box", remote])
    #expect(!plain.contains("IdentitiesOnly=yes"))
    #expect(remote.contains("command -v northpane-bridge"))
    #expect(remote.contains("\"$HOME/.local/bin/northpane-bridge\" serve --stdio"))
    // PATH must be widened so the Bridge is found and can itself find Herdr under Homebrew.
    #expect(remote.contains("/opt/homebrew/bin"))
    #expect(remote.contains("export PATH="))
}

/// The remote command must run under a POSIX shell and pick the fallback location when the
/// name is not on PATH; a local `sh` with an empty PATH and a stub in a fake HOME proves it.
@Test func remoteBridgeCommandFallsBackToTheUserLocalBin() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "northpane-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    let bin = home.appending(path: ".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let stub = bin.appending(path: "northpane-bridge")
    try Data("#!/bin/sh\nprintf 'fallback:%s' \"$*\"\n".utf8).write(to: stub)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", ProcessBridgeTransport.remoteBridgeCommand()]
    process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(result == "fallback:serve --stdio")
}

@Test func remoteInstallCommandAppendsTheKeyOnceAndRejectsUnsafeInput() throws {
    let key = try NativeSSHCredential().authorizedKey
    let command = try SSHKeyBootstrap.remoteInstallCommand(authorizedKey: key)
    #expect(command.hasPrefix("sh -c '"))
    #expect(command.contains("grep -qF -- \"\(key)\""))
    #expect(command.contains("chmod 600"))
    #expect(throws: SSHKeyBootstrapError.invalidAuthorizedKey) {
        _ = try SSHKeyBootstrap.remoteInstallCommand(authorizedKey: "ssh-ed25519 AAAA' ; rm -rf ~ ; '")
    }
    #expect(throws: SSHKeyBootstrapError.invalidAuthorizedKey) {
        _ = try SSHKeyBootstrap.remoteInstallCommand(authorizedKey: "ssh-ed25519 AAAA comment with $HOME")
    }
}

/// A stand-in for `ssh` that behaves like a password-only Host: it must be told to use
/// askpass unconditionally, reads the password from the askpass helper (whose source for
/// this prompt must be a FIFO, never a regular file), records what it was asked to run,
/// and accepts exactly one password.
private func fakeSSH(in directory: URL, acceptedPassword: String) throws -> URL {
    let script = """
    #!/bin/sh
    [ "$SSH_ASKPASS_REQUIRE" = "force" ] || { echo "askpass not forced" >&2; exit 3; }
    [ -p "$NORTHPANE_ASKPASS_DIR/prompt.0" ] || { echo "askpass source is not a fifo" >&2; exit 5; }
    pw=$("$SSH_ASKPASS" "user@host's password:") || { echo "askpass failed" >&2; exit 4; }
    printf '%s\\n' "$*" > "\(directory.path)/arguments"
    for arg in "$@"; do :; done
    printf '%s' "$arg" > "\(directory.path)/remote-command"
    printf '%s\\n' "$pw" > "\(directory.path)/received-password"
    [ "$pw" = "\(acceptedPassword)" ] || { echo "Permission denied (password)." >&2; exit 255; }
    exit 0
    """
    let url = directory.appending(path: "fake-ssh")
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

@Test func bootstrapFeedsThePasswordThroughAskpassAndInstallsTheDeviceKey() async throws {
    let directory = try privateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = try NativeSSHCredential().authorizedKey
    let bootstrap = SSHKeyBootstrap(sshExecutable: try fakeSSH(in: directory, acceptedPassword: "corr€ct horse"), timeout: 20, temporaryRoot: directory)

    try await bootstrap.installAuthorizedKey(endpoint: "dev@build-box", authorizedKey: key, password: "corr€ct horse")

    let arguments = try String(contentsOf: directory.appending(path: "arguments"), encoding: .utf8)
    #expect(arguments.contains("PubkeyAuthentication=no"))
    #expect(arguments.contains("NumberOfPasswordPrompts=1"))
    #expect(arguments.contains("StrictHostKeyChecking=yes"))
    #expect(arguments.contains("-- dev@build-box "))
    #expect(!arguments.contains("corr€ct horse"))
    let remoteCommand = try String(contentsOf: directory.appending(path: "remote-command"), encoding: .utf8)
    #expect(remoteCommand == (try SSHKeyBootstrap.remoteInstallCommand(authorizedKey: key)))
    #expect(remoteCommand.contains(key))
    let received = try String(contentsOf: directory.appending(path: "received-password"), encoding: .utf8)
    #expect(received == "corr€ct horse\n")
    // Only this test's own private root is inspected: other bootstrap tests run concurrently.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("northpane-ssh-bootstrap-") }
    #expect(leftovers.isEmpty)
}

/// A fake `ssh` that, like a macOS Host offering both keyboard-interactive and password,
/// invokes the askpass helper twice before it accepts the login. A single-shot feeder would
/// leave the second prompt unanswered.
private func fakeSSHWithTwoPrompts(in directory: URL, acceptedPassword: String) throws -> URL {
    let script = """
    #!/bin/sh
    p1=$("$SSH_ASKPASS" "keyboard-interactive:") || exit 4
    p2=$("$SSH_ASKPASS" "password:") || exit 4
    printf '%s\\n%s\\n' "$p1" "$p2" > "\(directory.path)/both-passwords"
    [ "$p1" = "\(acceptedPassword)" ] && [ "$p2" = "\(acceptedPassword)" ] || { echo "Connection closed by 10.0.0.1 port 22" >&2; exit 255; }
    exit 0
    """
    let url = directory.appending(path: "fake-ssh-two")
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

@Test func bootstrapAnswersEveryPromptWhenTheHostOffersSeveralAuthMethods() async throws {
    let directory = try privateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = try NativeSSHCredential().authorizedKey
    let bootstrap = SSHKeyBootstrap(sshExecutable: try fakeSSHWithTwoPrompts(in: directory, acceptedPassword: "s3cret"), timeout: 20)
    try await bootstrap.installAuthorizedKey(endpoint: "dev@host", authorizedKey: key, password: "s3cret")
    let both = try String(contentsOf: directory.appending(path: "both-passwords"), encoding: .utf8)
    #expect(both == "s3cret\ns3cret\n")
}

@Test func bootstrapReportsARejectedPasswordAsAuthenticationFailure() async throws {
    let directory = try privateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = try NativeSSHCredential().authorizedKey
    let bootstrap = SSHKeyBootstrap(sshExecutable: try fakeSSH(in: directory, acceptedPassword: "right"), timeout: 20)
    await #expect(throws: SystemTransportError.sshAuthenticationFailed) {
        try await bootstrap.installAuthorizedKey(endpoint: "dev@build-box", authorizedKey: key, password: "wrong")
    }
    let failing = directory.appending(path: "fake-ssh-failing")
    try Data("#!/bin/sh\necho 'Warning: Permanently added host' >&2; echo 'zsh:1: no such file or directory: sh' >&2; exit 1\n".utf8).write(to: failing)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failing.path)
    await #expect(throws: SSHKeyBootstrapError.commandFailed(exitCode: 1, detail: "zsh:1: no such file or directory: sh")) {
        try await SSHKeyBootstrap(sshExecutable: failing, timeout: 20).installAuthorizedKey(endpoint: "dev@build-box", authorizedKey: key, password: "right")
    }
    await #expect(throws: SSHKeyBootstrapError.emptyPassword) {
        try await bootstrap.installAuthorizedKey(endpoint: "dev@build-box", authorizedKey: key, password: "")
    }
    await #expect(throws: SSHKeyBootstrapError.invalidEndpoint) {
        try await bootstrap.installAuthorizedKey(endpoint: "-oProxyCommand=evil", authorizedKey: key, password: "x")
    }
}


/// Every prompt is served from its own FIFO, so no amount of CPU contention can make the
/// feeder hand one askpass helper two copies of the password. This load also exercises the
/// termination handling around a process that has already exited by the time it is awaited.
@Test func bootstrapStaysCorrectWhileManyRunsCompeteForTheCPU() async throws {
    let directory = try privateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = try NativeSSHCredential().authorizedKey
    let instant = directory.appending(path: "fake-ssh-instant")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: instant)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: instant.path)
    let bootstrap = SSHKeyBootstrap(sshExecutable: instant, timeout: 20, temporaryRoot: directory)

    for _ in 0..<12 {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask { try await bootstrap.installAuthorizedKey(endpoint: "dev@host", authorizedKey: key, password: "s3cret") }
            }
            try await group.waitForAll()
        }
    }

    // Nothing is left behind, however many runs overlapped.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("northpane-ssh-bootstrap-") }
    #expect(leftovers.isEmpty)
}

/// An `ssh` that is gone almost before the bootstrap looks at it is what raced the termination
/// handler against the "has it already exited?" check and resumed the continuation twice. The
/// sequential walk keeps that path covered without the load of the test above.
@Test func bootstrapSurvivesAnSSHThatExitsBeforeItIsEverAsked() async throws {
    let directory = try privateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = try NativeSSHCredential().authorizedKey
    let instant = directory.appending(path: "fake-ssh-instant")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: instant)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: instant.path)
    let bootstrap = SSHKeyBootstrap(sshExecutable: instant, timeout: 20, temporaryRoot: directory)

    for _ in 0..<25 {
        try await bootstrap.installAuthorizedKey(endpoint: "dev@build-box", authorizedKey: key, password: "pw")
    }

    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("northpane-ssh-bootstrap-") }
    #expect(leftovers.isEmpty)
}
#endif
