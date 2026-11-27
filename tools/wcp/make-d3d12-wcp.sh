#!/usr/bin/env bash
# Package Madeira's D3D12 PE DLLs and Metal Shader Converter IR native dylib as
# independently selectable .wcp components:
#
#   tools/wcp/make-d3d12-wcp.sh [version-name]
#   -> dist/<version-name>-pe.wcp      (d3d12.dll + d3d12core.dll)
#   -> dist/<version-name>-dxil-native.wcp  (libmadeira_ir_unix.dylib, signed)
#
# Keeping D3D12 PE and DXIL native converter as dedicated selectable packages lets
# users toggle or update the D3D12/DXIL graphics stack inside Madeira without
# coupling it to game-specific Wine/FEX/UnixHalf packages or rebuilding the app.
set -euo pipefail

VERSION="${1:-Madeira-D3D12-v1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PE_DIR="$ROOT/build/madeira-d3d12/out-pe"
IR_DYLIB="$ROOT/build/dxmt-ios/libmadeira_ir_unix.dylib"
OUT="$ROOT/dist"

for req in "$PE_DIR/d3d12.dll" "$PE_DIR/d3d12core.dll" "$IR_DYLIB"; do
    [ -f "$req" ] || { echo "missing required build artifact: $req" >&2; exit 1; }
done
command -v zstd >/dev/null || { echo "zstd is required (brew install zstd)" >&2; exit 1; }

IDENTITY="${MADEIRA_SIGN_IDENTITY:-Apple Development: austinturner859@gmail.com (46R7UQ723P)}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    echo "signing identity not found: $IDENTITY (set MADEIRA_SIGN_IDENTITY to override)" >&2
    exit 1
fi

mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. D3D12 PE package (arm64ec-windows/d3d12.dll + d3d12core.dll)
PE_WORK="$WORK/pe"
mkdir -p "$PE_WORK/files/lib/wine/arm64ec-windows"
cp "$PE_DIR/d3d12.dll" "$PE_WORK/files/lib/wine/arm64ec-windows/d3d12.dll"
cp "$PE_DIR/d3d12core.dll" "$PE_WORK/files/lib/wine/arm64ec-windows/d3d12core.dll"
cat > "$PE_WORK/profile.json" <<EOF
{
  "type": "Wine",
  "versionName": "$VERSION",
  "versionCode": 1,
  "description": "Madeira D3D12 PE override (d3d12.dll + d3d12core.dll: dual-source blend fallback, tiled resources, tex-drop-mip, fence-chain 6, async PSO archive).",
  "files": [
    {
      "source": "files/lib/wine/arm64ec-windows/d3d12.dll",
      "target": "\${sysarm64ec}/d3d12.dll"
    },
    {
      "source": "files/lib/wine/arm64ec-windows/d3d12core.dll",
      "target": "\${sysarm64ec}/d3d12core.dll"
    }
  ]
}
EOF
PE_DEST="$OUT/$VERSION-pe.wcp"
( cd "$PE_WORK" && COPYFILE_DISABLE=1 tar --disable-copyfile -cf - profile.json files ) | zstd -q -f -19 -o "$PE_DEST"
printf '%s  (%s)\n' "$PE_DEST" "$(du -h "$PE_DEST" | cut -f1)"

# 2. DXIL / Metal IR converter native Mach-O package (libmadeira_ir_unix.dylib)
IR_WORK="$WORK/ir"
mkdir -p "$IR_WORK/files"
cp "$IR_DYLIB" "$IR_WORK/files/libmadeira_ir_unix.dylib"
codesign --force --sign "$IDENTITY" --timestamp=none "$IR_WORK/files/libmadeira_ir_unix.dylib"
TEAM="$(codesign -dvvv "$IR_WORK/files/libmadeira_ir_unix.dylib" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ -n "$TEAM" ] || { echo "signed libmadeira_ir_unix.dylib has no TeamIdentifier" >&2; exit 1; }
cat > "$IR_WORK/profile.json" <<EOF
{
  "type": "UnixHalf",
  "versionName": "${VERSION}-dxil",
  "versionCode": 1,
  "description": "Madeira DXIL/Metal IR converter native override (libmadeira_ir_unix.dylib: dual-source blending, SM5.1 register spaces, GS void-VS, signed $TEAM).",
  "files": [
    {
      "source": "files/libmadeira_ir_unix.dylib",
      "target": "files/libmadeira_ir_unix.dylib"
    }
  ]
}
EOF
IR_DEST="$OUT/${VERSION}-dxil-native.wcp"
( cd "$IR_WORK" && COPYFILE_DISABLE=1 tar --disable-copyfile -cf - profile.json files ) | zstd -q -f -19 -o "$IR_DEST"
printf '%s  (%s)  team=%s\n' "$IR_DEST" "$(du -h "$IR_DEST" | cut -f1)" "$TEAM"
