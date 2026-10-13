#!/bin/sh
set -eu

# The reviewed SwiftTerm revision supports Musl directly. Refuse drift instead
# of applying the historical 1.15 checkout patches to a different terminal core.
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift package --package-path "$repository_root" resolve
dependency="$repository_root/.build/checkouts/SwiftTerm"
revision=$(git -C "$dependency" rev-parse HEAD)
if [ "$revision" != fe4fb45d5888ce33ff3788d6873870a73894a41b ]; then
  echo "Unsupported SwiftTerm revision for the static Linux build: $revision" >&2
  exit 1
fi
if [ -n "$(git -C "$dependency" status --porcelain --untracked-files=no)" ]; then
  echo "SwiftTerm differs from the reviewed upstream source" >&2
  exit 1
fi
