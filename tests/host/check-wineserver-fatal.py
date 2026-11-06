#!/usr/bin/env python3
"""A wineserver that dies at start-up is no longer reported as running (app/Madeira/WineServerBridge.m); no Wine runs.

wineserver runs as a thread of the app. Its fatal_error() is replaced in
WineServerBridge.m: it logs "[Wine] FATAL: ..." and ends the thread with
pthread_exit(), so the end of wineserver_thread_func, which clears
g_wineserver_running, never runs. When the server could not start (for example
"[Wine] FATAL: bind: Operation not permitted" in LiveContainer Multitask, #562),
wineserver_is_running() still said 1: the launch waited out its 2 s, started Wine
anyway and Wine waited forever for its first reply. The flag also stayed set for
the rest of the app's life, so every "no session runs" guard kept refusing.

Compiles the production fatal_error(), wineserver_is_running() and the flag
(WineServerBridge.m) with a stub logger, and checks:
  - a server thread that calls fatal_error() during start-up leaves
    wineserver_is_running() at 0, and the FATAL line is logged;
  - the launch's wait for the server (ContentView.swift) stops at once when the
    flag clears, instead of after 2 s;
  - and statically, that the launch then does not start Wine: the wait also ends
    on wineserver_is_running() == 0, startWineProcess() returns before
    wine_process_start() when the server is not running, and a launch whose
    Wine never ran is reported with launchFailed().
Needs python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
bridge = (root / 'app/Madeira/WineServerBridge.m').read_text()
content = (root / 'app/Madeira/ContentView.swift').read_text()
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]


# ------------------------------------------------------------------ static
fatal = function(bridge, 'void fatal_error( const char *err, ... ) {')
running = function(bridge, 'int wineserver_is_running(void) {')
flag = re.findall(r'^static volatile int g_wineserver_running = 0;$', bridge, re.M)
require(len(flag) == 1, 'WineServerBridge.m defines g_wineserver_running once')
require('pthread_exit(NULL);' in fatal and not re.search(r'^\s*exit\(', fatal, re.M),
        'fatal_error() ends only the server thread (pthread_exit), not the app')

launch = content[content.index('self.startWineserver()'):content.index('self.startWineProcess()')]
require('while wineserver_is_ready() == 0, wineserver_is_running() != 0, CFAbsoluteTimeGetCurrent() - waitStart < 2.0 {' in launch,
        'the launch waits for the server until it is ready, stops running, or 2 s pass')
start_wine = function(content, '    private func startWineProcess() {')
require(re.search(r'if wineserver_is_running\(\) == 0 \{\n[^}]*\n\s*return\n\s*\}', start_wine) is not None and
        start_wine.index('if wineserver_is_running() == 0 {') < start_wine.index('wine_process_start('),
        'startWineProcess() does not start Wine while the server is not running')
tail = content[content.index('self.startWineProcess()'):]
tail = tail[:tail.index('private func startWineserver()')]
require('while wine_process_is_running() != 0 {' in tail and
        'if wine_process_is_running() == 0 { LibraryModel.shared.launchFailed() }' in tail,
        'a launch whose Wine is not running ends and is reported as failed')

# ------------------------------------------------------------------ behaviour
harness = r'''
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static char logged[1200];
static void wine_log_msg_impl( const char *fmt, ... )
{
    va_list args;
    va_start( args, fmt );
    vsnprintf( logged, sizeof(logged), fmt, args );
    va_end( args );
}
void fatal_error( const char *err, ... );
''' + (flag[0] + '\n' if flag else '')

harness_main = r'''
static int bad;
static void check( int ok, const char *label ) { printf( "%s: %s\n", ok ? "PASS" : "FAIL", label ); bad |= !ok; }

static double now( void )
{
    struct timespec ts;
    clock_gettime( CLOCK_MONOTONIC, &ts );
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* wineserver_thread_func -> wineserver_main -> acquire_lock() (request_ios.c) */
static void *server_thread( void *arg )
{
    (void)arg;
    fatal_error( "bind: %s\n", strerror( EPERM ) );
    return (void *)1;   /* not reached */
}

int main( void )
{
    pthread_t thread;
    void *result = NULL;
    double start, waited;
    int ready = 0;

    g_wineserver_running = 1;   /* wineserver_start(), before pthread_create */
    pthread_create( &thread, NULL, server_thread, NULL );

    /* ContentView.swift, MADEIRA_FAST_SERVER_START: wait for ready, a stopped server or 2 s */
    start = now();
    while (!ready && wineserver_is_running() != 0 && now() - start < 2.0)
    {
        struct timespec ms10 = { 0, 10 * 1000 * 1000 };
        nanosleep( &ms10, NULL );
    }
    waited = now() - start;
    pthread_join( thread, &result );

    check( result == NULL, "the server thread ended inside fatal_error() (pthread_exit)" );
    check( strstr( logged, "[Wine] FATAL: bind: " ) != NULL, "the FATAL line is logged" );
    check( wineserver_is_running() == 0, "after fatal_error(), wineserver_is_running() is 0" );
    printf( "launch wait ended after %.0f ms\n", waited * 1000 );
    check( waited < 1.0, "the launch's wait for the server stops when fatal_error() runs, not after 2 s" );
    return bad;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-wineserver-fatal-') as directory:
    folder = Path(directory)
    source = folder / 'check.c'
    source.write_text(harness + fatal + running + harness_main)
    executable = folder / 'check'
    cc = os.environ.get('CC', 'cc')
    flags = [cc, '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-g', '-pthread',
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
