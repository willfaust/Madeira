#!/bin/bash
# Build madeira_d3d12.dll as ARM64EC, plus the x64 test executable.
#
# A SEPARATE DLL, not a replacement for the bundled d3d12.dll: the design says
# not to overwrite the shipped loader as the first experiment, and keeping it
# separate means the D3D11 path cannot regress while this is unfinished.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
MINGW="$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
SRC="$REPO_ROOT/madeira-d3d12/src/pe"
TESTS="$REPO_ROOT/madeira-d3d12/tests/windows"
OUT="${OUT:-$REPO_ROOT/build/madeira-d3d12/out-pe}"
mkdir -p "$OUT"

# Regenerate the stub tables so a toolchain header update cannot silently leave
# the vtables the wrong length.
python3 "$SRC/gen_vtables.py" \
    "$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/generic-w64-mingw32/include/d3d12.h" \
    "$SRC/madeira_d3d12_stubs.h" >/dev/null

echo "=== madeira_d3d12.dll (arm64ec) ==="
"$MINGW/arm64ec-w64-mingw32-clang" -shared -O2 -Wall \
    -o "$OUT/madeira_d3d12.dll" "$SRC/madeira_d3d12.c" "$SRC/d3d12.def" \
    -I"$SRC" -I"$REPO_ROOT/madeira-d3d12/src" -I"$REPO_ROOT/dxmt/src/winemetal" \
    -L"$REPO_ROOT/dxmt/build-arm64ec/src/winemetal" -lwinemetal \
    -luuid -lole32
echo "  built $(ls -l "$OUT/madeira_d3d12.dll" | awk '{print $5}') bytes"
# The same binary also ships as d3d12.dll (ml849): the engine reaches it through
# the standard entry points, while the tests keep loading it by the old name.
cp "$OUT/madeira_d3d12.dll" "$OUT/d3d12.dll"
echo "  exports: $("$MINGW/llvm-objdump" --private-headers "$OUT/d3d12.dll" 2>/dev/null | grep -cE '^ +[0-9]+ +0x[0-9a-f]+ +D3D12|^ +[0-9]+ .*D3D12')  (ordinal 101/102 pinned by d3d12.def)"

# The Agility SDK half: D3D12SDKVersion plus forwarders to d3d12.dll. It ships
# next to d3d12.dll; nothing loads it unless madeira.cfg d3d12-core-dll is set.
echo "=== d3d12core.dll (arm64ec) ==="
"$MINGW/arm64ec-w64-mingw32-clang" -shared -O2 -Wall \
    -o "$OUT/d3d12core.dll" "$SRC/d3d12core.c" "$SRC/d3d12core.def"
echo "  built $(ls -l "$OUT/d3d12core.dll" | awk '{print $5}') bytes, $("$MINGW/llvm-readobj" --coff-exports "$OUT/d3d12core.dll" | grep -c 'ForwardedTo: d3d12\.') forwarders to d3d12.dll"

echo "=== d3d12-m2-x64.exe (x86_64 guest) ==="
"$MINGW/x86_64-w64-mingw32-clang" -O2 -Wall \
    -o "$OUT/d3d12-m2-x64.exe" "$TESTS/m2_abi.c" -luuid -lole32
echo "  built $(ls -l "$OUT/d3d12-m2-x64.exe" | awk '{print $5}') bytes"

echo "=== d3d12-vfetch-x64.exe (x86_64 guest, vertex-path differential test, ml906) ==="
"$MINGW/x86_64-w64-mingw32-clang" -O2 -Wall \
    -o "$OUT/d3d12-vfetch-x64.exe" "$TESTS/vfetch_test.c" -I"$TESTS" -luuid -lole32
echo "  built $(ls -l "$OUT/d3d12-vfetch-x64.exe" | awk '{print $5}') bytes"

echo "=== d3d12-cube-x64.exe (x86_64 guest, visible) ==="
"$MINGW/x86_64-w64-mingw32-clang" -O2 -Wall -mwindows \
    -o "$OUT/d3d12-cube-x64.exe" "$TESTS/cube_window.c" -I"$TESTS" -luuid -lole32
echo "  built $(ls -l "$OUT/d3d12-cube-x64.exe" | awk '{print $5}') bytes"
