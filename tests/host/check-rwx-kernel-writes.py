#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Kernel writes into anonymous RWX memory go through its RW alias (server_ios.c, virtual_ios.c); no Wine runs.

Models the iOS dual mapping on the host: one shared memory object mapped twice, a read-only view
standing in for the JIT pool's RX view at the guest address and a read-write view as its RW alias,
registered in the production anon-RWX alias table (and, for the pool branch, as the pool itself).
Compiles the production reply-data path (read_reply_data, ios_read_reply_guest and its helpers),
virtual_locked_read/pread/recvmsg with the ios_kw_* helpers, ios_range_writable and the alias
table code against stubs (a fake mach_vm_region over the test's own mappings, the reply fd, the
write-watch helpers), and checks:
  - the model reproduces the problem: the old reply read (read_reply_data) into the read-only view
    is a fatal protocol error, and virtual_locked_read without the alias fails with EFAULT;
  - a reply into aliased memory, or into the pool's RX range, arrives through the alias across page
    boundaries, routed before any read() rather than after a failed one (checked in the log), and the
    reply stream stays in step;
  - a reply into memory that is neither aliased nor writable is drained and reported as a fault
    (wait_reply turns that into STATUS_ACCESS_VIOLATION), and the next reply is read intact;
  - read(), pread() and recvmsg() (one aliased iovec of two) fill aliased memory through the alias;
    a destination with an unwritable page fails with EFAULT before any byte is consumed;
  - releasing a range retires exactly the aliases that start inside it, so a later lookup or
    cover check at that address finds no stale backing; NtFreeVirtualMemory retires before
    free_pages.
Needs python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
server = (root / 'build/ntdll-unix/server_ios.c').read_text()
virtual = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


def span(source, first, last_signature):
    start = source.index(first)
    return source[start:source.index('\n}', source.index(last_signature, start)) + 2] + '\n'


def upto(source, first, last_line):
    start = source.index(first)
    return source[start:source.index(last_line, start) + len(last_line)] + '\n'


# wait_reply reads a reply's data through ios_read_reply_guest and fails the call on a fault.
wait = function(server, 'static inline unsigned int wait_reply(')
assert 'ios_read_reply_guest( req->reply_data, req->u.reply.reply_header.reply_size, code, &fault )' in wait
assert wait.index('ios_read_reply_guest(') < wait.index('if (fault) return STATUS_ACCESS_VIOLATION;')
# NtFreeVirtualMemory retires the aliases of a released range before the pages go.
free_fn = virtual[virtual.index('NTSTATUS WINAPI NtFreeVirtualMemory( HANDLE process'):]
release = free_fn[free_fn.index('    case MEM_RELEASE:\n'):]
release = release[:release.index('break;')]
assert release.index('ios_jit_anon_alias_retire_range( base, size );') < release.index('free_pages( view, base, size )')

code = r'''
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/uio.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_vm.h>
typedef vm_map_t fake_task_t;
#else
typedef int kern_return_t; typedef int fake_task_t; typedef uint64_t mach_vm_address_t, mach_vm_size_t;
typedef unsigned int mach_msg_type_number_t, mach_port_t; typedef int *vm_region_info_t; typedef int vm_region_flavor_t;
typedef struct { int protection; } vm_region_basic_info_data_64_t;
#define KERN_SUCCESS 0
#define VM_REGION_BASIC_INFO_64 9
#define VM_REGION_BASIC_INFO_COUNT_64 1
#define VM_PROT_READ 1
#define VM_PROT_WRITE 2
#define MACH_PORT_NULL 0
static fake_task_t mach_task_self( void ) { return 1; }
#endif
typedef int BOOL;
typedef int NTSTATUS;
#define TRUE 1
#define FALSE 0
#define STATUS_SUCCESS 0
#define max(a, b) ((a) > (b) ? (a) : (b))
#define GetCurrentThreadId() 0x1234u
#define dprintf(fd, ...) fprintf( stderr, __VA_ARGS__ )

/* ---- fake address map: the test's own mappings; anything else (heap, stack) is ordinary read-write memory */
struct fake_region { uintptr_t lo, hi; int prot; };
static struct fake_region fake_map[8];
static int fake_n;
static void fake_add( void *p, size_t n, int prot )
{
    fake_map[fake_n].lo = (uintptr_t)p; fake_map[fake_n].hi = (uintptr_t)p + n; fake_map[fake_n].prot = prot; fake_n++;
}
static kern_return_t fake_mach_vm_region( fake_task_t t, mach_vm_address_t *a, mach_vm_size_t *s, vm_region_flavor_t f,
                                          vm_region_info_t info, mach_msg_type_number_t *c, mach_port_t *o )
{
    int i;
    (void)t; (void)f; (void)c; (void)o;
    for (i = 0; i < fake_n; i++)
        if (*a >= fake_map[i].lo && *a < fake_map[i].hi)
        {
            *a = fake_map[i].lo; *s = fake_map[i].hi - fake_map[i].lo;
            ((vm_region_basic_info_data_64_t *)info)->protection = fake_map[i].prot;
            return KERN_SUCCESS;
        }
    *a &= ~(mach_vm_address_t)0xfff; *s = 0x1000;
    ((vm_region_basic_info_data_64_t *)info)->protection = VM_PROT_READ | VM_PROT_WRITE;
    return KERN_SUCCESS;
}
#define mach_vm_region fake_mach_vm_region

/* ---- stubs for the reply path */
static struct { int reply_fd; } thread_data;
#define ntdll_get_thread_data() (&thread_data)
static jmp_buf fatal_jmp;
static int fatal_armed, fatal_errno;
static void __attribute__((noreturn)) server_protocol_perror( const char *err )
{
    fatal_errno = errno;
    if (fatal_armed) longjmp( fatal_jmp, 1 );
    fprintf( stderr, "unexpected protocol error: %s: %s\n", err, strerror( fatal_errno ) );
    _exit( 3 );
}
static void __attribute__((noreturn)) abort_thread( int status )
{
    if (fatal_armed) longjmp( fatal_jmp, 2 );
    fprintf( stderr, "unexpected abort_thread(%d)\n", status );
    _exit( 4 );
}

/* ---- stubs for the alias table and virtual_locked_* */
void *ios_jit_rx_base_global, *ios_jit_rw_base_global;
size_t ios_jit_pool_size_global;
static pthread_mutex_t ios_pool_lock = PTHREAD_MUTEX_INITIALIZER;
static int notes, mono_retired;
static uint64_t last_mono_retired;
void ios_jit_anon_alias_note_write( unsigned long long addr ) { (void)addr; notes++; }
static void ios_mono_alias_retire( uint64_t guest_rx ) { mono_retired++; last_mono_retired = guest_rx; }
static int virtual_mutex, use_kernel_writewatch;
static void server_enter_uninterrupted_section( int *m, sigset_t *s ) { (void)m; (void)s; }
static void server_leave_uninterrupted_section( int *m, sigset_t *s ) { (void)m; (void)s; }
static NTSTATUS check_write_access( void *addr, size_t size, BOOL *ww ) { (void)addr; (void)size; *ww = FALSE; return 0; }
static void update_write_watches( void *addr, size_t size, size_t accessed ) { (void)addr; (void)size; (void)accessed; }
'''
code += upto(virtual, '#define IOS_JIT_MAX_ANON_ALIASES', 'static volatile int ios_jit_anon_alias_tombstones = 0;')
code += function(virtual, 'uintptr_t ios_jit_anon_alias_lookup(uintptr_t fault_addr)\n{')
code += function(virtual, 'int ios_jit_anon_alias_find_cover(void *user_va, size_t size, void **rw_out, void **rx_out)\n{')
code += function(virtual, 'static void ios_jit_anon_alias_retire_range(')
code += function(virtual, 'static int ios_range_writable( const void *addr, size_t size )\n{')
code += span(virtual, '#define IOS_KW_PAGE', 'static ssize_t ios_kw_recvmsg(')
code += function(virtual, 'ssize_t virtual_locked_read( int fd, void *addr, size_t size )\n{')
code += function(virtual, 'ssize_t virtual_locked_pread( int fd, void *addr, size_t size, off_t offset )\n{')
code += function(virtual, 'ssize_t virtual_locked_recvmsg( int fd, struct msghdr *hdr, int flags )\n{')
code += function(server, 'static BOOL read_reply_data( void *buffer, size_t size )\n{')
code += span(server, '#define IOS_REPLY_PAGE', 'static BOOL ios_read_reply_guest(')
code += r'''
#define VIEW 0x10000   /* a multiple of every host page size */
static unsigned char pattern[3 * VIEW];

static void make_view( char **rx, char **rw )   /* one object, a read-only "RX" view and a read-write alias */
{
    FILE *f = tmpfile();
    int fd;
    assert( f );
    fd = fileno( f );
    assert( !ftruncate( fd, VIEW ) );
    *rx = mmap( NULL, VIEW, PROT_READ, MAP_SHARED, fd, 0 );
    *rw = mmap( NULL, VIEW, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0 );
    assert( *rx != MAP_FAILED && *rw != MAP_FAILED );
    fclose( f );
    fake_add( *rx, VIEW, VM_PROT_READ );
    fake_add( *rw, VIEW, VM_PROT_READ | VM_PROT_WRITE );
}

static void alias( int slot, char *rx, size_t size, char *rw )
{
    ios_jit_anon_aliases[slot].user_va_end = (uintptr_t)rx + size;
    ios_jit_anon_aliases[slot].jit_rw_alias = (uintptr_t)rw;
    ios_jit_anon_aliases[slot].jit_rx_alias = (uintptr_t)rx;
    ios_jit_anon_aliases[slot].user_va = (uintptr_t)rx;
    if (slot >= ios_jit_anon_alias_count) ios_jit_anon_alias_count = slot + 1;
    ios_jit_anon_alias_live++;
}

static void new_pipe( int fds[2] )
{
    static int old_write = -1;
    if (old_write >= 0) { close( thread_data.reply_fd ); close( old_write ); }
    assert( !pipe( fds ) );
    assert( !fcntl( fds[0], F_SETFL, O_NONBLOCK ) );   /* every byte is written first: a lost one fails at once */
    thread_data.reply_fd = fds[0];
    old_write = fds[1];
}

static void put( int fd, const void *p, size_t n ) { assert( write( fd, p, n ) == (ssize_t)n ); }

static void next_marker( int fd )   /* the reply stream is still in step */
{
    char got[16];
    assert( read( fd, got, sizeof(got) ) == sizeof(got) && !memcmp( got, "next-reply-12345", 16 ) );
}

int main( void )
{
    char *rx, *rw, *pool_rx, *pool_rw, *ro, buf[300];
    int fds[2], sv[2], i;
    volatile int fatal;
    BOOL fault;

    (void)ios_jit_anon_alias_hiwater; (void)ios_jit_anon_alias_tombstones;
    alarm( 60 );   /* a watchdog: no check may hang */

    for (i = 0; i < (int)sizeof(pattern); i++) pattern[i] = (unsigned char)(i * 7 + 3);
    make_view( &rx, &rw );
    make_view( &pool_rx, &pool_rw );
    ro = mmap( NULL, VIEW, PROT_READ, MAP_PRIVATE | MAP_ANON, -1, 0 );
    assert( ro != MAP_FAILED );
    fake_add( ro, VIEW, VM_PROT_READ );

    /* the old reply read into the read-only view is fatal: the model reproduces the problem */
    new_pipe( fds );
    put( fds[1], pattern, 300 );
    fatal = 0; fatal_armed = 1;
    if (setjmp( fatal_jmp )) fatal = 1;
    else read_reply_data( rx + 0x100, 300 );
    fatal_armed = 0;
    assert( fatal == 1 && fatal_errno == EFAULT );
    puts( "old reply read into the RX view: fatal protocol error (EFAULT)" );

    /* a reply into aliased memory arrives through the alias, across three guest pages */
    alias( 0, rx, VIEW / 2, rw );   /* the second half of the view stays read-only without an alias */
    new_pipe( fds );
    put( fds[1], pattern, 6000 );
    put( fds[1], "next-reply-12345", 16 );
    fault = FALSE; notes = 0;
    assert( ios_read_reply_guest( rx + 0xf00, 6000, 42, &fault ) && !fault );
    assert( !memcmp( rx + 0xf00, pattern, 6000 ) && notes == 3 );
    next_marker( fds[0] );

    /* the pool's own RX range takes the same path */
    ios_jit_rx_base_global = pool_rx; ios_jit_rw_base_global = pool_rw; ios_jit_pool_size_global = VIEW;
    put( fds[1], pattern + 1, 2000 );
    put( fds[1], "next-reply-12345", 16 );
    fault = FALSE;
    assert( ios_read_reply_guest( pool_rx + 0x800, 2000, 43, &fault ) && !fault );
    assert( !memcmp( pool_rx + 0x800, pattern + 1, 2000 ) );
    next_marker( fds[0] );

    /* ordinary memory keeps the single read() */
    put( fds[1], pattern + 2, sizeof(buf) );
    fault = FALSE; notes = 0;
    assert( ios_read_reply_guest( buf, sizeof(buf), 44, &fault ) && !fault && !notes );
    assert( !memcmp( buf, pattern + 2, sizeof(buf) ) );

    /* neither aliased nor writable: the reply is drained, the call reports a fault, the next reply is intact */
    put( fds[1], pattern, 5000 );
    put( fds[1], "next-reply-12345", 16 );
    fault = FALSE;
    fatal = 0; fatal_armed = 1;
    if (setjmp( fatal_jmp )) fatal = 1;
    else assert( ios_read_reply_guest( ro + 0x10, 5000, 45, &fault ) );
    fatal_armed = 0;
    assert( !fatal && fault );
    next_marker( fds[0] );

    /* aliased pages first, then the unaliased read-only half: the aliased part arrives, the call reports a fault */
    memset( rw + VIEW / 2 - 0x800, 0, 0x800 );
    put( fds[1], pattern, 0x1000 );
    put( fds[1], "next-reply-12345", 16 );
    fault = FALSE;
    assert( ios_read_reply_guest( rx + VIEW / 2 - 0x800, 0x1000, 46, &fault ) && fault );
    assert( !memcmp( rx + VIEW / 2 - 0x800, pattern, 0x800 ) );
    next_marker( fds[0] );
    puts( "replies: through the alias and the pool alias, ordinary memory unchanged, faults drained in step" );

    /* read(): without the alias the call fails as before and consumes nothing; with it the data arrives */
    put( fds[1], pattern + 5, 5000 );
    ios_jit_anon_alias_count = 0;
    errno = 0;
    assert( virtual_locked_read( fds[0], rx + 0x1f00, 5000 ) == -1 && errno == EFAULT );
    ios_jit_anon_alias_count = 1;
    assert( virtual_locked_read( fds[0], rx + 0x1f00, 5000 ) == 5000 );
    assert( !memcmp( rx + 0x1f00, pattern + 5, 5000 ) );

    /* a destination with an unwritable page fails with EFAULT before reading: the data is still there */
    put( fds[1], pattern + 6, 0x1000 );
    errno = 0;
    assert( virtual_locked_read( fds[0], rx + VIEW / 2 - 0x800, 0x1000 ) == -1 && errno == EFAULT );
    assert( virtual_locked_read( fds[0], buf, 256 ) == 256 && !memcmp( buf, pattern + 6, 256 ) );
    {
        static char rest[0x1000];
        assert( read( fds[0], rest, 0x1000 - 256 ) == 0x1000 - 256 );
    }

    /* pread() into the pool alias, from an offset, up to a short read at the end of the file */
    {
        FILE *f = tmpfile();
        int fd;
        assert( f && fwrite( pattern, 1, 9000, f ) == 9000 && !fflush( f ) );
        fd = fileno( f );
        assert( virtual_locked_pread( fd, pool_rx + 0x3000, 3000, 100 ) == 3000 );
        assert( !memcmp( pool_rx + 0x3000, pattern + 100, 3000 ) );
        assert( virtual_locked_pread( fd, pool_rx + 0x5000, 4000, 7000 ) == 2000 );
        assert( !memcmp( pool_rx + 0x5000, pattern + 7000, 2000 ) );
        fclose( f );
    }

    /* recvmsg(): one ordinary iovec and one aliased iovec */
    {
        struct iovec iov[2];
        struct msghdr hdr;

        assert( !socketpair( AF_UNIX, SOCK_STREAM, 0, sv ) );
        put( sv[1], pattern + 9, 300 );
        memset( &hdr, 0, sizeof(hdr) );
        iov[0].iov_base = buf; iov[0].iov_len = 100;
        iov[1].iov_base = rx + 0x3ff0; iov[1].iov_len = 200;   /* crosses a guest page */
        hdr.msg_iov = iov; hdr.msg_iovlen = 2;
        assert( virtual_locked_recvmsg( sv[0], &hdr, 0 ) == 300 );
        assert( !memcmp( buf, pattern + 9, 100 ) && !memcmp( rx + 0x3ff0, pattern + 109, 200 ) );
        close( sv[0] ); close( sv[1] );
    }
    puts( "read, pread, recvmsg: through the alias; an unwritable destination fails before reading" );

    /* releasing a range retires the aliases that start inside it, and only those */
    memset( ios_jit_anon_aliases, 0, sizeof(ios_jit_anon_aliases) );
    ios_jit_anon_alias_count = 0; ios_jit_anon_alias_live = 0;
    alias( 0, (char *)0x7000010000ull, 0x10000, (char *)0x7100010000ull );
    alias( 1, (char *)0x7000020000ull, 0x10000, (char *)0x7100020000ull );
    alias( 2, (char *)0x7000030000ull, 0x10000, (char *)0x7100030000ull );
    alias( 3, (char *)0x7000048000ull, 0x10000, (char *)0x7100048000ull );   /* starts before the next range */
    {
        void *rwp, *rxp;
        assert( ios_jit_anon_alias_find_cover( (void *)0x7000020000ull, 0x4000, &rwp, &rxp ) );
        ios_jit_anon_alias_retire_range( (void *)0x7000020000ull, 0x10000 );
        assert( mono_retired == 1 && last_mono_retired == 0x7000020000ull && ios_jit_anon_alias_live == 3 );
        assert( !ios_jit_anon_alias_lookup( 0x7000020008ull ) );
        assert( !ios_jit_anon_alias_find_cover( (void *)0x7000020000ull, 0x4000, &rwp, &rxp ) );
        assert( ios_jit_anon_alias_lookup( 0x700001fff8ull ) == 0x710001fff8ull );
        assert( ios_jit_anon_alias_lookup( 0x7000030000ull ) == 0x7100030000ull );
    }
    ios_jit_anon_alias_retire_range( (void *)0x7000050000ull, 0x10000 );   /* alias 3 starts below: kept */
    assert( mono_retired == 1 && ios_jit_anon_alias_lookup( 0x7000050000ull ) == 0x7100050000ull );
    ios_jit_anon_alias_retire_range( (void *)0x7000010000ull, 0x30000 );
    assert( mono_retired == 3 && ios_jit_anon_alias_live == 1 );
    assert( !ios_jit_anon_alias_lookup( 0x7000010000ull ) && !ios_jit_anon_alias_lookup( 0x7000030000ull ) );
    puts( "release: the aliases that start inside the range are retired, the others stay" );
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-rwx-kernel-writes-') as directory:
    folder = Path(directory)
    src = folder / 'check.c'
    src.write_text(code)
    exe = folder / 'check'
    cc = os.environ.get('CC', 'cc')
    flags = [cc, '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-Wno-unused-parameter',
             '-Wno-sign-compare', '-g', '-pthread', str(src), '-o', str(exe)]
    sanitize = ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    if subprocess.run(flags[:1] + sanitize + flags[1:], capture_output=True).returncode == 0:
        print('built with AddressSanitizer/UBSan')
    else:
        r = subprocess.run(flags, capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        print('built without sanitizers')
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    print(r.stdout.strip())
    # The path each reply took: aliased destinations are routed up front, not after a failed read().
    for line in ['[reply-alias] tid=1234 req=42 ', '[reply-alias] tid=1234 req=43 ', '[reply-alias] tid=1234 req=46 ',
                 '[reply-efault] tid=1234 req=45 ', '[kw-alias] read ', '[kw-alias] pread ', '[kw-alias] recvmsg ',
                 '[jit-alias] guest free of ']:
        assert line in r.stderr, (line, r.stderr)
    for line in ['[reply-efault] tid=1234 req=42 ', '[reply-efault] tid=1234 req=43 ', 'req=44 ']:
        assert line not in r.stderr, (line, r.stderr)
print('PASS: kernel writes into anonymous RWX memory go through its RW alias; released ranges retire their aliases')
