#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""[atom-arg] env.MADEIRA_ATOM_ARG: an ATOM that reaches win32u with a 32-bit program's guest window base added
(the WoW64 thunks convert every non-zero 32-bit value like a pointer) is given back as the atom
(build/win32u-unix/class_ios.c).

Static anchors only: the switch is read once and is on unless exactly "0", a value is un-rebased only when it lies
in [base + 1, base + 0xffff] above 4 GB, a 64-bit program (no window base) is untouched, the switch is tested only
after a candidate was found, get_int_atom_value goes through it, and the [atom-arg] line.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / 'build/win32u-unix/class_ios.c').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(start):
    b = src[src.index(start):]
    return b[:b.index('\n}\n')]

en = body('static int ios_atom_arg_enabled(void)')
check('static int enabled = -1;' in en and re.search(r'const char \*env = getenv\( "MADEIRA_ATOM_ARG" \);', en) is not None
      and 'enabled = !env || strcmp( env, "0" );' in en,
      'the switch is read once; on by default, exactly 0 turns it off')

un = body('static ULONG_PTR ios_atom_unrebase( ULONG_PTR value, ULONG_PTR base )')
check('if (!(value >> 32)) return value;' in un, 'a value below 4 GB (a plain atom or a 64-bit pointer there) is returned as it came')
check('if (!base || value <= base || value - base >= 0x10000) return value;' in un and 'return value - base;' in un,
      'only [base + 1, base + 0xffff] is an atom; no window base (a 64-bit program) changes nothing')

arg = body('const WCHAR *ios_atom_arg( const WCHAR *ptr )')
check('atom = ios_atom_unrebase( value, ios_wow_base() );' in arg, "the base is the calling process's guest window base")
check(arg.index('atom = ios_atom_unrebase(') < arg.index('if (atom == value || !ios_atom_arg_enabled()) return ptr;'),
      'the switch is consulted only when a rebased atom was found')
check('"[atom-arg] guest=%#lx atom=%#lx\\n"' in arg and '< 8' in arg, 'each conversion is logged as [atom-arg], eight lines')

gia = body('static ATOM get_int_atom_value( UNICODE_STRING *name )')
check(gia.index('const WCHAR *ptr = ios_atom_arg( name->Buffer );') < gia.index('if (IS_INTRESOURCE(ptr)) return LOWORD(ptr);'),
      'get_int_atom_value converts the buffer before its IS_INTRESOURCE test')
check('const WCHAR *end = ptr + name->Length / sizeof(WCHAR);' in gia, 'the string branch reads the converted pointer')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    check('key: "env.MADEIRA_ATOM_ARG"' in text, 'the config catalog documents env.MADEIRA_ATOM_ARG')

print(f'check-atom-arg-switch: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
