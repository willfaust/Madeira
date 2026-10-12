#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
WINE="$ROOT/wine"
MINGW="$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
export PATH="$MINGW:$PATH"

[[ -x "$WINE/configure" ]] || { echo "ERROR: wine submodule is missing" >&2; exit 1; }

# Sync iOS shim headers into Wine tree so makedep resolves them during configure
SHIMS="$ROOT/build/ntdll-unix/shims"
if [[ -d "$SHIMS" ]]; then
  echo "Syncing iOS shim headers to Wine tree..."
  cp -R "$SHIMS"/* "$WINE/include/" 2>/dev/null || true
  cp -f "$SHIMS"/*.h "$WINE/dlls/ntdll/unix/" 2>/dev/null || true
  cp -f "$SHIMS"/*.h "$WINE/server/" 2>/dev/null || true
fi

# Ensure wine/server/fd.c includes socket headers on Apple
WINE_FD="$WINE/server/fd.c"
if [[ -f "$WINE_FD" ]] && ! grep -q "sys/socket.h" "$WINE_FD"; then
  echo "Patching $WINE_FD for socket headers..."
  python3 -c "
with open('$WINE_FD', 'r') as f:
    c = f.read()
target = '#include <sys/types.h>'
replacement = '''#include <sys/types.h>
#ifdef __APPLE__
#include <sys/socket.h>
#include <netinet/in.h>
#endif'''
if target in c:
    c = c.replace(target, replacement, 1)
    with open('$WINE_FD', 'w') as f:
        f.write(c)
" 2>/dev/null || true
fi


# Native macOS build tree. Madeira's iOS unix-side libraries consume config.h,
# generated headers, and host build outputs from here. aarch64 is the native
# PE architecture used by the tracked Wine/DXMT side.
if [[ ! -f "$WINE/build-macos/Makefile" ]]; then
  echo "Configuring Wine (macOS/aarch64)..."
  mkdir -p "$WINE/build-macos"
  (
    cd "$WINE/build-macos"
    ../configure --enable-archs=aarch64 --disable-tests
  )
fi

# Wine 11 generates one flat top-level Makefile (via tools/makedep) with no
# phony per-subdir targets: a goal like "tools" or "include" names an existing
# directory, so make silently treats it as up to date and builds nothing.
# The real aggregate is "include/all", and the header rules depend on the
# widl binary, so requesting include/all builds every widl-generated header
# (objidlbase.h, unknwn.h, wtypes.h, mf*.h, dshow.h, ...) plus widl itself.
if [[ ! -f "$WINE/build-macos/include/dwrite.h" || ! -x "$WINE/build-macos/tools/winebuild/winebuild" ]]; then
  echo "Building Wine host tools and headers..."
  make -C "$WINE/build-macos" -j"$JOBS" tools/winebuild/winebuild include/all
else
  echo "Wine host tree: cached"
fi

# Madeira's ntdll iOS build currently includes generated dwrite headers from a
# directory named build-arm64ec. Configure that tree reproducibly and build only
# the generated headers required by the iOS static libraries; PE binaries are
# already versioned by Madeira and are not rebuilt during onboarding.
if [[ ! -f "$WINE/build-arm64ec/Makefile" ]]; then
  echo "Configuring Wine (ARM64EC headers)..."
  mkdir -p "$WINE/build-arm64ec"
  (
    cd "$WINE/build-arm64ec"
    ../configure --enable-archs=arm64ec --disable-tests
  )
fi

if [[ ! -f "$WINE/build-arm64ec/include/dwrite.h" || ! -f "$WINE/build-arm64ec/include/dwrite_3.h" ]]; then
  echo "Generating Wine ARM64EC headers..."
  make -C "$WINE/build-arm64ec" -j"$JOBS" include/all
else
  echo "Wine ARM64EC headers: cached"
fi
