#!/usr/bin/env python3
"""Shape and spacing audit for the new look (Cameron, Nov 9: "it seems sloppy").

Polished apps draw every corner, gap and text size from a few fixed values. This lists every
corner radius, padding/spacing and fixed font size in the new-look code, says which are off the
scale below, and checks that shapes drawn inside other shapes are concentric (inner radius =
outer radius - the gap between them, Apple's Liquid Glass rule).

Not a pass/fail test: it prints a report. `--strict` exits 1 when anything is off the scale.
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

root = Path(__file__).resolve().parents[2]
app = root / 'app' / 'Madeira'

# The scale (points). Capsule (fully round) is always fine for pills, buttons and bars.
RADII = {8: 'settings icon badges', 16: 'covers, step tiles, small cards', 22: 'cards and grouped lists',
         28: 'sheets and floating panels'}
# The same values by name (NewLook.swift), and shapes worked out from another one (concentric
# rings, an icon's rounding as a share of its size): all fine.
NAMED = {'NewLook.badgeRadius': 8, 'NewLook.coverRadius': 16, 'NewLook.cardRadius': 22, 'NewLook.sheetRadius': 28}
DERIVED = ('Radius - inset', 'size * ')
SPACING = {2, 4, 6, 8, 12, 16, 20, 24, 28, 32, 40, 48}

# Where the new look lives: all of NewLook.swift and PadHighlight.swift, and the new-look parts of Library.swift.
def new_look_lines():
    for name in ['NewLook.swift', 'PadHighlight.swift']:
        for n, line in enumerate((app / name).read_text(encoding='utf-8').splitlines(), 1):
            yield name, n, line
    lines = (app / 'Library.swift').read_text(encoding='utf-8').splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith('// MARK: - New look (NewLook.swift)'))
    for n in range(start, len(lines)):
        yield 'Library.swift', n + 1, lines[n]

radius_re = re.compile(r'(?:cornerRadius:\s*|newLookGlass\(|newLookCard\()([^,)\n]+)')
pad_re = re.compile(r'\.padding\((?:\.[a-zA-Z]+,\s*)?(-?[0-9.]+)\)')
spacing_re = re.compile(r'spacing:\s*(-?[0-9.]+)')
font_re = re.compile(r'\.system\(size:\s*([0-9.]+)')

radii, pads, fonts = defaultdict(list), defaultdict(list), defaultdict(list)
for file, n, line in new_look_lines():
    code = line.split('//')[0]
    for m in radius_re.finditer(code):
        expr = m.group(1).strip()
        if expr in NAMED:
            radii[str(NAMED[expr])].append(f'{file}:{n}')
            continue
        if any(d in code for d in DERIVED) or expr in ('0', 'cornerRadius'):
            continue  # derived from another shape (checked under CONCENTRIC)
        nums = re.findall(r'\b\d+(?:\.\d+)?\b', expr)
        if 'radius' in expr and not nums:
            continue  # a parameter passed through
        for v in nums or [expr]:
            radii[v].append(f'{file}:{n}')
    for m in pad_re.finditer(code):
        pads[m.group(1)].append(f'{file}:{n}')
    for m in spacing_re.finditer(code):
        pads[m.group(1)].append(f'{file}:{n}')
    for m in font_re.finditer(code):
        fonts[m.group(1)].append(f'{file}:{n}')

def num(v):
    try:
        return float(v)
    except ValueError:
        return None

off = 0
print('CORNER RADII (scale: ' + ', '.join(f'{k} {v}' for k, v in RADII.items()) + '; Capsule)')
for v, where in sorted(radii.items(), key=lambda kv: (num(kv[0]) is None, num(kv[0]) or 0)):
    ok = num(v) is not None and num(v) in RADII
    off += 0 if ok else len(where)
    print(f"  {'ok ' if ok else 'OFF'} {v:>6} x{len(where):<3} {', '.join(where[:6])}{' ...' if len(where) > 6 else ''}")

print('\nPADDING AND SPACING (scale: ' + ', '.join(str(s) for s in sorted(SPACING)) + ')')
for v, where in sorted(pads.items(), key=lambda kv: num(kv[0]) or 0):
    ok = abs(num(v) or 0) in SPACING or num(v) == 0
    off += 0 if ok else len(where)
    print(f"  {'ok ' if ok else 'OFF'} {v:>6} x{len(where):<3} {', '.join(where[:6])}{' ...' if len(where) > 6 else ''}")

print('\nFIXED FONT SIZES (better: text styles like .headline, which follow the user\'s text size)')
for v, where in sorted(fonts.items(), key=lambda kv: num(kv[0]) or 0):
    print(f"  {v:>6} x{len(where):<3} {', '.join(where[:6])}{' ...' if len(where) > 6 else ''}")

# Concentric: a glass bar of radius R with .padding(p) inside it should hold shapes of radius R - p.
print('\nCONCENTRIC CHECKS')
look = (app / 'NewLook.swift').read_text(encoding='utf-8')
bar = re.search(r'\.padding\((\d+)\)[^\n]*\n\s*\.newLookGlass\(\)', look)
tab = re.search(r'\.padItem\("tab-\\\(item\.rawValue\)", capsule: true, inset: 0\)', look)
if bar and tab:
    print(f'  tab bar: a capsule; the tabs are capsules {bar.group(1)} pt inside it (concentric), and the'
          ' highlight sits on the tab\'s own edge (inset 0), so it stays inside the bar')
else:
    print('  tab bar: pattern not found (check by hand)')
ring = (app / 'PadHighlight.swift').read_text(encoding='utf-8')
if 'cornerRadius: max(0, cornerRadius - inset)' in ring and '.padding(inset)' in ring:
    print('  highlight ring: the item\'s own shape moved out or in by `inset`, corners changed by the same amount (concentric)')
else:
    print('  highlight ring: concentric rule not found (check PadItem by hand)')

print(f'\n{off} values off the scale.')
sys.exit(1 if off and '--strict' in sys.argv else 0)
