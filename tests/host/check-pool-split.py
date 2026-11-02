#!/usr/bin/env python3
"""Split JIT pool (pool-split = 1) and POISONED-range salvage in virtual_ios.c; no Wine runs.

GTA V Enhanced on an iPhone 17 Pro Max (logs 2026-10-02 16:00 / 16:19 / 16:33): the
low band [0x148000000, 0x180000000) is split by the main thread's stack, the pool shrank
to the 592-631 MB below it and Social Club's 240 MB libcef.dll copy no longer fit. With
pool-split the app adds the 258-325 MB run above the stack as a second debugger region,
aliased as one span; WINE_IOS_JIT_HOLE names the part in between, which ntdll must never
hand out.

Compiles the production helpers from build/ntdll-unix/virtual_ios.c
(ios_pool_hole_head_place, ios_pool_hole_tail_start, ios_pool_hole_between,
IOS_POOL_IN_HOLE, ios_pool_tail_unreserve, ios_pool_execable_runs) and checks:
  - without a hole every helper is the identity of the old code;
  - a randomized head/tail allocation model built from them never hands out a byte of
    the hole and never overlaps two live ranges, with and without a split;
  - a refused carve that jumped the hole gives its reservation back only while no later
    carve sits on top of it; unsplit it is the old fetch-and-sub;
  - the executable runs of a POISONED range: the 16 KB RW pages are cut out, runs under
    64 KB and unmapped gaps are dropped, a nonsense region answer stops the walk;
and textually: the bump, the warmer, the tail carve, the BIG cap, the pool init and the
POISONED branch use them; the app sets WINE_IOS_JIT_HOLE only for a split pool.
The big-image slot (env MADEIRA_POOL_BIG_SLOT_MB, GTA V Enhanced build 373, 2026-10-04
08:41: 469 MB of per-process DLL copies + 112 MB of FEX code left no 240 MB run for
libcef.dll in either part): the bump and the tail treat the slot as part of the hole
(ios_jit_hole_end_eff), the warmer does not, one image of 64 MB or more takes the slot,
and the reclaim gives it back instead of putting it on the freelist; modelled with the
build 373 sizes, where libcef.dll fails without the slot and fits with it.
Needs python3 and a C compiler (AddressSanitizer/UBSan).
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
swift = (root / 'app/Madeira/StikJITHelper.swift').read_text()
content = (root / 'app/Madeira/ContentView.swift').read_text()


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


helpers = ''.join(function(native, sig) for sig in (
    'static size_t ios_pool_hole_head_place(',
    'static size_t ios_pool_hole_tail_start(',
    'static size_t ios_pool_hole_between(',
    'static size_t ios_pool_holes_head_place(',
    'static size_t ios_pool_holes_tail_start(',
    'static size_t ios_pool_holes_between(',
    'static int ios_pool_skip_pieces(',
    'static void ios_pool_tail_unreserve(',
))
macro = native[native.index('#define IOS_POOL_IN_HOLE(o)'):]
macro = macro[:macro.index('\n', macro.index('\\\n') + 2) + 1]   # pool-mid: two lines, both holes
runs_typedef = native[native.index('typedef int (*ios_pool_region_fn)'):]
runs_typedef = runs_typedef[:runs_typedef.index(';') + 1] + '\n'
runs = function(native, 'static int ios_pool_execable_runs(')

# --- call sites ---------------------------------------------------------------
bump = native[native.index('/* madeira-bcd split pool: never into a hole (ios_jit_hole_off, pool-mid'):][:3200]
assert ('ios_pool_holes_head_place( jit_pool_offset, alloc_size,\n'
        '                                                 ios_jit_hole_off_eff, ios_jit_hole_end_eff,\n'
        '                                                 ios_jit_hole2_off, ios_jit_hole2_end );') in bump
assert native.count('ios_pool_holes_head_place( jit_pool_offset, alloc_size, ios_jit_hole_off_eff, ios_jit_hole_end_eff,') == 2
assert 'ios_pool_hole_head_place( jit_pool_offset' not in native, 'every placement takes both holes'
assert ('ios_pool_skip_pieces( jit_pool_offset, cand, ios_jit_hole_off_eff, ios_jit_hole_end_eff,\n'
        '                                               ios_jit_hole2_off, ios_jit_hole2_end, poff, psz )') in bump, \
    'the leftover freelist ranges exclude a lower image slot and both holes'
assert 'ios_jit_hole_end );' not in native.replace('ios_jit_hole_end_eff );', ''), 'no placement uses the bare hole end'
assert ('#define IOS_POOL_IN_HOLE(o) ((size_t)(o) - ios_jit_hole_off < ios_jit_hole_end - ios_jit_hole_off || \\\n'
        '                             (size_t)(o) - ios_jit_hole2_off < ios_jit_hole2_end - ios_jit_hole2_off)') in native, \
    'the warmer still warms the slot and skips both native holes'
slot_alloc = native[native.index('/* madeira-bcd: the big-image slot (ios_pool_big_off), once it is free and'):][:1500]
assert 'pool_limit && ios_pool_big_size && !ios_pool_big_taken && alloc_size >= IOS_POOL_BIG_MIN' in slot_alloc
assert 'now - ios_pool_big_freed_at >= IOS_POOL_REUSE_GRACE_SEC' in slot_alloc
assert 'if (pool_limit && off == (size_t)-1)' in native and 'if (off == (size_t)-1 && (alloc_size >= 32u * 1024 * 1024 || bump_short))' in native
assert 'while (off == (size_t)-1 &&\n           (i = ios_pool_best_fit(' in native, 'the slot skips the freelist'
reclaim = function(native, 'void ios_jit_reclaim_process( void *peb )')
slot_free = reclaim[reclaim.index('if (ios_pool_big_size && off < ios_pool_big_off + ios_pool_big_size'):][:700]
assert 'ios_pool_big_taken = 0;' in slot_free and 'ios_pool_big_freed_at = time( NULL );' in slot_free
assert 'ios_pool_ledger[i] = ios_pool_ledger[--ios_pool_ledger_count];\n            continue;' in slot_free
assert reclaim.index('if (ios_pool_big_size && off <') < reclaim.index('ios_pool_free_put( ios_pool_freelist'), \
    'the slot is given back before the freelist would take it'
big_init = native[native.index('const char *big = getenv( "MADEIRA_POOL_BIG_SLOT_MB" );'):][:3500]
assert 'ios_pool_big_layout( jit_pool_size, ios_jit_hole_off,' in big_init
assert 'ios_pool_big_off = slot;' in big_init and 'ios_jit_hole_end_eff = skip_end;' in big_init
assert 'ios_jit_hole_off_eff = skip_off;' in big_init
assert native.index('ios_jit_hole_end_eff = (size_t)h1;') < native.index('const char *big = getenv( "MADEIRA_POOL_BIG_SLOT_MB" );')
assert 'jit_pool_offset = cand + alloc_size;' in bump
assert 'ios_pool_freelist[ios_pool_free_count].off = poff[k];' in bump

warmer = function(native, 'static void *ios_pool_warmer_thread(')
assert warmer.count('if (IOS_POOL_IN_HOLE(o)) continue;') == 4, 'all four warmer loops skip the hole'

tail = native[native.index('size_t reserve_offset, tail_added, tail_skipped = 0;'):][:16000]
assert 'ios_pool_holes_tail_start( ios_jit_pool_size_global, cur, alloc_size,' in tail
# two rollbacks of a refused tail, plus the tail-carve exec check's refusal (MADEIRA_TAIL_CARVE_EXEC_CHECK=0 skips it)
assert tail.count('ios_pool_tail_unreserve( &ios_jit_tail_reserved, reserve_offset + alloc_size, tail_added,') == 3
carve_check = tail[tail.index('if (carve_check &&'):][:1800]
assert 'ios_pool_tail_unreserve( &ios_jit_tail_reserved, reserve_offset + alloc_size, tail_added,' in carve_check \
    and 'return STATUS_NO_MEMORY;' in carve_check, 'the exec-check refusal rolls the tail back the same way'
assert '__sync_fetch_and_sub(&ios_jit_tail_reserved' not in tail, 'every rollback goes through ios_pool_tail_unreserve'
assert 'ios_tail_carves[ios_tail_carve_n].off = skip_off[k];' in tail
assert ('ios_jit_hole_off_eff, ios_jit_hole_end_eff,\n'
        '                                                   ios_jit_hole2_off, ios_jit_hole2_end );') in tail, \
    'the tail jumps either slot placement with the hole, and the second hole'
assert ('ios_pool_skip_pieces( ios_jit_pool_size_global - start, ios_jit_pool_size_global - cur,') in tail
assert 'if (skip_size[k] < 0x100000 || ios_tail_carve_n >= IOS_TAIL_CARVE_MAX) continue;' in tail

cap = native[native.index('enum { TAIL_SMALL = 0x1000000 };'):][:2200]
assert 'ios_pool_code_cap( ios_jit_pool_size_global, head_now, tail_now,' in cap
assert ('ios_jit_hole_off_eff, ios_jit_hole_end_eff,\n'
        '                                            ios_pool_head_reserve +\n'
        '                                            ios_pool_hole_between( ios_jit_pool_size_global, head_now, tail_now,\n'
        '                                                                   ios_jit_hole2_off, ios_jit_hole2_end ) );') in cap, \
    'the second hole is not room for code either'
assert 'if (alloc_size > cap && !low_fits)' in cap, 'region C still bypasses the tail cap'

init = native[native.index('const char *hole = getenv( "WINE_IOS_JIT_HOLE" );'):][:1400]
init2 = native[native.index('const char *hole2 = getenv( "WINE_IOS_JIT_HOLE2" );'):][:1200]
assert ('if (ios_jit_hole_end > ios_jit_hole_off && h0 >= ios_jit_hole_end + 0x4000 &&\n'
        '                            h1 > h0 && h1 < jit_pool_size && !(h0 & 0x3fff) && !(h1 & 0x3fff))') in init2, \
    'a second hole only above a valid first one, with a third region between them'
assert 'ios_jit_hole2_off = (size_t)h0;' in init2 and 'ios_jit_hole2_end = (size_t)h1;' in init2
assert native.index('ios_jit_hole_end = (size_t)h1;') < native.index('const char *hole2 = getenv( "WINE_IOS_JIT_HOLE2" );') \
    < native.index('const char *big = getenv( "MADEIRA_POOL_BIG_SLOT_MB" );'), 'hole 1, then hole 2, then the slot'
assert ('if (big && *big && strtoul( big, NULL, 10 ) && ios_jit_hole2_end > ios_jit_hole2_off)') in native, \
    'the big-image slot is laid out against one hole: refused with two'
assert 'h1 < jit_pool_size' in init and '!(h0 & 0x3fff) && !(h1 & 0x3fff)' in init
assert 'ios_jit_hole_off = (size_t)h0;' in init and 'ios_jit_hole_end = (size_t)h1;' in init
assert native.index('ios_jit_pool_size_global = jit_pool_size;') < native.index('const char *hole = getenv( "WINE_IOS_JIT_HOLE" );')

poisoned = native[native.index('if (!ios_pool_range_execable( ios_pool_freelist[i].off,'):][:2400]
assert 'ios_pool_execable_runs( (uint64_t)(uintptr_t)ios_jit_rx_base_global, bad.off, bad.size,' in poisoned
assert '(bad.advised & 2) ? 0' in poisoned, 'a salvaged run found poisoned again is dropped whole'
assert 'ios_pool_freelist[ios_pool_free_count].advised = bad.advised | 2;' in poisoned
print('PASS: bump, warmer, tail carve, BIG cap, pool init and the POISONED branch use the helpers')

assert 'MadeiraConfig.gameValue("pool-split") ?? MadeiraConfig.get("pool-split")' in swift
assert 'if poolSize >= requestedPoolSize {' in swift, 'no split when the pool got its full size'
assert 'poolHole = bOff > aSize ? (off: aSize, end: bOff) : nil' in swift
assert swift.count('splitHoles(aSize: poolSize, bOff: holeEnd, rxBase: rxAddrV)') == 2
assert 'VM_FLAGS_OVERWRITE' in swift and 'rw + (rxB - rxA)' in swift, 'one RW alias, one RX->RW distance'
assert 'gapHitsWindow' in swift, 'the hole may never hold the executable window'
hole_env = content[content.index('if let hole = StikJITHelper.poolHole {'):][:300]
assert 'setenv("WINE_IOS_JIT_HOLE", String(format: "%lx:%lx", hole.off, hole.end), 1)' in hole_env
assert 'unsetenv("WINE_IOS_JIT_HOLE")' in hole_env
print('PASS: the app splits only on request and exports WINE_IOS_JIT_HOLE only for a split pool')

# pool-mid (RDR2 build 470, 14:33: a 71 MB mapping at image load cut the pool to 285 + 319 MB
# around 213 MB of free space; d3dcompiler_47.dll found no room, ERR_GFX_INIT)
def swift_func(signature):
    start = swift.index(signature)
    return swift[start:swift.index('\n    }\n', start) + 7]


take = swift_func('private static func takeSecondRegion(')
mid_take = take[take.index('poolMid = nil'):take.index('// PROT_NONE placeholders over the free gaps between the regions.')]
assert 'MadeiraConfig.gameValue("pool-mid") ?? MadeiraConfig.get("pool-mid")' in mid_take
assert '["1", "on", "true", "yes"].contains(midText)' in mid_take, 'pool-mid is opt-in (GTA never gets it)'
assert 'let midBudget = want - Int(size)' in mid_take and 'midBudget >= 64 << 20' in mid_take, \
    'M only from what A and B left of the requested size'
assert 'freeRuns(aEnd, b, minSize: 64 << 20).max(by: { $0.size < $1.size })' in mid_take, 'M only between the regions'
assert 'freeRuns(0x100000000, run.base, minSize: msize)' in mid_take and 'mplugs.append(' in mid_take, \
    'every lower run that could take M is plugged (first-fit)'
assert 'if m >= run.base && m + msize <= run.base + run.size {' in mid_take, 'a stray M is released'
assert take.index('poolMid = nil') > take.index('let b = vm_address_t(bitPattern: p)'), 'M only after B is placed'
assert 'VM_FLAGS_OVERWRITE' not in mid_take
assert swift.index('poolMid = nil   // pool-mid') < swift.index('var pairSecond: (base: vm_address_t, size: vm_address_t)? = nil'), \
    'reset before pool-pair, which takes B (and M) early'
assert swift.count('poolMid = nil') == 4
holes = swift_func('private static func splitHoles(')
assert 'poolHole = below ?? above' in holes and 'poolHole2 = below == nil ? nil : above' in holes
assert swift.count('"pool-RW-alias-mid"') == 2, 'M gets its own no-footprint request'
assert 'if let mid = poolMid { lowRegions.append((rx: mid.base, size: mid.size)) }' in swift, 'C, A, M, B with region C'
assert ("rwSplit = mapLowAlias([(rx: rxAddrV, size: vm_address_t(poolSize)), (rx: mid.base, size: mid.size),\n"
        "                                           (rx: second.base, size: second.size)], tag: \"[pool-mid]\")") in swift
released = swift[swift.index('if rwSplit == nil {\n                        let dkr'):][:400]
assert 'vm_deallocate(mach_task_self_, mid.base, vm_size_t(mid.size))' in released and 'poolMid = nil' in released, \
    'a failed three-region alias gives M back and maps A and B as before'
gone = swift[swift.index('the pool stays \\(poolSize >> 20)MB in one region", level: .error)'):][:300]
assert 'vm_deallocate(mach_task_self_, mid.base, vm_size_t(mid.size))' in gone, 'M goes with B'
hole2_env = content[content.index('if let hole2 = StikJITHelper.poolHole2 {'):][:300]
assert 'setenv("WINE_IOS_JIT_HOLE2", String(format: "%lx:%lx", hole2.off, hole2.end), 1)' in hole2_env
assert 'unsetenv("WINE_IOS_JIT_HOLE2")' in hole2_env
assert content.index('if let hole = StikJITHelper.poolHole {') < content.index('if let hole2 = StikJITHelper.poolHole2 {')
allocator = (root / 'app/Madeira/JITAllocator.c').read_text()
assert 'vm_address_t ra = win + winsz + (vm_address_t)madeira_early_pool_size;' in allocator, \
    'the mapping the placeholder ran into is recorded too'
assert 'ml1135: the placeholder ended at the mapping' in swift
print('PASS: pool-mid takes the largest free run between the regions as region M after B, aliases A, M and B in one '
      'reservation (M given back on failure) and exports WINE_IOS_JIT_HOLE2 only with M')

# pool-pair (GTA build 364, 21:00 / 23:47): two runs above the window instead of the 464 MB hole below it
pair = swift[swift.index('let pairOff = '):swift.index('if pairA == nil && largest < vm_address_t(poolSize) {')]
assert 'MadeiraConfig.gameValue("pool-pair")' in pair and 'MadeiraConfig.get("pool-pair")' in pair
assert '.contains(splitValue) && windowHeld && !pairOff' in pair, 'pool-pair needs pool-split and the held window'
assert 's.base + s.size <= exeWinBase' in pair, 'only when the single-region pool would land below the window'
assert 'aFit + bFit > best' in pair, 'only when the pair beats the single run'
assert 'freeRuns(0x100000000, pa.base, minSize: pa.size)' in pair and 'plugs.append(' in pair
assert swift.count('if pairA == nil && earlyPoolBase != 0 && windowHeld') == 2, 'ml1040 steering is off in pair mode'
check = swift[swift.index('var pairSecond: (base: vm_address_t, size: vm_address_t)? = nil'):swift.index('guard let rxPtr = rxPtrOpt else {')]
assert 'if got == pa.base {' in check and 'pairSecond = takeSecondRegion(' in check
assert 'jit26_prepare_region(nil, pairSingle)' in check, 'a missed pair falls back to the single-region size'
assert 'pairSecond ?? takeSecondRegion(' in swift
print('PASS: pool-pair takes two runs above the window only with pool-split, and falls back on a miss')

harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
static size_t ios_jit_hole_off, ios_jit_hole_end;
static size_t ios_jit_hole2_off, ios_jit_hole2_end;
''' + macro + helpers + runs_typedef + runs + r'''
#define MB ((size_t)1 << 20)
#define FAIL(...) do { fprintf(stderr, __VA_ARGS__); exit(1); } while (0)

/* --- a model of the pool: head bump + top-down tail carves, the production rules --- */
struct range { size_t off, size; int live; };
static struct range live[4096];
static int nlive;
static size_t total, head, tail_resv;
static unsigned long jumps, below;
static size_t skipped_head;
static size_t eff_end;                   /* ios_jit_hole_end_eff; 0 = ios_jit_hole_end */
static size_t big_off, big_size;
static int big_taken;
#define HOLE_END_EFF (eff_end ? eff_end : ios_jit_hole_end)

static void check_new( size_t off, size_t size )
{
    int i;
    if (off + size > total) FAIL("range 0x%zx+0x%zx past the pool end\n", off, size);
    if (ios_jit_hole_end > ios_jit_hole_off && off < ios_jit_hole_end && off + size > ios_jit_hole_off)
        FAIL("range 0x%zx+0x%zx overlaps the hole [0x%zx,0x%zx)\n", off, size, ios_jit_hole_off, ios_jit_hole_end);
    if (ios_jit_hole2_end > ios_jit_hole2_off && off < ios_jit_hole2_end && off + size > ios_jit_hole2_off)
        FAIL("range 0x%zx+0x%zx overlaps hole 2 [0x%zx,0x%zx)\n", off, size, ios_jit_hole2_off, ios_jit_hole2_end);
    for (i = 0; i < nlive; i++)
        if (live[i].live && off < live[i].off + live[i].size && off + size > live[i].off)
            FAIL("range 0x%zx+0x%zx overlaps live 0x%zx+0x%zx\n", off, size, live[i].off, live[i].size);
    live[nlive].off = off; live[nlive].size = size; live[nlive].live = 1; nlive++;
}

static int head_alloc( size_t size )   /* ios_pool_alloc_range_ex's bump */
{
    size_t limit = total - tail_resv;
    size_t cand = ios_pool_holes_head_place( head, size, ios_jit_hole_off, HOLE_END_EFF,
                                             ios_jit_hole2_off, ios_jit_hole2_end );
    if (big_size && size >= 64 * ((size_t)1 << 20) && !big_taken && size <= big_size)
    {   /* the big-image slot */
        check_new( big_off, size );
        big_taken = 1;
        return 1;
    }
    if (cand + size > limit) return 0;
    check_new( cand, size );
    if (cand != head)
    {
        size_t po[3], ps[3], kept = 0;
        int np = ios_pool_skip_pieces( head, cand, ios_jit_hole_off, HOLE_END_EFF, ios_jit_hole2_off, ios_jit_hole2_end, po, ps ), k;
        jumps++;
        for (k = 0; k < np; k++)
        {
            if (k && po[k] < po[k - 1] + ps[k - 1]) FAIL("skipped pieces out of order\n");
            if (IOS_POOL_IN_HOLE(po[k]) || IOS_POOL_IN_HOLE(po[k] + ps[k] - 1)) FAIL("a skipped piece in a hole\n");
            if (po[k] < head || po[k] + ps[k] > cand) FAIL("a skipped piece outside the jump\n");
            kept += ps[k];
        }
        skipped_head += kept;
    }
    head = cand + size;
    return 1;
}

static int tail_alloc( size_t size )   /* NtAllocateVirtualMemoryEx's EC_CODE carve */
{
    int split = ios_jit_hole_end > ios_jit_hole_off;
    size_t cur = tail_resv, start, added, off;
    if (split) start = ios_pool_holes_tail_start( total, cur, size, ios_jit_hole_off, HOLE_END_EFF,
                                                  ios_jit_hole2_off, ios_jit_hole2_end );
    else start = cur;
    tail_resv = start + size;
    added = start + size - cur;
    off = total - start - size;
    if (start + size > (total / 4) * 3 || off < head)
    {
        ios_pool_tail_unreserve( &tail_resv, start + size, added, split );
        if (tail_resv != cur) FAIL("rollback left the counter at 0x%zx, not 0x%zx\n", tail_resv, cur);
        return 0;
    }
    check_new( off, size );
    if (start != cur) below++;
    return 1;
}

static unsigned long long rng = 88172645463325252ull;
static unsigned rnd( unsigned n ) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (unsigned)(rng % n); }

static void model( size_t pool, size_t h0, size_t h1, int rounds, size_t *heads, size_t *tails )
{
    int r, k;
    *heads = *tails = 0;
    for (r = 0; r < rounds; r++)
    {
        unsigned bias = 1 + rnd(4);   /* 1..4 in 5: from tail-heavy to head-heavy runs */
        total = pool; head = 0; tail_resv = 0; nlive = 0;
        ios_jit_hole_off = h0; ios_jit_hole_end = h1;
        for (k = 0; k < 400 && nlive < 4000; k++)
        {
            size_t sz = ((size_t)(1 + rnd(rnd(4) ? 64 : 4096)) * 0x4000);
            if (rnd(5) < bias) { if (head_alloc( sz )) *heads += sz; }
            else { size_t t = (size_t)0x100000 << rnd(8); if (tail_alloc( t )) *tails += t; }
        }
    }
}

/* pool-mid: the random model with two holes (hole 1 below hole 2) */
static void model2( size_t pool, size_t a0, size_t a1, size_t b0, size_t b1, int rounds, size_t *heads, size_t *tails )
{
    ios_jit_hole2_off = b0; ios_jit_hole2_end = b1;
    model( pool, a0, a1, rounds, heads, tails );
    ios_jit_hole2_off = ios_jit_hole2_end = 0;
}

/* RDR2 on build 470 (2026-10-09 14:33): A 285 MB | early mapping 71 MB | 213 MB free |
 * stack 7 MB | B 319 MB. 462 MB of image copies, FEX code 128 + 16 MB from the pool
 * (region C full) after the first 300 MB, then d3dcompiler_47.dll (720 KB) last.
 * mid = 0: the 470 pool (one hole over all of it); mid = 1: pool-mid. Returns the step
 * that failed, 0 if none. */
static int rdr2_470( int mid )
{
    /* M is the 213 MB run rounded down to 16 MB (poolRunSize): 208 MB, the rest stays in hole 2 */
    size_t a = 285 * MB, m0 = a + 71 * MB, m1 = m0 + 208 * MB, b0 = m0 + 213 * MB + 7 * MB + 0x40000, i;
    total = 0x38000000; head = 0; tail_resv = 0; nlive = 0;
    if (b0 + 319 * MB > total) FAIL("rdr2 layout does not fit the span\n");
    ios_jit_hole_off = a; ios_jit_hole_end = mid ? m0 : b0;
    ios_jit_hole2_off = mid ? m1 : 0; ios_jit_hole2_end = mid ? b0 : 0;
    for (i = 0; i < 300; i += 4) if (!head_alloc( 4 * MB )) return 1;
    if (!tail_alloc( 128 * MB ) || !tail_alloc( 16 * MB )) return 2;
    for (i = 300; i < 462; i += 3) if (!head_alloc( 3 * MB )) return 3;
    if (!head_alloc( 0xb4000 )) return 4;                                           /* d3dcompiler_47.dll */
    ios_jit_hole2_off = ios_jit_hole2_end = 0;
    return 0;
}

/* GTA V Enhanced + Social Club, sizes from the 2026-10-02 logs: returns the step that failed, 0 if none */
static int gta_scenario( size_t pool, size_t h0, size_t h1 )
{
    size_t i;
    total = pool; head = 0; tail_resv = 0; nlive = 0;
    ios_jit_hole_off = h0; ios_jit_hole_end = h1;
    for (i = 0; i < 275; i += 5) if (!head_alloc( 5 * MB )) return 1;               /* game + launcher images */
    if (!tail_alloc( 128 * MB ) || !tail_alloc( 16 * MB ) || !tail_alloc( 16 * MB )) return 2;   /* FEX code */
    if (!head_alloc( 25 * MB )) return 3;                                           /* SocialClubHelper.exe, chrome_elf */
    if (!head_alloc( 240 * MB )) return 4;                                          /* libcef.dll */
    for (i = 0; i < 30; i += 3) if (!head_alloc( 3 * MB )) return 5;                /* its GPU stack */
    if (!tail_alloc( 16 * MB ) || !tail_alloc( 16 * MB )) return 6;                 /* its code buffers */
    return 0;
}

/* GTA V Enhanced build 373 (2026-10-04 08:41): A = 624 MB, stack hole 10 MB, B = 256 MB;
 * 450 MB of per-process DLL copies and 112 MB of FEX code before libcef.dll (240 MB) */
static int gta373( size_t slot )
{
    size_t i, a = 624 * MB, b = a + 10 * MB;
    total = b + 256 * MB; head = 0; tail_resv = 0; nlive = 0; big_taken = 0;
    ios_jit_hole_off = a; ios_jit_hole_end = b;
    big_off = b; big_size = slot; eff_end = slot ? b + slot : 0;
    for (i = 0; i < 450; i += 5) if (!head_alloc( 5 * MB )) return 1;
    for (i = 0; i < 7; i++) if (!tail_alloc( 16 * MB )) return 2;
    if (!head_alloc( 0xefc0000 )) return 3;                                         /* libcef.dll */
    for (i = 0; i < 30; i += 3) if (!head_alloc( 3 * MB )) return 4;              /* its GPU stack */
    if (!tail_alloc( 16 * MB ) || !tail_alloc( 16 * MB )) return 5;
    /* what is left below the hole is all the session has: the slot moves libcef.dll
     * out of the way, it does not make the pool bigger */
    return 0;
}

/* --- a fake VM map for ios_pool_execable_runs --- */
struct reg { uint64_t base, size; unsigned max; };
static struct reg map[16];
static int nmap, nonsense;
static int fake_region( uint64_t *addr, uint64_t *size, unsigned int *max_prot )
{
    int i;
    if (nonsense) { *size = 0x4000; *max_prot = 7; *addr = *addr - 0x8000; return 0; }
    for (i = 0; i < nmap; i++)
        if (map[i].base + map[i].size > *addr) { *addr = map[i].base; *size = map[i].size; *max_prot = map[i].max; return 0; }
    return -1;
}

int main( void )
{
    size_t heads, tails, a, b, c;
    size_t ro[16], rs[16];
    int n;

    /* no hole: identities */
    ios_jit_hole_off = ios_jit_hole_end = 0;
    if (ios_pool_hole_head_place( 0x1234000, 0x8000, 0, 0 ) != 0x1234000) FAIL("head place without hole\n");
    if (ios_pool_hole_tail_start( 600 * MB, 7 * MB, 16 * MB, 0, 0 ) != 7 * MB) FAIL("tail start without hole\n");
    if (ios_pool_hole_between( 600 * MB, 1 * MB, 1 * MB, 0, 0 )) FAIL("between without hole\n");
    if (IOS_POOL_IN_HOLE(0) || IOS_POOL_IN_HOLE(0x4000) || IOS_POOL_IN_HOLE(~(size_t)0)) FAIL("IN_HOLE without hole\n");
    if (ios_pool_holes_head_place( 0x1234000, 0x8000, 0, 0, 0, 0 ) != 0x1234000 ||
        ios_pool_holes_tail_start( 600 * MB, 7 * MB, 16 * MB, 0, 0, 0, 0 ) != 7 * MB ||
        ios_pool_holes_between( 600 * MB, 1 * MB, 1 * MB, 0, 0, 0, 0 ))
        FAIL("two-hole helpers without holes\n");
    printf("PASS: without WINE_IOS_JIT_HOLE the helpers are the old bump, carve and room\n");

    /* pool-mid helpers against the one-hole ones, and the skipped pieces */
    {
        size_t h1o = 285 * MB, h1e = 356 * MB, h2o = 569 * MB, h2e = 576 * MB, tot = 896 * MB, po[3], ps[3];
        size_t cur, sz;
        for (cur = 0; cur < tot; cur += 3 * MB + 0x4000)
            for (sz = 0x4000; sz < 300 * MB; sz = sz * 3 + 0x4000)
            {
                if (ios_pool_holes_head_place( cur, sz, h1o, h1e, 0, 0 ) != ios_pool_hole_head_place( cur, sz, h1o, h1e ))
                    FAIL("two-hole head place with one hole differs\n");
                if (ios_pool_holes_tail_start( tot, cur, sz, h1o, h1e, 0, 0 ) != ios_pool_hole_tail_start( tot, cur, sz, h1o, h1e ))
                    FAIL("two-hole tail start with one hole differs\n");
                {
                    size_t h = ios_pool_holes_head_place( cur, sz, h1o, h1e, h2o, h2e );
                    if (h < cur || (h < h1e && h + sz > h1o) || (h < h2e && h + sz > h2o)) FAIL("head into a hole\n");
                }
                if (cur + sz <= tot)
                {
                    size_t t = ios_pool_holes_tail_start( tot, cur, sz, h1o, h1e, h2o, h2e ), off;
                    if (t < cur || t + sz > tot) continue;
                    off = tot - t - sz;
                    if ((off < h1e && off + sz > h1o) || (off < h2e && off + sz > h2o)) FAIL("tail carve into a hole\n");
                }
            }
        if (ios_pool_skip_pieces( 280 * MB, 576 * MB, h1o, h1e, h2o, h2e, po, ps ) != 2 ||
            po[0] != 280 * MB || ps[0] != 5 * MB || po[1] != h1e || ps[1] != h2o - h1e)
            FAIL("skip pieces across both holes\n");
        if (ios_pool_skip_pieces( 300 * MB, 600 * MB, h1o, h1e, h2o, h2e, po, ps ) != 2 ||
            po[0] != h1e || ps[0] != h2o - h1e || po[1] != h2e || ps[1] != 24 * MB)
            FAIL("skip pieces from inside hole 1\n");
        if (ios_pool_skip_pieces( 280 * MB, 285 * MB, h1o, h1e, 0, 0, po, ps ) != 1 || po[0] != 280 * MB || ps[0] != 5 * MB)
            FAIL("skip pieces below one hole\n");
        if (ios_pool_skip_pieces( h1o, h1e, h1o, h1e, h2o, h2e, po, ps ) != 0) FAIL("a hole is no piece\n");
        if (ios_pool_skip_pieces( 0, 0x2000, 0, 0, 0, 0, po, ps ) != 0) FAIL("a piece under 16 KB\n");
        if (!IOS_POOL_IN_HOLE(h1o) && 0) FAIL("x\n");
        ios_jit_hole_off = h1o; ios_jit_hole_end = h1e; ios_jit_hole2_off = h2o; ios_jit_hole2_end = h2e;
        if (!IOS_POOL_IN_HOLE(h2o) || !IOS_POOL_IN_HOLE(h2e - 0x4000) || IOS_POOL_IN_HOLE(h2e) || IOS_POOL_IN_HOLE(h2o - 0x4000) ||
            !IOS_POOL_IN_HOLE(h1o) || IOS_POOL_IN_HOLE(h1e))
            FAIL("IN_HOLE with two holes\n");
        if (ios_pool_holes_between( tot, 100 * MB, 100 * MB, h1o, h1e, h2o, h2e ) != (h1e - h1o) + (h2e - h2o))
            FAIL("room excludes both holes\n");
        if (ios_pool_holes_between( tot, 400 * MB, 100 * MB, h1o, h1e, h2o, h2e ) != h2e - h2o)
            FAIL("room once the head passed hole 1\n");
        ios_jit_hole_off = ios_jit_hole_end = ios_jit_hole2_off = ios_jit_hole2_end = 0;
        printf("PASS: pool-mid helpers equal the one-hole ones without a second hole, never hand out either hole, "
               "and the skipped pieces are the pool memory in between\n");
    }

    /* the 16:33 layout: A = 592 MB, stack gap ~5.7 MB, B = 288 MB */
    a = 592 * MB; b = a + 0x5bc000 + 0x4000 * 3; c = b + 288 * MB;
    ios_jit_hole_off = a; ios_jit_hole_end = b;
    if (!IOS_POOL_IN_HOLE(a) || !IOS_POOL_IN_HOLE(b - 0x4000) || IOS_POOL_IN_HOLE(b) || IOS_POOL_IN_HOLE(a - 0x4000))
        FAIL("IN_HOLE bounds\n");
    if (ios_pool_hole_head_place( a - 4 * MB, 4 * MB, a, b ) != a - 4 * MB) FAIL("head that ends at the hole moved\n");
    if (ios_pool_hole_head_place( a - 4 * MB, 4 * MB + 0x4000, a, b ) != b) FAIL("head reaching the hole not moved above it\n");
    if (ios_pool_hole_head_place( b, 64 * MB, a, b ) != b) FAIL("head above the hole moved\n");
    if (ios_pool_hole_tail_start( c, 0, 128 * MB, a, b ) != 0) FAIL("top carve moved\n");
    if (ios_pool_hole_tail_start( c, 250 * MB, 64 * MB, a, b ) != c - a) FAIL("overlapping carve not put below the hole\n");
    if (ios_pool_hole_tail_start( c, c - a, 16 * MB, a, b ) != c - a) FAIL("carve directly below the hole moved\n");
    if (ios_pool_hole_tail_start( c, c - b, 16 * MB, a, b ) != c - a) FAIL("carve ending at the hole top not moved below\n");
    if (ios_pool_hole_tail_start( c, c - b - 16 * MB, 16 * MB, a, b ) != c - b - 16 * MB) FAIL("carve ending at hole_end moved\n");
    if (ios_pool_hole_between( c, 500 * MB, 200 * MB, a, b ) != b - a) FAIL("hole between head and tail not counted\n");
    if (ios_pool_hole_between( c, b + MB, 100 * MB, a, b ) || ios_pool_hole_between( c, 100 * MB, c - a + MB, a, b ))
        FAIL("hole counted once a side passed it\n");
    printf("PASS: head jumps the hole, a carve that would overlap it goes directly below it, room excludes it\n");

    {
        volatile size_t ctr = 300 * MB;
        ios_pool_tail_unreserve( &ctr, 300 * MB, 16 * MB, 0 );
        if (ctr != 284 * MB) FAIL("unsplit rollback is not fetch-and-sub\n");
        ctr = 300 * MB;
        ios_pool_tail_unreserve( &ctr, 300 * MB, 100 * MB, 1 );
        if (ctr != 200 * MB) FAIL("split rollback with nothing on top\n");
        ctr = 316 * MB;   /* another carve came after ours */
        ios_pool_tail_unreserve( &ctr, 300 * MB, 100 * MB, 1 );
        if (ctr != 316 * MB) FAIL("split rollback lowered the counter under a later carve\n");
        printf("PASS: a refused carve gives back what it took, and never lowers the counter under a later carve\n");
    }

    jumps = below = 0;
    model( c, a, b, 300, &heads, &tails );
    if (!jumps || !below) FAIL("the split model never jumped the hole (%lu) or carved below it (%lu)\n", jumps, below);
    printf("PASS: split model, 300 runs: %zu MB head + %zu MB tail handed out (%lu head jumps, %lu carves below "
           "the hole), none in the hole, no overlap\n", heads >> 20, tails >> 20, jumps, below);
    if ((n = gta_scenario( 592 * MB, 0, 0 )) != 4) FAIL("GTA scenario on the 592 MB pool failed at step %d, not 4\n", n);
    if ((n = gta_scenario( c, a, b )) != 0) FAIL("GTA scenario on the split pool failed at step %d\n", n);
    printf("PASS: GTA-shaped run: the 592 MB pool refuses libcef.dll, the split pool (592 + 288 MB) serves it all\n");
    if ((n = rdr2_470( 0 )) != 3 && n != 4) FAIL("RDR2 470 layout without pool-mid failed at step %d, not 3/4\n", n);
    if ((n = rdr2_470( 1 )) != 0) FAIL("RDR2 470 layout with pool-mid failed at step %d\n", n);
    printf("PASS: RDR2 build 470 layout: the 604 MB pool runs the image copies dry, with the 208 MB third region "
           "(812 MB) everything, d3dcompiler_47.dll included, fits\n");
    jumps = below = 0; skipped_head = 0;
    model2( 0x38000000, 285 * MB, 356 * MB, 569 * MB, 576 * MB, 300, &heads, &tails );
    if (!jumps || !below || !skipped_head) FAIL("the two-hole model never jumped (%lu), carved below (%lu) or kept a piece\n",
                                                jumps, below);
    printf("PASS: two-hole model, 300 runs: %zu MB head + %zu MB tail (%lu head jumps, %lu carves below a hole, "
           "%zu MB of skipped pieces kept), nothing in either hole, no overlap\n", heads >> 20, tails >> 20, jumps, below,
           skipped_head >> 20);
    model2( 0x38000000, 64 * MB, 64 * MB + 0x4000, 64 * MB + 0x8000, 64 * MB + 0xc000, 100, &heads, &tails );
    model2( 0x38000000, 0x38000000 - 0x14000, 0x38000000 - 0x10000, 0x38000000 - 0xc000, 0x38000000 - 0x8000, 100, &heads, &tails );
    printf("PASS: two 16 KB holes close together near either end are never handed out\n");
    model( 592 * MB, 0, 0, 300, &heads, &tails );
    printf("PASS: unsplit model, 300 runs: %zu MB head + %zu MB tail, no overlap\n", heads >> 20, tails >> 20);
    if ((n = gta373( 0 )) != 3) FAIL("build 373 without the slot failed at step %d, not 3 (libcef.dll)\n", n);
    if ((n = gta373( 240 * MB )) != 0) FAIL("build 373 with a 240 MB slot failed at step %d\n", n);
    /* a slot-shaped split model: the slot behaves as part of the hole for the bump and the tail */
    {
        size_t a2 = 600 * MB, b2 = a2 + 8 * MB, c2 = b2 + 300 * MB;
        eff_end = b2 + 240 * MB; big_size = 0;
        model( c2, a2, b2, 200, &heads, &tails );
        for (n = 0; n < nlive; n++)
            if (live[n].off < eff_end && live[n].off + live[n].size > b2) FAIL("a small range in the slot\n");
        eff_end = 0;
    }
    printf("PASS: build 373 sizes: libcef.dll fails without the big-image slot and fits with 240 MB; "
           "nothing else lands in the slot\n");
    model( c, 64 * MB, 64 * MB + 0x4000, 100, &heads, &tails );
    model( c, c - 0x8000 - 0x4000, c - 0x8000, 100, &heads, &tails );
    printf("PASS: a 16 KB hole near either end is never handed out\n");

    /* POISONED salvage: off 0x110ac000 size 0x25c000, one RW page at +0x1e0000 (16:19 log) */
    nmap = 3;
    map[0] = (struct reg){ 0x148000000ull, 0x110ac000ull + 0x1e0000, 5 };
    map[1] = (struct reg){ 0x148000000ull + 0x110ac000 + 0x1e0000, 0x4000, 3 };
    map[2] = (struct reg){ 0x148000000ull + 0x110ac000 + 0x1e4000, 0x10000000, 7 };
    n = ios_pool_execable_runs( 0x148000000ull, 0x110ac000, 0x25c000, fake_region, ro, rs, 16 );
    if (n != 2 || ro[0] != 0x110ac000 || rs[0] != 0x1e0000 || ro[1] != 0x110ac000 + 0x1e4000 || rs[1] != 0x78000)
        FAIL("salvage: n=%d %zx+%zx %zx+%zx\n", n, ro[0], rs[0], ro[1], rs[1]);
    /* a run under 64 KB is dropped, an unmapped gap ends a run */
    nmap = 4;
    map[0] = (struct reg){ 0x200000000ull, 0xc000, 5 };
    map[1] = (struct reg){ 0x20000c000ull, 0x4000, 1 };
    map[2] = (struct reg){ 0x200010000ull, 0x20000, 5 };
    map[3] = (struct reg){ 0x200040000ull, 0x40000, 5 };   /* gap [0x30000, 0x40000) before it */
    n = ios_pool_execable_runs( 0x200000000ull, 0, 0x80000, fake_region, ro, rs, 16 );
    if (n != 2 || ro[0] != 0x10000 || rs[0] != 0x20000 || ro[1] != 0x40000 || rs[1] != 0x40000)
        FAIL("salvage with gap: n=%d %zx+%zx %zx+%zx\n", n, ro[0], rs[0], ro[1], rs[1]);
    /* nothing mapped at all, and a nonsense answer, end the walk with no run */
    nmap = 0;
    if (ios_pool_execable_runs( 0x200000000ull, 0, 0x80000, fake_region, ro, rs, 16 ) != 0) FAIL("unmapped salvage\n");
    nonsense = 1;
    if (ios_pool_execable_runs( 0x200000000ull, 0x10000, 0x80000, fake_region, ro, rs, 16 ) != 0) FAIL("nonsense salvage\n");
    nonsense = 0;
    /* `max` caps the output */
    nmap = 3;
    map[0] = (struct reg){ 0x300000000ull, 0x10000, 5 };
    map[1] = (struct reg){ 0x300010000ull, 0x4000, 3 };
    map[2] = (struct reg){ 0x300014000ull, 0x10000, 5 };
    if (ios_pool_execable_runs( 0x300000000ull, 0, 0x24000, fake_region, ro, rs, 1 ) != 1) FAIL("max ignored\n");
    printf("PASS: a POISONED range keeps its executable runs of 64 KB or more; RW pages, gaps and short runs are cut\n");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as t:
    c = Path(t) / 'split.c'
    c.write_text(harness)
    exe = Path(t) / 'split'
    subprocess.run(['cc', '-std=gnu11', '-O1', '-Wall', '-Wno-unused-function', '-fsanitize=address,undefined',
                    '-fno-sanitize-recover=all', str(c), '-o', str(exe)], check=True)
    out = subprocess.run([str(exe)], capture_output=True, text=True)
    print(out.stdout, end='')
    assert out.returncode == 0, out.stderr
