# Native process foundation

The native runtime is still experimental. Herdr remains the default and the
Bridge has no production native Workspace or terminal adapter yet.

On macOS and Linux the explicit commands are:

```
NORTHPANE_STATE_DIRECTORY=/tmp/northpane-cert northpane-bridge runtime --ensure
NORTHPANE_STATE_DIRECTORY=/tmp/northpane-cert northpane-bridge runtime --status
```

`runtime` runs the owner in the foreground. `--ensure` reuses a healthy owner
or executes a detached owner and waits for its handshake; `--status` only
connects. Both print revision, incarnation, version and process ID as JSON.
They do not start shells/agents, select the native adapter or install a user
service. Windows reports the command as unavailable until its own IPC and
process lifecycle are implemented.

## Local trust and lifetime

The state directory contains `runtime/` (0700), `runtime.lock` (0600) and
`runtime.sock` (0600). The lock is held for the owner's lifetime. Directory
and lock are opened without following links, ownership is checked and a lock
with multiple hard links is refused. Only the locked owner removes an old
socket; a regular file or link at the socket path is never removed. Both
listener and connecting client verify the peer's kernel-provided effective
UID (`getpeereid` on macOS, `SO_PEERCRED` on Linux).

The detached launcher uses `setsid` and double fork, resets signals and closes
inherited descriptors. Only C/POSIX calls run after fork. A close-on-exec pipe
reports failed exec synchronously. The child has null standard streams, so
it cannot retain the Bridge's SSH pipes. Disconnecting a client never stops
the owner. A healthy owner is reused regardless of the caller's executable
version. An incompatible/unauthenticated response is not treated as absence.

`Protocol/runtime-v1.proto` is a separate user-local contract, not the public
Client schema. Messages have a four-byte big-endian length, a one-MiB ceiling
and a negotiated revision. The first revision supports hello/ping only; zero
and unknown revisions are rejected. The revision policy retains N-1 when it
exists. Partial/failed exchanges close their stream. Header/body timeouts and
a 32-connection limit bound idle peers; idle RPC connections expire after ten
seconds without affecting the process. Longer terminal/event channels require
their own lifecycle in the forthcoming adapter.

## Certification and remaining work

Process tests invoke separate Bridge executables in temporary directories and
check detach, reconnect, reuse after an executable change, concurrent starts,
kill/restart and a new incarnation. Socket permission/link tests, invalid
revisions and malformed/oversized frames exercise the same interface. A UID
policy check supplements real same-user kernel credential checks; the tests
do not claim to have created an actual foreign-user process.

`NativeRuntimeUserService` prepares launchd/systemd registration for the
forthcoming native adapter. It reuses a healthy owner before touching service
configuration, never bootouts/restarts an owner to apply an update, and keeps
versioned installations on their `current` executable pointer. Linux attempts
user linger and reports its verified state; macOS does not claim survival
across full user logout from LaunchAgent registration alone. Missing service
managers fall back to the detached launcher, with logout continuity unknown.
This interface is not yet called by the production Bridge.

The launchd opt-in test uses a unique certification label and temporary
registration file, then removes that service. It checks launchd startup and
automatic restart after SIGKILL, not live Pane continuity:

```
NORTHPANE_RUNTIME_SERVICE_CERT=1 swift test --jobs 2 --filter NativeRuntimeLaunchdTests
```

For the quoting/expansion rules used by the Linux unit, see the primary
[systemd service documentation source](https://github.com/systemd/systemd/blob/main/man/systemd.service.xml).

This is not yet a guarantee across logout, reboot or a live update with Pane
processes. Linux service-manager/linger certification, the Workspace model,
PTY ownership in this process and full terminal reattachment remain required
before enabling automatic fallback on Hosts without Herdr.

## Structural model

An internal `NativeWorkspaceStore` implements the persistent graph independently
of terminal parsing: Workspace `wN`, tab `wN:tM`, Pane `wN:pM`, binary right/down
splits, active tabs/Panes and Workspace focus. Counters never reuse a closed
identity. Mutations validate a copy, write `layout-v1.json` atomically and only
then publish the new graph/revision; failure preserves both the prior graph
and the next identity. Loading rejects invalid references, counters, versions,
split ratios/depths and oversized files instead of resetting user data.

Snapshots read the graph under one lock. They advertise no capabilities or
agents and mark process status unknown: this is shape storage, not evidence of
a running shell. The file carries no environment, terminal bytes, input or
agent credentials. The store must be owned under the daemon's process lock;
RPC integration, live metadata and PTY ownership are still forthcoming.
