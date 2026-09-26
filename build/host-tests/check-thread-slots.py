#!/usr/bin/env python3
"""ml1990 host checks for the iOS Mach thread registry, the x18 trampoline slots
and the FEX code-buffer generation cap; never runs Wine, FEX or iOS.

Compiles the PRODUCTION registry block of build/ntdll-unix/signal_arm64_ios.c and
the trampoline allocator + ios_tail_gen_cap() of build/ntdll-unix/virtual_ios.c
under ASan/UBSan, over a simulated Mach port namespace that recycles the lowest
free name immediately (the harshest case for ml401's "never reuse a live name").

  * churn: thousands of thread start/exit cycles keep the registry and the
    trampoline page bounded; every lookup names the right TEB; dead names'
    pinned refs are dropped so names really are recycled;
  * cross-terminated threads (no exit hook) are reclaimed only by the FULL sweep,
    and a dead thread still stamped as holding a FEX lock keeps its row;
  * true overflow: registration fails, lookups MISS (teb 0), slot 0 is never
    aliased or overwritten;
  * concurrent writers + a lock-free reader: a lookup never returns a TEB that
    was registered under a different port name;
  * gen cap: the device case (budget 104 MB, live 32 MB) now grants 32 MB, low
    headroom and the three-quarters rule are unchanged;
  * each MADEIRA_* kill switch restores the pre-ml1990 behaviour.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
sig = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text(encoding='utf-8')
vir = (root / 'build/ntdll-unix/virtual_ios.c').read_text(encoding='utf-8')


def function(source, start):
    a = source.index(start)
    b = source.index('{', a)
    depth, c = 1, b + 1
    while depth:
        depth += (source[c] == '{') - (source[c] == '}')
        c += 1
    return source[a:c]


reg_start = sig.index('/* Per-thread trampoline for signal handlers (runs on faulting thread) */')
reg_end = sig.index('static int ios_lookup_thread(')
registry = sig[reg_start:reg_end] + function(sig, 'static int ios_lookup_thread(')
assert 'ios_thread_registry_add( pe_thread, teb, trampoline )' in sig, 'registration goes through the new helper'
assert sig.count('Mach events on it will resolve to the slot-0 TEB') == 1, 'old FULL path only in the rollback branch'

tr_start = vir.index('void *ios_jit_rx_base_global = NULL;')
tramp = vir[tr_start:vir.index('/* Reverse of the JIT translation', tr_start)]
gen_start = vir.index('static size_t ios_tail_head_margin(void)')
gencap = vir[gen_start:vir.index('/* How many carves are free, and how many bytes they hold.', gen_start)]
thread_ios = (root / 'build/ntdll-unix/thread_ios.c').read_text(encoding='utf-8')
assert 'ios_thread_registry_exit_self();' in function(thread_ios, 'static DECLSPEC_NORETURN void pthread_exit_wrapper('), \
    'exit hook runs on every pthread_exit_wrapper path'

prelude = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ---- simulated Mach port namespace (the "kernel") ---- */
typedef unsigned int thread_t, mach_port_t, mach_port_type_t, mach_port_urefs_t, mach_port_right_t;
typedef int kern_return_t, mach_port_delta_t;
typedef unsigned long long mach_vm_address_t, mach_vm_size_t;
typedef unsigned int mach_msg_type_number_t;
typedef int *thread_info_t;
struct thread_basic_info { int run_state; };
#define KERN_SUCCESS 0
#define KERN_INVALID_ARGUMENT 4
#define KERN_INVALID_NAME 15
#define KERN_INVALID_RIGHT 17
#define KERN_INVALID_VALUE 18
#define KERN_TERMINATED 37
#define MACH_SEND_INVALID_DEST 0x10000003
#define MACH_PORT_RIGHT_SEND 0
#define MACH_PORT_RIGHT_DEAD_NAME 4
#define MACH_PORT_TYPE_SEND (1u << 16)
#define MACH_PORT_TYPE_DEAD_NAME (1u << 20)
#define THREAD_BASIC_INFO 3
#define THREAD_BASIC_INFO_COUNT 1
#define NNAMES 4096
enum { N_NONE, N_ALIVE, N_DEAD };
static struct { int st; unsigned urefs; } names[NNAMES];
static pthread_mutex_t kmu = PTHREAD_MUTEX_INITIALIZER;
static unsigned long recycled;
static thread_t name_of(int i) { return (thread_t)(i * 4 + 0x1003); }
static int idx_of(thread_t n) { if (n < 0x1003 || (n - 0x1003) % 4) return -1; int i = (n - 0x1003) / 4; return i < NNAMES ? i : -1; }
static mach_port_t mach_task_self(void) { return 0; }
static thread_t k_create(void)           /* lowest free name: recycle as eagerly as possible */
{
    pthread_mutex_lock(&kmu);
    for (int i = 0; i < NNAMES; i++)
        if (names[i].st == N_NONE) { names[i].st = N_ALIVE; names[i].urefs = 1; recycled++; pthread_mutex_unlock(&kmu); return name_of(i); }
    pthread_mutex_unlock(&kmu); fprintf(stderr, "name space exhausted (pinned refs leaked)\n"); abort();
}
static void k_die(thread_t n)            /* thread terminates; bsdthread_terminate drops pthread's ref */
{
    pthread_mutex_lock(&kmu);
    int i = idx_of(n); assert(i >= 0 && names[i].st == N_ALIVE);
    names[i].st = N_DEAD;
    if (--names[i].urefs == 0) names[i].st = N_NONE;
    pthread_mutex_unlock(&kmu);
}
static kern_return_t mach_port_type(mach_port_t t, thread_t n, mach_port_type_t *ty)
{
    kern_return_t kr = KERN_SUCCESS; (void)t;
    pthread_mutex_lock(&kmu);
    int i = idx_of(n);
    if (i < 0 || names[i].st == N_NONE) kr = KERN_INVALID_NAME;
    else *ty = names[i].st == N_DEAD ? MACH_PORT_TYPE_DEAD_NAME : MACH_PORT_TYPE_SEND;
    pthread_mutex_unlock(&kmu);
    return kr;
}
static kern_return_t mach_port_get_refs(mach_port_t t, thread_t n, mach_port_right_t r, mach_port_urefs_t *out)
{
    kern_return_t kr = KERN_SUCCESS; (void)t;
    pthread_mutex_lock(&kmu);
    int i = idx_of(n);
    if (i < 0 || names[i].st == N_NONE) kr = KERN_INVALID_NAME;
    else if ((r == MACH_PORT_RIGHT_DEAD_NAME) != (names[i].st == N_DEAD)) *out = 0;
    else *out = names[i].urefs;
    pthread_mutex_unlock(&kmu);
    return kr;
}
static kern_return_t mach_port_mod_refs(mach_port_t t, thread_t n, mach_port_right_t r, mach_port_delta_t d)
{
    kern_return_t kr = KERN_SUCCESS; (void)t;
    pthread_mutex_lock(&kmu);
    int i = idx_of(n);
    if (i < 0 || names[i].st == N_NONE) kr = KERN_INVALID_NAME;
    else if ((r == MACH_PORT_RIGHT_DEAD_NAME) != (names[i].st == N_DEAD)) kr = KERN_INVALID_RIGHT;
    else if (d < 0 && (unsigned)-d > names[i].urefs) kr = KERN_INVALID_VALUE;
    else { names[i].urefs += d; if (!names[i].urefs) names[i].st = N_NONE; }
    pthread_mutex_unlock(&kmu);
    return kr;
}
static kern_return_t thread_info(thread_t n, int f, thread_info_t info, mach_msg_type_number_t *c)
{
    mach_port_type_t ty; (void)f; (void)info; (void)c;
    if (mach_port_type(0, n, &ty)) return MACH_SEND_INVALID_DEST;
    return ty == MACH_PORT_TYPE_DEAD_NAME ? KERN_TERMINATED : KERN_SUCCESS;
}
/* TEB arena: reads of it succeed, anything else fails like an unmapped page */
#define NTEBS 12000
static unsigned char (*teb_arena)[0x1800];
static kern_return_t mach_vm_read_overwrite(mach_port_t t, mach_vm_address_t a, mach_vm_size_t s,
                                            mach_vm_address_t dst, mach_vm_size_t *got)
{
    uintptr_t lo = (uintptr_t)teb_arena, hi = lo + sizeof(*teb_arena) * NTEBS; (void)t;
    if (a < lo || a + s > hi) return 1;
    memcpy((void *)(uintptr_t)dst, (void *)(uintptr_t)a, s); *got = s; return KERN_SUCCESS;
}
static __thread thread_t test_cur_port;
#define pthread_mach_thread_np(x) (test_cur_port)
#define ERR(...) fprintf(stderr, __VA_ARGS__)
static void sys_icache_invalidate(void *p, size_t n) { (void)p; (void)n; }
/* ---- tail gen cap stubs ---- */
static size_t jit_pool_offset, ios_jit_tail_reserved, test_live;
static void ios_tail_free_census( unsigned *free_n, size_t *free_bytes, size_t *live_bytes )
{ if (free_n) *free_n = 0; if (free_bytes) *free_bytes = 0; if (live_bytes) *live_bytes = test_live; }
/* ml2000: jetsam headroom; 0 = unknown, which keeps the wide generation. */
size_t os_proc_available_memory( void ) { return 0; }
'''

harness = r'''
#define MB (1024ul * 1024)
static unsigned char pool[0x4000 * 2];
static unsigned tramp_teb_word(int slot) { return (unsigned)*(uint64_t *)(pool + slot * 16); }

struct sim { thread_t port; uintptr_t teb; int slot; void *tramp; };
static int teb_next;
static uintptr_t new_teb(thread_t owner)
{
    assert(teb_next < NTEBS);
    uintptr_t t = (uintptr_t)teb_arena[teb_next++];
    memset((void *)t, 0, 0x1800);
    *(thread_t *)t = owner;                         /* the name this TEB was registered under */
    return t;
}
static int start(struct sim *s)                     /* init_syscall_frame's order: trampoline, then registry */
{
    s->port = k_create();
    s->teb = new_teb(s->port);
    s->slot = ios_jit_alloc_trampoline_slot();
    ios_jit_set_teb_slot(s->slot, s->teb);
    s->tramp = ios_jit_get_trampoline(s->slot);
    return ios_thread_registry_add(s->port, s->teb, s->tramp);
}
static void finish(struct sim *s, int hook)        /* pthread_exit_wrapper on the thread, then death */
{
    if (hook)
    {
        test_cur_port = s->port; ios_my_slot = s->slot; ios_my_trampoline = s->tramp;
        ios_thread_registry_exit_self();
        assert(!ios_my_trampoline && ios_my_slot == -1);
    }
    k_die(s->port);
}
static void check_lookup(struct sim *s)
{
    uintptr_t teb = 1; void *tr = (void *)1;
    int ok = ios_lookup_thread(s->port, &teb, &tr);
    assert(ok && teb == s->teb && tr == s->tramp);
}
static unsigned live_names(void)
{
    unsigned n = 0;
    for (int i = 0; i < NNAMES; i++) n += names[i].st != N_NONE;
    return n;
}

/* ---- concurrency: writers churn, one reader validates every hit ---- */
static volatile int stop_reader;
static volatile unsigned long reader_hits, reader_bad;
static void *reader(void *arg)
{
    (void)arg;
    unsigned seed = 1;
    while (!stop_reader)
    {
        seed = seed * 1103515245 + 12345;
        thread_t n = name_of((seed >> 8) % 200);
        uintptr_t teb = 0; void *tr = NULL;
        if (ios_lookup_thread(n, &teb, &tr))
        {
            reader_hits++;
            if (!teb || *(volatile thread_t *)teb != n) reader_bad++;
        }
    }
    return NULL;
}
static pthread_mutex_t teb_mu = PTHREAD_MUTEX_INITIALIZER;
static void *writer(void *arg)
{
    long id = (long)arg;
    for (int k = 0; k < 400; k++)
    {
        struct sim s;
        s.port = k_create();
        pthread_mutex_lock(&teb_mu); s.teb = new_teb(s.port); pthread_mutex_unlock(&teb_mu);
        test_cur_port = s.port;
        s.slot = ios_jit_alloc_trampoline_slot();
        ios_jit_set_teb_slot(s.slot, s.teb);
        s.tramp = ios_jit_get_trampoline(s.slot);
        ios_my_slot = s.slot; ios_my_trampoline = s.tramp;
        int idx = ios_thread_registry_add(s.port, s.teb, s.tramp);
        assert(idx >= 0);
        check_lookup(&s);
        if ((k + id) % 7) ios_thread_registry_exit_self();   /* some die without the hook */
        k_die(s.port);
    }
    return NULL;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "new";
    teb_arena = aligned_alloc(0x1000, sizeof(*teb_arena) * NTEBS);
    ios_jit_rx_base_global = pool; ios_jit_rw_base_global = pool;
    ios_threg_read_switches();

    if (!strcmp(mode, "gencap"))
    {
        /* device case: budget 104 MB = pool 512 - head 312 - margin 96, live 32 MB */
        ios_jit_pool_size_global = 512 * MB; jit_pool_offset = 312 * MB; test_live = 32 * MB;
        ios_jit_tail_reserved = 64 * MB;
        printf("budget=%lu cap=%lu\n", ios_tail_budget() / MB, ios_tail_gen_cap() / MB);
        return 0;
    }
    if (!strcmp(mode, "gencap-low"))
    {
        ios_jit_pool_size_global = 512 * MB; jit_pool_offset = 312 * MB; test_live = 48 * MB;
        ios_jit_tail_reserved = 64 * MB;
        size_t low = ios_tail_gen_cap();
        test_live = 32 * MB; ios_jit_tail_reserved = 80 * MB;          /* > 3/4 of the budget committed */
        ios_tail_live_hw = 32 * MB;
        printf("low=%lu committed=%lu\n", low / MB, ios_tail_gen_cap() / MB);
        return 0;
    }

    ios_jit_pool_size_global = 0x4000 * 2;

    if (!strcmp(mode, "rollback-reg"))
    {
        /* MADEIRA_THREAD_REG_RECLAIM=0: append-only, never reused */
        for (int k = 0; k < 600; k++) { struct sim s; int idx = start(&s); if (k >= 512) assert(idx == -1); finish(&s, 1); }
        printf("count=%d\n", ios_thread_registry_count());
        return 0;
    }
    if (!strcmp(mode, "rollback-alias"))
    {
        struct sim a; start(&a);
        uintptr_t teb = 0; void *tr = NULL;
        ios_lookup_thread(0x7777, &teb, &tr);
        printf("alias=%d\n", teb == a.teb);
        return 0;
    }
    if (!strcmp(mode, "rollback-tramp"))
    {
        struct sim s[300];
        for (int k = 0; k < 300; k++) start(&s[k]);
        printf("slot299=%d slot0teb_is_last=%d\n", s[299].slot, tramp_teb_word(0) == (unsigned)s[299].teb);
        return 0;
    }

    /* 1. churn: 20 live threads, 6000 start/exit cycles */
    {
        struct sim live[20];
        for (int i = 0; i < 20; i++) assert(start(&live[i]) >= 0);
        for (int k = 0; k < 6000; k++)
        {
            int v = k % 20;
            finish(&live[v], 1);
            assert(start(&live[v]) >= 0);
            for (int i = 0; i < 20; i++) check_lookup(&live[i]);
        }
        assert(ios_thread_registry_count() <= 22);
        for (int i = 0; i < 20; i++) assert(live[i].slot >= 0 && live[i].tramp);   /* never exhausted: slots come back */
        assert(live_names() <= 22);              /* dead names' pins were dropped: names recycle */
        for (int i = 0; i < 20; i++) finish(&live[i], 1);
        printf("churn ok count=%d tramp_next=%d names=%u created=%lu\n",
               ios_thread_registry_count(), ios_jit_next_slot, live_names(), recycled);
    }

    /* 2. cross-terminated threads (no hook) fill the table; the FULL sweep reclaims them,
     *    except a dead thread still stamped as holding a FEX lock */
    struct sim held;
    {
        struct sim s;
        assert(start(&held) >= 0);
        *(uint64_t *)(held.teb + 0x16f8) = 0xabc;         /* dies holding the FEX shared lock */
        finish(&held, 0);
        while (ios_thread_registry_count() < 512) { assert(start(&s) >= 0); finish(&s, 0); }
        for (int i = 0; i < 512; i++) assert(ios_thread_registry[i].state == IOS_THREG_LIVE);
        assert(start(&s) >= 0);                               /* the FULL sweep made room */
        check_lookup(&s);
        uintptr_t teb = 0; void *tr = NULL;
        assert(ios_lookup_thread(held.port, &teb, &tr) && teb == held.teb);   /* row kept for the census */
        finish(&s, 1);
        printf("sweep ok\n");
    }

    /* 3. true overflow: 512 live threads; no alias, slot 0 untouched */
    {
        *(uint64_t *)(held.teb + 0x16f8) = 0;              /* census reaped it: now reclaimable */
        static struct sim live[520];
        int i, ok = 0, first_slot0_teb;
        for (i = 0; i < 512; i++) if (start(&live[i]) >= 0) ok++;
        first_slot0_teb = tramp_teb_word(0);
        struct sim extra;
        int idx = start(&extra);
        assert(idx == -1);
        assert(extra.slot != 0);                                  /* never handed slot 0 */
        { int none = 0; for (i = 0; i < 512; i++) none += live[i].slot == -1 && !live[i].tramp; assert(none > 200); }
        assert(tramp_teb_word(0) == (unsigned)first_slot0_teb);   /* slot 0 not overwritten */
        uintptr_t teb = 1; void *tr = (void *)1;
        assert(!ios_lookup_thread(extra.port, &teb, &tr) && teb == 0 && tr == NULL);
        for (i = 0; i < 512; i++) check_lookup(&live[i]);
        finish(&extra, 1);
        for (i = 0; i < 512; i++) finish(&live[i], 1);
        printf("overflow ok registered=%d\n", ok);
    }

    /* 4. concurrent writers, one lock-free reader */
    {
        pthread_t r, w[4];
        pthread_create(&r, NULL, reader, NULL);
        for (long i = 0; i < 4; i++) pthread_create(&w[i], NULL, writer, (void *)i);
        for (int i = 0; i < 4; i++) pthread_join(w[i], NULL);
        stop_reader = 1; pthread_join(r, NULL);
        assert(!reader_bad);
        printf("concurrent ok hits=%lu bad=%lu\n", reader_hits, reader_bad);
    }
    return 0;
}
'''

code = prelude + registry + '\n' + tramp + '\n' + gencap + '\n' + harness

with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp) / 'check.c'
    exe = Path(tmp) / 'check'
    c.write_text(code)
    subprocess.run(['cc', '-std=gnu11', '-O1', '-g', '-pthread', '-Wall', '-Wno-unused-function',
                    '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-fno-omit-frame-pointer',
                    str(c), '-o', str(exe)], check=True)

    def run(mode, **env):
        import os
        e = dict(os.environ, **env)
        r = subprocess.run([str(exe), mode], capture_output=True, text=True, env=e)
        assert r.returncode == 0, (mode, r.stdout, r.stderr[-3000:])
        return r

    r = run('new')
    for tag in ('churn ok', 'sweep ok', 'overflow ok registered=512', 'concurrent ok'):
        assert tag in r.stdout, (tag, r.stdout)
    assert '[thread-registry] ml1990 reclaim=1 no-alias=1' in r.stderr, r.stderr[:500]
    assert 'NOT registered; its Mach events MISS (no slot-0 alias) rev=ml1990' in r.stderr
    assert '[tramp-slot] ml1990 EXHAUSTED' in r.stderr
    assert 'no slot-0 alias rev=ml1990' in r.stderr
    print('PASS: registry + trampoline reclamation (' + ' | '.join(l for l in r.stdout.splitlines()) + ')')

    r = run('rollback-reg', MADEIRA_THREAD_REG_RECLAIM='0')
    assert 'count=512' in r.stdout and 'resolve to the slot-0 TEB' in r.stderr, r.stdout
    print('PASS: MADEIRA_THREAD_REG_RECLAIM=0 restores the append-only registry')
    r = run('rollback-alias', MADEIRA_THREAD_REG_NO_ALIAS='0')
    assert 'alias=1' in r.stdout and 'slot-0 fallback' in r.stderr
    r = run('rollback-alias')
    assert 'alias=0' in r.stdout
    print('PASS: MADEIRA_THREAD_REG_NO_ALIAS=0 restores the slot-0 fallback; default misses')
    r = run('rollback-tramp', MADEIRA_TRAMP_RECLAIM='0')
    assert 'slot299=0 slot0teb_is_last=1' in r.stdout, r.stdout
    print('PASS: MADEIRA_TRAMP_RECLAIM=0 restores the slot-0 fallback (and its overwrite)')

    r = run('gencap')
    assert 'budget=104 cap=32' in r.stdout and '[pool-tail] ml1990 wide generation' in r.stderr, (r.stdout, r.stderr)
    r = run('gencap', MADEIRA_TAIL_GEN_WIDE='0')
    assert 'budget=104 cap=16' in r.stdout and 'DISABLED by MADEIRA_TAIL_GEN_WIDE=0' in r.stderr, r.stdout
    r = run('gencap-low')
    assert 'low=8 committed=16' in r.stdout, r.stdout
    print('PASS: gen cap 16 -> 32 MB at the device numbers; low headroom and 3/4-committed unchanged; rollback 16 MB')
