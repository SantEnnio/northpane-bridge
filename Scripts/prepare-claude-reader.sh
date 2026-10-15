#!/bin/sh
set -eu
# Build-machine dependencies only: Bun 1.3.10, npm, Python 3. Hosts need none.
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
platform=${1:?usage: prepare-claude-reader.sh <macos-arm64|macos-x86_64|linux-arm64|linux-x86_64>}
case "$platform" in
  macos-arm64) target=bun-darwin-arm64 ;;
  macos-x86_64) target=bun-darwin-x64 ;;
  linux-arm64) target=bun-linux-arm64-musl ;;
  linux-x86_64) target=bun-linux-x64-musl-baseline ;;
  *) echo "Unsupported reader platform: $platform" >&2; exit 2 ;;
esac
[ "$(bun --version)" = "1.3.10" ] || { echo "Building the reader requires Bun 1.3.10" >&2; exit 2; }
source_directory="$repository_root/Integrations/claude-reader"
sign_identity=${NORTHPANE_READER_SIGN_IDENTITY:--}
platform_directory="$repository_root/.build/claude-reader/$platform"
fingerprint=$(python3 - "$source_directory" "$0" "$sign_identity" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256(b'bun-1.3.10')
digest.update(sys.argv[3].encode())
for path in [root / 'package.json', root / 'package-lock.json', root / 'reader.ts', root / 'reader.entitlements', root / 'linux-libraries.json', pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[2]).with_name('prepare-reader-libraries.py')]:
    digest.update(path.read_bytes())
print(digest.hexdigest())
PY
)
output_directory="$platform_directory/$fingerprint"
mkdir -p "$output_directory"
output="$output_directory/northpane-claude-reader"
if [ ! -f "$output_directory/inputs" ] || [ "$(cat "$output_directory/inputs")" != "$fingerprint" ] || [ ! -x "$output" ]; then
  npm ci --prefix "$source_directory" --omit=optional --ignore-scripts --no-audit --no-fund >&2
  bun build "$source_directory/reader.ts" --compile --target="$target" --minify \
    --no-compile-autoload-dotenv --no-compile-autoload-bunfig \
    --no-compile-autoload-tsconfig --no-compile-autoload-package-json \
    --outfile "$output.partial" >&2
  case "$platform" in
    macos-*)
      if [ "$sign_identity" = "-" ]; then
        codesign --force --sign - --identifier northpane-claude-reader "$output.partial" >&2
      else
        codesign --force --sign "$sign_identity" --identifier northpane-claude-reader \
          --options runtime --timestamp --entitlements "$source_directory/reader.entitlements" "$output.partial" >&2
      fi
      ;;
    linux-*)
      bun build "$source_directory/reader.ts" --target=bun --minify --outfile "$output_directory/reader.mjs" >&2
      case "$platform" in linux-x86_64) library_arch=x86_64 ;; linux-arm64) library_arch=aarch64 ;; esac
      python3 "$repository_root/Scripts/prepare-reader-libraries.py" "$library_arch" "$output_directory" >&2
      ;;
  esac
  mv -f "$output.partial" "$output"
  printf '%s\n' "$fingerprint" > "$output_directory/inputs"
fi
printf '%s\n' "$output"
