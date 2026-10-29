#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
SRC="$ROOT/toolchains/llvm-project"
HOST="$ROOT/toolchains/llvm-host-build"
IOS="$ROOT/toolchains/llvm-ios-build"
TAG=llvmorg-15.0.7

# CI restores archives and headers, not the LLVM Git checkout.
if [[ "${GITHUB_ACTIONS:-}" == true && -s "$IOS/.madeira-cache.sha256" &&
      -s "$IOS/lib/libLLVMCore.a" && -s "$IOS/lib/libLLVMSupport.a" &&
      -f "$IOS/include/llvm/Config/llvm-config.h" && -f "$SRC/llvm/include/llvm/IR/Module.h" ]] &&
   (cd "$IOS" && shasum -a 256 -c .madeira-cache.sha256 >/dev/null 2>&1); then
  echo "Using the input-matched LLVM iOS cache"
  exit 0
fi

mkdir -p "$ROOT/toolchains"
if [[ ! -e "$SRC/.git" ]]; then
  [[ ! -e "$SRC" ]] || {
    echo "ERROR: incomplete LLVM cache or non-Git source directory: $SRC" >&2
    exit 1
  }
  git clone --depth 1 --branch "$TAG" https://github.com/llvm/llvm-project.git "$SRC"
fi

# Apple ld does not accept --gc-sections. DXMT's documented iOS build requires
# AddLLVM.cmake to treat iOS like Darwin and use -dead_strip in every check, not only the first.
python3 - "$SRC/llvm/cmake/modules/AddLLVM.cmake" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
if 'MATCHES "Darwin|iOS"' not in s:
    old = 'MATCHES "Darwin"'
    if old not in s:
        raise SystemExit(f"expected pattern not found in {p}")
    p.write_text(s.replace(old, 'MATCHES "Darwin|iOS"'))
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
(cd "$IOS" && shasum -a 256 lib/libLLVM*.a) > "$IOS/.madeira-cache.sha256"
