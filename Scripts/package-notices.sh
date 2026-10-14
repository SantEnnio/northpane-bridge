#!/bin/sh
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_directory=${1:-"$repository_root/.release-artifacts"}
checkout=${2:-"$repository_root/.build/checkouts"}
if [ ! -d "$checkout" ] && [ -d "$repository_root/.build/arm64/checkouts" ]; then
  checkout="$repository_root/.build/arm64/checkouts"
fi
mkdir -p "$output_directory"
# Read only tracked license texts at the resolved revisions, including vendored
# notices. Neutral archive metadata never identifies the build machine or user.
python3 - "$checkout" "$repository_root/Package.resolved" "$output_directory/third-party-licenses.tar.gz" <<'PY'
import gzip, io, json, pathlib, subprocess, sys, tarfile
checkout, manifest, destination = map(pathlib.Path, sys.argv[1:])
pins = json.loads(manifest.read_text())["pins"]
directories = {p.name.lower(): p for p in checkout.iterdir() if p.is_dir()}
count = 0
with destination.open("wb") as output, gzip.GzipFile(filename="", fileobj=output, mode="wb", mtime=0) as compressed:
    with tarfile.open(fileobj=compressed, mode="w") as archive:
        for pin in sorted(pins, key=lambda p: p["identity"]):
            identity = pin["identity"]
            directory = directories.get(identity.lower())
            if directory is None:
                raise SystemExit("Missing resolved checkout: " + identity)
            revision = pin["state"]["revision"]
            paths = subprocess.check_output(["git", "-C", str(directory), "ls-tree", "-r", "--name-only", revision], text=True).splitlines()
            names = sorted(p for p in paths if pathlib.PurePosixPath(p).name.lower().startswith(("license", "copying", "notice")))
            if not names:
                raise SystemExit("Missing license text: " + identity)
            for name in names:
                body = subprocess.check_output(["git", "-C", str(directory), "show", revision + ":" + name])
                info = tarfile.TarInfo(identity + "/" + name)
                info.size = len(body); info.mode = 0o644; info.mtime = 0
                info.uid = info.gid = 0; info.uname = info.gname = ""
                archive.addfile(info, io.BytesIO(body))
                count += 1
print(f"Packaged {count} license texts from {len(pins)} resolved packages")
PY
