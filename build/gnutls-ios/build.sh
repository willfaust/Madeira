#!/bin/bash
# Cross-compile the GnuTLS stack (GMP -> nettle/hogweed -> GnuTLS) as
# static libraries for iOS arm64. Output prefix: toolchains/gnutls-ios/.
#
# Consumers: Wine's bcrypt/secur32(schannel)/crypt32 unixlibs, compiled
# into libntdll_unix.a. Those normally dlopen libgnutls at runtime; on
# iOS we link these .a files into Madeira.app and resolve symbols through
# a generated table (see build/crypto-unix/).
#
# Notes:
#  - GMP: --disable-assembly (iOS-safe; crypto here isn't hot-path enough
#    to chase hand-tuned asm through Apple's assembler quirks).
#  - GnuTLS: bundled libtasn1 + unistring, no p11-kit (PKCS#11 is
#    meaningless on iOS), no tools/tests/docs.
# - Stage markers make re-runs skip completed stages; delete
#    obj/<stage>.done to force a rebuild.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
SRC_DIR="$BUILD_DIR/src"
OBJ_DIR="$BUILD_DIR/obj"
PREFIX="$REPO_ROOT/toolchains/gnutls-ios"

GMP_VER=6.3.0
NETTLE_VER=3.10.1
GNUTLS_VER=3.8.9

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CLANG=$(xcrun -f clang)
HOSTFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=17.0"

export CC="$CLANG $HOSTFLAGS"
export CXX="$(xcrun -f clang++) $HOSTFLAGS"
export CFLAGS="-O2"
export AR="$(xcrun -sdk iphoneos -f ar)"
export RANLIB="$(xcrun -sdk iphoneos -f ranlib)"
export STRIP="$(xcrun -sdk iphoneos -f strip)"
export CC_FOR_BUILD="$CLANG -isysroot $(xcrun --sdk macosx --show-sdk-path)"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
# Configure probes must not find Homebrew libs meant for macOS.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

HOST=aarch64-apple-darwin
JOBS="${JOBS:-${BUILD_JOBS:-}}"
if [[ -z "$JOBS" ]]; then
    if command -v sysctl >/dev/null && sysctl -n hw.ncpu >/dev/null 2>&1; then
        JOBS="$(sysctl -n hw.ncpu)"
    else
        JOBS=4
    fi
fi

mkdir -p "$OBJ_DIR" "$PREFIX"

extract() { # tarball, dirname
    if [ ! -d "$OBJ_DIR/$2" ]; then
        echo "=== extracting $2 ==="
        if [ ! -f "$SRC_DIR/$1" ]; then
            echo "ERROR: missing source tarball $SRC_DIR/$1" >&2
            exit 1
        fi
        tar -C "$OBJ_DIR" -xf "$SRC_DIR/$1"
    fi
}

# ---------------- GMP ----------------
if [ ! -f "$OBJ_DIR/gmp.done" ]; then
    extract "gmp-$GMP_VER.tar.xz" "gmp-$GMP_VER"
    echo "=== configuring GMP ==="
    cd "$OBJ_DIR/gmp-$GMP_VER"
    ./configure --host="$HOST" --prefix="$PREFIX" \
        --enable-static --disable-shared --disable-assembly --with-pic \
        2>&1 | tee "$OBJ_DIR/gmp-configure.log"
    echo "=== building GMP ==="
    make -j"$JOBS" 2>&1 | tee "$OBJ_DIR/gmp-make.log"
    make install 2>&1 | tee -a "$OBJ_DIR/gmp-make.log"
    touch "$OBJ_DIR/gmp.done"
fi
echo "GMP ok"

# ---------------- nettle ----------------
if [ ! -f "$OBJ_DIR/nettle.done" ]; then
    extract "nettle-$NETTLE_VER.tar.gz" "nettle-$NETTLE_VER"
    echo "=== configuring nettle ==="
    cd "$OBJ_DIR/nettle-$NETTLE_VER"
    ./configure --host="$HOST" --prefix="$PREFIX" \
        --enable-static --disable-shared --disable-documentation \
        --with-include-path="$PREFIX/include" --with-lib-path="$PREFIX/lib" \
        2>&1 | tee "$OBJ_DIR/nettle-configure.log"
    echo "=== building nettle ==="
    make -j"$JOBS" 2>&1 | tee "$OBJ_DIR/nettle-make.log"
    make install 2>&1 | tee -a "$OBJ_DIR/nettle-make.log"
    touch "$OBJ_DIR/nettle.done"
fi
echo "nettle ok"

# ---------------- GnuTLS ----------------
if [ ! -f "$OBJ_DIR/gnutls.done" ]; then
    extract "gnutls-$GNUTLS_VER.tar.xz" "gnutls-$GNUTLS_VER"
    echo "=== configuring GnuTLS ==="
    cd "$OBJ_DIR/gnutls-$GNUTLS_VER"
    ./configure --host="$HOST" --prefix="$PREFIX" \
        --enable-static --disable-shared \
        --with-included-libtasn1 --with-included-unistring \
        --without-p11-kit --without-tpm --without-tpm2 \
        --without-idn --without-brotli --without-zstd \
        --disable-doc --disable-tests --disable-tools --disable-cxx \
        --disable-libdane --disable-nls --disable-guile \
        --with-nettle-mini=no \
        NETTLE_CFLAGS="-I$PREFIX/include" NETTLE_LIBS="-L$PREFIX/lib -lnettle" \
        HOGWEED_CFLAGS="-I$PREFIX/include" HOGWEED_LIBS="-L$PREFIX/lib -lhogweed -lgmp" \
        GMP_CFLAGS="-I$PREFIX/include" GMP_LIBS="-L$PREFIX/lib -lgmp" \
        2>&1 | tee "$OBJ_DIR/gnutls-configure.log"
    echo "=== building GnuTLS ==="
    make -j"$JOBS" 2>&1 | tee "$OBJ_DIR/gnutls-make.log"
    make install 2>&1 | tee -a "$OBJ_DIR/gnutls-make.log"
    touch "$OBJ_DIR/gnutls.done"
fi
echo "GnuTLS ok"

echo
echo "=== static libs in $PREFIX/lib ==="
ls -la "$PREFIX/lib/"*.a
lipo -info "$PREFIX/lib/libgnutls.a" 2>/dev/null || true
