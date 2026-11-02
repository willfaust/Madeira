#!/usr/bin/env python3
"""Game details › Steam › Installed DLC: the DLC that the game's install record
(appmanifest_<id>.acf, InstalledDepots entries with a dlcappid) says is installed,
named from Steam when signed in. Source checks only (the app is needed to build).
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


install = (app / 'SteamInstall.swift').read_text(encoding='utf-8')
games = (app / 'SteamGames.swift').read_text(encoding='utf-8')
owned = (app / 'SteamOwnedLibrary.swift').read_text(encoding='utf-8')

reader = install[install.index('static func installedDLC('):install.index('static func sizeOnDisk(')]
check('state["InstalledDepots"]?.fields' in reader and 'depot["dlcappid"]' in reader, 'reads dlcappid from InstalledDepots')
check('.prefix(512)' in reader and 'dlc > 0' in reader and 'max(size, 0)' in reader, 'bounded and ignores bad values')
check('Task.detached(priority: .utility)' in games and 'SteamInstallFiles.installedDLC(' in games, 'the record is read off the main thread')
check('LabeledContent("Installed DLC", value: "None")' in games and 'ForEach(dlc) { item in' in games, 'Game details shows the list, or None')
check('dlcNames[item.id] ?? "DLC \\(item.id)"' in games, 'falls back to the DLC app ID when no name is known')
check('[steam-dlc] app=' in games, 'logs what it found')
names = owned[owned.index('func names(ofDLC ids: [Int], gameAppID: Int)'):]
names = names[:names.index('\n    }\n') + 6]
check('guard Self.enabled, signedIn, !inSession' in names and '.prefix(32)' in names, 'asks Steam for names only when signed in, outside a session, at most 32')
check('fetcher.fetchAppInfos(appIDs: missing.map' in names, 'DLC names are asked for in one request')
check('depot.dlcAppID { keep(Int(dlc), depot.name) }' in names, "unnamed DLC fall back to their depot name in the game's app info")
check('[steam-dlc] names asked=' in names and '[steam-dlc] names skipped' in names, 'logs how many names were found')
check('names(ofDLC: list.map(\\.id), gameAppID: appID)' in games, 'Game details passes the game app ID')
check('struct InstalledDLC: Identifiable' in games, 'rows are identifiable')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
