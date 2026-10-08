# Northpane Bridge

The Bridge is the part of Northpane that runs on your own
computer, the **Host**, next to [Herdr](https://herdr.dev). The Northpane apps for Mac, iPhone
and iPad talk to it over SSH to show your Herdr workspaces, follow and control terminals, open
previews and read the files an agent points at. The Bridge never runs as root and keeps
everything it writes under your home directory.

It is open source so that you can read exactly what runs on your machine with access to your
terminals.

## Install

The Northpane apps are moving to installing and updating the Bridge through these same
scripts: over SSH they run `install.sh` (or `install.ps1` on Windows) with the exact version
and SHA-256 the app was built with, check that the new Bridge answers, and roll back if it
does not. When the Host cannot reach GitHub, the app downloads the same file, checks it, and
sends it over SFTP instead.

To install by hand (once the first release is published):

```sh
# Linux and macOS
curl -fsSL https://github.com/SantEnnio/northpane-bridge/releases/latest/download/install.sh | sh
```

```powershell
# Windows
irm https://github.com/SantEnnio/northpane-bridge/releases/latest/download/install.ps1 | iex
```

The script checks the download against the release's `SHA256SUMS`, installs into
`~/.local/share/northpane/bridge/versions/<version>` (`%LOCALAPPDATA%\Northpane\Bridge` on
Windows, where the active version is the `current` junction on your PATH), keeps the previous
version for rollback and links `~/.local/bin/northpane-bridge`.

| Host | Binary |
| --- | --- |
| Linux x86_64 and arm64 | fully static (musl): no Swift runtime or particular glibc needed |
| Windows x86_64 | executable with the Swift and Visual C++ runtime DLLs beside it |
| macOS (universal) | one executable for Apple silicon and Intel, signed ad hoc |

A Host keeps the key that proves its identity in a file only its user can read, on every platform
and whatever built the Bridge, the way `sshd` keeps a host key. Updating, rolling back or
reinstalling the Bridge therefore never changes which Host it is. (Until 1.0.3 a release Bridge on
a Mac kept the key in the Keychain; a Bridge from 1.0.4 on still finds it there and copies it
beside the state.)

Herdr must be installed on the Host. The Bridge finds it in `~/.local/bin` (Herdr's
installer), Homebrew, `/usr/local/bin`, `/usr/bin` or `PATH`, or wherever
`NORTHPANE_HERDR_EXECUTABLE` points.

## Agent plan usage

When an app asks, the Bridge says how much of the agent subscriptions on the Host has been
used, by running the CLI you installed with the session it already holds. It has no
credential of its own, and it sends on percentages, amounts and reset times only: never an
account, a session or the CLI's own text. A reading is reused for five minutes, by every app
that reaches the Host (it is kept, numbers only, in
`~/.northpane/services/agent-usage-readings-v1.json`), and nothing runs while no app is asking.
What it runs, and nothing else:

- **Claude**: `claude -p "/usage" --output-format json --no-session-persistence --strict-mcp-config`,
  and `claude auth status` after a failure. No tokens are spent. The output is text meant for a
  person and can change without notice; when it does, the Bridge stops reading rather than guess.
- **Codex**: `codex app-server`, asked `account/rateLimits/read` (and `account/read` after a
  failure), which is its documented interface.
- **Antigravity**: off until you turn it on from an app, for that Host. `agy` is found by looking
  at files and is never run before that. Then `agy -p /usage --output-format json`, once per
  reading, which invokes no model. [Google's Antigravity Additional Terms](https://antigravity.google/terms)
  restrict third-party software that accesses the service and Google has not said whether this
  counts, so turning it on is your own decision about your own Google account, and you can
  withdraw it. The choice is kept in `~/.northpane/services/agent-usage-consent-v1.json`.

## When a Pane was last used

Herdr reports no times, so the Bridge tells an app when each Pane was last used from the Pane's
terminal: the system notes when a terminal is written to and read from, which is what `w` shows as
idle time. To know which terminal is which Pane, it looks at the processes Herdr starts directly,
one per Pane, belonging to your own user, and reads the `HERDR_PANE_ID` Herdr puts in their
environment. Nothing else in that environment is kept or sent, nor anything the terminal shows:
an app receives one time per Pane, to the second. The process table is read again at most every
30 seconds, sooner when a new Pane appears. Herdr says nothing while a Pane's process works without
changing status, so while an app watches, the Bridge looks at the terminals every 20 seconds and
sends a new snapshot when one of them was used. On macOS and Linux only; on Windows no time is sent.

## What is in this repository

- `northpane-bridge`: the Bridge. `northpane-bridge serve --stdio` is what an SSH session
  starts; `northpane-bridge self-check --json` reports whether the binary is sound.
- `northpane`: the command-line tool agents use from inside a Herdr pane to publish
  previews and artifacts to the Northpane app (`northpane --help`), and its agent skill in
  `Integrations/northpane`.
- The libraries both sides share: the wire protocol (`Protocol/bridge-v1.proto`, with every
  published revision frozen in `Protocol/compatibility`), the Herdr integration, the
  projection of Herdr's state, and the connection and security layers.
- The relay a Mac of the Operator's can run for their other devices (`SSHRelayServer`): an SSH
  server that takes enrolled device keys only and opens `direct-tcpip` channels only to the
  Hosts the Operator enabled, each named by its ID and dialled by the Mac where it reaches it
  now, never at an address the device names. A device runs its own SSH session with the Host
  inside that channel, so the relay never sees what the session carries. The Mac that runs the
  relay has no SSH server of its own: when the app offers it, the relay joins a session to that
  Mac's own Bridge, which asks of the device what a Bridge asks over SSH, to pair and to prove
  its key in every session. The relay runs no shell and no command of the device's.

## Build and test

Swift 6.0 or later.

```sh
swift build
swift test
swift run northpane-bridge self-check --json
```

The conformance run against a real Herdr is opt-in, and uses its own home and session so
your Herdr is never touched:

```sh
HOME=/tmp/herdr-home herdr --session npcert server &
NORTHPANE_CONFORMANCE_HERDR=$(command -v herdr) NORTHPANE_CONFORMANCE_HOME=/tmp/herdr-home \
  swift test --filter liveHerdrConformance
HOME=/tmp/herdr-home herdr --session npcert server stop
```

The static Linux binaries need a swift.org toolchain and the Static Linux SDK:

```sh
swift sdk install <static-linux SDK URL> --checksum <sha256>   # see .github/workflows/ci.yml
Scripts/build-static-linux.sh x86_64
Scripts/build-static-linux.sh aarch64
```

`Scripts/check-protobuf.sh` (needs `protoc`) checks that the generated Swift matches the schema
and that no frozen revision changed.

## License

MIT, see [LICENSE](LICENSE). Third-party components and their licenses are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

### Windows directory roots (schema 22)

`LIST_HOST_DIRECTORIES` accepts `/` as the virtual computer on Windows and returns
logical drive roots as absolute directory hits. Listing a drive root returns `/`
as its parent. The virtual computer is a navigation target, never a Workspace
working directory. Empty paths still list the user's home. The command remains
directory-only and requires `terminalControl`; hidden directories and credential
stores remain excluded. File reads and path searches retain their existing roots.

## Read-only agent conversations (schema 23)

An explicitly selected Pane may request an observation of an explicitly selected
agent session. This needs the terminal-control grant: messages and tool results
can contain workspace files. The request binds the Pane to the observed runtime
incarnation; reads run outside the serial connection loop and at most two run
at once in a Bridge process. JSON readings are bounded below the wire frame limit.

On macOS/Linux, Codex uses only `app-server proxy` to the **existing** Unix socket
and WebSocket transport, initializes an observer, then calls `thread/list`,
`thread/loaded/list`, `thread/read` and `thread/turns/list`. Only a loaded thread
can be selected. It never starts a server, resumes a thread, subscribes to actions
or answers server requests. Claude uses `listSessions`, `getSessionInfo` and
`getSessionMessages` from the official Agent SDK 0.3.293, installed with Node.js
18+ under `~/.northpane/integrations/claude-reader`. It reads CLI transcripts
without invoking Claude; no diff is invented from Edit/Write inputs. OpenCode
reads the existing V1 HTTP server of 1.18.x, accepting only numeric loopback
origins with a port, refusing redirects, bounding response bytes and using Host
environment authentication when present. No replacement server is launched.

Windows adapters and OpenCode V2 are currently unavailable. Large content and
missing capabilities remain explicit in the result. Newest history windows are
re-read as snapshots, not appended deltas, so compaction and repeated reads do
not accumulate duplicate items. Conversation contents are not persisted or logged
by the Bridge. The optional live Codex test is opt-in; ordinary tests use synthetic
content only.
