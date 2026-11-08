#!/usr/bin/env python3
"""The stale-VA table keeps tracking new hot VAs after it fills; no Wine runs.

Slay the Spire 2 on the Wave 2 test build: Steam's dockhost queued 155 stale
VAs and filled the old 256-slot table. The game's main thread then called
into its ucrtbase copy through dozens of stale PE VAs in turn. Every newcomer
evicted the coldest entry, which was always the previous newcomer at 1 hit,
so none reached the 256-fault threshold: 3.3 million exec faults in 35 s,
nothing healed, no window.

Compiles the production ios_stale_va_enqueue (build/ntdll-unix/
signal_arm64_ios.c) and checks:
  - 300 VAs queued earlier and 3000 cold one-shots, then 40 VAs faulting
    round-robin: all 40 are queued, each exactly once;
  - a queued VA faulting again is not queued twice;
  - a full heal queue retries later instead of losing the VA;
  - boot one-shots (< 256 faults) are never queued.
Needs python3 and a C compiler.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()
start = source.index('#define IOS_STALE_VA_MAX')
end = source.index('static void *ios_stale_va_scanner( void *arg )')
table = source[start:end]
assert 'IOS_STALE_VA_MAX 4096' in table and 'IOS_STALE_VA_PROBE' in table
assert 'ios_stale_va_queue[ios_stale_va_head % IOS_STALE_VA_QUEUE]' in source
assert '[stale-heal] table %d slots hashed' in source

code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static int queued_logs;
#define fprintf(f, ...) (queued_logs++)
''' + table + r'''
#undef fprintf
static int count_queued(uint64_t va)
{
    int n = 0, i;
    for (i = ios_stale_va_head; i != ios_stale_va_tail; i++)
        if (ios_stale_va_queue[i % IOS_STALE_VA_QUEUE] == va) n++;
    return n;
}
static void drain(void) { ios_stale_va_head = ios_stale_va_tail; }
int main(void)
{
    int i, r;
    /* Earlier processes: 300 hot VAs, all queued and healed. */
    for (i = 0; i < 300; i++)
    {
        uint64_t va = 0x71fc000000ull + (uint64_t)i * 0x1234;
        for (r = 0; r < 256; r++) ios_stale_va_enqueue(va);
        if (count_queued(va) != 1) { printf("early VA %d not queued\n", i); return 1; }
        drain();
    }
    /* Boot one-shots everywhere. */
    for (i = 0; i < 3000; i++)
        for (r = 0; r < 3; r++) ios_stale_va_enqueue(0x7000000000ull + (uint64_t)i * 0x40);
    assert(ios_stale_va_tail == ios_stale_va_head);       /* none of them queued */
    /* The game: 40 ucrtbase VAs, round-robin, 300 faults each. */
    int before = ios_stale_va_tail;
    for (r = 0; r < 300; r++)
        for (i = 0; i < 40; i++)
            ios_stale_va_enqueue(0x71f52b0000ull + 0x2c190 + (uint64_t)i * 0x1d4);
    for (i = 0; i < 40; i++)
    {
        uint64_t va = 0x71f52b0000ull + 0x2c190 + (uint64_t)i * 0x1d4;
        if (count_queued(va) != 1) { printf("game VA %d queued %d times\n", i, count_queued(va)); return 1; }
    }
    assert(ios_stale_va_tail - before == 40);
    drain();
    /* Queued once: more faults do not queue it again. */
    for (r = 0; r < 1000; r++) ios_stale_va_enqueue(0x71f52b0000ull + 0x2c190);
    assert(ios_stale_va_tail == ios_stale_va_head);
    /* Full heal queue: the VA waits and is queued once there is room. */
    for (i = 0; i < IOS_STALE_VA_QUEUE; i++)
        for (r = 0; r < 256; r++) ios_stale_va_enqueue(0x7180000000ull + (uint64_t)i * 0x88);
    assert(ios_stale_va_tail - ios_stale_va_head == IOS_STALE_VA_QUEUE);
    uint64_t late = 0x7190000000ull;
    for (r = 0; r < 256; r++) ios_stale_va_enqueue(late);
    assert(count_queued(late) == 0);
    drain();
    ios_stale_va_enqueue(late);
    assert(count_queued(late) == 1);
    puts("stale-heal table OK");
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-stale-heal-table-') as tmp:
    c = Path(tmp) / 'check.c'
    exe = Path(tmp) / 'check'
    c.write_text(code)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-variable', '-Wno-unused-function', '-O1', '-fsanitize=address,undefined',
                    str(c), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
