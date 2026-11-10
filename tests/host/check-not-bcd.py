#!/usr/bin/env python3
"""Checks that new code does not copy BCD's (GPL-3.0-only; Cameron's rule: learn from it, never copy).

    python3 tests/host/check-not-bcd.py <BCD source folder> [base commit]

Takes every line the working tree adds to app/Madeira since `base` (default: the commit before
the new look, c0218d53) and looks for it in BCD's Swift files:
  SAME LINE   a changed line of real code (24+ characters once spaces are squeezed) that is in BCD
  SAME RUN    3 changed lines in a row that are also 3 lines in a row in BCD (after squeezing)
Lines Madeira already had at `base` (moved, not new) are left out: BCD started from Madeira, so
they match because both come from the same place. A brace-only or short line never counts.
Common SwiftUI one-liners match by chance (".buttonStyle(.plain)"), so SAME LINE lists them for a
look; SAME RUN is the one that would mean copying. The BCD folder is a read-only reference kept
outside the repository; nothing from it goes into a branch or a build.
Exits 1 when it finds a SAME RUN.
"""
import re
import subprocess
import sys
from pathlib import Path

if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(2)
bcd = Path(sys.argv[1])
base = sys.argv[2] if len(sys.argv) > 2 else 'c0218d53'
root = Path(__file__).resolve().parents[2]

def squeeze(line):
    code = line.split('//')[0]
    return re.sub(r'\s+', ' ', code).strip()

bcd_lines, bcd_runs = set(), set()
for f in bcd.rglob('*.swift'):
    rows = [squeeze(l) for l in f.read_text(encoding='utf-8', errors='replace').splitlines()]
    rows = [r for r in rows if r]
    bcd_lines.update(rows)
    bcd_runs.update(tuple(rows[i:i + 3]) for i in range(len(rows) - 2))

# Every line Madeira's own Swift files had at the base: moved code is not new code.
names = subprocess.run(['git', 'ls-tree', '-r', '--name-only', base, 'app/Madeira'], cwd=root,
                       capture_output=True, text=True, check=True).stdout.split()
base_lines = set()
for name in names:
    if name.endswith('.swift'):
        text = subprocess.run(['git', 'show', f'{base}:{name}'], cwd=root, capture_output=True, text=True).stdout
        base_lines.update(squeeze(l) for l in text.splitlines())

def counts(l):
    return l is not None and len(l) >= 16 and re.search(r'[A-Za-z]{3}', l) and l not in base_lines

diff = subprocess.run(['git', 'diff', '-U0', base, '--', 'app/Madeira/*.swift'], cwd=root,
                      capture_output=True, text=True, check=True).stdout
added, file = [], None
for line in diff.splitlines():
    if line.startswith('+++ '):
        file = line[6:]
    elif line.startswith('+') and not line.startswith('+++'):
        added.append((file, line[1:]))
    elif line.startswith('@@'):
        added.append((file, None))   # a break between hunks

same_line = [(f, l) for f, l in added if l is not None and len(squeeze(l)) >= 24 and counts(squeeze(l)) and squeeze(l) in bcd_lines]
rows = [(f, None if l is None else squeeze(l)) for f, l in added if l is None or squeeze(l)]
same_run = []
for i in range(len(rows) - 2):
    chunk = rows[i:i + 3]
    if any(l is None for _, l in chunk):
        continue
    if tuple(l for _, l in chunk) in bcd_runs and sum(1 for _, l in chunk if counts(l)) >= 2:
        same_run.append(chunk)

print(f'{sum(1 for _, l in added if l is not None)} added lines since {base}, against {len(bcd_lines)} BCD lines')
print(f'SAME LINE ({len(same_line)}): look at each; a common SwiftUI line is fine')
for f, l in same_line:
    print(f'  {f}: {squeeze(l)[:110]}')
print(f'SAME RUN ({len(same_run)}): 3 lines in a row also in BCD')
for chunk in same_run:
    print(f'  {chunk[0][0]}: ' + ' | '.join(l[:50] for _, l in chunk))
sys.exit(1 if same_run else 0)
