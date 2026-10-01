#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
SRC="$ROOT/FEX"
BUILD="$SRC/build-ios"
OUT="$BUILD/FEXCore/Source/libFEXCore.a"

if [[ -f "$OUT" && -f "$BUILD/FEXCore/Source/libJemallocLibs.a" ]]; then
  echo "FEX iOS: cached"
  exit 0
fi

# Options mirror build/fex-ios/build.sh. Do not define FEX_IOS_HOST here: in
# this FEX fork it selects the code for FEX running as a Windows PE under Wine
# on iOS (xtajit.dll, xtajit64.dll), which calls Win32 APIs and symbols that
# only those modules define. The native library the app links uses __APPLE__.

# fex-ios.patch makes the pinned FEX compile and link for this target:
# - Arm64.cpp: IosLogUnimplementedCASPAL dumps a Win32 VirtualQuery region;
#   keep the log line, drop the dump.
# - Core.cpp: the [ffs-bypass]/[cb-entry] reporters read counters declared only
#   under FEX_IOS_HOST, and rpm_cas_snapshot_take lives in FEX's rpmalloc fork,
#   which is not linked with the allocator off (weak stub, reports nothing).
if ! git -C "$SRC" apply --reverse --check "$ROOT/scripts/build/fex-ios.patch" 2>/dev/null; then
  git -C "$SRC" apply "$ROOT/scripts/build/fex-ios.patch"
fi

cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTING=OFF \
  -DBUILD_FEX_LINUX_TESTS=OFF \
  -DBUILD_THUNKS=OFF \
  -DBUILD_FEXCONFIG=OFF \
  -DBUILD_STEAM_SUPPORT=OFF \
  -DENABLE_FEX_ALLOCATOR=OFF \
  -DENABLE_ASSERTIONS=OFF \
  -DENABLE_LTO=OFF \
  -DENABLE_CCACHE=OFF \
  -DTUNE_CPU=generic \
  -DTUNE_ARCH=generic

# The Xcode project links these archives from FEX/build-ios.
cmake --build "$BUILD" --target FEXCore FEXCore_Base JemallocLibs --parallel "$JOBS"
for lib in "$OUT" "$BUILD/FEXCore/Source/libJemallocLibs.a"; do
  [[ -f "$lib" ]] || { echo "ERROR: FEX build did not produce $lib" >&2; exit 1; }
done
