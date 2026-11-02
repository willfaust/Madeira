#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""[anon-cas] env.MADEIRA_ANON_CAS_FLUSH: a compare-and-swap that faults on an anonymous RWX alias is handed on
to the emulator (which drops the page's translation and performs it) instead of being emulated in the Mach handler
(build/ntdll-unix/signal_arm64_ios.c).

Static anchors only: the switch is read once and is opt-in, the handoff takes exactly the stores the emulation
would have taken (natural alignment, the whole word in one alias run), a handed CAS is neither emulated nor
reported as undecoded, and the counters the spin report reads are kept for both outcomes.
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

reader = src[src.index('static int ios_anon_cas_flush_on( void )'):]
reader = reader[:reader.index('\n}\n')]
check('static int ios_anon_cas_flush = -1;' in src
      and re.search(r'getenv\( "MADEIRA_ANON_CAS_FLUSH" \);', reader) is not None
      and "v = (e && e[0] && e[0] != '0') ? 1 : 0;" in reader
      and '__atomic_store_n( &ios_anon_cas_flush, v, __ATOMIC_RELAXED );' in reader,
      'the switch is read once and cached; unset or 0 keeps it off')
check('volatile unsigned long long ios_anon_cas_last_addr, ios_anon_cas_last_ms;' in src
      and 'volatile unsigned ios_anon_cas_emulated, ios_anon_cas_handed;' in src,
      'the counters the [spin] report reads are exported (not static)')
note = src[src.index('static void ios_anon_cas_note('):]
note = note[:note.index('\n}\n')]
check('__sync_add_and_fetch( &ios_anon_cas_handed, 1 )' in note and '__sync_add_and_fetch( &ios_anon_cas_emulated, 1 )' in note
      and 'ios_anon_cas_last_addr = addr;' in note, 'the note counts handed and emulated CASes apart and keeps the last address')

cas = src[src.index('int anon_cas_handoff = 0;'):]
cas = cas[:cas.index('if (emulated)')]
# The handoff is its own case of the store decoder, just before the LD<OP>/CAS case (ios_mach_emulate_rmw),
# so a handed CAS never reaches that emulation.
gate = cas.index('else if (!in_jit && (insn & 0xbfa07c00u) == 0x88a07c00u && ios_anon_cas_flush_on() &&')
emul = cas.index('if (ios_mach_emulate_rmw( insn, rw_addr, gpr ))')
check(gate < emul and cas.index('else if ((insn & 0x3f20cc00u) == 0x38200000u ||') > gate,
      'the handoff case comes before the read-modify-write case in the same else-if chain')
check("!((uintptr_t)fault_addr & ((insn & 0x40000000u) ? 7 : 3)) &&" in cas[gate:emul]
      and 'ios_jit_anon_alias_lookup( fault_addr + ((insn & 0x40000000u) ? 7 : 3) ) ==' in cas[gate:emul],
      'the handoff takes W and X CASes, naturally aligned, the last byte in the same alias run as the first')
check('anon_cas_handoff = 1;' in cas[gate:emul] and 'ios_anon_cas_note( (unsigned long long)fault_addr, 1 );' in cas[gate:emul],
      'a handed CAS is marked and counted as handed')
check('ios_anon_cas_note( (unsigned long long)fault_addr, 0 );' in cas[emul:emul + 600],
      'without the switch the CAS is emulated and counted as emulated')
check('if (!emulated && !anon_cas_handoff)' in cas,
      'a handed CAS skips the [store-undecoded] report')
check('"[anon-cas] MADEIRA_ANON_CAS_FLUSH insn=%08x' in cas and 'cas_flush_logs++ < 16' in cas,
      'the handoff is logged as [anon-cas], 16 lines at most')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    check('key: "env.MADEIRA_ANON_CAS_FLUSH"' in text, 'the config catalog documents env.MADEIRA_ANON_CAS_FLUSH')

print(f'check-anon-cas-flush-switch: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
