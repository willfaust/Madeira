#!/usr/bin/env bash
# MADEIRA ml990: build and run the fastsync cell-protocol host model.
#
# It compiles against the REAL build/ntdll-unix/shims/ios_fastsync.h, so the
# packing, the accessors and the sign handling under test are the shipping
# ones. Exit 0 means the ml990 packed {gen,state} word stole no token from a
# recycled cell; the ml982 shape is run alongside it as the contrast.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIMS="$HERE/../ntdll-unix/shims"
OUT="${1:-$HERE/fastsync-cellrace}"
${CC:-cc} -O2 -g -Wall -I"$SHIMS" -o "$OUT" "$HERE/fastsync-cellrace.c" -lpthread
"$OUT"
echo "CELLRACE EXIT STATUS: $? (0 = passed)"
