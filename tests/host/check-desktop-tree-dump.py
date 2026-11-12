#!/usr/bin/env python3
"""The Wine desktop's window-tree dump is off unless asked for (app/Madeira/Winios/Winios.m).

Every desktop session walked all of its windows twelve times a minute and wrote the result to the
log. It now needs env.MADEIRA_DESKTOP_TREE_DUMP = 1 as well as the desktop switch the session sets.
Source checks only: no Wine runs.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
winios = (root / 'app/Madeira/Winios/Winios.m').read_text()
catalog = (root / 'app/Madeira/ConfigCatalog.generated.swift').read_text()
failures = 0


def check(ok, label):
    global failures
    print(('PASS: ' if ok else 'FAIL: ') + label)
    failures += 0 if ok else 1


dump = winios[winios.index('Desktop debugging: dump the full window tree'):winios.index('return winios_drain_input();')]
check('getenv("MADEIRA_DESKTOP_TREE_DUMP")' in dump and "d && *d == '1' && t && *t == '1'" in dump,
      'the dump needs MADEIRA_DESKTOP_TREE_DUMP=1 besides the desktop switch')
check('winios_dump_window_tree();' in dump and dump.count('winios_dump_window_tree();') == 1, 'it is still there for whoever turns it on')
check('MADEIRA_DESKTOP_TREE_DUMP' in catalog, 'the config catalog lists the switch')
print('PASS' if not failures else f'FAILED ({failures})')
sys.exit(1 if failures else 0)
