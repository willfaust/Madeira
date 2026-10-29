#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
for pair in arm64ec:arm64ec-windows aarch64:aarch64-windows i686:i386-windows; do
    compiler="${pair%%:*}-w64-mingw32-clang"
    "${BROWSER_TOOLCHAIN:+$BROWSER_TOOLCHAIN/}$compiler" -Os -municode -mwindows "$ROOT/build/game-browser/main.c" -lwinhttp -lshell32 -o "$ROOT/app/Madeira/${pair#*:}/madeira-url-opener.exe"
done
