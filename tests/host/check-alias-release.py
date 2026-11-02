#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Ported from a community host check; anchors are the merged engine code's.
"""env.MADEIRA_ALIAS_RELEASE: anonymous JIT aliases follow MEM_RELEASE and MEM_DECOMMIT.

A 64-bit title froze loading a save. It released a 4 GB arena at 0x7a00000000
and reserved it again at the same base. The alias records of the code copies
it had made there (0x7a00040000, 0x7a00084000, 0x7a00090000) outlived the
release. In the new arena a decommit over them was refused whole
([alias-tomb]), and the first store found read-only pages and no alias
([store-noalias] ... prot=1 max=3).

In build/ntdll-unix/virtual_ios.c, with the switch on:
  - delete_view drops the alias records inside the view (ios_alias_release_view);
  - decommit_pages goes part by part (ios_decommit_alias_split): an alias's
    part is zeroed through its pool slot only as far as the alias reaches, and
    the parts between get the plain branch's fresh zero pages.

Checks:
  - the four functions, cut out of virtual_ios.c and compiled on the host over
    real memory with 16 KB pages, as on iOS:
      - the switch: unset, '', '0' or 'yes' is off; '1' is on;
      - split: each alias zeroed in its own pool slot only (never past it, the
        slot next to it untouched), plain parts zeroed with partial pages at
        the range's own ends, a slot handed out again left alone and named, a
        swap reservation punched instead of mapped over, an alias being
        retired skipped, the first alias part named for the read-back;
      - release: aliases inside or partly inside the view dropped (range
        first, then key, each retired from the Mono bridge), others kept, the
        pool lock released, and not taken at all for a view with no alias;
  - delete_view calls it gated, before unmap_area, never for a system view;
  - decommit_pages tries it first, gated; the old alias, plain and sub-page
    branches are unchanged, so the switch off is the old code;
  - the settings catalog documents the switch (when the catalog exists).
The host compile is skipped when no C compiler is found.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile

R = Path(__file__).resolve().parents[2]
src = (R / "build/ntdll-unix/virtual_ios.c").read_text()
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok = ok and bool(cond)


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3] + '\n'


enabled = function(src, 'static int ios_alias_release_enabled(void)')
release = function(src, 'static void ios_alias_release_view( const void *base, size_t size )')
foreign = function(src, 'static int ios_pool_foreign_overlap( uintptr_t rw_start, size_t size )')
split = function(src, 'static const char *ios_decommit_alias_split( char *base, size_t size,')
check("the switch is read once in virtual_ios.c", src.count('getenv( "MADEIRA_ALIAS_RELEASE" )') == 1)

cc = shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
if not cc:
    print("SKIP host compile: no C compiler")
else:
    harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <pthread.h>
#include <sys/mman.h>
typedef uintptr_t UINT_PTR;
typedef size_t SIZE_T;
#define ROUND_ADDR(addr,mask) ((void *)((UINT_PTR)(addr) & ~(UINT_PTR)(mask)))
#define ROUND_SIZE(addr,size,mask) (((SIZE_T)(size) + ((UINT_PTR)(addr) & (mask)) + (mask)) & ~(UINT_PTR)(mask))
static const UINT_PTR host_page_mask = 0x3fff;   /* iOS: 16 KB pages */
#define PAGE 0x4000ul

struct ios_jit_anon_alias { uintptr_t user_va, user_va_end, jit_rw_alias, jit_rx_alias; };
static struct ios_jit_anon_alias ios_jit_anon_aliases[16];
static volatile int ios_jit_anon_alias_count;

static int n_locks;
static pthread_mutex_t ios_pool_lock_real = PTHREAD_MUTEX_INITIALIZER;
static void *ios_pool_lock;
#define pthread_mutex_lock(m)   (n_locks++, pthread_mutex_lock( &ios_pool_lock_real ))
#define pthread_mutex_unlock(m) pthread_mutex_unlock( &ios_pool_lock_real )

static uint64_t retired[16];
static int n_retired;
static int range_cleared_first = 1;
void ios_mono_alias_retire( uint64_t guest_rx )
{
    int i;
    for (i = 0; i < ios_jit_anon_alias_count; i++)   /* range gone before the key goes */
        if (ios_jit_anon_aliases[i].user_va == guest_rx && ios_jit_anon_aliases[i].user_va_end)
            range_cleared_first = 0;
    retired[n_retired++] = guest_rx;
}

static void *ios_jit_rw_base_global;
static size_t ios_jit_pool_size_global;
struct ios_pool_alloc { size_t off, size; void *peb; };
static struct ios_pool_alloc ios_pool_ledger[16];
static int ios_pool_ledger_count;

static char *swap_lo, *swap_hi;
static int n_punch, n_swap_release, n_mmap;
static int ios_swap_punch_resv( char *lo, size_t len )
{
    if (lo < swap_lo || lo + len > swap_hi) return 0;
    memset( lo, 0, len );
    n_punch++;
    return 1;
}
static void ios_swap_release_range( void *base, size_t size, int copy_back ) { n_swap_release++; }
static void *anon_mmap_fixed( void *start, size_t size, int prot, int flags )
{
    n_mmap++;
    if (((uintptr_t)start | size) & host_page_mask) { printf( "mmap-over not on 16 KB pages: %p+%#zx\n", start, size ); exit( 2 ); }
    return mmap( start, size, prot, MAP_PRIVATE | MAP_ANON | MAP_FIXED | flags, -1, 0 );
}

static int n_logs;
static char last_log[512];
static int log_line( int fd, const char *fmt, ... )
{
    va_list ap;
    va_start( ap, fmt );
    vsnprintf( last_log, sizeof(last_log), fmt, ap );
    va_end( ap );
    n_logs++;
    return 0;
}
#define dprintf log_line
''' + enabled + release + foreign + split + r'''
#undef dprintf
static unsigned char *guest, *pool;
#define GSIZE 0x100000ul
#define PSIZE 0x40000ul
static int fails;

static void fail( const char *what ) { printf( "FAIL %s\n", what ); fails++; }

static void reset( void )
{
    memset( guest, 0xaa, GSIZE );
    memset( pool, 0xbb, PSIZE );
    memset( ios_jit_anon_aliases, 0, sizeof(ios_jit_anon_aliases) );
    ios_jit_anon_alias_count = 0;
    ios_pool_ledger_count = 0;
    swap_lo = swap_hi = NULL;
    n_punch = n_swap_release = n_mmap = n_logs = n_locks = n_retired = 0;
    range_cleared_first = 1;
}

/* an alias at guest+g, size n, in its own ledgered pool slot at pool+p */
static void alias( size_t g, size_t n, size_t p )
{
    int i = ios_jit_anon_alias_count++;
    ios_jit_anon_aliases[i].user_va = (uintptr_t)guest + g;
    ios_jit_anon_aliases[i].user_va_end = (uintptr_t)guest + g + n;
    ios_jit_anon_aliases[i].jit_rw_alias = (uintptr_t)pool + p;
    ios_jit_anon_aliases[i].jit_rx_alias = 0x14e000000ul + p;
    ios_pool_ledger[ios_pool_ledger_count].off = p;
    ios_pool_ledger[ios_pool_ledger_count].size = n;
    ios_pool_ledger[ios_pool_ledger_count++].peb = (void *)0x71ffff0000ul;
}

/* every byte of [lo, hi) is v */
static int all( const unsigned char *b, size_t lo, size_t hi, unsigned char v )
{
    size_t i;
    for (i = lo; i < hi; i++) if (b[i] != v) return 0;
    return 1;
}

static void expect_bytes( const char *what, const unsigned char *b, size_t lo, size_t hi, unsigned char v )
{
    if (!all( b, lo, hi, v ))
    {
        printf( "  %s [%#zx,%#zx) is not all %02x\n", b == guest ? "guest" : "pool", lo, hi, v );
        fail( what );
    }
}

static void test_split( void )
{
    const void *verify = NULL;
    size_t vsize = 0;
    const char *branch;

    /* the reported shape: aliases A0, A1+A2 (adjacent slots), a slot handed out again
     * (A4), an alias outside the range (A3); the range starts and ends mid-page */
    reset();
    alias( 0x10000, PAGE, 0x0000 );        /* A0 */
    alias( 0x20000, 3 * PAGE, 0x4000 );    /* A1 */
    alias( 0x2c000, PAGE, 0x10000 );       /* A2 */
    alias( 0x80000, 3 * PAGE, 0x14000 );   /* A3, outside the range */
    alias( 0x40000, PAGE, 0x24000 );       /* A4 */
    ios_pool_ledger[ios_pool_ledger_count].off = 0x26000;   /* a module now overlaps A4's slot */
    ios_pool_ledger[ios_pool_ledger_count++].size = 0x4000;
    branch = ios_decommit_alias_split( (char *)guest + 0x9000, 0x4a000 - 0x9000, &verify, &vsize );
    expect_bytes( "split: guest below the range untouched", guest, 0x0, 0x9000, 0xaa );
    expect_bytes( "split: plain part with a partial first page zeroed", guest, 0x9000, 0x10000, 0 );
    expect_bytes( "split: A0's guest bytes not written (the pool backs them)", guest, 0x10000, 0x14000, 0xaa );
    expect_bytes( "split: plain part between A0 and A1 zeroed", guest, 0x14000, 0x20000, 0 );
    expect_bytes( "split: A1/A2 guest bytes not written", guest, 0x20000, 0x30000, 0xaa );
    expect_bytes( "split: plain part between A2 and A4 zeroed", guest, 0x30000, 0x40000, 0 );
    expect_bytes( "split: A4 (slot handed out again) guest bytes kept", guest, 0x40000, 0x44000, 0xaa );
    expect_bytes( "split: last plain part with a partial last page zeroed", guest, 0x44000, 0x4a000, 0 );
    expect_bytes( "split: guest above the range untouched", guest, 0x4a000, GSIZE, 0xaa );
    expect_bytes( "split: A0, A1 and A2 zeroed in their slots", pool, 0x0, 0x14000, 0 );
    expect_bytes( "split: A3's slot untouched", pool, 0x14000, 0x20000, 0xbb );
    expect_bytes( "split: A4's slot kept, and the pool above it", pool, 0x20000, PSIZE, 0xbb );
    if (strcmp( branch, "alias-split(PART KEPT, not zeroed)" )) fail( "split: a kept part is named in the branch" );
    if (verify != pool || vsize != PAGE) fail( "split: the read-back names A0's slot" );
    if (n_mmap != 4 || n_swap_release != 4 || n_punch) fail( "split: four plain parts mapped over" );
    if (n_logs != 1 || !strstr( last_log, "3 alias part(s) zeroed in the pool, 4 plain part(s) (0 swap hole(s)), 1 part(s) kept" ))
        { printf( "  log: %s", last_log ); fail( "split: one [alias-release] line with the counts" ); }

    /* a decommit that starts at an alias and runs far past it (the 128 MB one at
     * 0x7a00040000): A0 is zeroed in its slot only, never 0x30000 bytes from it */
    reset();
    alias( 0x10000, PAGE, 0x0000 );
    alias( 0x20000, PAGE, 0x4000 );
    verify = NULL;
    branch = ios_decommit_alias_split( (char *)guest + 0x10000, 0x30000, &verify, &vsize );
    expect_bytes( "past an alias: its slot zeroed", pool, 0x0, 0x8000, 0 );
    expect_bytes( "past an alias: the pool after its slot untouched", pool, 0x8000, PSIZE, 0xbb );
    expect_bytes( "past an alias: plain parts zeroed", guest, 0x14000, 0x20000, 0 );
    expect_bytes( "past an alias: plain parts zeroed (2)", guest, 0x24000, 0x40000, 0 );
    if (strcmp( branch, "alias-split" )) fail( "past an alias: branch alias-split" );

    /* 4 KB inside a live alias (the [alias-tomb] refusals at 0x7a00093000): zeroed in its
     * slot, even though the slot is in the ledger */
    reset();
    alias( 0x20000, 3 * PAGE, 0x4000 );
    verify = NULL;
    branch = ios_decommit_alias_split( (char *)guest + 0x2b000, 0x1000, &verify, &vsize );
    expect_bytes( "4 KB inside an alias: zeroed in the slot", pool, 0xf000, 0x10000, 0 );
    expect_bytes( "4 KB inside an alias: the rest of the slot kept", pool, 0x4000, 0xf000, 0xbb );
    expect_bytes( "4 KB inside an alias: nothing else", pool, 0x10000, PSIZE, 0xbb );
    expect_bytes( "4 KB inside an alias: guest untouched", guest, 0, GSIZE, 0xaa );
    if (verify != pool + 0xf000 || vsize != 0x1000 || n_mmap) fail( "4 KB inside an alias: read-back, no mapping" );

    /* a swap reservation is punched, not mapped over */
    reset();
    alias( 0x10000, PAGE, 0x0000 );
    swap_lo = (char *)guest + 0x14000;
    swap_hi = (char *)guest + 0x20000;
    verify = NULL;
    ios_decommit_alias_split( (char *)guest + 0x10000, 0x10000, &verify, &vsize );
    if (n_punch != 1 || n_mmap || n_swap_release) fail( "swap: the plain part is punched" );
    expect_bytes( "swap: the punched part reads zero", guest, 0x14000, 0x20000, 0 );

    /* an alias being retired (range cleared, key not yet) is not used */
    reset();
    alias( 0x10000, PAGE, 0x0000 );
    ios_jit_anon_aliases[0].user_va_end = 0;
    verify = NULL;
    ios_decommit_alias_split( (char *)guest + 0x10000, PAGE, &verify, &vsize );
    expect_bytes( "retiring alias: its slot untouched", pool, 0, PSIZE, 0xbb );
    expect_bytes( "retiring alias: the range is plain", guest, 0x10000, 0x14000, 0 );

    /* the log is capped: 5 calls above, then 2100 more: lines for calls 6..32, 1024 and 2048 */
    reset();
    alias( 0x10000, PAGE, 0x0000 );
    {
        int i;
        for (i = 0; i < 2100; i++) ios_decommit_alias_split( (char *)guest + 0x10000, PAGE, &verify, &vsize );
        if (n_logs != 27 + 2) { printf( "  %d lines\n", n_logs ); fail( "split: at most 32 lines, then every 1024th" ); }
    }
}

static void test_release( void )
{
    reset();
    alias( 0x10000, PAGE, 0x0000 );       /* 0: inside the view */
    alias( 0x20000, 3 * PAGE, 0x4000 );   /* 1: inside */
    alias( 0x3c000, 2 * PAGE, 0x10000 );  /* 2: ends past the view: partly inside */
    alias( 0x40000, PAGE, 0x18000 );      /* 3: starts at the view's end */
    alias( 0x80000, PAGE, 0x1c000 );      /* 4: elsewhere */
    ios_alias_release_view( guest, 0x40000 );
    if (ios_jit_anon_aliases[0].user_va || ios_jit_anon_aliases[0].user_va_end ||
        ios_jit_anon_aliases[1].user_va || ios_jit_anon_aliases[2].user_va) fail( "release: aliases inside the view dropped" );
    if (!ios_jit_anon_aliases[3].user_va || !ios_jit_anon_aliases[4].user_va ||
        ios_jit_anon_aliases[3].user_va_end != (uintptr_t)guest + 0x44000) fail( "release: other aliases kept" );
    if (n_retired != 3 || retired[0] != (uintptr_t)guest + 0x10000 || retired[2] != (uintptr_t)guest + 0x3c000)
        fail( "release: each dropped alias retired from the Mono bridge" );
    if (!range_cleared_first) fail( "release: the range is cleared before the key" );
    if (n_locks != 1) fail( "release: the pool lock taken once" );
    if (pthread_mutex_trylock( &ios_pool_lock_real )) fail( "release: the pool lock released" );
    else pthread_mutex_unlock( &ios_pool_lock_real );
    if (n_logs != 3 || !strstr( last_log, "[alias-release] anon RWX alias" )) fail( "release: one line per dropped alias" );
    if (all( pool, 0, PSIZE, 0xbb ) != 1 || all( guest, 0, GSIZE, 0xaa ) != 1) fail( "release: no memory written" );

    /* a view with no alias: one scan, no lock */
    n_locks = n_logs = 0;
    ios_alias_release_view( guest + 0x90000, 0x10000 );
    if (n_locks || n_logs) fail( "release: a view with no alias takes no lock" );
}

int main( int argc, char **argv )
{
    if (argc > 1 && !strcmp( argv[1], "switch" ))
    {
        printf( "%d\n", ios_alias_release_enabled() );
        return 0;
    }
    guest = mmap( NULL, GSIZE + PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0 );
    pool = mmap( NULL, PSIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0 );
    guest = (unsigned char *)(((uintptr_t)guest + PAGE - 1) & ~(PAGE - 1));
    ios_jit_rw_base_global = pool;
    ios_jit_pool_size_global = PSIZE;
    test_split();
    test_release();
    printf( "%s\n", fails ? "HARNESS FAILED" : "harness ok" );
    return fails != 0;
}
'''
    with tempfile.TemporaryDirectory() as tmp:
        c = os.path.join(tmp, "t.c")
        exe = os.path.join(tmp, "t")
        open(c, "w").write(harness)
        flags = [cc, "-std=gnu99", "-Wall", "-Werror", "-Wno-unused-function", "-Wno-unused-parameter",
                 "-Wno-unused-variable"]
        b = subprocess.run(flags + ["-fsanitize=address,undefined", c, "-o", exe], capture_output=True, text=True)
        if b.returncode:
            b = subprocess.run(flags + [c, "-o", exe], capture_output=True, text=True)
        check("the four functions compile on the host", b.returncode == 0)
        if b.returncode == 0:
            r = subprocess.run([exe], capture_output=True, text=True)
            print(r.stdout.strip())
            check("split: each alias zeroed in its own slot only, plain parts zeroed, a slot handed out "
                  "again left alone; release: the view's aliases dropped, the others kept", r.returncode == 0)
            seen = {}
            for value in (None, "", "0", "yes", "1"):
                env = dict(os.environ)
                env.pop("MADEIRA_ALIAS_RELEASE", None)
                if value is not None:
                    env["MADEIRA_ALIAS_RELEASE"] = value
                s = subprocess.run([exe, "switch"], capture_output=True, text=True, env=env)
                seen[value] = s.stdout.strip()
            check("the switch: unset, '', '0' and 'yes' are off; '1' is on",
                  seen == {None: "0", "": "0", "0": "0", "yes": "0", "1": "1"})
        else:
            print(b.stderr[-3000:])

delete = function(src, 'static void delete_view( struct file_view *view )')
gate = ('    if (!(view->protect & VPROT_SYSTEM) && ios_alias_release_enabled())\n'
        '        ios_alias_release_view( view->base, view->size );')
check("delete_view drops the aliases, gated, never for a system view, before unmap_area",
      delete.count(gate) == 1 and delete.index(gate) < delete.index('unmap_area( view->base, view->size );'))
check("release and split run only from those two places",
      src.count('ios_alias_release_view(') == 2 and src.count('ios_decommit_alias_split(') == 2)

decommit = function(src, 'static NTSTATUS decommit_pages( struct file_view *view, char *base, size_t size )')
# the split line may carry a trailing comment; only the code is anchored
first = re.compile(re.escape('        uintptr_t rw_alias = ios_jit_anon_alias_lookup( (uintptr_t)base );\n'
                             '        if (ios_alias_release_enabled() && ios_jit_anon_alias_overlaps( base, size, NULL, NULL ))\n'
                             '            dc_branch = ios_decommit_alias_split( base, size, &dc_verify, &dc_vsize );')
                   + r'[^\n]*\n' + re.escape('        else if (rw_alias)\n'))
check("decommit_pages tries the split first, gated, then the old alias branch", first.search(decommit) is not None)
check("the old branches are unchanged: the [alias-tomb] refusal, the alias memset, the plain "
      "mmap-over and the sub-page memset",
      'if (ios_pool_live_overlap( rw_alias, size, &l_off, &l_peb ))' in decommit and
      'dc_branch = "alias-REFUSED(NOT zeroed)";' in decommit and
      'memset( (void *)rw_alias, 0, size );\n                dc_branch = "alias-memset";' in decommit and
      'anon_mmap_fixed( host_start, host_end - host_start, PROT_READ | PROT_WRITE, 0 );\n'
      '                dc_branch = "mmap-over";' in decommit and
      'dc_branch = "subpage-memset";' in decommit)
check("split's plain part does what the plain branch does",
      'if (ios_swap_punch_resv( hs, he - hs )) n_hole++;' in split and
      'ios_swap_release_range( hs, he - hs, 0 );' in split and
      'anon_mmap_fixed( hs, he - hs, PROT_READ | PROT_WRITE, 0 );' in split)
check("it logs [alias-release] at most 32 times per kind, then every 1024th",
      'if (++n_calls <= 32 || (n_calls % 1024) == 0)' in split and
      'if (n_logged < 32 || (n_dropped % 1024) == 0)' in release)

catalog = R / "app/Madeira/ConfigCatalog.generated.swift"
if catalog.exists():
    cat = catalog.read_text()
    check("the catalog documents env.MADEIRA_ALIAS_RELEASE (default 0)",
          'ConfigOption(key: "env.MADEIRA_ALIAS_RELEASE", title: "Drop a released arena\'s code copies", '
          'kind: .bool, defaultValue: "0"' in cat)

print("PASS: alias release" if ok else "FAILED: alias release")
sys.exit(0 if ok else 1)
