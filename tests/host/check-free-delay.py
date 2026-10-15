#!/usr/bin/env python3
"""Delayed release of 1-16 MB guest allocations (MADEIRA_FREE_DELAY_MS); no Wine runs.

Compiles the production ios_fd_* helpers from build/ntdll-unix/virtual_ios.c
against stubs for the view tree, the clock and NtFreeVirtualMemory, and checks:
  - a whole-view MEM_RELEASE of a private 1-16 MB guest-band allocation is held
    (reported freed at once), a second release of the same base reports
    STATUS_MEMORY_NOT_ALLOCATED's case, anything else is not held;
  - held views are really released once the delay has run out, or at once
    while more than 128 MB are held, through the bypass (never re-held);
  - unset (the default) or MADEIRA_FREE_DELAY_MS=0 holds nothing;
  - the NtFreeVirtualMemory call site drains first and only takes size-0,
    page-aligned MEM_RELEASE calls;
  - ios_fd_reuse (MADEIRA_FREE_DELAY_REUSE, default on): a reservation at an
    explicit address whose range meets the same program's held releases and no
    other view frees exactly those held ranges first (out of the ring, through
    the bypass, never twice), so Horizon Forbidden West's 2 MB-aligned
    re-reservation inside the block it just released is found free instead of
    STATUS_CONFLICTING_ADDRESSES; one, several, partly met and rounded-into
    blocks are freed, while a range that also meets a live view or another
    program's held release, a changed view, a commit, a placeholder replacement,
    a touching block and a request without an address change nothing;
    MADEIRA_FREE_DELAY_REUSE=0 keeps the refusal, and with MADEIRA_FREE_DELAY_MS=0
    nothing is held, so nothing changes;
  - its call sites: NtAllocateVirtualMemory[Ex] call it only for a request with
    an address, right before their one generic allocation, virtual_map_section
    only for a view with a base (not a placeholder replacement) before map_view,
    and allocate_virtual_memory never (Madeira's own fixed placements, such as
    the jumbo slot walk, keep their behaviour).
Needs python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()

start = native.index('#define IOS_FD_N 256')
block = native[start:native.index('#endif', native.index('static int ios_fd_take('))]

free_fn = native[native.index('NTSTATUS WINAPI NtFreeVirtualMemory( HANDLE process'):]
site = free_fn[free_fn.index('base = ROUND_ADDR( addr, page_mask );'):][:700]
assert 'if (!ios_fd_bypass)' in site and 'ios_fd_drain( 0 );' in site
assert site.index('ios_fd_drain( 0 );') < site.index('ios_fd_take( base, &held )')
assert 'if (type == MEM_RELEASE && !size && base == addr)' in site
assert 'if (t == 1) { *addr_ptr = base; *size_ptr = held; return STATUS_SUCCESS; }' in site
assert 'if (t == 2) return STATUS_MEMORY_NOT_ALLOCATED;' in site

def body(signature):
    b = native[native.index(signature):]
    return b[:b.index('\n}\n')]

assert native.index('static unsigned int ios_fd_reuse( const void *addr, SIZE_T size, ULONG type );') \
    < native.index('static unsigned int virtual_map_section( HANDLE handle,'), 'declared before its first caller'
section = body('static unsigned int virtual_map_section( HANDLE handle,')
call = 'if (base && !(alloc_type & MEM_REPLACE_PLACEHOLDER)) ios_fd_reuse( base, size, MEM_RESERVE );'
assert section.count('ios_fd_reuse(') == 1
assert section.index('if (!(size = ROUND_SIZE( 0, size, page_mask ))) return STATUS_INVALID_PARAMETER;') \
    < section.index(call) < section.index('server_enter_uninterrupted_section( &virtual_mutex, &sigset );') \
    < section.index('res = map_view( &view, base, size, alloc_type, vprot, limit_low, limit_high, 0 );'), \
    'the view\'s final range, before map_view and outside virtual_mutex'
nt = native[native.index('NTSTATUS WINAPI NtAllocateVirtualMemory( HANDLE process'):]
nt = nt[:nt.index('NTSTATUS WINAPI NtAllocateVirtualMemoryEx(')]
assert nt.count('ios_fd_reuse(') == 1
assert 'if (!ios_steered && *ret) ios_fd_reuse( *ret, *size_ptr, type );\n' \
       '            if (!ios_steered)\n' \
       '                st = allocate_virtual_memory( ret, size_ptr, type, protect, 0, limit, 0, 0 );' in nt, \
    'only with an address, right before the generic allocation'
ex = body('NTSTATUS WINAPI NtAllocateVirtualMemoryEx(')
assert ex.count('ios_fd_reuse(') == 1
assert 'if (!caged && *ret) ios_fd_reuse( *ret, *size_ptr, type );\n' \
       '            if (!caged)\n' \
       '                st = allocate_virtual_memory( ret, size_ptr, type, protect,' in ex, \
    'only with an address, right before the generic allocation'
assert 'ios_fd_reuse' not in body('static NTSTATUS allocate_virtual_memory('), 'internal fixed placements unchanged'
assert native.count('ios_fd_reuse(') == 5, 'the declaration, the definition and three callers'

code = r'''
#include <assert.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
typedef int NTSTATUS;
typedef size_t SIZE_T;
typedef void *HANDLE;
typedef unsigned int ULONG;
#define MEM_COMMIT  0x1000
#define MEM_RESERVE 0x2000
#define MEM_REPLACE_PLACEHOLDER 0x4000
#define MEM_RELEASE 0x8000
typedef uintptr_t UINT_PTR;
static const UINT_PTR page_mask = 0xfff;
static const UINT_PTR granularity_mask = 0xffff;
#define ROUND_ADDR(addr,mask) ((void *)((UINT_PTR)(addr) & ~(UINT_PTR)(mask)))
#define SEC_FILE    0x800000
#define SEC_IMAGE   0x1000000
#define VPROT_SYSTEM 0x0200
#define NtCurrentProcess() ((HANDLE)~(uintptr_t)0)
struct file_view { char *base; size_t size; unsigned int protect; int valloc; };
static struct file_view views[64];
static int nviews;
static int virtual_mutex;
static void server_enter_uninterrupted_section( int *m, sigset_t *s ) { (void)m; (void)s; }
static void server_leave_uninterrupted_section( int *m, sigset_t *s ) { (void)m; (void)s; }
static struct file_view *find_view( const void *addr, size_t size )
{
    int i;
    (void)size;
    for (i = 0; i < nviews; i++)
        if ((const char *)addr >= views[i].base && (const char *)addr < views[i].base + views[i].size) return &views[i];
    return NULL;
}
/* the first view overlapping [addr, addr + size), as Wine's */
static struct file_view *find_view_range( const void *addr, size_t size )
{
    int i;
    for (i = 0; i < nviews; i++)
        if (views[i].size && views[i].base < (const char *)addr + size &&
            views[i].base + views[i].size > (const char *)addr) return &views[i];
    return NULL;
}
static int is_view_valloc( const struct file_view *v ) { return v->valloc; }
static void *cur_peb = (void *)0x1000;   /* the calling thread's program */
static void *ios_jit_current_peb( void ) { return cur_peb; }
static unsigned int fake_ms;
static int fake_clock( int id, struct timespec *ts ) { (void)id; ts->tv_sec = fake_ms / 1000; ts->tv_nsec = (fake_ms % 1000) * 1000000L; return 0; }
#define clock_gettime fake_clock
static char *released[64];
static int nreleased, bypass_seen;
static NTSTATUS NtFreeVirtualMemory( HANDLE process, void **addr, SIZE_T *size, ULONG type );
'''
code += block
code += r'''
static NTSTATUS NtFreeVirtualMemory( HANDLE process, void **addr, SIZE_T *size, ULONG type )
{
    struct file_view *v = find_view( *addr, 0 );
    unsigned int i;
    (void)process; (void)size;
    assert( type == MEM_RELEASE );
    if (ios_fd_bypass) bypass_seen++;
    for (i = 0; i < ios_fd_n; i++) assert( ios_fd_ring[i].base != (char *)*addr );   /* out of the ring first */
    assert( v && v->base == (char *)*addr );                                            /* a whole live view */
    v->size = 0;                                                                        /* gone */
    released[nreleased++] = *addr;
    return 0;
}
static struct file_view *view( uintptr_t base, size_t size, unsigned int protect, int valloc )
{
    struct file_view *v = &views[nviews++];
    v->base = (char *)base; v->size = size; v->protect = protect; v->valloc = valloc;
    return v;
}
#define MB (1u << 20)
#define CONFLICT ((int)0xc0000018)
/* map_fixed_area's test: any view in the range refuses the reservation */
static int model_reserve( uintptr_t base, size_t size )
{
    if (find_view_range( (const void *)base, size )) return CONFLICT;
    view( base, size, 0, 1 );
    return 0;
}
static int is_held( uintptr_t base )
{
    unsigned int i;
    for (i = 0; i < ios_fd_n; i++) if (ios_fd_ring[i].base == (char *)base) return 1;
    return 0;
}
/* a program's allocation that it releases at once: held */
static void hold( uintptr_t base, size_t size )
{
    SIZE_T held = 0;
    view( base, size, 0, 1 );
    assert( ios_fd_take( (char *)base, &held ) == 1 && held == size );
}
static void reset( void )
{
    fake_ms += 10000;
    ios_fd_drain( 0 );
    assert( !ios_fd_n && !ios_fd_bytes );
    nviews = 0; nreleased = 0; bypass_seen = 0;
}
/* Horizon Forbidden West, build 517, log 08:49: 2 MB at P (not 2 MB-aligned) and
 * then 4 MB-4 KB at Q are allocated and released at once; the game then reserves
 * 2 MB at A, the 2 MB-aligned address inside Q's block. */
static const uintptr_t P = 0x7041230000ull, Q = 0x7041430000ull, A = 0x7041600000ull;
static void hfw( int reuse_on )
{
    reset();
    hold( P, 2 * MB );
    hold( Q, 4 * MB - 0x1000 );
    assert( A > Q && A + 2 * MB <= Q + 4 * MB - 0x1000 && !(A & (2 * MB - 1)) );
    assert( model_reserve( A, 2 * MB ) == CONFLICT );                  /* what the game kept getting */
    if (!reuse_on)
    {
        assert( ios_fd_reuse( (void *)A, 2 * MB, MEM_RESERVE | MEM_COMMIT ) == 0 );
        assert( !nreleased && is_held( Q ) && model_reserve( A, 2 * MB ) == CONFLICT );
        fake_ms += 2000;                                                /* only after the delay */
        ios_fd_drain( 0 );
        assert( model_reserve( A, 2 * MB ) == 0 );
        return;
    }
    assert( ios_fd_reuse( (void *)A, 2 * MB, MEM_RESERVE | MEM_COMMIT ) == 1 );
    assert( nreleased == 1 && released[0] == (char *)Q && bypass_seen == 1 );
    assert( !is_held( Q ) && is_held( P ) && ios_fd_n == 1 && ios_fd_bytes == 2 * MB );   /* P keeps its delay */
    assert( model_reserve( A, 2 * MB ) == 0 );                          /* free, as on Windows */
    assert( ios_fd_reuse( (void *)A, 2 * MB, MEM_RESERVE ) == 0 );      /* nothing held there any more */
}
static void reuse_cases( void )
{
    const uintptr_t S = 0x7045000000ull, T = 0x7046000000ull, U = 0x7047000000ull, W = 0x7048000000ull;
    const uintptr_t X = 0x7049000000ull, Y = 0x704a000000ull, Z = 0x704b000000ull, V = 0x704c000000ull;
    const uintptr_t R = 0x704d000000ull, E = 0x704e000000ull, F = 0x704f000000ull, G = 0x7050000000ull;
    int n0, i, j;

    reset();
    /* exactly the released range */
    hold( E, 1 * MB );
    assert( ios_fd_reuse( (void *)E, 1 * MB, MEM_RESERVE ) == 1 && model_reserve( E, 1 * MB ) == 0 );
    /* an address below 64 KB granularity rounds down into the end of a 4 MB-4 KB block */
    hold( R, 4 * MB - 0x1000 );
    assert( find_view_range( (void *)(R + 4 * MB - 0x800), 0x1000 ) == NULL );
    assert( model_reserve( R + 4 * MB - 0x10000, 0x10000 ) == CONFLICT );
    assert( ios_fd_reuse( (void *)(R + 4 * MB - 0x800), 0x1000, MEM_RESERVE ) == 1 && !is_held( R ) );
    /* several blocks: three adjacent, one elsewhere keeps its delay */
    hold( S, 2 * MB ); hold( S + 2 * MB, 2 * MB ); hold( S + 4 * MB, 2 * MB );
    hold( F, 1 * MB );
    n0 = nreleased;
    assert( ios_fd_reuse( (void *)(S + MB), 4 * MB, MEM_RESERVE ) == 3 );
    assert( nreleased == n0 + 3 && !is_held( S ) && !is_held( S + 2 * MB ) && !is_held( S + 4 * MB ) && is_held( F ) );
    assert( model_reserve( S + MB, 4 * MB ) == 0 );
    /* two blocks with free space between them, held in the opposite order */
    hold( T + 2 * MB, 1 * MB ); hold( T, 1 * MB );
    assert( ios_fd_reuse( (void *)T, 3 * MB, MEM_RESERVE ) == 2 && model_reserve( T, 3 * MB ) == 0 );
    /* partly met: the range runs past the block into free space */
    hold( U, 2 * MB );
    assert( ios_fd_reuse( (void *)(U + MB), 2 * MB, MEM_RESERVE ) == 1 && model_reserve( U + MB, 2 * MB ) == 0 );
    /* held + live: refused as before, nothing freed; the held part alone is freed */
    hold( W, 2 * MB );
    view( W + 2 * MB, 1 * MB, 0, 1 );
    n0 = nreleased;
    assert( ios_fd_reuse( (void *)W, 3 * MB, MEM_RESERVE ) == 0 && nreleased == n0 && is_held( W ) );
    assert( model_reserve( W, 3 * MB ) == CONFLICT );
    view( X, 0x10000, 0, 1 );                                           /* live view before a held block */
    hold( X + 0x10000, 1 * MB );
    assert( ios_fd_reuse( (void *)X, 0x10000 + MB, MEM_RESERVE ) == 0 && is_held( X + 0x10000 ) );
    assert( ios_fd_reuse( (void *)W, 2 * MB, MEM_RESERVE ) == 1 && !is_held( W ) );
    /* another program of the session (one address space here) cannot free this one's held release */
    hold( G, 1 * MB );
    cur_peb = (void *)0x2000;
    n0 = nreleased;
    assert( ios_fd_reuse( (void *)G, 1 * MB, MEM_RESERVE ) == 0 && nreleased == n0 && is_held( G ) );
    cur_peb = (void *)0x1000;
    assert( ios_fd_reuse( (void *)G, 1 * MB, MEM_RESERVE ) == 1 && !is_held( G ) );
    /* a held block whose view has changed since (half of it released by size) counts as live */
    hold( Y, 2 * MB );
    find_view( (void *)Y, 0 )->size = MB;
    n0 = nreleased;
    assert( ios_fd_reuse( (void *)Y, 2 * MB, MEM_RESERVE ) == 0 && nreleased == n0 && is_held( Y ) );
    find_view( (void *)Y, 0 )->size = 2 * MB;
    /* not a reservation at an address: a commit, a placeholder replacement, no address, a touching block */
    hold( Z, 1 * MB );
    hold( V, 1 * MB );
    n0 = nreleased;
    assert( ios_fd_reuse( (void *)Z, 1 * MB, MEM_COMMIT ) == 0 );
    assert( ios_fd_reuse( (void *)Z, 1 * MB, MEM_RESERVE | MEM_REPLACE_PLACEHOLDER ) == 0 );
    assert( ios_fd_reuse( NULL, 1 * MB, MEM_RESERVE ) == 0 );
    assert( ios_fd_reuse( (void *)Z, 0, MEM_RESERVE ) == 0 );
    assert( ios_fd_reuse( (void *)(V + MB), 1 * MB, MEM_RESERVE ) == 0 );
    assert( ios_fd_reuse( (void *)(V - MB), 1 * MB, MEM_RESERVE ) == 0 );
    assert( nreleased == n0 && is_held( Z ) && is_held( V ) && is_held( F ) && is_held( Y ) && is_held( X + 0x10000 ) );
    /* the rest keep their delay, and nothing is ever freed twice */
    fake_ms += 1999;
    ios_fd_drain( 0 );
    assert( nreleased == n0 );
    fake_ms += 1;
    ios_fd_drain( 0 );
    assert( !ios_fd_n && !ios_fd_bytes && nreleased == n0 + 5 && bypass_seen == nreleased );
    for (i = 0; i < nreleased; i++) for (j = i + 1; j < nreleased; j++) assert( released[i] != released[j] );
}
int main( int argc, char **argv )
{
    SIZE_T held = 0;
    const int off = argc > 1 && !strcmp( argv[1], "off" );
    const int reuse_off = argc > 1 && !strcmp( argv[1], "reuse-off" );
    fake_ms = 100000;
    view( 0x7040000000ull, 2 * MB, 0, 1 );                 /* the GoT case */
    view( 0x7050000000ull, 512 * 1024, 0, 1 );             /* too small */
    view( 0x7060000000ull, 32 * MB, 0, 1 );                /* too large */
    view( 0x7070000000ull, 2 * MB, SEC_IMAGE, 0 );         /* not private */
    view( 0x7c10000000ull, 2 * MB, 0, 1 );                 /* outside the guest band */
    view( 0x7080000000ull, 16 * MB, 0, 1 );
    if (off)
    {
        assert( ios_fd_take( (char *)0x7040000000ull, &held ) == 0 );
        assert( ios_fd_reuse( (void *)0x7040000000ull, 2 * MB, MEM_RESERVE ) == 0 && !nreleased );
        puts( "off: nothing held, a reservation at an address changes nothing" );
        return 0;
    }
    if (reuse_off)
    {
        hfw( 0 );
        puts( "reuse off: the reservation over the held block is refused until the delay runs out" );
        return 0;
    }
    assert( ios_fd_take( (char *)0x7040000000ull, &held ) == 1 && held == 2 * MB );
    assert( ios_fd_take( (char *)0x7040000000ull, &held ) == 2 );          /* double release */
    assert( ios_fd_take( (char *)0x7040001000ull, &held ) == 0 );          /* not the view base */
    assert( ios_fd_take( (char *)0x7050000000ull, &held ) == 0 );
    assert( ios_fd_take( (char *)0x7060000000ull, &held ) == 0 );
    assert( ios_fd_take( (char *)0x7070000000ull, &held ) == 0 );
    assert( ios_fd_take( (char *)0x7c10000000ull, &held ) == 0 );
    assert( ios_fd_take( (char *)0x7080000000ull, &held ) == 1 && held == 16 * MB );
    fake_ms += 1999;
    ios_fd_drain( 0 );
    assert( nreleased == 0 && ios_fd_n == 2 );
    fake_ms += 1;
    ios_fd_drain( 0 );
    assert( nreleased == 2 && bypass_seen == 2 && ios_fd_n == 0 && ios_fd_bytes == 0 );
    /* the bypass is not re-held */
    ios_fd_bypass = 1;
    assert( ios_fd_take( (char *)0x7040000000ull, &held ) == 0 );
    ios_fd_bypass = 0;
    /* past the 128 MB cap entries go at once until at most 128 MB are held */
    nviews = 0; nreleased = 0;
    for (int i = 0; i < 9; i++) view( 0x7100000000ull + (uintptr_t)i * 0x1000000, 16 * MB, 0, 1 );
    for (int i = 0; i < 9; i++) assert( ios_fd_take( (char *)(0x7100000000ull + (uintptr_t)i * 0x1000000), &held ) == 1 );
    assert( ios_fd_bytes == 144u * MB );
    ios_fd_drain( 0 );
    assert( nreleased == 1 && ios_fd_n == 8 && ios_fd_bytes == 128u * MB );
    fake_ms += 2000;
    ios_fd_drain( 0 );
    assert( nreleased == 9 && ios_fd_n == 0 && !ios_fd_bytes );
    puts( "held 1-16 MB guest releases, released after the delay or past the cap" );
    hfw( 1 );
    reuse_cases();
    puts( "a reservation at an address over its own program's held releases (and no live view) frees exactly those at once" );
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-free-delay-') as directory:
    folder = Path(directory)
    src = folder / 'check.c'
    src.write_text(code)
    exe = folder / 'check'
    cc = os.environ.get('CC', 'cc')
    flags = [cc, '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-Wno-unused-parameter',
             '-g', '-pthread', str(src), '-o', str(exe)]
    sanitize = ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    if subprocess.run(flags[:1] + sanitize + flags[1:], capture_output=True).returncode == 0:
        print('built with AddressSanitizer/UBSan')
    else:
        r = subprocess.run(flags, capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        print('built without sanitizers')
    # off unless set (opt-in); MADEIRA_FREE_DELAY_REUSE is on unless it is 0
    for value, reuse, mode in [(None, None, 'off'), ('2000', None, 'on'), ('2000', '1', 'on'), ('0', None, 'off'),
                               ('2000', '0', 'reuse-off')]:
        env = dict(os.environ)
        env.pop('MADEIRA_FREE_DELAY_MS', None)
        env.pop('MADEIRA_FREE_DELAY_REUSE', None)
        if value is not None:
            env['MADEIRA_FREE_DELAY_MS'] = value
        if reuse is not None:
            env['MADEIRA_FREE_DELAY_REUSE'] = reuse
        r = subprocess.run([str(exe), mode], env=env, capture_output=True, text=True)
        assert r.returncode == 0, r.stdout + r.stderr
        if mode == 'on':
            assert '[free-delay] #1 reservation at 0x7041600000+0x200000: 1 held release(s) from 0x7041430000 ' \
                   '(0x3ff000 bytes) freed at once (1 in flight)' in r.stderr, r.stderr
            assert 'also meets a live view or another program\'s release: its 1 held release(s) stay held' \
                in r.stderr, r.stderr
        if mode == 'reuse-off':
            assert '[free-delay] MADEIRA_FREE_DELAY_REUSE=0: a reservation at 0x7041600000+0x200000' in r.stderr, r.stderr
        print(f'MADEIRA_FREE_DELAY_MS={value!r} MADEIRA_FREE_DELAY_REUSE={reuse!r}: {" / ".join(r.stdout.split(chr(10))).strip(" /")}')
print('PASS: released 1-16 MB guest allocations are held for the delay and then really freed; '
      'a program\'s reservation at its own held address frees that hold at once')
