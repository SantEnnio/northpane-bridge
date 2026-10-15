#!/usr/bin/env python3
"""Extract only pinned runtime libraries; never run APK scripts or use Host libraries."""
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import urllib.request

root = Path(__file__).resolve().parent.parent
architecture, output = sys.argv[1], Path(sys.argv[2])
entries = json.loads((root / "Integrations/claude-reader/linux-libraries.json").read_text())[architecture]
for entry in entries:
    with urllib.request.urlopen(entry["url"], timeout=60) as response:
        data = response.read(8 * 1024 * 1024 + 1)
    if hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise SystemExit("Runtime library checksum mismatch: " + entry["name"])
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        if entry["name"] == "musl":
            member = archive.getmember(f"lib/ld-musl-{architecture}.so.1")
            name = "ld-musl.so"
        elif entry["name"] == "libgcc":
            member = archive.getmember("usr/lib/libgcc_s.so.1")
            name = "libgcc_s.so.1"
        else:
            member = next(m for m in archive if m.isfile() and m.name.startswith("usr/lib/libstdc++.so."))
            name = "libstdc++.so.6"
        if not member.isfile():
            raise SystemExit("Expected a regular runtime library")
        (output / name).write_bytes(archive.extractfile(member).read())
        (output / name).chmod(0o700)
