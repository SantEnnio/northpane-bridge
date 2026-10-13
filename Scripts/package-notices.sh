#!/bin/sh
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_directory=${1:-"$repository_root/.release-artifacts"}
checkout="$repository_root/.build/checkouts"
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
mkdir -p "$output_directory"
# Keep public package-relative paths only, never build-machine directories.
# Include vendored crypto notices as well as each package's root license.
(cd "$checkout" && find . -type f \( -iname 'license*' -o -iname 'copying*' -o -iname 'notice*' \) | LC_ALL=C sort) > "$temporary_directory/files"
test -s "$temporary_directory/files"
tar -czf "$output_directory/third-party-licenses.tar.gz" -C "$checkout" -T "$temporary_directory/files"
