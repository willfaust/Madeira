#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Two placement switches, both on by default (build/ntdll-unix/virtual_ios.c, build/ntdll-unix/process_ios.c):
  env.MADEIRA_EXE_WINDOW_HANDOFF      a fixed-base main image's claim on the executable window is matched at the
                                      host-page-rounded size, a new main image waits for the previous owner to exit,
                                      and the parent's process-creation wait can return early for such a child
  env.MADEIRA_THIN_RESERVE            1-2 GB read-write reserves get a thin head once
                                      MADEIRA_THIN_RESERVE_AFTER_GB (default 8) GB of them were reserved normally;
                                      MADEIRA_THIN_RESERVE_MB is the slot stride (default 64, 16..512)

Static anchors only: each switch is read once and only "0" turns it off, the gates of the code they change, the
process-creation poll that cannot return early when off, the thin reserve's request shape, and the log lines.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / 'build/ntdll-unix/virtual_ios.c').read_text(encoding='utf-8', errors='replace')
proc = (ROOT / 'build/ntdll-unix/process_ios.c').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(start):
    b = src[src.index(start):]
    return b[:b.index('\n}\n')]

# executable-window handoff
en = body('static int ios_exe_win_handoff_enabled(void)')
check(re.search(r'const char \*e = getenv\( "MADEIRA_EXE_WINDOW_HANDOFF" \);', en) is not None and "enabled = !(e && e[0] == '0');" in en,
      'handoff: read once; on by default, only 0 turns it off')
wo = body('int ios_exe_win_handoff_waits_on( void *peb )')
check('return peb && ios_exewin_waiters > 0 && ios_exewin_waiter_owner == peb;' in wo
      and 'extern int ios_exe_win_handoff_waits_on( void *peb );' in proc,
      'handoff: the waiter test is exported to process_ios.c and is true only while a main image waits on this process')
check('if (ios_exe_win_handoff_enabled()) size = ROUND_SIZE( 0, size, host_page_mask );' in src,
      'handoff: a claim is matched at the host-page-rounded image size only when on')
wait = body('static void ios_exe_win_wait_for_handoff( const struct pe_image_info *info )')
check('if (!wait_ms || !ios_exe_win_handoff_enabled()) return;' in wait and 'wait_ms = e && *e ? atoi( e ) : 10000;' in wait,
      'handoff: off (or MADEIRA_EXE_WINDOW_WAIT_MS=0), a new main image does not wait; default wait 10 s')
check('if (!(info->image_charact & IMAGE_FILE_RELOCS_STRIPPED)) return;' in wait and 'if (info->image_charact & IMAGE_FILE_DLL) return;' in wait,
      'handoff: only a fixed-base executable waits')
reg = wait[wait.index('if (!wait_ms || !ios_exe_win_handoff_enabled()) return;'):]
check('__atomic_add_fetch( &ios_exewin_waiters, 1, __ATOMIC_SEQ_CST );' in reg
      and src.count('__atomic_add_fetch( &ios_exewin_waiters, 1,') == 1
      and re.search(r'while \(NtWaitForSingleObject\( process_info, FALSE, &poll \) == STATUS_TIMEOUT\)\s*\{\s*'
                    r'if \(ios_exe_win_handoff_waits_on\( NtCurrentTeb\(\)->Peb \)\)', proc) is not None,
      'process creation: a 50 ms poll that can return early only for a registered waiter; off, nothing registers, '
      'so it waits for the child as before')
check('if (ios_exe_win_handoff_waits_on( NtCurrentTeb()->Peb ))' in proc and 'poll.QuadPart = -50 * 10000;' in proc
      and '"[exe-window] the new process is waiting for this process\'s fixed base; "' in proc,
      'process creation: the poll returns early when the child waits for this process, logged as [exe-window]')

# thin reserve
cfg = body('static int ios_thin_config(void)')
check('if (ios_thin_mode >= 0) return ios_thin_mode;' in cfg and re.search(r'e = getenv\( "MADEIRA_THIN_RESERVE" \);', cfg) is not None
      and "ios_thin_mode = !(e && e[0] == '0');" in cfg,
      'thin: read once; on by default, only 0 turns it off')
check('mb = (e = getenv( "MADEIRA_THIN_RESERVE_MB" )) ? strtoul( e, NULL, 10 ) : 64;' in cfg
      and 'if (mb < 16) mb = 16;' in cfg and 'if (mb > 512) mb = 512;' in cfg,
      'thin: the stride defaults to 64 MB and is held to 16..512')
check('gb = (e = getenv( "MADEIRA_THIN_RESERVE_AFTER_GB" )) ? strtoul( e, NULL, 10 ) : 8;' in cfg
      and 'ios_thin_head   = ios_thin_stride - IOS_THIN_GUARD;' in cfg and '"[thin] %s: 1-2 GB read-write reserves get a %lu MB head once %lu GB of them "' in cfg
      and 'ios_thin_mode ? "on" : "off (MADEIRA_THIN_RESERVE=0)"' in cfg,
      'thin: 8 GB reserved normally first by default; the head is the stride less a 1 MB guard; logged on or off')
res = body('static BOOL ios_thin_reserve( void **ret, SIZE_T *size_ptr, ULONG protect, NTSTATUS *status )')
check(res.index('if (protect != PAGE_READWRITE || size < IOS_THIN_MIN_SIZE || size > IOS_THIN_MAX_SIZE) return FALSE;')
      < res.index('if (!ios_thin_config()) return FALSE;'),
      'thin: only a 1-2 GB read-write reserve is considered, and nothing happens when off')
check(re.search(r'if \(!\*ret && type == MEM_RESERVE && !limit_low && !limit_high && !align && !attributes\)\s*\{\s*'
                r'NTSTATUS thin_status;\s*if \(ios_thin_reserve\( ret, size_ptr, protect, &thin_status \)\) return thin_status;', src) is not None,
      'thin: only an unconstrained, unhinted MEM_RESERVE reaches it')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    for key in ('env.MADEIRA_EXE_WINDOW_HANDOFF', 'env.MADEIRA_THIN_RESERVE', 'env.MADEIRA_THIN_RESERVE_MB', 'env.MADEIRA_THIN_RESERVE_AFTER_GB'):
        check(f'key: "{key}"' in text, f'the config catalog documents {key}')

print(f'check-exe-window-handoff-switch: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
