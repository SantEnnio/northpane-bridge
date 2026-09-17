#!/bin/sh
set -eu

# Builds the macOS Bridge as one universal (arm64 + x86_64) executable, stripped and gzipped.
# The linker signs it ad hoc, which is all a binary fetched with curl needs to run; the Mac app
# keeps sending its own Developer ID signed copy, which screen capture permissions depend on.
#
#   Scripts/package-macos.sh [output-directory]
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_directory=${1:-"$repository_root/.release-artifacts"}

swift build --package-path "$repository_root" -c release --arch arm64 --arch x86_64 --product northpane-bridge
binary="$(swift build --package-path "$repository_root" -c release --arch arm64 --arch x86_64 --show-bin-path)/northpane-bridge"
mkdir -p "$output_directory"
packaged="$output_directory/northpane-bridge-macos-universal"
strip -x -o "$packaged" "$binary"
codesign --force --sign - "$packaged"
chmod 755 "$packaged"
lipo -verify_arch arm64 x86_64 "$packaged"
env -i "$packaged" self-check --json > /dev/null
gzip -9 -n -f "$packaged"
(cd "$output_directory" && shasum -a 256 "northpane-bridge-macos-universal.gz" > "northpane-bridge-macos-universal.gz.sha256")
echo "$packaged.gz"
