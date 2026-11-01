#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export PATH="$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
test -f "$ROOT/wine/include/wine/ios_io_abi.h"
# The i386 backend imports the native aarch64 wow64 DLL; it is not an i386
# image or an ARM64EC DLL. Rebuild the actual producer, not a replacement API.
make -C "$ROOT/wine/build-macos" -j"${JOBS:-8}" dlls/wow64/aarch64-windows/wow64.dll
output="$ROOT/app/Madeira/aarch64-windows/wow64.dll"
cp "$ROOT/wine/build-macos/dlls/wow64/aarch64-windows/wow64.dll" "$output"
"$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/aarch64-w64-mingw32-strip" --strip-debug "$output"
python3 - "$output" <<'PY'
from pathlib import Path
import struct, sys
path = Path(sys.argv[1]); data = path.read_bytes()
pe = struct.unpack_from('<I', data, 0x3c)[0]
assert struct.unpack_from('<H', data, pe + 4)[0] == 0xaa64, 'wow64.dll must be native ARM64'
assert b'madeira-io-abi-v2' in data, 'stale WoW64 IOSB producer'
size = struct.unpack_from('<I', data, pe + 24 + 56)[0]
if len(data) < size: path.write_bytes(data + bytes(size - len(data)))
print('PASS native ARM64 WoW64 IOSB producer rebuilt')
PY

# Rebuild the actual guest32 caller so query/protect failures are visible even
# when WriteProcessMemory never reaches the native NtWriteVirtualMemory path.
if [[ ! -f "$ROOT/wine/build-i386/Makefile" ]]; then
  mkdir -p "$ROOT/wine/build-i386"
  (cd "$ROOT/wine/build-i386" && ../configure --enable-archs=i386 --without-x --without-vulkan \
      --without-freetype --without-gnutls --disable-tests --enable-winegstreamer)
fi
make -C "$ROOT/wine/build-i386" -j"${JOBS:-8}" dlls/kernelbase/i386-windows/kernelbase.dll
cp "$ROOT/wine/build-i386/dlls/kernelbase/i386-windows/kernelbase.dll" "$ROOT/app/Madeira/i386-windows/kernelbase.dll"
"$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/i686-w64-mingw32-strip" --strip-debug "$ROOT/app/Madeira/i386-windows/kernelbase.dll"
python3 - "$ROOT/app/Madeira/i386-windows/kernelbase.dll" <<'PY'
from pathlib import Path
import struct, sys
data = Path(sys.argv[1]).read_bytes()
pe = struct.unpack_from('<I', data, 0x3c)[0]
assert struct.unpack_from('<H', data, pe + 4)[0] == 0x14c
assert b'[wpm-call-v1]' in data, 'stale guest32 WriteProcessMemory diagnostics'
assert b'[steam-arch-v1]' in data, 'stale Steam architecture observation producer'
print('PASS rebuilt i386 WriteProcessMemory caller includes bounded query/result diagnostics')
PY
