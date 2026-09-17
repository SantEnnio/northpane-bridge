import Foundation
import NorthpaneProtocol

public enum SSHKeyBootstrapError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidAuthorizedKey
    case emptyPassword
    case timedOut
    /// `ssh` ended with a code that is neither an authentication nor a Host-key failure;
    /// `detail` is its standard error, so the user can see the real reason.
    case commandFailed(exitCode: Int32, detail: String)
}

/// The remote POSIX command that appends a device key to `~/.ssh/authorized_keys` once, creating
/// the directory and file with the permissions `sshd` requires. Shared by the macOS bootstrap
/// (system `ssh`) and the iOS one (native SSH), so both Clients install the key the same way.
public enum SSHAuthorizedKeyInstall {
    public static func remoteCommand(authorizedKey: String) throws -> String {
        let key = authorizedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: #"^[A-Za-z0-9@._+/=-]+ [A-Za-z0-9+/=]+( [A-Za-z0-9@._+-]+)?$"#, options: .regularExpression) != nil else {
            throw SSHKeyBootstrapError.invalidAuthorizedKey
        }
        let script = #"umask 077; d="$HOME/.ssh"; f="$d/authorized_keys"; mkdir -p "$d"; chmod 700 "$d"; touch "$f"; chmod 600 "$f"; grep -qF -- "\#(key)" "$f" || printf "%s\n" "\#(key)" >> "$f""#
        return "sh -c '\(script)'"
    }
}

/// How a remote Host launches the Bridge over SSH. A non-interactive SSH session gets a minimal
/// PATH (`/usr/bin:/bin:…`) that excludes `~/.local/bin` and Homebrew, so the command widens PATH
/// first: the Bridge is found where the installer put it, and it inherits a PATH with `herdr`.
/// Shared by the macOS (system `ssh`) and iOS (native SSH) transports so both find the Bridge.
public enum RemoteBridgeLaunch {
    /// Directories a non-interactive SSH shell omits but where the Bridge and Herdr actually live.
    public static let searchPath = "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"

    /// Where install.ps1 keeps the active Bridge on a Windows Host.
    public static let windowsBridgePath = #"%LOCALAPPDATA%\Northpane\Bridge\current\northpane-bridge.exe"#

    public static func command(_ bridgeCommand: String = "northpane-bridge", shell: HostShell = .posix) -> String {
        switch shell {
        case .posix:
            return "sh -c 'export PATH=\"\(searchPath):$PATH\"; if command -v \(bridgeCommand) >/dev/null 2>&1; then exec \(bridgeCommand) serve --stdio; else exec \"$HOME/.local/bin/\(bridgeCommand)\" serve --stdio; fi'"
        case .windows:
            // An SSH session on Windows lands in cmd.exe, which knows neither `sh` nor the POSIX
            // command above. The installed Bridge comes first; a Bridge on PATH is the fallback.
            return #"if exist "\#(windowsBridgePath)" ("\#(windowsBridgePath)" serve --stdio) else (\#(bridgeCommand).exe serve --stdio)"#
        }
    }
}
