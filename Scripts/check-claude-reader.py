#!/usr/bin/env python3
"""Exercise the distributed SDK helper with synthetic sessions and no tools on PATH."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid

helper = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="northpane-reader-") as temporary:
    root = Path(temporary).resolve()
    workspace = root / "workspace"
    workspace.mkdir()
    config = root / "config"
    project = config / "projects" / re.sub(r"[^a-zA-Z0-9]", "-", str(workspace))
    project.mkdir(parents=True)
    session = str(uuid.uuid4())
    first, second = str(uuid.uuid4()), str(uuid.uuid4())
    common = {"sessionId": session, "cwd": str(workspace), "isSidechain": False,
              "version": "2.1.291", "userType": "external", "timestamp": "2026-01-01T00:00:00Z"}
    rows = [dict(common, uuid=first, parentUuid=None, type="user", message={"role": "user", "content": "Synthetic hello"}),
            dict(common, uuid=second, parentUuid=first, type="assistant", message={"role": "assistant", "content": [{"type": "text", "text": "Synthetic answer"}]})]
    transcript = project / (session + ".jsonl")
    transcript.write_text("".join(json.dumps(row) + "\n" for row in rows))
    # Local malicious runtime settings must never load, even in the working directory.
    (root / ".env").write_text("CLAUDE_CONFIG_DIR=/nonexistent\n")
    (root / "bunfig.toml").write_text('preload = ["./must-not-load.js"]\n')
    (root / "must-not-load.js").write_text('throw new Error("Workspace code loaded");\n')
    environment = {"HOME": str(root), "PATH": "/nonexistent", "CLAUDE_CONFIG_DIR": str(config),
                   "BUN_BE_BUN": "0", "BUN_OPTIONS": "", "BUN_JSC_useJIT": "1"}
    command = [str(helper)]
    if (helper.parent / "ld-musl.so").exists():
        environment["BUN_BE_BUN"] = "1"
        command = [str(helper.parent / "ld-musl.so"), "--library-path", str(helper.parent), str(helper),
                   "--no-env-file", "--config=/dev/null", "--no-install", str(helper.parent / "reader.mjs")]

    def run(*arguments):
        completed = subprocess.run([*command, *arguments], env=environment, cwd=root,
                                   capture_output=True, timeout=15)
        assert completed.returncode == 0, completed.stderr.decode()
        assert not completed.stderr, "Unexpected diagnostic output"
        return json.loads(completed.stdout)

    assert run("--version") == {"sdk": "0.3.293", "runtime": "1.3.10"}
    sessions = run(str(workspace), "", "50")["sessions"]
    assert [row["sessionId"] for row in sessions] == [session], sessions
    messages = run(str(workspace), session, "50")["messages"]
    assert [row["uuid"] for row in messages] == [first, second], messages
    assert "Synthetic answer" in json.dumps(messages)
    assert run(str(workspace), str(uuid.uuid4()), "50")["problem"] == "unreadable"
    # Real histories readily exceed 16 MiB; recent messages must remain readable.
    large = dict(common, uuid=str(uuid.uuid4()), parentUuid=second, type="assistant",
                 message={"role": "assistant", "content": [{"type": "tool_use", "id": "tool-1", "name": "Read",
                            "input": {"output": "x" * (17 * 1024 * 1024)}}]})
    history = [*rows, large]
    parent = large["uuid"]
    for index in range(60):
        entry = dict(common, uuid=str(uuid.uuid4()), parentUuid=parent, type="assistant",
                     message={"role": "assistant", "content": [{"type": "text", "text": f"Recent message {index}"}]})
        history.append(entry)
        parent = entry["uuid"]
    transcript.write_text("".join(json.dumps(row) + "\n" for row in history))
    recent = run(str(workspace), session, "20")
    assert not recent.get("problem"), f"Large history unavailable: {recent.get('problem')}"
    assert len(recent["messages"]) == 20 and recent["hasOlder"]
    assert recent["messages"][-1]["uuid"] == parent
    # A huge recent tool result must be shortened before the subprocess pipe limit.
    tool = dict(common, uuid=str(uuid.uuid4()), parentUuid=parent, type="user",
                message={"role": "user", "content": [{"type": "tool_result", "tool_use_id": "tool-1",
                           "content": "\\\"\n" * (3 * 1024 * 1024)}]})
    final = dict(common, uuid=str(uuid.uuid4()), parentUuid=tool["uuid"], type="assistant",
                 message={"role": "assistant", "content": [{"type": "text", "text": "Latest answer survives"}]})
    with transcript.open("a") as output:
        output.write(json.dumps(tool) + "\n" + json.dumps(final) + "\n")
    recent = run(str(workspace), session, "20")
    assert not recent.get("problem"), recent.get("problem")
    assert recent["truncated"] and recent["messages"][-1]["uuid"] == final["uuid"]
    assert "Latest answer survives" in json.dumps(recent)
    assert len(json.dumps(recent).encode()) < 768 * 1024
    with transcript.open("ab") as output:
        output.truncate(128 * 1024 * 1024 + 1)
    assert run(str(workspace), session, "50")["problem"] == "outputTooLarge"
    print("Bundled Claude reader: listing, large history, bounded tool output, safety limit and config isolation passed")
