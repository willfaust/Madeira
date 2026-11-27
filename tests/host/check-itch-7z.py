#!/usr/bin/env python3
"""The itch.io .7z reader (app/Madeira/SwiftItch/itch_7z.c); no Wine or app runs.

Compiles itch_7z.c as the app does (liblzma with the file's own declarations, zlib)
with a small driver, unpacks every fixture in tests/host/itch-7z (made by 7-Zip from
the tree below, see make-fixtures.sh) and checks the result file by file: solid and
not, LZMA, LZMA2, x86 BCJ over LZMA, Copy and Deflate (liblzma runs the filter over
LZMA2 framing), BCJ2 (decoded here), Delta, ARM64 when the system liblzma has it, a
plain and a packed header, empty files and folders, non-ASCII names. A PPMd and an
encrypted archive are refused with their reason codes. Then every fixture cut short and
bytes flipped through the header must fail cleanly (no crash; with the sanitizers where
the compiler has them).

--tree DIR writes the tree the fixtures hold.
"""
from pathlib import Path
import os, random, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
fixtures = Path(__file__).resolve().parent / "itch-7z"
source = root / "app/Madeira/SwiftItch"


def x86_like(seed, size):
    """Code-like bytes: plenty of CALL/JMP/Jcc with near targets (what BCJ/BCJ2 convert)."""
    rng = random.Random(seed)
    out = bytearray()
    vocab = [bytes([0x55, 0x48, 0x89, 0xe5]), bytes([0x48, 0x83, 0xec, 0x20]), bytes([0xc3]), bytes([0x90, 0x90]),
             bytes([0x8b, 0x45, 0xfc]), bytes([0x31, 0xc0]), b"\x0f\x1f\x44\x00\x00"]
    while len(out) < size:
        k = rng.random()
        if k < 0.25:
            op = rng.choice([b"\xe8", b"\xe9", b"\x0f\x84", b"\x0f\x85"])
            target = rng.randrange(0, size) - len(out)
            out += op + (target & 0xffffffff).to_bytes(4, "little")
        else:
            out += rng.choice(vocab)
    return bytes(out[:size])


def tree(base):
    base = Path(base)
    if base.exists():
        shutil.rmtree(base)
    for d in ["Engine/Binaries/Win64", "VotV/Content/Paks", "emptydir/sub", "Ünïcødé 日本 🎮"]:
        (base / d).mkdir(parents=True, exist_ok=True)
    (base / "VotV.exe").write_bytes(b"MZ" + x86_like(1, 40_000))
    (base / "Engine/Binaries/Win64/UE4Game.dll").write_bytes(b"MZ" + x86_like(2, 16_000))
    rng = random.Random(3)
    (base / "VotV/Content/Paks/data.pak").write_bytes(bytes(rng.randrange(256) for _ in range(3_000)))
    (base / "VotV/Content/text.ini").write_text("".join(f"line {i} of a text file\n" for i in range(4000)))
    (base / "empty.txt").write_bytes(b"")
    (base / "Ünïcødé 日本 🎮/empty2").write_bytes(b"")
    (base / "Ünïcødé 日本 🎮/ok.txt").write_text("hi\n")
    (base / "READ THIS NOW OTHERWISE THINGS.txt").write_text("Please set the Dither color depth to 16.\n")


if len(sys.argv) == 3 and sys.argv[1] == "--tree":
    tree(sys.argv[2])
    sys.exit(0)

DRIVER = r"""
#include "itch_7z.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
static const char *root; static FILE *cur; static i7z *Z;
static void parents(char *p) { for (char *s = p + 1; *s; s++) if (*s == '/') { *s = 0; mkdir(p, 0755); *s = '/'; } }
static void path_of(char *out, size_t n, uint32_t i, const char *tail) {
    snprintf(out, n, "%s/%s%s", root, i7z_name(Z, i), tail);
    for (char *s = out; *s; s++) if (*s == '\\') *s = '/';
}
static int sink(void *c, int ev, uint32_t item, const uint8_t *d, size_t n) {
    (void)c; char path[4096];
    if (ev == I7Z_BEGIN) { path_of(path, sizeof path, item, ""); parents(path); cur = fopen(path, "wb"); return cur ? 0 : 1; }
    if (ev == I7Z_DATA) return fwrite(d, 1, n, cur) == n ? 0 : 1;
    fclose(cur); cur = NULL; return 0;
}
int main(int argc, char **argv) {
    (void)argc; char reason[64] = "";
    int r = i7z_open(argv[1], &Z, reason, sizeof reason);
    if (r) { printf("open %d %s\n", r, reason); return 2; }
    root = argv[2];
    for (uint32_t i = 0; i < i7z_count(Z); i++) {
        int f = i7z_flags(Z, i); char path[4096];
        if (f & I7Z_ITEM_DIR) { path_of(path, sizeof path, i, "/"); parents(path); }
        else if (!(f & I7Z_ITEM_STREAM)) { path_of(path, sizeof path, i, ""); parents(path); FILE *e = fopen(path, "wb"); if (e) fclose(e); }
    }
    r = i7z_extract(Z, sink, NULL, reason, sizeof reason);
    if (cur) fclose(cur);
    printf("extract %d %s items=%u total=%llu\n", r, reason, i7z_count(Z), (unsigned long long)i7z_total(Z));
    i7z_close(Z);
    return r ? 3 : 0;
}
"""

work = Path(tempfile.mkdtemp(prefix="itch-7z-"))
fails = 0


def check(what, ok, detail=""):
    global fails
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f": {detail}"))
    if not ok:
        fails += 1


try:
    cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
    if not cc:
        print("SKIP: no C compiler")
        sys.exit(0)
    (work / "driver.c").write_text(DRIVER)
    exe = work / "driver"
    base = [cc, "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-I", str(source), str(work / "driver.c"), str(source / "itch_7z.c"), "-o", str(exe)]
    built = None
    for sanitize in (["-fsanitize=address,undefined", "-fno-omit-frame-pointer"], []):
        for lzma in (["-llzma"], ["/usr/lib/x86_64-linux-gnu/liblzma.so.5"], ["/usr/lib/aarch64-linux-gnu/liblzma.so.5"]):
            if lzma[0].startswith("/") and not Path(lzma[0]).exists():
                continue
            p = subprocess.run(base + sanitize + lzma + ["-lz"], capture_output=True, text=True)
            if p.returncode == 0:
                built = sanitize
                break
            last = p.stderr
        if built is not None:
            break
    if built is None:
        print(last)
        check("itch_7z.c builds and links against liblzma and zlib", False, "see the compiler output above")
        sys.exit(1)
    check("itch_7z.c builds and links against liblzma and zlib" + (" (sanitizers on)" if built else ""), True)

    expected = work / "expected"
    tree(expected / "game")

    def run(archive, out):
        if out.exists():
            shutil.rmtree(out)
        out.mkdir(parents=True)
        env = dict(os.environ, ASAN_OPTIONS=("detect_leaks=0" if sys.platform == "darwin" else "detect_leaks=1") + ":abort_on_error=0", UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1")
        return subprocess.run([str(exe), str(archive), str(out)], capture_output=True, text=True, env=env, timeout=120)

    def same(a, b):
        p = subprocess.run(["diff", "-r", str(a), str(b)], capture_output=True, text=True)
        return p.returncode == 0, p.stdout[:400]

    good = ["default", "x86-lzma2", "x86-lzma", "x86-copy-plain-header", "x86-deflate", "delta", "arm64", "nonsolid",
            "bcj2-lzma", "bcj2-lzma2"]
    for name in good:
        p = run(fixtures / f"{name}.7z", work / name)
        if name == "arm64" and "lzma-options" in p.stdout:
            print("skip arm64: this liblzma has no ARM64 filter (xz before 5.4)")
            continue
        ok, diff = same(expected / "game", work / name / "game") if p.returncode == 0 else (False, "")
        check(f"{name}.7z unpacks to the same files", ok, (p.stdout + p.stderr)[-600:] + diff)

    for name, reason in [("ppmd", "ppmd"), ("encrypted", "encrypted")]:
        p = run(fixtures / f"{name}.7z", work / name)
        check(f"{name}.7z is refused ({reason})", p.returncode in (2, 3) and reason in p.stdout, (p.stdout + p.stderr)[-600:])

    # Damaged archives: cut short, and bytes flipped in the header area.
    rng = random.Random(7)
    crashes = 0
    tried = 0
    for name in ["default", "bcj2-lzma", "x86-copy-plain-header", "x86-lzma", "x86-deflate"]:
        data = (fixtures / f"{name}.7z").read_bytes()
        cuts = sorted({0, 1, 6, 31, 32, 33, len(data) // 2, len(data) - 40, len(data) - 1} | {rng.randrange(len(data)) for _ in range(6)})
        variants = [data[:k] for k in cuts if 0 <= k < len(data)]
        for _ in range(40):
            b = bytearray(data)
            at = rng.choice([rng.randrange(32), len(b) - 1 - rng.randrange(min(len(b), 400)), rng.randrange(len(b))])
            b[at] ^= 1 << rng.randrange(8)
            variants.append(bytes(b))
        for k, v in enumerate(variants):
            f = work / f"bad-{name}-{k}.7z"
            f.write_bytes(v)
            p = run(f, work / "bad")
            tried += 1
            if p.returncode not in (0, 2, 3) or "Sanitizer" in p.stderr or "runtime error" in p.stderr:
                crashes += 1
                if crashes <= 3:
                    print(f"  {f.name}: exit {p.returncode}\n{p.stderr[-1500:]}")
            f.unlink()
    check(f"{tried} damaged archives fail cleanly", crashes == 0, f"{crashes} crashed")
finally:
    shutil.rmtree(work, ignore_errors=True)

print("PASS" if fails == 0 else f"{fails} FAILED")
sys.exit(1 if fails else 0)
