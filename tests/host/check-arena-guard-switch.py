#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""[arena-guard] env.MADEIRA_ARENA_GUARD and the [alloc-fail] log throttle (build/ntdll-unix/virtual_ios.c).

With the switch a fixed or hinted guest reservation that overlaps an emulator-only (FEX_ONLY) area is refused
with STATUS_CONFLICTING_ADDRESSES, and the steering valve skips its top slot when the emulator's arena lies in it.
The [alloc-fail] line prints every failure up to 64, every 64th up to 65536, and then only the powers of two, so
a title that retries one failing reservation forever cannot fill the log.

Static anchors only: the switch read, its default and its two gates, the refusal hook ahead of map_fixed_area,
the steering bound, and the throttle condition.
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

def body(start):
    b = src[src.index(start):]
    return b[:b.index('\n}\n')]

en = body('static int ios_arena_guard_enabled(void)')
check(re.search(r'const char \*e = getenv\( "MADEIRA_ARENA_GUARD" \);', en) is not None and "v = !(e && e[0] == '0');" in en
      and '__atomic_store_n( &enabled, v, __ATOMIC_RELEASE );' in en,
      'the switch is read once; on by default, only 0 turns it off')
ref = body('static int ios_arena_guard_refuses( void *base, size_t size, ULONG_PTR limit_low, ULONG_PTR limit_high )')
check(ref.index('if (!ios_arena_guard_enabled()) return 0;') < ref.index('LIST_FOR_EACH_ENTRY( area, &reserved_areas'),
      'the refusal is gated before the reserved-area walk')
check('if (limit_high && fex_arena_covers( (void *)limit_low, (void *)limit_high )) return 0;' in ref,
      "the emulator's own requests (limits inside the arena) are never refused")
check('if (area_end <= start || !area->fex_only) continue;' in ref and '"[arena-guard] #%lu refused fixed/hinted %p+0x%lx' in ref,
      'only an overlap with a FEX_ONLY area is refused, logged as [arena-guard]')
check(re.search(r'if \(ios_arena_guard_refuses\( base, size, limit_low, limit_high \)\) return STATUS_CONFLICTING_ADDRESSES;\s*'
                r'if \(\(status = map_fixed_area\( base, size, unix_prot \)\)\) return status;', src) is not None,
      'the refusal sits right before map_fixed_area in the fixed-base branch')
top = body('static int ios_steer_top_slot_usable(void)')
check('if (!ios_arena_guard_enabled()) return 1;' in top and '"[arena-guard] steering valve: the top slot' in top,
      'off, the steering valve keeps its top slot; on, it is skipped when the arena lies in it')
valve = src[src.index('int steer_top = ios_steer_top_slot_usable();'):]
valve = valve[:valve.index('0x7400000000ULL, ios_spill_cap, 0, 0 );')]
check(re.search(r'int steer_ok = steer_top && \(', valve) is not None
      and re.search(r'NTSTATUS sst = !steer_ok \? STATUS_NO_MEMORY :\s*allocate_virtual_memory\(', valve) is not None
      and 'if (sst)' in valve,
      'a skipped top slot sends the valve straight to its second range')
check(src.count('ios_arena_guard_enabled()') == 2, 'the switch has exactly two gates: the refusal and the steering valve')

check('if (n <= 64 || (n <= 65536 && (n % 64) == 0) || (n > 65536 && (n & (n - 1)) == 0))' in src,
      '[alloc-fail]: the first 64, every 64th up to 65536, then powers of two only')
af = src[src.index('if (n <= 64 || (n <= 65536 && (n % 64) == 0) || (n > 65536 && (n & (n - 1)) == 0))'):][:400]
check('"[alloc-fail] ml814 #%lu status=%08x hint=%p size=0x%llx type=0x%x "' in af and 'static unsigned long af_n;' in src,
      '[alloc-fail]: the throttle guards the ml814 line, counted per session')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    check('key: "env.MADEIRA_ARENA_GUARD"' in text, 'the config catalog documents env.MADEIRA_ARENA_GUARD')

print(f'check-arena-guard-switch: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
