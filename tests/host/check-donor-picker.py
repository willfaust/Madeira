#!/usr/bin/env python3
"""Settings > Memory and sync: the Donor pool picker is open with the swap tier off.

Since ml2200, donor-pool-mb without swap-mb starts the donor pool on its own
(WineProcessBridge.m sets MADEIRA_SWAP_DONOR_ONLY; virtual_ios.c ios_swap_init),
unless madeira.cfg has donor-only = 0. The picker used to be greyed out unless
the swap tier was on (Discord, Nov 2026), so players had to turn Swap on, pick
Donor and turn Swap off again.

Source checks only (no swiftc here):
1. The Donor pool picker is disabled only when the swap tier is off AND donor-only = 0.
2. Swap coverage and 32-bit programs are open while either stage is on.
3. donorAlone reads donor-only with default 1, the same default as WineProcessBridge.m.
4. The footer no longer says the donor pool needs the swap tier.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
lib = (root / 'app/Madeira/Library.swift').read_text()
bridge = (root / 'app/Madeira/WineProcessBridge.m').read_text()
failures = []


def check(cond, what):
    print(('PASS: ' if cond else 'FAIL: ') + what)
    if not cond:
        failures.append(what)


check('(donor-alone)' in lib, 'marker comment (donor-alone) is in Library.swift')
donor = re.search(r'mbPicker\("Donor pool".*?\n\s*\.disabled\(([^\n]*)\)\n', lib, re.S)
check(donor is not None and donor.group(1).strip() == 'swapMB == 0 && !Self.donorAlone',
      'Donor pool picker: greyed out only with the swap tier off and donor-only = 0')
check(lib.count('.disabled(!tierOn)') == 2, 'Swap coverage and 32-bit programs follow tierOn')
check('.disabled(swapMB == 0)' not in lib, 'nothing in Memory and sync is greyed out by the swap tier alone')
check('private var tierOn: Bool { swapMB > 0 || (donorPoolMB > 0 && Self.donorAlone) }' in lib,
      'tierOn: the swap tier, or the donor pool on its own')
check('static var donorAlone: Bool { (Int(MadeiraConfig.get("donor-only") ?? "") ?? 1) != 0 }' in lib,
      'donorAlone reads donor-only, default on')
check('madeira_cfg_int("donor-only", 1)' in bridge, 'the launch reads donor-only with the same default (1)')
check('needs the swap tier on' not in lib, 'the footer no longer says the swap tier is needed')
check('It works without the swap tier too' in lib, 'the footer says the donor pool works without the swap tier')

if failures:
    print(f'{len(failures)} check(s) failed')
    sys.exit(1)
print('all donor picker checks passed')
