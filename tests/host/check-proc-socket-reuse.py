#!/usr/bin/env python3
"""A child process's master-socket slot is reused once the child has exited
(build/ntdll-unix/server_ios.c); no Wine runs.

ios_register_proc_socket() used to take a new index for every child and never give one back, so the
65th child a launch ever started had no master socket (the wineserver then never saw it die), however
few were alive. Compiles the production slot table, ios_proc_socket_index and
ios_register_proc_socket, and checks:
  - 500 children started one after another, each exiting (PEB cleared, as process_exit_wrapper does)
    before the next, all get a slot, and each is found by its PEB;
  - 64 live children fill the table, the 65th is refused (and logged) without touching the others, and
    a slot freed afterwards is taken by the next one;
  - 8 threads registering 8 children each at once get 64 different slots;
  - the high-water mark never passes the table's size, and a reader never finds a slot by the
    claim marker.
Needs python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
server = (root / 'build/ntdll-unix/server_ios.c').read_text()
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]


start = server.index('#define IOS_MAX_PROC_SOCKETS')
table = server[start:server.index('\n}\n', server.index('BOOL *ios_process_exiting_ptr(void)')) + 3]
claim = server.index('#define IOS_PROC_SLOT_CLAIMED')
register = server[claim:server.index('\n}\n', server.index('static void ios_register_proc_socket(void *peb_id, int fd)')) + 3]
exit_path = function(server, 'void process_exit_wrapper( int status )')

require('ios_proc_sockets[i].peb = NULL;' in exit_path and exit_path.index('close( ios_proc_sockets[i].fd );') <
        exit_path.index('ios_proc_sockets[i].peb = NULL;'),
        'an exiting child closes its fd before it frees its slot')
require('__sync_fetch_and_add(&ios_proc_socket_count' not in server, 'no index is handed out without being taken back')

harness = r'''
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
typedef uintptr_t ULONG_PTR;
typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define FDT_MASTER 1
static int fd_socket = 3;
static __thread void *cur_peb;
void *ios_jit_current_peb(void) { return cur_peb; }
static void ios_fdt_reg( int fd, int kind, void *peb ) { (void)fd; (void)kind; (void)peb; }
static int full_logs;
static void wine_log_write( const char *format, ... ) { if (strstr( format, "table FULL" )) full_logs++; }
'''

main = r'''
static int bad;
static void check( int ok, const char *label ) { printf( "%s: %s\n", ok ? "PASS" : "FAIL", label ); bad |= !ok; }
#define PEB(n) ((void *)(uintptr_t)(0x100000 + (n) * 0x1000))
static int slot_of( void *peb ) { cur_peb = peb; return ios_proc_socket_index(); }
static void exit_child( void *peb ) { int i = slot_of( peb ); if (i >= 0) ios_proc_sockets[i].peb = NULL; }

static void *batch( void *arg )
{
    int base = (int)(intptr_t)arg, i;
    for (i = 0; i < 8; i++) ios_register_proc_socket( PEB( base + i ), 100 + base + i );
    return NULL;
}

int main( void )
{
    int i, ok = 1, n;
    (void)ios_dead_peb_next;

    for (i = 0; i < 500; i++)
    {
        ios_register_proc_socket( PEB( i ), 10 + i );
        if (slot_of( PEB( i ) ) < 0 || ios_proc_sockets[slot_of( PEB( i ) )].fd != 10 + i) ok = 0;
        exit_child( PEB( i ) );
    }
    check( ok, "500 children, one after another, each get a slot and are found by their PEB" );
    check( ios_proc_socket_count <= IOS_MAX_PROC_SOCKETS && ios_proc_socket_count == 1, "the high-water mark stays small when one child lives at a time" );
    check( full_logs == 0, "no 'table FULL' while at most one child lived" );

    for (i = 0; i < IOS_MAX_PROC_SOCKETS; i++) ios_register_proc_socket( PEB( 1000 + i ), 200 + i );
    ok = 1;
    for (i = 0; i < IOS_MAX_PROC_SOCKETS; i++) if (slot_of( PEB( 1000 + i ) ) < 0) ok = 0;
    check( ok, "64 live children fill the table and every one is found" );
    ios_register_proc_socket( PEB( 2000 ), 999 );
    check( slot_of( PEB( 2000 ) ) < 0 && full_logs == 1, "the 65th live child is refused and logged" );
    ok = 1;
    for (i = 0; i < IOS_MAX_PROC_SOCKETS; i++) if (slot_of( PEB( 1000 + i ) ) < 0 || ios_proc_sockets[slot_of( PEB( 1000 + i ) )].fd != 200 + i) ok = 0;
    check( ok, "refusing one leaves the live children as they were" );
    check( ios_proc_socket_count == IOS_MAX_PROC_SOCKETS, "the high-water mark never passes the table size" );
    exit_child( PEB( 1010 ) );
    ios_register_proc_socket( PEB( 2001 ), 998 );
    check( slot_of( PEB( 2001 ) ) >= 0 && slot_of( PEB( 1010 ) ) < 0, "a freed slot is taken by the next child" );
    check( slot_of( IOS_PROC_SLOT_CLAIMED ) < 0, "the claim marker is never found as a PEB" );

    for (i = 0; i < IOS_MAX_PROC_SOCKETS; i++) { void *p = i < 1000 ? PEB( 1000 + i ) : NULL; if (slot_of( p ) >= 0) exit_child( p ); }
    exit_child( PEB( 2001 ) );
    {
        pthread_t t[8];
        for (i = 0; i < 8; i++) pthread_create( &t[i], NULL, batch, (void *)(intptr_t)(3000 + i * 8) );
        for (i = 0; i < 8; i++) pthread_join( t[i], NULL );
        ok = 1; n = 0;
        for (i = 0; i < 64; i++)
        {
            int s = slot_of( PEB( 3000 + i ) );
            if (s < 0) { ok = 0; continue; }
            for (int j = 0; j < i; j++) if (slot_of( PEB( 3000 + j ) ) == s) ok = 0;
            n++;
        }
        check( ok && n == 64, "8 threads registering 8 children each get 64 different slots" );
    }
    return bad;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-proc-socket-') as directory:
    folder = Path(directory)
    source = folder / 'check.c'
    source.write_text(harness + table + register + main)
    executable = folder / 'check'
    cc = os.environ.get('CC', 'cc')
    flags = [cc, '-std=gnu11', '-Wall', '-Wextra', '-Wno-unused-function', '-Werror', '-g', '-pthread', str(source), '-o', str(executable)]
    sanitize = ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    build = subprocess.run(flags[:1] + sanitize + flags[1:], capture_output=True, text=True)
    if build.returncode == 0:
        print('built with AddressSanitizer/UBSan')
    else:
        build = subprocess.run(flags, capture_output=True, text=True)
        print('built without sanitizers' if build.returncode == 0 else build.stderr[-4000:])
    require(build.returncode == 0, 'harness compiles')
    if build.returncode == 0:
        run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=60)
        print(run.stdout, end='')
        require(run.returncode == 0, 'every runtime check passed, no sanitizer report')
        if run.returncode:
            print(run.stderr[-4000:])

print('PASS' if not failures else f'FAILED ({failures})')
sys.exit(1 if failures else 0)
