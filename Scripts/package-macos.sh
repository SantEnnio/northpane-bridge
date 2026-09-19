#!/bin/sh
set -eu

# Builds the macOS Bridge as one universal (arm64 + x86_64) executable, stripped and gzipped.
# It is signed ad hoc, which is all a binary fetched with curl needs to run. Nothing a Host keeps
# depends on the signature: its identity is in a file, and screen recording is granted to the
# frozen helper bundle the Bridge installs once, not to the Bridge.
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
# The identifier is set here, not derived from the file's name, so every release signs as the
# same "northpane-bridge" whatever the package is called.
codesign --force --sign - --identifier northpane-bridge "$packaged"
chmod 755 "$packaged"
lipo -info "$packaged"
lipo "$packaged" -verify_arch arm64 x86_64
env -i "$packaged" self-check --json
gzip -9 -n -f "$packaged"
(cd "$output_directory" && shasum -a 256 "northpane-bridge-macos-universal.gz" > "northpane-bridge-macos-universal.gz.sha256")
echo "$packaged.gz"
