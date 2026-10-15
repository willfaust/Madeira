#!/usr/bin/env python3
"""wsex-mincore: env.MADEIRA_WSEX_MINCORE = 1 (opt-in) makes QueryWorkingSetEx
answer from mincore() on iOS, and turns on madeira-d3d12's default-buffer-swap
residency census; no Wine runs.

iOS has no /proc/self/pagemap, so build/ntdll-unix/virtual_ios.c's
fill_working_set_info read every page as not resident. The census needs a real
answer: are a GPU-only, file-backed buffer's pages still in memory when the GPU
time per present goes up (Horizon Forbidden West, default-buffer-swap = 1,
build 531, 11:24:13)?

Checks:
  - ios_wsex_mincore_on (virtual_ios.c) compiled on this host: unset, empty or
    0 = off, 1 = on, the env is read once;
  - fill_working_set_info asks mincore only when the pagemap file is not open
    and the switch is on, one page at a time, and sets the same pagemap bit
    the Valid test reads; the rest of the Valid test is unchanged;
  - mincore on this (Darwin) host says what the census relies on: a touched
    page of a MAP_SHARED file mapping is in memory, an untouched page of a
    fresh sparse file is not;
  - madeira-d3d12: the census reads the same switch, uses K32QueryWorkingSetEx,
    samples 128 pages a moved buffer, runs from the 5 s memory report only when
    buffers were moved; buffers enter the census when Metal accepted them and
    leave it at release;
  - the catalog lists the switch and CI runs this check.
"""
from pathlib import Path
import mmap
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
VIRT = ROOT / "build/ntdll-unix/virtual_ios.c"
D3D12 = ROOT / "madeira-d3d12/src/pe/madeira_d3d12.c"
CAT = ROOT / "app/Madeira/ConfigCatalog.generated.swift"
CI = ROOT / ".github/workflows/build-ipa.yml"

failures = []


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


def func_body(src, signature):
    i = src.find(signature)
    if i < 0:
        return ""
    j = src.find("{", i)
    depth = 0
    for k in range(j, len(src)):
        if src[k] == "{":
            depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0:
                return src[i:k + 1]
    return ""


virt = VIRT.read_text(encoding="utf-8")
d3d12 = D3D12.read_text(encoding="utf-8")

on_fn = func_body(virt, "static int ios_wsex_mincore_on( void )")
check(bool(on_fn), "ios_wsex_mincore_on found")
harness = r'''
#include <stdio.h>
#include <stdlib.h>
static int getenvs;
static char *h_getenv( const char *n ) { getenvs++; return getenv( n ); }
#define getenv h_getenv
''' + on_fn + r'''
int main( void ) { int a = ios_wsex_mincore_on(), b = ios_wsex_mincore_on(); printf( "%d %d %d\n", a, b, getenvs ); return 0; }
'''
cc = os.environ.get("CC", "cc")
with tempfile.TemporaryDirectory(prefix="madeira-wsex-") as t:
    c = Path(t) / "w.c"
    exe = Path(t) / "w"
    c.write_text(harness)
    r = subprocess.run([cc, "-std=gnu11", "-Wall", "-Werror", str(c), "-o", str(exe)], capture_output=True, text=True)
    check(r.returncode == 0, "ios_wsex_mincore_on compiles on this host" + ("" if not r.returncode else ": " + r.stderr[-500:]))
    if not r.returncode:
        clean = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}
        for val, want in ((None, "0 0 1"), ("", "0 0 1"), ("0", "0 0 1"), ("1", "1 1 1")):
            env = dict(clean, **({"MADEIRA_WSEX_MINCORE": val} if val is not None else {}))
            o = subprocess.run([str(exe)], capture_output=True, text=True, env=env)
            check(o.stdout.strip() == want, "MADEIRA_WSEX_MINCORE=%r -> %s (env read once)" % (val, o.stdout.strip()))

    # what the census relies on, on this Darwin host
    probe = r'''
#include <fcntl.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
int main( int argc, char **argv )
{
    long ps = sysconf( _SC_PAGESIZE );
    int fd = open( argv[1], O_RDWR | O_CREAT | O_TRUNC, 0600 );
    char *p, v0 = 0, v1 = 0;
    if (fd < 0 || ftruncate( fd, 64 * ps )) return 2;
    p = mmap( NULL, 64 * ps, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0 );
    if (p == MAP_FAILED) return 3;
    p[0] = 1;   /* page 0 touched, page 40 never */
    if (mincore( p, ps, &v0 ) || mincore( p + 40 * ps, ps, &v1 )) return 4;
    printf( "%d %d\n", (v0 & MINCORE_INCORE) != 0, (v1 & MINCORE_INCORE) != 0 );
    return 0;
}
'''
    pc = Path(t) / "p.c"
    pe = Path(t) / "p"
    pc.write_text(probe)
    r = subprocess.run([cc, "-std=gnu11", "-Wall", "-Werror", str(pc), "-o", str(pe)], capture_output=True, text=True)
    if r.returncode:
        check(False, "mincore probe compiles: " + r.stderr[-400:])
    else:
        o = subprocess.run([str(pe), str(Path(t) / "f.bin")], capture_output=True, text=True)
        check(o.returncode == 0 and o.stdout.split() == ["1", "0"],
              "mincore: a touched MAP_SHARED file page is in memory, an untouched sparse one is not (%s)" % o.stdout.strip())

fill = func_body(virt, "static void fill_working_set_info( struct fill_working_set_info_data *d, struct file_view *view, BYTE vprot,\n"
                       "                                   struct working_set_info_ref *ref, SIZE_T count,\n"
                       "                                   MEMORY_WORKING_SET_EX_INFORMATION *info )\n{\n    MEMORY_WORKING_SET_EX_INFORMATION *p;")
check("if (pagemap_fd == -1 && ios_wsex_mincore_on())" in fill and
      "if (!mincore( (void *)(page * host_page_size), host_page_size, &vec ) && (vec & MINCORE_INCORE))\n                pagemap = 1ull << 63;" in fill,
      "fill_working_set_info: mincore only without the pagemap file and with the switch, one page, the pagemap bit")
check("p->VirtualAttributes.Valid = !(vprot & VPROT_GUARD) && (vprot & 0x0f) && (pagemap >> 63);" in fill and
      fill.index("ios_wsex_mincore_on()") < fill.index("p->VirtualAttributes.Valid ="),
      "the Valid test itself is unchanged and comes after")
check(virt.count("ios_wsex_mincore_on(") == 2, "no other caller in virtual_ios.c")

census = func_body(d3d12, "static void mad_dsw_census(void) {")
check('GetEnvironmentVariableA("MADEIRA_WSEX_MINCORE", v, sizeof v)' in census and 'GetProcAddress(k32, "K32QueryWorkingSetEx")' in census and
      "on = m == 1 && v[0] == '1' && qwse;" in census and "if (!on) return;" in census,
      "census: same switch, K32QueryWorkingSetEx, off without it")
check("info[128]" in census and "for (j = 0; j < 128; j++) res += (unsigned)(info[j].attr & 1);" in census, "census: 128 pages a buffer, the Valid bit")
check("if (g_defswap_n) mad_dsw_census();   /* madeira-bcd: opt-in, env.MADEIRA_WSEX_MINCORE */" in func_body(d3d12, "static void mad_acct_report(void) {"),
      "census runs from the 5 s memory report, only with moved buffers")
check("mad_dsw_track(mem, len, 1);" in d3d12 and "mad_dsw_track(r->own_mem, 0, 0);" in d3d12, "buffers enter at acceptance and leave at release")

cat = CAT.read_text(encoding="utf-8")
check('ConfigOption(key: "env.MADEIRA_WSEX_MINCORE"' in cat, "the catalog documents env.MADEIRA_WSEX_MINCORE")
# The CI step exists only in the fork's workflow; upstream has no .github.
if CI.exists():
    check("python3 tests/host/check-wsex-mincore.py" in CI.read_text(encoding="utf-8"), "CI runs this check")

if failures:
    print("FAILED: %d" % len(failures))
    sys.exit(1)
print("OK")
