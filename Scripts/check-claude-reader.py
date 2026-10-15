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
    with transcript.open("ab") as output:
        output.truncate(16 * 1024 * 1024 + 1)
    assert run(str(workspace), session, "50")["problem"] == "outputTooLarge"
    print("Bundled Claude reader: synthetic listing, history, size limit and config isolation passed without Node/npm/git")
