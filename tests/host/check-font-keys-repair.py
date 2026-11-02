#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml2330, from testers' logs of 2026-11-01: a launcher's embedded browser crashed on every start (a stack
overflow in Chromium's font fallback) and its dialogs drew no text. DirectWrite lists only the fonts named in
HKLM\\...\\Windows NT\\CurrentVersion\\Fonts, and Tahoma, Marlett, Symbol, Webdings and Wingdings had lost
their values there: the prefix template's External Fonts names them too (macOS paths), and one session whose
font list came up empty ran update_external_font_keys, which deletes the Fonts value of every external entry
it finds no face for. The Windows directory's fonts are not external, so nothing wrote the values back.

- wine/dlls/win32u/font.c: a session that found no fonts leaves the keys alone; a stale external entry naming
  a font of the Windows directory is dropped from External Fonts only; every font of the Windows directory
  whose Fonts value is missing gets it back; font_init logs the size of the shared font list
  (env.MADEIRA_FONT_KEYS_REPAIR=0 restores upstream behaviour).

Static anchors only.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(src, name, stop='\n}\n'):
    i = src.index(name)
    return src[i:src.index(stop, i)]

src = ROOT / 'wine/dlls/win32u/font.c'
if src.exists():
    s = src.read_text(encoding='utf-8', errors='replace')
    switch = body(s, 'static BOOL ios_font_keys_repair_enabled(void)\n{')
    check('getenv( "MADEIRA_FONT_KEYS_REPAIR" )' in switch and "enabled = !(e && e[0] == '0');" in switch,
          'env.MADEIRA_FONT_KEYS_REPAIR=0 restores upstream behaviour, default on')
    windir = body(s, 'static const WCHAR *ios_windows_font_file( const struct gdi_font_face *face )\n{')
    check('(face->flags & ADDFONT_EXTERNAL_FONT)) return NULL;' in windir and 'get_fonts_win_dir_path( NULL, dir );' in windir,
          'only non-external fonts loaded from C:\\windows\\Fonts count as the Windows directory\'s fonts')
    check("!wcschr( name, '\\\\' )" in windir, 'files in subfolders of the fonts folder are not counted')
    update = body(s, 'static void update_external_font_keys(void)\n{')
    check('if (repair && !faces)' in update and update.index('if (repair && !faces)') < update.index('reg_create_key( NULL, fonts_winnt_config_keyW'),
          'a session that found no fonts returns before touching the Fonts keys')
    check('key->list_only = TRUE;' in update and 'ios_windows_font_file( face )' in update,
          'a stale external entry naming a Windows directory font is queued for External Fonts only')
    drop = update[update.index('if (key->list_only)'):]
    drop = drop[:drop.index('continue;')]
    check('reg_delete_value( hkey, key->value );' in drop and 'winnt_key' not in drop and 'win9x_key' not in drop,
          'that entry keeps its Fonts values')
    restore = update[update.index('if (repair)\n    {'):]
    check('query_reg_value( winnt_key, value, partial, sizeof(buffer) )) continue;' in restore
          and 'set_reg_value( winnt_key, value, REG_SZ, name, len );' in restore
          and 'set_reg_value( win9x_key, value, REG_SZ, name, len );' in restore,
          'a missing Fonts value of a Windows directory font is written back, an existing one is kept')
    check('!face->scalable' in restore and 'true_type_suffixW' in restore,
          'only scalable faces, named "<full name> (TrueType)" as the template has them')
    check('[fonts] ml2330' in body(s, 'UINT font_init(void)\n{'), 'font_init logs the size of the shared font list')
else:
    print('SKIP: wine sources not checked out')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    check('key: "env.MADEIRA_FONT_KEYS_REPAIR"' in catalog.read_text(encoding='utf-8'),
          'the config catalog documents env.MADEIRA_FONT_KEYS_REPAIR')

print(f'check-font-keys-repair: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
