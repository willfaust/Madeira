#!/bin/bash
# Configure (first time) and build the ARM64EC FEX module (libarm64ecfex.dll,
# shipped as xtajit64.dll). Options mirror the development build's CMakeCache,
# plus what a clean configure on a macOS host needs:
#   MINGW_TRIPLE          toolchain_mingw.cmake builds the compiler name from it;
#                         left empty, CMake looks for a compiler named "-clang".
#   FEX_IOS_HOST*         Module.cpp uses IosJitReverseTranslate outside its
#                         #ifdef FEX_IOS_HOST block, and ARM64EC/CMakeLists.txt
#                         only uses the link rules that work on a macOS host when
#                         FEX_IOS_HOST_BUILD is set (same flags as fex-wow64).
#   TUNE_CPU=none         "native" runs aarch64_fit_native.py on /proc/cpuinfo,
#                         which macOS lacks (and would tune for the Mac, not the
#                         iPhone).
#   ENABLE_LTO=OFF        with LTO, ld.lld does not resolve the EC libc++ symbols
#                         (std::mutex, __gxx_personality_seh0, ...) from the
#                         llvm-mingw archives.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
B="$R/FEX/build-arm64ec"
if [ ! -f "$B/CMakeCache.txt" ]; then
    cmake -S "$R/FEX" -B "$B" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$R/FEX/Data/CMake/toolchain_mingw.cmake" \
        -DMINGW_TRIPLE=arm64ec-w64-mingw32 \
        -DFEX_IOS_HOST_BUILD=ON -DCMAKE_C_FLAGS=-DFEX_IOS_HOST \
        -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST \
        -DTUNE_ARCH=generic -DTUNE_CPU=none -DENABLE_LTO=OFF \
        -DENABLE_FEX_ALLOCATOR=ON -DENABLE_JEMALLOC_GLIBC_ALLOC=ON -DENABLE_OFFLINE_RUNTIME=ON \
        -DBUILD_FEXCONFIG=ON -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON \
        -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DENABLE_ASSERTIONS=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
fi
cmake --build "$B" --target arm64ecfex -j "$(sysctl -n hw.ncpu)"
mkdir -p "$R/app/Madeira/arm64ec-windows"
cp "$B/Bin/libarm64ecfex.dll" "$R/app/Madeira/arm64ec-windows/xtajit64.dll" && ls -l "$R/app/Madeira/arm64ec-windows/xtajit64.dll"
