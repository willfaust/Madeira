#!/bin/bash
# list-journal host test (x86-64 Linux): the same random D3D12 command-list call
# sequences go once straight to logging mocks and once through the x64 journal
# in madeira_d3d12.dll and its replay; the two call logs must be identical.
# Usage: run.sh <madeira_d3d12.dll built by build/madeira-d3d12/build-pe.sh> <llvm-mingw bin dir>
set -eu
DLL=$1 MINGW=$2
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/../../src/pe"
OUT="$(mktemp -d)"
"$MINGW/x86_64-w64-mingw32-clang" -O1 -shared -nostdlib -ffreestanding -fno-builtin \
    -Wl,--image-base=0x10000000 -Wl,--entry= -I"$SRC" "$DIR/jrtest_mock.c" -o "$OUT/jrtest_mock.dll"
cc -O1 -o "$OUT/jrtest" "$DIR/jrtest.c"
"$MINGW/llvm-nm" "$DLL" > "$OUT/d3d12.nm"
"$MINGW/llvm-nm" "$OUT/jrtest_mock.dll" > "$OUT/jrtest_mock.nm"
"$OUT/jrtest" "$DLL" "$OUT/d3d12.nm" "$OUT/jrtest_mock.dll" "$OUT/jrtest_mock.nm"
