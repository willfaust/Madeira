#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""[redeliv]/[segv-loop] env.MADEIRA_FAULT_GUARD_RATE: the two fault-storm guards count a run of identical faults
as a storm only when it is dense (and, in the Mach path, while the presenter stands still), so a title that throws
managed null-reference exceptions through a trap at a game's pace is not ended alive
(build/ntdll-unix/signal_arm64_ios.c).

Static anchors only: the switch is read once and is opt-in, the density and frame thresholds, the Mach-path
2000 mark only fires when the run is not alive, the BSD path counts per thread and restarts a slow run, and the
log tags.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / 'build/ntdll-unix/signal_arm64_ios.c').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

reader = src[src.index('static int ios_fault_guard_rate_on( void )'):]
reader = reader[:reader.index('\n}\n')]
check('static int ios_fault_guard_rate = -1;' in src
      and re.search(r'getenv\( "MADEIRA_FAULT_GUARD_RATE" \);', reader) is not None
      and "v = (e && e[0] && e[0] != '0') ? 1 : 0;" in reader
      and '__atomic_store_n( &ios_fault_guard_rate, v, __ATOMIC_RELAXED );' in reader,
      'the switch is read once and cached; unset or 0 keeps it off')
check(re.search(r'#define IOS_FGR_DENSE_NS\s+500000000ull', src) is not None
      and re.search(r'#define IOS_FGR_FRAMES\s+3\b', src) is not None
      and re.search(r'#define IOS_FGR_BSD_RUN_NS 5000000ull', src) is not None,
      'thresholds: 2000 deliveries in 0.5 s are dense, 3 presented frames make a sparse run alive, 5 ms for the BSD run')
resolve = src[src.index('static void ios_fgr_resolve( void )'):]
resolve = resolve[:resolve.index('\n}\n')]
check('if (ios_fault_guard_rate_on())' in resolve
      and 'dlsym( RTLD_DEFAULT, "madeira_get_present_count" );' in resolve
      and 'ios_fgr_resolve();   /* MADEIRA_FAULT_GUARD_RATE */' in src
      and '*known = ios_fgr_present_count != NULL;' in src,
      'the frame counter is looked up by name once, on the Mach exception thread, only with the switch; '
      'a build without it judges by density alone')

alive = src[src.index('static int ios_fgr_run_alive('):]
alive = alive[:alive.index('\n}\n')]
check('int known, dense = dt < IOS_FGR_DENSE_NS, alive;' in alive
      and 'alive = !dense && (!known || frames >= IOS_FGR_FRAMES);' in alive,
      'a run is alive only when it is sparse and frames kept coming')
check('*n = 1;' in alive and '*t0 = now;' in alive, 'an alive run starts over instead of ending the process')
check('"[redeliv] MADEIRA_FAULT_GUARD_RATE pc=0x%llx addr=0x%llx:' in alive and 'said < 6' in alive,
      'the verdict is logged as [redeliv], six lines at most')

check('if (ios_fault_guard_rate_on()) ios_fgr_run_begin( &redeliv[rslot].t0, &redeliv[rslot].p0 );' in src,
      'Mach path: a new run records its start time and frame count only with the switch')
check(re.search(r'else if \(redeliv\[rslot\]\.n >= 2000 && !ios_redeliv_terminating &&\s*'
                r'!\(ios_fault_guard_rate_on\(\) &&\s*ios_fgr_run_alive\(', src) is not None,
      'Mach path: the 2000 mark ends the process unless the switch is on and the run is alive')

bsd = src[src.index('struct ios_fgr_bsd_slot *fgr_slot = NULL;'):]
bsd = bsd[:bsd.index('if (this_pc == *lastp)\n')]
check('uintptr_t *lastp = &last_fault_pc;' in src and 'int *cntp = &fault_repeat_count;' in src,
      'BSD path: unset, the shared statics are used as before')
check('fgr_slot = ios_fgr_bsd_slot_get();' in bsd and 'lastp = &fgr_slot->pc;' in bsd
      and 'fgr_now - fgr_slot->t0 > IOS_FGR_BSD_RUN_NS' in bsd and '*cntp = 0;' in bsd,
      'BSD path: with the switch the run is per thread and a run slower than 5 ms starts over')
check('"[segv-loop] MADEIRA_FAULT_GUARD_RATE pc=%p addr=%p:' in bsd, 'the BSD restart is logged as [segv-loop]')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    check('key: "env.MADEIRA_FAULT_GUARD_RATE"' in text, 'the config catalog documents env.MADEIRA_FAULT_GUARD_RATE')

print(f'check-fault-guard-rate-switch: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
