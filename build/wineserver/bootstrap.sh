#!/usr/bin/env bash
# Build the pristine iOS wineserver archive that build.sh patches in-place.
# This removes the circular requirement that contributors already have an
# untracked app/Madeira/libwineserver.a before their first build.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OBJ_DIR="$BUILD_DIR/obj"
BASE_DIR="$OBJ_DIR/base"
APP_LIB="$REPO_ROOT/app/Madeira/libwineserver.a"
SHIMS_DIR="$REPO_ROOT/build/ntdll-unix/shims"

if [[ -f "$OBJ_DIR/libwineserver.a" || -f "$APP_LIB" ]]; then
  echo "wineserver base: cached"
  exit 0
fi

[[ -f "$WINE_SRC/build-macos/include/config.h" ]] || {
  echo "ERROR: Wine host tree is missing; run scripts/build/build-wine.sh first" >&2
  exit 1
}

mkdir -p "$BASE_DIR"
CC_FLAGS=(
  -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
  -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
  -I"$WINE_SRC/build-macos/include" -I"$WINE_SRC/build-macos/server"
  -I"$BUILD_DIR" -I"$WINE_SRC/server"
  -I"$SHIMS_DIR"
  -include "$BUILD_DIR/config_ios.h"
  -include stdarg.h
  -include "$BUILD_DIR/unicode_fix.h"
  -include "$BUILD_DIR/wineserver_ios_kill.h"
  -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
  -D__WINESRC__ -DWINE_IOS=1
  -Dmain=wineserver_main
  -Wno-implicit-function-declaration
)

# build.sh replaces these with Madeira's iOS-specific/patched variants. They do
# not need to be present in the pristine archive.
is_replaced() {
  case "$1" in
    async.c|class.c|fd.c|mach.c|main.c|mapping.c|object.c|process.c|queue.c|region.c|request.c|sock.c|thread.c|unicode.c|user.c|window.c|winstation.c)
      return 0 ;;
    *) return 1 ;;
  esac
}

objects=()
while IFS= read -r base; do
  [[ -n "$base" ]] || continue
  is_replaced "$base" && continue
  src="$WINE_SRC/server/$base"
  obj="$BASE_DIR/${base%.c}.o"
  echo "  bootstrap ${base%.c}"
  xcrun -sdk iphoneos clang "${CC_FLAGS[@]}" -c "$src" -o "$obj"
  objects+=("$obj")
done < <(awk '
  /^SOURCES =/ { in_sources=1; next }
  in_sources && /^UNIX_CFLAGS/ { exit }
  in_sources {
    gsub(/\\/, "")
    for (i=1; i<=NF; i++) if ($i ~ /\.c$/) print $i
  }
' "$WINE_SRC/server/Makefile.in")

(( ${#objects[@]} > 0 )) || { echo "ERROR: no wineserver sources were compiled" >&2; exit 1; }
ar rcs "$OBJ_DIR/libwineserver.a" "${objects[@]}"
cp "$OBJ_DIR/libwineserver.a" "$APP_LIB"
echo "wineserver base: $(wc -c < "$APP_LIB" | tr -d ' ') bytes"
