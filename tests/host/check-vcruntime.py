#!/usr/bin/env python3
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DIR = ROOT / "app/Madeira/x86_64-vcruntime"

FILES = [
    "concrt140.dll",
    "msvcp140.dll",
    "msvcp140_1.dll",
    "msvcp140_2.dll",
    "msvcp140_atomic_wait.dll",
    "msvcp140_codecvt_ids.dll",
    "vcamp140.dll",
    "vccorlib140.dll",
    "vcomp140.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll",
    "vcruntime140_threads.dll",
    "mfc140.dll",
    "mfc140u.dll"
]

def check_sig(d):
    if len(d) < 0x40 or d[:2] != b"MZ":
        return False
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    if pe + 24 + 112 + 40 > len(d) or d[pe:pe + 4] != b"PE\0\0":
        return False
    if struct.unpack_from("<H", d, pe + 24)[0] != 0x20B:
        return False
    off, size = struct.unpack_from("<II", d, pe + 24 + 112 + 4 * 8)
    return off > 0 and size > 0 and off + size <= len(d)

def main():
    strict = "--strict" in sys.argv

    if not DIR.exists():
        if strict:
            print(f"error: {DIR} does not exist", file=sys.stderr)
            sys.exit(1)
        print(f"Directory {DIR} does not exist, skipping check")
        sys.exit(0)

    existing = [f for f in FILES if (DIR / f).is_file()]
    if not existing:
        if strict:
            print("error: no vcruntime dlls present", file=sys.stderr)
            sys.exit(1)
        print(f"No vcruntime dlls present in {DIR} (clean checkout)")
        sys.exit(0)

    missing = [f for f in FILES if not (DIR / f).is_file()]
    if missing:
        print("Missing runtime DLLs:", file=sys.stderr)
        for m in missing:
            print("  -", m, file=sys.stderr)
        sys.exit(1)

    bad_sig = []
    for f in FILES:
        d = (DIR / f).read_bytes()
        if not check_sig(d):
            bad_sig.append(f)

    if bad_sig:
        print("Files with missing or invalid signature payload:", file=sys.stderr)
        for b in bad_sig:
            print("  -", b, file=sys.stderr)
        sys.exit(1)

    print(f"ok: check-vcruntime passed ({len(FILES)} files verified, signature payload present)")

if __name__ == "__main__":
    main()
