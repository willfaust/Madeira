#!/usr/bin/env python3
"""Source-extracted lifetime and suspension regressions; no guest execution."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]


def function(source, signature):
    start = source.index(signature)
    cursor = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[cursor] == '{') - (source[cursor] == '}')
        cursor += 1
    return source[start:cursor]


virtual = (root/'build/ntdll-unix/virtual_ios.c').read_text()
signals = (root/'build/ntdll-unix/signal_arm64_ios.c').read_text()
process = (root/'wine/dlls/ntdll/process.c').read_text()
prefix = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <pthread.h>
typedef uintptr_t ULONG_PTR;
typedef unsigned thread_t, mach_msg_type_number_t;
typedef int kern_return_t;
typedef int *thread_info_t;
struct thread_basic_info { int ignored; };
#define THREAD_BASIC_INFO_COUNT 1
#define THREAD_BASIC_INFO 1
#define KERN_SUCCESS 0
#define KERN_INVALID_ARGUMENT 4
#define MACH_SEND_INVALID_DEST 5
#define KERN_TERMINATED 37
static struct { uintptr_t teb; thread_t mach_thread; } ios_thread_registry[8];
static int query_status[8];
static int ios_thread_registry_count(void) { return 8; }
static kern_return_t thread_info(thread_t port, int flavor, thread_info_t info, mach_msg_type_number_t *length)
{ assert(port < 8); return query_status[port]; }
#define IOS_WOW_MAX_WINDOWS 3
#define IOS_WOW_WINDOW_SIZE 0x100000000ULL
#define IOS_WOW_SETTLE_SEC 3
static struct { ULONG_PTR base; void *peb, *dead_peb; unsigned guard_owned, dead; time_t released_at; } ios_wow_windows[3];
struct ios_wow_placeholder { int adopted; };
static struct ios_wow_placeholder placeholders[3];
static pthread_mutex_t ios_wow_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct ios_wow_placeholder *ios_wow_placeholder_find(ULONG_PTR base)
{ return &placeholders[(base >> 32) - 0x71]; }
static unsigned teardown_count, graphics_count;
static int teardown_ok = 1;
static int ios_wow_window_teardown(ULONG_PTR base, void *peb, unsigned guard)
{ teardown_count++; return teardown_ok; }
static void d3d9_native_process_teardown(void *peb) { graphics_count++; }
static void *ios_jit_rx_base_global = (void *)0x100000000;
static unsigned pool_reclaims;
typedef void *HANDLE;
typedef unsigned long ULONG;
typedef unsigned short WCHAR;
typedef int BOOL, LONG, NTSTATUS;
#define WINAPI
#define STATUS_NOT_IMPLEMENTED (-100)
typedef struct { unsigned short Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
static void RtlInitUnicodeString(UNICODE_STRING *s, const void *name) { (void)s; (void)name; }
static int RtlQueryEnvironmentVariable_U(void *unused, UNICODE_STRING *name, UNICODE_STRING *value)
{
    const char *env = getenv("MADEIRA_WOW_SUSPEND");
    if (!env) return -1;
    size_t len = strlen(env);
    if (len * sizeof(WCHAR) > value->MaximumLength) return -2;
    value->Length = len * sizeof(WCHAR);
    for (size_t i = 0; i < len; ++i) value->Buffer[i] = env[i];
    return 0;
}
static int InterlockedIncrement(LONG *p) { return ++*p; }
#define DbgPrint(...) fprintf(stderr, __VA_ARGS__)
static unsigned suspend_calls;
static NTSTATUS NtSuspendThread(HANDLE thread, ULONG *count)
{
    suspend_calls++;
    if (thread != (void *)12) return -9;
    if (count) *count = 3;
    return 0;
}
'''
# Execute the exact production precondition before the unrelated pool allocator.
jit = function(virtual, 'void ios_jit_reclaim_process( void *peb )')
jit = jit[:jit.index('    pthread_mutex_lock( &ios_pool_lock );')] + '    pool_reclaims++;\n}\n'
checks = r'''
static void dead_window(void)
{
    ios_wow_windows[0].base = 0x7100000000;
    ios_wow_windows[0].dead_peb = (void *)123;
    ios_wow_windows[0].dead = 1;
    ios_wow_windows[0].released_at = time(NULL) - 10;
    placeholders[0].adopted = 1;
}
int main(void)
{
    const uintptr_t base = 0x7100000000;
    unsetenv("MADEIRA_WOW_LIVE_WINDOW_GUARD");
    assert(!ios_thread_registry_range_busy(base, IOS_WOW_WINDOW_SIZE));
    ios_thread_registry[0].teb = base + 0x2c0000;
    ios_thread_registry[0].mach_thread = 1;
    query_status[1] = KERN_SUCCESS;
    assert(ios_thread_registry_range_busy(base, IOS_WOW_WINDOW_SIZE));
    assert(!ios_thread_registry_range_busy(base + IOS_WOW_WINDOW_SIZE, IOS_WOW_WINDOW_SIZE));
    query_status[1] = 99; /* An unexpected query failure is not proof of exit. */
    assert(ios_thread_registry_range_busy(base, IOS_WOW_WINDOW_SIZE));
    query_status[1] = KERN_SUCCESS;
    dead_window();
    ios_wow_reclaim_dead_windows();
    assert(teardown_count == 0 && graphics_count == 0);
    assert(ios_wow_windows[0].dead == 1 && placeholders[0].adopted);
    ios_jit_reclaim_process((void *)123);
    assert(pool_reclaims == 0);
    ios_jit_reclaim_process((void *)456); /* Unrelated native owner. */
    assert(pool_reclaims == 1);
    query_status[1] = KERN_INVALID_ARGUMENT;
    assert(!ios_thread_registry_range_busy(base, IOS_WOW_WINDOW_SIZE));
    ios_jit_reclaim_process((void *)123);
    assert(pool_reclaims == 2);
    teardown_ok = 0;
    ios_wow_reclaim_dead_windows();
    assert(ios_wow_windows[0].dead == 1 && placeholders[0].adopted);
    teardown_ok = 1;
    ios_wow_reclaim_dead_windows();
    assert(!ios_wow_windows[0].base && !placeholders[0].adopted);
    query_status[1] = MACH_SEND_INVALID_DEST;
    assert(!ios_thread_registry_range_busy(base, IOS_WOW_WINDOW_SIZE));
    query_status[1] = KERN_TERMINATED;
    assert(!ios_thread_registry_range_busy(base, IOS_WOW_WINDOW_SIZE));
    ios_thread_registry[0].teb = base + IOS_WOW_WINDOW_SIZE;
    query_status[1] = KERN_SUCCESS;
    assert(!ios_thread_registry_range_busy(base, IOS_WOW_WINDOW_SIZE));
    ios_thread_registry[0].teb = base;
    assert(ios_thread_registry_range_busy(base, IOS_WOW_WINDOW_SIZE));
    dead_window();
    setenv("MADEIRA_WOW_LIVE_WINDOW_GUARD", "0", 1);
    ios_jit_reclaim_process((void *)123);
    assert(pool_reclaims == 3);
    ios_wow_reclaim_dead_windows();
    assert(!ios_wow_windows[0].base); /* Rollback reproduces live-memory retirement. */
    puts("PASS: live/unknown/dead threads, window boundaries, deferred executable retirement, retry and rollback");

    ULONG count = 99;
    unsetenv("MADEIRA_WOW_SUSPEND");
    assert(RtlWow64SuspendThread((void *)12, &count) == 0 && count == 3);
    assert(RtlWow64SuspendThread((void *)12, NULL) == 0);
    count = 99;
    assert(RtlWow64SuspendThread(NULL, &count) == -9 && count == 99);
    assert(suspend_calls == 3);
    setenv("MADEIRA_WOW_SUSPEND", "0", 1);
    assert(RtlWow64SuspendThread((void *)12, &count) == STATUS_NOT_IMPLEMENTED);
    assert(count == 99 && suspend_calls == 3);
    setenv("MADEIRA_WOW_SUSPEND", "1", 1);
    assert(RtlWow64SuspendThread((void *)12, &count) == 0 && suspend_calls == 4);
    puts("PASS: suspension forwards handle/count/status, optional count and disabled path");
}
'''
source = '\n'.join([prefix,
    function(signals, 'int ios_thread_registry_range_busy('),
    function(virtual, 'static void ios_wow_reclaim_dead_windows(void)'), jit,
    function(process, 'NTSTATUS WINAPI RtlWow64SuspendThread('), checks])
with tempfile.TemporaryDirectory(prefix='madeira-lifetime-check-') as directory:
    path = Path(directory)
    (path/'check.c').write_text(source)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-g', '-O1',
                    '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-pthread',
                    str(path/'check.c'), '-o', str(path/'check')], check=True)
    subprocess.run([str(path/'check')], check=True,
                   env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=1'})
