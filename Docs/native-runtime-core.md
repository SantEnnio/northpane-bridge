# Native runtime core

The native daemon owns one persistent Workspace/tab/Pane graph, live Unix PTYs,
the authoritative terminal engine, and global terminal control leases. Separate
Bridge connections use typed private RPCs to reach the same owner. Detaching a
Bridge or an attachment preserves the child, history and graph. A daemon restart
reloads the graph with a new incarnation; it does not claim to resurrect children.

`NativeHostRuntime` implements the same narrow `HostRuntime` interface as the
Herdr adapter. It is available on macOS and Linux. The Bridge's default selection
chooses an installed Herdr by default and otherwise the native owner. The
revision 25 handshake reports that choice; native Hosts reject legacy Clients. Windows preserves Herdr support; native ConPTY is a separate milestone.

The additive `workspace_model` and `terminal_frames` readiness flags distinguish
older healthy owners. A newer Bridge never restarts an older owner to acquire
features. Unsupported operations fail before being sent. Private IPC revision
remains 1; these additions do not change the Client/Bridge protocol. Rejected
commands preserve framing and do not publish partial graph mutations.

## Process and lease ownership

`PTYProcess` uses Northpane's C/POSIX `forkpty` shim. Arguments are prepared before
fork, an exec-error pipe reports invalid paths synchronously, inherited descriptors
are closed, and signal masks/handlers are reset. A dedicated reader drains output
before exit and reaps the child. Linux PTY `EIO` is EOF. Explicit Workspace closure
escalates TERM to KILL after two seconds; connection detach never terminates it.

The owner serializes graph, emulator, metadata and lease mutations. Reader callbacks
apply backpressure rather than queueing an unbounded transcript. Input writes stay
outside the emulator queue so a slow child can still drain its output. Connection-
scoped attachment tokens and unique process-birth proofs reject stale input after
replacement. Takeover revokes the previous global controller, including controllers
in another Bridge process. Observers can page their own history view but cannot send
input or resize the process. Counts, grid dimensions and RPC payloads are bounded.

Only graph shape and launch directories are persisted. Environment values, terminal
contents and credentials are not written to the layout file. Agent status remains
`unknown` until a trusted status integration supplies evidence; terminal output is
not evidence that an agent is blocked or waiting for input.

## Authoritative painted frames

SwiftTerm is pinned to upstream commit
`fe4fb45d5888ce33ff3788d6873870a73894a41b`, coordinated with the Client dependency.
Its public owned render snapshot supplies cells, soft-wrap flags, DEC line modes,
colors and palette. Northpane uses the portable engine, never upstream process/UI
wrappers. No Northpane app UI source lives in this repository.

Only the Host receives raw PTY bytes and answers terminal queries. Each attachment
receives a complete painted view, followed by further painted views. This is not a
resumable parser checkpoint: fragmented UTF-8, CSI/OSC state, saved cursors and
charsets remain in the authoritative Host engine. No parser continuation is replayed
on the Client. The initial paint resets the Client; subsequent paints reuse its
buffer, preserving a selection whose cells remain unchanged. Soft wraps use real
autowrap, null cells remain null, Unicode wide cells and OSC 8 links are preserved,
and input-encoding modes are explicitly updated. Alternate screens and Host history
pages are painted without moving the Host cursor. A slow consumer sees coalesced
frames; there is no disconnected output queue to replay.

The former experimental `TerminalViewport` checkpoint probe has been retired. Its
continuation tests do not describe the production seam. `NativeTerminalPaintTests`
checks the actual frame contract, including wraps/copy/reflow, palette/reverse video,
DEC double lines, links, fragmented parser input and recorded shell/vim/less output.
Graphics and real agent-UI certification remain outside these textual fixtures.

The pinned upstream source supports Musl directly. The static-build helper verifies
the revision and rejects local changes; historical 1.15 patches are not applied.
`SWIFTTERM_EXCLUDE_APPLE=1` excludes Apple sources when cross-compiling from macOS.
The CI/release macOS jobs select Xcode 26.3 and install the Swift 6.3.2 compiler explicitly. Windows dependency checkouts
retain upstream LF resources: the terminfo build-info generator requires that form.
Linux Crypto C++ objects link their runtime explicitly (GNU libstdc++ or static-SDK
libc++), including when the dependency graph has build-tool executables.

Primary source: [pinned SwiftTerm render snapshot](https://github.com/migueldeicaza/SwiftTerm/blob/fe4fb45d5888ce33ff3788d6873870a73894a41b/Sources/SwiftTerm/Portable/TerminalRenderSnapshot.swift).

## Verification

```
swift test --jobs 2
NORTHPANE_TERMINAL_BENCHMARK=1 swift test --jobs 2 --filter PTYProcessTests
```

Owner, socket and adapter tests use temporary homes and synthetic local processes.
They cover lease takeover, observer isolation, detach/reconnect continuity, process
replacement, rejected launches, graph durability and owner exit. They never use real
operator sessions or provider accounts. The PTY stress test validates every byte of
50 MiB without storing a transcript; the optional emulator benchmark measures parsing
and bounded retained history. Those are harness measurements, not production memory
guarantees.

Opt-in corpus recording uses `NORTHPANE_TERMINAL_CORPUS` and
`NORTHPANE_TERMINAL_CORPUS_OUTPUT`. Review recordings for private identifiers before
adding fixtures. External agent CLIs require explicit operator authorization: an
empty home does not establish absence of Keychain access or external requests.
