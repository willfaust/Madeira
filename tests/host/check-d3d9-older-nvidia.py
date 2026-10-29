#!/usr/bin/env python3
"""Older NVIDIA card (Direct3D 9) (app/Madeira/LibraryBCD.swift, D3D9Identity).

Fallout 3 and New Vegas pick their render path from the card's name and the driver
file. The switch makes DXMT's Direct3D 9 report a GeForce 7900 GS on nv4_disp.dll,
as the d3d9.dll wrapper New Vegas players install does. d3d9.customDriver is
DXMT's (dxmt/src/d3d9/d3d9_interface.cpp).
The game keeps the card's name in its prefs (sD3DDevice) and opens its launcher
when it changes, so the switch keeps that line on the card the game will see.
"""
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[2]
bcd = (root / 'app/Madeira/LibraryBCD.swift').read_text(encoding='utf-8')
prefs = (root / 'app/Madeira/LibraryPrefs.swift').read_text(encoding='utf-8')
library = (root / 'app/Madeira/Library.swift').read_text(encoding='utf-8')
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


# The identity.
check('"d3d9.customVendorId=10de"' in bcd and '"d3d9.customDeviceId=0292"' in bcd,
      'the switch reports NVIDIA\'s ids for a 7900 GS')
check('"d3d9.customDeviceDesc=\\"\\(olderNvidiaName)\\""' in bcd, 'the description is quoted (it has spaces)')
check('"d3d9.customDriver=nv4_disp.dll"' in bcd, 'the driver is NVIDIA\'s')
check('static let olderNvidiaName = "NVIDIA GeForce 7900 GS"' in bcd, 'the prefs use the same name')
m = re.search(r'if nvidia \{.*?\n        \}(.*?)// The game\'s own settings', bcd, re.S)
check(m is not None and 'if olderNvidia { dxmtExtra += D3D9Identity.olderNvidia.options }' in m.group(1),
      'after the NVIDIA ids, so its Direct3D 9 ids win')
check('olderNvidia: olderNvidia, card: card, profile: profile)' in bcd and 'D3D9Identity.syncGamePrefs(appID: appID, olderNvidia: olderNvidia)' in bcd,
      'a library launch passes the switch and keeps the prefs in step')

# The switch.
check('olderNvidiaKey = "madeira.library.olderNvidia"' in prefs and 'func setOlderNvidia(' in prefs, 'LibraryPrefs keeps it per game')
check('compatLabel("Older NVIDIA card (Direct3D 9)"' in library and 'LibraryPrefs.setOlderNvidia(on, for: entry.windowsPath)' in library,
      'Game details > Compatibility shows it')
check('olderNvidia = LibraryPrefs.olderNvidia(windowsPath)' in library, 'the settings page reads it')

# The prefs files.
check('22380: "FalloutNV/FalloutPrefs.ini"' in bcd and '22300: "Fallout3/FalloutPrefs.ini"' in bcd,
      'New Vegas and Fallout 3 prefs are known')

# prefsText, in Python: the same rules.
NAME = 'NVIDIA GeForce 7900 GS'


def prefs_text(text, older, metal):
    lines = text.split('\n'); changed = False
    for i, raw in enumerate(lines):
        cr = raw.endswith('\r'); line = raw[:-1] if cr else raw
        if not line.lower().startswith('sd3ddevice='):
            continue
        key = line.split('=', 1)[0]; cur = line[len(key) + 1:].strip('" \t')
        wanted = (None if cur == NAME else NAME) if older else (metal if cur == NAME else None)
        if wanted is None:
            continue
        lines[i] = f'{key}="{wanted}"' + ('\r' if cr else ''); changed = True
    return '\n'.join(lines) if changed else None


src = '[Display]\r\nsD3DDevice="Apple M4 GPU"\r\niSize W=1280\r\n'
on = prefs_text(src, True, 'Apple M4 GPU')
check(on == '[Display]\r\nsD3DDevice="NVIDIA GeForce 7900 GS"\r\niSize W=1280\r\n', 'on: the 7900 GS, CRLF kept')
check(prefs_text(on, True, 'Apple M4 GPU') is None, 'on again: nothing to write')
check(prefs_text(on, False, 'Apple M4 GPU') == src, 'off: the Metal name back')
check(prefs_text('sD3DDevice="Something Else"\n', False, 'Apple M4 GPU') is None, 'off: a name we did not write stays')
for rule in ['line.lowercased().hasPrefix("sd3ddevice=")', 'current == olderNvidiaName ? nil : olderNvidiaName',
             'current == olderNvidiaName ? metalName : nil', '(cr ? "\\r" : "")']:
    check(rule in bcd, f'Swift has the same rule: {rule}')

# DXMT reads d3d9.customDriver.
d3d9 = root / 'dxmt/src/d3d9/d3d9_interface.cpp'
if d3d9.exists():
    check('cfg.getOption<std::string>("d3d9.customDriver", "")' in d3d9.read_text(encoding='utf-8'),
          'the dxmt submodule reads d3d9.customDriver')
else:
    print('SKIP: dxmt submodule not checked out')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
