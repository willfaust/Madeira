#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Russell Barton
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""env.MADEIRA_POOL_CARVE_MERGE = 1: free FEX code buffers merge, and a free one is cut to the size asked (virtual_ios.c pool-merge).

Without the switch a JIT-pool carve is cut once and never merged, so free carves that add up to hundreds of MB can still refuse
one large buffer, and a 16 KB request takes a whole free 16-32 MB carve. With it a buffer FEX releases merges with the free
carves on either side, and a free carve 1 MB or more larger than a request is cut so the request gets exactly its size.

Checks:
  1. the switch (ios_pool_carve_merge_enabled): only "1" turns it on, read at each call; where the source has the policy for
     the program being played (ios_pool_fg_class), env.MADEIRA_POOL_CODE_FOREGROUND = 1 turns it on as well;
  2. the pool-carve-merge-test region with the real EC_CODE allocation prefix (cap, lift, reuse and its cut), the real
     MEM_RELEASE carve block (and its merge) and the real exit retire, on a model of the pool (-Wall -Wextra -Werror, and
     ASan + UBSan): neighbours released in any order form one run with the latest release time; a dead process's carve stays
     apart until reused; region C and the pool never merge (C ends where the pool begins); 128 MB from a free 160 MB run is
     cut from its top (only that piece NOP-filled, the tail cursor untouched) and merges back; 16 KB takes 16 KB of a free
     32 MB carve; exactly 1 MB larger is cut, less is handed out whole, as with the carve table full; with the switch unset
     nothing merges and nothing is cut;
  3. wiring: the cut and the merge run under ios_tail_carve_lock; the catalog documents the key (off by default) and the
     session end clears it.
Not covered: fresh tail placement (a model: bump down from the pool's end, no holes); thread scans (stubs); the log text; the
policy for the program being played (check-pool-code-policy.py).
Needs python3 and a C compiler.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/virtual_ios.c").read_text()
cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc")
ok = True


def check(what, cond, detail=""):
    global ok
    print(("PASS: " if cond else "FAIL: ") + what + (("\n      " + str(detail)[-3000:]) if detail and not cond else ""))
    ok = ok and bool(cond)


def cut(text, start, end="\n}\n"):
    at = text.index(start)
    return text[at:text.index(end, at) + len(end)]


def define(name):
    return next(line for line in src.splitlines() if line.startswith("#define " + name + " ")) + "\n"


has_fg = "static int ios_pool_fg_class(" in src
begin, end = "/* pool-carve-merge-test:begin", "/* pool-carve-merge-test:end */"
region = src[src.index(begin):src.index(end) + len(end)] + "\n"
ec = src[src.index("size_t alloc_size = (*size_ptr + 0x3FFF) & ~0x3FFFUL;"):]
ec = ec[:ec.index("size_t reserve_offset, tail_added, tail_skipped = 0;")]
free_start = src.index("    if ((type & MEM_RELEASE) && ios_jit_rx_base_global && ios_jit_pool_size_global &&")
release_block = src[free_start:src.index("\n    }\n", src.index("/* pool address but not a live tail carve", free_start)) + 7]
carve_table = src[src.index("#define IOS_TAIL_CARVE_MAX "):]
carve_table = carve_table[:carve_table.index("\n\n")] + "\n"
helpers = "".join(cut(src, s) for s in (
    "static size_t ios_pool_hole_between(", "static size_t ios_pool_code_cap(", "int ios_jit_low_contains(",
    "static int ios_pool_low_take(", "static int ios_tail_carve_in_low(", "static int ios_pool_preserve_code_carve(", "static int ios_pool_preserve_big_carve(",
    "static int ios_tail_carve_ready(", "static unsigned ios_tail_carves_retire_owner(",
    "static int ios_tail_carve_foreign_release(", "static void ios_tail_carves_owner_died("))
merge_enabled = cut(src, "static int ios_pool_carve_merge_enabled(")
# The policy (check-pool-code-policy.py) is off here: the allocator asks for the caller's class and the hold rule.
fg_stub = ("enum { IOS_POOL_FG_OFF = 0, IOS_POOL_FG_OTHER = 1, IOS_POOL_FG_GAME = 2 };\n"
           "static int ios_pool_fg_class(void) { return IOS_POOL_FG_OFF; }\n" + define("IOS_POOL_OTHER_MAX") +
           define("IOS_POOL_FG_HOLD_SEC") + cut(src, "static int ios_pool_fg_held(")) if has_fg else ""

fixture = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <unistd.h>
#define MB ((size_t)1 << 20)
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "failed line %d: %s\n", __LINE__, #c); exit(1); } } while (0)
enum { STATUS_NO_MEMORY = -1, STATUS_SUCCESS = 0, FALLBACK_TAIL = 2, FALL_THROUGH = 3, MEM_RELEASE = 0x8000 };
#define POOL (512 * MB)
#define LOW (64 * MB)
''' + define("IOS_POOL_LOW_CARVE_MAX") + define("IOS_POOL_REUSE_GRACE_SEC") + r'''
static time_t fake_now;
static time_t fake_time(time_t *t) { if (t) *t = fake_now; return fake_now; }
#define time(t) fake_time(t)
static void *ios_jit_rx_base_global, *ios_jit_rw_base_global;
uintptr_t ios_jit_low_rx_global, ios_jit_low_rw_global;
size_t ios_jit_low_size_global;
static size_t ios_jit_pool_size_global, jit_pool_offset, ios_pool_head_reserve;
static volatile size_t ios_jit_low_reserved, ios_jit_tail_reserved;
static size_t ios_jit_hole_off_eff, ios_jit_hole_end_eff, ios_jit_hole2_off, ios_jit_hole2_end;
static int ios_jit_low_full_logged;
static unsigned ios_tail_carve_n;
static pthread_mutex_t ios_tail_carve_lock = PTHREAD_MUTEX_INITIALIZER;
''' + carve_table + r'''
static uintptr_t owner;
static void *ios_jit_current_peb(void) { return (void *)owner; }
static uintptr_t ios_wow_base(void) { return 0; }
static int ios_tail_carve_scan(const void *b, size_t s, int strict) { (void)b; (void)s; (void)strict; return 0; }
static int ios_tail_carve_occupied(const void *b, size_t s) { (void)b; (void)s; return 0; }
''' + fg_stub + helpers + region + merge_enabled + r'''
static int allocate(size_t *size_ptr, void **ret)
{
''' + ec + r'''
    (void)kept_big_carve;  /* read by the production tail path after this prefix */
    return FALLBACK_TAIL;   /* the production tail path starts after this prefix */
}
static int release(void *base, unsigned type, void **addr_ptr, size_t *size_ptr)
{
''' + release_block + r'''
    return FALL_THROUGH;
}

static char *pool, *low;
static size_t got;

/* Model of the tail path: a new carve right below the last one. */
static int tail_carve(size_t *size_ptr, void **ret)
{
    size_t size = (*size_ptr + 0x3fff) & ~(size_t)0x3fff;
    if (ios_jit_tail_reserved + size > POOL - jit_pool_offset) return STATUS_NO_MEMORY;
    ios_jit_tail_reserved += size;
    CHECK(ios_tail_carve_n < IOS_TAIL_CARVE_MAX);
    ios_tail_carves[ios_tail_carve_n++] = (struct ios_tail_carve){ .off = POOL - ios_jit_tail_reserved, .size = size,
                                                                   .peb = (void *)owner };
    *ret = pool + POOL - ios_jit_tail_reserved;
    *size_ptr = size;
    return STATUS_SUCCESS;
}
static void *ask(uintptr_t peb, size_t size)   /* one FEX request: the buffer, its size in `got` */
{
    void *rx = NULL;
    int status;
    owner = peb;
    if ((status = allocate(&size, &rx)) == FALLBACK_TAIL) status = tail_carve(&size, &rx);
    CHECK(status == STATUS_SUCCESS);
    got = size;
    return rx;
}
static void give_back(uintptr_t peb, void *rx, size_t size)   /* FEX's release of a buffer */
{
    void *addr = NULL;
    size_t freed = 0;
    owner = peb;
    CHECK(release(rx, MEM_RELEASE, &addr, &freed) == STATUS_SUCCESS && addr == rx && freed == size);
}
static size_t off_of(const void *rx) { return (size_t)((const char *)rx - pool); }
static struct ios_tail_carve *at(const void *rx)   /* the entry that starts at rx */
{
    unsigned i = 0;
    while (i < ios_tail_carve_n && ios_tail_carves[i].off != off_of(rx)) i++;
    CHECK(i < ios_tail_carve_n);
    return &ios_tail_carves[i];
}
static unsigned free_n(void)
{
    unsigned i, n = 0;
    for (i = 0; i < ios_tail_carve_n; i++) n += ios_tail_carves[i].free;
    return n;
}
static void consistent(size_t total)   /* no two entries overlap, no byte lost */
{
    unsigned i, j;
    size_t sum = 0;
    for (i = 0; i < ios_tail_carve_n; i++)
    {
        sum += ios_tail_carves[i].size;
        for (j = i + 1; j < ios_tail_carve_n; j++)
            CHECK(ios_tail_carves[j].off - ios_tail_carves[i].off >= ios_tail_carves[i].size &&
                  ios_tail_carves[i].off - ios_tail_carves[j].off >= ios_tail_carves[j].size);
    }
    CHECK(sum == total);
}
static void reset(int merge)
{
    ios_jit_low_rx_global = ios_jit_low_rw_global = (uintptr_t)low;
    ios_jit_low_size_global = ios_jit_low_reserved = LOW;   /* region C full: requests go to the carves and the tail */
    ios_jit_rx_base_global = ios_jit_rw_base_global = pool;
    ios_jit_pool_size_global = POOL;
    jit_pool_offset = 128 * MB;
    ios_pool_head_reserve = 48 * MB;
    ios_jit_tail_reserved = ios_tail_carve_n = 0;
    memset(ios_tail_carves, 0, sizeof(ios_tail_carves));
    fake_now = 1000;
    if (merge) setenv("MADEIRA_POOL_CARVE_MERGE", "1", 1);
    else unsetenv("MADEIRA_POOL_CARVE_MERGE");
}

static void switch_values(void)
{
    static const char *const values[] = { "1", "0", "", "11", "01", " 1", "1 ", "yes", "2" };
    unsigned k;
    unsetenv("MADEIRA_POOL_CARVE_MERGE");
    CHECK(!ios_pool_carve_merge_enabled());
    for (k = 0; k < sizeof(values) / sizeof(values[0]); k++)
    {
        setenv("MADEIRA_POOL_CARVE_MERGE", values[k], 1);
        CHECK(ios_pool_carve_merge_enabled() == !strcmp(values[k], "1"));
    }
    unsetenv("MADEIRA_POOL_CARVE_MERGE");
    CHECK(!ios_pool_carve_merge_enabled());
#if HAS_FG
    setenv("MADEIRA_POOL_CODE_FOREGROUND", "1", 1);
    setenv("MADEIRA_POOL_CARVE_MERGE", "0", 1);
    CHECK(ios_pool_carve_merge_enabled());
    for (k = 1; k < sizeof(values) / sizeof(values[0]); k++)
    {
        setenv("MADEIRA_POOL_CODE_FOREGROUND", values[k], 1);
        CHECK(!ios_pool_carve_merge_enabled());
    }
    unsetenv("MADEIRA_POOL_CODE_FOREGROUND");
#endif
    puts(HAS_FG ? "PASS: only \"1\" turns the merge on, read at each call; MADEIRA_POOL_CODE_FOREGROUND=1 turns it on as well"
                : "PASS: only \"1\" turns the merge on, read at each call");
}

/* Three 32 MB neighbours (and a live 16 MB one below) released in every order. */
static void neighbours(int merge)
{
    static const int order[6][3] = { {0, 1, 2}, {0, 2, 1}, {1, 0, 2}, {1, 2, 0}, {2, 0, 1}, {2, 1, 0} };
    unsigned k, i;
    for (k = 0; k < 6; k++)
    {
        void *b[3], *live;
        reset(merge);
        for (i = 0; i < 3; i++) b[i] = ask(7, 32 * MB);
        live = ask(7, 16 * MB);
        CHECK(off_of(b[2]) == POOL - 96 * MB && off_of(live) == POOL - 112 * MB);
        for (i = 0; i < 3; i++)
        {
            fake_now = 1000 + 10 * i;
            give_back(7, b[order[k][i]], 32 * MB);
            consistent(112 * MB);
            if (i == 1 && order[k][0] + order[k][1] == 2) CHECK(ios_tail_carve_n == 4);   /* 0 and 2: apart */
        }
        CHECK(ios_tail_carve_n == (merge ? 2u : 4u) && free_n() == ios_tail_carve_n - 1 && !at(live)->free);
        if (merge) CHECK(at(b[2])->free && at(b[2])->size == 96 * MB && at(b[2])->freed_at == 1020);
    }
    if (!merge) return;

    /* The run keeps the latest release time, whichever part had it; the moved last entry is followed. */
    reset(1);
    ios_tail_carves[0] = (struct ios_tail_carve){ .off = 48 * MB, .size = 16 * MB, .free = 1, .freed_at = 90 };
    ios_tail_carves[1] = (struct ios_tail_carve){ .off = 200 * MB, .size = 16 * MB, .peb = (void *)7 };
    ios_tail_carves[2] = (struct ios_tail_carve){ .off = 80 * MB, .size = 16 * MB, .free = 1, .freed_at = 70 };
    ios_tail_carves[3] = (struct ios_tail_carve){ .off = 64 * MB, .size = 16 * MB, .free = 1, .freed_at = 50 };
    ios_tail_carve_n = 4;
    i = ios_tail_carves_merge(ios_tail_carves, &ios_tail_carve_n, 3);
    CHECK(ios_tail_carve_n == 2 && i < 2 && ios_tail_carves[i].off == 48 * MB && ios_tail_carves[i].size == 48 * MB);
    CHECK(ios_tail_carves[i].free && ios_tail_carves[i].freed_at == 90 && !ios_tail_carves[1 - i].free);
    puts("PASS: neighbours released in any order form one run with the latest release time; a live one stays out");
}

static void dead_apart(void)
{
    void *a, *b, *c;
    reset(1);
    a = ask(8, 16 * MB);
    b = ask(7, 32 * MB);
    c = ask(8, 24 * MB);
    ios_tail_carves_owner_died((void *)8);            /* a and c: free, retired */
    give_back(7, b, 32 * MB);
    CHECK(ios_tail_carve_n == 3 && free_n() == 3 && at(a)->retired && at(c)->retired && at(b)->size == 32 * MB);
    fake_now += IOS_POOL_REUSE_GRACE_SEC;
    CHECK(ask(9, 16 * MB) == a && got == 16 * MB && !at(a)->retired && !at(a)->free);
    give_back(9, a, 16 * MB);                         /* FEX's own release: it merges */
    CHECK(ios_tail_carve_n == 2 && at(b)->free && at(b)->size == 48 * MB && at(c)->retired && at(c)->size == 24 * MB);
    consistent(72 * MB);
    puts("PASS: a dead process's carve stays apart; reused and released by FEX it merges");
}

static void region_c_edge(void)
{
    reset(1);
    ios_tail_carves[0] = (struct ios_tail_carve){ .off = (size_t)0 - 16 * MB, .size = 16 * MB, .peb = (void *)7 };
    ios_tail_carves[1] = (struct ios_tail_carve){ .off = 0, .size = 16 * MB, .peb = (void *)7 };
    ios_tail_carves[2] = (struct ios_tail_carve){ .off = (size_t)0 - 32 * MB, .size = 16 * MB, .peb = (void *)7 };
    ios_tail_carve_n = 3;
    CHECK(ios_tail_carve_in_low(ios_tail_carves[0].off) && !ios_tail_carve_in_low(0));
    give_back(7, pool, 16 * MB);
    give_back(7, pool - 16 * MB, 16 * MB);
    CHECK(ios_tail_carve_n == 3 && free_n() == 2);
    give_back(7, pool - 32 * MB, 16 * MB);
    CHECK(ios_tail_carve_n == 2 && at(pool - 32 * MB)->size == 32 * MB && at(pool)->size == 16 * MB && free_n() == 2);
    puts("PASS: region C's carves merge with each other, never with the pool's");
}

static void cuts(void)
{
    void *a, *b, *c;
    size_t tail;
    unsigned i;

    reset(1);
    a = ask(7, 32 * MB);
    b = ask(7, 128 * MB);
    give_back(7, a, 32 * MB);
    give_back(7, b, 128 * MB);
    CHECK(ios_tail_carve_n == 1 && at(b)->size == 160 * MB);
    tail = ios_jit_tail_reserved;
    memset((char *)b + 32 * MB - 4, 0x5a, 4);
    c = ask(8, 128 * MB);
    CHECK(c == (char *)b + 32 * MB && got == 128 * MB && ios_jit_tail_reserved == tail && ios_tail_carve_n == 2);
    CHECK(at(b)->free && at(b)->size == 32 * MB && !at(c)->free && at(c)->peb == (void *)8);
    CHECK(((uint32_t *)c)[0] == 0xd503201fu && ((uint32_t *)c)[32 * MB - 1] == 0xd503201fu &&
          ((uint32_t *)c)[-1] == 0x5a5a5a5au);    /* only the piece handed out is NOP-filled */
    give_back(8, c, 128 * MB);
    CHECK(ios_tail_carve_n == 1 && at(b)->size == 160 * MB);
    puts("PASS: 128 MB from a free 160 MB run is cut from its top, the tail cursor untouched, and merges back");

    reset(1);
    a = ask(7, 32 * MB);
    give_back(7, a, 32 * MB);
    CHECK(ask(8, 0x4000) == (char *)a + 32 * MB - 0x4000 && got == 0x4000 && at(a)->size == 32 * MB - 0x4000);
    reset(1);
    a = ask(7, 17 * MB);
    give_back(7, a, 17 * MB);
    CHECK(ask(8, 16 * MB) == (char *)a + MB && got == 16 * MB && at(a)->free && at(a)->size == MB);
    reset(1);
    a = ask(7, 17 * MB - 0x4000);
    give_back(7, a, 17 * MB - 0x4000);
    CHECK(ask(8, 16 * MB) == a && got == 17 * MB - 0x4000 && ios_tail_carve_n == 1);
    puts("PASS: 16 KB takes 16 KB of a free 32 MB carve; exactly 1 MB larger is cut, less than that is handed out whole");

    reset(1);
    for (i = 0; i < IOS_TAIL_CARVE_MAX - 1; i++)
        ios_tail_carves[i] = (struct ios_tail_carve){ .off = 256 * MB + i * 0x4000, .size = 0x4000, .peb = (void *)7 };
    ios_tail_carves[i] = (struct ios_tail_carve){ .off = 384 * MB, .size = 32 * MB, .free = 1 };
    ios_tail_carve_n = IOS_TAIL_CARVE_MAX;
    /* no cut without a free entry: Madeira's keep-big rule then applies as without the merge; with it off the whole carve goes */
    setenv("MADEIRA_POOL_CODE_KEEP_BIG", "0", 1);
    CHECK(ask(8, 0x4000) == pool + 384 * MB && got == 32 * MB && ios_tail_carve_n == IOS_TAIL_CARVE_MAX);
    unsetenv("MADEIRA_POOL_CODE_KEEP_BIG");
    puts("PASS: with the carve table full nothing is cut (MADEIRA_POOL_CODE_KEEP_BIG=0: the whole carve is handed out)");
}

static void unset(void)
{
    void *a, *b;
    neighbours(0);
    reset(0);
    a = ask(7, 32 * MB);
    b = ask(7, 128 * MB);
    give_back(7, a, 32 * MB);
    give_back(7, b, 128 * MB);
    CHECK(ios_tail_carve_n == 2);
    CHECK(ask(8, 32 * MB) == a && got == 32 * MB && ask(8, 128 * MB) == b && got == 128 * MB && ios_tail_carve_n == 2);
    puts("PASS: with the switch unset nothing merges and nothing is cut");
}

int main(void)
{
    void *p = NULL;
    CHECK(!posix_memalign(&p, 0x4000, LOW + POOL));
    low = p;
    pool = low + LOW;                               /* region C ends where the pool begins */
    switch_values();
    neighbours(1);
    dead_apart();
    region_c_edge();
    cuts();
    unset();
    free(p);
    return 0;
}
'''

# 1-2. the switch and the allocator, built twice: warnings as errors, then ASan + UBSan
if not cc:
    check("a C compiler for the host test", False)
else:
    with tempfile.TemporaryDirectory(prefix="madeira-pool-carve-merge-") as tmp:
        cfile = Path(tmp) / "pool-carve-merge.c"
        cfile.write_text(fixture)
        env = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_POOL_")}
        base = [cc, "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-DHAS_FG=%d" % has_fg, "-Wall", "-Wextra", "-Werror", "-pthread"]
        for name, flags in (("-Wall -Wextra -Werror, -O2", ["-O2"]),
                            ("ASan + UBSan", ["-O1", "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined",
                                              "-fno-omit-frame-pointer"])):
            exe = Path(tmp) / ("merge-" + flags[0].strip("-"))
            r = subprocess.run(base + flags + [str(cfile), "-o", str(exe)], capture_output=True, text=True)
            check(f"the fixture compiles ({name})", r.returncode == 0, r.stderr)
            if r.returncode == 0:
                r = subprocess.run([str(exe)], capture_output=True, text=True, env=env)
                print("".join(f"  [{name}] {line}\n" for line in r.stdout.splitlines()), end="")
                check(f"the scenarios pass ({name})", r.returncode == 0, r.stderr)

# 3. wiring
lock, unlock = "pthread_mutex_lock( &ios_tail_carve_lock );", "pthread_mutex_unlock( &ios_tail_carve_lock );"
reuse = ec[ec.index("retry_code_carve_reuse:"):]
use = reuse.index("ios_tail_carve_cut( ios_tail_carves, &ios_tail_carve_n, IOS_TAIL_CARVE_MAX, best, alloc_size );")
hand_out = reuse.index("if (best != ~0u)\n")
check("the cut runs where the reuse path hands a carve out, under the carve lock, once",
      ec.count("ios_tail_carve_cut(") == 1 and reuse.index(lock) < hand_out < use < reuse.index(unlock, hand_out))
use = release_block.index("ios_tail_carves_merge( ios_tail_carves, &ios_tail_carve_n, i );")
check("the merge runs in the release under the carve lock, once, after the carve is marked free",
      release_block.count("ios_tail_carves_merge(") == 1 and
      release_block.index(lock) < release_block.index("ios_tail_carves[i].free = 1;") < use < release_block.index(unlock))
gen = (root / "build/tools/gen-config-catalog.py").read_text()
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
bridge = (root / "app/Madeira/WineProcessBridge.m").read_text()
check("the catalog documents the key, off by default; the session end clears it",
      re.search(r'"env\.MADEIRA_POOL_CARVE_MERGE": \{[^}]*"default": "0"', gen) is not None
      and re.search(r'key: "env\.MADEIRA_POOL_CARVE_MERGE"[^\n]*defaultValue: "0"', cat) is not None
      and 'unsetenv("MADEIRA_POOL_CARVE_MERGE");' in bridge)
print("PASS: pool-carve-merge" if ok else "FAILED: pool-carve-merge")
sys.exit(0 if ok else 1)
