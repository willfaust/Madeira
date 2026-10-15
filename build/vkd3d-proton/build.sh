#!/bin/bash
# vkd3d-proton (Direct3D 12 on Vulkan, LGPL-2.1-or-later) for x64 programs, built as
# ARM64EC like DXMT and madeira-d3d12: d3d12.dll and d3d12core.dll, run as native code in
# the program's process, on Vulkan through Wine's winevulkan (MoltenVK by default).
#
# The second Direct3D 12 route. madeira-d3d12 (build/madeira-d3d12) stays the default;
# a session uses these DLLs only with madeira.cfg `d3d12 = vkd3d` (WineProcessBridge.m
# links them over system32\d3d12.dll and d3d12core.dll for that session).
#
#   VKD3D_SRC    upstream checkout at VKD3D_COMMIT with submodules
#                (default toolchains/vkd3d-proton; cloned when absent)
#   VKD3D_WORK   build directory: patched source copy + meson tree
#                (default toolchains/vkd3d-proton-build)
#   LLVM_MINGW   llvm-mingw (default toolchains/llvm-mingw-20260421-ucrt-macos-universal,
#                else toolchains/llvm-mingw)
#   DEST         where the DLLs go (default app/Madeira/vulkan/arm64ec-windows)
#
# Host tools: meson, ninja, glslangValidator (helper shaders) and the toolchain's widl.
# Patches: build/vkd3d-proton/patches/*.patch, applied in order (see PATCHES.md there).
#
# The TEB: vkd3d-proton is built with the toolchain's own winnt.h, so NtCurrentTeb() and
# the compiler's implicit-TLS accesses read x18, as in every ARM64EC DLL Madeira ships;
# the loader's x18 patcher (ios_jit_patch_x18, build/ntdll-unix/virtual_ios.c) rewrites
# those instructions at load time to read the TEB from Madeira's TSD slot. A compile-time
# slot number (another port's WINE_TEB_TSD_SLOT) does not fit Madeira, whose slot is found
# at run time (ios_teb_tls_slot_offset). The script checks that every x18 instruction in
# the result is a form the patcher rewrites.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
VKD3D_COMMIT=750061ae2be846d19d6364628eaf5ea4beb8e619
VKD3D_URL=https://github.com/HansKristian-Work/vkd3d-proton.git
VKD3D_SRC="${VKD3D_SRC:-$REPO_ROOT/toolchains/vkd3d-proton}"
VKD3D_WORK="${VKD3D_WORK:-$REPO_ROOT/toolchains/vkd3d-proton-build}"
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

# 1. Upstream source at the pinned commit.
if [ ! -d "$VKD3D_SRC/.git" ]; then
    git clone -q "$VKD3D_URL" "$VKD3D_SRC"
fi
if [ "$(git -C "$VKD3D_SRC" rev-parse HEAD)" != "$VKD3D_COMMIT" ]; then
    git -C "$VKD3D_SRC" fetch -q origin "$VKD3D_COMMIT" || true
    git -C "$VKD3D_SRC" checkout -q "$VKD3D_COMMIT"
fi
git -C "$VKD3D_SRC" submodule update --init --recursive -q

# 2. A patched copy (the checkout stays pristine).
SRC="$VKD3D_WORK/src"
PE="$VKD3D_WORK/arm64ec"
mkdir -p "$VKD3D_WORK"
rsync -a --delete --exclude .git "$VKD3D_SRC/" "$SRC/"
for p in "$BUILD_DIR"/patches/[0-9]*.patch; do
    [ -f "$p" ] || continue
    patch -s -p1 -d "$SRC" < "$p"
    echo "applied $(basename "$p")"
done
find "$SRC" -name "*.orig" -delete

# 3. ARM64EC cross build. -static links the C++ runtime (dxil-spirv) in, as DXMT does.
CROSS="$VKD3D_WORK/arm64ec-cross.txt"
cat > "$CROSS.new" <<CROSSFILE
[binaries]
c = '$M-clang'
cpp = '$M-clang++'
ar = '$M-ar'
strip = '$M-strip'
widl = '$M-widl'
windres = '$M-windres'

[built-in options]
c_link_args = ['-static']
cpp_link_args = ['-static', '-static-libstdc++']

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
        -Denable_tests=false -Denable_extras=false > "$VKD3D_WORK/setup.log" 2>&1 ||
        { tail -40 "$VKD3D_WORK/setup.log"; exit 1; }
else
    rm -f "$CROSS.new"
fi
ninja -C "$PE" > "$VKD3D_WORK/build.log" 2>&1 ||
    { grep -E "error|FAILED" "$VKD3D_WORK/build.log" | head -30; exit 1; }

# 4. Strip like every shipped builtin, and check the x18 sites.
mkdir -p "$DEST"
for d in libs/d3d12/d3d12.dll libs/d3d12core/d3d12core.dll; do
    out="$DEST/$(basename "$d")"
    "$M-strip" --strip-debug -o "$out" "$PE/$d"
    # Instruction forms ios_jit_patch_x18 rewrites: x18 as the base of a load/store
    # (immediate, register or pre/post-indexed, LDP/STP), as the index of a
    # register-offset load/store, mov xN, x18, add/sub with x18. Anything else
    # (x18 written, or used by another instruction) would run with iOS's x18.
    if command -v llvm-objdump >/dev/null; then
        OBJDUMP=llvm-objdump
    else
        OBJDUMP="$LLVM_MINGW/bin/llvm-objdump"
    fi
    total=$("$OBJDUMP" -d "$out" 2>/dev/null | grep -cE '\bx18\b' || true)
    odd=$("$OBJDUMP" -d "$out" 2>/dev/null | grep -E '\bx18\b' |
          grep -vE '\b(ldr|ldrb|ldrh|ldrsw|ldrsb|ldrsh|ldur|ldurb|ldurh|str|strb|strh|stur|sturb|sturh|ldp|stp)\b[^[]*\[x18' |
          grep -vE '\b(ldr|ldrb|ldrh|str|strb|strh)\b.*\[x[0-9]+, x18' |
          grep -vE '\b(mov|add|sub)\b +x[0-9]+, x18\b' | grep -vE '\badd\b +x[0-9]+, x[0-9]+, x18\b' || true)
    echo "$(basename "$d"): $(wc -c < "$out") bytes, $total x18 instructions"
    if [ -n "$odd" ]; then
        echo "WARNING: x18 instructions the load-time patcher may not rewrite:"
        echo "$odd" | head -20
    fi
done

# 5. Licence texts for the bundle (app/Madeira/licenses, a bundled folder): vkd3d-proton
# (LGPL-2.1-or-later) and the two MIT shader translators linked into d3d12core.dll.
LIC="${LIC_DEST:-$REPO_ROOT/app/Madeira/licenses}"
if [ -d "$LIC" ]; then
    cp "$VKD3D_SRC/LICENSE" "$LIC/vkd3d-proton-LGPL-2.1.txt"
    cp "$VKD3D_SRC/subprojects/dxil-spirv/LICENSE.MIT" "$LIC/dxil-spirv-MIT.txt"
    cp "$VKD3D_SRC/subprojects/dxil-spirv/subprojects/dxbc-spirv/LICENSE" "$LIC/dxbc-spirv-MIT.txt"
fi
echo "vkd3d-proton $VKD3D_COMMIT -> $DEST"
