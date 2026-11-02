#!/usr/bin/env python3
"""A full thread registry gives an exited thread's entry to a new thread; no
Wine runs.

#397: a 32-bit game that keeps starting and ending worker threads filled the
512-entry Mach thread registry within minutes with a few dozen threads alive
("[thread-registry] FULL (512 slots)" after idx=511); every later thread
resolved to the slot-0 TEB and the process died on a wrong thread context.
Compiles from build/ntdll-unix/signal_arm64_ios.c the registry and its writers
(ios_thread_registry_add, _reclaim, _reuse_enabled, _purge_range, _range_busy,
ios_thread_port_gone) and ios_lookup_thread, with a fake thread_info that knows
which fake threads are alive, and checks:
  - 4000 threads over the session's life with at most 40 alive all register and
    each resolves to its own TEB; with MADEIRA_THREAD_REUSE=0 (the kill switch),
    the same run reproduces the report: thread 512 is not registered and
    resolves to slot 0;
  - a full registry of live threads still refuses (FULL), and displaces none;
  - entry 0 (the lookup's fallback) and an exited thread's entry whose TEB still
    carries a FEX lock stamp are kept; an entry purged with its guest window and
    an exited thread's entry are reused; an unexpected thread_info failure
    counts as alive;
  - concurrent registrations never fill the same entry.
Needs python3 and a C compiler.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()


def body(signature):
    start = source.index(signature + '\n{')
    return source[start:source.index('\n}\n', start) + 3]


start = source.index('#define IOS_MAX_WINE_THREADS ')
registry = source[start:source.index('\n', start) + 1]
start = source.index('struct ios_thread_entry {')
end = source.index('static pthread_mutex_t ios_thread_registry_lock = PTHREAD_MUTEX_INITIALIZER;\n', start)
registry += source[start:end] + 'static pthread_mutex_t ios_thread_registry_lock = PTHREAD_MUTEX_INITIALIZER;\n'
functions = '\n'.join(body(s) for s in (
    'int ios_thread_registry_count(void)',
    'int ios_thread_registry_purge_range( uintptr_t base, uintptr_t size )',
    'static int ios_thread_port_gone( thread_t port )',
    'int ios_thread_registry_range_busy( uintptr_t base, uintptr_t size )',
    'static int ios_thread_registry_reclaim( void )',
    'static int ios_thread_registry_reuse_enabled( void )',
    'static int ios_thread_registry_add( thread_t pe_thread, uintptr_t teb, void *trampoline )',
    'static int ios_lookup_thread(thread_t mach_thread, uintptr_t *teb_out, void **tramp_out)',
))
setup = body('static void ios_setup_mach_exception_handler( thread_t pe_thread, uintptr_t teb,\n'
             '                                               void *trampoline )')
assert 'int idx = ios_thread_registry_add( pe_thread, teb, trampoline );' in setup
assert 'ios_thread_registry[' not in setup, 'registration writes the registry only through ios_thread_registry_add'
assert functions.count('ios_thread_registry_reclaim()') == 1
assert 'else if (ios_thread_registry_reuse_enabled() && (idx = ios_thread_registry_reclaim()) >= 0)' in functions

harness = r'''
#include <assert.h>
#include <pthread.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned int thread_t, mach_port_t, mach_msg_type_number_t;
typedef int kern_return_t;
typedef int *thread_info_t;
typedef uint64_t mach_vm_address_t, mach_vm_size_t;
/* [wow-reap] (MADEIRA_WOW_REAP_DEAD): a suspended thread of an exited process does not hold its
 * range. The fake threads are never suspended (suspend_count 0), so it never applies here. */
typedef uint64_t vm_address_t, vm_size_t;
typedef struct { void *Peb; } TEB;
#define vm_read_overwrite mach_vm_read_overwrite
int ios_peb_is_dead( const void *peb ) { (void)peb; return 0; }
#define KERN_SUCCESS 0
#define KERN_INVALID_ADDRESS 1
#define KERN_INVALID_ARGUMENT 4
#define KERN_FAILURE 5
#define KERN_TERMINATED 37
#define MACH_SEND_INVALID_DEST 0x10000003
#define THREAD_BASIC_INFO 3
#define THREAD_BASIC_INFO_COUNT 10
#define MACH_PORT_RIGHT_SEND 0
struct thread_basic_info { int suspend_count; int words[9]; };
static mach_port_t mach_task_self(void) { return 1; }

/* fake threads: port FIRST_PORT + n is thread n */
enum { FIRST_PORT = 0x1003, MAX_PORTS = 40000, TEBS = 1024, TEB_SIZE = 0x2000 };
static unsigned char thread_state[MAX_PORTS];   /* 0 never created, 1 alive, 2 exited, 3 query fails */
static _Alignas(16) unsigned char teb_pool[TEBS][TEB_SIZE];
static unsigned long mod_refs_calls;
static kern_return_t thread_info(thread_t port, int flavor, thread_info_t info, mach_msg_type_number_t *count)
{
    unsigned n = port - FIRST_PORT;
    (void)flavor; (void)count;
    if (info) memset(info, 0, sizeof(struct thread_basic_info));
    if (port < FIRST_PORT || n >= MAX_PORTS) return MACH_SEND_INVALID_DEST;
    switch (__atomic_load_n(&thread_state[n], __ATOMIC_ACQUIRE))
    {
    case 1: return KERN_SUCCESS;
    case 3: return KERN_FAILURE;
    default: return MACH_SEND_INVALID_DEST;   /* an exited thread leaves a dead name */
    }
}
static kern_return_t mach_vm_read_overwrite(mach_port_t task, mach_vm_address_t addr, mach_vm_size_t size,
                                            mach_vm_address_t out, mach_vm_size_t *got)
{
    uintptr_t lo = (uintptr_t)teb_pool, hi = lo + sizeof(teb_pool);
    (void)task;
    if (addr < lo || addr + size > hi) return KERN_INVALID_ADDRESS;
    memcpy((void *)(uintptr_t)out, (const void *)(uintptr_t)addr, size);
    *got = size;
    return KERN_SUCCESS;
}
static kern_return_t mach_port_mod_refs(mach_port_t task, thread_t port, int right, int delta)
{
    (void)task; (void)port; (void)right; (void)delta;
    __atomic_add_fetch(&mod_refs_calls, 1, __ATOMIC_RELAXED);
    return KERN_SUCCESS;
}
static unsigned long full_lines, reuse_lines, replace_lines, switch_off_lines;
static void fake_err(const char *format, ...)
{
    char line[512];
    va_list ap;
    va_start(ap, format);
    vsnprintf(line, sizeof(line), format, ap);
    va_end(ap);
    if (strstr(line, "] FULL (")) __atomic_add_fetch(&full_lines, 1, __ATOMIC_RELAXED);
    if (strstr(line, "] FULL (") && strstr(line, "MADEIRA_THREAD_REUSE=0"))
        __atomic_add_fetch(&switch_off_lines, 1, __ATOMIC_RELAXED);
    if (strstr(line, "] REUSE #")) __atomic_add_fetch(&reuse_lines, 1, __ATOMIC_RELAXED);
    if (strstr(line, "] REPLACE idx=")) __atomic_add_fetch(&replace_lines, 1, __ATOMIC_RELAXED);
}
#define ERR(...) fake_err(__VA_ARGS__)
''' + registry + functions + r'''
static thread_t port_of(unsigned n) { return FIRST_PORT + n; }
static uintptr_t teb_of(unsigned n) { return (uintptr_t)teb_pool[n % TEBS]; }
static void *tramp_of(unsigned n) { return (void *)(uintptr_t)(0x9000000 + n * 16); }
static void set_state(unsigned n, unsigned char s) { __atomic_store_n(&thread_state[n], s, __ATOMIC_RELEASE); }
static void reset(void)
{
    memset(ios_thread_registry, 0, sizeof(ios_thread_registry));
    ios_thread_count = 0;
    memset(thread_state, 0, sizeof(thread_state));
    memset(teb_pool, 0, sizeof(teb_pool));
    full_lines = reuse_lines = replace_lines = switch_off_lines = 0;
}
static int entry_of(thread_t port)
{
    int i, found = -1;
    for (i = 0; i < ios_thread_registry_count(); i++)
        if (ios_thread_registry[i].mach_thread == port) { assert(found < 0); found = i; }
    return found;
}
static int new_thread(unsigned n)
{
    set_state(n, 1);
    return ios_thread_registry_add(port_of(n), teb_of(n), tramp_of(n));
}

/* #397: worker threads come and go, a few dozen alive at once */
static void churn(int with_reclaim)
{
    enum { TOTAL = 4000, LIVE = 40 };
    unsigned n, oldest = 1, first_failed = 0, failed = 0, misresolved = 0;
    reset();
    assert(new_thread(0) == 0);                       /* the session's first thread keeps entry 0 */
    for (n = 1; n <= TOTAL; n++)
    {
        unsigned live;
        if (new_thread(n) < 0 && !failed++) first_failed = n;
        for (live = oldest; live <= n; live++)
        {
            uintptr_t teb = 0; void *tramp = NULL;
            assert(ios_lookup_thread(port_of(live), &teb, &tramp));
            if (teb != teb_of(live) || tramp != tramp_of(live)) misresolved++;
        }
        if (n - oldest + 1 >= LIVE) set_state(oldest++, 2);
    }
    assert(ios_thread_registry_count() == IOS_MAX_WINE_THREADS);
    assert(ios_thread_registry[0].mach_thread == port_of(0) && ios_thread_registry[0].teb == teb_of(0));
    if (with_reclaim)
    {
        assert(!failed && !misresolved && !full_lines);
        assert(reuse_lines == 16 + (TOTAL - (IOS_MAX_WINE_THREADS - 1)) / 256);
        assert(mod_refs_calls >= TOTAL + 1);
        printf("PASS: %u threads, %d alive at most: every one registered and resolves to its own TEB "
               "(%lu REUSE lines)\n", TOTAL, LIVE, reuse_lines);
    }
    else
    {
        assert(first_failed == IOS_MAX_WINE_THREADS && failed == TOTAL - (IOS_MAX_WINE_THREADS - 1));
        assert(misresolved && full_lines == failed && switch_off_lines == failed && !reuse_lines);
        printf("PASS: with MADEIRA_THREAD_REUSE=0 the same run reproduces #397: thread %u is not registered, "
               "%u threads unregistered, %u lookups resolved to the slot-0 TEB\n",
               first_failed, failed, misresolved);
    }
}

static void edges(void)
{
    unsigned n, next = IOS_MAX_WINE_THREADS;
    struct ios_thread_entry before[IOS_MAX_WINE_THREADS];
    reset();
    for (n = 0; n < IOS_MAX_WINE_THREADS; n++) assert(new_thread(n) == (int)n);

    /* every entry live: refused, nothing displaced */
    memcpy(before, ios_thread_registry, sizeof(before));
    assert(new_thread(next++) == -1 && full_lines == 1);
    assert(!memcmp(before, ios_thread_registry, sizeof(before)));

    /* entry 0 is the lookup's fallback: never reused */
    set_state(0, 2);
    assert(new_thread(next++) == -1 && full_lines == 2);

    /* an unexpected query failure counts as alive */
    set_state(3, 3);
    assert(new_thread(next++) == -1 && full_lines == 3);

    /* an exited thread whose TEB carries a FEX lock stamp stays for ios_lock_census */
    set_state(5, 2); *(uint64_t *)(teb_of(5) + 0x16f8) = 0x7123450000;   /* Instrumentation[8] */
    set_state(7, 2); *(uint64_t *)(teb_of(7) + 0x16e8) = 0x7123460000;   /* Instrumentation[6] */
    set_state(9, 2);
    assert(new_thread(next) == 9 && ios_thread_registry[9].mach_thread == port_of(next));
    assert(ios_thread_registry[9].teb == teb_of(next) && ios_thread_registry[9].trampoline == tramp_of(next));
    next++;
    assert(new_thread(next++) == -1);
    *(uint64_t *)(teb_of(5) + 0x16f8) = 0;
    assert(new_thread(next++) == 5);

    /* a TEB the read cannot reach does not keep an exited thread's entry */
    set_state(11, 2); ios_thread_registry[11].teb = 0x10;
    assert(new_thread(next++) == 11);

    /* entries purged with their guest window are taken next */
    {
        uintptr_t base = teb_of(20), size = (uintptr_t)teb_of(23) - base;
        unsigned k;
        for (k = 20; k < 23; k++) set_state(k, 2);
        assert(!ios_thread_registry_range_busy(base, size));
        set_state(21, 1);
        assert(ios_thread_registry_range_busy(base, size));
        set_state(21, 2);
        assert(ios_thread_registry_purge_range(base, size) == 3);
        for (k = 20; k < 23; k++) assert(!ios_thread_registry[k].mach_thread && !ios_thread_registry[k].teb);
        for (k = 20; k < 23; k++) assert(new_thread(next++) == (int)k);
    }

    /* the same port again is replaced in place, as before */
    {
        unsigned count = ios_thread_registry_count();
        int idx = entry_of(port_of(100));
        assert(ios_thread_registry_add(port_of(100), teb_of(101), tramp_of(101)) == idx && idx == 100);
        assert(replace_lines == 1 && ios_thread_registry_count() == (int)count);
        assert(ios_thread_registry[100].teb == teb_of(101));
    }
    for (n = 1; n < IOS_MAX_WINE_THREADS; n++)
        if (n != 5 && n != 7 && n != 9 && n != 11 && (n < 20 || n > 22))
            assert(ios_thread_registry[n].mach_thread == port_of(n));
    printf("PASS: a registry of live threads refuses and displaces none; entry 0, a stamped exited "
           "thread's entry and an unanswerable query are kept; exited and purged entries are reused\n");
}

/* concurrent registrations never take the same entry */
enum { WORKERS = 8, EACH = 1500, KEEP = 6 };
static void *worker(void *arg)
{
    unsigned w = (unsigned)(uintptr_t)arg, i, base = 1 + w * EACH;
    for (i = 0; i < EACH; i++)
    {
        assert(new_thread(base + i) >= 0);
        if (i >= KEEP) set_state(base + i - KEEP, 2);
    }
    return NULL;
}
static void concurrent(void)
{
    pthread_t threads[WORKERS];
    unsigned w, i, live = 0;
    reset();
    assert(new_thread(0) == 0);
    for (w = 0; w < WORKERS; w++) assert(!pthread_create(&threads[w], NULL, worker, (void *)(uintptr_t)w));
    for (w = 0; w < WORKERS; w++) assert(!pthread_join(threads[w], NULL));
    for (i = 0; i <= WORKERS * EACH; i++)
    {
        if (thread_state[i] != 1) continue;
        assert(entry_of(port_of(i)) >= 0);
        live++;
    }
    assert(live == 1 + WORKERS * KEEP && !full_lines);
    printf("PASS: %u concurrent registrations, %u live threads, each in an entry of its own\n",
           WORKERS * EACH, live);
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    assert(ios_thread_registry_reuse_enabled() == atoi(argv[1]));
    if (atoi(argv[1])) { churn(1); edges(); concurrent(); }
    else churn(0);
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-thread-registry-') as directory:
    temp = Path(directory)
    unit = temp / 'registry.c'
    exe = temp / 'registry'
    unit.write_text(harness)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-function', '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                    str(unit), '-pthread', '-o', str(exe)], check=True)
    env = {k: v for k, v in os.environ.items() if k != 'MADEIRA_THREAD_REUSE'}
    for value, reuse in ((None, 1), ('1', 1), ('0', 0)):
        run_env = dict(env, **({'MADEIRA_THREAD_REUSE': value} if value is not None else {}))
        subprocess.run([str(exe), str(reuse)], env=run_env, check=True)
