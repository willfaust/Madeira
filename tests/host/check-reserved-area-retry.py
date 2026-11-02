#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Ported from a community host check; anchors are the merged engine code's.
"""A MAP_FIXED over a guest window that the kernel refuses is retried at the next free range (small address maps only).

A 32-bit program on a 63 GB address map: a 0x11000-byte section map inside the guest window
[0x400000000,0x500000000) ended in STATUS_NO_MEMORY with a 2 GB gap free, and ucrtbase's init failed (c0000142).
The errno=17 in [va-scan] is only map_free_area's no-clobber probe finding our own PROT_NONE reservation; the
placement itself is map_reserved_area's MAP_FIXED over that reservation, which returned NULL in silence.

virtual_ios.c now retries the next free range after an ENOMEM from that MAP_FIXED (ios_reserved_retry), only when
ios_wow_small_va_slots is set (a small address map; env.MADEIRA_RESERVED_RETRY = 0 makes it one attempt again), and
says why on the failing path: [reserved-area] (the refusal), and STAGE= on the [map-sec] and ml985 refusals, so the
next log tells the refusal from create_view. The retry is a recovery for the first reading, not a proof.

Later the same refusal ended an 8 MB request (a Direct3D 9 buffer, then a WoW64 stack): all 32 retries are 64 KB
apart, so they cover 2 MB of range, and the [reserved-area] budget of eight lines had been spent by the small
requests at load time. Now: a request of 1 MB or more has its own budget, every refused candidate
and the kernel's regions across the refused range are logged (and what the first candidate after a refusal held before it
was mapped), and, only when the placement ended in NULL after a refusal on a small address map, the first refused
candidate is unmapped and mapped again without overwriting (ios_reserved_remap; env.MADEIRA_RESERVED_REMAP = 0 turns it off).
The retry loop itself is unchanged. The whole of map_reserved_area_inner is compiled and run against fakes: nothing but a
refused, unplaced chain reaches the new code, and a healthy placement reads no region.

Source checks (every host) hold the shape; the retry loop is then compiled and run against fakes.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
ok = True


def check(what, cond, detail=''):
    global ok
    print(('ok   ' if cond else 'FAIL ') + what + (('\n     ' + detail) if (detail and not cond) else ''))
    ok = ok and bool(cond)


def function(signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


retry_fn = function('static void *ios_reserved_retry(')
typedefs = source[source.index('typedef void *(*ios_reserved_once_fn)'):source.index('static void *ios_reserved_retry(')]
inner_fn = function('static void *map_reserved_area_inner( void *limit_low, void *limit_high, size_t size, int top_down,\n'
                    '                                      int unix_prot, size_t align_mask )\n{\n    struct ios_reserved_ctx')
once_fn = function('static void *map_reserved_area_once( void *limit_low, void *limit_high, void *ctx_, void **refused, int *err )\n{')
retry_on_fn = function('static int ios_reserved_retry_enabled(void)')

check('the retry loop only calls the placement again; it maps, protects and unmaps nothing itself',
      all(m not in retry_fn for m in ('mmap(', 'munmap(', 'mprotect(', 'anon_mmap', 'memset(', 'memcpy(')))
check('a retry happens only after the kernel said ENOMEM, only up to the given number of tries',
      'while (!ptr && refused && err == ENOMEM && n < max_tries)' in retry_fn)
check('each retry lies strictly above (bottom-up) or below (top-down) the refused address',
      'if (top_down) high = (char *)refused + size - 1;' in retry_fn
      and 'else low = (char *)refused + align_mask + 1;' in retry_fn)
check('the retry is on only on a small address map (ios_wow_small_va_slots), zero tries elsewhere',
      '(ios_wow_small_va_slots && ios_reserved_retry_enabled()) ? IOS_RESERVED_RETRY_MAX : 0' in inner_fn
      and '#define IOS_RESERVED_RETRY_MAX 32' in source)
check('env.MADEIRA_RESERVED_RETRY: read once, on unless exactly "0" (then one attempt, as before)',
      'static int on = -1;' in retry_on_fn and 'getenv( "MADEIRA_RESERVED_RETRY" )' in retry_on_fn
      and "on = !(e && e[0] == '0' && !e[1]);" in retry_on_fn)
check('the placement is still one MAP_FIXED over the reservation, and a failure of it is reported, not hidden',
      once_fn.count('anon_mmap_fixed(') == 1 and '*refused = ptr;' in once_fn and '*err = errno;' in once_fn)
check('a search that finds no range still returns NULL with no refusal recorded (nothing is retried)',
      once_fn.count('return NULL;') == 2 and 'refused' not in once_fn[:once_fn.index('if (top_down)')].replace('void **refused', ''))
check('the refusal is logged once-capped, with what Mach says about the address',
      '++ra_n <= 8' in inner_fn and 'ios_va_describe( first_refused' in inner_fn)
check('map_fixed_area (a fixed address) is untouched', source.count('static NTSTATUS map_fixed_area(') == 1
      and 'ios_reserved_retry' not in function('static NTSTATUS map_fixed_area('))

remap_fn = function('static void *ios_reserved_remap(')
check('the retry loop is as it was (the refused candidates are recorded by the placement, not by the loop)',
      retry_fn.count('once(') == 2 and 'ctx' in retry_fn and 'refused_list' not in retry_fn and 'ios_va_regions' not in retry_fn)
check('the last resort runs only when the placement is still NULL after a refusal, ENOMEM, a small address map, key on',
      'if (!ptr && first_err == ENOMEM && ios_wow_small_va_slots && ios_reserved_remap_enabled())' in inner_fn
      and inner_fn.index('if (first_refused)') < inner_fn.index('ios_reserved_remap( first_refused'))
check('the last resort touches only a candidate Wine calls free: no view, wholly inside one reserved area, not the JIT pool',
      'find_view_range( addr, size )' in remap_fn and 'mmap_is_in_reserved_area( addr, size ) != 1' in remap_fn
      and 'ios_jit_pool_intersects( addr, size )' in remap_fn
      and remap_fn.index('find_view_range') < remap_fn.index('munmap(') and remap_fn.index('ios_jit_pool_intersects') < remap_fn.index('munmap('))
check('the last resort puts the PROT_NONE reservation back when the no-overwrite map fails',
      'anon_mmap_fixed( addr, size, PROT_NONE, MAP_NORESERVE )' in remap_fn and remap_fn.index('anon_mmap_tryfixed(') < remap_fn.index('anon_mmap_fixed('))
check('the new kernel reads (regions, the candidate after a refusal) happen only after a refusal',
      once_fn.count('ios_va_regions(') == 1 and 'if (ptr && ctx->nrefused)' in once_fn
      and inner_fn.count('ios_va_regions(') == 1 and inner_fn.index('ios_va_regions(') > inner_fn.index('if (first_refused)'))
check('requests of 1 MB or more have a budget of their own (64, then every 64th); the small ones keep eight then every 256th',
      'int first_err, show = 0, big = size >= 0x100000;' in inner_fn
      and 'show = big ? (++ra_big_n <= 64 || !(ra_big_n % 64)) : (++ra_n <= 8 || !(ra_n % 256));' in inner_fn)
check('the first [reserved-area] line keeps its words (tools and earlier logs read them)',
      '"[reserved-area] #%lu MAP_FIXED over our own reservation refused: %p+0x%lx errno=%d (%s) | %s | "' in inner_fn
      and re.search(re.escape('"%s (%u refused in all; small address map retry %s)') + r'(?: rev=\S+)?\\n"', inner_fn) is not None)
catalog = root / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    check('the catalog lists env.MADEIRA_RESERVED_REMAP', '"env.MADEIRA_RESERVED_REMAP"' in catalog.read_text())

cc = shutil.which(os.environ.get('CC', 'cc')) or shutil.which('clang') or shutil.which('gcc')
if not cc:
    print('SKIP host compile: no C compiler')
    sys.exit(0 if ok else 1)

harness = r'''
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
''' + typedefs + retry_fn + r'''
/* a window of candidate 64 KB-aligned addresses; `bad` ones are refused with `bad_err` */
#define NCAND 8
static uintptr_t cand[NCAND];
static int bad[NCAND], bad_err = ENOMEM;
static unsigned calls;

static void *once_fake( void *low, void *high, void *ctx, void **refused, int *err )
{
    size_t size = *(size_t *)ctx;
    int i;
    (void)size; calls++;
    /* bottom-up: the lowest candidate in [low, high - size]; top-down is tested through `topdown` below */
    for (i = 0; i < NCAND; i++)
    {
        uintptr_t a = cand[i];
        if (a < (uintptr_t)low || a + size > (uintptr_t)high) continue;
        if (bad[i]) { *refused = (void *)a; *err = bad_err; return NULL; }
        return (void *)a;
    }
    return NULL;
}
static void *once_fake_td( void *low, void *high, void *ctx, void **refused, int *err )
{
    size_t size = *(size_t *)ctx;
    int i;
    calls++;
    for (i = NCAND - 1; i >= 0; i--)
    {
        uintptr_t a = cand[i];
        if (a < (uintptr_t)low || a + size > (uintptr_t)high) continue;
        if (bad[i]) { *refused = (void *)a; *err = bad_err; return NULL; }
        return (void *)a;
    }
    return NULL;
}

int main(void)
{
    size_t size = 0x14000, align_mask = 0xffff;
    unsigned n; void *first; int err, i;
    void *p;
    for (i = 0; i < NCAND; i++) { cand[i] = 0x400110000UL + (uintptr_t)i * 0x100000; bad[i] = 0; }
    void *lo = (void *)0x400110000UL, *hi = (void *)0x500000000UL;

    /* nothing refused: placed at the first range, no retry, nothing recorded */
    calls = 0;
    p = ios_reserved_retry( lo, hi, size, 0, align_mask, 32, once_fake, &size, &n, &first, &err );
    assert( p == (void *)cand[0] && n == 0 && first == NULL && calls == 1 );

    /* two refusals bottom-up: the third range is taken; the first refusal is the one reported */
    bad[0] = bad[1] = 1; calls = 0;
    p = ios_reserved_retry( lo, hi, size, 0, align_mask, 32, once_fake, &size, &n, &first, &err );
    assert( p == (void *)cand[2] && n == 2 && first == (void *)cand[0] && err == ENOMEM && calls == 3 );

    /* the same on a 512 GB map (zero tries): the refusal is reported and nothing is retried, as before */
    calls = 0;
    p = ios_reserved_retry( lo, hi, size, 0, align_mask, 0, once_fake, &size, &n, &first, &err );
    assert( p == NULL && n == 1 && first == (void *)cand[0] && calls == 1 );

    /* top-down: the highest candidates are refused, the next lower is taken */
    memset( bad, 0, sizeof bad ); bad[NCAND - 1] = bad[NCAND - 2] = 1; calls = 0;
    p = ios_reserved_retry( lo, hi, size, 1, align_mask, 32, once_fake_td, &size, &n, &first, &err );
    assert( p == (void *)cand[NCAND - 3] && n == 2 && first == (void *)cand[NCAND - 1] && calls == 3 );

    /* only ENOMEM is retried: EEXIST (someone else's mapping) is not */
    memset( bad, 0, sizeof bad ); bad[0] = 1; bad_err = EEXIST; calls = 0;
    p = ios_reserved_retry( lo, hi, size, 0, align_mask, 32, once_fake, &size, &n, &first, &err );
    assert( p == NULL && n == 1 && err == EEXIST && calls == 1 );
    bad_err = ENOMEM;

    /* the cap holds */
    for (i = 0; i < NCAND; i++) bad[i] = 1;
    calls = 0;
    p = ios_reserved_retry( lo, hi, size, 0, align_mask, 3, once_fake, &size, &n, &first, &err );
    assert( p == NULL && calls == 4 && n == 4 );

    /* every candidate refused and nothing left: the loop ends with NULL */
    calls = 0;
    p = ios_reserved_retry( lo, hi, size, 0, align_mask, 32, once_fake, &size, &n, &first, &err );
    assert( p == NULL && calls == NCAND + 1 && n == NCAND );

    /* a search that finds no range at all is not a refusal */
    memset( bad, 0, sizeof bad ); calls = 0;
    p = ios_reserved_retry( (void *)0x600000000UL, (void *)0x700000000UL, size, 0, align_mask, 32, once_fake, &size, &n, &first, &err );
    assert( p == NULL && n == 0 && first == NULL && calls == 1 );

    puts( "PASS: retry after ENOMEM (bottom-up, top-down), none on a 512 GB map, none for other errors, capped, none without a refusal" );
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='reserved-area-retry-') as directory:
    temp = Path(directory)
    unit = temp / 'retry.c'
    unit.write_text(harness)
    exe = temp / 'retry'
    subprocess.run([cc, '-std=c11', '-D_DARWIN_C_SOURCE', '-D_GNU_SOURCE', '-Wall', '-Wextra',
                    '-Werror', str(unit), '-o', str(exe)], check=True)
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    check('the retry loop behaves against fake placements', r.returncode == 0, r.stderr)

# ---- the whole placement (map_reserved_area_inner) against fakes: the last resort, the budgets, the healthy path ----
ctx_struct = source[source.index('struct ios_reserved_ctx\n{'):]
ctx_struct = ctx_struct[:ctx_struct.index('};') + 3]
remap_region = retry_on_fn + function('static int ios_reserved_remap_enabled(void)') + remap_fn
harness2 = r"""
#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#define IOS_RESERVED_RETRY_MAX 32
struct file_view { int x; };
typedef unsigned long SIZE_T;
/* ---- the kernel and Wine's tables, faked ---- */
static int view_overlaps, in_area = 1, pool_hit, unmap_rc, unmap_errno = EACCES, tryfixed_ok = 1, restore_ok = 1;
static unsigned n_unmap, n_try, n_restore, n_regions, n_describe;
static void *last_unmap, *last_try, *last_restore;
static int last_try_prot = -1, last_restore_prot = -1;
static struct file_view dummy_view;
static struct file_view *find_view_range( const void *a, size_t s ) { (void)a; (void)s; return view_overlaps ? &dummy_view : NULL; }
static int mmap_is_in_reserved_area( void *a, SIZE_T s ) { (void)a; (void)s; return in_area; }
static int ios_jit_pool_intersects( const void *a, size_t s ) { (void)a; (void)s; return pool_hit; }
static void ios_pool_va_warn( const char *w, const void *a, size_t s ) { (void)w; (void)a; (void)s; }
static int fake_munmap( void *a, size_t s ) { (void)s; n_unmap++; last_unmap = a; if (unmap_rc) errno = unmap_errno; return unmap_rc; }
static void *anon_mmap_tryfixed( void *a, size_t s, int prot, int flags ) { (void)s; (void)flags; n_try++; last_try = a; last_try_prot = prot; if (tryfixed_ok) return a; errno = ENOMEM; return MAP_FAILED; }
void *anon_mmap_fixed( void *a, size_t s, int prot, int flags ) { (void)s; (void)flags; n_restore++; last_restore = a; last_restore_prot = prot; if (restore_ok) return a; errno = ENOMEM; return MAP_FAILED; }
#define munmap fake_munmap
static unsigned ios_wow_small_va_slots = 12;
static char logbuf[200000]; static unsigned nlines_first, nlines_detail, nlines_last;
static int dprintf_fake( int fd, const char *fmt, ... )
{
    char line[1500]; va_list ap; (void)fd;
    va_start( ap, fmt ); vsnprintf( line, sizeof(line), fmt, ap ); va_end( ap );
    if (strstr( line, " detail: " )) nlines_detail++;
    else if (strstr( line, "last resort at" ) && !strstr( line, "MAP_FIXED over" )) nlines_last++;
    else if (strstr( line, "MAP_FIXED over our own reservation refused" )) nlines_first++;
    if (strlen( logbuf ) + strlen( line ) < sizeof(logbuf) - 2) strcat( logbuf, line );
    return 0;
}
#define dprintf dprintf_fake
static void ios_va_describe( void *a, char *b, size_t n ) { (void)a; n_describe++; snprintf( b, n, "OCCUPIED fake prot=0/0" ); }
static void ios_va_regions( void *a, size_t s, char *b, size_t n ) { (void)a; (void)s; n_regions++; snprintf( b, n, "0xA+0x10000 0/0" ); }
""" + ctx_struct + typedefs + retry_fn + remap_region + r"""
/* the scripted placement: the first `refuse` candidates (64 KB apart from 0x40f8c0000) are refused with `ref_err`, then one is taken (or never) */
static unsigned refuse, ref_err = ENOMEM, called; static int never_place;
static void *map_reserved_area_once( void *limit_low, void *limit_high, void *ctx_, void **refused, int *err );
""" + inner_fn + r"""
static void *map_reserved_area_once( void *limit_low, void *limit_high, void *ctx_, void **refused, int *err )
{
    struct ios_reserved_ctx *ctx = ctx_;
    void *ptr;
    (void)limit_high;
    ptr = (void *)((uintptr_t)limit_low > 0x40f8c0000UL ? (uintptr_t)limit_low : 0x40f8c0000UL);
    called++;
    if (ptr && ctx->nrefused) { ctx->next_pre_addr = ptr; ios_va_regions( ptr, ctx->size, ctx->next_pre, sizeof(ctx->next_pre) ); }
    if (never_place || ctx->nrefused < refuse)
    {
        *refused = ptr; *err = (int)ref_err;
        if (ctx->nrefused < 40) ctx->refused_list[ctx->nrefused] = ptr;
        ctx->nrefused++;
        return NULL;
    }
    return ptr;
}
static void *place( size_t size, int unix_prot )
{
    called = 0;
    return map_reserved_area_inner( (void *)0x400110000UL, (void *)0x500000000UL, size, 0, unix_prot, 0xffff );
}
static void reset( void )
{
    n_unmap = n_try = n_restore = n_regions = n_describe = 0; last_unmap = last_try = last_restore = NULL;
    view_overlaps = pool_hit = unmap_rc = 0; in_area = 1; tryfixed_ok = restore_ok = 1; ref_err = ENOMEM; never_place = 0;
    ios_wow_small_va_slots = 12; refuse = 0; logbuf[0] = 0; nlines_first = nlines_detail = nlines_last = 0;
}
int main( int argc, char **argv )
{
    void *p;
    int i;
    if (argc > 1 && !strcmp( argv[1], "budget" ))
    {
    /* log budgets: small requests eight lines then every 256th; 1 MB and more 64 then every 64th */
    reset(); never_place = 1; ios_wow_small_va_slots = 0;       /* no last resort, one refusal per chain: only the logging */
    for (i = 0; i < 300; i++) place( 0x14000, 3 );
    {
        assert( nlines_first == 8 + 1 );     /* eight, then the 256th */
    }
    reset(); never_place = 1; ios_wow_small_va_slots = 0;
    for (i = 0; i < 200; i++) place( 0x810000, 3 );
    assert( nlines_first == 64 + 2 );        /* 64, then the 128th and the 192nd */

        puts( "PASS: log budgets" );
        return 0;
    }
    if (argc > 1 && !strcmp( argv[1], "off" ))
    {
        /* env.MADEIRA_RESERVED_REMAP = 0 (read once per process): the retry and the logging as before, no last resort */
        reset(); never_place = 1; p = place( 0x810000, 3 );
        assert( p == NULL && n_unmap == 0 && n_try == 0 && n_restore == 0 && called == 33 && nlines_first == 1 && nlines_detail == 1 );
        assert( !strstr( logbuf, "last resort" ) );
        puts( "PASS: MADEIRA_RESERVED_REMAP=0 keeps the retry and the log, and does no last resort" );
        return 0;
    }

    /* healthy: placed first time: nothing read from the kernel, nothing logged, no remap */
    reset(); p = place( 0x810000, 3 );
    assert( p == (void *)0x40f8c0000UL && n_regions == 0 && n_describe == 0 && n_unmap == 0 && logbuf[0] == 0 );

    /* the small case: nine refusals, the retry places it: logged, but no last resort */
    reset(); refuse = 9; p = place( 0x14000, 3 );
    assert( p == (void *)(0x40f8c0000UL + 9 * 0x10000UL) && n_unmap == 0 && n_try == 0 && nlines_first == 1 && nlines_detail == 1 );
    assert( strstr( logbuf, "it took the mapping" ) && strstr( logbuf, "9 candidate(s) refused" ) && !strstr( logbuf, "last resort" ) );

    /* the 8 MB case: every retry refused (33 candidates): the last resort maps the FIRST refused candidate */
    reset(); never_place = 1; p = place( 0x810000, 3 );
    assert( p == (void *)0x40f8c0000UL && n_unmap == 1 && last_unmap == (void *)0x40f8c0000UL && n_try == 1 && last_try == last_unmap
            && last_try_prot == 3 && n_restore == 0 );
    assert( strstr( logbuf, "munmap then a no-overwrite map placed it" ) && strstr( logbuf, "(it was refused too)" ) && strstr( logbuf, "[reserved-area] #1 detail" ) );
    assert( strstr( logbuf, "the last resort placed it" ) );
    assert( strstr( logbuf, "33 candidate(s) refused" ) && strstr( logbuf, "(>= 1 MB, own budget)" ) );

    /* the no-overwrite map fails too: the reservation goes back as PROT_NONE and the request fails as before */
    reset(); never_place = 1; tryfixed_ok = 0; p = place( 0x810000, 3 );
    assert( p == NULL && n_unmap == 1 && n_try == 1 && n_restore == 1 && last_restore == (void *)0x40f8c0000UL && last_restore_prot == PROT_NONE );
    assert( strstr( logbuf, "reservation put back" ) );
    reset(); never_place = 1; tryfixed_ok = 0; restore_ok = 0; p = place( 0x810000, 3 );
    assert( p == NULL && strstr( logbuf, "reservation NOT put back" ) );

    /* munmap refused: nothing changed, nothing else called */
    reset(); never_place = 1; unmap_rc = -1; p = place( 0x810000, 3 );
    assert( p == NULL && n_unmap == 1 && n_try == 0 && n_restore == 0 && strstr( logbuf, "munmap failed errno=" ) );

    /* a view, a partial area or the JIT pool in the way: never touched */
    reset(); never_place = 1; view_overlaps = 1; p = place( 0x810000, 3 );
    assert( p == NULL && n_unmap == 0 && n_try == 0 && n_restore == 0 && strstr( logbuf, "a view overlaps it" ) );
    reset(); never_place = 1; in_area = -1; p = place( 0x810000, 3 );
    assert( p == NULL && n_unmap == 0 && strstr( logbuf, "not wholly inside one reserved area" ) );
    reset(); never_place = 1; in_area = 0; p = place( 0x810000, 3 );
    assert( p == NULL && n_unmap == 0 );
    reset(); never_place = 1; pool_hit = 1; p = place( 0x810000, 3 );
    assert( p == NULL && n_unmap == 0 && strstr( logbuf, "touches the JIT pool" ) );

    /* a 512 GB map (no small-map slots): one refusal reported, nothing retried, nothing remapped, as before */
    reset(); never_place = 1; ios_wow_small_va_slots = 0; p = place( 0x810000, 3 );
    assert( p == NULL && called == 1 && n_unmap == 0 && n_try == 0 && nlines_first == 1 );

    /* another error than ENOMEM (someone else's mapping): neither retried nor remapped */
    reset(); never_place = 1; ref_err = EEXIST; p = place( 0x810000, 3 );
    assert( p == NULL && called == 1 && n_unmap == 0 );

    puts( "PASS: nothing but a refused, unplaced chain reaches the new code; the last resort places, restores or does nothing" );
    return 0;
}
"""
with tempfile.TemporaryDirectory(prefix='reserved-area-remap-') as directory:
    temp = Path(directory)
    unit = temp / 'remap.c'
    unit.write_text(harness2)
    exe = temp / 'remap'
    r = subprocess.run([cc, '-std=gnu11', '-D_DARWIN_C_SOURCE', '-Wall', '-Wno-unused-function', '-Wno-unused-variable',
                        '-fsanitize=address,undefined', str(unit), '-o', str(exe)], capture_output=True, text=True)
    check('the placement, the last resort and the logging compile on the host', r.returncode == 0, r.stderr[-2500:])
    if r.returncode == 0:
        r = subprocess.run([str(exe)], capture_output=True, text=True, env={**os.environ, 'ASAN_OPTIONS': 'symbolize=0'})
        sys.stdout.write(r.stdout)
        check('map_reserved_area_inner against fake kernel and tables', r.returncode == 0, (r.stdout + r.stderr)[-2500:])
        r = subprocess.run([str(exe), 'off'], capture_output=True, text=True, env={**os.environ, 'ASAN_OPTIONS': 'symbolize=0', 'MADEIRA_RESERVED_REMAP': '0'})
        sys.stdout.write(r.stdout)
        check('env.MADEIRA_RESERVED_REMAP = 0 turns the last resort off', r.returncode == 0, (r.stdout + r.stderr)[-1500:])
        r = subprocess.run([str(exe), 'budget'], capture_output=True, text=True, env={**os.environ, 'ASAN_OPTIONS': 'symbolize=0'})
        sys.stdout.write(r.stdout)
        check('the log budgets: small requests eight lines then every 256th, 1 MB and more 64 then every 64th', r.returncode == 0, (r.stdout + r.stderr)[-1500:])
        for value in ('1', '', '00', 'no'):
            r = subprocess.run([str(exe)], capture_output=True, text=True, env={**os.environ, 'ASAN_OPTIONS': 'symbolize=0', 'MADEIRA_RESERVED_REMAP': value})
            check('MADEIRA_RESERVED_REMAP=%r leaves it on (only "0" turns it off)' % value, r.returncode == 0, (r.stdout + r.stderr)[-800:])
sys.exit(0 if ok else 1)
