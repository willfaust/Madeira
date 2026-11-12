#!/usr/bin/env python3
"""Controller walk-through, done on the code: every control on a new-look screen should be
reachable by the highlight, every scrolling page should follow it, and every layer should
have something to land on or an A of its own.

    python3 tests/host/check-pad-coverage.py          # report
    python3 tests/host/check-pad-coverage.py --strict # exit 1 on anything uncovered

A control counts as covered when a .padItem( or .menuPad( (or a padItem-registering style)
follows it before the next control starts at the same or a shallower indent. Rough by design:
it points at places to look, it does not prove a screen works.
"""
import re
import sys
from pathlib import Path

app = Path(__file__).resolve().parents[2] / 'app' / 'Madeira'

def region(name, start=None, end=None):
    lines = (app / name).read_text(encoding='utf-8').splitlines()
    a = next((i for i, l in enumerate(lines) if start and start in l), 0) if start else 0
    b = next((i for i, l in enumerate(lines) if end and end in l and i > a), len(lines)) if end else len(lines)
    return [(name, i + 1, lines[i]) for i in range(a, b)]

screens = {
    'New look screens (NewLook.swift)': region('NewLook.swift'),
    'Library tab bar and pages (Library.swift)': region('Library.swift', '// MARK: - New look (NewLook.swift)', '// MARK: - New look: the starting screen'),
    'Starting screen (Library.swift)': region('Library.swift', '// MARK: - New look: the starting screen'),
    "A game's pages (Library.swift)": region('Library.swift', '@ViewBuilder private var displayPage', '// MARK: - New look'),
}

control = re.compile(r'^\s*(Button\b|Toggle\b|Picker\b|Slider\b|Stepper\b|NavigationLink\b|TextField\b|Menu\b)')
covered_by = ('.padItem(', '.menuPad(', 'PadCardStyle', '.padLayer(', 'pageRow(')
skip_words = ('contextMenu', 'confirmationDialog', '.toolbar', 'alert(')

def indent(s):
    return len(s) - len(s.lstrip(' '))

uncovered = 0
for title, lines in screens.items():
    misses = []
    total = 0
    for k, (file, n, line) in enumerate(lines):
        code = line.split('//')[0]
        if not control.match(code):
            continue
        # Controls inside a context menu, dialog or toolbar are the system's own, not the highlight's.
        ctx = ' '.join(l for _, _, l in lines[max(0, k - 6):k])
        if any(w in ctx for w in skip_words):
            continue
        total += 1
        base = indent(line)
        found = any(c in code for c in covered_by)
        for _, _, nxt in lines[k + 1:k + 40]:
            if nxt.strip() and indent(nxt) <= base and control.match(nxt.split('//')[0]):
                break
            if any(c in nxt for c in covered_by):
                found = True
                break
            if nxt.strip().startswith('}') and indent(nxt) < base:
                break
        if not found:
            misses.append(f'{file}:{n}  {line.strip()[:90]}')
    uncovered += len(misses)
    print(f'{title}: {total} controls, {len(misses)} with no highlight item nearby')
    for m in misses:
        print('    ' + m)

# Every scrolling new-look page follows the highlight.
print()
for name in ['NewLook.swift', 'Library.swift']:
    text = (app / name).read_text(encoding='utf-8')
    readers = text.count('ScrollViewReader')
    follows = text.count('.padScrollFollow(')
    print(f'{name}: {readers} ScrollViewReader, {follows} .padScrollFollow')

# Every layer: a start item, or items under it, or an accept of its own.
print()
layer_re = re.compile(r'\.padLayer\("([^"]+)"(.*)')
for name in ['NewLook.swift', 'Library.swift', 'MenuPad.swift', 'SettingsPages.swift']:
    for n, line in enumerate((app / name).read_text(encoding='utf-8').splitlines(), 1):
        m = layer_re.search(line)
        if m:
            rest = m.group(2)
            how = 'start ' + re.search(r'start: ([^,)]+)', rest).group(1) if 'start:' in rest else 'settles on its top-left item'
            print(f'layer {m.group(1):<16} {name}:{n}  {how}{", own A" if "accept:" in rest else ""}')

print(f'\n{uncovered} control(s) to look at.')
sys.exit(1 if uncovered and '--strict' in sys.argv else 0)
