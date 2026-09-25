#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
VERSION=20260421
NAME="llvm-mingw-${VERSION}-ucrt-macos-universal"
DEST="$ROOT/toolchains/$NAME"
URL="https://github.com/mstorsjo/llvm-mingw/releases/download/${VERSION}/${NAME}.tar.xz"

if [[ -x "$DEST/bin/aarch64-w64-mingw32-clang" && -x "$DEST/bin/arm64ec-w64-mingw32-clang" ]]; then
  echo "llvm-mingw: cached"
  exit 0
fi

mkdir -p "$ROOT/toolchains"
echo "Downloading llvm-mingw $VERSION..."
curl -fL "$URL" | tar -xJ -C "$ROOT/toolchains"
[[ -x "$DEST/bin/arm64ec-w64-mingw32-clang" ]] || {
  echo "ERROR: llvm-mingw archive does not contain arm64ec-w64-mingw32-clang" >&2
  exit 1
}
