---
name: northpane
description: Publish, inspect, read, or close Northpane Preview and Artifact resources from a Herdr worktree. Use when a user wants an agent-produced local web server or file exposed in the Northpane app, or asks for Northpane resource status.
---

# Northpane

Use the `northpane` CLI from inside the relevant Herdr worktree. Prefer `--json` and report the returned resource ID, revision, expiry, health, and viewer availability.

- Check reachability with `northpane status --json`.
- Register a loopback web server with `northpane preview server --origin http://127.0.0.1:<port> --title <title> --json`. Keep the server process alive; Northpane proxies only the registered origin.
- Publish a file or directory inside the current worktree with `northpane artifact publish <path> --json`. Publication is an immutable snapshot, so publish again after content changes.
- Inspect resources with `northpane preview list --json` or `northpane artifact list --json`.
- Close a Preview or delete an Artifact using its current ID and revision. If the revision changed, list again and reassess instead of retrying the stale mutation.
- Read an Artifact in bounded chunks with `northpane artifact read <id> --path <relative-path> --offset <bytes> --length <bytes>`.

Start `northpane auth github` only when the user explicitly requests GitHub CLI authorization. The command waits for strong confirmation in a paired Northpane app and never prints a provider token.

Treat a failed or unavailable viewer as a degraded resource capability; do not infer that the underlying terminal or Host connection failed.
