#!/usr/bin/env python3
"""Exercise production session retirement with mock server clients and pthreads.

Runs host-only lifecycle checks, not Wine or an emulator. Production bridge
functions and server-loop decisions are extracted without rewriting their logic.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
bridge = (root / 'app/Madeira/WineServerBridge.m').read_text()
client = (root / 'app/Madeira/WineProcessBridge.m').read_text()
server = (root / 'build/wineserver/fd_ios.c').read_text()
process = (root / 'wine/server/process.c').read_text()


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


code = r'''
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define wine_log_msg(...) ((void)0)
#define ws_log(...) ((void)0)
static int g_wineserver_running, g_wine_running;
static int g_wineserver_should_stop, g_wineserver_session_stop, g_wineserver_root_retired;
static pthread_t g_wineserver_thread;
static int user_processes;  /* server-owned, like the production counter */
static int requested_clients, observed_clients, forced_quit;
static void shutdown_master_socket(void)
{
    __atomic_store_n(&forced_quit,1,__ATOMIC_RELEASE);
    __atomic_store_n(&requested_clients,0,__ATOMIC_RELEASE);
}
'''
for signature in ['static void wineserver_thread_finished(', 'int wineserver_is_running(',
                  'int wineserver_request_session_stop(', 'void wineserver_stop(',
                  'void wineserver_finish_session(']:
    code += function(bridge, signature)
code += function(client, 'static void wine_process_finished(')
code += function(client, 'int wine_process_is_running(')
code += function(process, 'int ios_server_user_process_count(')
code += r'''
static void *server_main(void *arg)
{
    pthread_cleanup_push(wineserver_thread_finished,NULL);
    if (arg) pthread_exit(NULL);  /* actual server timeout/fatal exit style */
    int session_processes=-1;
    unsigned int session_notes=0;
    for (;;)
    {
        user_processes=__atomic_load_n(&requested_clients,__ATOMIC_ACQUIRE);
'''
start = server.index('            extern int g_wineserver_session_stop;')
end = server.index('            /* Check stop flag */', start)
code += server[start:end]
code += r'''
        __atomic_store_n(&observed_clients,user_processes,__ATOMIC_RELEASE);
        if (__atomic_load_n(&g_wineserver_should_stop,__ATOMIC_ACQUIRE)) break;
        usleep(1000);
    }
    pthread_cleanup_pop(1);
    return NULL;
}
static void *retire_root(void *unused)
{
    wine_process_finished(unused);
    return NULL;
}
static void wait_value(int *value,int expected)
{
    for (int n=0;n<5000;++n)
    {
        if (__atomic_load_n(value,__ATOMIC_ACQUIRE)==expected) return;
        usleep(1000);
    }
    assert(!"session lifecycle timed out");
}
static void start(int clients, int fail)
{
    g_wineserver_running=g_wine_running=1;
    g_wineserver_should_stop=g_wineserver_session_stop=g_wineserver_root_retired=0;
    forced_quit=0; observed_clients=-1; requested_clients=clients;
    assert(!pthread_create(&g_wineserver_thread,NULL,server_main,fail ? (void *)1 : NULL));
}
int main(void)
{
    pthread_t root_thread;
    unsetenv("MADEIRA_SESSION_DESCENDANTS");
    /* Launcher and child are registered before the launcher retires. */
    start(2,0);
    assert(!pthread_create(&root_thread,NULL,retire_root,NULL));
    wait_value(&g_wineserver_root_retired,1);
    wait_value(&observed_clients,2);
    assert(wine_process_is_running() && wineserver_is_running());
    __atomic_store_n(&requested_clients,1,__ATOMIC_RELEASE);
    wait_value(&observed_clients,1); /* launcher EOF; child remains */
    assert(wine_process_is_running() && wineserver_is_running());
    __atomic_store_n(&requested_clients,2,__ATOMIC_RELEASE);
    wait_value(&observed_clients,2); /* child starts a grandchild */
    __atomic_store_n(&requested_clients,1,__ATOMIC_RELEASE);
    wait_value(&observed_clients,1); /* intermediate launcher retires */
    assert(wine_process_is_running() && wineserver_is_running());
    __atomic_store_n(&requested_clients,0,__ATOMIC_RELEASE);
    assert(!pthread_join(root_thread,NULL));
    assert(!wine_process_is_running() && !wineserver_is_running() && !forced_quit);

    /* A session with no descendants closes, without a fixed grace timeout. */
    start(0,0); wine_process_finished(NULL);
    assert(!wine_process_is_running() && !wineserver_is_running());

    /* Quit still reaches the server while the original thread is joining. */
    start(1,0);
    assert(!pthread_create(&root_thread,NULL,retire_root,NULL));
    wait_value(&g_wineserver_root_retired,1); wait_value(&observed_clients,1);
    assert(wineserver_request_session_stop());
    assert(!pthread_join(root_thread,NULL));
    assert(forced_quit && !wine_process_is_running() && !wineserver_is_running());

    /* Rollback preserves immediate stop even with a live child. */
    setenv("MADEIRA_SESSION_DESCENDANTS","0",1);
    start(1,0); wine_process_finished(NULL);
    assert(g_wineserver_should_stop && !wine_process_is_running() && !wineserver_is_running());
    unsetenv("MADEIRA_SESSION_DESCENDANTS");

    /* A pthread_exit path clears state, so joining a failed server completes. */
    start(1,1); wait_value(&g_wineserver_running,0); wine_process_finished(NULL);
    assert(!wine_process_is_running() && !g_wineserver_thread);
    puts("PASS: child/grandchild retention, final exit, no-child exit, Quit, rollback, server pthread_exit, and repeated sessions");
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-session-check-') as directory:
    path = Path(directory)
    (path / 'check.c').write_text(code)
    subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-parameter', '-pthread', '-fsanitize=address,undefined',
                    '-o', str(path / 'check'), str(path / 'check.c')], check=True)
    subprocess.run([str(path / 'check')], check=True, timeout=30)
