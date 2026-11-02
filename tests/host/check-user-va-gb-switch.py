#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""[user-va] env.MADEIRA_USER_VA_GB = n: a 64-bit process is told that its user address space ends at n GiB
(HighestUserAddress in virtual_get_system_info); placement keeps the real limit (build/ntdll-unix/virtual_ios.c).

Static anchors only: the value is read once and parsed strictly, 0 is off, n is held to 4..4096, only the report
is lowered and never raised, a 32-bit process and the session's client and browser-engine programs are skipped,
and the log tags.
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

cap = src[src.index('static ULONG_PTR ios_user_va_cap_bytes(void)'):]
cap = cap[:cap.index('\n}\n')]
check('static ULONG_PTR cap = ~(ULONG_PTR)0;' in cap and 'if (cap != ~(ULONG_PTR)0) return cap;' in cap,
      'the value is resolved once')
check(re.search(r'e = getenv\( "MADEIRA_USER_VA_GB" \);', cap) is not None and 'if (!e || !e[0]) return cap;' in cap
      and 'if (!n) return cap;' in cap, 'unset, empty or 0: off')
check('if (end == e || *end)' in cap and '"[user-va] MADEIRA_USER_VA_GB=\\"%s\\" is not a number of GiB: ignored\\n"' in cap,
      'anything but a plain number is ignored and logged')
check('if (n < 4 || n > 4096)' in cap and 'n = n < 4 ? 4 : 4096;' in cap and 'cap = (ULONG_PTR)n << 30;' in cap,
      'n is held to 4..4096 GiB')

skip = src[src.index('static int ios_user_va_skip_image( const WCHAR *path, size_t len )'):]
skip = skip[:skip.index('\n}\n')]
check('{ "helper", "webview", "cef", "chrome", "epic", "dockhost" }' in skip and 'if (!strncmp( name, "steam", 5 )) return 1;' in skip,
      "the store clients, helper/browser-engine programs and the Dock host are never told the figure")

rep = src[src.index('static void ios_user_va_cap_report( SYSTEM_BASIC_INFORMATION *info )'):]
rep = rep[:rep.index('\n}\n')]
check('if (!cap || (ULONG_PTR)info->HighestUserAddress < cap) return;' in rep, 'off, or the real limit is already lower: never raised')
check('ios_user_va_skip_image( pp->ImagePathName.Buffer, pp->ImagePathName.Length / sizeof(WCHAR) )' in rep,
      "the skip test reads the calling process's image path")
check('info->HighestUserAddress = (void *)(cap - 1);' in rep and '"[user-va] MADEIRA_USER_VA_GB: peb=%p is told HighestUserAddress=%p' in rep,
      'only the reported HighestUserAddress changes, logged once per process as [user-va]')

info = src[src.index('void virtual_get_system_info( SYSTEM_BASIC_INFORMATION *info, BOOL wow64 )'):]
info = info[:info.index('\n}\n')]
check('if (!wow64) ios_user_va_cap_report( info );' in info, 'applied in virtual_get_system_info, never for a 32-bit process')
check(info.index('else info->HighestUserAddress = (char *)user_space_limit - 1;') < info.index('ios_user_va_cap_report( info );'),
      'it runs after the real limit is filled in; user_space_limit itself is untouched')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    check('key: "env.MADEIRA_USER_VA_GB"' in text, 'the config catalog documents env.MADEIRA_USER_VA_GB')

print(f'check-user-va-gb-switch: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
