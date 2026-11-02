#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml2290, from a tester's log of 2026-10-31: a launcher installer ran its 32-bit VC++
redistributables one after the other. The second got the first's WoW window and TEB
addresses, and exit_thread's raw prev_teb hand-off named the thread that was exiting:
its worker thread freed its own kernel stack (unregister_view+4, the stack fault waiting
for the virtual_mutex it held) and the installer waited on that thread forever.

- build/ntdll-unix/thread_ios.c: exit_thread takes the checked hand-off
  (ios_ea_reap_exited_thread, virtual_ios.c) by default; env.MADEIRA_THREAD_REAP_CHECKED=0
  restores the upstream hand-off unless MADEIRA_EA_CEF=1.

Static anchors only.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
failures = 0


def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond:
        failures += 1


def body(src, name, stop='\n}\n'):
    i = src.index(name)
    return src[i:src.index(stop, i)]


thread = (ROOT / 'build/ntdll-unix/thread_ios.c').read_text(encoding='utf-8', errors='replace')
exit_thread = body(thread, 'static DECLSPEC_NORETURN void exit_thread( int status )')
check('getenv( "MADEIRA_THREAD_REAP_CHECKED" )' in exit_thread, 'exit_thread reads env.MADEIRA_THREAD_REAP_CHECKED')
check("if (!(checked && checked[0] == '0') || (ea_cef && !strcmp( ea_cef, \"1\" )))" in exit_thread,
      'the checked hand-off is the default; 0 restores the old one unless MADEIRA_EA_CEF=1')
gate = exit_thread[exit_thread.index('const char *checked'):]
check(gate.index('ios_ea_reap_exited_thread( NtCurrentTeb() );') < gate.index('InterlockedExchangePointer( &prev_teb'),
      'the checked hand-off is the first branch, prev_teb the fallback')

virtual = (ROOT / 'build/ntdll-unix/virtual_ios.c').read_text(encoding='utf-8', errors='replace')
reap = body(virtual, 'void ios_ea_reap_exited_thread( TEB *current )')
check('retired.teb != current' in reap and '!pthread_equal( retired.pthread_id, pthread_self() )' in reap,
      'the reaper never joins or frees the calling thread')
check('ios_ea_retired_thread_matches( &retired )' in reap and 'virtual_free_teb( retired.teb );' in reap,
      'the previous thread is found in the live TEB list again before its stacks are freed')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    check('key: "env.MADEIRA_THREAD_REAP_CHECKED"' in catalog.read_text(encoding='utf-8'),
          'the config catalog documents env.MADEIRA_THREAD_REAP_CHECKED')

print(f'check-thread-reap: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
