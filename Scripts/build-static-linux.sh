#!/bin/sh
set -eu

# Builds the Linux Bridge as one fully static executable with the Swift Static Linux SDK (musl),
# so it starts on any Linux distribution without a Swift runtime or a particular glibc.
#
#   Scripts/build-static-linux.sh <x86_64|aarch64> [output-directory]
#
# Needs a swift.org toolchain (not Xcode's) with the matching Static Linux SDK installed:
#   swift sdk install <static-linux artifactbundle URL> --checksum <sha256>
# Output: northpane-bridge-linux-<x86_64|arm64>.gz and its .sha256 in the output directory.
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
architecture=${1:?usage: build-static-linux.sh <x86_64|aarch64> [output-directory]}
output_directory=${2:-"$repository_root/.release-artifacts"}

case "$architecture" in
  x86_64) platform=linux-x86_64 ;;
  aarch64) platform=linux-arm64 ;;
  *) echo "unsupported architecture: $architecture" >&2; exit 2 ;;
esac
sdk="$architecture-swift-linux-musl"

swift build --package-path "$repository_root" -c release --swift-sdk "$sdk" --product northpane-bridge
binary="$(swift build --package-path "$repository_root" -c release --swift-sdk "$sdk" --show-bin-path)/northpane-bridge"

# The toolchain's llvm-objcopy strips either architecture, whatever the build machine is.
toolchain_bin=$(dirname -- "$(command -v swift)")
objcopy="$toolchain_bin/llvm-objcopy"
[ -x "$objcopy" ] || objcopy=$(command -v llvm-objcopy)

mkdir -p "$output_directory"
stripped="$output_directory/northpane-bridge-$platform"
"$objcopy" --strip-all "$binary" "$stripped"
chmod 755 "$stripped"

# A binary for this machine's architecture must start with nothing around it.
if [ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" = "$architecture" ]; then
  env -i "$stripped" self-check --json > /dev/null
fi

gzip -9 -n -f "$stripped"
if command -v sha256sum > /dev/null; then
  (cd "$output_directory" && sha256sum "northpane-bridge-$platform.gz" > "northpane-bridge-$platform.gz.sha256")
else
  (cd "$output_directory" && shasum -a 256 "northpane-bridge-$platform.gz" > "northpane-bridge-$platform.gz.sha256")
fi
echo "$output_directory/northpane-bridge-$platform.gz"
