#!/usr/bin/env python3
"""The session's first process has its own exiting flag (build/ntdll-unix/server_ios.c); no Wine runs.

Wine's mutex_lock() and mutex_unlock() (wine/dlls/ntdll/unix/unix_private.h) skip
the pthread call while the global process_exiting is set, and every pseudo-process
reads that one global. ios_process_exiting_ptr() gave children a flag of their
own but handed the global itself to the initial process, which has no slot in
ios_proc_sockets. When a first process that started a game exited,
NtTerminateProcess( 0, ... ) set the global, and virtual_mutex, fd_cache_mutex and
the other locks stopped excluding anything for the rest of the session.

Compiles the production slot table, ios_proc_socket_index,
ios_process_exiting_ptr and ios_register_proc_socket (server_ios.c) with Wine's
own mutex_lock/mutex_unlock (unix_private.h), and checks:
  - the first process (no slot) setting its flag, as NtTerminateProcess( 0, ... )
    does, leaves the global FALSE, and its own flag reads back TRUE;
  - after that, a mutex taken with mutex_lock() in one process is really held
    against another process, and mutex_unlock() really releases it;
  - a child exiting sets neither the global, the first process's flag nor a
    sibling's;
  - NtTerminateProcess (process_ios.c) sets the flag ios_process_exiting_ptr()
    returned, and only its non-iOS branch writes the global.
Needs the wine submodule, python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
ntdll = root / 'build/ntdll-unix'
server = (ntdll / 'server_ios.c').read_text()
process = (ntdll / 'process_ios.c').read_text()
private_h = root / 'wine/dlls/ntdll/unix/unix_private.h'
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]


if not private_h.exists():
    print('FAIL: wine/dlls/ntdll/unix/unix_private.h missing (check out the wine submodule)')
    sys.exit(1)
private = private_h.read_text()
locks = (function(private, 'static inline void mutex_lock( pthread_mutex_t *mutex )') +
         function(private, 'static inline void mutex_unlock( pthread_mutex_t *mutex )'))
require('if (!process_exiting) pthread_mutex_lock( mutex );' in locks,
        "wine: mutex_lock() does nothing while the global process_exiting is set")

start = server.index('#define IOS_MAX_PROC_SOCKETS')
table = server[start:server.index('\n}\n', server.index('BOOL *ios_process_exiting_ptr(void)')) + 3]
register = function(server, 'static void ios_register_proc_socket(void *peb_id, int fd)')

# ------------------------------------------------------------------ static
require('&process_exiting' not in server, 'server_ios.c hands out no pointer to the global')
terminate = function(process, 'NTSTATUS WINAPI NtTerminateProcess( HANDLE handle, LONG exit_code )')
require('BOOL *exiting_flag = ios_process_exiting_ptr();' in terminate and
        '#ifdef WINE_IOS\n        if (!handle) *exiting_flag = TRUE;' in terminate,
        'NtTerminateProcess sets the flag ios_process_exiting_ptr() returned')
writes = [(f.name, line.strip()) for f in sorted(ntdll.glob('*.c'))
          for line in f.read_text().splitlines() if re.search(r'\bprocess_exiting\s*=\s*\w+\s*;', line)]
require(writes == [('process_ios.c', 'if (!handle) process_exiting = TRUE;'),
                   ('server_ios.c', 'BOOL process_exiting = FALSE;')] and
        '#else\n        if (!handle) process_exiting = TRUE;' in terminate,
        'the global is written only by its definition and the non-iOS branch of NtTerminateProcess')

harness = r'''
#include <errno.h>
#include <pthread.h>
#include <stdio.h>

typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define FDT_MASTER 1
BOOL process_exiting = FALSE;
static int fd_socket = 3;
static __thread void *cur_peb;
void *ios_jit_current_peb(void) { return cur_peb; }
static void ios_fdt_reg( int fd, int kind, void *peb ) { (void)fd; (void)kind; (void)peb; }
static void wine_log_write( const char *format, ... ) { (void)format; }
'''

harness_main = r'''
#define FIRST  ((void *)0x10000)   /* the program the app started: no slot */
#define CHILD1 ((void *)0x20000)
#define CHILD2 ((void *)0x30000)

static int bad;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int trylock_result;

static void check( int ok, const char *label ) { printf( "%s: %s\n", ok ? "PASS" : "FAIL", label ); bad |= !ok; }
static BOOL *flag_of( void *peb ) { cur_peb = peb; return ios_process_exiting_ptr(); }

static void *other_process( void *peb )
{
    cur_peb = peb;
    trylock_result = pthread_mutex_trylock( &lock );
    if (!trylock_result) pthread_mutex_unlock( &lock );
    return NULL;
}

static int trylock_from( void *peb )
{
    pthread_t thread;
    pthread_create( &thread, NULL, other_process, peb );
    pthread_join( thread, NULL );
    return trylock_result;
}

int main( void )
{
    BOOL *first;

    ios_register_proc_socket( CHILD1, 10 );
    ios_register_proc_socket( CHILD2, 11 );
    first = flag_of( FIRST );
    check( first != &process_exiting, "the first process (no slot) gets a flag of its own, not the global" );
    check( flag_of( CHILD1 ) != flag_of( CHILD2 ) && flag_of( CHILD1 ) != first && flag_of( CHILD2 ) != first,
           "every process has a separate flag" );

    /* the first process exits: RtlExitUserProcess -> NtTerminateProcess( 0, ... ) */
    *flag_of( FIRST ) = TRUE;
    check( !process_exiting, "first process exits: the global stays FALSE" );
    check( *flag_of( FIRST ) == TRUE, "first process exits: its own flag reads TRUE (its self-terminate shortcut)" );
    check( !*flag_of( CHILD1 ) && !*flag_of( CHILD2 ), "first process exits: the children's flags stay FALSE" );

    /* the game it started goes on and takes a lock */
    cur_peb = CHILD1;
    mutex_lock( &lock );
    check( trylock_from( CHILD2 ) == EBUSY, "afterwards: a mutex_lock() in one process excludes another" );
    cur_peb = CHILD1;
    mutex_unlock( &lock );
    check( trylock_from( CHILD2 ) == 0, "afterwards: mutex_unlock() releases it" );

    /* a child exits */
    *flag_of( CHILD1 ) = TRUE;
    check( !process_exiting && !*flag_of( CHILD2 ), "a child exits: the global and its sibling's flag stay FALSE" );
    check( flag_of( NULL ) == first, "a thread without a PEB shares the first process's flag, not the global" );
    return bad;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-first-exiting-') as directory:
    folder = Path(directory)
    source = folder / 'check.c'
    source.write_text(harness + locks + table + register + harness_main)
    executable = folder / 'check'
    cc = os.environ.get('CC', 'cc')
    flags = [cc, '-std=gnu11', '-Wall', '-Wextra', '-Wno-unused-function', '-Werror', '-g', '-pthread',
             str(source), '-o', str(executable)]
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
