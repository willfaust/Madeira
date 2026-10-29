#!/usr/bin/env bash
# Rebuild the shipped Windows runtime from the same Wine, FEX and DXMT pins
# as the native iOS half. Graphics DLLs retain their existing source owners.
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TC="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
export PATH="$TC:$PATH"
export JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
bash "$R/tools/build/build-wine.sh"
modules=()
while IFS= read -r name; do
    [ "$name" = ntdll ] || modules+=("$name")
done < <(python3 "$R/build/windows-runtime/targets.py" arm64ec list)
[ ${#modules[@]} -gt 0 ] || { echo 'No ARM64EC Wine modules selected' >&2; exit 1; }
bash "$R/build/wine-pe/build-modules.sh" "${modules[@]}"
bash "$R/build/wine-pe/build-ntdll.sh"
python3 "$R/build/windows-runtime/targets.py" aarch64 install
# Vulkan Wine DLLs are isolated from the default Metal farm.
DEST="$R/app/Madeira/vulkan/arm64ec-windows" \
    bash "$R/build/wine-pe/build-modules.sh" winevulkan vulkan-1

for arch in arm64ec aarch64; do
    W="$R/wine/build-arm64ec"
    [ "$arch" != aarch64 ] || W="$R/wine/build-macos"
    B="$R/dxmt/build-$arch"
    X="$W/dxmt-$arch.ini"
    sed "s|@GLOBAL_SOURCE_ROOT@|$R|g" "$R/dxmt/build-$arch-win.txt" > "$X"
    # ntdll/winecrt0/dbghelp import libraries are produced by the Wine targets.
    if [ ! -f "$B/build.ninja" ]; then
        SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" meson setup "$B" "$R/dxmt" \
            --cross-file "$X" --native-file "$R/dxmt/build-osx.txt" --buildtype release \
            -Dwine_build_path="$W" -Dwine_builtin_dll=true -Denable_nvapi=true
    fi
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" meson compile -C "$B" -j "$JOBS"
    DEST="$R/app/Madeira/$arch-windows"
    for m in d3d11/d3d11.dll dxgi/dxgi.dll d3d10/d3d10core.dll winemetal/winemetal.dll; do
        # The existing aarch64 farm uses Wine's D3D10 core and D3D9 frontend.
        [ "$arch:$m" != aarch64:d3d10/d3d10core.dll ] || continue
        "$TC/$arch-w64-mingw32-strip" --strip-debug -o "$DEST/$(basename "$m")" "$B/src/$m"
    done
    if [ "$arch" = arm64ec ]; then
        for pair in 'd3d9/d3d9.dll:d3d9.dll' 'nvapi/nvapi64.dll:nvapi64.dll'; do
            "$TC/$arch-w64-mingw32-strip" --strip-debug -o "$DEST/${pair#*:}" "$B/src/${pair%:*}"
        done
    fi
done
bash "$R/build/fex-arm64ec/build.sh"
bash "$R/build/fex-wow64/build.sh"
bash "$R/build/faultrep/build.sh"
"$TC/arm64ec-w64-mingw32-clang" -shared -O2 \
    -Wl,--no-insert-timestamp \
    -o "$R/app/Madeira/arm64ec-windows/wineios.drv" "$R/build/wineios-drv/wineios.c"
"$TC/x86_64-w64-mingw32-clang" -shared -O2 -nostdlib -fno-stack-protector \
    -Wl,--entry,DllMainCRTStartup,--no-insert-timestamp \
    -o "$R/app/Madeira/arm64ec-windows/tftrace-x64.dll" "$R/build/tftrace/tftrace-x64.c" -lkernel32
MADEIRA_REQUIRE_KERNELS=1 bash "$R/build/madeira-d3d12/build-pe.sh"
for dll in madeira_d3d12 d3d12 d3d12core; do
    cp "$R/build/madeira-d3d12/out-pe/$dll.dll" "$R/app/Madeira/arm64ec-windows/$dll.dll"
done

# Pin the compatibility runtime instead of building a moving branch.
LUA="$R/toolchains/luajit-a4c064539ea931274d407e1249b4bb575424a0f4"
if [ ! -d "$LUA/.git" ]; then
    git init -q "$LUA"
    git -C "$LUA" fetch --depth 1 https://github.com/LuaJIT/LuaJIT.git a4c064539ea931274d407e1249b4bb575424a0f4
    git -C "$LUA" checkout -q FETCH_HEAD
fi
[ "$(git -C "$LUA" rev-parse HEAD)" = a4c064539ea931274d407e1249b4bb575424a0f4 ] || exit 1
LUAJIT_SRC="$LUA" bash "$R/build/luajit-x64/build.sh"

python3 "$R/build/windows-runtime/targets.py" closure
