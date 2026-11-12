#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""env.MADEIRA_WOW_CHILD_WINDOW: a 32-bit child of a 32-bit parent gets its own guest window.

Battle.net's 32-bit helper froze: the child logged `i386 image ... window=0x7800000000`
(its parent's window) and no `[wow-window] reserved` line. ios_wow_window_reserve_once
returned "already have one" because ios_wow_slot_current() falls back to the pthread_t
that reserved the slot, and that pthread_t of a long-gone boot thread was recycled for
the child's thread. The child then ran in the parent's window (KUSER_SHARED_DATA map
failed, ntdll at the wrong base, c0000005).

Checks (source level, in build/ntdll-unix/virtual_ios.c):
  - reserve_once only treats the current slot as ours when it is unbound, or is the
    window of the PEB this thread already runs as;
  - otherwise it logs [wow-window] child-own-slot (16 at most), clears the stale
    owner thread so ios_wow_slot_current can no longer resolve to it, and goes on
    to reserve a new slot;
  - MADEIRA_WOW_CHILD_WINDOW=0 returns the old "already have one" result.
Plus a host simulation of the decision.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/virtual_ios.c').read_text()

a = src.index('static NTSTATUS ios_wow_window_reserve_once(void)\n{')
fn = src[a:src.index('\nvoid ios_wow_window_bind', a)]

assert 'if ((slot = ios_wow_slot_current()))' in fn
assert 'int ours = !slot->peb || ios_wow_slot_for_peb( ios_jit_current_peb() ) == slot;' in fn
assert 'getenv( "MADEIRA_WOW_CHILD_WINDOW" )' in fn
assert 'if (ours || (cw && cw[0] == \'0\'))' in fn
assert 'return STATUS_SUCCESS;   /* already have one */' in fn
assert '[wow-window] child-own-slot:' in fn
assert 'own_logged++ < 16' in fn
assert 'memset( &slot->owner, 0, sizeof(slot->owner) )' in fn
assert fn.index('slot = NULL;') < fn.index('for (i = 0; i < IOS_WOW_MAX_WINDOWS; i++)')
# the existing window-count loop still hands out the first free registry entry
assert 'else if (!slot) slot = &ios_wow_windows[i];' in fn
# the owner is only ever read by ios_wow_slot_current
assert len(re.findall(r'pthread_equal\( ios_wow_windows\[i\]\.owner', src)) == 1

# decision simulation: (slot_exists, bound, peb_matches, env_off) -> reuse?
def reuse(slot_exists, bound, peb_matches, env_off):
    if not slot_exists:
        return False
    ours = (not bound) or peb_matches
    return ours or env_off

assert reuse(True, False, False, False)        # boot gap: reserved, not yet bound
assert reuse(True, True, True, False)          # the process's own thread
assert not reuse(True, True, False, False)     # recycled owner thread of a live parent's slot
assert reuse(True, True, False, True)          # switch off: old behaviour
assert not reuse(False, False, False, False)

print('check-wow-child-window: ok')
