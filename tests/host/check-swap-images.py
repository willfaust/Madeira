#!/usr/bin/env python3
"""madeira-bcd swap-images (virtual_ios.c): pure-x64 images' sections move to the
swap tier's file after they are read, so phys_footprint stops charging them.

The 467 run (2026-10-09 13:09, Red Dead Redemption 2 through Madeira Dock) had
libcef.dll's image 228 MB dirty and each steamclient64.dll copy 22 MB: every x64
PE section is read() into anonymous memory, because its 4 KB-aligned address and
512-byte file offset can never be mmapped on 16 KB pages.

1. Compiles the production swap-tier core (between the "swap-tier core" markers,
   which now holds ios_swap_image_take / ios_swap_image_map) together with the
   glue cut out of virtual_ios.c (ios_swap_image_note, ios_swap_images_enabled,
   ios_swap_image_flush) against small stubs for Wine's view table, its lock and
   its protection helpers, and runs it on real memory with a real sparse file:
   - a note is taken only while map_image_into_view's loop is armed, as the
     host-page interior of the section (edges shared with neighbours stay out),
     at most 32 per image;
   - the flush moves each noted interior into the file with the data intact, as
     a MAP_SHARED mapping of the swap file (/proc/self/maps), so a later store
     reaches the file; the pages' protections are re-applied;
   - the pwrite runs with the lock RELEASED, the take and the map with it HELD
     (ml1081: no file-page touches under virtual_mutex);
   - nothing moves for a view without VPROT_X64DATA, a view that went away, an
     image that failed to map (ok = 0), a range already backed, or when pwrite
     fails (the offset goes back, the range keeps its anonymous data);
   - release (delete_view) returns the file space and the image byte count;
     a GUARD copy-back of an image extent keeps the count right; image extents
     never reach the churn filter in broad mode; the census and the stats line
     carry the image figures only once an image moved;
   - the switch is read once with madeira_cfg_bool("swap-images", 0) and is off
     while the tier is off.
2. Source-checks the call sites: the note right after map_file_into_view_ex's
   read() fallback, for images only; arming before map_image_into_view's
   sections loop with the [x64-image] test and disarming after it and at done:;
   the flush right after virtual_map_image leaves virtual_mutex; set_protection
   keeps an X64DATA view's file pages for EXEC/WRITECOPY but not for GUARD.
Device runs are still required: this proves the bookkeeping and the locking
order, not iOS paging.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
virt = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
failures = []


def check(cond, what):
    print(('ok   ' if cond else 'FAIL ') + what)
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
                return src[start:i + 1] + '\n'
    raise AssertionError('unterminated body: ' + signature)


core = virt[virt.index('/* swap-tier core begin'):virt.index('/* swap-tier core end */')]
pend_decl = virt[virt.index('#define IOS_SWAP_IMAGE_PENDING'):virt.index('/* Remember the host-page interior')]
note_fn = body_of(virt, 'static void ios_swap_image_note( const struct file_view *view, char *addr, size_t size )')
enabled_fn = body_of(virt, 'static int ios_swap_images_enabled( void )')
flush_fn = body_of(virt, 'static void ios_swap_image_flush( int ok )')

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
#include <signal.h>
#include <sys/mman.h>
#include <linux/falloc.h>
#include <pthread.h>
/* ml1291's deferred punches: a worker thread, the free list under virtual_mutex, and
 * ml1293's MS_KILLPAGES (Darwin: drop dirty pages before the punch; a plain msync here). */
#define pthread_setname_np(name) ((void)(name))   /* Darwin's one-argument form */
#ifndef MS_KILLPAGES
#define MS_KILLPAGES MS_ASYNC
#endif
static pthread_mutex_t virtual_mutex = PTHREAD_MUTEX_INITIALIZER;
typedef unsigned long ULONG_PTR;
typedef long NTSTATUS;
#define NT_SUCCESS(s) ((s) >= 0)
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
#define VPROT_X64DATA          0x1000
#define SEC_FILE    0x00800000
#define SEC_IMAGE   0x01000000
#define SEC_RESERVE 0x04000000
#define SEC_COMMIT  0x08000000
struct file_view { void *base; size_t size; unsigned int protect; };
static inline int is_view_valloc( const struct file_view *view )
{ return !(view->protect & (SEC_FILE | SEC_RESERVE | SEC_COMMIT)); }
static uintptr_t host_page_mask = 0x3fff;
ULONG_PTR ios_fex_arena_base_unix = 0x7c00000000ULL, ios_fex_arena_end_unix = 0x8000000000ULL;
void *ios_jit_rw_base_global = (void *)0x7000000000ULL;
void *ios_jit_rx_base_global = (void *)0x119400000ULL;
size_t ios_jit_pool_size_global = 0x20000000;
static int ios_jit_low_overlaps( uintptr_t a, size_t size ) { (void)a; (void)size; return 0; }
/* Wine's rules: WRITE and WRITECOPY are host-writable, EXEC maps to read here */
static int get_unix_prot( unsigned char v )
{
    int p = 0;
    if ((v & VPROT_COMMITTED) && !(v & VPROT_GUARD))
    {
        if (v & VPROT_READ) p |= PROT_READ;
        if (v & (VPROT_WRITE | VPROT_WRITECOPY)) p |= PROT_READ | PROT_WRITE;
        if (v & VPROT_EXEC) p |= PROT_READ;
    }
    return p;
}
static unsigned char page_vprot = VPROT_READ | VPROT_COMMITTED;   /* what the image's pages carry */
static unsigned char get_host_page_vprot( const void *addr ) { (void)addr; return page_vprot; }
static int locked;   /* virtual_mutex depth (the stubs below) */
static int mprotect_range( void *base, size_t size, unsigned char set, unsigned char clear )
{
    char *a = (char *)((uintptr_t)base & ~host_page_mask);
    char *e = (char *)(((uintptr_t)base + size + host_page_mask) & ~host_page_mask);
    for (; a < e; a += host_page_mask + 1)
        if (mprotect( a, host_page_mask + 1, get_unix_prot( (get_host_page_vprot( a ) & ~clear) | set ) )) return -1;
    return 0;
}
static void *anon_mmap_fixed( void *a, size_t l, int prot, int flags )
{
    (void)flags;
    assert( !((uintptr_t)a & host_page_mask) );
    assert( !(l & host_page_mask) );
    return mmap( a, l, prot, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0 );
}
struct fpunchhole { unsigned fp_flags; unsigned reserved; off_t fp_offset; off_t fp_length; };
#define F_PUNCHHOLE 99
static int test_fcntl( int fd, int cmd, struct fpunchhole *ph )
{ (void)cmd; return fallocate( fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, ph->fp_offset, ph->fp_length ); }
#define fcntl( fd, cmd, arg ) test_fcntl( fd, cmd, arg )
static unsigned long long ios_swap_footprint_mb( void ) { return 1234; }
static int cfg_mode = 1;
static void ios_swap_cfg( int *mode, int *min_mb ) { *mode = cfg_mode; *min_mb = 0; }
static unsigned long long ios_swap_disk_used( void ) { return 0; }
/* ml2021: madeira.cfg swap-wow64 (default), no WoW64 guest window, and the donor guard's host free RAM */
static long madeira_cfg_int( const char *key, long def ) { (void)key; return def; }
static unsigned long ios_wow_window_covering( const void *s, const void *e ) { (void)s; (void)e; return 0; }
static uint64_t ios_donor_system_free( void ) { return 0; }
/* the calling program is not a Chromium browser (ios_swap_browser) */
static int ios_avail_phys_chromium( void ) { return 0; }
/* ml2021: the swap core asks whether a 32-bit program is in the session (none here) */
static unsigned ios_wow_window_count, ios_wow_placeholder_count;
static struct { unsigned long base; } ios_wow_windows[1], ios_wow_placeholders[1];
/* the take and the map must run with the lock held: wrap the core's versions */
#define ios_swap_image_take real_ios_swap_image_take
#define ios_swap_image_map real_ios_swap_image_map
'''

glue_stubs = r'''
#undef ios_swap_image_take
#undef ios_swap_image_map
static int take_unlocked, map_unlocked, pwrite_locked, pwrite_fail;
static uint64_t ios_swap_image_take( size_t len ) { if (locked != 1) take_unlocked++; return real_ios_swap_image_take( len ); }
static int ios_swap_image_map( char *va, size_t len, uint64_t off ) { if (locked != 1) map_unlocked++; return real_ios_swap_image_map( va, len, off ); }
static ssize_t test_pwrite( int fd, const void *buf, size_t len, off_t off )
{
    if (locked) pwrite_locked++;
    if (pwrite_fail) { pwrite_fail--; errno = EIO; return -1; }
    return pwrite( fd, buf, len, off );
}
#define pwrite( fd, buf, len, off ) test_pwrite( fd, buf, len, off )
/* virtual_mutex is the prelude's (ml1291's punch worker locks it); the section only counts depth */
static void server_enter_uninterrupted_section( pthread_mutex_t *m, sigset_t *s ) { (void)m; (void)s; locked++; }
static void server_leave_uninterrupted_section( pthread_mutex_t *m, sigset_t *s ) { (void)m; (void)s; locked--; }
/* the view table: one image view at most */
static struct file_view the_view;
static int have_view;
static struct file_view *find_view( const void *addr, size_t size )
{
    const char *a = addr;
    if (!have_view || a < (char *)the_view.base || a + size > (char *)the_view.base + the_view.size) return NULL;
    return &the_view;
}
static int cfg_reads, cfg_images;
static int madeira_cfg_bool( const char *key, int dflt ) { cfg_reads++; return strcmp( key, "swap-images" ) ? dflt : cfg_images; }
'''

harness = r'''
static int bad;
#define CHECK(c, what) do { if (!(c)) { printf("FAIL: %s (line %d)\n", what, __LINE__); bad++; } } while (0)

static char *region( uintptr_t at, size_t len )
{
    void *p = mmap( (void *)at, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0 );
    if (p == MAP_FAILED || p != (void *)at) { printf( "FAIL: cannot map test region at %p (errno %d)\n", (void *)at, errno ); exit( 2 ); }
    return p;
}
/* "rw-s" etc. and whether the mapping at p is the swap file (inode) */
static int map_info( const void *p, char perm[5], unsigned long *inode )
{
    char line[512];
    FILE *f = fopen( "/proc/self/maps", "r" );
    int found = 0;
    while (f && fgets( line, sizeof(line), f ))
    {
        unsigned long lo, hi, off, ino; char pm[5], dev[16];
        if (sscanf( line, "%lx-%lx %4s %lx %15s %lu", &lo, &hi, pm, &off, dev, &ino ) == 6 && (uintptr_t)p >= lo && (uintptr_t)p < hi)
        { memcpy( perm, pm, 5 ); *inode = ino; found = 1; break; }
    }
    if (f) fclose( f );
    return found;
}
static unsigned long swap_ino;
static int is_file_backed( const void *p ) { char pm[5]; unsigned long ino = 0; return map_info( p, pm, &ino ) && pm[3] == 's' && ino == swap_ino; }
static int is_anon( const void *p ) { char pm[5]; unsigned long ino = 1; return map_info( p, pm, &ino ) && ino == 0; }
static void fill( char *p, size_t n, int seed ) { size_t i; for (i = 0; i < n; i++) p[i] = (char)(i * 31 + seed); }
static int same( const char *p, size_t n, int seed ) { size_t i; for (i = 0; i < n; i++) if (p[i] != (char)(i * 31 + seed)) return 0; return 1; }
static void reset_tier( void )
{
    ios_swap_n = 0; ios_swap_nfree = 0; ios_swap_bump = 0; ios_swap_bytes = 0; ios_swap_peak = 0;
    ios_swap_img_bytes = ios_swap_img_peak = ios_swap_img_backs = ios_swap_img_refused = 0;
}

static void test_switch( void )
{
    int fd = ios_swap_fd;
    cfg_images = 1;
    CHECK( ios_swap_images_enabled() == 1 && cfg_reads == 1, "on with the tier on, read once" );
    CHECK( ios_swap_images_enabled() == 1 && cfg_reads == 1, "cached" );
    (void)fd;
}

static void test_note( void )
{
    struct file_view v = { (void *)0x7060000000ULL, 0x400000, SEC_IMAGE };
    ios_swap_image_npend = 0;
    ios_swap_image_armed = 0;
    ios_swap_image_note( &v, (char *)0x7060001000ULL, 0x40000 );
    CHECK( ios_swap_image_npend == 0, "not armed: nothing noted" );
    ios_swap_image_armed = 1;
    ios_swap_image_note( &v, (char *)0x7060001000ULL, 0x40000 );   /* .text at rva 0x1000 */
    CHECK( ios_swap_image_npend == 1 && ios_swap_image_pend[0].va == (char *)0x7060004000ULL &&
           ios_swap_image_pend[0].len == 0x3c000, "interior: header page and the tail page stay out" );
    ios_swap_image_note( &v, (char *)0x7060042000ULL, 0x3000 );     /* no whole host page inside */
    CHECK( ios_swap_image_npend == 1, "a section without a whole host page is not noted" );
    for (int i = 0; i < 40; i++) ios_swap_image_note( &v, (char *)0x7060100000ULL + i * 0x8000, 0x8000 );
    CHECK( ios_swap_image_npend == IOS_SWAP_IMAGE_PENDING, "at most 32 notes per image" );
    ios_swap_image_armed = 0;
    ios_swap_image_npend = 0;
}

static void test_flush( void )
{
    char *r = region( 0x7050000000ULL, 1u << 20 );
    char *text = r + 0x4000, *data = r + 0x80000;
    unsigned long long bump0;
    reset_tier();
    have_view = 1;
    the_view.base = r; the_view.size = 1u << 20; the_view.protect = SEC_IMAGE | VPROT_X64DATA;
    fill( r, 1u << 20, 7 );   /* what pread left in the anonymous view */
    page_vprot = VPROT_READ | VPROT_COMMITTED;

    ios_swap_image_armed = 1;
    ios_swap_image_note( &the_view, r + 0x1000, 0x7f000 );    /* .text: interior 0x4000..0x80000 */
    ios_swap_image_note( &the_view, r + 0x80000, 0x22800 );   /* .rdata: interior 0x80000..0xa0000 */
    ios_swap_image_armed = 0;
    ios_swap_image_flush( 1 );
    CHECK( ios_swap_image_npend == 0, "flush empties the notes" );
    CHECK( !take_unlocked && !map_unlocked, "take and map run with virtual_mutex held" );
    CHECK( !pwrite_locked, "pwrite runs with virtual_mutex released (ml1081)" );
    CHECK( locked == 0, "lock balanced" );
    CHECK( ios_swap_img_backs == 2 && ios_swap_img_bytes == 0x7c000 + 0x20000 && ios_swap_n == 2, "both interiors moved" );
    CHECK( is_file_backed( text ) && is_file_backed( data ) && is_file_backed( r + 0x9c000 ), "sections are MAP_SHARED of the swap file" );
    CHECK( is_anon( r ) && is_anon( r + 0xa0000 ), "header page and the page past the noted range stay anonymous" );
    CHECK( same( r, 1u << 20, 7 ), "every byte of the view intact" );
    {
        char pm[5]; unsigned long ino;
        CHECK( map_info( text, pm, &ino ) && pm[0] == 'r' && pm[1] == '-', "protections re-applied (read-only pages)" );
    }
    /* a store reaches the file */
    mprotect( data, 0x4000, PROT_READ | PROT_WRITE );
    data[5] = 0x5a;
    {
        char b = 0;
        unsigned k;
        uint64_t off = (uint64_t)-1;
        for (k = 0; k < ios_swap_n; k++) if (ios_swap_ext[k].va == data) off = ios_swap_ext[k].off;
        msync( data, 0x4000, MS_SYNC );
        CHECK( off != (uint64_t)-1 && pread( ios_swap_fd, &b, 1, (off_t)(off + 5) ) == 1 && b == 0x5a, "a store lands in the file" );
        CHECK( ios_swap_ext[0].img == 1 && ios_swap_ext[0].key == 0 && ios_swap_ext[0].born == 0, "image extents carry img, no churn key" );
    }
    data[5] = (char)(0x80005 * 31 + 7);   /* undo: same() below stays valid */

    /* a second flush of the same ranges: already backed -> nothing taken */
    bump0 = ios_swap_bump;
    ios_swap_image_armed = 1;
    ios_swap_image_note( &the_view, r + 0x1000, 0x7f000 );
    ios_swap_image_armed = 0;
    ios_swap_image_flush( 1 );
    CHECK( ios_swap_img_backs == 2 && ios_swap_bump == bump0, "an already backed range is not moved twice" );

    /* GUARD copy-back of part of an image extent: the count follows */
    ios_swap_release_range( text, 0x4000, 1 );
    CHECK( ios_swap_img_bytes == 0x7c000 + 0x20000 - 0x4000 && is_anon( text ) && same( text, 0x4000, 7 + 0x4000 * 31 ),
           "copy-back takes the page out of the image count, data kept" );

    /* the view goes away (delete_view): file space and counts return */
    ios_swap_release_range( r, 1u << 20, 0 );
    CHECK( ios_swap_n == 0 && ios_swap_img_bytes == 0 && ios_swap_bytes == 0 && ios_swap_bump == 0 && ios_swap_nfree == 0,
           "release returns every file range" );
    munmap( r, 1u << 20 );
}

static void test_refusals( void )
{
    char *r = region( 0x7058000000ULL, 1u << 20 );
    reset_tier();
    have_view = 1;
    the_view.base = r; the_view.size = 1u << 20; the_view.protect = SEC_IMAGE;   /* not pure x64 */
    fill( r, 1u << 20, 3 );
    ios_swap_image_armed = 1; ios_swap_image_note( &the_view, r + 0x4000, 0x40000 ); ios_swap_image_armed = 0;
    ios_swap_image_flush( 1 );
    CHECK( ios_swap_n == 0 && ios_swap_bump == 0 && is_anon( r + 0x4000 ), "no VPROT_X64DATA: nothing taken" );

    the_view.protect = SEC_IMAGE | VPROT_X64DATA;
    ios_swap_image_armed = 1; ios_swap_image_note( &the_view, r + 0x4000, 0x40000 ); ios_swap_image_armed = 0;
    ios_swap_image_flush( 0 );
    CHECK( ios_swap_n == 0 && ios_swap_image_npend == 0, "a failed map (ok = 0) drops the notes" );

    ios_swap_image_armed = 1; ios_swap_image_note( &the_view, r + 0x4000, 0x40000 ); ios_swap_image_armed = 0;
    have_view = 0;
    ios_swap_image_flush( 1 );
    CHECK( ios_swap_n == 0 && ios_swap_bump == 0, "a view that went away: nothing taken" );
    have_view = 1;

    ios_swap_image_armed = 1; ios_swap_image_note( &the_view, r + 0x4000, 0x40000 ); ios_swap_image_armed = 0;
    pwrite_fail = 1;
    ios_swap_image_flush( 1 );
    CHECK( ios_swap_n == 0 && ios_swap_img_refused >= 1 && is_anon( r + 0x4000 ) && same( r, 1u << 20, 3 ),
           "pwrite failure: the range keeps its anonymous data" );
    CHECK( ios_swap_bump == 0 && ios_swap_nfree == 0, "pwrite failure: the offset goes back" );

    /* the core alone: unaligned or overlapping maps are refused and give the offset back */
    {
        uint64_t off = ios_swap_image_take( 0x4000 );
        CHECK( off != (uint64_t)-1, "take" );
        CHECK( !ios_swap_image_map( r + 0x1000, 0x4000, off ) && ios_swap_bump == 0, "unaligned va refused, offset back" );
        CHECK( ios_swap_image_take( 0x3000 ) == (uint64_t)-1, "a length that is not whole host pages is refused" );
    }
    {
        int fd = ios_swap_fd;
        ios_swap_fd = -1;
        CHECK( ios_swap_image_take( 0x4000 ) == (uint64_t)-1 && !ios_swap_image_map( r, 0x4000, 0 ), "tier off: no-op" );
        ios_swap_fd = fd;
    }
    munmap( r, 1u << 20 );
    reset_tier();
}

static void test_broad_churn_and_census( void )
{
    char *r = region( 0x705c000000ULL, 4u << 20 );
    int i;
    setenv( "MADEIRA_SWAP_COVERAGE", "broad", 1 );
    ios_swap_config();
    reset_tier();
    have_view = 1;
    the_view.base = r; the_view.size = 4u << 20; the_view.protect = SEC_IMAGE | VPROT_X64DATA;
    fill( r, 4u << 20, 9 );
    for (i = 0; i < 20; i++)   /* load and unload an image again and again, young */
    {
        ios_swap_image_armed = 1; ios_swap_image_note( &the_view, r, 0x100000 ); ios_swap_image_armed = 0;
        ios_swap_image_flush( 1 );
        ios_swap_release_range( r, 4u << 20, 0 );
        anon_mmap_fixed( r, 0x100000, PROT_READ | PROT_WRITE, 0 );
    }
    CHECK( ios_swap_nchurn == 0 && ios_swap_nchurny == 0, "image extents never reach the churn filter" );
    CHECK( ios_swap_img_backs == 20 && ios_swap_img_bytes == 0, "twenty moves, all released" );
    ios_swap_tick( 1 );
    ios_swap_stats_line();
    munmap( r, 4u << 20 );
    setenv( "MADEIRA_SWAP_COVERAGE", "blocks", 1 );
    ios_swap_config();
}

int main( void )
{
    char path[] = "/tmp/madeira-swapimg-XXXXXX";
    int fd = mkstemp( path );
    if (fd < 0) return 2;
    close( fd );
    setenv( "MADEIRA_SWAP_FILE", path, 1 );
    setenv( "MADEIRA_SWAP_MB", "256", 1 );
    setenv( "MADEIRA_SWAP_COVERAGE", "blocks", 1 );   /* merged free list: given-back ranges lower the bump */
    setenv( "MADEIRA_SWAP_PUNCH_DEFER", "0", 1 );     /* ml1291: synchronous punches, ranges back at once (check-swap-coverage.py tests the queue) */
    ios_swap_init();
    {
        char pm[5]; unsigned long ino = 0;
        void *probe = mmap( NULL, 0x4000, PROT_READ, MAP_SHARED, ios_swap_fd, 0 );
        map_info( probe, pm, &ino );
        swap_ino = ino;
        munmap( probe, 0x4000 );
    }
    unlink( path );
    if (ios_swap_fd < 0 || !swap_ino) { printf( "FAIL: tier did not start\n" ); return 1; }
    test_switch();
    test_note();
    test_flush();
    test_refusals();
    test_broad_churn_and_census();
    printf( "%d failures\n", bad );
    return bad != 0;
}
'''

if not sys.platform.startswith('linux'):
    # fallocate, /proc/self/maps and MAP_FIXED_NOREPLACE, as check-swap-coverage.py
    print('note: the runtime part needs Linux; source checks only')
else:
  with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp) / 'swapimg.c'
    exe = Path(tmp) / 'swapimg'
    c.write_text(prelude + core + glue_stubs + pend_decl + note_fn + enabled_fn + flush_fn + harness)
    r = subprocess.run(['cc', '-O1', '-Wall', '-Wno-unused-function', '-Werror', '-o', str(exe), str(c)],
                       capture_output=True, text=True)
    check(r.returncode == 0, 'core + glue compile with -Wall -Werror' + ('' if r.returncode == 0 else ':\n' + r.stderr[-3000:]))
    if r.returncode == 0:
        run = subprocess.run([str(exe)], capture_output=True, text=True)
        print(run.stdout.strip())
        check(run.returncode == 0, 'runtime checks')
        err = run.stderr
        check('[swap] swap-images on: sections of pure-x64 images move to the swap file' in err, 'the switch is announced once')
        census = [l for l in err.splitlines() if l.startswith('[swap] census file-backed now=')]
        check(census and ' | images=0MB peak=' in census[-1] and 'sections=20' in census[-1], 'census carries the image figures')
        check('[swap] swap-images: 0 MB of image sections in the file' in err and '20 sections moved' in err,
              'stats line carries the image figures')
        check('[swap] swap-images: moved 0x7050004000+0x7c000 (image section' in err, 'moves are logged')

# ------------------------------------------------------------ source checks
mfiv = body_of(virt, 'static NTSTATUS map_file_into_view_ex( struct file_view *view, int fd, size_t start, size_t size,\n'
                     '                                       off_t offset, unsigned int vprot, BOOL removable,\n'
                     '                                       BOOL for_image )\n{')
tail = mfiv[mfiv.rindex('mprotect( map_addr, map_size, PROT_READ | PROT_WRITE );'):]
check('pread( fd, map_addr, size, offset );\n#ifdef WINE_IOS\n    if (for_image) ios_swap_image_note( view, map_addr, map_size );' in tail,
      'the note follows the read() fallback, images only')
check(mfiv.count('ios_swap_image_note') == 1, 'no other note in map_file_into_view_ex (mmapped sections are file pages already)')
check('if (!ios_swap_image_armed ||' in note_fn and 'mmap' not in note_fn and 'pwrite' not in note_fn,
      'the note is bookkeeping only and needs the armed loop')

mimv = body_of(virt, 'static NTSTATUS map_image_into_view( struct file_view *view, const UNICODE_STRING *nt_name, int fd,')
arm = mimv.index('ios_swap_image_armed = ios_swap_images_enabled() && ios_x64_image_nocopy_enabled() && !ios_map_resource_view &&')
loop = mimv.index('for (i = pos = 0; i < nt->FileHeader.NumberOfSections; i++)')
disarm = mimv.index('ios_swap_image_armed = 0;   /* madeira-bcd swap-images: only the sections loop notes */')
done = mimv.index('\ndone:\n')
check(arm < loop < disarm < done, 'armed right before the sections loop, disarmed right after it')
check('ios_swap_image_armed = 0;' in mimv[done:done + 200], 'disarmed at done: too')
armexpr = mimv[arm:mimv.index(';', arm)]
for part in ('IMAGE_FILE_MACHINE_AMD64', 'IMAGE_NT_OPTIONAL_HDR64_MAGIC', '!image_info->is_hybrid', '!image_info->wine_builtin',
             '!ios_wow_base()', '!ios_map_resource_view'):
    check(part in armexpr, 'armed only for the [x64-image] images: ' + part)
x64 = mimv[mimv.index('if (ios_x64_image_nocopy_enabled() && !ios_map_resource_view && !ios_wow_base() &&'):]
check('view->protect |= VPROT_X64DATA;' in x64[:800], 'the [x64-image] mark the flush re-checks is still set here')
check('ios_swap_image_npend = 0;' in mimv[:loop], 'stale notes are dropped before the loop')

vmi = body_of(virt, 'static NTSTATUS virtual_map_image( HANDLE mapping, void **addr_ptr, SIZE_T *size_ptr, HANDLE shared_file,')
check('done:\n    server_leave_uninterrupted_section( &virtual_mutex, &sigset );\n#ifdef WINE_IOS\n    ios_swap_image_flush( NT_SUCCESS(status) );' in vmi,
      'the flush runs right after virtual_map_image leaves virtual_mutex')
pos, in_order = 0, True
for s in ('server_enter_uninterrupted_section( &virtual_mutex, &sigset );', 'ios_swap_image_take( len )',
          'server_leave_uninterrupted_section( &virtual_mutex, &sigset );', 'pwrite( ios_swap_fd, va, len, (off_t)off )',
          'server_enter_uninterrupted_section( &virtual_mutex, &sigset );', 'ios_swap_image_map( va, len, off )',
          'mprotect_range( va, len, 0, 0 )', 'server_leave_uninterrupted_section( &virtual_mutex, &sigset );'):
    nxt = flush_fn.find(s, pos)
    in_order &= nxt >= 0
    pos = nxt + 1 if nxt >= 0 else pos
check(in_order and flush_fn.count('pwrite(') == 1 and flush_fn.count('server_enter_uninterrupted_section') == 2,
      'flush order: lock/take/unlock, pwrite, lock/map/protect/unlock')
check(flush_fn.count('VPROT_X64DATA') == 2, 'the view is re-checked as pure x64 before the take and before the map')
check('madeira_cfg_bool( "swap-images", 0 )' in enabled_fn and 'if (ios_swap_fd < 0) on = 0;' in enabled_fn,
      'swap-images is read once, and is off while the tier is off')

setprot = body_of(virt, 'static NTSTATUS set_protection( struct file_view *view, void *base, SIZE_T size, ULONG protect )')
check('if ((vprot & VPROT_GUARD) || ((vprot & (VPROT_EXEC | VPROT_WRITECOPY)) && !(view->protect & VPROT_X64DATA)))\n'
      '        ios_swap_release_range( base, size, 1 );' in setprot,
      'set_protection: GUARD always leaves the tier, EXEC/WRITECOPY only outside pure-x64 image views')
check(setprot.index('ios_swap_release_range( base, size, 1 )') < setprot.index('if (!set_vprot( view, base, size, vprot | VPROT_COMMITTED ))'),
      'set_protection: still before set_vprot (ml1257)')
cat = (root / 'app/Madeira/ConfigCatalog.generated.swift').read_text()
check(re.search(r'key: "swap-images".*kind: \.bool, defaultValue: "0"', cat) is not None, 'catalog lists swap-images, off by default')

if failures:
    print('FAILED:')
    for f in failures:
        print('  - ' + f)
    raise SystemExit(1)
print('PASS: swap-images moves pure-x64 image sections to the swap file outside virtual_mutex')
