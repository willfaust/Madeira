#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""A Dock session's GDI handle table is section-backed (app/Madeira/ContentView.swift).

A Dock session starts 64-bit (explorer, then the host) and later starts 32-bit
programs: one-time installers and 32-bit games. win32u decides once, when the first
program initialises it, whether the GDI handle table is a section a 32-bit program can
map inside its guest window (wine dlls/win32u/gdiobj.c gdi_shared_use_section). The
Dock start now asks for the section; madeira.cfg can still turn it off.

Checks:
  * startDock sets MADEIRA_GDI_SHARED_SECTION=1 once, before the launch request, and
    nothing else in the app sets or clears it (the regular launch path is unchanged);
  * the bridge exports madeira.cfg env.* entries with setenv(..., 1) when the session
    starts, i.e. after startDock, so env.MADEIRA_GDI_SHARED_SECTION = 0 still wins;
  * when the wine submodule is checked out: gdi_shared_use_section(), compiled
    verbatim, returns TRUE for "1", FALSE for "0", and falls back to the session
    being armed when the variable is unset or empty.
Source checks and one small host compile: no Wine, iOS or device.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app' / 'Madeira'
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


content = (app / 'ContentView.swift').read_text(encoding='utf-8')
start = content.index('private func startDock(')
body = content[start:content.index('\n    }\n', start)]
line = 'setenv("MADEIRA_GDI_SHARED_SECTION", "1", 1)'
require(body.count(line) == 1, 'startDock asks for the section-backed GDI table once')
require(body.index(line) < body.index('MadeiraDock.requestLaunch('), 'before the launch request')

for path in sorted(app.rglob('*')):
    if path.suffix not in ('.swift', '.m', '.mm', '.c', '.h') or path.name == 'ConfigCatalog.generated.swift':
        continue
    text = path.read_text(encoding='utf-8', errors='replace')
    count = text.count('"MADEIRA_GDI_SHARED_SECTION"')
    expected = 1 if path.name == 'ContentView.swift' else 0
    if count != expected:
        require(False, f'{path.name}: MADEIRA_GDI_SHARED_SECTION appears {count} time(s), expected {expected}')
require(content.count('"MADEIRA_GDI_SHARED_SECTION"') == 1, 'nothing else in ContentView touches it (regular launches unchanged)')

bridge = (app / 'WineProcessBridge.m').read_text(encoding='utf-8')
export = bridge.index('if (![line hasPrefix:@"env."] || eq.location == NSNotFound) continue;')
# ml1184 grew the export loop (a game's own keys win), so look to the end of it.
require('setenv(k.UTF8String, v.UTF8String, 1);' in bridge[export:export + 6000],
        'madeira.cfg env.* entries are exported with overwrite when the session starts')

gdiobj = root / 'wine' / 'dlls' / 'win32u' / 'gdiobj.c'
if gdiobj.exists():
    src = gdiobj.read_text(encoding='utf-8', errors='replace')
    begin = src.index('static BOOL gdi_shared_use_section(void)')
    func = src[begin:src.index('\n}\n', begin) + 3]
    CC = os.environ.get('CC') or shutil.which('cc') or 'cc'
    with tempfile.TemporaryDirectory() as tmp:
        c = Path(tmp) / 't.c'
        c.write_text('#include <stdio.h>\n#include <stdlib.h>\ntypedef int BOOL;\n'
                     'static int armed;\nstatic int ios_wow_session_armed(void) { return armed; }\n'
                     + func.replace('ios_wow_session_armed && ', '') +
                     'int main(int c, char **v) { armed = atoi(v[1]); printf("%d\\n", gdi_shared_use_section()); return 0; }\n')
        exe = Path(tmp) / 't'
        subprocess.run([CC, '-O1', '-o', str(exe), str(c)], check=True)

        def run(value, armed):
            env = {k: v for k, v in os.environ.items() if k != 'MADEIRA_GDI_SHARED_SECTION'}
            if value is not None:
                env['MADEIRA_GDI_SHARED_SECTION'] = value
            return subprocess.run([str(exe), str(armed)], env=env, capture_output=True, text=True).stdout.strip()

        require(run('1', 0) == '1', 'wine: "1" section-backs the table in an unarmed (64-bit start) session')
        require(run('0', 1) == '0', 'wine: "0" keeps the private table even in an armed session')
        require(run(None, 0) == '0' and run(None, 1) == '1', 'wine: unset follows the session being armed')
        require(run('', 1) == '1', 'wine: empty follows the session being armed')
else:
    print('SKIP: wine submodule not checked out; gdi_shared_use_section not compiled')

print('FAILURES:', failures)
sys.exit(1 if failures else 0)
