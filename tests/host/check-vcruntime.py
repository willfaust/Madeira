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
    "vcruntime140_threads.dll"
]

if not DIR.exists():
    print(f"Directory {DIR} does not exist, skipping check")
    sys.exit(0)

existing = [f for f in FILES if (DIR / f).is_file()]
if not existing:
    print(f"No vcruntime dlls present in {DIR} (clean checkout)")
    sys.exit(0)

missing = [f for f in FILES if not (DIR / f).is_file()]
if missing:
    print("Missing runtime DLLs:")
    for m in missing:
        print("  -", m)
    sys.exit(1)

bad_sig = []
for f in FILES:
    p = DIR / f
    d = p.read_bytes()
    if len(d) < 0x40:
        bad_sig.append(f)
        continue
    pe = struct.unpack_from("<I", d, 0x3c)[0]
    if pe + 24 + 112 + 4 * 8 + 8 > len(d):
        bad_sig.append(f)
        continue
    off, size = struct.unpack_from("<II", d, pe + 24 + 112 + 4 * 8)
    ok = size and off + size <= len(d)
    if not ok:
        bad_sig.append(f)

if bad_sig:
    print("Files with invalid or stripped signatures:")
    for b in bad_sig:
        print("  -", b)
    sys.exit(1)

print(f"ok: check-vcruntime passed ({len(FILES)} signed files verified)")
