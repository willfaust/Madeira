#!/bin/bash
# Configure wine/build-macos: the host-configured Wine tree whose generated
# include/ (config.h, and widl headers such as wtypes.h and dwrite.h) is read by
# build/ntdll-unix, build/wineserver and build/win32u-unix. Nothing else creates
# it, and without it every ntdll-unix file fails on its forced
# -include .../build-macos/include/config.h.
#
# Needs (Homebrew): bison flex freetype gnutls pkg-config. macOS ships bison 2.3,
# which Wine's configure rejects; Homebrew's keg-only bison/flex are put first on
# PATH here. FreeType and GnuTLS must be found so config.h enables the font and
# crypto code the unix libraries compile.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v brew >/dev/null || { echo "ERROR: Homebrew is required"; exit 1; }
export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
bison --version | head -1 | grep -q ' 3\.' || { echo "ERROR: bison 3 not found (brew install bison)"; exit 1; }

B="$R/wine/build-macos"
mkdir -p "$B"
cd "$B"
if [ ! -f config.status ]; then
    ../configure --enable-archs=arm64ec --without-x --disable-tests --enable-winegstreamer
fi
# Generate every IDL-derived header (builds widl first). -k: a few .idl files
# have no header rule, which is harmless.
make -k -j"$(sysctl -n hw.ncpu)" $(cd ../include && ls *.idl | sed 's/\.idl$/.h/; s/^/include\//') || true
for h in include/config.h include/wtypes.h include/dwrite.h; do
    [ -f "$h" ] || { echo "ERROR: $B/$h was not generated"; exit 1; }
done
echo "wine/build-macos ready"
