#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml2020 [fex-arena] GROW: when the emulator's arena is full, ntdll holds another FEX_ONLY band
below it and serves the emulator's requests from every FEX_ONLY area (build/ntdll-unix/virtual_ios.c).

Static anchors only: the switch and its catalog note, the grow function's bounds, the whole-area
rule in both scan directions, the hook before the STATUS_NO_MEMORY return, and that the arena guard
covers every FEX_ONLY area (so a grown band is protected like the arena).
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / 'build/ntdll-unix/virtual_ios.c').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

check(re.search(r'getenv\( "MADEIRA_FEX_ARENA_GROW" \);\s*/\* 1:', src) is not None
      and "v = (e && e[0] == '1');" in src,
      'the switch is read once with the note the config catalog takes, and it is opt-in (1 = hold a band; '
      'default: fail the request as before, since a band on the Social Club layout lies in guest-granted address space)')
grow = src[src.index('static int ios_fex_arena_grow( size_t need )'):src.index('static NTSTATUS map_view(')]
check('IOS_FEX_ARENA_GROW_MAX' in src and re.search(r'#define IOS_FEX_ARENA_GROW_MAX\s+4\b', src) is not None,
      'at most four extra bands')
check(re.search(r'#define IOS_FEX_ARENA_GROW_FLOOR 0x7000000000ULL', src) is not None and 'cand >= IOS_FEX_ARENA_GROW_FLOOR' in grow,
      "candidates never go below the hardware bands (the guest's furniture stays free of emulator memory)")
check('8ULL << 30, 4ULL << 30, 2ULL << 30, 1ULL << 30' in grow, 'band sizes 8, 4, 2, 1 GB, largest first')
check('VM_FLAGS_FIXED' in grow and 'PROT_NONE' in grow and 'find_view_range(' in grow,
      'a band is a FIXED native hold over a range Wine has no view in')
check('mmap_add_fex_reserved_area(' in grow and 'mach_vm_deallocate(' in grow,
      'the band is registered FEX_ONLY, and released when registration is refused')
check(grow.count('return 0;') >= 3 and 'return 1;' in grow, 'the function reports whether a band now exists')

inner = src[src.index('static void *map_reserved_area_inner('):src.index('static NTSTATUS map_fixed_area(')]
check(inner.count('if (!fex_arena_covers( limit_low, limit_high )) continue;') == 2
      and inner.count('if (fex_arena_request_is_own( limit_low, limit_high ))') == 2
      and inner.count('if (start != (void *)ios_fex_arena_base_unix) continue;   /* a grown band: not for the WoW64 module */') == 2
      and inner.count('find_reserved_free_area_outside_preloader( a_start, a_end, size, top_down, align_mask )') == 2,
      "both scan directions: the emulator's own request from every FEX_ONLY area, the WoW64 module's from the arena only, clipped")
check(inner.count('ULONG_PTR hold = ios_fex_arena_tail_hold();') == 2
      and inner.count('a_end = (char *)start + (area->size - hold);') == 2,
      "the arena's held tail is left to the 32-bit program's emulator in both directions")
check('if (area->fex_only && !fex_arena_covers' not in inner, 'the old clipped rule is gone')
check('static int fex_arena_request_is_own( const void *limit_low, const void *limit_high )' in src
      and 'return lo >= ios_fex_arena_base_unix && hi <= ios_fex_arena_end_unix;' in src,
      "own = strictly inside the published arena (the [wow-band] clause is not own)")
check(re.search(r'getenv\( "MADEIRA_WOW_ARENA_HOLD_GB" \);\s*/\* GB at the top', src) is not None
      and 'hold = (w && w[0] >= \'1\' && w[0] <= \'9\' && gb) ? (ULONG_PTR)gb << 30 : 0;' in src,
      'the tail hold is sized by MADEIRA_WOW_ARENA_HOLD_GB (default 3) and only while a guest window is held')

view = src[src.index('static NTSTATUS map_view('):]
hook = view.index('ios_fex_arena_grow( view_size )')
fail = view.index('return STATUS_NO_MEMORY;', hook)
check(fail - hook < 1200 and 'fex_arena_request_is_own( (void *)limit_low, (void *)limit_high )' in view[hook - 200:hook],
      "the grow attempt sits right before the STATUS_NO_MEMORY return and only for the emulator's own requests")
check('map_reserved_area( start, end, host_size, top_down, unix_prot, align_mask )' in view[hook:hook + 400],
      'after growing, the request is placed through the reserved-area path (the new band is one)')

guard = src[src.index('static int ios_arena_guard_refuses('):]
guard = guard[:guard.index('\n}\n')]
check('LIST_FOR_EACH_ENTRY( area, &reserved_areas' in guard and '!area->fex_only) continue' in guard,
      'the arena guard walks every FEX_ONLY area, so a grown band refuses fixed guest requests like the arena')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    check('key: "env.MADEIRA_FEX_ARENA_GROW"' in text, 'the config catalog documents env.MADEIRA_FEX_ARENA_GROW')
    check('key: "env.MADEIRA_WOW_ARENA_HOLD_GB"' in text, 'the config catalog documents env.MADEIRA_WOW_ARENA_HOLD_GB')

print(f'check-fex-arena-grow: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
