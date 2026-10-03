#!/usr/bin/env python3
"""Delayed release of 1-16 MB guest allocations (MADEIRA_FREE_DELAY_MS); no Wine runs.

Compiles the production ios_fd_* helpers from build/ntdll-unix/virtual_ios.c
against stubs for the view tree, the clock and NtFreeVirtualMemory, and checks:
  - a whole-view MEM_RELEASE of a private 1-16 MB guest-band allocation is held
    (reported freed at once), a second release of the same base reports
    STATUS_MEMORY_NOT_ALLOCATED's case, anything else is not held;
  - held views are really released once the delay has run out, or at once
    while more than 128 MB are held, through the bypass (never re-held);
  - MADEIRA_FREE_DELAY_MS=0 holds nothing;
  - the NtFreeVirtualMemory call site drains first and only takes size-0,
    page-aligned MEM_RELEASE calls.
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
#define MEM_RELEASE 0x8000
#define SEC_FILE    0x800000
#define SEC_IMAGE   0x1000000
#define VPROT_SYSTEM 0x0200
#define NtCurrentProcess() ((HANDLE)~(uintptr_t)0)
struct file_view { char *base; size_t size; unsigned int protect; int valloc; };
static struct file_view views[16];
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
static int is_view_valloc( const struct file_view *v ) { return v->valloc; }
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
    (void)process; (void)size;
    assert( type == MEM_RELEASE );
    if (ios_fd_bypass) bypass_seen++;
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
int main( int argc, char **argv )
{
    SIZE_T held = 0;
    const int off = argc > 1 && !strcmp( argv[1], "off" );
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
        puts( "off: nothing held" );
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
    for value, mode in [(None, 'on'), ('2000', 'on'), ('0', 'off')]:
        env = dict(os.environ)
        env.pop('MADEIRA_FREE_DELAY_MS', None)
        if value is not None:
            env['MADEIRA_FREE_DELAY_MS'] = value
        r = subprocess.run([str(exe), mode], env=env, capture_output=True, text=True)
        assert r.returncode == 0, r.stdout + r.stderr
        print(f'MADEIRA_FREE_DELAY_MS={value!r}: {r.stdout.strip()}')
print('PASS: released 1-16 MB guest allocations are held for the delay and then really freed')
