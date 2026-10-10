#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""The poll loop's INET cache forgets a slot when it is reused (build/wineserver/fd_ios.c).

The iOS poll loop gives INET sockets a real poll() and synthesises events for every other
fd, including an unconditional POLLOUT. ios_fd_is_inet cached that verdict per (poll user
slot, fd number) and nothing cleared it when add_poll_user/remove_poll_user recycled a
slot. The slot freelist is LIFO and unix fds are allocated lowest-first, so a socket
created right after a thread exits can get that thread's request-fifo slot and fd number;
the stale "not INET" verdict then reported its nonblocking connect complete while it was
still connecting, and the next send failed with ENOTCONN. Both functions now forget the
slot's entry. If the cache cannot grow, the fd is classified uncached instead of being
called "not INET", and each grown array is kept as soon as its realloc succeeds.

Compiles the poll-user arrays, add_poll_user, remove_poll_user and the INET cache verbatim
from fd_ios.c, with stand-ins for the epoll hooks and the log, under AddressSanitizer and
UBSan, and checks on real pipes and sockets:
  * a TCP socket that gets a closed pipe's slot and fd number is classified INET, and a
    pipe that gets a closed socket's is not;
  * UDP and IPv6 sockets are INET, an AF_UNIX socketpair is not;
  * the cache still caches: one getsockname per (slot, fd), again after the slot is reused;
  * when either realloc fails, sockets and pipes are still classified right, and the cache
    is intact afterwards (no stale array pointer).
Local pipes and unconnected sockets only: no Wine, iOS, device or network traffic.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/wineserver/fd_ios.c').read_text().replace('\r\n', '\n')
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


def lines(first, last):
    start = src.index(first)
    return src[start:src.index('\n', src.index(last, start)) + 1]


poll_arrays = lines('static struct fd **poll_users;', 'static struct fd **freelist;')
cache = lines('static int *ios_inet_cache_fd;', 'static int ios_inet_cache_size;')
forget = function('static void ios_fd_inet_forget( int user )')
family = function('static signed char ios_fd_family_is_inet( int fd )')
add = function('static int add_poll_user( struct fd *fd )')
remove = function('static void remove_poll_user( struct fd *fd, int user )')
is_inet = function('static signed char ios_fd_is_inet( int user, int fd )')

# ------------------------------------------------------------------ static
require('ios_fd_inet_forget( ret );' in add and add.index('ios_fd_inet_forget( ret );') > add.index('ret = nb_users++;'),
        'add_poll_user forgets the slot it hands out, from the freelist or new')
require('ios_fd_inet_forget( user );' in remove, 'remove_poll_user forgets the slot it frees')
require('static int *cache_fd;' not in is_inet and 'return 0;' not in is_inet,
        'ios_fd_is_inet keeps no private cache and never answers "not INET" without asking')
require(src.count('ios_fd_is_inet( i, pollfd[i].fd )') == 2, 'the poll loop still asks it for both passes')

harness = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <unistd.h>

struct fd { int unix_fd; };
static void init_epoll( void ) { }
static void remove_epoll_user( struct fd *fd, int user ) { }
#define ws_log(...) ((void)0)

static int realloc_calls, realloc_fail_mask;      /* bit n: the n-th realloc from now fails */
static void *test_realloc( void *p, size_t n )
{
    int k = realloc_calls++;
    if (k < 31 && ((realloc_fail_mask >> k) & 1)) return NULL;
    return realloc( p, n );
}
#define realloc test_realloc

static int getsockname_calls;
static int test_getsockname( int fd, struct sockaddr *sa, socklen_t *len )
{
    getsockname_calls++;
    return getsockname( fd, sa, len );
}
#define getsockname test_getsockname
'''

harness_main = r'''
static int check( int ok, const char *label ) { printf( "%s: %s\n", ok ? "PASS" : "FAIL", label ); return !ok; }

/* as set_fd_events would: the slot polls the fd */
static int add( struct fd *fd )
{
    int user = add_poll_user( fd );
    if (user >= 0) { pollfd[user].fd = fd->unix_fd; pollfd[user].events = POLLIN | POLLOUT; }
    return user;
}

/* the fd number `want`, now holding `fd` (socket() and pipe() take the lowest free number;
 * force it if something else got there first) */
static int on_number( int fd, int want )
{
    if (fd == want || fd < 0) return fd;
    if (dup2( fd, want ) != want) return -1;
    close( fd );
    return want;
}

int main( void )
{
    struct fd spacer[3], a, b, c, d;
    int bad = 0, i, p[2], q[2], sv[2], s, s6, u_a, u_b, n, big, first;

    /* a few busy slots first, like the server's own fds */
    for (i = 0; i < 3; i++) { spacer[i].unix_fd = dup( 2 ); add( &spacer[i] ); }

    /* a pipe in a slot, classified, then freed (a thread's request fifo, closed at its exit) */
    if (pipe( p )) return 2;
    a.unix_fd = p[0];
    u_a = add( &a );
    bad |= check( ios_fd_is_inet( u_a, p[0] ) == 0, "a pipe is not INET" );
    remove_poll_user( &a, u_a );
    close( p[0] ); close( p[1] );

    /* a TCP socket created next: same fd number, and the LIFO freelist hands out the same slot */
    s = on_number( socket( AF_INET, SOCK_STREAM, 0 ), p[0] );
    b.unix_fd = s;
    u_b = add( &b );
    bad |= check( s == p[0] && u_b == u_a, "the socket got the pipe's poll slot (LIFO freelist) and fd number" );
    bad |= check( ios_fd_is_inet( u_b, s ) == 1, "the socket on the reused slot and fd is INET (real poll, no synthesised POLLOUT)" );

    /* the cache still caches */
    getsockname_calls = 0;
    for (i = 0; i < 1000; i++) ios_fd_is_inet( u_b, s );
    bad |= check( getsockname_calls == 0, "1000 more polls of the same slot and fd: no getsockname" );

    /* the other direction: a pipe on the socket's slot and fd number */
    remove_poll_user( &b, u_b );
    close( s );
    if (pipe( q )) return 2;
    q[0] = on_number( q[0], s );
    c.unix_fd = q[0];
    n = add( &c );
    getsockname_calls = 0;
    bad |= check( n == u_b && q[0] == s && ios_fd_is_inet( n, q[0] ) == 0 && getsockname_calls == 1,
                  "a pipe on a socket's reused slot and fd is not INET (asked once)" );
    remove_poll_user( &c, n );
    close( q[0] ); close( q[1] );

    s = socket( AF_INET, SOCK_DGRAM, 0 );
    d.unix_fd = s;
    n = add( &d );
    bad |= check( ios_fd_is_inet( n, s ) == 1, "a UDP socket is INET" );
    remove_poll_user( &d, n );
    close( s );

    if ((s6 = socket( AF_INET6, SOCK_STREAM, 0 )) >= 0)
    {
        d.unix_fd = s6;
        n = add( &d );
        bad |= check( ios_fd_is_inet( n, s6 ) == 1, "an IPv6 socket is INET" );
        remove_poll_user( &d, n );
        close( s6 );
    }
    else printf( "SKIP: no IPv6 sockets here\n" );

    if (socketpair( AF_UNIX, SOCK_STREAM, 0, sv )) return 2;
    d.unix_fd = sv[0];
    n = add( &d );
    bad |= check( ios_fd_is_inet( n, sv[0] ) == 0, "an AF_UNIX socketpair is not INET (keeps the synthesised events)" );

    /* the cache cannot grow: the fd array's realloc fails, then the verdict array's */
    s = socket( AF_INET, SOCK_STREAM, 0 );
    if (pipe( q )) return 2;
    big = ios_inet_cache_size + 100;
    first = ios_inet_cache_size;
    realloc_calls = 0; realloc_fail_mask = 3;   /* the fd array's realloc, in both calls */
    bad |= check( ios_fd_is_inet( big, s ) == 1 && ios_fd_is_inet( big, q[0] ) == 0 && ios_inet_cache_size == first,
                  "first realloc fails: a socket is still INET and a pipe still not, uncached" );
    realloc_calls = 0; realloc_fail_mask = 2;   /* the fd array grows, the verdict array's realloc fails */
    bad |= check( ios_fd_is_inet( big, s ) == 1 && ios_inet_cache_size == first,
                  "second realloc fails: the socket is still INET, uncached" );
    realloc_fail_mask = 0;
    getsockname_calls = 0;
    bad |= check( ios_fd_is_inet( n, sv[0] ) == 0 && getsockname_calls == 0,
                  "after the failures the cache is intact: the earlier entry still answers from the cache" );
    bad |= check( ios_fd_is_inet( big, s ) == 1 && ios_inet_cache_size > big && ios_fd_is_inet( big, s ) == 1
                  && getsockname_calls == 1, "with memory again the cache grows and caches the socket" );
    remove_poll_user( &d, n );
    close( sv[0] ); close( sv[1] ); close( s ); close( q[0] ); close( q[1] );
    return bad;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp) / 'inet_poll_cache.c'
    exe = Path(tmp) / 'inet_poll_cache'
    c.write_text(harness + poll_arrays + cache + forget + family + add + remove + is_inet + harness_main)
    build = subprocess.run([CC, '-std=gnu11', '-g', '-O1', '-Wall', '-Wno-unused-function', '-Wno-unused-variable',
                            '-Werror=implicit-function-declaration',
                            '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined', str(c), '-o', str(exe)],
                           capture_output=True, text=True)
    require(build.returncode == 0, 'harness compiles (ASan + UBSan)')
    if build.returncode:
        print(build.stderr[-4000:])
    else:
        run = subprocess.run([str(exe)], capture_output=True, text=True,
                             env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'), timeout=120)
        print(run.stdout, end='')
        require(run.returncode == 0, 'every case passed, no sanitizer report')
        if run.returncode:
            print(run.stderr[-4000:])

print('PASS' if not failures else f'FAILED ({failures})')
sys.exit(1 if failures else 0)
