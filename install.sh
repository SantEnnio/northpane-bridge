#!/bin/sh
# Installs Northpane Bridge for the current user on Linux or macOS. No root, nothing outside $HOME.
#
#   curl -fsSL https://github.com/SantEnnio/northpane-bridge/releases/latest/download/install.sh | sh
#
# The Northpane app runs this same script over SSH with everything pinned by the app itself:
#
#   sh install.sh --version 1.0.0 --sha256 <hex> [--url https://...] [--file <path already on the Host>]
#
# Layout (shared with earlier Northpane installs):
#   ~/.local/share/northpane/bridge/versions/<version>/northpane-bridge
#   ~/.local/share/northpane/bridge/current, previous  (symlinks to versions/<version>)
#   ~/.local/bin/northpane-bridge                       (symlink through current)
#
# Machine-readable lines on stdout start with "northpane-install ". Exit codes:
#   2 usage, 20 no downloader, 21 download failed, 22 digest mismatch,
#   23 self-check failed, 24 unsupported platform, 25 no digest tool
set -eu

repository="SantEnnio/northpane-bridge"
version=""
expected=""
url=""
file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) version=${2:?}; shift 2 ;;
    --sha256) expected=${2:?}; shift 2 ;;
    --url) url=${2:?}; shift 2 ;;
    --file) file=${2:?}; shift 2 ;;
    *) echo "northpane-install: unknown argument $1" >&2; exit 2 ;;
  esac
done

say() { printf 'northpane-install %s\n' "$*"; }
fail() { code=$1; shift; echo "northpane-install: $*" >&2; exit "$code"; }

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64|Linux-amd64) platform=linux-x86_64 ;;
  Linux-aarch64|Linux-arm64) platform=linux-arm64 ;;
  Darwin-arm64|Darwin-x86_64) platform=macos-universal ;;
  *) fail 24 "unsupported platform $(uname -s) $(uname -m)" ;;
esac
say "platform=$platform"

case "$version" in
  ''|[A-Za-z0-9]*) ;;
  *) fail 2 "invalid version" ;;
esac
case "$version" in *[!A-Za-z0-9._-]*) fail 2 "invalid version" ;; esac
case "$expected" in
  '') ;;
  *[!0-9a-f]*) fail 2 "the digest must be 64 lowercase hex characters" ;;
  *) [ "${#expected}" -eq 64 ] || fail 2 "the digest must be 64 lowercase hex characters" ;;
esac
case "$url" in ''|https://*) ;; *) fail 2 "the download URL must use HTTPS" ;; esac

fetch() { # fetch <url> <destination>
  if command -v curl > /dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 --retry 2 -o "$2" "$1" || fail 21 "download failed: $1"
  elif command -v wget > /dev/null 2>&1; then
    wget -q -O "$2" "$1" || fail 21 "download failed: $1"
  else
    fail 20 "neither curl nor wget is available"
  fi
}

digest() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
  elif command -v shasum > /dev/null 2>&1; then shasum -a 256 "$1" | cut -d ' ' -f 1
  elif command -v openssl > /dev/null 2>&1; then openssl dgst -sha256 -r "$1" | cut -d ' ' -f 1
  else fail 25 "no SHA-256 tool (sha256sum, shasum or openssl) is available"
  fi
}

asset="northpane-bridge-$platform.gz"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -z "$version" ]; then
  # Manual install: the latest release, checked against that release's own digest list.
  [ -z "$file" ] || fail 2 "--file needs --version and --sha256"
  base="https://github.com/$repository/releases/latest/download"
  fetch "$base/SHA256SUMS" "$work/SHA256SUMS"
  fetch "$base/VERSION" "$work/VERSION"
  version=$(tr -d '[:space:]' < "$work/VERSION")
  case "$version" in ''|*[!A-Za-z0-9._-]*) fail 21 "the release names no valid version" ;; esac
  expected=$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1 }' "$work/SHA256SUMS")
  [ -n "$expected" ] || fail 24 "the latest release has no Bridge for $platform"
  url="https://github.com/$repository/releases/download/v$version/$asset"
fi
[ -n "$expected" ] || fail 2 "--version needs --sha256"
[ -n "$url" ] || url="https://github.com/$repository/releases/download/v$version/$asset"

if [ -n "$file" ]; then
  [ -f "$file" ] || fail 21 "no file at $file"
  mv "$file" "$work/$asset"
else
  fetch "$url" "$work/$asset"
fi
actual=$(digest "$work/$asset")
[ "$actual" = "$expected" ] || fail 22 "digest mismatch: expected $expected, got $actual"

root="$HOME/.local/share/northpane/bridge"
target="$root/versions/$version"
mkdir -p "$target" "$HOME/.local/bin"
gzip -dc "$work/$asset" > "$target/northpane-bridge.partial"
chmod 700 "$target/northpane-bridge.partial"
mv -f "$target/northpane-bridge.partial" "$target/northpane-bridge"
"$target/northpane-bridge" self-check --json > /dev/null 2>&1 || fail 23 "the downloaded Bridge failed its self-check"

previous=none
if [ -L "$root/current" ]; then
  previous=$(basename "$(readlink "$root/current")")
  if [ "$previous" != "$version" ]; then ln -sfn "$(readlink "$root/current")" "$root/previous"; fi
fi
ln -sfn "versions/$version" "$root/current"
ln -sfn "../share/northpane/bridge/current/northpane-bridge" "$HOME/.local/bin/northpane-bridge"
say "previous=$previous"
say "activated=$version"

# Keep the active version and the one before it, so the app can still roll back.
kept_previous=""
[ -L "$root/previous" ] && kept_previous=$(basename "$(readlink "$root/previous")")
for candidate in "$root"/versions/*; do
  [ -d "$candidate" ] || continue
  name=$(basename "$candidate")
  [ "$name" = "$version" ] || [ "$name" = "$kept_previous" ] || rm -rf -- "$candidate"
done

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Add ~/.local/bin to PATH to run northpane-bridge from a shell; the Northpane app finds it either way." >&2 ;;
esac
