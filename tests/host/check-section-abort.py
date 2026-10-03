#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""A thread killed inside an uninterrupted section leaves it first (build/ntdll-unix/server_ios.c).

On iOS the server cannot signal a thread it kills, so the thread runs on until a request
finds its pipes closed. When that request was inside server_enter_uninterrupted_section
(NtClose, NtDuplicateObject and server_get_unix_fd hold fd_cache_mutex around theirs) the
thread exited holding the mutex, and every later NtClose in every process hung. Now the
request fails with STATUS_THREAD_IS_TERMINATING and the thread exits when it leaves its
outermost section.

Compiles the production helper block, send_request, read_reply_data, wait_reply,
server_call_unlocked and the section enter/leave pair, taken verbatim from server_ios.c
(the diagnostic x18 read is replaced so it builds on any host), with minimal stand-ins for
the thread data and abort_thread, under AddressSanitizer and UBSan, and checks on real
pipes and mutexes:
  * a live server: the reply's status comes back, inside or outside a section;
  * killed inside a section (closed request pipe: EPIPE; or closed reply pipe: EOF): the
    request fails with STATUS_THREAD_IS_TERMINATING, a second request fails without
    writing anything, the thread exits exactly once, when it leaves the section, and the
    mutex is free afterwards;
  * nested sections: the exit waits for the outermost one, both mutexes are free;
  * killed outside a section: the thread exits at the request, as before;
  * sections and requests on the exit path neither write nor exit a second time;
  * MADEIRA_DEFER_SECTION_ABORT=0: the thread exits inside the section and the mutex stays
    locked, the old hang this change removes;
  * the pthread key exists before main, and the log stops after 16 lines.
Synthetic pipes only: no Wine, iOS or device.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/server_ios.c').read_text().replace('\r\n', '\n')
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


start = src.index('#ifdef WINE_IOS\n/* A thread killed inside an uninterrupted section')
helpers = src[start:src.index('#endif\n', start) + len('#endif\n')]
send_request = function('static unsigned int send_request( const struct __server_request_info *req )')
read_reply = function('static BOOL read_reply_data( void *buffer, size_t size )')
wait_reply = function('static inline unsigned int wait_reply( struct __server_request_info *req )')
call_unlocked = function('unsigned int server_call_unlocked( void *req_ptr )')
enter = function('void server_enter_uninterrupted_section( pthread_mutex_t *mutex, sigset_t *sigset )')
leave = function('void server_leave_uninterrupted_section( pthread_mutex_t *mutex, sigset_t *sigset )')

# ------------------------------------------------------------------ static
# ml1183 adds a third: wine_server_receive_fd's dead fd socket, read inside the
# fd_cache_mutex section of server_get_unix_fd.
require(src.count('ios_defer_section_abort()') == 3, 'three deferral points: the EPIPE write, the EOF read and the fd read')
receive_fd = function('int wine_server_receive_fd( obj_handle_t *handle )')
require('if (ios_defer_section_abort()) return -1;' in receive_fd
        and receive_fd.index('ios_defer_section_abort()') < receive_fd.rindex('abort_thread(0)'),
        'ml1183: a dead fd socket inside a section fails the read before abort_thread')
require('if (ios_defer_section_abort()) return STATUS_THREAD_IS_TERMINATING;\n#endif\n        abort_thread(0);' in send_request,
        'send_request: EPIPE outside a section still exits at once')
require('if (ios_defer_section_abort()) return FALSE;\n#endif\n    /* the server closed the connection; time to die... */\n    abort_thread(0);' in read_reply,
        'read_reply_data: EOF outside a section still exits at once')
require(call_unlocked.index('IOS_SECTION_ABORT') < call_unlocked.index('send_request( req )'),
        'server_call_unlocked: a killed thread sends nothing more')
require(leave.index('mutex_unlock( mutex );') < leave.index('pthread_sigmask( SIG_SETMASK, sigset, NULL );') < leave.index('abort_thread( 0 );'),
        'leave: unlock, restore the mask, then exit (where Linux delivers SIGQUIT)')
require(src.count('server_enter_uninterrupted_section( &fd_cache_mutex') == 4 ==
        src.count('server_leave_uninterrupted_section( &fd_cache_mutex'),
        'the four fd_cache_mutex sections themselves are unchanged')
require('wait_select_reply' not in helpers and src.count('if (!reply.cookie) abort_thread( reply.signaled );') == 1,
        'a thread woken as killed in a server wait still exits at once')
log_line = helpers[helpers.index('dprintf( 2, "[section-abort]'):helpers.index(');', helpers.index('dprintf( 2, "[section-abort]'))]
require('%s' not in log_line, 'the log line prints numbers only')
require('_Thread_local' not in helpers.split('*/', 1)[1], 'no thread-local variable (first touch allocates on Darwin)')

x18 = '__asm__ volatile("mov %0, x18" : "=r"(x18_val));'
require(read_reply.count(x18) == 1, 'the x18 diagnostic read is the only host-specific line replaced')
read_reply = read_reply.replace(x18, 'x18_val = 0;')

harness = r'''
#define WINE_IOS 1
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>

typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define DECLSPEC_NORETURN __attribute__((noreturn))
#define STATUS_SUCCESS                0x00000000
#define STATUS_ACCESS_VIOLATION       0xC0000005
#define STATUS_THREAD_IS_TERMINATING  0xC000004B
typedef unsigned int data_size_t;
struct request_header { int req; data_size_t request_size; data_size_t reply_size; };
struct reply_header { unsigned int error; data_size_t reply_size; };
union generic_request { struct request_header request_header; char pad[64]; };
union generic_reply { struct reply_header reply_header; char pad[64]; };
struct __server_iovec { const void *ptr; data_size_t size; };
#define __SERVER_MAX_DATA 5
struct __server_request_info
{
    union { union generic_request req; union generic_reply reply; } u;
    unsigned int data_count;
    void *reply_data;
    struct __server_iovec data[__SERVER_MAX_DATA];
};

struct thread_data { int request_fd, reply_fd; };
static __thread struct thread_data tdata;
static struct thread_data *ntdll_get_thread_data(void) { return &tdata; }
static void *NtCurrentTeb(void) { return &tdata; }
static int fd_socket = -1;
static unsigned int GetCurrentThreadId(void) { return 0x42; }
static sigset_t server_block_set;
static void mutex_lock( pthread_mutex_t *m ) { pthread_mutex_lock( m ); }
static void mutex_unlock( pthread_mutex_t *m ) { pthread_mutex_unlock( m ); }
static void ios_fdt_autopsy( const char *what, int fd, int ret, int err ) { (void)what; (void)fd; (void)ret; (void)err; }
volatile int ios_srv_req_count;
void ios_wineserver_wake(void) {}
static DECLSPEC_NORETURN void server_protocol_perror( const char *err ) { perror( err ); abort(); }
void server_enter_uninterrupted_section( pthread_mutex_t *mutex, sigset_t *sigset );
void server_leave_uninterrupted_section( pthread_mutex_t *mutex, sigset_t *sigset );
unsigned int server_call_unlocked( void *req_ptr );

static int abort_calls, abort_status = -1, exit_path_mode;
static unsigned int exit_path_result;
static pthread_mutex_t exit_mutex = PTHREAD_MUTEX_INITIALIZER;
static int exit_probe_fd[2];
DECLSPEC_NORETURN void abort_thread( int status );
'''

harness_main = r'''
DECLSPEC_NORETURN void abort_thread( int status )
{
    __sync_fetch_and_add( &abort_calls, 1 );
    abort_status = status;
    if (exit_path_mode)   /* teardown work that takes a section and asks the server */
    {
        struct __server_request_info req;
        sigset_t ss;
        memset( &req, 0, sizeof(req) );
        tdata.request_fd = exit_probe_fd[1];
        server_enter_uninterrupted_section( &exit_mutex, &ss );
        exit_path_result = server_call_unlocked( &req );
        server_leave_uninterrupted_section( &exit_mutex, &ss );
    }
    pthread_exit( NULL );
}

enum kill_kind { ALIVE, KILLED_EPIPE, KILLED_EOF };
struct scenario
{
    enum kill_kind kill;
    int sections;          /* 0, 1 or 2 */
    pthread_mutex_t m1, m2;
    int req[2], rep[2], healthy[2];
    unsigned int r1, r2;
    int after_call, after_inner_leave, reached_end;
};

static void setup( struct scenario *s, enum kill_kind kill, int sections )
{
    memset( s, 0, sizeof(*s) );
    s->kill = kill; s->sections = sections;
    pthread_mutex_init( &s->m1, NULL ); pthread_mutex_init( &s->m2, NULL );
    if (pipe( s->req ) || pipe( s->rep ) || pipe( s->healthy )) abort();
    fcntl( s->healthy[0], F_SETFL, O_NONBLOCK );
    if (kill == ALIVE)
    {
        union generic_reply reply;
        memset( &reply, 0, sizeof(reply) );
        reply.reply_header.error = 0x1234;
        if (write( s->rep[1], &reply, sizeof(reply) ) != sizeof(reply)) abort();
        if (write( s->rep[1], &reply, sizeof(reply) ) != sizeof(reply)) abort();
    }
    if (kill == KILLED_EPIPE) { close( s->req[0] ); s->req[0] = -1; }
    if (kill != ALIVE) { close( s->rep[1] ); s->rep[1] = -1; }
}

static void *worker( void *arg )
{
    struct scenario *s = arg;
    struct __server_request_info req;
    sigset_t ss1, ss2;

    memset( &req, 0, sizeof(req) );
    tdata.request_fd = s->req[1];
    tdata.reply_fd = s->rep[0];
    if (s->sections >= 1) server_enter_uninterrupted_section( &s->m1, &ss1 );
    if (s->sections >= 2) server_enter_uninterrupted_section( &s->m2, &ss2 );
    s->r1 = server_call_unlocked( &req );
    s->after_call = 1;
    if (s->kill != ALIVE) tdata.request_fd = s->healthy[1];  /* would a second request write? */
    s->r2 = server_call_unlocked( &req );
    if (s->sections >= 2) server_leave_uninterrupted_section( &s->m2, &ss2 );
    s->after_inner_leave = 1;
    if (s->sections >= 1) server_leave_uninterrupted_section( &s->m1, &ss1 );
    s->reached_end = 1;
    return NULL;
}

static int run( struct scenario *s )
{
    pthread_t t;
    int before = abort_calls;
    pthread_create( &t, NULL, worker, s );
    pthread_join( t, NULL );
    return abort_calls - before;
}

static int check( int ok, const char *label ) { printf( "%s: %s\n", ok ? "PASS" : "FAIL", label ); return !ok; }
static int is_free( pthread_mutex_t *m ) { if (pthread_mutex_trylock( m )) return 0; pthread_mutex_unlock( m ); return 1; }
static int nothing_written( int fd ) { char c; return read( fd, &c, 1 ) == -1 && errno == EAGAIN; }

int main( int argc, char **argv )
{
    struct scenario s;
    int bad = 0, i, exits;

    signal( SIGPIPE, SIG_IGN );
    sigemptyset( &server_block_set );
    sigaddset( &server_block_set, SIGQUIT );
    bad |= check( ios_section_key_ready == 1, "the pthread key exists before main" );

    if (argc > 1 && !strcmp( argv[1], "off" ))
    {
        setup( &s, KILLED_EPIPE, 1 );
        exits = run( &s );
        bad |= check( exits == 1 && !s.after_call, "switched off: the thread exits at the request, inside the section" );
        bad |= check( !is_free( &s.m1 ), "switched off: the mutex stays locked (the old hang)" );
        return bad;
    }

    for (i = 0; i <= 1; i++)
    {
        setup( &s, ALIVE, i );
        exits = run( &s );
        bad |= check( !exits && s.r1 == 0x1234 && s.r2 == 0x1234 && s.reached_end,
                      i ? "live server inside a section: the reply's status, no exit" : "live server outside a section: the reply's status, no exit" );
    }

    setup( &s, KILLED_EPIPE, 1 );
    exits = run( &s );
    bad |= check( s.r1 == STATUS_THREAD_IS_TERMINATING && s.after_call, "killed inside a section (EPIPE): the request fails, the thread goes on" );
    bad |= check( s.r2 == STATUS_THREAD_IS_TERMINATING && nothing_written( s.healthy[0] ), "a second request fails without writing" );
    bad |= check( exits == 1 && abort_status == 0 && s.after_inner_leave && !s.reached_end, "the thread exits once, when it leaves the section" );
    bad |= check( is_free( &s.m1 ), "the mutex is free afterwards" );

    setup( &s, KILLED_EOF, 1 );
    exits = run( &s );
    bad |= check( s.r1 == STATUS_THREAD_IS_TERMINATING && s.r2 == STATUS_THREAD_IS_TERMINATING && nothing_written( s.healthy[0] ),
                  "killed inside a section (reply EOF): both requests fail, nothing more written" );
    bad |= check( exits == 1 && !s.reached_end && is_free( &s.m1 ), "reply EOF: one exit on leaving, mutex free" );

    setup( &s, KILLED_EPIPE, 2 );
    exits = run( &s );
    bad |= check( s.after_inner_leave && !s.reached_end && exits == 1, "nested: the exit waits for the outermost section" );
    bad |= check( is_free( &s.m1 ) && is_free( &s.m2 ), "nested: both mutexes are free" );

    setup( &s, KILLED_EPIPE, 0 );
    exits = run( &s );
    bad |= check( exits == 1 && !s.after_call, "killed outside a section: the thread exits at the request, as before" );

    setup( &s, KILLED_EOF, 0 );
    exits = run( &s );
    bad |= check( exits == 1 && !s.after_call, "reply EOF outside a section: exits at the request, as before" );

    if (pipe( exit_probe_fd )) abort();
    fcntl( exit_probe_fd[0], F_SETFL, O_NONBLOCK );
    exit_path_mode = 1;
    setup( &s, KILLED_EPIPE, 1 );
    exits = run( &s );
    exit_path_mode = 0;
    bad |= check( exits == 1 && exit_path_result == STATUS_THREAD_IS_TERMINATING && nothing_written( exit_probe_fd[0] ),
                  "exit path: a section and a request neither write nor exit again" );
    bad |= check( is_free( &exit_mutex ) && is_free( &s.m1 ), "exit path: its mutex is free too" );

    for (i = 0; i < 20; i++) { setup( &s, KILLED_EPIPE, 1 ); run( &s ); }
    bad |= check( is_free( &s.m1 ), "twenty more killed threads: still no mutex left locked" );
    return bad;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp) / 'section_abort.c'
    exe = Path(tmp) / 'section_abort'
    c.write_text(harness + helpers + send_request + read_reply + wait_reply + call_unlocked + enter + leave + harness_main)
    build = subprocess.run([CC, '-std=gnu11', '-g', '-O1', '-Wall', '-Wno-unused-function', '-Werror=implicit-function-declaration',
                            '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined', '-pthread', str(c), '-o', str(exe)],
                           capture_output=True, text=True)
    require(build.returncode == 0, 'harness compiles (ASan + UBSan)')
    if build.returncode:
        print(build.stderr[-4000:])
    else:
        env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0')
        env.pop('MADEIRA_DEFER_SECTION_ABORT', None)
        on = subprocess.run([str(exe)], capture_output=True, text=True, env=env, timeout=120)
        print(on.stdout, end='')
        require(on.returncode == 0, 'default run: every check passed, no sanitizer report')
        if on.returncode:
            print(on.stderr[-4000:])
        lines = [l for l in on.stderr.splitlines() if l.startswith('[section-abort]')]
        require(len(lines) == 16, f'the log stops after 16 lines (got {len(lines)} of 24 deferrals)')
        require(all('tid=0042 killed inside 1 uninterrupted section(s)' in l or 'inside 2 ' in l for l in lines),
                'log lines carry the thread id and depth only')
        off = subprocess.run([str(exe), 'off'], capture_output=True, text=True,
                             env=dict(env, MADEIRA_DEFER_SECTION_ABORT='0'), timeout=120)
        print(off.stdout, end='')
        require(off.returncode == 0 and '[section-abort]' not in off.stderr, 'MADEIRA_DEFER_SECTION_ABORT=0 restores the immediate exit')

print('PASS' if not failures else f'FAILED ({failures})')
sys.exit(1 if failures else 0)
