#!/usr/bin/env python3
"""thread-start-pe-va: a new thread's start routine is reported as the image VA, not the JIT-pool copy address.

StarCraft x64 (log 8976beb7): ARM64EC d3d11.dll runs from its pool copy, takes &func there and creates threads with
start=<pool copy>. ClientSdk then rewrites the first byte of a thread start that is inside no module, and the thread
dies in BaseThreadInitThunk (c000001d). build/ntdll-unix/thread_ios.c now maps a start address inside a pool image
copy back to pe_base + offset. Source check (python3); THREAD_IOS_SRC overrides the file path.

Checked:
  1. ios_thread_start_pe_va exists, uses ios_jit_reverse_translate, leaves FEX's own module and unmapped addresses alone;
  2. switch MADEIRA_THREAD_START_PE_VA=0 turns it off; default on;
  3. log "[thread-start] pool %p -> image %p" capped at 32;
  4. NtCreateThreadEx calls it on `start` for the current process only (after the remote-process APC branch), before
     thread_data->start is stored (so server_init_thread entry = Win32StartAddress and the initial X0 both see it);
  5. a model of the translation behaves: pool address -> pe_base+offset, others unchanged.
"""
from pathlib import Path
import os, re, sys

root = Path(__file__).resolve().parents[2]
path = Path(os.environ.get('THREAD_IOS_SRC') or root / 'build/ntdll-unix/thread_ios.c')
src = path.read_text()

m = re.search(r'static void \*ios_thread_start_pe_va\( void \*start \)\n\{(.*?)\n\}\n', src, re.S)
assert m, 'ios_thread_start_pe_va not found'
body = m.group(1)
assert 'ios_jit_reverse_translate(' in body
assert 'ios_jit_pool_pc_is_fex(' in body and 'return start;' in body
assert 'getenv( "MADEIRA_THREAD_START_PE_VA" )' in body and "e[0] == '0'" in body
assert src.count('"[thread-start] pool %p -> image %p\\n"') == 1
assert re.search(r'__sync_add_and_fetch\( &logged, 1 \) <= 32', body), 'log must be capped at 32'
assert '!va || !mod' in body

fn = src[src.index('NTSTATUS WINAPI NtCreateThreadEx('):]
fn = fn[:fn.index('\n}\n')]
call = fn.index('start = ios_thread_start_pe_va( start );')
remote = fn.index('if (process != NtCurrentProcess())')
store = fn.index('thread_data->start = start;')
assert remote < call < store, 'translation must follow the remote-process branch and precede thread_data->start'
assert fn.count('ios_thread_start_pe_va(') == 1
# the [thr-create] forensic line still logs the address the creator passed (before translation)
assert fn.index('[thr-create] creator_teb') < call

# model: mapping table lookup as in ios_jit_reverse_translate
maps = [(0x16f468000, 0x70ebd80000, 0x200000)]  # (jit_base, pe_base, size)
def translate(a, enabled=True, is_fex=False):
    if not enabled or not a or is_fex:
        return a
    for jb, pb, sz in maps:
        if jb <= a < jb + sz:
            return pb + (a - jb)
    return a
assert translate(0x16f4c64cc) == 0x70ebd80000 + 0x5e4cc
assert translate(0x70ebd8e4cc) == 0x70ebd8e4cc
assert translate(0x16f4c64cc, enabled=False) == 0x16f4c64cc
assert translate(0x16f4c64cc, is_fex=True) == 0x16f4c64cc
assert translate(0) == 0

print('PASS: thread start inside a pool image copy is passed on as the image VA (switch MADEIRA_THREAD_START_PE_VA=0)')
