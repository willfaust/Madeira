#!/usr/bin/env python3
"""[pool-tail-for-head]: a free FEX code-buffer carve goes to the head when an image copy or an anon RWX page would fail.

Wave 33 (Battle.net + StarCraft): five 128 MB "tail BIG" grants plus 16 MB ones put the tail at 0x294b4000 of the
0x374a8000 pool (its 3/4 ceiling), the head had 0x94000 left, and POWRPROF.dll ("Required library ... does not exist")
and ClientSdk's 1.5 MB RWX page failed "EXHAUSTED" while the dead helpers' code buffers sat free in ios_tail_carves.
The head allocators only read the head freelist, so the space was idle. build/ntdll-unix/virtual_ios.c now, before either
failure is reported, moves the smallest eligible free carve to the head freelist (ios_pool_tail_for_head) and retries once.

Checks, without a device:
  - the carve picker (compiled and run against the real struct and ios_tail_carve_ready): smallest free carve that fits,
    retired ones only after the reuse grace, never a live one, never region C (wrapping offset) or one that leaves the pool,
    skips offsets already refused, refuses sizes it cannot hold;
  - both failure sites (anon RWX, image) call the census once and then ios_pool_tail_for_head, retry exactly once, and the
    image site tries it after the existing recycle attempts and before "[jit-pool] EXHAUSTED (image";
  - ios_pool_tail_for_head: switch exactly "0", eligibility checks (grace via the picker, executable throughout, strict thread
    scan), carve lock then pool lock, removal from the table only when the freelist put (or the tail_resv CAS) succeeded,
    tail_resv only lowered by CAS for the lowest carve of an unsplit pool and then no freelist entry;
  - the BIG bound is off unless MADEIRA_POOL_BIG_MAX is 1..16, sits before the fresh carve, after the free-carve reuse;
  - the log lines exist (capped at 32 / 16).
Needs python3 and a C compiler.
"""
from pathlib import Path
import os, re, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/virtual_ios.c').read_text()

def between(a, b, frm=0):
    i = src.index(a, frm)
    return src[i:src.index(b, i)], i

# --- the helpers --------------------------------------------------------------
struct_txt, _ = between('struct ios_tail_carve\n{', '};\nstatic struct ios_tail_carve ios_tail_carves[')
struct_txt += '};\n'
ready_txt, _ = between('static int ios_tail_carve_ready(', '\n}\n')
ready_txt += '\n}\n'
pick_txt, _ = between('static unsigned ios_pool_pick_carve_for_head(', '\n}\n')
pick_txt += '\n}\n'
take_txt, take_at = between('static int ios_pool_tail_for_head(', '\n}\n')
census_txt, _ = between('static void ios_tail_carve_census_once(', '\n}\n')
big_txt, _ = between('static int ios_pool_big_max(void)', 'static int ios_pool_big_live_at_limit')
enabled_txt, _ = between('static int ios_tail_for_head_enabled(void)', '\n}\n')
enabled_txt += '\n}\n'

assert 'e[0] == \'0\' && !e[1]' in enabled_txt and 'MADEIRA_POOL_TAIL_FOR_HEAD' in enabled_txt

# --- ios_pool_tail_for_head's own rules ------------------------------------------
for need in ('ios_tail_for_head_enabled()', 'ios_pool_pick_carve_for_head( ios_tail_carves', 'ios_pool_recycle_range_ready( off, size )',
             'ios_tail_carve_scan( (char *)ios_jit_rx_base_global + off, size, 1 )', 'ios_pool_live_overlap(',
             'ios_pool_free_put( ios_pool_freelist', 'ios_wow_base()', '[pool-tail-for-head] #%d took carve off=0x%lx size=0x%lx for want=0x%lx',
             '<= 32', '<= 16', 'attempt < 8'):
    assert need in take_txt, need
assert take_txt.index('pthread_mutex_lock( &ios_tail_carve_lock )') < take_txt.index('pthread_mutex_lock( &ios_pool_lock )'), 'lock order carve -> pool'
assert take_txt.index('ios_pool_free_put(') < take_txt.rindex('ios_tail_carves[best] = ios_tail_carves[--ios_tail_carve_n];'), 'removed after the put succeeded'
assert take_txt.count('ios_tail_carves[best] = ios_tail_carves[--ios_tail_carve_n];') == 2
# tail_resv: only the lowest carve of an unsplit pool, by CAS, and then no freelist entry
low = take_txt[take_txt.index('if (ios_jit_hole_end <= ios_jit_hole_off'):take_txt.index('else\n        {\n            size_t live_off;')]
for need in ('ios_jit_hole_end <= ios_jit_hole_off', 'off == ios_jit_pool_size_global - tail_now', '__sync_bool_compare_and_swap( &ios_jit_tail_reserved, tail_now, tail_now - size )', 'lowered = 1'):
    assert need in low, need
assert 'ios_pool_free_put' not in low
for need in ('MADEIRA_POOL_TAIL_FOR_HEAD', 'NOT lowered when the carve goes to the freelist'):
    assert need in src, need

# --- the two failure sites + the census -------------------------------------------
anon = src[src.index('size_t offset = ios_pool_alloc_range(alloc_size, jit_pool_size - ios_jit_tail_reserved);'):]
anon = anon[:anon.index('mprotect( base, size, PROT_READ );')]
assert anon.count('ios_pool_tail_for_head( alloc_size, "anon RWX" )') == 1 and anon.count('ios_pool_alloc_range(alloc_size') == 2
assert anon.index('ios_tail_carve_census_once( "anon RWX", alloc_size )') < anon.index('ios_pool_tail_for_head(') < anon.index('EXHAUSTED (anon RWX)')
img_at = src.index('ios_pool_recycle_code_range( alloc_size ))\n                    offset = ios_pool_alloc_range_tagged')
img = src[img_at:src.index('EXHAUSTED (image')]
assert img.count('ios_pool_tail_for_head( alloc_size, "image" )') == 1 and img.count('ios_pool_alloc_range_tagged(alloc_size') == 2
assert img.index('ios_tail_carve_census_once( "image", alloc_size )') < img.index('ios_pool_tail_for_head(')
assert 'if (offset == (size_t)-1)\n                {\n                    /* pool-tail-for-head' in img
for need in ('__sync_lock_test_and_set( &done, 1 )', 'live=%u', 'free=%u', 'retired by an exited process', 'largest_free'):
    assert need in census_txt + src, need
assert census_txt.count('pthread_mutex_lock( &ios_tail_carve_lock )') == 1 and 'ios_pool_lock' not in census_txt

# --- the BIG bound ----------------------------------------------------------------
assert 'v >= 1 && v <= 16' in big_txt and 'max = 0;' in big_txt
bound_at = src.index('if (ios_pool_big_refuse( alloc_size )) return STATUS_NO_MEMORY;')
assert src.index('tail REUSE rx=%p') < src.index('size_t reserve_offset, tail_added, tail_skipped = 0;') < bound_at, 'bound sits after the free-carve reuse and the fresh-carve declarations (outside the EC allocation block other host checks extract)'
assert bound_at < src.index('reserve_offset = __sync_fetch_and_add(&ios_jit_tail_reserved, alloc_size);') and bound_at < src.index('} while (!__sync_bool_compare_and_swap( &ios_jit_tail_reserved, cur, start + alloc_size ));'), 'and before either way of taking the tail bytes'
refuse = src[src.index('static int ios_pool_big_refuse('):]
refuse = refuse[:refuse.index('\n}\n')]
assert 'alloc_size <= 0x1000000' in refuse and 'ios_pool_big_live_at_limit()' in refuse and '<= 16' in refuse and 'MADEIRA_POOL_BIG_MAX' in refuse
live = src[src.index('static int ios_pool_big_live_at_limit(void)'):]
live = live[:live.index('\n}\n')]
assert 'max <= 0) return 0' in live and '!ios_tail_carves[i].free && ios_tail_carves[i].size > 0x1000000' in live and 'ios_tail_carve_in_low' in live

# --- compile the picker and exercise it -----------------------------------------------
prog = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define IOS_POOL_REUSE_GRACE_SEC 3
''' + struct_txt + ready_txt + pick_txt + r'''
#define MB (1024ul * 1024)
int main(void) {
    const size_t pool = 0x374a8000ul;
    time_t now = 1000000;
    struct ios_tail_carve c[8];
    size_t skip[4] = { 0, 0, 0, 0 };
    memset(c, 0, sizeof(c));
    c[0] = (struct ios_tail_carve){ .off = 0x10000000, .size = 16 * MB, .free = 0 };                                   /* live */
    c[1] = (struct ios_tail_carve){ .off = 0x20000000, .size = 128 * MB, .free = 1, .retired = 1, .freed_at = now };   /* just retired: in grace */
    c[2] = (struct ios_tail_carve){ .off = 0x28000000, .size = 64 * MB, .free = 1, .retired = 1, .freed_at = now - 10 };
    c[3] = (struct ios_tail_carve){ .off = 0x2c000000, .size = 32 * MB, .free = 1, .retired = 0 };                     /* FEX-released */
    c[4] = (struct ios_tail_carve){ .off = (size_t)0 - 0x8000000ul, .size = 16 * MB, .free = 1, .retired = 1, .freed_at = 1 }; /* region C: wraps */
    c[5] = (struct ios_tail_carve){ .off = 0x30000000, .size = 0x4000, .free = 1, .retired = 0 };
    c[6] = (struct ios_tail_carve){ .off = 0x30004000, .size = 0x4000 * 3 + 1, .free = 1, .retired = 0 };              /* unaligned size */
    c[7] = (struct ios_tail_carve){ .off = pool - 8 * MB, .size = 16 * MB, .free = 1, .retired = 0 };                  /* leaves the pool */
    if (ios_pool_pick_carve_for_head(c, 8, now, 0x180000, pool, skip, 0) != 3) return 1;      /* smallest that fits: 32 MB, not 64 */
    if (ios_pool_pick_carve_for_head(c, 8, now, 40 * MB, pool, skip, 0) != 2) return 2;       /* 64 MB; the 128 MB one is in grace */
    if (ios_pool_pick_carve_for_head(c, 8, now, 100 * MB, pool, skip, 0) != ~0u) return 3;     /* only the in-grace one is big enough */
    if (ios_pool_pick_carve_for_head(c, 8, now + 4, 100 * MB, pool, skip, 0) != 1) return 4;   /* grace over */
    if (ios_pool_pick_carve_for_head(c, 8, now, 0x4000, pool, skip, 0) != 5) return 5;        /* exact size */
    skip[0] = 0x2c000000;
    if (ios_pool_pick_carve_for_head(c, 8, now, 0x180000, pool, skip, 1) != 2) return 6;      /* skips the one already refused */
    skip[1] = 0x28000000;
    if (ios_pool_pick_carve_for_head(c, 8, now, 0x180000, pool, skip, 2) != ~0u) return 7;
    if (ios_pool_pick_carve_for_head(c, 8, now, 0, pool, skip, 0) != ~0u) return 8;            /* want 0 */
    if (ios_pool_pick_carve_for_head(c, 8, now, 12 * MB, pool, skip, 0) != 3) return 9;        /* 16 MB region-C and 16 MB out-of-pool never chosen */
    c[3].free = 0;
    if (ios_pool_pick_carve_for_head(c, 8, now, 20 * MB, pool, skip, 0) != 2) return 10;       /* a live carve is never taken */
    puts("ok");
    return 0;
}
'''
with tempfile.TemporaryDirectory() as d:
    c = Path(d, 't.c'); c.write_text(prog)
    exe = Path(d, 't')
    subprocess.run([os.environ.get('CC', 'cc'), '-Wall', '-Werror', '-o', str(exe), str(c)], check=True)
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout.strip() == 'ok', ('picker test failed', r.returncode, r.stdout)
    # the switches: only "0" turns tail-for-head off; the BIG bound is on only for 1..16
    harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char *g_env;
static char *stub_getenv(const char *n) { return (char *)g_env; }
#define getenv stub_getenv
''' + enabled_txt + '\nstatic int ios_pool_big_max_unused(void){return 0;}\n'
    for val, want in (('0', 0), ('1', 1), ('', 1), ('00', 1), (None, 1)):
        c2 = Path(d, 's.c')
        c2.write_text(harness + 'int main(void){ g_env = %s; return ios_tail_for_head_enabled() == %d ? 0 : 1; }'
                      % ('NULL' if val is None else '"%s"' % val, want))
        subprocess.run([os.environ.get('CC', 'cc'), '-w', '-o', str(Path(d, 's')), str(c2)], check=True)
        assert subprocess.run([str(Path(d, 's'))]).returncode == 0, ('tail-for-head switch', val)
    bigh = r'''
#include <stdio.h>
#include <stdlib.h>
static const char *g_env;
static char *stub_getenv(const char *n) { return (char *)g_env; }
#define getenv stub_getenv
''' + big_txt.rstrip() + '\n'
    for val, want in ((None, 0), ('', 0), ('0', 0), ('1', 1), ('2', 2), ('16', 16), ('17', 0), ('x', 0), ('2x', 0), ('-1', 0)):
        c3 = Path(d, 'b.c')
        c3.write_text(bigh + 'int main(void){ g_env = %s; return ios_pool_big_max() == %d ? 0 : 1; }'
                      % ('NULL' if val is None else '"%s"' % val, want))
        subprocess.run([os.environ.get('CC', 'cc'), '-w', '-o', str(Path(d, 'b')), str(c3)], check=True)
        assert subprocess.run([str(Path(d, 'b'))]).returncode == 0, ('BIG_MAX', val)

print('check-pool-tail-for-head: ok')
