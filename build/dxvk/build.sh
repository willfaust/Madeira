#!/bin/bash
# DXVK (Direct3D 10/11 and DXGI on Vulkan, zlib licence) for x64 programs, built as
# ARM64EC like DXMT and vkd3d-proton: d3d11.dll, d3d10core.dll and dxgi.dll, run as native
# code in the program's process, on Vulkan through Wine's winevulkan (MoltenVK or
# KosmicKrisp, madeira.cfg `vulkan`).
#
# An opt-in route next to DXMT. DXMT stays the default; a session uses these DLLs only
# with madeira.cfg `d3d11 = dxvk` (WineProcessBridge.m links system32\d3d11.dll,
# d3d10core.dll and dxgi.dll to them for that session, and pairs them with vkd3d-proton
# for Direct3D 12). They are installed under different names (dxvk-d3d11.dll,
# dxvk-d3d10core.dll, dxvk-dxgi.dll) because the vulkan folder already holds
# vkd3d-proton's and nothing else should pick them up by name. D3D9/D3D8 are not built:
# Vulkan is x64-only here (no i386 winevulkan) and most D3D9 programs are 32-bit.
#
#   DXVK_SRC     upstream checkout at DXVK_COMMIT with submodules
#                (default toolchains/dxvk-src; cloned when absent)
#   DXVK_WORK    build directory: patched source copy + meson tree
#                (default toolchains/dxvk-build)
#   LLVM_MINGW   llvm-mingw (default toolchains/llvm-mingw-20260421-ucrt-macos-universal,
#                else toolchains/llvm-mingw)
#   DEST         where the DLLs go (default app/Madeira/vulkan/arm64ec-windows)
#   LIC_DEST     where the licence texts go (default app/Madeira/licenses)
#
# Host tools: meson, ninja, glslangValidator (DXVK's built-in shaders, --target-env
# vulkan1.3, so glslang 11.8 or newer). Patches: build/dxvk/patches/*.patch, applied in
# order (see PATCHES.md there).
#
# The TEB: as for vkd3d-proton (build/vkd3d-proton/build.sh), the toolchain's own winnt.h
# reads the TEB through x18 and the loader's x18 patcher (ios_jit_patch_x18) rewrites those
# instructions at load time; this script lists any x18 instruction it would not rewrite.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
DXVK_TAG=v3.1.1
DXVK_COMMIT=b1a1c99ab52b687cf950d62c88bc2fa316b41663
DXVK_URL=https://github.com/doitsujin/dxvk.git
DXVK_SRC="${DXVK_SRC:-$REPO_ROOT/toolchains/dxvk-src}"
DXVK_WORK="${DXVK_WORK:-$REPO_ROOT/toolchains/dxvk-build}"
DEST="${DEST:-$REPO_ROOT/app/Madeira/vulkan/arm64ec-windows}"
if [ -z "${LLVM_MINGW:-}" ]; then
    for d in "$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal" "$REPO_ROOT/toolchains/llvm-mingw"; do
        [ -x "$d/bin/arm64ec-w64-mingw32-clang" ] && { LLVM_MINGW=$d; break; }
    done
fi
[ -n "${LLVM_MINGW:-}" ] || { echo "llvm-mingw not found (see docs/BUILDING.md); set LLVM_MINGW"; exit 1; }
M="$LLVM_MINGW/bin/arm64ec-w64-mingw32"
for t in meson ninja glslangValidator; do
    command -v $t >/dev/null || { echo "missing host tool: $t"; exit 1; }
done

# 1. Upstream source at the pinned release commit (tag $DXVK_TAG).
if [ ! -d "$DXVK_SRC/.git" ]; then
    git clone -q "$DXVK_URL" "$DXVK_SRC"
fi
if [ "$(git -C "$DXVK_SRC" rev-parse HEAD)" != "$DXVK_COMMIT" ]; then
    git -C "$DXVK_SRC" fetch -q origin "$DXVK_COMMIT" || git -C "$DXVK_SRC" fetch -q --tags origin || true
    git -C "$DXVK_SRC" checkout -q "$DXVK_COMMIT"
fi
git -C "$DXVK_SRC" submodule update --init --recursive -q

# 2. A patched copy (the checkout stays pristine).
SRC="$DXVK_WORK/src"
PE="$DXVK_WORK/arm64ec"
mkdir -p "$DXVK_WORK"
rsync -a --delete --exclude .git "$DXVK_SRC/" "$SRC/"
for p in "$BUILD_DIR"/patches/[0-9]*.patch; do
    [ -f "$p" ] || continue
    patch -s -p1 -d "$SRC" < "$p"
    echo "applied $(basename "$p")"
done
find "$SRC" -name "*.orig" -delete

# 3. ARM64EC cross build. DXVK links the C++ runtime statically itself (-static,
# -static-libstdc++ in its meson.build); D3D8/D3D9 are left out (see the header).
CROSS="$DXVK_WORK/arm64ec-cross.txt"
cat > "$CROSS.new" <<CROSSFILE
[binaries]
c = '$M-clang'
cpp = '$M-clang++'
ar = '$M-ar'
strip = '$M-strip'
windres = '$M-windres'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
CROSSFILE
if [ ! -f "$PE/build.ninja" ] || ! cmp -s "$CROSS.new" "$CROSS"; then
    rm -rf "$PE"
    mv "$CROSS.new" "$CROSS"
    meson setup "$PE" "$SRC" --cross-file "$CROSS" --buildtype release \
        -Denable_d3d8=false -Denable_d3d9=false -Denable_d3d10=true -Denable_d3d11=true \
        -Denable_dxgi=true > "$DXVK_WORK/setup.log" 2>&1 ||
        { tail -40 "$DXVK_WORK/setup.log"; exit 1; }
else
    rm -f "$CROSS.new"
fi
ninja -C "$PE" > "$DXVK_WORK/build.log" 2>&1 ||
    { grep -E "error|FAILED" "$DXVK_WORK/build.log" | head -30; exit 1; }

# 4. Strip like every shipped builtin, install under the dxvk- names, check the x18 sites.
mkdir -p "$DEST"
if command -v llvm-objdump >/dev/null; then
    OBJDUMP=llvm-objdump
else
    OBJDUMP="$LLVM_MINGW/bin/llvm-objdump"
fi
for d in src/d3d11/d3d11.dll src/d3d10/d3d10core.dll src/dxgi/dxgi.dll; do
    out="$DEST/dxvk-$(basename "$d")"
    "$M-strip" --strip-debug -o "$out" "$PE/$d"
    # Instruction forms ios_jit_patch_x18 rewrites: x18 as the base of a load/store
    # (immediate, register or pre/post-indexed, LDP/STP), as the index of a
    # register-offset load/store, mov xN, x18, add/sub with x18. Anything else
    # (x18 written, or used by another instruction) would run with iOS's x18.
    total=$("$OBJDUMP" -d "$out" 2>/dev/null | grep -cE '\bx18\b' || true)
    odd=$("$OBJDUMP" -d "$out" 2>/dev/null | grep -E '\bx18\b' |
          grep -vE '\b(ldr|ldrb|ldrh|ldrsw|ldrsb|ldrsh|ldur|ldurb|ldurh|str|strb|strh|stur|sturb|sturh|ldp|stp)\b[^[]*\[x18' |
          grep -vE '\b(ldr|ldrb|ldrh|str|strb|strh)\b.*\[x[0-9]+, x18' |
          grep -vE '\b(mov|add|sub)\b +x[0-9]+, x18\b' | grep -vE '\badd\b +x[0-9]+, x[0-9]+, x18\b' || true)
    echo "$(basename "$out"): $(wc -c < "$out") bytes, $total x18 instructions"
    if [ -n "$odd" ]; then
        echo "WARNING: x18 instructions the load-time patcher may not rewrite:"
        echo "$odd" | head -20
    fi
done

# 5. Licence texts for the bundle (app/Madeira/licenses, a bundled folder): DXVK (zlib)
# and the two MIT libraries linked in, dxbc-spirv (also in vkd3d-proton; the same text)
# and libdisplay-info.
LIC="${LIC_DEST:-$REPO_ROOT/app/Madeira/licenses}"
if [ -d "$LIC" ]; then
    cp "$DXVK_SRC/LICENSE" "$LIC/DXVK-zlib.txt"
    cp "$DXVK_SRC/subprojects/libdisplay-info/LICENSE" "$LIC/libdisplay-info-MIT.txt"
    [ -f "$LIC/dxbc-spirv-MIT.txt" ] || cp "$DXVK_SRC/subprojects/dxbc-spirv/LICENSE" "$LIC/dxbc-spirv-MIT.txt"
fi
echo "DXVK $DXVK_TAG ($DXVK_COMMIT) -> $DEST"
