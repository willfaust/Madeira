#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
VERSION=20260421
NAME="llvm-mingw-${VERSION}-ucrt-macos-universal"
DEST="$ROOT/toolchains/$NAME"
SHA256=bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7
URL="https://github.com/mstorsjo/llvm-mingw/releases/download/${VERSION}/${NAME}.tar.xz"

if [[ -x "$DEST/bin/aarch64-w64-mingw32-clang" && -x "$DEST/bin/arm64ec-w64-mingw32-clang" ]]; then
  echo "llvm-mingw: cached"
  exit 0
fi

mkdir -p "$ROOT/toolchains"
echo "Downloading llvm-mingw $VERSION..."
ARCHIVE="$ROOT/toolchains/$NAME.tar.xz"
curl -fL --retry 3 "$URL" -o "$ARCHIVE.part"
printf '%s  %s\n' "$SHA256" "$ARCHIVE.part" | shasum -a 256 -c -
mv "$ARCHIVE.part" "$ARCHIVE"
tar -xJf "$ARCHIVE" -C "$ROOT/toolchains"
[[ -x "$DEST/bin/arm64ec-w64-mingw32-clang" ]] || {
  echo "ERROR: llvm-mingw archive does not contain arm64ec-w64-mingw32-clang" >&2
  exit 1
}
