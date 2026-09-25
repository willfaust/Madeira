#!/usr/bin/env bash
# Compile DXMT's .metal airconv shaders to .air and embed them as C headers.
# The DXMT meson flow does this via its metalir/hexdump generators; the iOS
# static-library flow consumes the headers directly, so this step reproduces
# that generation with the same compiler, flags, and xxd embedding.
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$ROOT/research/dxmt/src/airconv/shaders"
OUT="$ROOT/build/dxmt-ios/shader-headers"
SHADERS=(air_msad air_samplepos air_tessellation)

for name in "${SHADERS[@]}"; do
  if [[ -f "$OUT/$name.h" && -f "$OUT/$name.air" ]]; then
    echo "shader $name: cached"
    continue
  fi
  [[ -f "$SRC/$name.metal" ]] || { echo "ERROR: missing shader source $SRC/$name.metal (is the dxmt submodule checked out?)" >&2; exit 1; }
  echo "shader $name: compiling"
  mkdir -p "$OUT"
  xcrun -sdk macosx metal -o "$OUT/$name.air" -c "$SRC/$name.metal" \
    -std=metal3.1 --target=air64-apple-macos14.0
  xxd -n "$name" -i "$OUT/$name.air" "$OUT/$name.h"
done
