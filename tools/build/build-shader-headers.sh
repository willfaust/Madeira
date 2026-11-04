#!/usr/bin/env bash
# Compile DXMT's .metal airconv shaders to .air and embed them as C headers.
# The DXMT meson flow does this via its metalir/hexdump generators; the iOS
# static-library flow consumes the headers directly, so this step reproduces
# that generation with the same compiler, flags, and xxd embedding.
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$ROOT/dxmt/src/airconv/shaders"
OUT="$ROOT/build/dxmt-ios/shader-headers"
SHADERS=(air_msad air_samplepos air_tessellation)

# Metal toolchain 32023 (Xcode 27) gave __metal_atomic_fetch_add_explicit a fifth
# memory-flags argument. Xcode 26.x's toolchain already defines
# __METAL_MEMORY_FLAGS_NONE__ but its builtin still takes four, so the macro
# cannot choose the form: MADEIRA_METAL_ATOMIC_FLAGS does, and the compile below
# tries the five-argument form first and falls back to four.
python3 - "$SRC/air_tessellation.metal" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
old = "  return __metal_atomic_fetch_add_explicit(out_count, 1, int(memory_order_relaxed), __METAL_MEMORY_SCOPE_THREADGROUP__);\n"
five = old.replace("__);", "__, __METAL_MEMORY_FLAGS_NONE__);")
earlier = "#ifdef __METAL_MEMORY_FLAGS_NONE__\n" + five + "#else\n" + old + "#endif\n"
if "MADEIRA_METAL_ATOMIC_FLAGS" not in s:
    if earlier in s:      # a checkout patched by the earlier version of this script
        s = s.replace(earlier, old, 1)
    if old not in s:
        raise SystemExit(f"expected atomic call not found in {p}")
    new = "#if MADEIRA_METAL_ATOMIC_FLAGS\n" + five + "#else\n" + old + "#endif\n"
    p.write_text(s.replace(old, new, 1))
PY

for name in "${SHADERS[@]}"; do
  [[ -f "$SRC/$name.metal" ]] || { echo "ERROR: missing shader source $SRC/$name.metal (is the dxmt submodule checked out?)" >&2; exit 1; }
  echo "shader $name: compiling"
  mkdir -p "$OUT"
  if ! xcrun -sdk macosx metal -o "$OUT/$name.air" -c "$SRC/$name.metal" \
      -std=metal3.1 --target=air64-apple-macos14.0 -DMADEIRA_METAL_ATOMIC_FLAGS=1 2>"$OUT/$name.err"; then
    if [[ "$name" == air_tessellation ]] && grep -q "too many arguments" "$OUT/$name.err"; then
      echo "shader $name: this Metal toolchain's atomic builtin takes four arguments"
      xcrun -sdk macosx metal -o "$OUT/$name.air" -c "$SRC/$name.metal" \
        -std=metal3.1 --target=air64-apple-macos14.0 -DMADEIRA_METAL_ATOMIC_FLAGS=0
    else
      cat "$OUT/$name.err" >&2; exit 1
    fi
  fi
  rm -f "$OUT/$name.err"
  xxd -n "$name" -i "$OUT/$name.air" "$OUT/$name.h"
done
