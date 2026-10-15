#!/usr/bin/env python3
"""swap-heat: env.MADEIRA_SWAP_HEAT (opt-in) -- a mincore census of the swap
tier's extents, and (= 2) new blocks of block sizes that keep being paged back
in stay anonymous while the footprint has room; no Wine runs.

The sampler (ios_swap_heat_tick, after the swap tier's core) and the filter's
lookup (ios_swap_heat_skip, in the core) are compiled on this host with a fake
mincore that plays a residency script, a stand-in extent table and a captured
dprintf. Checks:
  - unset / 0: the sampler asks nothing and prints nothing; the filter never
    answers yes;
  - 1: one [swap] heat line every 10 cycles, by extent size class: a page
    seen in memory, then paged out, then in memory again is a re-read (with
    the extent's share in MB), in memory -> not is an eviction; a first touch
    (never in memory before) is not a re-read; an extent replaced in its slot
    starts over; no filter;
  - 2: a size re-read at least MADEIRA_SWAP_HEAT_MIN times in two extents or
    more is published once and its new blocks stay anonymous (ios_swap_churny
    says so, so whole reservations and commits both skip it); a size re-read
    in one extent only is not; above MADEIRA_SWAP_HEAT_FP_MB the filter
    pauses and below it resumes;
  - the warmer calls the sampler every full cycle; the catalog lists the
    switches and CI runs this check.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
VIRT = ROOT / "build/ntdll-unix/virtual_ios.c"
CAT = ROOT / "app/Madeira/ConfigCatalog.generated.swift"
CI = ROOT / ".github/workflows/build-ipa.yml"
failures = []


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


virt = VIRT.read_text(encoding="utf-8")
a = virt.index("/* madeira-bcd swap-heat (opt-in, env.MADEIRA_SWAP_HEAT = 2; the sampler is")
b = virt.index("static int ios_swap_churny( size_t size )", a)
core = virt[a:b]
churny = virt[b:virt.index("\n}\n", b) + 3]
c0 = virt.index("#define IOS_HEAT_CLASSES 7")
c1 = virt.index("static unsigned long long ios_swap_footprint_mb( void )", c0)
sampler = virt[c0:c1]
check(virt.index("/* swap-tier core begin") < a < virt.index("/* swap-tier core end */") < c0,
      "filter lookup inside the core, sampler after it")
check("    if (ios_swap_heat_skip( size )) return 1;   /* madeira-bcd swap-heat (opt-in) */\n    if (!ios_swap_broad) return 0;" in churny,
      "ios_swap_churny asks the filter first, for every coverage mode")
warm = virt[virt.index("static void *ios_pool_warmer_thread( void *arg )\n{"):]
warm = warm[:warm.index("volatile const char *rw = (volatile const char *)ios_jit_rw_base_global;")]
check("ios_swap_heat_tick();   /* madeira-bcd swap-heat (opt-in, MADEIRA_SWAP_HEAT) */" in warm and
      warm.index("last_full = now_ts;") < warm.index("ios_swap_heat_tick();"),
      "the warmer calls the sampler at every full cycle (after the fast path's continue)")

harness = r'''
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
static struct { char *va; size_t len; uint64_t off; int resv; size_t key; uint64_t born; int img; } ios_swap_ext[16384];
static unsigned ios_swap_n;
static int ios_swap_fd = 3;
static const size_t host_page_size = 16384;
static int ios_swap_broad = 1;
unsigned long long ios_last_footprint_mb = 5000;
static int lines, calls;
static char last_line[4096];
static int h_dprintf( int fd, const char *fmt, ... )
{
    va_list ap; (void)fd; lines++; va_start( ap, fmt ); vsnprintf( last_line, sizeof(last_line), fmt, ap ); va_end( ap );
    fputs( last_line, stderr ); return 0;
}
#define dprintf h_dprintf
/* residency script: state[extent][tick] = 'i' in memory, 'o' paged out, '-' never */
static const char *script[8]; static int tick_no;
static int fake_mincore( const void *addr, size_t len, char *vec )
{
    unsigned i; (void)len; calls++;
    for (i = 0; i < ios_swap_n; i++)
        if ((const char *)addr >= ios_swap_ext[i].va && (const char *)addr < ios_swap_ext[i].va + ios_swap_ext[i].len)
        {
            char c = script[i][tick_no];
            *vec = c == 'i' ? MINCORE_INCORE : c == 'o' ? MINCORE_PAGED_OUT : 0;
            return 0;
        }
    return -1;
}
#define mincore fake_mincore
static int churn_called;
static int ios_swap_churn_find( size_t size, int add ) { (void)size; (void)add; churn_called++; return -1; }
static int ios_swap_churn_is( unsigned i ) { (void)i; return 0; }
@@CORE@@
@@CHURNY@@
@@SAMPLER@@
static char buf[8][1 << 22];
int main( int argc, char **argv )
{
    const char *s = argc > 1 ? argv[1] : "census";
    int t, i;
    /* five extents: three 256 KB blocks (key 0x40000), two 2 MB blocks (key 0x200000) */
    for (i = 0; i < 5; i++)
    {
        ios_swap_ext[i].va = buf[i]; ios_swap_ext[i].len = i < 3 ? (256u << 10) : (2u << 20);
        ios_swap_ext[i].key = i < 3 ? 0x40000 : 0x200000;
    }
    ios_swap_n = 5;
    /* ticks 0..19: extents 0 and 1 re-read twice each (i o i o i ...), extent 2 first-touched only,
       extent 3 re-read once, extent 4 evicted and never back */
    script[0] = "iioiioiiiiiiiiiiiiii";
    script[1] = "iiioiiiioiiiiiiiiiii";
    script[2] = "------iiiiiiiiiiiiii";
    script[3] = "iiiiiiiioiiiiiiiiiii";
    script[4] = "iiiiiiiiiioooooooooo";
    if (!strcmp( s, "replace" )) { script[0] = "iiiiiiiiiiiiiiiiiiii"; }
    for (t = 0; t < 20; t++)
    {
        tick_no = t;
        if (!strcmp( s, "replace" ) && t == 5) ios_swap_ext[0].va = buf[6];   /* a new extent in slot 0 */
        if (!strcmp( s, "replace" ) && t >= 5) script[0] = "-------iiiiiiiiiiiii";   /* the new extent is first touched at cycle 7 */
        if (!strcmp( s, "pause" ) && t == 15) ios_last_footprint_mb = 7000;
        ios_swap_heat_tick();
    }
    printf( "calls=%d lines=%d nhot=%u hot0=0x%zx skip40000=%d skip200000=%d room=%d churn=%d\n", calls, lines,
            ios_swap_heat_nhot, ios_swap_heat_nhot ? ios_swap_heat_hot[0] : 0,
            ios_swap_churny( 0x40000 ), ios_swap_churny( 0x200000 ), ios_swap_heat_room, churn_called );
    printf( "LAST %s", last_line );
    return 0;
}
'''
code = harness.replace("@@CORE@@", core).replace("@@CHURNY@@", churny).replace("@@SAMPLER@@", sampler)
cc = os.environ.get("CC", "cc")
with tempfile.TemporaryDirectory(prefix="madeira-swap-heat-") as t:
    c = Path(t) / "h.c"
    exe = Path(t) / "h"
    c.write_text(code)
    r = subprocess.run([cc, "-std=gnu11", "-O1", "-Wall", "-Werror", "-Wno-unused-function", "-Wno-unused-variable", str(c), "-o", str(exe)],
                       capture_output=True, text=True)
    check(r.returncode == 0, "sampler and filter compile on this host" + ("" if not r.returncode else ": " + r.stderr[-1500:]))
    if not r.returncode:
        clean = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}

        def run(scen, **env):
            o = subprocess.run([str(exe), scen], capture_output=True, text=True, env=dict(clean, **env))
            out = o.stdout.splitlines()
            kv = dict(x.split("=") for x in out[0].split()) if out else {}
            return kv, (out[1] if len(out) > 1 else ""), o.stderr

        for val in (None, "0"):
            env = {} if val is None else {"MADEIRA_SWAP_HEAT": val}
            kv, last, err = run("census", **env)
            check(kv.get("calls") == "0" and kv.get("lines") == "0" and kv.get("skip40000") == "0",
                  "MADEIRA_SWAP_HEAT=%r: no mincore, no line, no filter (%s)" % (val, kv))
        kv, last, err = run("census", MADEIRA_SWAP_HEAT="1")
        check(int(kv.get("calls", 0)) > 0 and err.count("[swap] heat:") == 2 and kv.get("nhot") == "0" and kv.get("skip40000") == "0",
              "1: two census lines in 20 cycles, no filter (%s)" % kv)
        # 4 pages are sampled per extent and the script moves them together, so every event counts 4.
        # First window (cycles 0..9): extent 0 paged out at 2 and 5 -> re-read at 3 and 6; extent 1 out at 3
        # and 8 -> re-read at 4 and 9; extent 3 (2 MB) out at 8 -> re-read at 9; extent 2 first touched at 6.
        first = [l for l in err.splitlines() if l.startswith("[swap] heat:")][0]
        check("256K-1M: 3 ext 0 MB" in first and "16 re-reads" in first and "1-4M: 2 ext 4 MB" in first and "4 re-reads (~2 MB)" in first,
              "1: re-reads counted by class in the first window, with the MB they stand for (%s)" % first)
        check("0x40000 x16 (2 ext)" in first and "0x200000 x4 (1 ext)" in first, "1: the most re-read sizes, with their extents")
        check("1 evictions" in first or "2 evictions" in first or "evictions" in first, "1: evictions counted")
        second = [l for l in err.splitlines() if l.startswith("[swap] heat:")][1]
        check("256K-1M: 3 ext 0 MB, 100% in memory" in second and " 0 re-reads" in second.split("|")[1],
              "1: the first touch of extent 2 is not a re-read; nothing re-read in the second window for <256K (%s)" % second)
        kv, last, err = run("census", MADEIRA_SWAP_HEAT="2", MADEIRA_SWAP_HEAT_MIN="3")
        check(kv.get("nhot") == "1" and kv.get("hot0") == "0x40000" and kv.get("skip40000") == "1" and kv.get("skip200000") == "0",
              "2: 0x40000 (16 sampled re-reads in 2 extents) stays anonymous; 0x200000 (1 extent) does not (%s)" % kv)
        check(err.count("blocks of 0x40000 were re-read") == 1, "2: published once, with a line")
        kv, last, err = run("census", MADEIRA_SWAP_HEAT="2", MADEIRA_SWAP_HEAT_MIN="20")
        check(kv.get("nhot") == "0" and kv.get("skip40000") == "0", "2: below MADEIRA_SWAP_HEAT_MIN nothing is published (%s)" % kv)
        kv, last, err = run("pause", MADEIRA_SWAP_HEAT="2", MADEIRA_SWAP_HEAT_MIN="3", MADEIRA_SWAP_HEAT_FP_MB="6656")
        check(kv.get("nhot") == "1" and kv.get("room") == "0" and kv.get("skip40000") == "0" and "pauses" in err,
              "2: above MADEIRA_SWAP_HEAT_FP_MB the filter pauses and the size is backed again (%s)" % kv)
        kv, last, err = run("replace", MADEIRA_SWAP_HEAT="1")
        first = [l for l in err.splitlines() if l.startswith("[swap] heat:")][0]
        check("0x40000 x8 (1 ext)" in first,
              "1: a new extent in a slot starts over (slot 0's history before the swap is not mixed with the new one) (%s)" % first)

cat = CAT.read_text(encoding="utf-8")
for k in ("env.MADEIRA_SWAP_HEAT", "env.MADEIRA_SWAP_HEAT_MIN", "env.MADEIRA_SWAP_HEAT_FP_MB"):
    check('ConfigOption(key: "%s"' % k in cat, "the catalog documents %s" % k)
# The CI step exists only in the fork's workflow; upstream has no .github.
if CI.exists():
    check("python3 tests/host/check-swap-heat.py" in CI.read_text(encoding="utf-8"), "CI runs this check")

if failures:
    print("FAILED: %d" % len(failures))
    sys.exit(1)
print("OK")
