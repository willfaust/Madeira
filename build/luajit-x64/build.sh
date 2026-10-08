#!/bin/bash
# GPL-3.0-or-later WITH the Madeira Converter Exception, version 1.
# Build an x86-64 Windows lua51.dll (LuaJIT 2.1) that Madeira can run, and
# stage it at app/Madeira/compat/love/lua51.dll.
#
# Why this exists: LOVE games (Balatro, ...) ship LuaJIT built in the old
# 32-bit-GC-pointer mode, which requires every GC object to live below 2 GB.
# iOS cannot map anything down there, so luaL_newstate() returns NULL and
# love.exe crashes on its first Lua call. The wineserver maps this build in
# place of such a lua51.dll when it is loaded, leaving the game's file alone
# (build/wineserver/luajit_compat.c).
#
# Build options, all deliberate:
#   GC64 (the v2.1 default on x64)  64-bit GC references: no low-2GB heap.
#   LUAJIT_DISABLE_JIT              interpreter only. The trace compiler wants
#                                   its machine code within +-2 GB of the VM
#                                   and rewrites it in place; under FEX that is
#                                   self-modifying x86 code on every trace. The
#                                   interpreter is static code FEX translates once.
#   LUAJIT_NO_UNWIND                internal error unwinding. The Windows default
#                                   raises an SEH exception for EVERY lua_error
#                                   (pcall/error are routine in LOVE); internal
#                                   unwinding never leaves the VM.
#
# Source: research/LuaJIT (git clone https://github.com/LuaJIT/LuaJIT, branch v2.1).
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${LUAJIT_SRC:-$R/research/LuaJIT}"
OUT="$R/app/Madeira/compat/love"
export PATH="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0   # LuaJIT's Makefile demands it for the macOS-hosted build tools

if [ ! -f "$SRC/src/luajit.h" ] && [ ! -f "$SRC/src/luajit_rolling.h" ]; then
    echo "LuaJIT source not found at $SRC" >&2
    echo "  git clone -b v2.1 https://github.com/LuaJIT/LuaJIT \"$SRC\"" >&2
    exit 1
fi

make -C "$SRC/src" clean >/dev/null
make -C "$SRC/src" -j"$(sysctl -n hw.ncpu)" \
    HOST_CC="xcrun clang" \
    CROSS=x86_64-w64-mingw32- \
    TARGET_SYS=Windows \
    BUILDMODE=dynamic \
    XCFLAGS="-DLUAJIT_DISABLE_JIT -DLUAJIT_NO_UNWIND" \
    lua51.dll

mkdir -p "$OUT"
x86_64-w64-mingw32-strip -o "$OUT/lua51.dll" "$SRC/src/lua51.dll"
git -C "$SRC" rev-parse --short HEAD > "$OUT/lua51.dll.version"
cp "$SRC/COPYRIGHT" "$R/app/Madeira/licenses/LuaJIT-MIT.txt"
ls -l "$OUT/lua51.dll"
