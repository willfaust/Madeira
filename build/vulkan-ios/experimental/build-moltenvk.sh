#!/bin/bash
# GPL-3.0-or-later WITH the Madeira Converter Exception, version 1.
# Explicit ten-patch experiment. No normal build calls this script.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="${MADEIRA_MOLTENVK_SOURCE:-$ROOT/toolchains/moltenvk-detroit-source}"
PLATFORM="${1:-ios}"
case "$PLATFORM" in
    prepare) LABEL=''; DEST='' ;;
    ios) LABEL='iOS'; DEST='generic/platform=iOS' ;;
    macos) LABEL='macOS'; DEST='generic/platform=macOS' ;;
    *) echo "usage: $0 [prepare|ios|macos]" >&2; exit 1 ;;
esac
python3 "$HERE/prepare-sources.py" moltenvk --directory "$SRC"
[ "$PLATFORM" != prepare ] || exit 0
cd "$SRC"
./fetchDependencies --"$PLATFORM" --keep-cache
# Clean the parent archive, which can otherwise retain a stale prelinked child.
xcodebuild clean build -project MoltenVKPackaging.xcodeproj \
    -scheme "MoltenVK Package ($LABEL only)" -configuration Release \
    -destination "$DEST" -jobs 2 CODE_SIGNING_ALLOWED=NO
if [ "$PLATFORM" = ios ]; then
    LIB="$SRC/Package/Release/MoltenVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a"
    OUT="$ROOT/toolchains/moltenvk-detroit-experimental/ios-arm64"
    test -f "$LIB"
    mkdir -p "$OUT"
    cp "$LIB" "$OUT/libMoltenVK.a"
    cp "$HERE/manifest.json" "$OUT/source-manifest.json"
    shasum -a 256 "$OUT/libMoltenVK.a" "$HERE/manifest.json" "$HERE"/patches/*.patch > "$OUT/SHA256SUMS"
    echo "Rebuild the static backend with MADEIRA_MOLTENVK_LIBRARY=$OUT/libMoltenVK.a"
fi
