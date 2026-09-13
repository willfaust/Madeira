#!/bin/bash
# Build freetype static for iOS arm64 — consumed by build/win32u-unix/build.sh,
# which compiles freetype_ios.c against these headers and merges
# build/libfreetype.a into libwin32u_unix.a (no Xcode project changes).
#
# Source: pinned FreeType 2.13.3 commit in research/freetype.
# All optional deps disabled — fonts are plain TTFs from wine/fonts/.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
SRC="$REPO_ROOT/research/freetype"
FREETYPE_COMMIT=42608f77f20749dd6ddc9e0536788eaad70ea4b5

if [[ ! -d "$SRC" ]]; then
  mkdir -p "$REPO_ROOT/research"
  download="$(mktemp -d "${TMPDIR:-/tmp}/freetype-fetch.XXXXXX")"
  trap 'rm -rf "$download"' EXIT
  git init "$download"
  git -C "$download" fetch --depth 1 https://github.com/freetype/freetype.git "$FREETYPE_COMMIT"
  git -C "$download" checkout --detach FETCH_HEAD
  mv "$download" "$SRC"
  trap - EXIT
fi
if [[ ! -e "$SRC/.git" ]] || [[ "$(git -C "$SRC" rev-parse HEAD)" != "$FREETYPE_COMMIT" ]]; then
  echo "ERROR: $SRC must be a checkout of FreeType commit $FREETYPE_COMMIT." >&2
  exit 1
fi

JOBS="${JOBS:-${BUILD_JOBS:-}}"
if [[ -z "$JOBS" ]]; then
    if command -v sysctl >/dev/null && sysctl -n hw.ncpu >/dev/null 2>&1; then
        JOBS="$(sysctl -n hw.ncpu)"
    else
        JOBS=4
    fi
fi

cmake -S "$SRC" -B "$BUILD_DIR/build" -G "Unix Makefiles" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
  -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON \
  -DCMAKE_C_FLAGS="-fno-stack-protector"

cmake --build "$BUILD_DIR/build" --parallel "$JOBS"
python3 "$REPO_ROOT/tools/validate-ios-bundle.py" --archive "$BUILD_DIR/build/libfreetype.a"
echo "Done: $BUILD_DIR/build/libfreetype.a"
