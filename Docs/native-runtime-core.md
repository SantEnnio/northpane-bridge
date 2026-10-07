# Native runtime core

This module is preparation for Hosts without Herdr. The Bridge still selects
Herdr; no native Workspace service or terminal attachment is enabled yet.

## PTY ownership

`PTYProcess` owns a Unix child and its controlling terminal. `NorthpanePTY`
prepares arguments in the parent, calls `forkpty`, and uses only C/POSIX calls
between fork and exec. An exec-error pipe makes a missing executable or working
directory a synchronous error rather than a successful launch followed by an
unexplained exit. Inherited descriptors are closed; signal masks and handlers
are reset before exec.

The dedicated reader drains output before reporting exit and reaps the child
with `waitpid`. Linux PTY `EIO` is treated as EOF. Input handles short writes and
backpressure; resize uses `TIOCSWINSZ`. Explicit Pane closure escalates from TERM
to KILL after two seconds. Client detach must leave the PTY owner alone.
Persistence across Bridge/SSH process exit requires the separate runtime
service, which is not implemented by this module.

Windows compiles the terminal engine and replay tests but does not yet provide
ConPTY. No Unix process API is exposed there.

## Terminal engine decision

SwiftTerm is pinned to **1.15.0**, matching the app's existing dependency. Its
portable `Terminal` is used directly; Northpane does not use `LocalProcess` or
`HeadlessTerminal`. The dependency itself also compiles Apple UI sources on a
Mac; none of that UI is Northpane product source or used by the Bridge. On Linux
and Windows its manifest excludes the Apple UI directories.

The Static Linux SDK uses Musl rather than Glibc. The 1.15 engine imports Glibc
unconditionally in `KittyGraphics.swift`. `build-static-linux.sh` applies the
small patches in `Patches/` through `prepare-swiftterm-musl.sh`.
The helper checks the exact revision and the full input-file SHA-256 and is
idempotent for the second architecture. Unknown source files fail the build;
The patches select the available libc and exclude unused upstream PTY/process
and Apple UI wrappers when building for musl. Northpane uses its own C PTY
shim; the upstream wrappers assume Glibc's Swift ioctl overlays. The manifest
patch also permits a musl build hosted on macOS. Terminal behavior is unchanged. Direct
musl builds must run that helper first.

The checked 1.20.0 manifest includes `SwiftTermBuildInfoPlugin` and does not
provide a portable render snapshot. Current main requires newer tools and has
additional graphics dependencies. Its `TerminalRenderSnapshot` exposes wraps
and rendering state, but is not a complete resumable terminal checkpoint.

Primary sources:

- [SwiftTerm 1.15 manifest](https://github.com/migueldeicaza/SwiftTerm/blob/v1.15.0/Package.swift)
- [SwiftTerm 1.20 manifest](https://github.com/migueldeicaza/SwiftTerm/blob/v1.20.0/Package.swift)
- [Portable render snapshot](https://github.com/migueldeicaza/SwiftTerm/blob/main/Sources/SwiftTerm/Portable/TerminalRenderSnapshot.swift)
- [forkpty semantics](https://www.man7.org/linux/man-pages/man3/openpty.3.html)

## Replay feasibility and remaining gate

`TerminalViewport` is **internal and experimental**. It reproduces visible
cells, Unicode graphemes and wide cells, SGR attributes, titles, cursor style
and visibility, basic modes, mouse selection, margins and both visible buffers.
It retains references to SwiftTerm's buffers through activation callbacks; it
does not switch the live terminal during serialization. Reprinting the final
leading cell restores pending autowrap. Incomplete CSI, bounded string payloads
and UTF-8 tails are appended to replay so subsequent bytes can complete them.

Synthetic tests and recorded shell/vim/less output compare cells and cursor,
then feed the same subsequent bytes to the original and replayed terminal.
Regression tests also demonstrate two unresolved differences:

- Scrollback is retained by the Host emulator but not transferred by replay.
- Soft-wrap flags are not public in 1.15. Replayed cells look identical, but
  resizing can reflow them differently.

Before enabling attachments, implement Host scroll views and preserve wrap
metadata (through an appropriate engine API or independently verified adapter).
Also cover saved modes, charsets, tab stops, OSC 8, palettes, graphics and
keyboard protocols. String sequences above 64 KiB and CSI above 1 KiB are
bounded by the probe and are not guaranteed to resume. A Client must not
generate duplicate terminal-query replies alongside the Host emulator.

Agent UI and htop recordings remain outstanding. A successful viewport test
must never be described as a complete terminal checkpoint or agent certification.

## Verification

```
swift test --jobs 2
NORTHPANE_TERMINAL_BENCHMARK=1 swift test --jobs 2 --filter PTYProcessTests
```

The default PTY stress test checks every byte of 50 MiB of output without
retaining a transcript. The opt-in emulator benchmark parses 50 MiB of text,
checks the retained history bound and compares the resulting viewport. Both
report elapsed time, test-process CPU and peak RSS; these are measurements of
the test harness, not production-service memory guarantees.

Local corpus recording is opt-in via `NORTHPANE_TERMINAL_CORPUS` (a JSON mapping
of labels to executable paths) and `NORTHPANE_TERMINAL_CORPUS_OUTPUT` (a temporary
output directory). It creates an empty home, supplies a minimal environment,
answers terminal queries and terminates each process. Review the bytes for
private identifiers before copying recordings into fixtures. Running external
agent CLIs additionally requires explicit operator authorization: an empty
home alone does not guarantee absence of Keychain access or external requests.
