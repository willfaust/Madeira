#!/bin/bash
# Host check: BC footprints are whole 4x4 blocks and a copy is cut to its level (bc-footprint).
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/../../src/pe/madeira_d3d12.c"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
awk '/^static void mad_format_info\(DXGI_FORMAT f, UINT \*bytes, UINT \*block\) \{/{p=1} p&&/^static D3D12_RESOURCE_ALLOCATION_INFO/{exit} p{print}' "$SRC" > "$OUT/extract.c"
cp "$DIR/bc_footprint_test.c" "$OUT/t.c"
${CC:-cc} -std=c11 -Wall -Wno-unused-function -I"$OUT" -o "$OUT/t" "$OUT/t.c"
"$OUT/t"
