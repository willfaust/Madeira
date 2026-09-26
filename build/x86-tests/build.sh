#!/bin/bash
# Build a tiny i386 PE for testing the WoW64 path; the 32-bit counterpart of
# build/x64-tests/build.sh. See docs/WOW64.md.
#
# Usage: ./build.sh hello-x86   (kernel32 only, no CRT)
#
# The exe is copied into app/Madeira/i386-windows/. Launch it from a direct
# launch with env.MADEIRA_EXE = hello-x86.exe in madeira.cfg: the bridge reads
# its PE machine, runs it from C:\windows\syswow64, and the log shows
# "MADEIRA-X86-32: hello from a 32-bit PE" and exit code 42.
set -e

NAME="${1:-hello-x86}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32 only) ==="
"$CC" -O2 -g -nostdlib -Wl,--entry=_start -o "$NAME.exe" "$NAME.c" -lkernel32

"$OBJDUMP" -f "$NAME.exe"
"$OBJDUMP" -p "$NAME.exe" | grep "DLL Name" || true

mkdir -p "$APP_BUNDLE"
cp "$NAME.exe" "$APP_BUNDLE/$NAME.exe"
ls -la "$APP_BUNDLE/$NAME.exe"
