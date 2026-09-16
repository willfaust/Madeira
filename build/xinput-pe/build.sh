#!/bin/bash
# iOS-Madeira: rebuild the ARM64EC xinput DLLs (host-pad mode, see
# wine/dlls/xinput1_3/unixlib.h) and drop them into the app bundle.
#
# Needs the configured PE tree at wine/build-arm64ec (same one the EC ntdll
# is built from). The unix half lives in build/ntdll-unix/xinput_host_ios.c,
# so re-run build/ntdll-unix/build.sh too.
set -e

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
PE_BUILD="$REPO_ROOT/wine/build-arm64ec"
APP_DIR="$REPO_ROOT/app/Madeira/arm64ec-windows"
MINGW="$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
export PATH="$MINGW:$PATH"

DLLS="xinput1_1 xinput1_2 xinput1_3 xinput1_4 xinput9_1_0"

if [ ! -f "$PE_BUILD/Makefile" ]; then
    echo "error: $PE_BUILD is not a configured Wine build tree" >&2
    exit 1
fi

for dll in $DLLS; do
    echo "=== $dll ==="
    out="$PE_BUILD/dlls/$dll/arm64ec-windows/$dll.dll"
    make -C "$PE_BUILD" -j"${JOBS:-8}" "dlls/$dll/arm64ec-windows/$dll.dll"
    if [ ! -f "$out" ]; then
        echo "error: no $dll.dll produced under $PE_BUILD/dlls/$dll" >&2
        exit 1
    fi
    cp "$out" "$APP_DIR/$dll.dll"
    if command -v llvm-strip >/dev/null; then llvm-strip -s "$APP_DIR/$dll.dll"; fi
    echo "  -> $APP_DIR/$dll.dll ($(wc -c < "$APP_DIR/$dll.dll" | tr -d ' ') bytes)"
done

echo "Done. Rebuild libntdll_unix.a (build/ntdll-unix/build.sh) and the app."
