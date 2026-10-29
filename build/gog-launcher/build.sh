#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
: "${GOG_CC:=arm64ec-w64-mingw32-clang}"
"$GOG_CC" -Os -municode "$ROOT/build/gog-launcher/main.c" -o "$ROOT/app/Madeira/arm64ec-windows/madeira-gog-launch.exe"
