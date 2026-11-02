#!/usr/bin/env python3
"""Region C for FEX's code buffers (pool-low = 1) in virtual_ios.c and the handlers; no Wine runs.

GTA V Enhanced, iPhone 17 Pro Max (build 374, 2026-10-04 09:25): the pool is 560 MB
below the main thread's stack + 304 MB above it, the 240 MB big-image slot holds
libcef.dll, and the head ran dry at 557 of the 560 MB below the hole while every
process's 16 MB code buffer had gone to the tail. Every log also shows a 416-476 MB
free run below the 0x140000000 executable window. With pool-low the app takes that
run (less a 128 MB margin) as a third debugger region, region C, outside the pool
span, and maps its RW alias at the pool's RX->RW distance in one reservation;
WINE_IOS_JIT_TAIL_REGION names it and ntdll carves FEX's code buffers from it first.

Compiles the production helpers from build/ntdll-unix/virtual_ios.c
(ios_jit_low_contains, ios_jit_low_rw_contains, ios_jit_low_overlaps,
ios_pool_low_parse, ios_pool_low_take, ios_pool_alias_extent, ios_sc_layout_pick and
the split-pool helpers) with AddressSanitizer/UBSan and checks:
  - without WINE_IOS_JIT_TAIL_REGION nothing is in region C and the predicates are 0;
  - the env parser takes only a page-aligned region of 16 MB or more entirely below
    the pool span, whose alias at the pool's distance does not wrap;
  - a C carve recorded with the wrapping offset (rx_C - rx) gives back its RX address
    as rx + off and its RW alias as rw + off, which is what every rx/rw + off path
    (reuse, free, lookup, census, the Mach store and backpatch emulation) relies on;
  - C's bump never hands out a byte past C and consumes nothing on a refusal;
  - Social Club layout 2: with C the alias reservation starts at 0x7900000000 and
    still ends below the V8 cage, so the layout stays 2; with the pool's own RW base
    alone it would fall back to layout 1;
  - a build-374-shaped model: without C the tail carves eat the pool's head room and
    the head fails; with C every carve lands in C, the head gets the whole span, and
    WoW64 carves still go to the tail;
and textually that every "is this JIT code?" decision in virtual_ios.c,
signal_arm64_ios.c and server_ios.c that the audit found asks about region C, and that
the app takes C only on request and exports it only when it has it.
Needs python3 and a C compiler.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
signal = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()
server = (root / 'build/ntdll-unix/server_ios.c').read_text()
swift = (root / 'app/Madeira/StikJITHelper.swift').read_text()
content = (root / 'app/Madeira/ContentView.swift').read_text()


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


# --- ntdll: init, carve, free, warmer, scans ---------------------------------
init = native[native.index('/* madeira-bcd pool-low: region C (see ios_jit_low_rx_global). Taken only'):][:4200]
assert 'ios_pool_low_parse( low, (uint64_t)(uintptr_t)jit_rx_base, (uint64_t)(uintptr_t)jit_rw_base,' in init
assert '(ix.max_protection & VM_PROT_EXECUTE)' in init, 'C must be executable'
assert '*pw = mark;' in init and 'ok = *px == mark;' in init and '*pw = keep;' in init, \
    'a word written through C\'s RW alias must read back through its RX side'
assert init.index('ios_jit_low_rw_global = lrw;') < init.index('ios_jit_low_size_global = (size_t)lsz;'), \
    'the size is published last: it is what turns region C on'
assert native.index('const char *big = getenv( "MADEIRA_POOL_BIG_SLOT_MB" );') < \
    native.index('/* madeira-bcd pool-low: region C (see ios_jit_low_rx_global). Taken only') < \
    native.index('pthread_create( &warm, NULL, ios_pool_warmer_thread, NULL )'), 'C is known before the warmer starts'

ec = native[native.index('size_t alloc_size = (*size_ptr + 0x3FFF) & ~0x3FFFUL;'):]
ec = ec[:ec.index('size_t pool_tail_off = ios_jit_pool_size_global - reserve_offset - alloc_size;')]
assert 'int low_ok = ios_jit_low_size_global && !ios_wow_base();' in ec, 'WoW64 never gets a C carve'
assert 'if (alloc_size > cap && !low_fits) {' in ec, 'the tail cap does not refuse what C can take'
assert ec.count('(low_ok || !ios_tail_carve_in_low( ios_tail_carves[') == 2, \
    'a freed C carve is neither reused by nor counted for a WoW64 process'
low_carve = ec[ec.index('if (low_ok)\n'):]
assert ec.index('/* ml438 (#74): serve from the free-list first') < ec.index('if (low_ok)\n') < \
    ec.index('size_t reserve_offset, tail_added, tail_skipped = 0;'), 'reuse first, then C, then the tail'
assert 'ios_pool_low_take( &ios_jit_low_reserved, ios_jit_low_size_global, alloc_size, &loff )' in low_carve
assert 'ios_tail_carves[ios_tail_carve_n].off = (size_t)((uintptr_t)jit_rx - (uintptr_t)ios_jit_rx_base_global);' \
    in low_carve, 'a C carve is recorded with its wrapping distance from the pool base'
assert 'rw_words[w] = 0xd503201fu;' in low_carve, 'C carves are NOP-prefilled like tail carves'
assert 'if (alloc_size > tail_cap)' in low_carve, 'a lost race for C still respects the tail cap'

free_path = native[native.index('/* madeira-bcd pool-low: a carve in region C is released the same way'):][:900]
assert 'ios_jit_low_contains( (uintptr_t)base )' in free_path
lookup = function(native, 'int ios_tail_carve_lookup_trylock(')
assert '(rx_addr < rx_base && !ios_jit_low_contains( (uintptr_t)rx_addr ))' in lookup
warmer = function(native, 'static void *ios_pool_warmer_thread(')
assert 'size_t used = ios_jit_low_reserved;' in warmer and 'sink += lrw[o]; sink += lrx[o];' in warmer
scan = function(native, 'static void* try_map_free_area(')
assert 'a < ios_jit_low_rx_global + low' in scan and 'pool_base = ios_jit_low_rw_global; pool_end = rw;' in scan, \
    'Wine\'s free-area scan jumps over C\'s RX side and the RW reservation below the pool alias'
assert 'if (ios_jit_low_overlaps( (uintptr_t)a, size )) return 1;' in function(native, 'static int ios_jit_pool_intersects(')
assert 'ios_jit_low_overlaps( a, size ))) return;' in function(native, 'static void ios_jit_range_tripwire( const char *tag, const void *addr, size_t size,\n                                    int prot, void *retaddr )\n{')
assert 'if (ios_jit_low_overlaps( b, size )) return 1;' in function(native, 'static int ios_swap_is_fexjit(')
if 'IOS_DC_INLINE int ios_dc_prepare(' in native:   # the decommit helpers (never called) are not upstream
    assert 'if (ios_jit_low_overlaps( p, host_page_size )) return 0;' in function(native, 'IOS_DC_INLINE int ios_dc_prepare(')
assert '!ios_jit_low_contains( (uintptr_t)block_begin )' in function(native, 'void ios_mono_bridge_capture(')
floor = function(native, 'static inline ULONG_PTR ios_usable_va_floor_get(void)')
assert 'if (ios_jit_low_size_global && sz)' in floor, 'the furniture floor follows the moved pool alias'
layout = function(native, 'static int ios_sc_layout(void)')
assert 'ios_pool_alias_extent( x, a, n, lrx, lsz, &lo, &span );' in layout and 'm = ios_sc_layout_pick( e, lo, span );' in layout
print('PASS: ntdll takes region C only when its alias proves out, carves code buffers there first (never for WoW64), '
      'frees, reuses, warms and skips it')

# --- the handlers: every pool-PC / pool-store decision also asks about C -----
assert 'if ((rx && pc >= rx && pc < rx + sz) || ios_jit_low_contains( pc ))\n    {\n        REGn_sig(17, context) = pc;' \
    in signal, 'x18 is restored for interrupted code in C (ios_fixup_x18_for_return)'
deliver = function(signal, 'static int ios_mach_deliver_guest_exception_inner(')
assert 'ios_jit_low_contains( (uintptr_t)pc ) ||   /* madeira-bcd pool-low: FEX code in region C */' in deliver, \
    'a guest fault in C\'s code is claimed as guest-side'
assert 'ios_jit_low_contains( (uintptr_t)pc );   /* madeira-bcd pool-low */' in deliver, 'native-thread decline'
assert 'ios_jit_low_contains( (uintptr_t)frame->pc ))' in signal, 'NtContinue keeps a native resume into C native'
assert 'int in_low = rx && rw && sz && ios_jit_low_contains( (uintptr_t)fault_addr );' in signal
assert 'fault_addr >= rx && fault_addr < rx + sz) || in_low;' in signal, 'Mach store emulation into C'
assert 'fault_addr - ios_jit_low_rx_global <= ios_jit_low_size_global - cas_width' in signal, 'CASAL lock word in C, bounded by C'
# #461: STP Q (and a store crossing a 16 KB page) writes through ios_alias_write, which resolves
# every fragment's alias, C included, and refuses one whose last byte is not at the same distance
write_alias = function(signal, 'static uintptr_t ios_write_alias(')
assert '|| ios_jit_low_contains( addr )))\n        return rw + (addr - rx);' in write_alias, 'C stores use the pool distance'
assert '|| ios_jit_low_contains( addr )) return 0;' in function(signal, 'static int ios_alias_write_is_trapped('), \
    'C is pool code, never a guest-protected page'
assert 'ios_write_alias( at + length - 1 ) != rw + length - 1) return 0;' in \
    function(signal, 'static int ios_alias_write('), 'STP Q never leaves C'
assert 'ios_alias_write( effective, values, sizeof(values), &alias_fault, honor_guest_prot )' in signal, \
    'STP Q goes through the fragment check'
assert 'ios_write_alias( a + len - 1 ) != part_rw[parts] + len - 1' in \
    function(signal, 'int ios_store_split_crossing('), 'a page-crossing store never leaves C either'
assert signal.count('ios_jit_low_contains( (uintptr_t)fault_pc )') >= 2, 'Mach exec-fault branch and LDAPR backpatch'
assert 'ios_jit_low_rw_contains( (uintptr_t)fault_pc )))   /* madeira-bcd pool-low */' in signal, 'RW-alias pc redirect'
assert 'ios_jit_low_contains( (uintptr_t)fa );   /* madeira-bcd pool-low */' in signal, 'exec recovery'
assert 'ios_jit_low_rw_contains( (uintptr_t)fa )))   /* madeira-bcd pool-low */' in signal, 'reclaim band never claims C\'s alias'
foreign = function(signal, 'static int ios_fault_is_foreign(')
assert foreign.count('ios_jit_low_contains(') == 2 and foreign.count('ios_jit_low_rw_contains(') == 2
assert '!ios_jit_low_contains( sg_pc ) &&' in signal, 'sub-floor service stays off for C pcs (x17 is FEX state)'
assert '(rx && rw && ios_jit_low_contains( fault )))' in signal, 'SIGBUS store emulation into C'
assert '!(rx && rw && ios_jit_low_contains( fault )))   /* madeira-bcd pool-low */' in signal
assert "ios_jit_low_contains( (uintptr_t)pc ))   /* madeira-bcd pool-low */\n            {\n                extern volatile uint64_t g_wine_return_pc;" \
    in signal, 'an exec fault in C is fatal, never walked as stores'
assert 'else if (ios_jit_low_contains( st.__pc )) c = 0;' in server and server.count('ios_jit_low_contains(') >= 3
print('PASS: x18 restore, guest-fault claim, native resume, store/CAS/STP/backpatch emulation, exec recovery, '
      'foreign-thread test, sub-floor gate and SIGBUS paths all treat region C as pool code')

# --- the app ------------------------------------------------------------------
assert 'MadeiraConfig.gameValue("pool-low") ?? MadeiraConfig.get("pool-low")' in swift
assert 'MadeiraConfig.gameValue("pool-low-margin") ?? MadeiraConfig.get("pool-low-margin")' in swift
take = function(swift, 'private static func takeLowRegion(')
assert 'Int(marginText) ?? 128' in take, 'the margin defaults to 128 MB'
assert 'guard poolRx >= exeWindow.base + exeWindow.size else {' in take, 'C only with the pool above the window'
assert 'runs.contains(where: { $0.base < r.base && $0.size >= margin }) ? 0 : margin' in take, \
    'a run keeps the margin unless a lower run alone holds it'
assert 'let available = r.size > keep ? r.size - keep : 0' in take
assert 'let pick = fits.max(by: { $0.size < $1.size })' in take, 'the run that leaves the largest C'
assert 'poolRunSize(available: available, wanted: available, pageFit: pageFit)' in take
assert 'let target = best.base + best.size - size' in take
assert 'freeRuns(0x100000000, best.base, minSize: size)' in take and 'plugs.append(' in take
assert 'if c < lowFloor || c + size > exeWindow.base || c + size > poolRx {' in take, 'a stray placement is released'
alias = function(swift, 'private static func mapLowAlias(')
assert 'let want = rw + (r.rx - first.rx)' in alias and 'VM_FLAGS_OVERWRITE' in alias, \
    'one reservation, every region at its own RX offset: one RX->RW distance'
assert 'rwAliasKeep(rw)' in alias and 'rwAliasDrop(kr)' in alias, 'layout 2 placement as mapSplitAlias'
assert swift.count('dropLowRegion(') == 3 and swift.count('lowReady(rwLow, low, rw)') == 2
assert swift.index('lowRegion = takeLowRegion(') < swift.index('poolHole = nil')
low_env = content[content.index('if let low = StikJITHelper.poolLow {'):][:600]
assert 'setenv("WINE_IOS_JIT_TAIL_REGION", String(format: "%lx:%lx", low.rx, low.size), 1)' in low_env
assert 'unsetenv("WINE_IOS_JIT_TAIL_REGION")' in low_env
print('PASS: the app takes region C only on request, at the top of the run below the window, aliases it with the '
      'pool in one reservation and exports WINE_IOS_JIT_TAIL_REGION only when it has it')

# --- compiled helpers -----------------------------------------------------------
low_block = native[native.index('uintptr_t ios_jit_low_rx_global, ios_jit_low_rw_global;'):]
low_block = low_block[:low_block.index('\n}', low_block.index('static void ios_pool_alias_extent(')) + 2] + '\n'
split_helpers = ''.join(function(native, sig) for sig in (
    'static size_t ios_pool_hole_head_place(',
    'static size_t ios_pool_hole_tail_start(',
    'static void ios_pool_tail_unreserve(',
))
sc_defs = ''.join(m.group(0) + '\n' for m in re.finditer(r'^#define IOS_SC2_(RW_ALIAS|RW_MAX|CAGE_BASE|E_BASE|POOL_REAL)\s+\S+',
                                                       native, re.M))
pick = function(native, 'static int ios_sc_layout_pick(')
carve_in_low = function(native, 'static int ios_tail_carve_in_low(')

harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#define FAIL(...) do { fprintf(stderr, __VA_ARGS__); exit(1); } while (0)
#define MB ((size_t)1 << 20)
static void *ios_jit_rx_base_global;
''' + low_block + split_helpers + sc_defs + pick + carve_in_low + r'''

static void set_low( uintptr_t rx, uintptr_t rw, size_t size )
{
    ios_jit_low_rx_global = rx; ios_jit_low_rw_global = rw; ios_jit_low_size_global = size; ios_jit_low_reserved = 0;
}

/* --- the pool model of check-pool-split.py, with region C in front of the tail --- */
struct range { uint64_t lo, size; };
static struct range live[4096];
static int nlive;
static size_t total, head, tail_resv, hole_off, hole_end;
static uint64_t pool_rx;

static void check_new( uint64_t lo, uint64_t size, const char *what )
{
    int i;
    if (lo >= pool_rx && lo - pool_rx < total && hole_end > hole_off &&
        lo - pool_rx < hole_end && lo - pool_rx + size > hole_off) FAIL("%s in the hole\n", what);
    for (i = 0; i < nlive; i++)
        if (lo < live[i].lo + live[i].size && lo + size > live[i].lo)
            FAIL("%s 0x%llx+0x%llx overlaps 0x%llx+0x%llx\n", what, (unsigned long long)lo, (unsigned long long)size,
                 (unsigned long long)live[i].lo, (unsigned long long)live[i].size);
    live[nlive].lo = lo; live[nlive].size = size; nlive++;
}

static int head_alloc( size_t size )
{
    size_t cand = ios_pool_hole_head_place( head, size, hole_off, hole_end );
    if (cand + size > total - tail_resv) return 0;
    check_new( pool_rx + cand, size, "head" );
    head = cand + size;
    return 1;
}

static unsigned low_carves, tail_carves;
/* NtAllocateVirtualMemoryEx's EC_CODE order: region C first (not for WoW64), then the tail */
static int code_alloc( size_t size, int wow )
{
    size_t loff, cur = tail_resv, start, off;
    int low_ok = ios_jit_low_size_global && !wow;
    if (low_ok && size <= IOS_POOL_LOW_CARVE_MAX &&
        ios_pool_low_take( &ios_jit_low_reserved, ios_jit_low_size_global, size, &loff ))
    {
        uint64_t rx = ios_jit_low_rx_global + loff;
        size_t rec = (size_t)(rx - (uint64_t)(uintptr_t)ios_jit_rx_base_global);   /* the recorded `off` */
        if (!ios_tail_carve_in_low( rec )) FAIL("C carve not recognised by its offset\n");
        if ((uint64_t)(uintptr_t)ios_jit_rx_base_global + rec != rx) FAIL("rx + off is not the carve\n");
        if (!ios_jit_low_contains( rx ) || !ios_jit_low_contains( rx + size - 1 ) ||
            (loff + size == ios_jit_low_size_global && ios_jit_low_contains( rx + size ))) FAIL("C carve bounds\n");
        check_new( rx, size, "C carve" );
        low_carves++;
        return 1;
    }
    start = hole_end > hole_off ? ios_pool_hole_tail_start( total, cur, size, hole_off, hole_end ) : cur;
    off = total - start - size;
    if (start + size > (total / 4) * 3 || off < head) return 0;
    tail_resv = start + size;
    if (ios_tail_carve_in_low( off )) FAIL("a tail carve taken for a C carve\n");
    check_new( pool_rx + off, size, "tail carve" );
    tail_carves++;
    return 1;
}

/* build 374: A 560 MB, the stack hole, B 304 MB of which 240 MB are the big-image slot
 * (modelled as part of the hole for everything else); 7 processes x 16 MB of FEX code,
 * images in 5 MB steps. Returns the MB of images the head took. */
static size_t gta374( int with_low, int wow_every )
{
    size_t a = 560 * MB, b = a + 10 * MB, i, got = 0;
    pool_rx = 0x148000000ull; total = b + 304 * MB; head = 0; tail_resv = 0; nlive = 0;
    hole_off = a; hole_end = b + 240 * MB;                  /* ios_jit_hole_end_eff */
    ios_jit_rx_base_global = (void *)(uintptr_t)pool_rx;
    if (with_low) set_low( 0x12e000000ull, 0x7025000000ull - (pool_rx - 0x12e000000ull), 288 * MB );
    else set_low( 0, 0, 0 );
    low_carves = tail_carves = 0;
    for (i = 0; i < 7; i++)
    {
        if (!code_alloc( 16 * MB, wow_every && (i % wow_every) == 0 )) FAIL("code buffer %zu refused\n", i);
        while (head_alloc( 5 * MB )) { got += 5; if (got >= 70 * (i + 1)) break; }
    }
    while (head_alloc( 5 * MB )) got += 5;
    return got;
}

int main( void )
{
    uint64_t rx = 0x148000000ull, rw = 0x7025000000ull, size = 0x36000000ull, lrx, lsz, lo, span;
    size_t off;
    volatile size_t res = 0;

    /* off: nothing is region C */
    set_low( 0, 0, 0 );
    if (ios_jit_low_contains( 0 ) || ios_jit_low_contains( 0x12e000000ull ) || ios_jit_low_rw_contains( 0 ) ||
        ios_jit_low_overlaps( 0, ~(uintptr_t)0 >> 1 )) FAIL("pool-low off still sees a region C\n");
    printf("PASS: without WINE_IOS_JIT_TAIL_REGION nothing is region C\n");

    /* the env parser */
    if (!ios_pool_low_parse( "12e000000:12000000", rx, rw, size, &lrx, &lsz ) || lrx != 0x12e000000ull || lsz != 0x12000000ull)
        FAIL("a good region refused\n");
    if (!ios_pool_low_parse( "12c800000:13800000", rx, rw, size, &lrx, &lsz ) ||
        lrx != 0x12c800000ull || lsz != 312 * MB || lrx + lsz != 0x140000000ull)
        FAIL("page-fitted 312MB C refused\n");
    if (ios_pool_low_parse( "12e000000:12000000", 0, rw, size, &lrx, &lsz )) FAIL("no pool\n");
    if (ios_pool_low_parse( "12e002000:12000000", rx, rw, size, &lrx, &lsz )) FAIL("unaligned base\n");
    if (ios_pool_low_parse( "12e000000:ff0000", rx, rw, size, &lrx, &lsz )) FAIL("under 16 MB\n");
    if (ios_pool_low_parse( "13e000000:12000000", rx, rw, size, &lrx, &lsz )) FAIL("reaches into the pool\n");
    if (ios_pool_low_parse( "150000000:4000000", rx, rw, size, &lrx, &lsz )) FAIL("inside the pool span\n");
    if (ios_pool_low_parse( "12e000000", rx, rw, size, &lrx, &lsz )) FAIL("no size\n");
    if (ios_pool_low_parse( "", rx, rw, size, &lrx, &lsz )) FAIL("empty\n");
    if (ios_pool_low_parse( "0:12000000", rx, rw, size, &lrx, &lsz )) FAIL("zero base\n");
    if (ios_pool_low_parse( "12e000000:12000000", rx, 0x10000000ull, size, &lrx, &lsz )) FAIL("alias would wrap\n");
    if (!ios_pool_low_parse( "136000000:12000000", rx, rw, size, &lrx, &lsz )) FAIL("ending right at the pool\n");
    printf("PASS: WINE_IOS_JIT_TAIL_REGION is taken only page-aligned, >= 16 MB, below the pool span\n");

    /* the same distance: rx + off / rw + off for a C carve recorded with a wrapping offset */
    ios_jit_rx_base_global = (void *)(uintptr_t)rx;
    set_low( 0x12e000000ull, rw - (rx - 0x12e000000ull), 0x12000000 );
    off = (size_t)(0x12f000000ull - rx);
    if ((uint64_t)(uintptr_t)ios_jit_rx_base_global + off != 0x12f000000ull) FAIL("rx + off\n");
    if (rw + off != ios_jit_low_rw_global + 0x1000000) FAIL("rw + off is not C's alias\n");
    if (!ios_tail_carve_in_low( off ) || ios_tail_carve_in_low( 0 ) || ios_tail_carve_in_low( size - 0x4000 ))
        FAIL("ios_tail_carve_in_low\n");
    if (!ios_jit_low_contains( 0x12e000000ull ) || !ios_jit_low_contains( 0x13fffffffull ) ||
        ios_jit_low_contains( 0x140000000ull ) || ios_jit_low_contains( 0x12dffffffull )) FAIL("RX bounds\n");
    if (!ios_jit_low_rw_contains( ios_jit_low_rw_global ) || ios_jit_low_rw_contains( rw ) ||
        ios_jit_low_rw_contains( ios_jit_low_rw_global - 1 )) FAIL("RW bounds\n");
    if (ios_jit_low_overlaps( 0x12d000000ull, 0x1000000 ) || ios_jit_low_overlaps( 0x12d000000ull, 0x1000001 ) != 1 ||
        ios_jit_low_overlaps( ios_jit_low_rw_global + 0x11fff000, 0x10000 ) != 2 || ios_jit_low_overlaps( 0x12e000000ull, 0 ))
        FAIL("overlap\n");
    printf("PASS: a C carve's wrapping offset gives rx + off = its RX address and rw + off = its RW alias\n");

    /* C's bump */
    if (!ios_pool_low_take( &res, 64 * MB, 16 * MB, &off ) || off != 0 || res != 16 * MB) FAIL("first take\n");
    if (!ios_pool_low_take( &res, 64 * MB, 48 * MB, &off ) || off != 16 * MB || res != 64 * MB) FAIL("exact fill\n");
    if (ios_pool_low_take( &res, 64 * MB, 0x4000, &off ) || res != 64 * MB) FAIL("past the end, or consumed on refusal\n");
    res = 0;
    if (ios_pool_low_take( &res, 64 * MB, 128 * MB, &off ) || res != 0) FAIL("larger than C\n");
    printf("PASS: region C's bump never passes its end and consumes nothing when it refuses\n");

    /* Social Club layout 2: C's alias at 0x7900000000, the pool's above it */
    {
        uint64_t prx = 0x14a000000ull, psz = 0x36000000ull, crx = 0x12e000000ull, csz = 0x12000000ull;
        uint64_t prw = IOS_SC2_RW_ALIAS + (prx - crx);
        ios_pool_alias_extent( prx, prw, psz, crx, csz, &lo, &span );
        if (lo != IOS_SC2_RW_ALIAS || span != psz + (prx - crx)) FAIL("alias extent\n");
        if (ios_sc_layout_pick( "2", lo, span ) != 2) FAIL("layout 2 lost with region C\n");
        if (ios_sc_layout_pick( "2", prw, psz ) != 1) FAIL("the pool's base alone should not pass for layout 2\n");
        if (lo + span > IOS_SC2_CAGE_BASE || lo < IOS_SC2_E_BASE + IOS_SC2_POOL_REAL) FAIL("the reservation hits a hold\n");
        ios_pool_alias_extent( prx, IOS_SC2_RW_ALIAS, psz, 0, 0, &lo, &span );
        if (lo != IOS_SC2_RW_ALIAS || span != psz || ios_sc_layout_pick( "2", lo, span ) != 2) FAIL("layout 2 without C\n");
        /* the whole band below the window plus the full band above it still fits the 4 GB */
        ios_pool_alias_extent( 0x148000000ull, IOS_SC2_RW_ALIAS + (0x148000000ull - 0x119000000ull), 0x38000000ull,
                               0x119000000ull, 0x27000000ull, &lo, &span );
        if (span > IOS_SC2_RW_MAX || ios_sc_layout_pick( "2", lo, span ) != 2) FAIL("worst case span\n");
    }
    printf("PASS: layout 2 keeps 0x%llx with region C in front of the pool's alias, ending below the V8 cage\n",
           (unsigned long long)IOS_SC2_RW_ALIAS);

    /* build 374 */
    {
        size_t without = gta374( 0, 0 ), with = gta374( 1, 0 ), lc = low_carves, tc = tail_carves, wow;
        if (lc != 7 || tc != 0) FAIL("with C: %u C carves, %u tail carves\n", low_carves, tail_carves);
        if (with < without + 7 * 16 - 16) FAIL("head %zu MB with C vs %zu MB without\n", with, without);
        wow = gta374( 1, 2 );
        if (low_carves != 3 || tail_carves != 4) FAIL("WoW64 carves went to C (%u C, %u tail)\n", low_carves, tail_carves);
        printf("PASS: build 374 shape: head %zu MB without region C, %zu MB with it (%zu C carves, %zu tail); "
               "WoW64 carves stay in the tail (head %zu MB)\n", without, with, lc, tc, wow);
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory() as t:
    c = Path(t) / 'low.c'
    c.write_text(harness)
    exe = Path(t) / 'low'
    subprocess.run(['cc', '-std=gnu11', '-O1', '-Wall', '-Wno-unused-function', '-Wno-unused-variable',
                    '-fsanitize=address,undefined', '-fno-sanitize-recover=all', str(c), '-o', str(exe)], check=True)
    out = subprocess.run([str(exe)], capture_output=True, text=True)
    print(out.stdout, end='')
    assert out.returncode == 0, out.stdout + out.stderr
