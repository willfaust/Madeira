#!/usr/bin/env python3
"""Fetch the immutable source used by the Playport patch series; never reset a checkout."""
from pathlib import Path
import hashlib
import sys
import tarfile
import urllib.request

PIN = "b39d173ca9369c19fda2635be6655d308067e52d"
SHA256 = "1d50da0fbedaec06f182932d01e9c1cde1f391105bfe27b77ff09944fcea3dd6"
root = Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
source = root / ("mesa-" + PIN)
marker = source / ".madeira-source-pin"
if source.exists():
    if not marker.exists() or marker.read_text().strip() != PIN:
        raise SystemExit("Source directory exists without the expected pin marker; choose another KK_WORK.")
    raise SystemExit(0)
archive = root / ("mesa-" + PIN + ".tar.gz")
if not archive.exists():
    urllib.request.urlretrieve(f"https://gitlab.freedesktop.org/mesa/mesa/-/archive/{PIN}/mesa-{PIN}.tar.gz", archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
    raise SystemExit("Mesa source archive hash mismatch")
with tarfile.open(archive) as stream:
    stream.extractall(root, filter="data")
marker.write_text(PIN + "\n")
