#!/bin/sh
set -eu

# SwiftTerm 1.15 unconditionally imports Glibc on Linux. Apply the narrowly
# scoped, reviewed compatibility patch before building against the Musl SDK.
# Keep the exact dependency pin and refuse unknown or locally modified sources.
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift package --package-path "$repository_root" resolve
dependency="$repository_root/.build/checkouts/SwiftTerm"
revision=$(git -C "$dependency" rev-parse HEAD)
if [ "$revision" != dd2fb8ac5b861e7bf617c872895e338f38165648 ]; then
  echo "Unsupported SwiftTerm revision for the musl compatibility patch: $revision" >&2
  exit 1
fi
source_digest() {
  if command -v sha256sum > /dev/null; then
    sha256sum "$dependency/$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$dependency/$1" | cut -d ' ' -f 1
  fi
}
prepare_source() {
  digest=$(source_digest "$1")
  case "$digest" in
    "$3")
      git -C "$dependency" apply --check --unidiff-zero "$repository_root/Patches/$2"
      git -C "$dependency" apply --unidiff-zero "$repository_root/Patches/$2"
      ;;
    "$4") ;; # The second architecture uses the same checkout.
    *) echo "SwiftTerm source differs from the reviewed musl patch inputs: $1" >&2; exit 1 ;;
  esac
  if [ "$(source_digest "$1")" != "$4" ]; then
    echo "SwiftTerm musl patch output differs from the reviewed source: $1" >&2
    exit 1
  fi
}
prepare_source Sources/SwiftTerm/KittyGraphics.swift swiftterm-1.15-musl.patch \
  c178c22090b5a3d7ca6e2c9a0cd302d3c205aab1ac3cc30ba5044568a41b2e5f \
  e12a3575a114e909bc728e0646e9807323f1c9359782925a589705a4345e04de
# Use only the portable engine. Northpane owns its PTY and process lifecycle;
# SwiftTerm's unused Unix wrappers assume Glibc's Swift ioctl overlays.
prepare_source Package.swift swiftterm-1.15-core-unix.patch \
  a1dfb1317409a108ad5c9d8db83e5d058bdbbd700ecbf8892f27a498ac200575 \
  db5c0bd6dee0f49089747c68343d7ba9b7c22f6cb65e9782a907c85afadd020f
