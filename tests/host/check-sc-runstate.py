#!/usr/bin/env python3
"""Execute production RunState tracing hooks and fault-safe diagnostic reads.

Tests nested runs, a controlled two-thread overwrite, bounded ring wrap and
unreadable/partial snapshots. No supplied helper binary is used or executed.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
header = root / 'build/ntdll-unix/ios_sc_runstate_diag.h'


def define(name):
    return int(re.search(r'#define ' + name + r'\s+(0x[\da-fA-F]+|\d+)', native)[1], 0)


start = native.index('static const unsigned char ios_sch_run_trace[')
array = native[start:native.index('};', start) + 2]
blob = bytes(int(x, 16) for x in re.findall(r'0x([\da-fA-F]{2})', array))
assert define('IOS_SCH_TASK') + 64 == define('IOS_SCH_RUN_RING')
assert define('IOS_SCH_RUN_RING') + define('IOS_SCH_RUN_RING_SIZE') <= define('IOS_SCH_CACHE')
assert define('IOS_SCH_TASK_ANY') + 11 <= define('IOS_SCH_RUN_INSTALL')
assert define('IOS_SCH_RUN_INSTALL') + len(blob) <= 0x181000
assert int(re.search(r'#define IOS_SC_RUN_RING_RVA (0x[\da-f]+)', header.read_text())[1], 0) == define('IOS_SCH_RUN_RING')
# 2.4.0.296 has no room for the trace: its build entry installs no RunState
# hook and its patch never names the ring, which the diagnostic gate rejects.
later = native[native.index('static const struct ios_sch_blob ios_sch296_blob[]'):
               native.index('static const struct ios_sch_build ios_sch_builds[]')]
assert 'run_trace' not in later and 'RUN_' not in later
assert not re.search(r'#define IOS_SCH296_RUN', native)
assert define('IOS_SCH296_STAMP') == 0x6ae5e38b and define('IOS_SCH296_SIZE') == 0x26d000

with tempfile.TemporaryDirectory(prefix='madeira-sc-runstate-') as name:
    folder = Path(name)
    linker = folder / 'trace.ld'
    linker.write_text('SECTIONS { . = 0x1740e0; .fixture : { *(.fixture) }\n'
                      ' . = 0x%x; .text : { *(.text) } }\n' % define('IOS_SCH_RUN_INSTALL') +
                      'install_return = 0x174128; restore_return = 0x174134;\n'
                      'get_thread_id = 0x1814a8; trace_ring = 0x%x;\n' % define('IOS_SCH_RUN_RING'))
    objects = []
    for source in ('sc-runstate-trace', 'sc-pump-run-fixture'):
        obj = folder / (source + '.o')
        subprocess.run(['as', '--64', str(root / 'tests/host' / (source + '.S')), '-o', str(obj)], check=True)
        objects.append(str(obj))
    subprocess.run(['ld', '-T', str(linker), *objects, '-o', str(folder / 'trace.elf')], check=True)
    for section in ('text', 'fixture'):
        subprocess.run(['objcopy', '-O', 'binary', '--only-section=.' + section,
                        str(folder / 'trace.elf'), str(folder / (section + '.bin'))], check=True)
    assert (folder / 'text.bin').read_bytes() == blob
    fixture = (folder / 'fixture.bin').read_bytes()
    assert fixture[0x41:0x48] == bytes.fromhex('48 89 41 40 48 8b 01')
    assert fixture[0x4b:0x54] == bytes.fromhex('48 89 7b 40 48 8b 5c 24 50')
    symbols = subprocess.check_output(['nm', str(folder / 'trace.elf')], text=True)
    for symbol, expected in (('sc_run_install', define('IOS_SCH_RUN_INSTALL')),
                             ('sc_run_restore', define('IOS_SCH_RUN_RESTORE')),
                             ('fixture_install', 0x174121), ('fixture_restore', 0x17412b)):
        assert int(re.search(r'([\da-f]+) T ' + symbol, symbols)[1], 16) == expected
    print('PASS: production trace bytes, hook return RVAs and disjoint code/data ranges', flush=True)

    code = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <signal.h>
#include <setjmp.h>
#include <sys/mman.h>
#define ABI __attribute__((ms_abi))
typedef uint64_t mach_vm_address_t, mach_vm_size_t;
#define KERN_SUCCESS 0
static int mach_task_self(void) { return 0; }
static _Thread_local sigjmp_buf *active;
static int read_failure;
static void fault_handler(int sig) { if (active) siglongjmp(*active, 1); _Exit(128 + sig); }
static int mach_vm_read_overwrite(int task, mach_vm_address_t addr, volatile size_t size,
                                  mach_vm_address_t dest, mach_vm_size_t *got)
{
    (void)task;
    *got = 0;
    if (read_failure == 1) return 1;
    sigjmp_buf probe;
    active = &probe;
    if (sigsetjmp(probe, 1)) { active = NULL; return 1; }
    size_t count = read_failure == 2 ? size / 2 : size;
    memcpy((void *)(uintptr_t)dest, (const void *)(uintptr_t)addr, count);
    active = NULL;
    *got = count;
    return 0;
}
static struct { void *Peb; } teb;
#define NtCurrentTeb() (&teb)
static char *image, *pool;
void *ios_jit_translate_addr_for_owner(void *addr, void *owner)
{ (void)owner; return addr == image ? pool : addr; }
unsigned long long ios_jit_module_base_for_va(unsigned long long addr, unsigned long long *size)
{
    uintptr_t base = (uintptr_t)image;
    if (addr >= base && addr - base < 0x244000) { *size = 0x244000; return base; }
    return 0;
}
#include "ios_sc_runstate_diag.h"
_Static_assert(sizeof(struct ios_sc_run_record) == 32, "trace record ABI");
_Static_assert(sizeof(struct ios_sc_run_ring) == 520, "trace ring ABI");
struct RunState { void *delegate, *dispatcher; uint8_t quit, padding[3]; uint32_t depth; };
struct Pump { void **vtable; char pad[0x38]; struct RunState *state; uintptr_t iocp; };
_Static_assert(offsetof(struct Pump, state) == 0x40, "Win pump state offset");
static _Thread_local uint32_t tid;
static uint32_t ABI get_tid(void) { return tid; }
static void (ABI *run)(struct Pump *, void *);
static int mode, calls;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static int first_entered, second_entered, first_left;
static void ABI body(struct Pump *p)
{
    assert(p->state && p->state->delegate == (void *)(uintptr_t)tid && !p->state->dispatcher && !p->state->quit);
    if (!mode) {
        calls++;
        if (p->state->depth == 1) {
            struct RunState *outer = p->state;
            run(p, (void *)(uintptr_t)tid);
            assert(p->state == outer);
        } else assert(p->state->depth == 2);
    } else {
        pthread_mutex_lock(&lock);
        if (tid == 0x101) {
            first_entered = 1;
            pthread_cond_broadcast(&cond);
            while (!second_entered) pthread_cond_wait(&cond, &lock);
        } else {
            second_entered = 1;
            pthread_cond_broadcast(&cond);
            while (!first_left) pthread_cond_wait(&cond, &lock);
            /* The first thread restored NULL while this run was still live.
             * Record the signature without dereferencing NULL or hiding it. */
            assert(!p->state);
        }
        pthread_mutex_unlock(&lock);
    }
}
static void *worker(void *arg)
{
    struct Pump *p = arg;
    tid = 0x202;
    pthread_mutex_lock(&lock);
    while (!first_entered) pthread_cond_wait(&cond, &lock);
    pthread_mutex_unlock(&lock);
    run(p, (void *)(uintptr_t)tid);
    return NULL;
}
static void patch(size_t site, size_t dest, size_t span)
{
    int32_t disp = (int32_t)(dest - site - 5);
    image[site] = (char)0xe9;
    memcpy(image + site + 1, &disp, 4);
    memset(image + site + 5, 0x90, span - 5);
}
int main(void)
{
    struct sigaction sa = {0}; sa.sa_handler = fault_handler;
    sigemptyset(&sa.sa_mask);
    assert(!sigaction(SIGSEGV, &sa, NULL)); assert(!sigaction(SIGBUS, &sa, NULL));
    image = mmap(NULL, 0x244000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    pool = mmap(NULL, 0x244000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(image != MAP_FAILED && pool != MAP_FAILED);
    memcpy(image + 0x1740e0, fixture, sizeof(fixture));
    memcpy(image + TRACE_ENTRY, trace, sizeof(trace));
    patch(0x174121, TRACE_ENTRY, 7); patch(0x17412b, TRACE_RESTORE, 9);
    *(uintptr_t *)(image + 0x1814a8) = (uintptr_t)get_tid;
    assert(!mprotect(image + 0x1000, 0x180000, PROT_READ | PROT_EXEC));
    run = (void *)(image + 0x1740e0);
    void *vtable[6] = {0}; vtable[5] = body;
    struct Pump p = {vtable, {0}, NULL, 0x1234};
    struct ios_sc_run_ring *ring = (void *)(image + IOS_SC_RUN_RING_RVA);
    tid = 0x101;
    run(&p, (void *)(uintptr_t)tid);
    assert(calls == 2 && !p.state && ring->counter == 4);
    assert(ring->record[0].operation == 1 && ring->record[1].operation == 1);
    assert(ring->record[2].operation == 2 && ring->record[2].state == ring->record[0].state);
    assert(ring->record[3].operation == 2 && !ring->record[3].state);
    mode = 1;
    pthread_t thread;
    assert(!pthread_create(&thread, NULL, worker, &p));
    run(&p, (void *)(uintptr_t)tid);
    pthread_mutex_lock(&lock); first_left = 1; pthread_cond_broadcast(&cond); pthread_mutex_unlock(&lock);
    assert(!pthread_join(thread, NULL));
    assert(ring->counter == 8);
    assert(ring->record[6].operation == 2 && ring->record[6].tid == 0x101 && !ring->record[6].state);
    assert(ring->record[7].operation == 2 && ring->record[7].tid == 0x202);
    p.state = NULL; mode = 0;
    for (int i = 0; i < 10; i++) run(&p, (void *)(uintptr_t)tid);
    assert(ring->counter == 48);
    for (int i = 0; i < 16; i++) {
        assert(ring->record[i].sequence >= 33 && ring->record[i].sequence <= 48);
        assert(ring->record[i].tid == tid && ring->record[i].pump == (uintptr_t)&p);
    }
    puts("PASS: production hooks replay Run, preserve nested states, identify cross-thread NULL restore and wrap at 16 records");

    unsigned char out[32], before[32]; memset(out, 0xa5, sizeof(out)); memcpy(before, out, sizeof(out));
    assert(!ios_sc_diag_read(0, out, sizeof(out)) && !memcmp(out, before, sizeof(out)));
    read_failure = 1; assert(!ios_sc_diag_read((uintptr_t)&p, out, sizeof(out)) && !memcmp(out, before, sizeof(out)));
    read_failure = 2; assert(!ios_sc_diag_read((uintptr_t)&p, out, sizeof(out)) && !memcmp(out, before, sizeof(out)));
    read_failure = 0;
    char *none = mmap(NULL, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(none != MAP_FAILED);
    assert(!ios_sc_diag_read((uintptr_t)none, out, sizeof(out)) && !memcmp(out, before, sizeof(out)));
    assert(!munmap(none, 4096));
    assert(!ios_sc_diag_read((uintptr_t)none, out, sizeof(out)) && !memcmp(out, before, sizeof(out)));
    assert(!ios_sc_diag_read(UINT64_MAX - 4, out, sizeof(out)));
    image[0] = 'M'; image[1] = 'Z';
    *(uint32_t *)(image + 0x3c) = 0x80;
    memcpy(image + 0x80, "PE\0\0", 4);
    *(uint16_t *)(image + 0x84) = 0x8664;
    *(uint32_t *)(image + 0x88) = 0x6a86d563;
    *(uint16_t *)(image + 0x98) = 0x20b;
    *(uint32_t *)(image + 0xd0) = 0x244000;
    assert(ios_sc_diag_helper((uintptr_t)image, (uintptr_t)image + 0x173be4));
    assert(!ios_sc_diag_helper((uintptr_t)image, (uintptr_t)image + 0x7e60));
    *(uint32_t *)(image + 0x88) ^= 1;
    assert(!ios_sc_diag_helper((uintptr_t)image, (uintptr_t)image + 0x173be4));
    *(uint32_t *)(image + 0x88) ^= 1;
    /* 2.4.0.296 (ios_sch_builds[1]) has no RunState trace or ring: never read one. */
    *(uint32_t *)(image + 0x88) = 0x6ae5e38b; *(uint32_t *)(image + 0xd0) = 0x26d000;
    assert(!ios_sc_diag_helper((uintptr_t)image, (uintptr_t)image + 0x173be4));
    *(uint32_t *)(image + 0xd0) = 0x244000;
    assert(!ios_sc_diag_helper((uintptr_t)image, (uintptr_t)image + 0x173be4));
    *(uint32_t *)(image + 0x88) = 0x6a86d563;
    memcpy(pool + IOS_SC_RUN_RING_RVA, ring, sizeof(*ring));
    uint64_t stack[256] = {0}; stack[12] = (uintptr_t)image + 0x17412b;
    ios_sc_runstate_dump((uintptr_t)image, (uintptr_t)image + 0x173be4, (uintptr_t)&p, (uintptr_t)stack);
    puts("PASS: exact helper/fault gate, protected/unmapped/partial reads and view/pool diagnostics");
    assert(!munmap(image, 0x244000)); assert(!munmap(pool, 0x244000));
    return 0;
}
'''
    data = '#include <stddef.h>\n#define TRACE_ENTRY 0x%x\n#define TRACE_RESTORE 0x%x\n' % (
        define('IOS_SCH_RUN_INSTALL'), define('IOS_SCH_RUN_RESTORE'))
    for variable, payload in (('trace', blob), ('fixture', fixture)):
        data += 'static const unsigned char %s[] = {%s};\n' % (variable, ','.join(str(b) for b in payload))
    driver = folder / 'test.c'
    driver.write_text(data + code)
    binary = folder / 'test'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                    '-fsanitize=address,undefined', '-g', '-pthread', '-I', str(header.parent),
                    str(driver), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True,
                            env={**os.environ, 'ASAN_OPTIONS': 'handle_segv=0:handle_sigbus=0'})
    if result.returncode:
        print(result.stderr)
        result.check_returncode()
    print(result.stdout, end='')
    assert '[sc-runst] fault helper=' in result.stderr
    assert 'view ring counter=48' in result.stderr and 'pool ring counter=48' in result.stderr
    assert 'stack+0x60 image=' in result.stderr
    assert len(result.stderr.splitlines()) <= 40, 'unbounded diagnostic output'
