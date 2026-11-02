#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""[wow-cpu-pool] env.MADEIRA_WOW_CPU_POOL_ONLY: when the kernel grants the WoW64 CPU module's PE view EXEC in
place although its pool copy exists, EXEC is taken back so its entry point and constructors run in the pool copy,
the one its exports run in (build/ntdll-unix/virtual_ios.c).

Static anchors only: the switch is read once and is on unless exactly "0", the view mark (native ARM64 PE64 named
xtajit.dll), the take-back answers only for a marked view with a pool copy, the mprotect that drops EXEC before the
pool path, and the [exec-split] / [wow-cpu-pool] log lines.
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

en = body('static int ios_wow_cpu_pool_only_enabled( void )')
check(re.search(r'const char \*v = getenv\( "MADEIRA_WOW_CPU_POOL_ONLY" \);', en) is not None
      and "cached = (v && v[0] == '0' && !v[1]) ? 0 : 1;" in en,
      'the switch is read once; on by default, exactly 0 turns it off')
check(re.search(r'#define IOS_VIEW_WOW_CPU\s+0x8\b', src) is not None, 'a view flag marks the WoW64 CPU module')
mark = body('static void ios_wow_cpu_mark_view( struct file_view *view, const UNICODE_STRING *nt_name, const IMAGE_NT_HEADERS *nt )')
check(mark.index('if (!ios_wow_cpu_pool_only_enabled()) return;') < mark.index('view->ios_flags |= IOS_VIEW_WOW_CPU;'),
      'off, no view is marked')
check('nt->FileHeader.Machine != IMAGE_FILE_MACHINE_ARM64 || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC' in mark
      and 'if (!ios_nt_name_has_basename( nt_name, "xtajit.dll" )) return;' in mark,
      'only a native ARM64 PE64 whose file is xtajit.dll is marked')
check('ios_wow_cpu_mark_view( view, nt_name, nt );' in src, 'map_image_into_view marks the view')

split = body('static int ios_exec_in_place_split( const void *base, size_t size, int unix_prot )')
check('if (ios_in_mach_exc) return 0;' in split and '!(view->protect & SEC_IMAGE)' in split,
      'no view lookup from the exception thread; images only')
check('cpu = (view->ios_flags & IOS_VIEW_WOW_CPU) && ios_wow_cpu_pool_only_enabled();' in split
      and 'if (!m) return 0;' in split and 'return cpu;' in split,
      'EXEC is taken back only for the marked module, only with the switch, only when a pool copy exists')
check('"[exec-split] %s %p+0x%lx prot=%c%c%c: EXEC was granted in place although the pool copy %p exists%s\\n"' in split
      and 'noted++ < 16' in split, 'other modules in that state are only reported, as [exec-split], 16 lines')

check(re.search(r'ios_exec_in_place_split\( base, size, unix_prot \)\)\s*\{', src) is not None
      and 'if (!mprotect( base, size, unix_prot & ~PROT_EXEC ))' in src and 'exec_taken_back = 1;' in src,
      "mprotect_exec's fast path drops EXEC again when the split answers 1")
check('if (!exec_taken_back && qkr == KERN_SUCCESS && (info.protection & VM_PROT_EXECUTE))' in src,
      'a taken-back view goes on to the pool path, as where the kernel never grants EXEC')
check('"[wow-cpu-pool] could not take EXEC back from %p+0x%lx (errno %d):' in src, 'a failed take-back is logged')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    check('key: "env.MADEIRA_WOW_CPU_POOL_ONLY"' in text, 'the config catalog documents env.MADEIRA_WOW_CPU_POOL_ONLY')

print(f'check-wow-cpu-pool-only: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
