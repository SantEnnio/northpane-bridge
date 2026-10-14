# Native agent status

The native owner accepts lifecycle evidence only for the current Pane process proof
and root conversation. It never derives blocked from screen text, output volume,
silence, or prompt patterns. Manually launched agents are recognized by foreground
executable/launcher arguments and process birth, with unknown status when no
trusted hook exists. This uses platform process metadata, not provider accounts or
conversation files.

Hook commands are advisory: no stdout decisions and no failure that could approve,
deny or stop an agent tool. Input is bounded to 64 KiB. Only session identity, cwd,
status and an opaque pending-request proof cross the private socket. Prompts, tool
input, transcript paths and messages are not forwarded or persisted. Matching tool
input may be hashed locally to correlate a permission request with its completion;
only that digest is retained in memory.

A hook may first arrive after startup, for example when a user has reviewed Codex
hooks. An explicit root SessionStart can replace the conversation within the same
process. Subagent fields and foreign session callbacks are ignored/rejected. Multiple
pending permissions remain blocked until their matching completions arrive; an
unrelated tool result cannot clear another request. Duplicate evidence does not
publish another transition. The watcher follows explicit native blocked periods
without Herdr's screen-detection grace period.

## Provider configuration

- **Codex:** CLI configuration overrides add session hook definitions for lifecycle,
  permission and completion events. Its normal hook trust review remains active.
  No hook-trust, approval, sandbox or managed-policy bypass is enabled. Until trusted,
  or when hooks are disabled by policy, status stays unknown.
- **Claude Code:** a per-process --settings value adds command hooks. Permission
  requests and supported interactive tools report blocked; completion resolves
  their request, and Stop/StopFailure reports idle. Global/project settings remain
  untouched, including managed restrictions.
- **OpenCode:** a local module is appended to per-process inline configuration.
  Existing inline settings/plugins are preserved. It subscribes to root session,
  permission and question events, serializes reporting, and ignores child sessions.
  No npm plugin is installed. Its module contains no credentials or session content.

The internal reporter, northpane-bridge hook, uses process-scoped environment
values created by the owner and never starts another owner. An older healthy owner
that lacks agent_hooks is not restarted, and unsupported hook RPCs are not sent.

## Verified scope

Synthetic owner/IPC tests cover root/process isolation, late trust, root-session
replacement, concurrent permissions, duplicate Attention, privacy and process cwd.
A Node harness exercises the actual OpenCode module with synthetic events and a
local reporter. Explicit opt-in startup checks used Codex 0.162.1, Claude Code
2.1.296 and OpenCode 1.18.34 with empty temporary homes, a minimal environment and
no prompts. These establish launch/configuration compatibility, not authenticated
permission/turn completion or iPhone push certification.

    swift test --jobs 2

The optional nativeAgentHookArgumentsAreAcceptedAtIsolatedStartup test reads local
CLI paths from NORTHPANE_NATIVE_STARTUP_AGENTS, a privately supplied JSON object.

Primary references:

- [Codex hook lifecycle and trust](https://learn.chatgpt.com/docs/hooks)
- [Codex configuration](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Claude Code hook reference](https://code.claude.com/docs/en/hooks)
- [OpenCode plugins](https://docs.opencode.ai/docs/plugins/)
- [OpenCode configuration precedence](https://docs.opencode.ai/docs/config/)
- [OpenCode 1.18.34 plugin loader](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/opencode/src/plugin/shared.ts)
