#!/usr/bin/env python3
"""Copy static archives with their arm64 objects relabelled from iOS to the iOS Simulator.

The device archives are arm64 machine code in objects whose LC_BUILD_VERSION names the
iOS platform; the simulator linker refuses those. This rewrites that one field, in place
and without changing any size, in a copy of each archive. It does not recompile: code that
needs a simulator-specific build (the x18 patch, device-only APIs) is not fixed by this.

    relabel-archives.py OUT_DIR ARCHIVE.a [ARCHIVE.a ...]
"""
import os
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_BUILD_VERSION = 0x32
PLATFORM_IOS, PLATFORM_IOSSIMULATOR = 2, 7


def relabel_macho(buf: bytearray, off: int) -> bool:
    if struct.unpack_from("<I", buf, off)[0] != MH_MAGIC_64:
        return False
    ncmds = struct.unpack_from("<I", buf, off + 16)[0]
    p, changed = off + 32, False
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", buf, p)
        if cmd == LC_BUILD_VERSION and struct.unpack_from("<I", buf, p + 8)[0] == PLATFORM_IOS:
            struct.pack_into("<I", buf, p + 8, PLATFORM_IOSSIMULATOR)
            changed = True
        p += size
    return changed


def relabel_archive(src: str, dst: str) -> int:
    buf = bytearray(open(src, "rb").read())
    if buf[:8] != b"!<arch>\n":
        raise SystemExit(f"{src}: not an ar archive")
    pos, n = 8, 0
    while pos + 60 <= len(buf):
        name = bytes(buf[pos:pos + 16]).decode("ascii", "replace").strip()
        size = int(bytes(buf[pos + 48:pos + 58]).decode("ascii").strip())
        data = pos + 60
        if name.startswith("#1/"):  # BSD long name: the name sits first in the data
            data += int(name[3:])
        n += relabel_macho(buf, data)
        pos = pos + 60 + size
        pos += pos & 1
    with open(dst, "wb") as f:
        f.write(buf)
    return n


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for a in sys.argv[2:]:
        print(f"{os.path.basename(a)}: {relabel_archive(a, os.path.join(out, os.path.basename(a)))} objects")
