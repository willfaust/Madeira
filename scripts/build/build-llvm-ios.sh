#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
SRC="$ROOT/toolchains/llvm-project"
HOST="$ROOT/toolchains/llvm-host-build"
IOS="$ROOT/toolchains/llvm-ios-build"
TAG=llvmorg-15.0.7

if compgen -G "$IOS/lib/libLLVM*.a" >/dev/null; then
  echo "LLVM iOS: cached"
  exit 0
fi

mkdir -p "$ROOT/toolchains"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --depth 1 --branch "$TAG" https://github.com/llvm/llvm-project.git "$SRC"
fi

# Apple ld does not accept --gc-sections. DXMT's documented iOS build requires
# AddLLVM.cmake to treat iOS like Darwin and use -dead_strip.
python3 - "$SRC/llvm/cmake/modules/AddLLVM.cmake" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
if 'MATCHES "Darwin|iOS"' not in s:
    old = 'MATCHES "Darwin"'
    if old not in s:
        raise SystemExit(f"expected pattern not found in {p}")
    p.write_text(s.replace(old, 'MATCHES "Darwin|iOS"', 1))
PY

if [[ ! -x "$HOST/bin/llvm-tblgen" ]]; then
  cmake -S "$SRC/llvm" -B "$HOST" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_ZLIB=OFF
  cmake --build "$HOST" --target llvm-tblgen --parallel "$JOBS"
fi

cmake -S "$SRC/llvm" -B "$IOS" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_TABLEGEN="$HOST/bin/llvm-tblgen" \
  -DLLVM_BUILD_UTILS=OFF \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_INCLUDE_TOOLS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_TARGETS_TO_BUILD=""

cmake --build "$IOS" --parallel "$JOBS"
compgen -G "$IOS/lib/libLLVM*.a" >/dev/null || {
  echo "ERROR: LLVM iOS build produced no static LLVM libraries" >&2
  exit 1
}
