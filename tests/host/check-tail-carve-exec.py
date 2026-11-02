#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Ported from a community host check; anchors are the merged engine code's.
"""A tail carve whose first pages cannot execute is refused, so FEX halves its code buffer.

Several 32-bit programs ended in a redelivery storm of EXECUTE faults inside the JIT pool: FEX's
128 MB code buffer (a tail carve) lay on pool pages that had lost EXEC for good (vm_region:
prot=3 max_prot=3), its first block faulted at carve+0x1c, and the guest exception dispatcher
compiled into the same page faulted again until the redelivery guard ended the process.
virtual_ios.c now looks at the first 2 MB of a fresh tail carve and refuses one with a
non-exec page (STATUS_NO_MEMORY, the way an exhausted tail is refused), so FEX's CodeBuffer
constructor halves the request and the next carve lies above the dead run.

Source checks (every host) hold the shape: the check runs in the fresh-tail branch only,
before anything is written, gives the reservation back, leaves a carve whose first 2 MB can
execute exactly as it was, and logs only when it refuses (or a deeper dead page is kept).
The helper is then compiled and run against real Mach memory on a Darwin host (a region whose
max protection was lowered to RW stands for a lost-EXEC page); other hosts skip that part.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
ok = True


def check(what, cond, detail=''):
    global ok
    print(('ok   ' if cond else 'FAIL ') + what + (('\n     ' + detail) if (detail and not cond) else ''))
    ok = ok and bool(cond)


def function(signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


helper = function('static int ios_pool_range_first_nonexec(')
check('the helper never writes, maps or protects memory',
      all(m not in helper for m in ('mprotect(', 'vm_protect(', 'mmap(', 'memset(', 'memcpy(', 'madvise(')))
check('a failed region query never refuses a carve', 'KERN_SUCCESS) return 0;' in helper)

marker = '/* tail-carve exec check: REFUSE A CARVE WHOSE FIRST PAGES CANNOT EXECUTE.'
check('the check exists exactly once', source.count(marker) == 1)
site = source[source.index(marker):]
branch = site[:site.index('iOS-Madeira: pre-fill the buffer with NOPs')]
before = source[source.rindex('void *jit_rx = (char *)ios_jit_rx_base_global + pool_tail_off;', 0, source.index(marker)):
                source.index(marker)]
check('it sits in the fresh-tail branch (the one that carves at pool_tail_off), before *ret is set',
      '*ret = jit_rx;' not in before and branch.count('*ret = jit_rx;') == 1
      and branch.index('ios_pool_range_first_nonexec( pool_tail_off') < branch.index('*ret = jit_rx;'))
check('the prefix is 2 MB (what the four logs prove)', 'CARVE_EXEC_PREFIX = 0x200000' in branch)
check('env.MADEIRA_TAIL_CARVE_EXEC_CHECK = 0 turns the check off (read once)',
      'getenv( "MADEIRA_TAIL_CARVE_EXEC_CHECK" )' in branch and "carve_check = !(e && e[0] == '0');" in branch
      and 'if (carve_check &&' in branch)
refuse = branch[branch.index('ios_pool_range_first_nonexec( pool_tail_off, alloc_size, CARVE_EXEC_PREFIX'):
                branch.index('if (alloc_size > CARVE_EXEC_PREFIX)')]
check('a refusal gives the reservation back, logs once-capped and returns STATUS_NO_MEMORY',
      'ios_pool_tail_unreserve( &ios_jit_tail_reserved, reserve_offset + alloc_size, tail_added,' in refuse
      and 'nonexec_n++ < 16' in refuse and 'return STATUS_NO_MEMORY;' in refuse)
check('a refusal writes no NOP prefill and records no carve',
      'rw_words' not in refuse and 'ios_tail_carves[' not in refuse and 'ios_tail_carve_n' not in refuse)
check('a dead page deeper than the prefix only logs',
      'return' not in branch[branch.index('if (alloc_size > CARVE_EXEC_PREFIX)'):])
check('the other tail grants (free-list reuse, region C, reclaimed head range) are untouched',
      source.count('tail carve NOT EXECUTABLE') == 1)

if sys.platform != 'darwin':
    print('skip host run: needs Mach (macOS)')
    sys.exit(0 if ok else 1)
cc = shutil.which(os.environ.get('CC', 'cc')) or shutil.which('clang') or shutil.which('gcc')
if not cc:
    print('SKIP host compile: no C compiler')
    sys.exit(0 if ok else 1)

harness = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#define MB ((size_t)1 << 20)
static void *ios_jit_rx_base_global;
''' + helper + r'''
int main(void)
{
    mach_vm_address_t base = 0;
    const size_t size = 64 * MB, pg = vm_page_size;
    size_t bad = 99; unsigned cur = 0, max = 0;

    assert(mach_vm_allocate(mach_task_self(), &base, size, VM_FLAGS_ANYWHERE) == KERN_SUCCESS);
    ios_jit_rx_base_global = (void *)base;

    /* all pages can execute (max RWX): nothing found */
    assert(!ios_pool_range_first_nonexec(0, 32 * MB, 16 * MB, &bad, &cur, &max));
    assert(bad == 99);

    /* a page whose max protection lost EXEC at +20 MB: outside a 16 MB prefix, inside a 32 MB one */
    assert(vm_protect(mach_task_self(), base + 20 * MB, pg, TRUE, VM_PROT_READ | VM_PROT_WRITE) == KERN_SUCCESS);
    assert(!ios_pool_range_first_nonexec(0, 32 * MB, 16 * MB, &bad, &cur, &max));
    assert(ios_pool_range_first_nonexec(0, 32 * MB, 32 * MB, &bad, &cur, &max));
    assert(bad == 20 * MB && max == (VM_PROT_READ | VM_PROT_WRITE));
    /* the same page seen from a carve that starts 4 MB higher */
    assert(ios_pool_range_first_nonexec(4 * MB, 28 * MB, 28 * MB, &bad, &cur, &max) && bad == 16 * MB);
    /* a carve ending just below it */
    assert(!ios_pool_range_first_nonexec(0, 20 * MB, 20 * MB, &bad, &cur, &max));

    /* the very first page: the reported case */
    assert(vm_protect(mach_task_self(), base, pg, TRUE, VM_PROT_READ | VM_PROT_WRITE) == KERN_SUCCESS);
    bad = 99;
    assert(ios_pool_range_first_nonexec(0, 128 * MB > size ? size : 128 * MB, 16 * MB, &bad, &cur, &max));
    assert(bad == 0);

    /* a gap (unmapped range) is not a refusal */
    assert(mach_vm_deallocate(mach_task_self(), base + 8 * MB, 8 * MB) == KERN_SUCCESS);
    assert(!ios_pool_range_first_nonexec(8 * MB, 8 * MB, 16 * MB, &bad, &cur, &max));
    puts("PASS: first non-exec page found at its offset, prefix honoured, gaps and clean ranges pass");
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='tail-carve-exec-') as directory:
    temp = Path(directory)
    unit = temp / 'test.c'
    unit.write_text(harness)
    exe = temp / 'test'
    subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror', str(unit), '-o', str(exe)],
                   check=True)
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    check('the helper finds a lost-EXEC page in real Mach memory', r.returncode == 0, r.stderr)
sys.exit(0 if ok else 1)
