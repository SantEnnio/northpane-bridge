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
| macOS (universal) | for a Mac the app does not manage; see below |

On a Mac, let the Northpane app install the Bridge. The Host's identity key is kept in the
Keychain, which grants access by code signature, so a Bridge from a release cannot use the identity
the app's own signed Bridge created — the Host stops answering until the previous one is put back.
`install.sh` refuses to replace an app-installed Bridge for that reason (`--replace-app-bridge`
insists). The macOS package is for a Mac that is only ever a Host, with no Northpane app to keep
its Bridge up to date.

Herdr must be installed on the Host. The Bridge finds it in `~/.local/bin` (Herdr's
installer), Homebrew, `/usr/local/bin`, `/usr/bin` or `PATH`, or wherever
`NORTHPANE_HERDR_EXECUTABLE` points.

## What is in this repository

- `northpane-bridge`: the Bridge. `northpane-bridge serve --stdio` is what an SSH session
  starts; `northpane-bridge self-check --json` reports whether the binary is sound.
- `northpane`: the command-line tool agents use from inside a Herdr pane to publish
  previews and artifacts to the Northpane app (`northpane --help`), and its agent skill in
  `Integrations/northpane`.
- The libraries both sides share: the wire protocol (`Protocol/bridge-v1.proto`, with every
  published revision frozen in `Protocol/compatibility`), the Herdr integration, the
  projection of Herdr's state, and the connection and security layers.

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
