#!/bin/bash
# Build the LLVM static libraries DXMT's airconv links (toolchains/llvm-ios-build),
# following the recipe in docs/BUILDING.md plus what a clean configure needs:
#   CMAKE_MACOSX_BUNDLE=OFF   iOS makes every executable an app bundle, and LLVM's
#                             install rules for llvm-tblgen then fail ("no BUNDLE
#                             DESTINATION for MACOSX_BUNDLE executable").
#   LLVM_ENABLE_TERMINFO=OFF  otherwise LLVMSupport finds the SDK's libcurses and
#                             the app link fails on _setupterm/_tigetnum/...
#   library targets only      LLVM's remaining tools (llvm-ar, ...) link with
#                             -Wl,--gc-sections, which Apple ld rejects; airconv
#                             needs only the libLLVM*.a archives.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$R/toolchains"
JOBS="$(sysctl -n hw.ncpu)"

if [ ! -d "$T/llvm-project/.git" ]; then
    git clone --filter=blob:none https://github.com/llvm/llvm-project.git "$T/llvm-project"
fi
git -C "$T/llvm-project" checkout -q 8dfdcc7b7

cmake -G Ninja -S "$T/llvm-project/llvm" -B "$T/llvm-host-build" \
    -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD=AArch64
ninja -C "$T/llvm-host-build" llvm-tblgen

cmake -G Ninja -S "$T/llvm-project/llvm" -B "$T/llvm-ios-build" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_BUILD_TYPE=Release -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 \
    -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 -DLLVM_TARGET_ARCH=host \
    -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= -DLLVM_BUILD_TOOLS=Off \
    -DLLVM_INCLUDE_TESTS=Off -DLLVM_ENABLE_ZLIB=Off \
    -DLLVM_TABLEGEN="$T/llvm-host-build/bin/llvm-tblgen" \
    -DLLVM_PARALLEL_LINK_JOBS=1 \
    -DCMAKE_MACOSX_BUNDLE=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF -DTERMINFO_LIB=TERMINFO_LIB-NOTFOUND

LIBS=$(ninja -C "$T/llvm-ios-build" -t targets all | grep -o '^lib/libLLVM[A-Za-z0-9_]*\.a' | sort -u)
ninja -C "$T/llvm-ios-build" -j "$JOBS" $LIBS

if nm "$T/llvm-ios-build/lib/libLLVMSupport.a" 2>/dev/null | grep -q "U _setupterm"; then
    echo "ERROR: LLVMSupport still references terminfo"; exit 1
fi
echo "Built $(ls "$T"/llvm-ios-build/lib/libLLVM*.a | wc -l | tr -d ' ') LLVM libraries"
