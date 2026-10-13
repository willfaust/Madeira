#!/bin/bash
# Configure (first time) and build the ARM64EC FEX module (libarm64ecfex.dll,
# shipped as xtajit64.dll). Options mirror the development build's CMakeCache.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
B="$R/FEX/build-arm64ec"
if [ ! -f "$B/CMakeCache.txt" ]; then
    # Verified on macOS (2026-10-13, Homebrew ninja and cmake): MINGW_TRIPLE is what
    # toolchain_mingw.cmake reads; TUNE_CPU=none skips the /proc/cpuinfo probe macOS
    # lacks; FEX_IOS_HOST_BUILD and -DFEX_IOS_HOST select the iOS code and link
    # rules (ASM too: Module.S reads the TEB from x18 without it, and x18 is 0 on
    # iOS); Homebrew's fmt must not be found (FEX builds its bundled one); and
    # ThinLTO drops ARM64EC symbols at the link (libc++, SyncThreadContext), so
    # LTO is off.
    cmake -S "$R/FEX" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$R/FEX/Data/CMake/toolchain_mingw.cmake" \
        -DMINGW_TRIPLE=arm64ec-w64-mingw32 -DTUNE_CPU=none \
        -DFEX_IOS_HOST_BUILD=ON -DCMAKE_C_FLAGS=-DFEX_IOS_HOST -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST \
        -DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew -DENABLE_LTO=OFF \
        -DENABLE_FEX_ALLOCATOR=ON -DENABLE_JEMALLOC_GLIBC_ALLOC=ON -DENABLE_OFFLINE_RUNTIME=ON \
        -DBUILD_FEXCONFIG=ON -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=OFF \
        -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DENABLE_ASSERTIONS=OFF
fi
cmake --build "$B" --target arm64ecfex
cp "$B/Bin/libarm64ecfex.dll" "$R/app/Madeira/arm64ec-windows/xtajit64.dll" && ls -l "$R/app/Madeira/arm64ec-windows/xtajit64.dll"
