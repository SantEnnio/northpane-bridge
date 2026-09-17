#!/bin/sh
set -eu

# Builds the macOS Bridge as one universal (arm64 + x86_64) executable, stripped and gzipped.
# The linker signs it ad hoc, which is all a binary fetched with curl needs to run; the Mac app
# keeps sending its own Developer ID signed copy, which screen capture permissions depend on.
#
#   Scripts/package-macos.sh [output-directory]
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_directory=${1:-"$repository_root/.release-artifacts"}

set -x
# One build per architecture, joined with lipo: a single multi-architecture build goes through the
# Xcode build system, which rejects one of the package's dependencies.
for arch in arm64 x86_64; do
  swift build --package-path "$repository_root" --scratch-path "$repository_root/.build/$arch" -c release --arch "$arch" --product northpane-bridge
done
binary="$repository_root/.build/universal/northpane-bridge"
mkdir -p "$(dirname "$binary")"
lipo -create \
  "$(swift build --package-path "$repository_root" --scratch-path "$repository_root/.build/arm64" -c release --arch arm64 --show-bin-path)/northpane-bridge" \
  "$(swift build --package-path "$repository_root" --scratch-path "$repository_root/.build/x86_64" -c release --arch x86_64 --show-bin-path)/northpane-bridge" \
  -output "$binary"
mkdir -p "$output_directory"
packaged="$output_directory/northpane-bridge-macos-universal"
strip -x -o "$packaged" "$binary"
codesign --force --sign - "$packaged"
chmod 755 "$packaged"
lipo -info "$packaged"
lipo "$packaged" -verify_arch arm64 x86_64
env -i "$packaged" self-check --json
gzip -9 -n -f "$packaged"
(cd "$output_directory" && shasum -a 256 "northpane-bridge-macos-universal.gz" > "northpane-bridge-macos-universal.gz.sha256")
echo "$packaged.gz"
