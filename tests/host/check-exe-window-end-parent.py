#!/usr/bin/env python3
"""env.MADEIRA_EXE_WINDOW_END_PARENT_MS (build/ntdll-unix/process_ios.c, server_ios.c).

A program that starts a copy of its own fixed-base exe and keeps running (DELTARUNE's
chapter select, a GameMaker game_change) ends itself after a grace time while the copy
waits for the fixed base, so the copy can start instead of failing c0000018.

Static anchors: the switch is read once (default 2000 ms, 0 off), it is armed only where
process creation returns early for a waiting child, the check runs from wine_server_call
only outside every uninterrupted section, only on the arming thread of the arming
process, only after the grace time, only while the child still waits, disarms before it
ends the process (no recursion through NtTerminateProcess's own server call), and ends
the process with the self pseudo-handle and code 0. The catalog lists the switch.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
proc = (ROOT / 'build/ntdll-unix/process_ios.c').read_text(encoding='utf-8', errors='replace')
srv = (ROOT / 'build/ntdll-unix/server_ios.c').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(src, start):
    b = src[src.index(start):]
    return b[:b.index('\n}\n')]

arm = body(proc, 'static void ios_exe_win_arm_end_parent(void)')
check('getenv( "MADEIRA_EXE_WINDOW_END_PARENT_MS" )' in arm and 'atoi( e ) : 2000;' in arm
      and 'if (grace_ms < 0) grace_ms = 0;' in arm and 'if (!grace_ms) return;' in arm,
      'switch: read once, default 2000 ms, 0 (or negative) never arms')
check(arm.index('ios_exewin_end_parent_at =') < arm.index('__atomic_store_n( &ios_exewin_end_parent_armed, 1, __ATOMIC_RELEASE );'),
      'arm: peb, tid and deadline are set before the armed flag is published')
early = proc[proc.index('if (handed_off)\n'):]
early = early[:early.index('}')]
check('ios_exe_win_arm_end_parent();' in early and proc.count('ios_exe_win_arm_end_parent();') == 1,
      'arm: only where process creation returns early for a child waiting on this process')

chk = body(proc, 'void ios_exe_win_end_parent_check(void)')
order = ['if (peb != ios_exewin_end_parent_peb) return;',
         '!= ios_exewin_end_parent_tid) return;',
         'if (ios_child_now() < ios_exewin_end_parent_at) return;',
         'if (!__atomic_exchange_n( &ios_exewin_end_parent_armed, 0, __ATOMIC_ACQ_REL )) return;',
         'if (!ios_exe_win_handoff_waits_on( peb ))',
         'NtTerminateProcess( NtCurrentProcess(), 0 );']
pos = [chk.find(o) for o in order]
check(all(p >= 0 for p in pos) and pos == sorted(pos),
      'check: same process, same thread, after the grace time, disarm once, child still waiting, then end self with 0')

call = body(srv, 'unsigned int CDECL wine_server_call( void *req_ptr )')
check('ios_exe_win_end_parent_check();' in call
      and '!(ios_section_state() & (IOS_SECTION_DEPTH | IOS_SECTION_ABORT))' in call
      and call.index('ios_exe_win_end_parent_check();') < call.index('pthread_sigmask( SIG_BLOCK'),
      'hook: wine_server_call, before the request, only outside every uninterrupted section and not when killed')
check('ios_exe_win_end_parent_check' not in body(srv, 'unsigned int server_call_unlocked( void *req_ptr )'),
      'hook: not in server_call_unlocked (called inside sections)')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
check('key: "env.MADEIRA_EXE_WINDOW_END_PARENT_MS"' in catalog.read_text(encoding='utf-8'),
      'catalog: Settings > All settings lists env.MADEIRA_EXE_WINDOW_END_PARENT_MS')

print('PASS' if not failures else f'{failures} FAILED')
sys.exit(1 if failures else 0)
