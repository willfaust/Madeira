#!/usr/bin/env python3
"""Epic Cloud saves, checked against Legendary's own reader and writer (Linux or macOS).

Compiles the production app/Madeira/Epic/EpicCloudSaves.swift (with EpicChunk.swift and
EpicManifest.swift) with swiftc into a host driver, then:

  1. selftest        the decision table, filters, save-folder variables, chunk basics;
  2. Swift -> Legendary   the driver uploads a synthetic save to a directory standing in for
                          Epic's service, and Legendary's Manifest/Chunk classes read it back:
                          every file must come out byte for byte, every chunk's rolling hash and
                          SHA-1 must be right, and Legendary's own manifest checks must pass;
  3. Legendary -> Swift   Legendary's SaveGameHelper writes a snapshot, the driver downloads it.

Needs a Swift toolchain and a copy of Legendary (github.com/derrod/legendary) in $LEGENDARY_SRC
(default ~/ref/legendary); without Legendary only step 1 runs. Legendary needs pycryptodomex for
AES, which saves never use, so a stub stands in for it.
"""
import hashlib, os, shutil, subprocess, sys, tempfile, types
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LEG = Path(os.environ.get("LEGENDARY_SRC", Path.home() / "ref" / "legendary"))
EPIC = ROOT / "app" / "Madeira" / "Epic"
failures = 0


def check(ok, what):
    global failures
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures += 1


def build(work):
    swiftc = shutil.which("swiftc") or str(Path.home() / "tools/swift/usr/bin/swiftc")
    src = work / "src"
    src.mkdir()
    for name in ("EpicChunk.swift", "EpicManifest.swift", "EpicCloudSaves.swift"):
        text = (EPIC / name).read_text(encoding="utf-8")
        if sys.platform != "darwin":   # Linux splits URLSession into FoundationNetworking
            text = text.replace("import Foundation\n", "import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n", 1)
        (src / name).write_text(text, encoding="utf-8")
    shutil.copy(Path(__file__).parent / "epic-cloud" / "main.swift", src / "main.swift")
    args = [swiftc, "-O", "-swift-version", "5", "-o", str(work / "driver")]
    if sys.platform != "darwin":   # no zlib module on Linux: describe the system header
        mod = work / "zlibmod"
        mod.mkdir()
        (mod / "module.modulemap").write_text('module zlib [system] {\n header "/usr/include/zlib.h"\n link "z"\n export *\n}\n')
        args += ["-I", str(mod)]
    args += [str(p) for p in sorted(src.glob("*.swift"))]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-3000:], r.stderr[-6000:])
        sys.exit("FAIL: the Swift sources did not compile")
    return work / "driver"


def sha1(b):
    return hashlib.sha1(b).hexdigest()


def make_save(root: Path):
    """A save folder with the shapes that matter: tiny, empty, nested, unicode, and bigger than a chunk."""
    files = {
        "slot1.sav": os.urandom(5000),
        "empty.bin": b"",
        "Profiles/main/profile.dat": os.urandom(100_000),
        "Profiles/zz/ünïcode-名前.sav": b"unicode name " * 100,
        "big/world.dat": os.urandom(2_500_000) + b"\0" * 700_000,        # spans 4 chunks, has compressible tail
        "exactly-one-chunk.bin": os.urandom(1024 * 1024),
        "Alpha.txt": b"sorting is case-insensitive",
    }
    for rel, data in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
    return files


def legendary_modules():
    sys.path.insert(0, str(LEG))
    crypto = types.ModuleType("Cryptodome")
    cipher = types.ModuleType("Cryptodome.Cipher")
    cipher.AES = None
    sys.modules.update({"Cryptodome": crypto, "Cryptodome.Cipher": cipher})
    from legendary.models.chunk import Chunk
    from legendary.models.manifest import Manifest
    from legendary.utils.rolling_hash import get_hash
    from legendary.utils.savegame_helper import SaveGameHelper
    return Chunk, Manifest, get_hash, SaveGameHelper


def main():
    work = Path(tempfile.mkdtemp(prefix="epic-cloud-check-"))
    try:
        driver = build(work)
        r = subprocess.run([str(driver), "selftest"], capture_output=True, text=True)
        print(r.stdout.rstrip())
        check(r.returncode == 0, "selftest")

        if not (LEG / "legendary" / "models" / "chunk.py").exists():
            print(f"SKIP: Legendary not found in {LEG}; set LEGENDARY_SRC for the round-trip checks")
            return
        Chunk, Manifest, get_hash, SaveGameHelper = legendary_modules()
        app, acct, folder = "TestApp", "0123456789abcdef0123456789abcdef", "{AppData}/Test/Saved"

        # 2. Swift writes, Legendary reads
        src, cloud = work / "device", work / "cloud"
        files = make_save(src)
        r = subprocess.run([str(driver), "pack", str(src), str(cloud), app, acct, folder, "2026.10.15-12.30.45"], capture_output=True, text=True)
        print(r.stdout.strip(), r.stderr.strip())
        check(r.returncode == 0, "driver packed a save")
        game = cloud / acct / "savesync" / app
        manifests = sorted((game / "manifests").glob("*.manifest"))
        check(len(manifests) == 1 and manifests[0].name == "2026.10.15-12.30.45.manifest", "one manifest, named by its build version")
        m = Manifest.read_all(manifests[0].read_bytes())
        check(m.meta.app_name == app + acct, "manifest app name is app + account (as Legendary writes it)")
        check(m.meta.build_version == "2026.10.15-12.30.45", "build version")
        check(m.custom_fields["CloudSaveFolder"] == folder, "CloudSaveFolder custom field")
        check(len(m.file_manifest_list.elements) == len(files), f"manifest lists {len(files)} files")
        chunks = {}
        for ci in m.chunk_data_list.elements:
            blob = (game / ci.path).read_bytes()
            check(len(blob) == ci.file_size, f"chunk {ci.path[-20:]} file size matches the manifest")
            c = Chunk.read_buffer(blob)
            data = c.data
            ok = (len(data) == 1024 * 1024 and c.guid == ci.guid and c.hash == ci.hash == get_hash(data)
                  and c.sha_hash == ci.sha_hash == hashlib.sha1(data).digest() and ci.window_size == len(data))
            check(ok, f"chunk {ci.guid_str[:8]}: guid, rolling hash, SHA-1 and size agree")
            chunks[c.guid_num] = data
        for fm in m.file_manifest_list.elements:
            got = b"".join(chunks[cp.guid_num][cp.offset:cp.offset + cp.size] for cp in fm.chunk_parts)
            want = files[fm.filename]
            check(got == want and fm.hash == hashlib.sha1(want).digest() and fm.file_size == len(want),
                  f"file {fm.filename!r} comes back byte for byte, hash and size right")
        check(sorted(fm.filename for fm in m.file_manifest_list.elements) == sorted(files),
              "the manifest names exactly the files that were saved")
        names = [fm.filename for fm in m.file_manifest_list.elements]
        check(names == sorted(names, key=str.casefold), "files are in Legendary's case-insensitive order")
        # round trip through Legendary's own serializer: it must accept what we wrote
        again = Manifest.read_all(m.write())
        check(len(again.file_manifest_list.elements) == len(files), "Legendary can re-serialise and re-read the manifest")

        # 3. Legendary writes, Swift reads
        dev2, cloud2, back = work / "device2", work / "cloud2", work / "backup2"
        files2 = make_save(dev2)
        sgh = SaveGameHelper()
        from datetime import datetime
        packed = sgh.package_savegame(str(dev2), app, acct, folder, "", None, None, datetime(2026, 10, 14, 8, 0, 0))
        game2 = cloud2 / acct / "savesync" / app
        for rel, fp in packed.items():
            t = game2 / rel
            t.parent.mkdir(parents=True, exist_ok=True)
            t.write_bytes(fp.read())
        dest = work / "restored"
        (dest / "slot1.sav").parent.mkdir(parents=True)
        (dest / "slot1.sav").write_bytes(b"older local copy")
        r = subprocess.run([str(driver), "fetch", str(cloud2), str(dest), str(back), app, acct], capture_output=True, text=True)
        print(r.stdout.strip(), r.stderr.strip())
        check(r.returncode == 0, "driver downloaded Legendary's snapshot")
        same = all((dest / rel).read_bytes() == data for rel, data in files2.items())
        check(same, f"all {len(files2)} files restored byte for byte")
        check((back / "slot1.sav").read_bytes() == b"older local copy", "the file it replaced was backed up first")
        check(int((dest / "slot1.sav").stat().st_mtime) == int(datetime(2026, 10, 14, 8, 0, 0).replace(tzinfo=__import__("datetime").timezone.utc).timestamp()),
              "restored files take the snapshot's date")

        # 3b. a damaged chunk must stop the download before anything is written
        victim = next((game2 / "ChunksV4").rglob("*.chunk"))
        victim.write_bytes(victim.read_bytes()[:-50])
        dest3 = work / "restored3"
        r = subprocess.run([str(driver), "fetch", str(cloud2), str(dest3), str(work / "b3"), app, acct], capture_output=True, text=True)
        check(r.returncode != 0 and not dest3.exists(), "a damaged chunk aborts the download and writes nothing")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("ALL OK" if failures == 0 else f"{failures} FAILED")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
