#!/bin/bash
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
WINE_BUILD="$WINE_SRC/build-macos"
command -v xcrun >/dev/null || { echo "ERROR: Wine iOS builds require macOS with Xcode (xcrun not found)." >&2; exit 1; }
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OBJ_DIR="$BUILD_DIR/obj"
APP_LIB="$REPO_ROOT/app/Madeira/libntdll_unix.a"
FREETYPE_DIR="$REPO_ROOT/build/freetype-ios"
GNUTLS_PREFIX="$REPO_ROOT/toolchains/gnutls-ios"

for input in "$WINE_BUILD/include/config.h" "$WINE_BUILD/include/dwrite.h" \
    "$WINE_BUILD/include/dwrite_3.h" "$REPO_ROOT/research/freetype/include/ft2build.h" \
    "$FREETYPE_DIR/build/include/freetype/config/ftconfig.h" "$GNUTLS_PREFIX/include/gnutls/gnutls.h"; do
    [[ -s "$input" ]] || { echo "ERROR: required Wine input missing: $input (run scripts/prepare-wine-ios.sh and build/gnutls-ios/build.sh)." >&2; exit 1; }
done
python3 "$REPO_ROOT/tools/validate-ios-bundle.py" --archive "$GNUTLS_PREFIX/lib/libgnutls.a"
python3 "$REPO_ROOT/tools/validate-ios-bundle.py" --archive "$FREETYPE_DIR/build/libfreetype.a"

mkdir -p "$OBJ_DIR"

SUCCEEDED=0
FAILED=0
FAILED_FILES=""
OBJECTS=()

compile_one() {
    local src=$1
    local name=$2
    echo -n "  $name... "

    if xcrun -sdk iphoneos clang \
        -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
        -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
        -Wno-implicit-function-declaration -Wno-int-conversion \
        -include "$WINE_BUILD/include/config.h" \
        -include "$BUILD_DIR/shims/wine_ios_exit.h" \
        -I"$BUILD_DIR/shims" \
        -I"$WINE_BUILD/dlls/ntdll" -I"$WINE_SRC/dlls/ntdll" -I"$WINE_SRC/dlls/ntdll/unix" \
        -I"$WINE_BUILD/include" -I"$WINE_SRC/include" \
        -D__WINESRC__ -DLTC_NO_PROTOTYPES -DLTC_SOURCE -D_NTSYSTEM_ \
        -D_ACRTIMP= -DWINBASEAPI= \
        -DBINDIR=\"/usr/local/bin\" -DLIBDIR=\"/usr/local/lib\" \
        -DDATADIR=\"/usr/local/share\" -DSYSTEMDLLPATH=\"\" \
        -DWINE_UNIX_LIB -DWINE_IOS=1 \
        -Dget_thread_context=ntdll_get_thread_context \
        -Dset_thread_context=ntdll_set_thread_context \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"
        SUCCEEDED=$((SUCCEEDED + 1))
        OBJECTS+=("$OBJ_DIR/$name.o")
    else
        echo "FAILED"
        FAILED=$((FAILED + 1))
        FAILED_FILES="$FAILED_FILES $name"
    fi
}

# iOS-Madeira 2026-07-05 (Steam S0): compile a DLL's unix side into
# libntdll_unix.a. Args: src, obj-name, funcs-prefix, extra flags...
# The __wine_unix_call_funcs tables are renamed per-lib (they'd collide
# in one archive) and registered by name in virtual_ios.c's
# load_builtin_unixlib. GnuTLS-backed libs add ios_gnutls_shim.h to
# route dlopen/dlsym at the static symtab (gnutls_symtab_ios.c).
CRYPTO_DIR="$REPO_ROOT/build/crypto-unix"
compile_unixlib() {
    local src=$1 name=$2 prefix=$3
    shift 3
    echo -n "  $name... "
    if xcrun -sdk iphoneos clang \
        -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
        -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
        -Wno-implicit-function-declaration -Wno-int-conversion \
        -include "$WINE_BUILD/include/config.h" \
        -include "$BUILD_DIR/shims/wine_ios_exit.h" \
        -I"$BUILD_DIR/shims" \
        -I"$WINE_BUILD/include" -I"$WINE_SRC/include" \
        -D__WINESRC__ -D_NTSYSTEM_ -D_ACRTIMP= -DWINBASEAPI= \
        -DWINE_UNIX_LIB -DWINE_IOS=1 \
        -D__wine_unix_call_funcs=${prefix}_unix_call_funcs \
        -D__wine_unix_call_wow64_funcs=${prefix}_unix_call_wow64_funcs \
        "$@" \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"
        SUCCEEDED=$((SUCCEEDED + 1))
        OBJECTS+=("$OBJ_DIR/$name.o")
    else
        echo "FAILED"
        FAILED=$((FAILED + 1))
        FAILED_FILES="$FAILED_FILES $name"
    fi
}

echo "=== Building ntdll unix (iOS) ==="

# iOS-Madeira 2026-05-13: silent audio driver — provides a null
# IAudioClock that advances at real time so FMOD's audio-gated rhythm
# logic in Thumper et al. advances past intro music.
compile_one "$BUILD_DIR/audio_null_ios.c" "audio_null_ios"

# iOS-Madeira 2026-07-05 (Steam S0): network + crypto unix sides.
echo "=== Building crypto/network unixlibs ==="
"$CRYPTO_DIR/gen_gnutls_symtab.sh"
compile_one "$CRYPTO_DIR/gnutls_symtab_ios.c" "gnutls_symtab_ios"
compile_unixlib "$WINE_SRC/dlls/ws2_32/unixlib.c" "ws2_32_unixlib" "ws2_32" \
    -I"$WINE_SRC/dlls/ws2_32"
compile_unixlib "$WINE_SRC/dlls/bcrypt/gnutls.c" "bcrypt_unixlib" "bcrypt" \
    -I"$WINE_SRC/dlls/bcrypt" -I"$GNUTLS_PREFIX/include" \
    -include "$CRYPTO_DIR/ios_gnutls_shim.h"
compile_unixlib "$WINE_SRC/dlls/secur32/schannel_gnutls.c" "secur32_unixlib" "secur32" \
    -I"$WINE_SRC/dlls/secur32" -I"$GNUTLS_PREFIX/include" \
    -include "$CRYPTO_DIR/ios_gnutls_shim.h"
# iOS-Madeira ml494 (#61 text wall): dwrite had NO unixlib, so every
# __wine_unix_call from dwrite.dll failed and get_glyph_bbox never ran —
# every glyph run reported an EMPTY bbox and Chromium drew no text at all.
# freetype is static here, so dwrite_freetype_ios.c rewrites dlopen/dlsym.
# dwrite.h/dwrite_3.h are generated by `make -C wine/build-macos include/all`.
# compile_unixlib already includes that build tree's include directory.
compile_unixlib "$BUILD_DIR/dwrite_freetype_ios.c" "dwrite_unixlib" "dwrite" \
    -I"$WINE_SRC/dlls/dwrite" -I"$FREETYPE_DIR/build/include" \
    -I"$REPO_ROOT/research/freetype/include"
compile_unixlib "$CRYPTO_DIR/crypt32_unixlib_ios.c" "crypt32_unixlib" "crypt32" \
    -I"$WINE_SRC/dlls/crypt32" -I"$GNUTLS_PREFIX/include" \
    -include "$CRYPTO_DIR/ios_gnutls_shim.h"
# iOS-Madeira 2026-08-03 (#79 transport): in-process NSI TCP connection
# tables (nsiproxy.sys is not shipped; PE nsi.dll falls back to this).
compile_one "$BUILD_DIR/nsi_unixlib_ios.c" "nsi_unixlib_ios"

for src in "$WINE_SRC"/dlls/ntdll/unix/*.c; do
    name=$(basename "$src" .c)

    # Use patched versions for specific files
    case "$name" in
        loader)
            compile_one "$BUILD_DIR/loader_ios.c" "loader"
            ;;
        process)
            compile_one "$BUILD_DIR/process_ios.c" "process"
            ;;
        server)
            compile_one "$BUILD_DIR/server_ios.c" "server"
            ;;
        env)
            compile_one "$BUILD_DIR/env_ios.c" "env"
            ;;
        cdrom)
            compile_one "$BUILD_DIR/cdrom_stub.c" "cdrom"
            ;;
        virtual)
            compile_one "$BUILD_DIR/virtual_ios.c" "virtual"
            ;;
        signal_arm64)
            compile_one "$BUILD_DIR/signal_arm64_ios.c" "signal_arm64"
            ;;
        thread)
            compile_one "$BUILD_DIR/thread_ios.c" "thread"
            ;;
        *)
            compile_one "$src" "$name"
            ;;
    esac
done

echo ""
echo "Results: $SUCCEEDED succeeded, $FAILED failed"
if [ -n "$FAILED_FILES" ]; then
    echo "Failed:$FAILED_FILES"
    for name in $FAILED_FILES; do
        cat "$OBJ_DIR/$name.err"
    done
    exit 1
fi

echo ""
echo "=== Building libntdll_unix.a ==="
rm -f "$OBJ_DIR/libntdll_unix.a"
xcrun --sdk iphoneos ar rcs "$OBJ_DIR/libntdll_unix.a" "${OBJECTS[@]}"

echo "Copying to app..."
python3 "$REPO_ROOT/tools/validate-ios-bundle.py" --archive "$OBJ_DIR/libntdll_unix.a"
cp "$OBJ_DIR/libntdll_unix.a" "$APP_LIB"
echo "libntdll_unix.a: $(wc -c < "$APP_LIB" | tr -d ' ') bytes"
echo "Done!"
