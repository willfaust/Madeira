#!/usr/bin/env python3
"""Swap tier (virtual_ios.c "swap-tier core"): coverage modes, merged free
extents, whole-host-page copy-back and the [swap] census.

1. Compiles the production swap-tier core (between the "swap-tier core"
   markers) against small stubs for Wine's view/protection helpers and runs
   it on real memory with a real sparse backing file:
   - policy parsing: default "classic" (8 MB, guest band), "blocks" (1 MB floor), "wide",
     MADEIRA_SWAP_MIN_KB / MADEIRA_SWAP_RESERVE_MAX_MB and their clamps;
   - classic runs the original predicate (8 MB, guest band) and the original
     unmerged free list;
   - eligibility reasons (prot, view, placeholder, ARM64EC, FEX arena, JIT
     pool, band, small) in blocks and wide;
   - randomized take/give against a model: free ranges never overlap live
     ranges, adjacent free ranges are merged, and after everything is given
     back the file offset space is empty again (bump 0, no free entries);
   - copy-back: an unaligned sub-range moves exactly its host pages to
     anonymous memory with the data intact and every remaining extent
     host-page aligned; a guard request on a PROT_NONE host page is copied
     (not faulted on) and the page is PROT_NONE again afterwards; without a
     copy buffer the range stays file-backed with its data;
   - opt-in reserve-time backing (wide) maps PROT_NONE, a later commit
     (mprotect) is zero-filled, is not backed twice ("present"), and a
     decommit splits it;
   - the census line names every reason and the coverage;
   - ml1291: a given-back range queued to the punch thread is not free before
     its punch, reads as zero in the file afterwards and only then returns
     to the free list (the other cases run with MADEIRA_SWAP_PUNCH_DEFER=0,
     punching synchronously as before);
   - ml1297: a range whose punch failed (synchronous or on the punch thread)
     is never returned to the free list.
2. Source-checks the call sites in allocate_virtual_memory(), that every new
   entry point returns first when the tier is off, that the census neither
   allocates nor uses stdio, that the punch thread punches without
   virtual_mutex and returns the range under it, and (ml1293) that a dead
   range drops its dirty pages (MS_KILLPAGES) before it is punched.
Device runs are still required: this proves the bookkeeping, not iOS paging.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
virt = (root / 'build/ntdll-unix/virtual_ios.c').read_text()

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)


def body_of(src, signature):
    start = src.index(signature)
    brace = src.index('{', start)
    depth = 0
    for i in range(brace, len(src)):
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                return src[brace:i + 1]
    raise AssertionError('unterminated body: ' + signature)


begin = virt.index('/* swap-tier core begin')
end = virt.index('/* swap-tier core end */')
core = virt[begin:end]

prelude = r'''
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <fcntl.h>
#include <assert.h>
#include <sys/mman.h>
#include <pthread.h>
#include <signal.h>
#include <linux/falloc.h>
typedef unsigned long ULONG_PTR;
#define VPROT_READ       0x01
#define VPROT_WRITE      0x02
#define VPROT_EXEC       0x04
#define VPROT_WRITECOPY  0x08
#define VPROT_GUARD      0x10
#define VPROT_COMMITTED  0x20
#define VPROT_WRITEWATCH 0x40
#define VPROT_ARM64EC          0x0100
#define VPROT_SYSTEM           0x0200
#define VPROT_PLACEHOLDER      0x0400
#define VPROT_FREE_PLACEHOLDER 0x0800
#define SEC_FILE    0x00800000
#define SEC_IMAGE   0x01000000
#define SEC_RESERVE 0x04000000
#define SEC_COMMIT  0x08000000
struct file_view { void *base; size_t size; unsigned int protect; };
static inline int is_view_valloc( const struct file_view *view )
{ return !(view->protect & (SEC_FILE | SEC_RESERVE | SEC_COMMIT)); }
static uintptr_t host_page_mask = 0x3fff;
ULONG_PTR ios_fex_arena_base_unix = 0x7c00000000ULL, ios_fex_arena_end_unix = 0x8000000000ULL;
void *ios_jit_rw_base_global = (void *)0x7000000000ULL;   /* numerically inside the band on purpose */
void *ios_jit_rx_base_global = (void *)0x119400000ULL;
size_t ios_jit_pool_size_global = 0x20000000;
/* Wine's rules (unix_private/virtual.c), EXEC mapped to read for the test */
static int get_unix_prot( unsigned char v )
{
    int p = 0;
    if ((v & VPROT_COMMITTED) && !(v & VPROT_GUARD))
    {
        if (v & VPROT_READ) p |= PROT_READ;
        if (v & VPROT_WRITE) p |= PROT_READ | PROT_WRITE;
        if (v & VPROT_EXEC) p |= PROT_READ;
    }
    return p;
}
/* per-page protection bytes: tv_in inside [tv_lo, tv_hi), tv_out elsewhere */
static uintptr_t tv_lo, tv_hi;
static unsigned char tv_in, tv_out = VPROT_READ | VPROT_WRITE | VPROT_COMMITTED;
static unsigned char get_host_page_vprot( const void *addr )
{
    uintptr_t p = (uintptr_t)addr & ~host_page_mask, q;
    unsigned char v = 0;
    for (q = p; q < p + host_page_mask + 1; q += 0x1000) v |= (q >= tv_lo && q < tv_hi) ? tv_in : tv_out;
    return v;
}
static int mprotect_range( void *base, size_t size, unsigned char set, unsigned char clear )
{
    char *a = (char *)((uintptr_t)base & ~host_page_mask);
    char *e = (char *)(((uintptr_t)base + size + host_page_mask) & ~host_page_mask);
    for (; a < e; a += host_page_mask + 1)
        if (mprotect( a, host_page_mask + 1, get_unix_prot( (get_host_page_vprot( a ) & ~clear) | set ) )) return -1;
    return 0;
}
/* the production helper asserts host-page alignment; so does this one */
static void *anon_mmap_fixed( void *a, size_t l, int prot, int flags )
{
    (void)flags;
    assert( !((uintptr_t)a & host_page_mask) );
    assert( !(l & host_page_mask) );
    return mmap( a, l, prot, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0 );
}
static int fail_malloc;
static void *test_malloc( size_t n ) { return fail_malloc ? NULL : malloc( n ); }
#define malloc( n ) test_malloc( n )
struct fpunchhole { unsigned fp_flags; unsigned reserved; off_t fp_offset; off_t fp_length; };
#define F_PUNCHHOLE 99
static int test_fcntl( int fd, int cmd, struct fpunchhole *ph )
{ (void)cmd; return fallocate( fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, ph->fp_offset, ph->fp_length ); }
#define fcntl( fd, cmd, arg ) test_fcntl( fd, cmd, arg )
/* ml1291: the punch thread returns ranges to the free list under Wine's virtual lock */
static pthread_mutex_t virtual_mutex = PTHREAD_MUTEX_INITIALIZER;
#ifdef __linux__
#define pthread_setname_np( name ) pthread_setname_np( pthread_self(), name )   /* glibc names a given thread */
#endif
/* ml1293: Darwin's msync flag (drop the pages without writing them back); a plain msync here */
#ifndef MS_KILLPAGES
#define MS_KILLPAGES 0
#endif
'''

harness = r'''
static unsigned long long ios_swap_footprint_mb( void ) { return 4321; }
/* ml1257: defined after the core in virtual_ios.c (madeira.cfg and fstat); classic cfg, no disk use here */
static void ios_swap_cfg( int *mode, int *min_mb ) { *mode = 1; *min_mb = 0; }
static unsigned long long ios_swap_disk_used( void ) { return 0; }
static int bad;
#define CHECK(c, what) do { if (!(c)) { printf("FAIL: %s (line %d)\n", what, __LINE__); bad++; } } while (0)

static void reset_tier( void )
{
    ios_swap_n = 0; ios_swap_nfree = 0; ios_swap_bump = 0; ios_swap_bytes = 0; ios_swap_peak = 0;
    ios_swap_resv_n = 0; ios_swap_resv_bytes = 0;
    memset( ios_swap_why_bytes, 0, sizeof(ios_swap_why_bytes) );
}
static void env( const char *cov, const char *mn, const char *rmax )
{
    if (cov) setenv( "MADEIRA_SWAP_COVERAGE", cov, 1 ); else unsetenv( "MADEIRA_SWAP_COVERAGE" );
    if (mn) setenv( "MADEIRA_SWAP_MIN_KB", mn, 1 ); else unsetenv( "MADEIRA_SWAP_MIN_KB" );
    if (rmax) setenv( "MADEIRA_SWAP_RESERVE_MAX_MB", rmax, 1 ); else unsetenv( "MADEIRA_SWAP_RESERVE_MAX_MB" );
    ios_swap_config();
}
/* protection of the host page at p from /proc/self/maps: "rw", "r-", "--" */
static const char *prot_of( const void *p )
{
    static char out[3];
    char line[512];
    FILE *f = fopen( "/proc/self/maps", "r" );
    strcpy( out, "??" );
    while (f && fgets( line, sizeof(line), f ))
    {
        unsigned long lo, hi; char perm[5];
        if (sscanf( line, "%lx-%lx %4s", &lo, &hi, perm ) == 3 && (uintptr_t)p >= lo && (uintptr_t)p < hi)
        { out[0] = perm[0]; out[1] = perm[1]; break; }
    }
    if (f) fclose( f );
    return out;
}

static void test_config( void )
{
    env( NULL, NULL, NULL );
    CHECK( !ios_swap_v2 && !ios_swap_wide && ios_swap_min == (8u << 20) && !strcmp( ios_swap_mode, "classic" ), "default = classic, 8 MB" );
    env( "junk", NULL, NULL );
    CHECK( !ios_swap_v2 && !strcmp( ios_swap_mode, "classic" ), "an unknown value means classic" );
    env( "blocks", NULL, NULL );
    CHECK( ios_swap_v2 && !strcmp( ios_swap_mode, "blocks" ) && ios_swap_min == (1u << 20) && !ios_swap_wide, "blocks, 1 MB" );
    env( "Wide", NULL, NULL );
    CHECK( ios_swap_v2 && !strcmp( ios_swap_mode, "wide" ) && ios_swap_wide && ios_swap_min == (1u << 20) && ios_swap_resv_max == (256u << 20), "wide preset" );
    env( "classic", "512", "64" );
    CHECK( !ios_swap_v2 && !ios_swap_wide && ios_swap_min == (8u << 20) && !strcmp( ios_swap_mode, "classic" ), "classic ignores the other knobs" );
    env( "CLASSIC", NULL, NULL );
    CHECK( !ios_swap_v2, "classic is case-insensitive" );
    env( "blocks", "512", NULL );
    CHECK( ios_swap_min == (512u << 10), "MADEIRA_SWAP_MIN_KB" );
    env( "blocks", "1", NULL );
    CHECK( ios_swap_min == (64u << 10), "MIN_KB clamped to 64 KB" );
    env( "blocks", "99999999999999999999", NULL );
    CHECK( ios_swap_min == ((size_t)1 << 32), "MIN_KB clamped to 4 GB without overflow" );
    env( "wide", NULL, "64" );
    CHECK( ios_swap_resv_max == (64u << 20), "MADEIRA_SWAP_RESERVE_MAX_MB" );
}

static void test_why( void )
{
    struct file_view v = { 0, 0, 0 }, ph = { 0, 0, VPROT_PLACEHOLDER }, img = { 0, 0, SEC_IMAGE }, sys = { 0, 0, VPROT_SYSTEM },
                     ec = { 0, 0, VPROT_ARM64EC };
    void *g = (void *)0x7050000000ULL, *low = (void *)0x1000000000ULL, *fex = (void *)0x7c10000000ULL;
    unsigned rw = VPROT_READ | VPROT_WRITE;

    env( "blocks", NULL, NULL );
    CHECK( ios_swap_why( g, 1u << 20, rw, &v ) == IOS_SW_BACKED, "blocks: 1 MB guest RW backed" );
    CHECK( ios_swap_why( g, (1u << 20) - 0x1000, rw, &v ) == IOS_SW_SMALL, "blocks: below 1 MB small" );
    CHECK( ios_swap_why( g, 1u << 20, rw | VPROT_EXEC, &v ) == IOS_SW_PROT, "exec never" );
    CHECK( ios_swap_why( g, 1u << 20, VPROT_READ, &v ) == IOS_SW_PROT, "read-only never" );
    CHECK( ios_swap_why( g, 1u << 20, rw | VPROT_WRITEWATCH, &v ) == IOS_SW_PROT, "write-watch never" );
    CHECK( ios_swap_why( g, 1u << 20, rw | VPROT_GUARD, &v ) == IOS_SW_PROT, "guard never" );
    CHECK( ios_swap_why( g, 1u << 20, rw, &img ) == IOS_SW_VIEW, "image never" );
    CHECK( ios_swap_why( g, 1u << 20, rw, &sys ) == IOS_SW_VIEW, "system view never" );
    CHECK( ios_swap_why( g, 1u << 20, rw, &ph ) == IOS_SW_VIEW, "placeholder never" );
    CHECK( ios_swap_why( g, 1u << 20, rw, &ec ) == IOS_SW_VIEW, "ARM64EC view never" );
    CHECK( ios_swap_why( g, 1u << 20, rw, NULL ) == IOS_SW_VIEW, "no view never" );
    CHECK( ios_swap_why( low, 64u << 20, rw, &v ) == IOS_SW_BAND, "blocks: outside band" );
    CHECK( ios_swap_why( fex, 64u << 20, rw, &v ) == IOS_SW_FEXJIT, "FEX arena labelled" );
    CHECK( ios_swap_why( (void *)0x7000100000ULL, 64u << 20, rw, &v ) == IOS_SW_FEXJIT, "JIT pool RW alias never" );
    CHECK( ios_swap_why( (void *)0x7c00000000ULL - 0x100000, 0x200000, rw, &v ) == IOS_SW_FEXJIT, "straddling the arena never" );

    env( "wide", NULL, NULL );
    CHECK( ios_swap_why( low, 1u << 20, rw, &v ) == IOS_SW_BACKED, "wide: outside band backed" );
    CHECK( ios_swap_why( fex, 64u << 20, rw, &v ) == IOS_SW_FEXJIT, "wide: FEX arena still never" );
    CHECK( ios_swap_why( (void *)0x119500000ULL, 64u << 20, rw, &v ) == IOS_SW_FEXJIT, "wide: JIT pool RX never" );

    env( "classic", NULL, NULL );   /* the original predicate, unchanged */
    CHECK( ios_swap_eligible( g, 8u << 20, rw, &v ), "classic: 8 MB band backed" );
    CHECK( !ios_swap_eligible( g, (8u << 20) - 1, rw, &v ), "classic: under 8 MB refused" );
    CHECK( !ios_swap_eligible( low, 64u << 20, rw, &v ), "classic: band only" );
    CHECK( ios_swap_eligible( (void *)0x7000100000ULL, 64u << 20, rw, &v ), "classic: no FEX/JIT exclusion (as before)" );
}

/* model check of take/give with merging (blocks) */
static void test_freelist( void )
{
    enum { N = 400 };
    uint64_t off[N], len[N];
    int live[N], i, step;
    unsigned seed = 2013;
    env( "blocks", NULL, NULL );
    reset_tier();
    memset( live, 0, sizeof(live) );
    for (step = 0; step < 20000; step++)
    {
        seed = seed * 1103515245u + 12345u;
        i = (seed >> 8) % N;
        if (!live[i])
        {
            len[i] = (uint64_t)(1 + ((seed >> 20) % 64)) << 14;
            off[i] = ios_swap_take( len[i] );
            if (off[i] == (uint64_t)-1) continue;
            live[i] = 1;
        }
        else { ios_swap_give( off[i], len[i] ); live[i] = 0; }
    }
    for (i = 0; i < N; i++) if (live[i])
    {
        unsigned f; int j;
        CHECK( off[i] + len[i] <= ios_swap_bump, "live range below bump" );
        for (f = 0; f < ios_swap_nfree; f++)
            if (off[i] < ios_swap_free[f].off + ios_swap_free[f].len && ios_swap_free[f].off < off[i] + len[i]) { CHECK( 0, "free overlaps live" ); break; }
        for (j = i + 1; j < N; j++) if (live[j] && off[i] < off[j] + len[j] && off[j] < off[i] + len[i]) { CHECK( 0, "live ranges overlap" ); break; }
    }
    {
        unsigned f, g;
        for (f = 0; f < ios_swap_nfree; f++)
            for (g = f + 1; g < ios_swap_nfree; g++)
                if (ios_swap_free[f].off + ios_swap_free[f].len == ios_swap_free[g].off ||
                    ios_swap_free[g].off + ios_swap_free[g].len == ios_swap_free[f].off) { CHECK( 0, "adjacent free ranges left unmerged" ); f = g = ios_swap_nfree; }
    }
    for (i = 0; i < N; i++) if (live[i]) { ios_swap_give( off[i], len[i] ); live[i] = 0; }
    CHECK( ios_swap_bump == 0 && ios_swap_nfree == 0, "all offsets returned: bump 0, free list empty" );
    printf( "freelist: merges=%llu bump-backs=%llu drops=%llu\n", ios_swap_merges, ios_swap_bump_back, ios_swap_free_drop );

    /* classic: the original plain free list, no merging, bump never lowered */
    env( "classic", NULL, NULL );
    reset_tier();
    {
        uint64_t a = ios_swap_take( 0x4000 ), b = ios_swap_take( 0x4000 );
        ios_swap_give( a, 0x4000 ); ios_swap_give( b, 0x4000 );
        CHECK( ios_swap_nfree == 2 && ios_swap_bump == 0x8000, "classic keeps the original free list" );
    }
    reset_tier();
}

static char *region( uintptr_t at, size_t len )
{
    void *p = mmap( (void *)at, len, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0 );
    if (p == MAP_FAILED || p != (void *)at) { printf( "FAIL: cannot map test region at %p (errno %d)\n", (void *)at, errno ); exit( 2 ); }
    return p;
}

static void test_commit_copyback( void )
{
    struct file_view v = { 0, 0, 0 };
    unsigned rw = VPROT_READ | VPROT_WRITE;
    char *r = region( 0x7050000000ULL, 4u << 20 );
    size_t i;
    unsigned k;
    env( "blocks", NULL, NULL );
    reset_tier();
    v.base = r; v.size = 4u << 20;
    /* MEM_RESERVE|MEM_COMMIT of 0x110000 (a 1 MB heap block + header) */
    anon_mmap_fixed( r, 0x110000, PROT_READ | PROT_WRITE, 0 );
    ios_swap_commit( r, 0x110000, rw, &v );
    CHECK( ios_swap_n == 1 && ios_swap_bytes == 0x110000, "1 MB heap block backed whole" );
    CHECK( ios_swap_why_bytes[IOS_SW_BACKED] == 0x110000, "census counts it as backed" );
    for (i = 0; i < 0x110000; i++) r[i] = (char)(i * 7 + 3);

    /* EXEC on an unaligned 8 KB piece: whole host page, data kept */
    tv_lo = (uintptr_t)r + 0x5000; tv_hi = tv_lo + 0x2000; tv_in = VPROT_READ | VPROT_EXEC | VPROT_COMMITTED;
    ios_swap_release_range( r + 0x5000, 0x2000, 1 );
    for (k = 0; k < ios_swap_n; k++)
        CHECK( !((uintptr_t)ios_swap_ext[k].va & 0x3fff) && !(ios_swap_ext[k].len & 0x3fff), "extents stay host-page aligned" );
    CHECK( ios_swap_n == 2 && ios_swap_bytes == 0x110000 - 0x4000, "exactly the one host page left the tier" );
    CHECK( !ios_swap_overlaps( r + 0x4000, 0x4000 ) && ios_swap_overlaps( r, 0x4000 ) && ios_swap_overlaps( r + 0x8000, 0x4000 ), "neighbours still backed" );
    CHECK( !strcmp( prot_of( r + 0x4000 ), "rw" ), "host page protection re-applied (union of its guest pages)" );
    for (i = 0; i < 0x110000; i++) if (r[i] != (char)(i * 7 + 3)) { CHECK( 0, "data preserved through copy-back" ); break; }

    /* GUARD on an aligned host page: the caller already made it PROT_NONE */
    tv_lo = (uintptr_t)r + 0x10000; tv_hi = tv_lo + 0x4000; tv_in = VPROT_READ | VPROT_WRITE | VPROT_GUARD | VPROT_COMMITTED;
    mprotect_range( r + 0x10000, 0x4000, 0, 0 );
    CHECK( !strcmp( prot_of( r + 0x10000 ), "--" ), "guard page is PROT_NONE before the copy-back" );
    ios_swap_release_range( r + 0x10000, 0x4000, 1 );
    CHECK( !ios_swap_overlaps( r + 0x10000, 0x4000 ), "guard page left the tier" );
    CHECK( !strcmp( prot_of( r + 0x10000 ), "--" ), "guard page is PROT_NONE again after the copy-back" );
    mprotect( r + 0x10000, 0x4000, PROT_READ | PROT_WRITE );
    for (i = 0x10000; i < 0x14000; i++) if (r[i] != (char)(i * 7 + 3)) { CHECK( 0, "guard page data preserved" ); break; }
    tv_lo = tv_hi = 0;

    /* no copy buffer: the range stays file-backed with its data */
    {
        unsigned long long before = ios_swap_bytes;
        unsigned n_before = ios_swap_n;
        fail_malloc = 1;
        ios_swap_release_range( r + 0x20000, 0x4000, 1 );
        fail_malloc = 0;
        CHECK( ios_swap_bytes == before && ios_swap_n == n_before && ios_swap_overlaps( r + 0x20000, 0x4000 ), "no buffer: range stays file-backed" );
        for (i = 0x20000; i < 0x24000; i++) if (r[i] != (char)(i * 7 + 3)) { CHECK( 0, "no buffer: data intact" ); break; }
    }

    /* the file punched only the copied pages: remaining backed data intact after a sync */
    msync( r, 0x110000, MS_SYNC );
    for (i = 0x14000; i < 0x110000; i++) if (r[i] != (char)(i * 7 + 3)) { CHECK( 0, "file-backed neighbours intact" ); break; }
    /* a fresh small commit is refused as small and counted */
    ios_swap_commit( r + 0x200000, 0x60000, rw, &v );
    CHECK( ios_swap_why_bytes[IOS_SW_SMALL] == 0x60000, "small commit counted" );
    ios_swap_release_range( r, v.size, 0 );   /* MEM_RELEASE */
    CHECK( ios_swap_n == 0 && ios_swap_bytes == 0 && ios_swap_bump == 0 && ios_swap_nfree == 0, "release returns all file space" );
    munmap( r, 4u << 20 );
}

static void test_classic_commit( void )
{
    struct file_view v = { 0, 0, 0 };
    unsigned rw = VPROT_READ | VPROT_WRITE;
    char *r = region( 0x7058000000ULL, 16u << 20 );
    env( "classic", NULL, NULL );
    reset_tier();
    v.base = r; v.size = 16u << 20;
    anon_mmap_fixed( r, 16u << 20, PROT_READ | PROT_WRITE, 0 );
    ios_swap_commit( r, 4u << 20, rw, &v );
    CHECK( ios_swap_n == 0, "classic: a 4 MB commit stays anonymous" );
    ios_swap_commit( r + (4u << 20), 8u << 20, rw, &v );
    CHECK( ios_swap_n == 1 && ios_swap_bytes == (8u << 20), "classic: an 8 MB commit is backed" );
    CHECK( ios_swap_why_bytes[IOS_SW_BACKED] == 0 && ios_swap_why_bytes[IOS_SW_SMALL] == 0, "classic: no census bookkeeping" );
    ios_swap_reserve( r, 1u << 20, rw, &v );
    CHECK( ios_swap_resv_n == 0 && ios_swap_n == 1, "classic: never backs a reservation" );
    ios_swap_release_range( r, 16u << 20, 0 );
    CHECK( ios_swap_n == 0 && ios_swap_bytes == 0, "classic: release drops the extent" );
    munmap( r, 16u << 20 );
    reset_tier();
}

static void test_reserve( void )
{
    struct file_view v = { 0, 0, 0 };
    unsigned rw = VPROT_READ | VPROT_WRITE;
    char *r = region( 0x7060000000ULL, 16u << 20 );
    size_t i;
    env( "wide", NULL, NULL );
    reset_tier();
    v.base = r; v.size = 0xfd0000;
    ios_swap_reserve( r, 0xfd0000, rw, &v );   /* a Wine subheap: MEM_RESERVE PAGE_READWRITE */
    CHECK( ios_swap_n == 1 && ios_swap_resv_n == 1, "writable reservation backed at reserve time" );
    CHECK( !strcmp( prot_of( r ), "--" ), "reservation mapped PROT_NONE" );
    CHECK( mprotect( r, 0x10000, PROT_READ | PROT_WRITE ) == 0, "commit = mprotect of file pages" );
    for (i = 0; i < 0x10000; i++) if (r[i]) { CHECK( 0, "fresh commit reads zero" ); break; }
    memset( r, 0x5a, 0x10000 );
    ios_swap_commit( r, 0x10000, rw, &v );
    CHECK( ios_swap_n == 1 && ios_swap_why_bytes[IOS_SW_PRESENT] == 0x10000, "commit inside a backed reservation is not backed twice" );
    ios_swap_release_range( r + 0x400000, 0x100000, 0 );   /* decommit the middle */
    anon_mmap_fixed( r + 0x400000, 0x100000, PROT_READ | PROT_WRITE, 0 );
    CHECK( ios_swap_n == 2, "decommit splits the reserve extent" );
    for (i = 0; i < 0x10000; i++) if (r[i] != 0x5a) { CHECK( 0, "data before the hole intact" ); break; }
    ios_swap_reserve( r, 0x100000, rw | VPROT_COMMITTED, &v );
    ios_swap_reserve( r, 0x20000000, rw, &v );
    ios_swap_reserve( r, 0x100000, VPROT_READ, &v );
    CHECK( ios_swap_resv_n == 1, "reserve-time backing refused where it must be" );
    env( "blocks", NULL, NULL );   /* blocks: reserve-time off */
    ios_swap_reserve( r + 0xfd0000, 0x20000, rw, &v );
    CHECK( ios_swap_resv_n == 1, "blocks never backs a reservation" );
    ios_swap_release_range( r, 16u << 20, 0 );
    CHECK( ios_swap_n == 0 && ios_swap_bump == 0 && ios_swap_nfree == 0, "reservation release returns all file space" );
    munmap( r, 16u << 20 );
}

/* ml1291: a give queued to the punch thread */
static void test_deferred_punch( void )
{
    char buf[0x4000];
    unsigned long long done0;
    uint64_t a, b;
    int i, waited;
    env( "blocks", NULL, NULL );
    reset_tier();
    unsetenv( "MADEIRA_SWAP_PUNCH_DEFER" );
    ios_swap_pq_state = 0;   /* the next give starts the thread */
    a = ios_swap_take( 0x8000 );
    b = ios_swap_take( 0x4000 );
    memset( buf, 0x6b, sizeof(buf) );
    CHECK( pwrite( ios_swap_fd, buf, sizeof(buf), (off_t)a ) == (ssize_t)sizeof(buf), "deferred: data written to the file" );
    done0 = ios_swap_pq_done;
    pthread_mutex_lock( &virtual_mutex );   /* every caller holds it in Wine */
    ios_swap_give( a, 0x8000 );
    CHECK( ios_swap_pq_state == 1, "deferred: the punch thread started" );
    CHECK( ios_swap_nfree == 0, "deferred: a queued range is not free before its punch" );
    pthread_mutex_unlock( &virtual_mutex );
    for (waited = 0; ios_swap_pq_done == done0 && waited < 5000; waited++) usleep( 1000 );
    pthread_mutex_lock( &virtual_mutex );
    CHECK( ios_swap_pq_done == done0 + 1, "deferred: the punch thread finished the give" );
    CHECK( ios_swap_nfree == 1 && ios_swap_free[0].off == a && ios_swap_free[0].len == 0x8000, "deferred: the range is free after its punch" );
    pthread_mutex_unlock( &virtual_mutex );
    memset( buf, 0x6b, sizeof(buf) );
    CHECK( pread( ios_swap_fd, buf, sizeof(buf), (off_t)a ) == (ssize_t)sizeof(buf), "deferred: file read back" );
    for (i = 0; i < (int)sizeof(buf); i++) if (buf[i]) { CHECK( 0, "deferred: the punched range reads zero" ); break; }
    pthread_mutex_lock( &virtual_mutex );
    ios_swap_give( b, 0x4000 );
    pthread_mutex_unlock( &virtual_mutex );
    for (waited = 0; ios_swap_pq_done == done0 + 1 && waited < 5000; waited++) usleep( 1000 );
    pthread_mutex_lock( &virtual_mutex );
    CHECK( ios_swap_pq_done == done0 + 2 && ios_swap_bump == 0 && ios_swap_nfree == 0, "deferred: all offsets returned" );
    pthread_mutex_unlock( &virtual_mutex );
    reset_tier();
}

/* ml1297: a range whose punch failed is never reused */
static void test_punch_failure( void )
{
    int fd = ios_swap_fd, nullfd = open( "/dev/null", O_RDONLY ), waited;
    unsigned long long leaks0 = ios_swap_punch_leaks, done0;
    uint64_t a;
    env( "blocks", NULL, NULL );
    reset_tier();
    a = ios_swap_take( 0x8000 );
    ios_swap_take( 0x4000 );   /* keeps a below the bump */
    ios_swap_pq_state = -1;   /* synchronous */
    ios_swap_fd = nullfd;
    ios_swap_give( a, 0x8000 );
    ios_swap_fd = fd;
    CHECK( ios_swap_punch_leaks == leaks0 + 1 && ios_swap_nfree == 0, "punch failure (synchronous): range not reused" );
    reset_tier();
    a = ios_swap_take( 0x8000 );
    ios_swap_take( 0x4000 );
    ios_swap_pq_state = 1;    /* the punch thread started in test_deferred_punch */
    done0 = ios_swap_pq_done;
    ios_swap_fd = nullfd;
    pthread_mutex_lock( &virtual_mutex );
    ios_swap_give( a, 0x8000 );
    pthread_mutex_unlock( &virtual_mutex );
    for (waited = 0; ios_swap_pq_done == done0 && waited < 5000; waited++) usleep( 1000 );
    ios_swap_fd = fd;
    pthread_mutex_lock( &virtual_mutex );
    CHECK( ios_swap_pq_done == done0 + 1 && ios_swap_punch_leaks == leaks0 + 2 && ios_swap_nfree == 0, "punch failure (punch thread): range not reused" );
    pthread_mutex_unlock( &virtual_mutex );
    close( nullfd );
    reset_tier();
}

static void test_off( void )
{
    struct file_view v = { 0, 0, 0 };
    int fd = ios_swap_fd;
    ios_swap_fd = -1;   /* the tier as shipped: swap-mb unset */
    env( "blocks", NULL, NULL );
    reset_tier();
    ios_swap_commit( (void *)0x7050000000ULL, 64u << 20, VPROT_READ | VPROT_WRITE, &v );
    ios_swap_reserve( (void *)0x7050000000ULL, 64u << 20, VPROT_READ | VPROT_WRITE, &v );
    ios_swap_note( IOS_SW_RECOMMIT, 1u << 20 );
    ios_swap_release_range( (void *)0x7050000000ULL, 64u << 20, 1 );
    CHECK( ios_swap_n == 0 && ios_swap_bump == 0 && ios_swap_why_bytes[IOS_SW_RECOMMIT] == 0, "tier off: every entry point is a no-op" );
    ios_swap_fd = fd;
}

int main( int argc, char **argv )
{
    char path[] = "/tmp/madeira-swap-XXXXXX";
    int fd = mkstemp( path );
    if (fd < 0) return 2;
    close( fd );
    setenv( "MADEIRA_SWAP_FILE", path, 1 );
    setenv( "MADEIRA_SWAP_MB", "256", 1 );
    setenv( "MADEIRA_SWAP_PUNCH_DEFER", "0", 1 );   /* ml1291: synchronous punches up to test_deferred_punch */
    unsetenv( "MADEIRA_SWAP_COVERAGE" );
    ios_swap_init();
    unlink( path );
    if (ios_swap_fd < 0) { printf( "FAIL: tier did not start\n" ); return 1; }
    test_off();
    test_config();
    test_why();
    test_freelist();
    test_commit_copyback();
    test_classic_commit();
    test_reserve();
    test_deferred_punch();
    test_punch_failure();
    env( "blocks", NULL, NULL );
    ios_swap_tick( 1 );
    printf( "%d failures\n", bad );
    return bad != 0;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp) / 'swap.c'
    exe = Path(tmp) / 'swap'
    c.write_text(prelude + core + harness)
    subprocess.run(['cc', '-O1', '-Wall', '-Wno-unused-function', '-Werror', '-pthread', '-o', str(exe), str(c)], check=True)
    r = subprocess.run([str(exe)], capture_output=True, text=True, env=dict(os.environ))
    print(r.stdout.strip())
    check(r.returncode == 0, 'swap-tier core run failed:\n' + r.stdout + r.stderr)
    err = r.stderr
    check('[swap] coverage=classic: 8 MB commits in the guest band, no census' in err, 'coverage line printed at tier start (classic is the default since 046af3e)')
    census = [l for l in err.splitlines() if l.startswith('[swap] census file-backed now=')]
    check(len(census) >= 1, 'census line printed')
    if census:
        for name in ('backed=', 'small=', 'band=', 'fex/jit=', 'prot=', 'view=', 'recommit=', 'present=', 'refused=', 'mapfail='):
            check(name in census[-1], 'census names ' + name)
        check('footprint=4321MB coverage=blocks min=1024KB' in census[-1], 'census carries footprint and coverage')
        check(re.search(r'file=\d+/256MB', census[-1]) is not None, 'census carries file use and cap')
    check('[swap] ml1291 deferred F_PUNCHHOLE off (MADEIRA_SWAP_PUNCH_DEFER=0)' in err, 'MADEIRA_SWAP_PUNCH_DEFER=0 keeps the punches synchronous')
    check('[swap] ml1291 deferred F_PUNCHHOLE on' in err, 'the punch thread starts by default')
    check('range not reused, ml1297' in err, 'ml1297: a failed synchronous punch is logged')

# ------------------------------------------------------------ source checks
avm = body_of(virt, 'static NTSTATUS allocate_virtual_memory(')
check('if (type & MEM_COMMIT) ios_swap_commit( base, size, vprot, view );' in avm, 'reserve path: commit-time backing through ios_swap_commit')
check('else if (!(attributes & MEM_EXTENDED_PARAMETER_EC_CODE)) ios_swap_reserve( base, size, vprot, view );' in avm,
      'reserve-only path: reserve-time backing (wide), never for EC code')
check('if (any_committed) ios_swap_note( IOS_SW_RECOMMIT, size );' in avm, 'commit path: already-committed counted, never backed')
check('else if (!get_vprot_flags( protect, &sv, 0 )) ios_swap_commit( base, size, sv, view );' in avm, 'commit path: fresh commit through ios_swap_commit')
check('ios_swap_eligible(' not in avm and 'ios_swap_back(' not in avm, 'no direct calls of the classic helpers left in allocate_virtual_memory')

# with the tier off (the default) every new entry point returns first
for sig, first in [
    ('static void ios_swap_commit( void *base, size_t size, unsigned int vprot, struct file_view *view )\n{', 'if (ios_swap_fd < 0) return;'),
    ('static void ios_swap_reserve( void *base, size_t size, unsigned int vprot, struct file_view *view )\n{', 'if (ios_swap_fd < 0 || !ios_swap_wide) return;'),
    ('static void ios_swap_note( int why, size_t size )\n{', 'if (ios_swap_fd < 0 || !ios_swap_v2) return;'),
    ('static void ios_swap_release_range( void *base, size_t size, int copy_back )\n{', 'if (ios_swap_fd < 0 || !ios_swap_n) return;'),
]:
    b = body_of(virt, sig)
    stmts = [l.strip() for l in b.splitlines()[1:] if l.strip() and not re.match(r'^(char|unsigned|int|static|struct|uint64_t|size_t|void)\b', l.strip())]
    check(stmts and stmts[0] == first, sig.split('(')[0] + ': first statement is the tier-off return')
commit = body_of(virt, 'static void ios_swap_commit( void *base, size_t size, unsigned int vprot, struct file_view *view )\n{')
check('if (!ios_swap_v2) { if (ios_swap_eligible( base, size, vprot, view )) ios_swap_back( base, size, vprot ); return; }' in commit,
      'classic runs the original commit rule')
tick = body_of(virt, 'static void ios_swap_tick( int force )\n{')
for bad in ('printf', 'malloc', 'calloc', 'strdup', 'asprintf', 'ERR(', 'TRACE('):
    check(bad not in tick, 'census: no ' + bad)
check('write( 2, line, p - line )' in tick, 'census written with one write(2)')
check('return ios_swap_map( base, size, get_unix_prot( vprot | VPROT_COMMITTED ) );' in virt or
      'ios_swap_map( base, size, get_unix_prot( vprot | VPROT_COMMITTED ) );' in virt, 'ml1082: commit-time extents mapped committed')
check('ios_swap_map( base, size, get_unix_prot( vprot ) )' in body_of(virt, 'static void ios_swap_reserve( void *base, size_t size, unsigned int vprot, struct file_view *view )\n{'),
      'reserve-time extents keep the reservation protection (PROT_NONE)')
give = body_of(virt, 'static void ios_swap_give( uint64_t off, size_t len )\n{')
check(give.index('if (ios_swap_punch_defer( off, len )) return;') < give.index('F_PUNCHHOLE'), 'ml1291: a give is queued before the synchronous punch')
punch = body_of(virt, 'static void *ios_swap_punch_thread( void *arg )\n{')
check(punch.index('ios_swap_punch_timed(') < punch.index('pthread_mutex_lock( &virtual_mutex );') < punch.index('ios_swap_free_add('),
      'ml1291: the punch runs without virtual_mutex, the free list is updated under it')
rel = body_of(virt, 'static void ios_swap_release_range( void *base, size_t size, int copy_back )\n{')
check('if (!copy_back) msync( oa, olen, MS_KILLPAGES );\n            ios_swap_give( ooff, olen );' in rel,
      'ml1293: a released range drops its dirty pages before it is given back')
resv = body_of(virt, 'static int ios_swap_punch_resv( char *lo, size_t len )\n{')
check('msync( lo, len, MS_KILLPAGES );' in resv and resv.index('msync( lo, len, MS_KILLPAGES );') < resv.index('ios_swap_punch_timed('),
      'ml1293: a decommit drops its dirty pages before the punch')
setprot = body_of(virt, 'static NTSTATUS set_protection( struct file_view *view, void *base, SIZE_T size, ULONG protect )')
check('ios_swap_release_range( base, size, 1 )' in setprot, 'set_protection still leaves the tier for EXEC/WRITECOPY/GUARD')

if failures:
    print('FAIL:')
    for f in failures:
        print('  - ' + f)
    raise SystemExit(1)
print('PASS: swap-tier coverage, merged free extents, copy-back and census')
