#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml2250, from device logs 116-119 (2026-10-28): Steam's 32-bit web helper stopped at start in three runs of
four, its renderer thread waiting without a timeout on Wine's SRW lock (an address 2 mod 4, two shared owners).

- build/ntdll-unix/signal_arm64_ios.c: each census cycle a 32-bit thread in such a wait for
  env.MADEIRA_SRW_HANG_DIAG_S (30) seconds has every 32-bit thread of its process logged once; at
  env.MADEIRA_SRW_HANG_KILL_S (unset = never) seconds the wineserver is asked to end that process;
- build/wineserver/fd_ios.c: the server's main loop takes the pid and ends the process with kill_process;
- app/Madeira/GameRecommendations.swift: the Steam Big Picture list sets the end at 40 seconds.

ml2260, from device log 120: FEX recorded the images already loaded when it starts
(FEX/Source/Windows/ARM64EC/Module.cpp, env.MADEIRA_FEX_PRELOADED_IMAGES=0 skips it).

Static anchors only.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sig = (ROOT / 'build/ntdll-unix/signal_arm64_ios.c').read_text(encoding='utf-8', errors='replace')
srv = (ROOT / 'build/wineserver/fd_ios.c').read_text(encoding='utf-8', errors='replace')
rec = (ROOT / 'app/Madeira/GameRecommendations.swift').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(src, name, stop='\n}\n'):
    i = src.index(name)
    return src[i:src.index(stop, i)]

census = body(sig, 'static void ios_srw_hang_census( int count )\n{')
check('ios_srw_hang_env( "MADEIRA_SRW_HANG_DIAG_S", 30 )' in census and 'ios_srw_hang_env( "MADEIRA_SRW_HANG_KILL_S", 0 )' in census,
      'the diagnostic defaults to 30 s, the end to never')
check("((uintptr_t)waddr & 3) != 2" in census and '!winf) continue;' in census and '!owners) continue;' in census
      and 'machine != 0x14c' in census,
      'only a 32-bit thread waiting without a timeout on a held SRW owners word counts')
check('kills < 3' in census and '__atomic_store_n( &ios_hang_kill_pid, (unsigned int)tpid, __ATOMIC_RELEASE );' in census,
      'at most 3 ends per run, handed to the server through ios_hang_kill_pid')
check('ndumped < 8' in census and 'ios_wow_dump_process( teb & ~0xffffffffull, (uint32_t)tpid, teb, count );' in census,
      'each process is dumped once, at most 8')
dump = body(sig, 'static void ios_wow_dump_process( uint64_t B, uint32_t pid, uint64_t any_teb, int count )\n{')
check('(teb & ~0xffffffffull) != B' in dump and '(uint32_t)tpid != pid' in dump and 'machine != 0x14c' in dump,
      "the dump covers only the process's own 32-bit threads")
check('ctx[0xb4 / 4]; eip = ctx[0xb8 / 4]; esp = ctx[0xc4 / 4];' in dump,
      'EBP, EIP and ESP are read from the I386 context in the CPU area')
pump = body(sig, 'void ios_pump_sample(void)\n{')
check('ios_srw_hang_census( count );' in pump, 'the census runs every pump sample')

check('__atomic_exchange_n( &ios_hang_kill_pid, 0, __ATOMIC_ACQ_REL );' in srv
      and 'kill_process( hang, 1 );' in srv and 'release_object( hang );' in srv,
      'the server takes the pid once and ends that process')

check('env.MADEIRA_SRW_HANG_KILL_S = 40' in rec, 'the Steam Big Picture list ends a stuck helper after 40 s')

fex = ROOT / 'FEX/Source/Windows/ARM64EC/Module.cpp'
if fex.exists():
    f = fex.read_text(encoding='utf-8', errors='replace')
    check('getenv("MADEIRA_FEX_PRELOADED_IMAGES")' in f and 'InvalidationTracker->HandleImageMap(ModuleName, Base);' in f,
          'FEX records the images on the loader list when it starts')
else:
    print('SKIP: FEX sources not checked out')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    for key in ('MADEIRA_SRW_HANG_DIAG_S', 'MADEIRA_SRW_HANG_KILL_S', 'MADEIRA_FEX_PRELOADED_IMAGES'):
        check(f'key: "env.{key}"' in text, f'the config catalog documents env.{key}')

print(f'check-srw-hang: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
