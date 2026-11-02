#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Madeira contributors
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Static host checks for the EA app store (docs/EA.md).

Never contacts EA. Checks licence headers, every EA source in the Xcode project,
the device-only Keychain item, no token or code in a log line, EA games kept out
of Other games, every Settings sheet switch handling the EA sign-in, the settings
catalog entry, the Game details section, the launch preparation and environment
clearing in ContentView, the EA app's environment list, and that the EA code
stands on its own (no other store's types).
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


sources = sorted((app / 'SwiftEA').glob('*.swift')) + [app / 'EALibrary.swift', app / 'EAGames.swift']
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text()
for path in sources:
    require(path.exists(), f'{path.name}: exists')
sources = [p for p in sources if p.exists()]
for path in sources:
    text = path.read_text()
    require(text.startswith('// SPDX-License-Identifier: GPL-3.0-or-later'), f'{path.name}: licence header')
    require(re.search(r'/\* (SwiftEA/)?' + re.escape(path.name) + r' in Sources \*/,', project) is not None,
            f'{path.name}: in the Xcode project sources')
    require('thebcd69' not in text and 'BCD Material' not in text, f'{path.name}: no BCD code or credit lines')

api = (app / 'SwiftEA/EAAPI.swift').read_text()
require('kSecAttrAccessibleWhenUnlockedThisDeviceOnly' in api and 'kSecAttrSynchronizable as String: false' in api,
        'tokens: one device-only Keychain item, not synchronised')
for path in sources:
    for line in path.read_text().splitlines():
        if 'EALog.event' in line or 'LogStore' in line:
            compact = line.replace(' ', '')
            bad = [w for w in ('accessToken', 'refreshToken', 'code', 'displayName', 'userID', 'personaID', 'accountName', 'opaque', 'signature')
                   if '\\(' + w in compact]
            if bad:
                require(False, f'{path.name}: no credential in a log line: {line.strip()[:80]}')

library = (app / 'Library.swift').read_text()
require('var eaOfferID: String?' in library, 'library entries record their EA offer')
require(library.count('$0.eaOfferID == nil') >= 2,
        'Other games: no EA game (it is listed in the EA app section)')
require('case .eaSignIn: EASignInView()' in library and 'eaSignIn' in library[library.index('enum SettingsSheet'):],
        'Settings: the EA sign-in sheet')
require('EASettingsSection(open: { settingsSheet = $0 })' in library, 'Settings: the EA app section')
require('EAGamesSection(search: search' in library, 'Library: the EA app section')
require('EAEntrySection(entry: $entry)' in library, 'Game details: the EA app section')
require('if !EALibrary.shared.signedIn {' in library, 'Play: an EA game needs the sign-in')
require('entry.eaOfferID != nil && $0.eaOfferID == entry.eaOfferID' in library, 'save: one entry per EA game')
require('func upsertEA(' in library and 'func removeEA(' in library, 'library model: EA entries come and go with installs')
content = (app / 'ContentView.swift').read_text()
require('case .eaSignIn: EASignInView()' in content, 'the developer strip handles the EA sign-in sheet')
require('EALibrary.shared.sessionChanged(active: true)' in content, 'EA downloads pause for a game session')
require('if entry.eaOfferID == nil { EALibrary.clearEnvironment() }' in content, 'every other launch clears the EA environment')
require('try await EALibrary.shared.prepareLaunch(entry)' in content, 'an EA game is prepared before its session')
steam = (app / 'SteamGames.swift').read_text()
require('EALibrary.shared.refreshLibrary(interactive: true)' in steam, 'pull to refresh refreshes the EA library')
catalog = (app / 'ConfigCatalog.generated.swift').read_text()
require('key: "env.MADEIRA_EA"' in catalog, 'Settings › All settings lists env.MADEIRA_EA')
ea = '\n'.join(path.read_text() for path in sources)
require(re.search(r'\b(Epic|GOG)[A-Z]\w*', ea) is None, 'EA code stands on its own (no Epic or GOG store types)')

# The environment an EA game gets, and that it is the list that is cleared.
lib = (app / 'EALibrary.swift').read_text()
names = re.search(r'static let environmentNames = \[(.*?)\]', lib, re.S)
require(names is not None, 'EALibrary names the EA environment')
if names:
    listed = set(re.findall(r'"([A-Za-z]+)"', names.group(1)))
    block = re.search(r'let environment: \[String: String\] = \[(.*?)\n        \]', lib, re.S)
    used = set(re.findall(r'"([A-Za-z]+)": ', block.group(1))) if block else set()
    require(block is not None and used == listed, f'the launch environment and the cleared list are the same ({len(listed)} names)')
    for name in ('EALsxPort', 'EARtPLaunchCode', 'ContentId', 'EALaunchUserAuthToken', 'EAAccessTokenJWS', 'EALicenseToken'):
        require(name in listed, f'environment: {name}')
require('"EALsxPort": String(EAService.port)' in lib, 'the game is told the service port Madeira listens on')
service = (app / 'SwiftEA/EAService.swift').read_text()
require('static let port: UInt16 = 3216' in service, 'the service listens on the EA app\'s port')
require('inet_addr("127.0.0.1")' in service, 'the service listens on the loopback only')
for name in ('ChallengeResponse', 'GetConfig', 'GetProfile', 'GetSetting', 'GetInternetConnectedState', 'GetGameInfo', 'GetAllGameInfo',
             'GetAuthCode', 'RequestLicense', 'QueryEntitlements', 'GetPresence', 'SetPresence', 'GetBlockList', 'QueryFriends',
             'QueryPresence', 'QueryOffers', 'QueryImage', 'GetVoipStatus', 'IsProgressiveInstallationAvailable', 'AreChunksInstalled'):
    require(f'case "{name}"' in service, f'service answers {name}')
licence = (app / 'SwiftEA/EALicense.swift').read_text()
require('ProgramData/Electronic Arts/EA Services/License' in licence, 'licences go where the game reads them')
require('renewAfter: TimeInterval = 14 * 24 * 3600' in licence, 'licences are renewed after two weeks')
formats = (app / 'SwiftEA/EAFormats.swift').read_text()
require('[65, 50, 114, 45, 208, 130, 239, 176, 220, 100, 87, 197, 118, 104, 202, 9]' in formats, 'the licence key')
require('"qrc:///html/login_successful.html"' in api, 'the sign-in redirect is the EA app\'s own')
docs = (root / 'docs/EA.md').read_text()
require('Maxima' in docs and 'GPL-3.0' in docs, 'docs credit Maxima')
require('tests/host/check-ea-formats.py' in docs and 'tests/host/check-ea-store.py' in docs, 'docs name both checks')

print('\nAll EA store checks passed.' if failures == 0 else f'\n{failures} EA store check(s) failed.')
raise SystemExit(1 if failures else 0)
