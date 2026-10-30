#!/usr/bin/env python3
"""Steam downloads include the DLC the account owns (SwiftSteam).

Madeira's own Steam downloader used to leave out every depot with a dlcappid, so
owned DLC that ships as depots of the game never arrived (Fallout: New Vegas's
Courier's Stash packs). Now a DLC depot is installed when the account's licenses
include it, its install record names its DLC app, and an owned DLC depot Steam
still refuses a key for is left out instead of failing the whole install.

Source checks only; tests/host/check-steam-library.py runs the selection itself.
"""
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[2]
steam = root / 'app/Madeira/SwiftSteam'
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


info = (steam / 'Library/SteamAppInfo.swift').read_text(encoding='utf-8')
downloader = (steam / 'Content/DepotDownloader.swift').read_text(encoding='utf-8')
library = (root / 'tests/host/check-steam-library.py').read_text(encoding='utf-8')

check('ownedDLC: Set<UInt32> = []) -> [DepotInfo]' in info and '(d.dlcAppID.map { ownedDLC.contains(d.depotID) && !dlcOff.contains($0) } ?? true)' in info,
      'the selection takes a DLC depot only when it is owned and not turned off')
check('ownedDLC = await ownedDepots() ?? []' in downloader and 'app.installDepots(ownedDLC: ownedDLC)' in downloader,
      "the download asks for the account's depots and passes them to the selection")
check('depotSelectionSummary(ownedDLC: ownedDLC)' in downloader, 'the selection log shows owned DLC as selected')
check(re.search(r'catch SteamError\.depotKeyNotFound\(let refused\) where depot\.dlcAppID != nil \{\s*//[^\n]*\n\s*licenseSkipped\.append\(refused\)\s*continue',
                downloader) is not None, 'a refused key for a DLC depot skips that DLC only')
check('dlcAppID: dlcApps[plan.depotID]' in downloader, "the record names each DLC depot's app, as Valve's client writes it")
check('info.installDepots(ownedDLC: [107])' in library, 'check-steam-library.py covers the selection')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
