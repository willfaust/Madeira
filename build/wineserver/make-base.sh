#!/bin/bash
# Build the BASE libwineserver.a that build/wineserver/build.sh expects to find.
#
# build.sh does not build the wineserver from scratch: it copies a prebuilt
# app/Madeira/libwineserver.a (git-ignored, never published) and swaps its own
# patched objects into it. This script produces that base archive from the
# wine submodule's server/ sources, compiled with exactly the same flags
# build.sh uses, so build.sh can then run normally.
#
# It compiles every wineserver source that build.sh does NOT replace. The
# files build.sh replaces (request, main, mach, unicode, fd, process, window,
# user, class, region, queue, mapping, winstation, thread, sock, object,
# async, event, semaphore, handle, inproc_sync) are skipped here, because
# build.sh compiles and inserts its own versions of them.
#
# Usage (from the Madeira folder):  build/wineserver/make-base.sh
set -u

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
SDK=$(xcrun --sdk iphoneos --show-sdk-path) || { echo "ERROR: iphoneos SDK not found (check xcode-select)"; exit 1; }
SHIMS_DIR="$REPO_ROOT/build/ntdll-unix/shims"
OBJ_DIR="$BUILD_DIR/obj"
BASE_DIR="$OBJ_DIR/base"

if [ ! -f "$WINE_SRC/build-macos/include/config.h" ]; then
    echo "ERROR: $WINE_SRC/build-macos/include/config.h is missing."
    echo "       Configure wine/build-macos first (same as for ntdll-unix)."
    exit 1
fi

# Identical to CC_FLAGS in build/wineserver/build.sh.
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

# server/Makefile.in SOURCES minus everything build.sh replaces.
BASE_SOURCES=(
    atom change clipboard completion console d3dkmt debugger device
    directory file hook mailslot mutex named_pipe procfs ptrace registry
    serial signal symlink timer token trace
)

mkdir -p "$BASE_DIR"
rm -f "$BASE_DIR"/*.o "$BASE_DIR"/*.err

echo "=== Building base wineserver objects ==="
ok=0; failed=()
for name in "${BASE_SOURCES[@]}"; do
    src="$WINE_SRC/server/$name.c"
    printf "  %s... " "$name"
    if [ ! -f "$src" ]; then
        echo "MISSING ($src)"; failed+=("$name"); continue
    fi
    if xcrun -sdk iphoneos clang "${CC_FLAGS[@]}" -c "$src" -o "$BASE_DIR/$name.o" 2>"$BASE_DIR/$name.err"; then
        echo "OK"; ok=$((ok + 1))
    else
        echo "FAILED (see obj/base/$name.err)"; failed+=("$name")
    fi
done

echo ""
echo "Results: $ok succeeded, ${#failed[@]} failed"
if [ ${#failed[@]} -gt 0 ]; then
    echo "Failed: ${failed[*]}"
    echo ""
    for name in "${failed[@]}"; do
        [ -s "$BASE_DIR/$name.err" ] || continue
        echo "== $name"
        grep -m3 -i "error" "$BASE_DIR/$name.err"
    done
    echo ""
    echo "Not creating the archive until every file compiles."
    exit 1
fi

echo "=== Creating obj/libwineserver.a ==="
rm -f "$OBJ_DIR/libwineserver.a"
ar rcs "$OBJ_DIR/libwineserver.a" "$BASE_DIR"/*.o
echo "Base archive: $OBJ_DIR/libwineserver.a ($(wc -c < "$OBJ_DIR/libwineserver.a" | tr -d ' ') bytes)"
echo ""
echo "Next: build/wineserver/build.sh"
