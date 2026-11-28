#!/bin/bash
# libxess.dll, the builtin that answers XeSS 2.x with MetalFX temporal upscaling
# through madeira_d3d12 (madeira-d3d12/src/libxess/libxess.c). ARM64EC, marked as a
# Wine builtin as winebuild --builtin does. Install it as arm64ec-windows/libxess.dll;
# wine loads it from system32 instead of the game's own copy with
# env.MADEIRA_XESS_METALFX = 1.
# Usage: build-libxess.sh [out-dir]   (LLVM_MINGW = llvm-mingw root; default as build-pe.sh)
set -eu
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MINGW="${LLVM_MINGW:-$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal}/bin"
OUT="${1:-$REPO_ROOT/build/madeira-d3d12/out}"
mkdir -p "$OUT"
"$MINGW/arm64ec-w64-mingw32-clang" -shared -O2 -o "$OUT/libxess.dll" "$REPO_ROOT/madeira-d3d12/src/libxess/libxess.c"
python3 "$REPO_ROOT/build/dxc-arm64ec/mark-builtin.py" "$OUT/libxess.dll"
