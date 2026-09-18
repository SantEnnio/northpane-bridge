#!/bin/sh
set -eu

case " $* " in
  *" api snapshot "*)
    if [ -n "${NORTHPANE_FIXTURE_WORKTREE:-}" ]; then worktree="{\"checkout_path\":\"$NORTHPANE_FIXTURE_WORKTREE\",\"is_linked_worktree\":false,\"repo_key\":\"$NORTHPANE_FIXTURE_WORKTREE/.git\",\"repo_name\":\"fixture\",\"repo_root\":\"$NORTHPANE_FIXTURE_WORKTREE\"}"; else worktree=null; fi
    # A pane whose agent draws on the alternate screen: Herdr holds nothing above it, ever.
    if [ -n "${NORTHPANE_FIXTURE_ALT_SCREEN_PANE:-}" ]; then
      alt=",{\"pane_id\":\"pane-alt\",\"terminal_id\":\"terminal-2\",\"workspace_id\":\"workspace-1\",\"tab_id\":\"tab-1\",\"focused\":false,\"agent\":\"opencode\",\"agent_status\":\"idle\",\"revision\":1,\"terminal_title_stripped\":\"OpenCode\",\"cwd\":\"${NORTHPANE_FIXTURE_WORKTREE:-/tmp}\",\"foreground_cwd\":\"${NORTHPANE_FIXTURE_WORKTREE:-/tmp}\",\"scroll\":{\"max_offset_from_bottom\":0,\"offset_from_bottom\":0,\"viewport_rows\":24}}"
    else
      alt=""
    fi
    printf '%s\n' "{\"id\":\"fixture\",\"result\":{\"type\":\"session_snapshot\",\"snapshot\":{\"version\":\"0.8.2\",\"protocol\":20,\"workspaces\":[{\"workspace_id\":\"workspace-1\",\"number\":1,\"label\":\"Fixture\",\"focused\":true,\"pane_count\":1,\"tab_count\":1,\"active_tab_id\":\"tab-1\",\"agent_status\":\"blocked\",\"worktree\":$worktree}],\"tabs\":[{\"tab_id\":\"tab-1\",\"workspace_id\":\"workspace-1\",\"number\":1,\"label\":\"Test\",\"focused\":true,\"pane_count\":1,\"agent_status\":\"blocked\"}],\"panes\":[{\"pane_id\":\"pane-1\",\"terminal_id\":\"terminal-1\",\"workspace_id\":\"workspace-1\",\"tab_id\":\"tab-1\",\"focused\":true,\"agent_status\":\"blocked\",\"revision\":1,\"display_agent\":\"Fixture Agent\",\"terminal_title_stripped\":\"Fixture Terminal\",\"cwd\":\"${NORTHPANE_FIXTURE_WORKTREE:-/tmp}\",\"foreground_cwd\":\"${NORTHPANE_FIXTURE_WORKTREE:-/tmp}/docs\",\"scroll\":{\"max_offset_from_bottom\":120,\"offset_from_bottom\":0,\"viewport_rows\":24}}$alt],\"layouts\":[],\"agents\":[]}}}"
    ;;
  *" terminal session "*)
    printf '%s\n' '{"type":"terminal.frame","bytes":"G1sySFRlc3QgZnJhbWUNCg=="}'
    while IFS= read -r line; do
      case "$line" in
        *terminal.release*) printf '%s\n' '{"type":"terminal.closed"}'; exit 0 ;;
        *terminal.input*) printf '%s\n' '{"type":"terminal.frame","bytes":"YWNrDQo="}' ;;
        *terminal.scroll*) printf '%s\n' '{"type":"terminal.frame","bytes":"c2Nyb2xsZWQNCg=="}' ;;
      esac
    done
    ;;
  *" workspace rename "*)
    printf '%s\n' '{"id":"fixture-workspace-rename","result":{"type":"ok"}}'
    ;;
  *" workspace close "*)
    printf '%s\n' '{"id":"fixture-workspace-close","result":{"type":"ok"}}'
    ;;
  *" workspace create "*)
    printf '%s\n' '{"id":"fixture-workspace-create","result":{"root_pane":{"pane_id":"workspace-created:p1","workspace_id":"workspace-created"},"type":"workspace_created","workspace":{"workspace_id":"workspace-created"}}}'
    ;;
  *" pane run "*)
    printf '%s\n' '{"id":"fixture-pane-run","result":{"type":"pane_input"}}'
    ;;
  *" agent wait "*)
    printf '%s\n' '{"id":"fixture-agent-wait","result":{"type":"agent_wait","agent":{"state":"idle"}}}'
    ;;
  *" agent rename "*)
    printf '%s\n' '{"id":"fixture-agent-rename","result":{"type":"agent_renamed"}}'
    ;;
  *" --version "*) printf '%s\n' 'herdr 0.8.2' ;;
  *" server "*) exit 0 ;;
  *) printf '%s\n' 'unsupported fake Herdr invocation' >&2; exit 2 ;;
esac
