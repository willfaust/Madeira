#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""MEM_DECOMMIT over never-committed guest pages of a 16 KB host page (build/ntdll-unix/virtual_ios.c).

Windows accepts a MEM_DECOMMIT that also spans pages that were reserved but never
committed, and leaves those pages alone. decommit_pages zeroed the parts of the range that
its host-page mmap-over cannot cover (partial host pages at the edges, or a range inside
one host page) with a plain memset. A host page whose guest pages are all uncommitted is
PROT_NONE, so the memset faulted inside ntdll with virtual_mutex held and the calling
thread was lost. Those parts are now zeroed by ios_decommit_zero_committed, which writes
only the committed guest pages.

Compiles ios_decommit_zero_committed verbatim from virtual_ios.c against a stand-in page
table, on real memory where every host page without a committed guest page is PROT_NONE
(what get_unix_prot makes of it), under AddressSanitizer and UBSan, and checks:
  * edge and single-host-page ranges whose host page holds no committed guest page are left
    alone: no fault, nothing zeroed;
  * committed guest pages are zeroed, also beside uncommitted ones on the same host page;
  * nothing outside the range is written, and the return value counts the zeroed bytes;
  * the [decommit-skip] line stops after 32 lines (then one per 1024);
  * decommit_pages uses it for both partial edges and the single-host-page case, reads back
    only a committed first page, and clears VPROT_COMMITTED only after zeroing.
Synthetic memory only: no Wine, iOS or device.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/virtual_ios.c').read_text().replace('\r\n', '\n')
CC = os.environ.get('CC') or shutil.which('cc') or 'cc'
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def function(head):
    start = src.index(head)
    return src[start:src.index('\n}\n', start) + 3]


helper = function('static size_t ios_decommit_zero_committed( char *start, char *end )')
decommit = function('static NTSTATUS decommit_pages( struct file_view *view, char *base, size_t size )')

# ------------------------------------------------------------------ static
require(decommit.count('memset(') == 1 and 'memset( (void *)rw_alias, 0, size );' in decommit,
        'decommit_pages: the only plain memset left is the alias one (whole committed alias range)')
require('if ((char *)base < host_start) ios_decommit_zero_committed( base, host_start );' in decommit
        and 'if (host_end < (char *)base + size) ios_decommit_zero_committed( host_end, (char *)base + size );' in decommit,
        'both partial host-page edges go through ios_decommit_zero_committed')
require('size_t zeroed = ios_decommit_zero_committed( base, (char *)base + size );' in decommit,
        'a range inside one host page goes through ios_decommit_zero_committed')
require('if (get_page_vprot( base ) & VPROT_COMMITTED)\n            {\n                dc_verify = base;' in decommit,
        'the single-host-page read-back runs only when the first guest page was committed (and zeroed)')
require(decommit.rindex('ios_decommit_zero_committed(') < decommit.index('set_page_vprot_bits( base, size, 0, VPROT_COMMITTED );'),
        'VPROT_COMMITTED is cleared only after the zeroing has read it')

harness = r'''
#define _GNU_SOURCE
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef unsigned char BYTE;
typedef uintptr_t UINT_PTR;
#define VPROT_COMMITTED 0x20
#define ROUND_ADDR(addr,mask) ((void *)((UINT_PTR)(addr) & ~(UINT_PTR)(mask)))
static const UINT_PTR page_mask = 0xfff;
static const size_t page_size = 0x1000;

#define NPAGES 128                    /* guest pages in the test region */
static char *region;
static size_t host;                   /* host page: 16 KB, or the real page size if larger */
static BYTE vprot[NPAGES];

static BYTE get_page_vprot( const void *addr )
{
    const char *p = addr;
    if (p < region || p >= region + NPAGES * page_size) return 0;
    return vprot[(p - region) / page_size];
}
'''

harness_main = r'''
static sigjmp_buf jb;
static volatile int faulted;

static void on_fault( int sig )
{
    faulted = 1;
    siglongjmp( jb, 1 );
}

/* one character per guest page: 'C' committed (filled with 0xAA), '.' never committed.
 * A host page is PROT_NONE unless one of its guest pages is committed. */
static void setup( const char *pattern )
{
    size_t i, per = host / page_size, n = strlen( pattern );

    mprotect( region, NPAGES * page_size, PROT_READ | PROT_WRITE );
    memset( region, 0x55, NPAGES * page_size );
    memset( vprot, 0, sizeof(vprot) );
    for (i = 0; i < n; i++)
        if (pattern[i] == 'C')
        {
            vprot[i] = VPROT_COMMITTED | 0x03;
            memset( region + i * page_size, 0xAA, page_size );
        }
    for (i = 0; i < NPAGES; i += per)
    {
        size_t j, any = 0;
        for (j = i; j < i + per; j++) any |= vprot[j] & VPROT_COMMITTED;
        if (!any) mprotect( region + i * page_size, host, PROT_NONE );
    }
}

static int all( const char *p, size_t len, int byte )
{
    size_t i;
    for (i = 0; i < len; i++) if ((unsigned char)p[i] != byte) return 0;
    return 1;
}

/* zero guest pages [first, last) through the production helper; -1 if it faulted */
static long zero_pages( size_t first, size_t last )
{
    size_t r;
    faulted = 0;
    if (sigsetjmp( jb, 1 )) return -1;
    r = ios_decommit_zero_committed( region + first * page_size, region + last * page_size );
    return faulted ? -1 : (long)r;
}

static int check( int ok, const char *label ) { printf( "%s: %s\n", ok ? "PASS" : "FAIL", label ); return !ok; }

int main( int argc, char **argv )
{
    struct sigaction sa;
    size_t real = (size_t)sysconf( _SC_PAGESIZE ), per;
    char *raw, pat[NPAGES + 1];
    int bad = 0, i;
    long r;

    host = real > 0x4000 ? real : 0x4000;
    per = host / page_size;
    if (per * 6 > NPAGES) { printf( "SKIP: host page of %zu bytes is too large for this test\n", host ); return 0; }
    raw = mmap( NULL, NPAGES * page_size + host, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0 );
    if (raw == MAP_FAILED) return 2;
    region = (char *)(((UINT_PTR)raw + host - 1) & ~(UINT_PTR)(host - 1));

    memset( &sa, 0, sizeof(sa) );
    sa.sa_handler = on_fault;
    sigaction( SIGSEGV, &sa, NULL );
    sigaction( SIGBUS, &sa, NULL );

    if (argc > 1 && !strcmp( argv[1], "storm" ))
    {
        setup( "" );
        for (i = 0; i < 1100; i++) if (zero_pages( 0, 2 ) != 0) return 3;
        return 0;
    }

    /* a never-committed reservation: decommit its first 1 and 2 guest pages (inside one host page) */
    setup( "" );
    bad |= check( zero_pages( 0, 1 ) == 0, "one guest page of a never-committed host page: no fault, nothing zeroed" );
    bad |= check( zero_pages( 0, 2 ) == 0, "two guest pages of a never-committed host page: no fault, nothing zeroed" );

    /* 5 host pages committed, decommit 5 host pages + 3 guest pages: the tail edge is the
     * first 3 guest pages of a never-committed host page */
    memset( pat, 'C', 5 * per ); pat[5 * per] = 0;
    setup( pat );
    r = zero_pages( 5 * per, 5 * per + 3 );
    bad |= check( r == 0, "tail edge on a never-committed host page: no fault, nothing zeroed" );

    /* head edge: the range starts at guest page 1 of a host page whose only committed page is 0 */
    setup( "C" );
    r = zero_pages( 1, per );
    bad |= check( r == 0 && all( region, page_size, 0xAA ), "head edge: no fault, and the committed page before the range is untouched" );

    /* a lone committed guest page */
    memset( pat, '.', 2 * per ); pat[per] = 'C'; pat[2 * per] = 0;
    setup( pat );
    r = zero_pages( per, per + 1 );
    bad |= check( r == (long)page_size && all( region + per * page_size, page_size, 0 ), "a lone committed guest page is zeroed" );

    /* mixed host page: guest pages 0 and 2 committed, 1 not; decommit 0..2 */
    setup( "C.C" );
    r = zero_pages( 0, 3 );
    bad |= check( r == (long)(2 * page_size) && all( region, page_size, 0 ) && all( region + 2 * page_size, page_size, 0 ),
                  "mixed host page: both committed guest pages are zeroed, 2 pages counted" );
    bad |= check( all( region + 3 * page_size, (per - 3) * page_size, 0x55 ), "mixed host page: nothing past the range is written" );

    /* fully committed host page: everything in the range is zeroed, the rest kept */
    memset( pat, 'C', per ); pat[per] = 0;
    setup( pat );
    r = zero_pages( 1, per - 1 );
    bad |= check( r == (long)((per - 2) * page_size) && all( region + page_size, (per - 2) * page_size, 0 )
                  && all( region, page_size, 0xAA ) && all( region + (per - 1) * page_size, page_size, 0xAA ),
                  "committed host page: exactly the range is zeroed" );

    /* across a host-page boundary: a never-committed host page, then one with a committed page */
    memset( pat, '.', 2 * per ); pat[per + 1] = 'C'; pat[2 * per] = 0;
    setup( pat );
    r = zero_pages( per - 2, per + 2 );
    bad |= check( r == (long)page_size && all( region + (per + 1) * page_size, page_size, 0 ),
                  "across a never-committed and a committed host page: no fault, the committed page zeroed" );
    return bad;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp) / 'decommit_uncommitted.c'
    exe = Path(tmp) / 'decommit_uncommitted'
    c.write_text(harness + helper + harness_main)
    build = subprocess.run([CC, '-std=gnu11', '-g', '-O1', '-Wall', '-Wno-unused-function', '-Werror=implicit-function-declaration',
                            '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined', str(c), '-o', str(exe)],
                           capture_output=True, text=True)
    require(build.returncode == 0, 'harness compiles (ASan + UBSan)')
    if build.returncode:
        print(build.stderr[-4000:])
    else:
        env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0:handle_segv=0:handle_sigbus=0')
        run = subprocess.run([str(exe)], capture_output=True, text=True, env=env, timeout=120)
        print(run.stdout, end='')
        require(run.returncode == 0, 'every case passed, no fault, no sanitizer report')
        if run.returncode:
            print(run.stderr[-4000:])
        storm = subprocess.run([str(exe), 'storm'], capture_output=True, text=True, env=env, timeout=120)
        lines = [l for l in storm.stderr.splitlines() if l.startswith('[decommit-skip]')]
        require(storm.returncode == 0 and len(lines) == 33,
                f'1100 skipped ranges: 33 [decommit-skip] lines (32, then one per 1024; got {len(lines)})')

print('PASS' if not failures else f'FAILED ({failures})')
sys.exit(1 if failures else 0)
