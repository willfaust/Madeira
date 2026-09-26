#!/bin/bash
# Build the 32-bit D3D9 acceptance test, d3d9-cube-x86.exe (docs/WOW64.md).
#
# Kept separate from build.sh on purpose: build.sh is owned by the 32-bit
# bring-up track (hello-x86 / window-x86) and this stage only adds files.
#
# Usage: ./build-d3d9-cube.sh
#
# Produces d3d9-cube-x86.exe (i386 PE) and copies it into
# app/Madeira/i386-windows/ so the IPA build picks it up.  Imports must be
# exactly kernel32 + user32 + d3d9, all Wine-supplied; the script asserts it.
set -e

NAME=d3d9-cube-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32/user32/d3d9) ==="
# -nostdlib: the file supplies `start` and its own memset/memcpy, so nothing
#   pulls in ucrtbase/msvcrt.  -static-libgcc is requested by the milestone
#   spec and is a DRIVER flag, not a linker flag (-Wl,-static-libgcc makes
#   lld fail with "unknown argument"); with -nostdlib there is no runtime
#   support library to link dynamically anyway, so clang notes it is unused
#   and -Wno-unused-command-line-argument keeps the build output clean.
# --large-address-aware: the guest window is a full 4 GB, so the image must
#   not be restricted to the low 2 GB (the
#   ios_wow_image_ceiling() LAA derivation reads exactly this bit).
"$CC" -O2 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start \
    -Wl,--large-address-aware \
    -o "$NAME.exe" "$NAME.c" \
    -lkernel32 -luser32 -ld3d9

ls -la "$NAME.exe"

echo ""
echo "=== machine type (file format) ==="
"$OBJDUMP" -f "$NAME.exe"

echo ""
echo "=== imports ==="
"$OBJDUMP" -p "$NAME.exe" | grep "DLL Name" || true

echo ""
echo "=== asserting the import set is Wine-supplied only ==="
imports=$("$OBJDUMP" -p "$NAME.exe" | sed -n 's/^\s*DLL Name: //p' | tr 'A-Z' 'a-z' | sort -u)
echo "$imports"
unexpected=0
for dll in $imports; do
    case "$dll" in
        kernel32.dll|user32.dll|d3d9.dll) ;;
        *) echo "UNEXPECTED IMPORT: $dll"; unexpected=1 ;;
    esac
done
if [ "$unexpected" != 0 ]; then
    echo "FAILED: the test must import only Wine-supplied DLLs."
    exit 1
fi

echo ""
echo "=== asserting the large-address-aware bit is set ==="
if "$OBJDUMP" -p "$NAME.exe" | grep -q "LARGE_ADDRESS_AWARE"; then
    echo "LARGE_ADDRESS_AWARE present"
else
    # objdump spells the characteristics differently across versions; fall
    # back to reading the bit (0x0020) out of the COFF header directly.
    chars=$("$OBJDUMP" -h "$NAME.exe" >/dev/null 2>&1; \
            "$TOOLCHAIN/llvm-readobj" --file-headers "$NAME.exe" \
            | sed -n 's/.*IMAGE_FILE_LARGE_ADDRESS_AWARE.*/yes/p' | head -1)
    if [ "$chars" = yes ]; then
        echo "LARGE_ADDRESS_AWARE present (readobj)"
    else
        echo "FAILED: LARGE_ADDRESS_AWARE not set."
        exit 1
    fi
fi

echo ""
echo "=== copying $NAME.exe to app bundle ($APP_BUNDLE) ==="
mkdir -p "$APP_BUNDLE"
cp "$NAME.exe" "$APP_BUNDLE/$NAME.exe"
ls -la "$APP_BUNDLE/$NAME.exe"

echo ""
echo "Done."
echo "App-side wiring still required (owned by the app track, not this stage):"
echo "  ContentView.swift  ->  add a 'd3d9-cube-x86' entry to the"
echo "  thirtyTwoBitTests table so the test gets its own launch button"
echo "  below the live view, the same way '32-bit hello' does."
echo "Expected log: MADEIRA-D3D9 lines, then MADEIRA-EXIT: d3d9-cube-x86.exe status=43"
