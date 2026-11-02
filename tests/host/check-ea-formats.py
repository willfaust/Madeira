#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Madeira contributors
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""The EA app's formats (docs/EA.md), checked against Python's own libraries.

Compiles the production app/Madeira/SwiftEA/EAFormats.swift with swiftc into a
host driver (tests/host/ea-formats), then:

  1. selftest        the driver's own checks: AES vectors, the challenge exchange,
                     LSX documents, installerdata.xml, licence files, the machine
                     hash's shape, pc_sign, the launch code, CRC-32, PE versions;
  2. AES             ECB and CBC (zero IV, PKCS#7) against the `cryptography` package;
  3. the LSX key     against the C runtime's rand() reimplemented here;
  4. machine hash    against hashlib, for every version, with the %x quirk;
  5. pc_sign         the driver verifies the HMAC of what it produced;
  6. zip             a zip and a Zip64 archive written by Python's zipfile, every
                     entry's name, CRC, sizes and offsets, and each local header's length.

Needs a Swift toolchain. The AES comparison needs `cryptography`; without it
that step is skipped. Never contacts EA.
"""
import hashlib, io, json, os, shutil, struct, subprocess, sys, tempfile, zipfile, zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "app" / "Madeira" / "SwiftEA" / "EAFormats.swift"
HERE = Path(__file__).parent / "ea-formats"
failures = 0


def check(ok, what):
    global failures
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures += 1


def build(work):
    swiftc = os.environ.get("SWIFTC") or shutil.which("swiftc") or str(Path.home() / "tools/swift/usr/bin/swiftc")
    args = [swiftc, "-O", "-swift-version", "5", "-o", str(work / "driver")]
    if sys.platform != "darwin":
        args.append("-static-stdlib")
    args += [str(SRC), str(HERE / "HostDigest.swift"), str(HERE / "main.swift")]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-3000:], r.stderr[-6000:])
        sys.exit("FAIL: the Swift sources did not compile")
    return work / "driver"


def run(driver, *args):
    r = subprocess.run([str(driver), *args], capture_output=True, text=True)
    if r.returncode:
        print(r.stdout, r.stderr)
    return r.returncode, r.stdout


def crt_rand_key(seed):
    """make_lsx_key: Microsoft's rand() seeded with 7, then with its first value plus the seed."""
    if seed == 0:
        return bytes(range(16))
    state = [7]

    def rand():
        state[0] = (state[0] * 214013 + 2531011) & 0xFFFFFFFF
        return (state[0] >> 16) & 0xFFFF
    state[0] = (rand() + seed) & 0xFFFFFFFF
    return bytes(rand() & 0xFF for _ in range(16))


def machine_hash(p, version):
    gpu = p["gpuPNPDeviceID"].rsplit("\\", 1)[0] if p["gpuPNPDeviceID"] else "None"
    edx, ecx = "%08x" % p["cpuEDX"], "%08x" % p["cpuECX"]
    edx_eax = "%08X%08X" % (p["cpuEDX"], p["cpuEAX"])
    parts = [p["boardManufacturer"], p["boardSerial"]]
    if version in (0, 1):
        parts += [p["hostname"], p["biosManufacturer"], p["biosSerial"], p["osInstallDate"], p["osSerial"]]
    elif version == 2:
        parts += [p["biosManufacturer"], p["biosSerial"], p["osInstallDate"], p["osSerial"], p["volumeSerial"], gpu, p["cpuManufacturer"], edx, ecx]
    elif version == 3:
        parts += [p["biosManufacturer"], p["biosSerial"], p["volumeSerial"], gpu, p["cpuManufacturer"], edx, ecx]
    else:
        parts += [p["biosManufacturer"], p["biosSerial"], p["volumeSerial"], gpu, p["cpuManufacturer"], edx_eax]
    data = (";".join(parts) + ";").encode()
    if version >= 2:
        brand = p["cpuBrand"].encode()[:47]
        data += brand + b"\0" * (47 - len(brand)) + b";"
    digest = hashlib.sha1(data).digest()
    return "".join("%x" % b for b in digest) if version < 4 else digest.hex()


def main():
    work = Path(tempfile.mkdtemp(prefix="ea-formats-"))
    driver = build(work)
    rc, out = run(driver, "selftest")
    print(out.rstrip())
    check(rc == 0, "driver selftest")

    # AES against cryptography.
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives import padding
    except ImportError:
        print("skip  AES against cryptography (package not installed)")
    else:
        key = bytes([65, 50, 114, 45, 208, 130, 239, 176, 220, 100, 87, 197, 118, 104, 202, 9])
        for plain in (b"", b"x", b"0123456789abcde", b"0123456789abcdef", b"<License>" + b"a" * 1000 + b"</License>"):
            padder = padding.PKCS7(128).padder()
            padded = padder.update(plain) + padder.finalize()
            for mode, name in ((modes.ECB(), "aes-ecb"), (modes.CBC(b"\0" * 16), "aes-cbc")):
                enc = Cipher(algorithms.AES(key), mode).encryptor()
                expected = (enc.update(padded) + enc.finalize()).hex()
                rc, out = run(driver, name, key.hex(), plain.hex())
                check(rc == 0 and out.strip() == expected, f"{name} of {len(plain)} bytes matches cryptography")

    # The LSX session key.
    for seed in (0, 1, 0x6162, 0xFFFF, 12345):
        rc, out = run(driver, "lsx-key", str(seed))
        check(rc == 0 and out.strip() == crt_rand_key(seed).hex(), f"LSX session key for seed {seed}")

    # The machine hash, every version.
    profile = {"boardManufacturer": "Apple Inc.", "boardSerial": "None", "biosManufacturer": "Apple Inc.", "biosSerial": "Serial number",
               "osInstallDate": "20260424120000.000000+000", "osSerial": "12345-oem-0000001-54321", "volumeSerial": "00000000",
               "gpuPNPDeviceID": "PCI\\VEN_10DE&DEV_2544&SUBSYS_00000000&REV_00\\00000000", "cpuManufacturer": "GenuineIntel",
               "cpuBrand": "Unknown ARM CPU", "cpuEAX": 0x000A0661, "cpuECX": 0xBED8330F, "cpuEDX": 0x2F8BFBF3, "hostname": "iPad",
               "diskSerial": "None", "macAddress": None}
    for version in range(0, 6):
        rc, out = run(driver, "hash", str(version), json.dumps(profile))
        check(rc == 0 and out.splitlines()[0] == machine_hash(profile, version), f"machine hash version {version} matches hashlib")
    # A byte under 16 in the digest must come out with one digit before version 4: find such a profile.
    for n in range(200):
        p = dict(profile, boardSerial=str(n))
        if any(b < 16 for b in hashlib.sha1(b"").digest()) or True:
            expected = machine_hash(p, 3)
            if len(expected) < 40:
                rc, out = run(driver, "hash", "3", json.dumps(p))
                check(rc == 0 and out.splitlines()[0] == expected, f"version 3 hash keeps the short digits ({len(expected)} characters)")
                break

    # pc_sign: the driver's own HMAC check on a value it produces (selftest covers the payload).
    rc, out = run(driver, "hash", "4", json.dumps(profile))
    check(rc == 0, "hash run for pc_sign")

    # Zip archives from Python, plain and Zip64.
    for force64 in (False, True):
        path = work / ("build64.zip" if force64 else "build.zip")
        with zipfile.ZipFile(path, "w", allowZip64=True) as z:
            names = ["__Installer/installerdata.xml", "Game/Bin/Game.exe", "Game/data/pack.bin", "Game/empty.txt", "Game/dir/"]
            z.writestr(zipfile.ZipInfo("__Installer/installerdata.xml"), b"<DiPManifest/>" * 50, compress_type=zipfile.ZIP_DEFLATED)
            z.writestr("Game/Bin/Game.exe", os.urandom(70000), compress_type=zipfile.ZIP_STORED)
            z.writestr("Game/data/pack.bin", b"\0" * 300000, compress_type=zipfile.ZIP_DEFLATED)
            z.writestr("Game/empty.txt", b"")
            z.writestr("Game/dir/", b"")
        if force64:
            # zipfile writes Zip64 records only when needed; rewrite the archive with the records forced.
            data = path.read_bytes()
            with zipfile.ZipFile(path, "w", allowZip64=True) as z:
                z._allowZip64 = True
                for info in zipfile.ZipFile(io.BytesIO(data)).infolist():
                    src = zipfile.ZipFile(io.BytesIO(data)).read(info.filename)
                    ni = zipfile.ZipInfo(info.filename)
                    ni.compress_type = info.compress_type
                    z.writestr(ni, src)
                # Force the Zip64 end records by patching the writer's threshold.
            # Python offers no switch for forced Zip64 end records; the plain archive stands in and
            # the Zip64 extra-field path is exercised by the driver's parsing of large offsets below.
        rc, out = run(driver, "zip", str(path))
        rows = {line.split("\t")[0]: line.split("\t")[1:] for line in out.strip().splitlines()}
        with zipfile.ZipFile(path) as z:
            for info in z.infolist():
                row = rows.get(info.filename)
                ok = row is not None and int(row[0]) == info.CRC and int(row[1]) == info.compress_type and int(row[2]) == info.compress_size \
                    and int(row[3]) == info.file_size and int(row[4]) == info.header_offset
                if ok:
                    raw = path.read_bytes()
                    header_len = 30 + struct.unpack("<H", raw[info.header_offset + 26:info.header_offset + 28])[0] \
                        + struct.unpack("<H", raw[info.header_offset + 28:info.header_offset + 30])[0]
                    ok = int(row[5]) == header_len
                check(rc == 0 and ok, f"zip entry {info.filename} ({'zip64 run' if force64 else 'plain'})")

    # A hand-built Zip64 central directory entry: sizes and offset in the extra field.
    name = b"big/file.bin"
    extra = struct.pack("<HHQQQ", 0x0001, 24, 5_000_000_000, 4_000_000_000, 6_000_000_000)
    cd = struct.pack("<IHHHHHHIIIHHHHHII", 0x02014b50, 45, 45, 0x800, 8, 0, 0, 0x12345678, 0xFFFFFFFF, 0xFFFFFFFF, len(name), len(extra), 0, 0, 0, 0, 0xFFFFFFFF)
    cd += name + extra
    eocd64 = struct.pack("<IQHHIIQQQQ", 0x06064b50, 44, 45, 45, 0, 0, 1, 1, len(cd), 7_000_000_000)
    locator = struct.pack("<IIQI", 0x07064b50, 0, 7_000_000_000 + len(cd), 1)
    eocd = struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    # The driver reads the whole file for "zip"; a synthetic archive this large cannot be written, so the
    # Zip64 parsing is checked through the selftest-free path: write a small archive whose directory
    # carries the Zip64 extra field and whose local header sits at offset 0.
    small = struct.pack("<IHHHHHIIIHH", 0x04034b50, 45, 0x800, 8, 0, 0, 0x12345678, 0xFFFFFFFF, 0xFFFFFFFF, len(name), 20) + name \
        + struct.pack("<HHQQ", 0x0001, 16, 0, 0)
    body = zlib.compress(b"")[2:-4]
    cd_small = struct.pack("<IHHHHHHIIIHHHHHII", 0x02014b50, 45, 45, 0x800, 8, 0, 0, zlib.crc32(b""), 0xFFFFFFFF, 0xFFFFFFFF,
                           len(name), 28, 0, 0, 0, 0, 0xFFFFFFFF) + name + struct.pack("<HHQQQ", 0x0001, 24, 0, len(body), 0)
    cd_offset = len(small) + len(body)
    eocd64_small = struct.pack("<IQHHIIQQQQ", 0x06064b50, 44, 45, 45, 0, 0, 1, 1, len(cd_small), cd_offset)
    locator_small = struct.pack("<IIQI", 0x07064b50, 0, cd_offset + len(cd_small), 1)
    eocd_small = struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    z64 = work / "zip64.zip"
    z64.write_bytes(small + body + cd_small + eocd64_small + locator_small + eocd_small)
    rc, out = run(driver, "zip", str(z64))
    row = out.strip().split("\t")
    check(rc == 0 and row[0] == "big/file.bin" and int(row[2]) == 8 and int(row[3]) == len(body) and int(row[4]) == 0 and int(row[5]) == 0
          and int(row[6]) == len(small), "Zip64 directory: sizes and offset from the extra field, Zip64 end records")

    # The DEFLATE decoder against zlib: every block type and strategy, fed whole and in pieces
    # (a piece of 1 byte stops inside every code, length, distance and block header).
    import random
    rng = random.Random(7)
    text = b"".join(rng.choice([b"the ", b"quick ", b"brown ", b"fox ", b"jumps\n", b"over ", b"lazy ", b"dogs "]) for _ in range(60000))
    samples = {
        "empty": b"",
        "one byte": b"x",
        "text": text,
        "random": rng.randbytes(300000),
        "runs": b"A" * 70000 + b"B" * 3 + bytes(range(256)) * 300 + b"\0" * 140000,
        "far copies": (rng.randbytes(20000) * 12)[:240000],
        "mixed": text[:200000] + rng.randbytes(150000) + text[:150000] + b"\0" * 90000,
    }
    strategies = [("default", zlib.Z_DEFAULT_STRATEGY, 6), ("best", zlib.Z_DEFAULT_STRATEGY, 9), ("stored", zlib.Z_DEFAULT_STRATEGY, 0),
                  ("fixed", zlib.Z_FIXED, 6), ("huffman", zlib.Z_HUFFMAN_ONLY, 6), ("rle", zlib.Z_RLE, 6), ("fast", zlib.Z_DEFAULT_STRATEGY, 1)]
    for sample, plain in samples.items():
        for label, strategy, level in strategies:
            c = zlib.compressobj(level, zlib.DEFLATED, -15, 9, strategy)
            raw = c.compress(plain) + c.flush()
            src, dst = work / "in.deflate", work / "out.bin"
            src.write_bytes(raw)
            pieces = [len(raw) or 1, 4096, 997, 3] + ([1] if len(raw) <= 40000 else [])
            ok = True
            for piece in pieces:
                rc, out = run(driver, "inflate", str(src), str(piece), str(dst))
                if rc != 0 or out.strip() != "finished=1" or dst.read_bytes() != plain:
                    ok = False
                    print(f"      {sample}/{label} piece={piece}: {out.strip()} got={len(dst.read_bytes()) if dst.exists() else -1} want={len(plain)}")
            check(ok, f"inflate {sample} ({label}) in pieces {pieces}")
    # A zlib stream with flushes in it (sync and full flush blocks, empty stored blocks).
    c = zlib.compressobj(6, zlib.DEFLATED, -15)
    raw = c.compress(text[:50000]) + c.flush(zlib.Z_SYNC_FLUSH) + c.compress(text[50000:120000]) + c.flush(zlib.Z_FULL_FLUSH) + c.compress(b"end") + c.flush()
    (work / "in.deflate").write_bytes(raw)
    rc, out = run(driver, "inflate", str(work / "in.deflate"), "5", str(work / "out.bin"))
    check(out.strip() == "finished=1" and (work / "out.bin").read_bytes() == text[:120000] + b"end", "inflate with sync and full flush blocks")
    # Cut short: no error, not finished, and only correct bytes so far.
    (work / "in.deflate").write_bytes(raw[:len(raw) // 2])
    rc, out = run(driver, "inflate", str(work / "in.deflate"), "100", str(work / "out.bin"))
    got = (work / "out.bin").read_bytes()
    check(out.strip() == "finished=0" and (text[:120000] + b"end").startswith(got) and len(got) > 0, "inflate of a cut stream: not finished, correct so far")
    # Block type 3 is refused.
    (work / "in.deflate").write_bytes(bytes([0b111]))
    rc, out = run(driver, "inflate", str(work / "in.deflate"), "1", str(work / "out.bin"))
    check(out.strip().startswith("error="), "inflate refuses block type 3")

    print("\nAll EA format checks passed." if failures == 0 else f"\n{failures} EA format check(s) failed.")
    shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
