#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""env.MADEIRA_X64_CHILD_NO_WINDOW: a 64-bit child of a 32-bit parent never allocates inside a 32-bit window.

StarCraft x86_64 children spawned by the 32-bit Battle.net launcher sometimes got TEB and PEB at
0x77xxxxxxxx (inside the parent's guest window) and booted as WoW64. virtual_alloc_teb() asks
ios_wow_slot_current(); its owner fallback matched a recycled pthread_t of the live parent's bound
window, so the TEB block, and then (ios_wow_base() != 0) the PEB, came out of that window.

Source-level checks plus a decision simulation.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
v = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
l = (root / 'build/ntdll-unix/loader_ios.c').read_text()

a = v.index('static struct ios_wow_window *ios_wow_slot_current(void)\n{')
fn = v[a:v.index('/* Live windows (bound or reserved', a)]
assert 'static __thread int ios_x64_child_thread;' in v
assert v.index('static __thread int ios_x64_child_thread;') < a
assert 'getenv( "MADEIRA_X64_CHILD_NO_WINDOW" )' in v
assert "if (e && e[0] == '0') on = 0;" in v
# a bound slot of a different live peb is never returned by the owner fallback
assert 'if (ios_wow_windows[i].peb && cur && ios_wow_windows[i].peb != cur) continue;' in fn
# a marked 64-bit child thread gets no window, and says so (16 at most)
assert 'if (ios_x64_child_thread)' in fn
assert '[wow-window] x64-child-outside:' in fn
assert 'outside_logged++ < 16' in fn
assert fn.index('x64-child-outside') < fn.index('return &ios_wow_windows[i];')
# the PEB-first lookup is untouched
assert 'if ((slot = ios_wow_slot_for_peb( cur ))) return slot;' in fn

# loader: marked only on the 64-bit branch (machine known), cleared on the i386 branch
b = l.index('int child_is_i386 = ios_child_main_machine')
blk = l[b:l.index('/* Allocate a new TEB for this child', b)]
assert 'ios_x64_child_no_window_mark( 0 )' in blk
assert 'if (ios_child_main_machine) ios_x64_child_no_window_mark( 1 );' in blk
assert blk.index('mark( 0 )') < blk.index('ios_wow_window_reserve()') if 'mark( 0 )' in blk else True
assert blk.index('ios_x64_child_no_window_mark( 1 )') > blk.index('(no guest window)')
assert blk.index('ios_x64_child_no_window_mark( 1 )') < len(blk)   # and before virtual_alloc_teb below
assert l.index('ios_x64_child_no_window_mark( 1 )') < l.index('status = virtual_alloc_teb( &teb );', b)

# decision simulation
def resolve(peb_hit, owner_match, slot_peb, cur, x64_flag, env_off=False):
    """-> 'slot' or None for the owner fallback of ios_wow_slot_current"""
    flag = x64_flag and not env_off
    if peb_hit:
        return 'slot'
    if not owner_match:
        return None
    if slot_peb and cur and slot_peb != cur:
        return None
    if flag:
        return None
    return 'slot'

assert resolve(False, True, 'A', None, False) == 'slot'     # boot gap of the owning process
assert resolve(False, True, None, None, False) == 'slot'    # reserved, unbound
assert resolve(False, True, 'A', 'B', False) is None        # other live process's thread, recycled owner
assert resolve(False, True, 'A', None, True) is None        # fresh x64 child thread, recycled owner
assert resolve(False, True, 'A', None, True, env_off=True) == 'slot'   # switch off: old behaviour
assert resolve(True, False, 'A', 'A', True) == 'slot'

print('check-x64-child-no-window: ok')
