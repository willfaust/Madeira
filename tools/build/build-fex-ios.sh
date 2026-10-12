#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
SRC="$ROOT/FEX"
BUILD="$SRC/build-ios"
OUT="$BUILD/FEXCore/Source/libFEXCore.a"

STUB="$BUILD/FEXCore/Source/libJemallocLibs.a"
create_jemalloc_stub() {
  # ar refuses to create an archive with no members, so archive a real
  # (empty) iOS object instead of relying on `ar cr x.a` alone.
  mkdir -p "$BUILD/FEXCore/Source"
  local stub_obj="$BUILD/FEXCore/Source/.jemalloc_stub.o"
  xcrun -sdk iphoneos clang -arch arm64 -c -x c /dev/null -o "$stub_obj"
  ar cr "$STUB" "$stub_obj"
  rm -f "$stub_obj"
}

if [[ -f "$OUT" ]]; then
  echo "FEX iOS: cached"
  [[ -f "$STUB" ]] || create_jemalloc_stub
  exit 0
fi

# Apply FEX atomic_ref fallback & host guards
if [[ -f "$ROOT/scripts/patch_fex_atomic_ref.sh" ]]; then
  bash "$ROOT/scripts/patch_fex_atomic_ref.sh" "$SRC"
fi

# -DFEX_IOS_HOST=1 selects the iOS host-feature stubs inside this FEX fork
# (HostFeatures, InvalidationTracker, logging). A build without it compiles
# but misdetects the host at runtime, so it is required here, not optional.
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_CXX_STANDARD=20 \
  -DCMAKE_CXX_STANDARD_REQUIRED=ON \
  -DCMAKE_CXX_EXTENSIONS=OFF \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-DFEX_IOS_HOST=1" \
  -DCMAKE_CXX_FLAGS="-DFEX_IOS_HOST=1 -std=c++20" \
  -DBUILD_TESTING=OFF \
  -DBUILD_FEX_LINUX_TESTS=OFF \
  -DBUILD_THUNKS=OFF \
  -DBUILD_FEXCONFIG=OFF \
  -DBUILD_STEAM_SUPPORT=OFF \
  -DENABLE_LTO=OFF \
  -DENABLE_CCACHE=OFF \
  -DTUNE_CPU=generic \
  -DTUNE_ARCH=generic

cmake --build "$BUILD" --target FEXCore FEXCore_Base --parallel "$JOBS"
[[ -f "$OUT" ]] || { echo "ERROR: FEX build did not produce $OUT" >&2; exit 1; }

BASE_OUT="$BUILD/FEXCore/Source/libFEXCore_Base.a"
[[ -f "$BASE_OUT" ]] || { echo "ERROR: FEX build did not produce $BASE_OUT" >&2; exit 1; }

# Create a stub archive for libJemallocLibs.a if not already generated, so any linker invocation succeeds
[[ -f "$STUB" ]] || create_jemalloc_stub
echo "=== Verifying libFEXCore_Base.a symbols ==="
if command -v nm >/dev/null; then
  nm -gU "$BASE_OUT" 2>/dev/null | grep 'Allocator.*memalign' || {
    echo "ERROR: FEXCore::Allocator::memalign definition missing from $BASE_OUT" >&2
    exit 1
  }
fi
