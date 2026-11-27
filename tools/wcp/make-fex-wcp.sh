#!/usr/bin/env bash
# Package a FEX ARM64EC module as a .wcp Madeira can import.
#
#   tools/wcp/make-fex-wcp.sh <version-name> <libarm64ecfex.dll> [description]
#   -> dist/<version-name>-fex.wcp
#
# The module must be built for iOS: run build/fex-arm64ec/build.sh first, which
# leaves it at app/Madeira/arm64ec-windows/xtajit64.dll. Madeira's importer
# maps libarm64ecfex.dll to that name.
set -euo pipefail

VERSION="${1:?usage: make-fex-wcp.sh <version-name> <libarm64ecfex.dll> [description]}"
DLL="${2:?missing libarm64ecfex.dll}"
DESC="${3:-FEX built from the Madeira FEX fork (branch ios-port-2607).}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "$DLL" ] || { echo "missing $DLL" >&2; exit 1; }
command -v zstd >/dev/null || { echo "zstd is required (brew install zstd)" >&2; exit 1; }

OUT="$ROOT/dist"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/files/lib/wine/aarch64-windows"
cp "$DLL" "$WORK/files/lib/wine/aarch64-windows/libarm64ecfex.dll"

cat > "$WORK/profile.json" <<EOF
{
  "type": "FEXCore",
  "versionName": "$VERSION",
  "versionCode": 1,
  "description": "$DESC",
  "files": [
    {
      "source": "files/lib/wine/aarch64-windows/libarm64ecfex.dll",
      "target": "\${system32}/xtajit64.dll"
    }
  ]
}
EOF

DEST="$OUT/$VERSION-fex.wcp"
( cd "$WORK" && COPYFILE_DISABLE=1 tar --disable-copyfile -cf - profile.json files ) | zstd -q -f -19 -o "$DEST"

echo "dll  $(shasum -a 256 "$DLL" | cut -c1-64)"
echo "wcp  $DEST ($(stat -f%z "$DEST") bytes)"
