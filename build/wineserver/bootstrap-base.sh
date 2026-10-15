#!/bin/bash
# Build the base libwineserver.a that build.sh starts from, for a checkout that
# has none (build.sh only patches an existing archive, and none is tracked).
# Compiles every wine/server source with build.sh's flags into
# obj/libwineserver.a; then run build.sh as usual.
# Needs wine/build-macos (config.h and the generated headers), like build.sh.
set -eu

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SHIMS_DIR="$REPO_ROOT/build/ntdll-unix/shims"
OBJ_DIR="$BUILD_DIR/obj"
BASE_DIR="$OBJ_DIR/base"
mkdir -p "$BASE_DIR"

# Same flags as build.sh.
CC_FLAGS=(
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
    -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
    -I"$WINE_SRC/build-macos/include"
    -I"$BUILD_DIR" -I"$WINE_SRC/server"
    -I"$SHIMS_DIR"
    -I"$BUILD_DIR/../madsync" -DHAVE_LINUX_NTSYNC_H=1
    -include "$BUILD_DIR/config_ios.h"
    -include stdarg.h
    -include "$BUILD_DIR/unicode_fix.h"
    -include "$BUILD_DIR/wineserver_ios_kill.h"
    -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
    -D__WINESRC__ -DWINE_IOS=1
    -Dmain=wineserver_main
    -Wno-implicit-function-declaration
)

echo "=== Compiling wine/server sources ==="
FAILED=""
for src in $(sed -n '/^SOURCES/,/^$/p' "$WINE_SRC/server/Makefile.in" | tr -s ' \t\\' '\n' | grep '\.c$'); do
    name=${src%.c}
    echo -n "  $name... "
    if xcrun -sdk iphoneos clang "${CC_FLAGS[@]}" -c "$WINE_SRC/server/$src" -o "$BASE_DIR/$name.o" 2>"$BASE_DIR/err-$name.txt"; then
        echo "OK"
    else
        echo "FAILED (see $BASE_DIR/err-$name.txt)"
        FAILED="$FAILED $name"
    fi
done
if [ -n "$FAILED" ]; then
    echo "Failed:$FAILED"
    exit 1
fi

rm -f "$OBJ_DIR/libwineserver.a"
ar rcs "$OBJ_DIR/libwineserver.a" "$BASE_DIR"/*.o
echo "Base archive: $OBJ_DIR/libwineserver.a. Now run build/wineserver/build.sh."
