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
    "$OUT/madeira_d3d12_stubs.h" >/dev/null
cmp -s "$OUT/madeira_d3d12_stubs.h" "$SRC/madeira_d3d12_stubs.h" || {
    echo "D3D12 stubs differ from the pinned headers; regenerate and review the source header" >&2
    exit 1
}

# Build-time inputs of madeira_d3d12.c, all optional: without them the runtime
# falls back as noted below.
EXTRA=()

# The PE-side shader cache's converter identity (madeira_d3d12.c,
# MAD_SC_CONVERTER_ID): a hash of everything that shapes a conversion -- the
# conversion service and the IR ABI, build/dxmt-ios/build.sh, DXMT's DXBC
# compiler and parser, LLVM's configuration, and the converter's headers and
# iOS library (the inputs build/dxmt-ios/build.sh hashes for the unix side). A
# build that changes none of them keeps the device's shader cache instead of
# converting every shader again; without it every build gets a cache of its own.
scid_inputs() {
    local f x
    for f in madeira-d3d12/src/unix madeira-d3d12/src/madeira_ir_abi.h \
             build/dxmt-ios/build.sh dxmt/src/airconv dxmt/libs \
             toolchains/llvm-ios-build/include/llvm/Config/llvm-config.h \
             madeira-d3d12/third_party/metal-shader-converter/include \
             app/Madeira/d3d12/libmetalirconverter.dylib; do
        [ -e "$REPO_ROOT/$f" ] || { echo "absent $f"; continue; }
        find "$REPO_ROOT/$f" -type f | LC_ALL=C sort | while read -r x; do
            echo "$(shasum -a 256 < "$x" | cut -c1-64) ${x#"$REPO_ROOT"/}"
        done
    done
}
SCID=$(scid_inputs | shasum -a 256 | cut -c1-16)
echo "=== shader cache converter identity $SCID ==="
EXTRA+=(-DMAD_SC_CONVERTER_ID="\"$SCID\"")

# MAD_BUILD_ID names the build in the device log ("madeira-d3d12 M2 <id>, <date>").
if [ -n "${MAD_BUILD_ID:-}" ]; then EXTRA+=(-DMAD_BUILD_ID="\"$MAD_BUILD_ID\""); fi

# The helper kernels (mad_kernels.metal) as an embedded metallib: the
# indirect-argument probe, clear-rects and the typed-view-align texture probe
# run on them. Without xcrun, or when the compile fails, they are left out and
# the runtime skips what needs them. The file is compiled again without the
# texture-buffer probe and/or the clear functions when those do not compile,
# so the other kernels never depend on them.
echo "=== helper kernels (metallib) ==="
MAD_KERNELS_FLAGS=""   # the -D flags of the compile that succeeded (the iOS 18 copy below uses them too)
mad_kernels_metal() {
    xcrun -sdk iphoneos metal -std=metal3.0 "$@" -o "$OUT/mad_kernels.metallib" "$SRC/mad_kernels.metal" 2> "$OUT/mad_kernels.err" &&
        MAD_KERNELS_FLAGS="$*"
}
if command -v xcrun > /dev/null 2>&1 &&
   { mad_kernels_metal ||
     mad_kernels_metal -DMAD_NO_NAN_CLEAN ||
     mad_kernels_metal -DMAD_NO_TEXBUF_PROBE ||
     mad_kernels_metal -DMAD_NO_CLEAR_RECTS ||
     mad_kernels_metal -DMAD_NO_TEXBUF_PROBE -DMAD_NO_CLEAR_RECTS ||
     mad_kernels_metal -DMAD_NO_TEXBUF_PROBE -DMAD_NO_CLEAR_RECTS -DMAD_NO_NAN_CLEAN; }; then
    (cd "$OUT" && xxd -i mad_kernels.metallib > mad_kernels_metallib.h)
    EXTRA+=(-DMAD_HAVE_KERNELS -I"$OUT")
    echo "  $(wc -c < "$OUT/mad_kernels.metallib" | tr -d ' ') bytes"
    # The same kernels for iOS 18 (AIR 2.7): the library above takes the SDK's
    # default target (AIR 2.8 with the iOS 26 SDK), which iOS 18 refuses. The
    # runtime loads this copy only when the first is refused (madeira_d3d12.c).
    if xcrun -sdk iphoneos metal -std=metal3.0 --target=air64-apple-ios18.0 $MAD_KERNELS_FLAGS \
           -o "$OUT/mad_kernels_ios18.metallib" "$SRC/mad_kernels.metal" 2> "$OUT/mad_kernels_ios18.err"; then
        (cd "$OUT" && xxd -i mad_kernels_ios18.metallib > mad_kernels_ios18_metallib.h)
        EXTRA+=(-DMAD_HAVE_KERNELS_IOS18)
        echo "  iOS 18 copy: $(wc -c < "$OUT/mad_kernels_ios18.metallib" | tr -d ' ') bytes"
    else
        echo "  the iOS 18 copy did not build -- iOS 18 runs without the helper kernels, as before"
        head -20 "$OUT/mad_kernels_ios18.err" 2> /dev/null || true
    fi
else
    echo "  helper kernels did not build -- what needs them is skipped"
    head -20 "$OUT/mad_kernels.err" 2> /dev/null || true
    [ "${MADEIRA_REQUIRE_KERNELS:-0}" != 1 ] || exit 1
fi

echo "=== madeira_d3d12.dll (arm64ec) ==="
# ml1310: DXMT's BCn decoders, for BC uploads on GPUs without BC sampling.
for cpp in "$SRC/mad_bcn.cpp" "$REPO_ROOT/dxmt/src/dxmt/dxmt_bcn.cpp"; do
    "$MINGW/arm64ec-w64-mingw32-clang++" -c -O2 -std=c++17 -fno-exceptions -fno-rtti \
        -I"$REPO_ROOT/dxmt/src/dxmt" -o "$OUT/$(basename "$cpp" .cpp).o" "$cpp"
done
"$MINGW/arm64ec-w64-mingw32-clang" -shared -O2 -Wall ${EXTRA[@]+"${EXTRA[@]}"} \
    -o "$OUT/madeira_d3d12.dll" "$SRC/madeira_d3d12.c" "$OUT/mad_bcn.o" "$OUT/dxmt_bcn.o" "$SRC/d3d12.def" \
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
