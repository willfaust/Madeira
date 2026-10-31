#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fex_source="${1:?Pass the existing pinned FEX checkout}"
fex_build="${2:?Pass a dedicated macOS FEX build directory}"
toolchain="${3:?Pass the existing llvm-mingw bin directory}"
delivery="${4:-$root/build/signed-fex/out/Madeira-Signed-FEX.ipa}"
cmake -S "$fex_source" -B "$fex_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_CXX_FLAGS=-DFEX_CALLRET_STACK_UNUSED=1 -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DTUNE_CPU=generic -DTUNE_ARCH=generic -DCMAKE_DISABLE_FIND_PACKAGE_fmt=TRUE \
    -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DBUILD_FEXCONFIG=OFF -DBUILD_FEX_LINUX_TESTS=OFF \
    -DENABLE_FEX_ALLOCATOR=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_CLANG_THUNKS=OFF \
    -DENABLE_CCACHE=OFF -DENABLE_WERROR=OFF -DENABLE_LTO=OFF \
    -DENABLE_OFFLINE_TELEMETRY=OFF -DENABLE_GDB_SYMBOLS=OFF -DENABLE_VIXL_DISASSEMBLER=OFF
cmake --build "$fex_build" --target FEXCore FEXCore_Base JemallocLibs --parallel 6
python3 "$root/build/signed-fex/prepare.py" --fex-source "$fex_source" --fex-build "$fex_build" --toolchain "$toolchain"
python3 "$root/build/signed-fex/bundle.py" --sdk macosx --toolchain "$toolchain"
xcrun --sdk macosx clang -target arm64-apple-macos13.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
    -I "$root/app/Madeira" "$root/build/signed-fex/host.m" "$root/app/Madeira/SignedFEX.c" \
    "$root/app/Madeira/SignedCodeProbe.m" -framework Foundation -o "$root/build/signed-fex/out/host"
"$root/build/signed-fex/out/host" \
    "$root/build/signed-fex/out/macosx/MadeiraSignedFEX.framework/MadeiraSignedFEX" \
    "$root/build/signed-fex/out/guest-image.bin"
python3 "$root/build/signed-fex/bundle.py" --sdk iphoneos --toolchain "$toolchain"
python3 "$root/build/signed-fex/package.py" --output "$delivery"
