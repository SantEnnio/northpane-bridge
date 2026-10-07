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
      git -C "$dependency" apply --check "$repository_root/Patches/$2"
      git -C "$dependency" apply "$repository_root/Patches/$2"
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
# Unlike Glibc, Musl declares ioctl's request as int, not unsigned long.
prepare_source Sources/SwiftTerm/Pty.swift swiftterm-1.15-musl-pty.patch \
  1d0d58b08576187897fb99b1d93426f6da949e2f4821ff0b436be47882250e6f \
  453a70f57b03e7fc8ee7ec8c9376cdaaa0e38e3dc704dddf7e5da70c801871ef
