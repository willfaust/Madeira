#!/usr/bin/env python3
"""Mark a PE file as a Wine builtin, as winebuild --builtin does: the 32-byte
signature "Wine builtin DLL" right after the DOS header. Wine's loader only
takes a DLL from its builtin directories (and only honours a load-order "b")
when the signature is there.

--prefer-native also sets Wine's IMAGE_DLLCHARACTERISTICS_PREFER_NATIVE (0x0010,
as winebuild --prefer-native): with the default load order a copy the program
ships wins, and the builtin is used only when the load order asks for it ("b").
Without the flag a builtin replaces the program's own copy everywhere."""
import struct
import sys

SIGNATURE = b'Wine builtin DLL'.ljust(32, b'\0')

PREFER_NATIVE = 0x0010

prefer_native = '--prefer-native' in sys.argv[1:]
path = [a for a in sys.argv[1:] if not a.startswith('--')][0]
with open(path, 'r+b') as f:
    header = bytearray(f.read(0x40))
    if header[:2] != b'MZ':
        sys.exit(f'{path}: not a PE file')
    e_lfanew = struct.unpack_from('<I', header, 0x3c)[0]
    if e_lfanew < 0x40 + len(SIGNATURE):
        sys.exit(f'{path}: no room for the signature (e_lfanew {e_lfanew:#x})')
    f.seek(0x40)
    f.write(SIGNATURE)
    if prefer_native:
        f.seek(e_lfanew)
        if f.read(4) != b'PE\0\0':
            sys.exit(f'{path}: no PE signature')
        characteristics_at = e_lfanew + 4 + 20 + 70   # PE32 and PE32+ alike
        f.seek(characteristics_at)
        characteristics = struct.unpack('<H', f.read(2))[0] | PREFER_NATIVE
        f.seek(characteristics_at)
        f.write(struct.pack('<H', characteristics))
print(f'{path}: marked as a Wine builtin' + (' (prefer native)' if prefer_native else ''))
