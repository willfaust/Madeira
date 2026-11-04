#!/usr/bin/env python3
"""Execute the bounded Win64 IPC rebind diagnostic; no supplied binary runs."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def sch_table(name):
    start = native.index(' ' + name + '[] =')
    return native[start:native.index('\n};', start)]


def define(name):
    return int(re.search(r'#define ' + name + r'\s+(0x[\da-fA-F]+|\d+)', native)[1], 0)


start = native.index('static const unsigned char ios_sch_ipc_rebind[')
array = native[start:native.index('};', start) + 2]
blob = bytes(int(h, 16) for h in re.findall(r'0x([\da-fA-F]{2})', array))
# The rebind trace is the first build's alone (ios_sch_builds[0]). 2.4.0.296's
# tables leave its Connect routine unhooked; that build keeps only the channel
# retention hook in its Channel Response (check-sc-ipc-split.py executes it).
first_blob, first_hook = sch_table('ios_sch_blob'), sch_table('ios_sch_hook')
later_blob, later_hook = sch_table('ios_sch296_blob'), sch_table('ios_sch296_hook')
assert '{ IOS_SCH_IPC_TRACE, ios_sch_ipc_rebind, sizeof(ios_sch_ipc_rebind), 0, 0,' in first_blob
assert '{ IOS_SCH_IPC_CONNECT, IOS_SCH_IPC_TRACE, 5, 0xe9, 0 },' in first_hook
assert 'rebind' not in later_blob and 'IPC_CONNECT' not in later_hook and 'IPC_TRACE' not in later_hook
assert '{ IOS_SCH296_RENDER_CHANNEL_KEEP, IOS_SCH296_RENDER_CHANNEL_THUNK, 7, 0xe9, 1 },' in later_hook
assert not re.search(r'#define IOS_SCH296_IPC_(TRACE|COUNT)', native)

with tempfile.TemporaryDirectory(prefix='madeira-sc-ipc-') as name:
    folder = Path(name)
    symbols = {'rebind_counter': define('IOS_SCH_IPC_COUNT'), 'helper_log': 0x111340,
               'connect_return': define('IOS_SCH_IPC_CONNECT') + 5}
    linker = folder / 'trace.ld'
    linker.write_text('SECTIONS { . = %d; .text : { *(.text) } }\n' % define('IOS_SCH_IPC_TRACE') +
                      '\n'.join('%s = %d;' % item for item in symbols.items()) + '\n')
    subprocess.run(['as', '--64', str(root / 'tests/host/sc-ipc-rebind.S'),
                    '-o', str(folder / 'trace.o')], check=True)
    subprocess.run(['ld', '-T', str(linker), str(folder / 'trace.o'),
                    '-o', str(folder / 'trace.elf')], check=True)
    subprocess.run(['objcopy', '-O', 'binary', '--only-section=.text',
                    str(folder / 'trace.elf'), str(folder / 'trace.bin')], check=True)
    assert (folder / 'trace.bin').read_bytes() == blob
    assert define('IOS_SCH_RENDER_DRAIN') + 31 <= define('IOS_SCH_IPC_TRACE')
    assert define('IOS_SCH_IPC_TRACE') + len(blob) <= 0x181000
    assert define('IOS_SCH_RUN_RING') + define('IOS_SCH_RUN_RING_SIZE') <= define('IOS_SCH_IPC_COUNT')
    assert define('IOS_SCH_IPC_COUNT') + 4 <= define('IOS_SCH_CACHE')

    source = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/mman.h>
#define ABI __attribute__((ms_abi))
struct Manager {
    unsigned char prefix[0x50];
    union { uint16_t inline_name[8]; const uint16_t *heap_name; } name;
    uint64_t size, capacity;
};
_Static_assert(offsetof(struct Manager, name) == 0x50 &&
               offsetof(struct Manager, capacity) == 0x68, "wstring offsets");
static uint16_t channel0[] = {'r','g','s','c','_','i','p','c','_','c','8','_','c','h','a','n','n','e','l','_','0',0};
static uint16_t channel1[] = {'r','g','s','c','_','i','p','c','_','c','8','_','c','h','a','n','n','e','l','_','1',0};
static struct Manager manager;
static unsigned int logs, bodies;
static _Thread_local uintptr_t logged_caller;
static _Thread_local int expect_inline;
static void (ABI *connect_entry)(struct Manager *, const uint16_t *, unsigned int, uintptr_t);
static void ABI logger(unsigned int level, const char *format, ...)
{
    __builtin_ms_va_list args;
    __builtin_ms_va_start(args, format);
    struct Manager *m = __builtin_va_arg(args, struct Manager *);
    const uint16_t *old = __builtin_va_arg(args, const uint16_t *);
    const uint16_t *requested = __builtin_va_arg(args, const uint16_t *);
    uintptr_t caller = __builtin_va_arg(args, uintptr_t);
    __builtin_ms_va_end(args);
    assert(!level && !strcmp(format, "[sc-ipc] rebind manager=%p old=%.80ls new=%.80ls caller=%p"));
    assert(m == &manager && requested == channel1 && caller);
    assert(old == (expect_inline ? m->name.inline_name : channel0));
    logged_caller = caller;
    __sync_fetch_and_add(&logs, 1);
    /* The diagnostic must restore volatile vector state clobbered by a logger. */
    __asm__ volatile("pxor %%xmm0, %%xmm0; pxor %%xmm1, %%xmm1; pxor %%xmm2, %%xmm2;"
                     "pxor %%xmm3, %%xmm3; pxor %%xmm4, %%xmm4; pxor %%xmm5, %%xmm5"
                     : : : "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5");
}
static void ABI original_continuation(struct Manager *m, const uint16_t *requested,
                                      unsigned int flag, uintptr_t cookie)
{
    assert(m == &manager && requested == channel1 && flag == 0x7a && cookie == 0x123456789abcdef0ULL);
    if (logged_caller) assert(logged_caller == (uintptr_t)__builtin_return_address(0));
    __sync_fetch_and_add(&bodies, 1);
}
static void stub(char *image, size_t rva, uintptr_t target)
{
    unsigned char code[12] = {0x48,0xb8,0,0,0,0,0,0,0,0,0xff,0xe0};
    memcpy(code + 2, &target, sizeof(target));
    memcpy(image + rva, code, sizeof(code));
}
static void *worker(void *unused)
{
    (void)unused;
    for (unsigned int i = 0; i < 12; i++)
        connect_entry(&manager, channel1, 0x7a, 0x123456789abcdef0ULL);
    return NULL;
}
''' + array + r'''
int main(void)
{
    char *image = mmap(NULL, 0x244000, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(image != MAP_FAILED);
    memcpy(image + TRACE_ENTRY, ios_sch_ipc_rebind, sizeof(ios_sch_ipc_rebind));
    int32_t disp = TRACE_ENTRY - CONNECT_ENTRY - 5;
    image[CONNECT_ENTRY] = (char)0xe9;
    memcpy(image + CONNECT_ENTRY + 1, &disp, sizeof(disp));
    stub(image, 0x111340, (uintptr_t)logger);
    stub(image, CONNECT_ENTRY + 5, (uintptr_t)original_continuation);
    assert(!mprotect(image + 0x1000, 0x180000, PROT_READ | PROT_EXEC));
    connect_entry = (void *)(image + CONNECT_ENTRY);
    unsigned int *counter = (void *)(image + COUNTER);
    expect_inline = 1;
    manager.capacity = 7;
    struct Manager before = manager;
    connect_entry(&manager, channel1, 0x7a, 0x123456789abcdef0ULL);
    assert(logs == 1 && bodies == 1 && *counter == 1 && !memcmp(&manager, &before, sizeof(manager)));
    expect_inline = 0;
    manager.name.heap_name = channel0;
    manager.size = 21;
    manager.capacity = 31;
    before = manager;
    for (unsigned int i = 0; i < 11; i++)
        connect_entry(&manager, channel1, 0x7a, 0x123456789abcdef0ULL);
    assert(logs == 8 && bodies == 12 && *counter == 8 && !memcmp(&manager, &before, sizeof(manager)));
    puts("PASS: production rebind hook preserves connect arguments, logs inline/heap names and the actual caller, capped at eight");
    *counter = logs = bodies = 0;
    logged_caller = 0;
    pthread_t threads[16];
    for (unsigned int i = 0; i < 16; i++) assert(!pthread_create(&threads[i], NULL, worker, NULL));
    for (unsigned int i = 0; i < 16; i++) assert(!pthread_join(threads[i], NULL));
    assert(logs == 8 && bodies == 16 * 12 && *counter >= 8 && *counter <= 16 * 12);
    assert(!memcmp(&manager, &before, sizeof(manager)));
    assert(!munmap(image, 0x244000));
    puts("PASS: concurrent diagnostic emits eight records and every original connect still runs");
}
'''
    source = source.replace('TRACE_ENTRY', hex(define('IOS_SCH_IPC_TRACE')))
    source = source.replace('CONNECT_ENTRY', hex(define('IOS_SCH_IPC_CONNECT')))
    source = source.replace('COUNTER', hex(define('IOS_SCH_IPC_COUNT')))
    driver = folder / 'test.c'
    driver.write_text(source)
    binary = folder / 'test'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-O2', '-fsanitize=address,undefined', '-g', '-pthread', str(driver),
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
