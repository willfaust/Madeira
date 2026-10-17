#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""In-app pairing for Built-in StikJIT (iOS 27), on the host.

1. The C header the app imports declares exactly the functions the Rust
   library exports, and the library's own tests pass (`cargo test`, when cargo
   is on PATH): the advertisement carries the host identity, cancellation ends
   the wait, and stray or silent connections do not end or block it.
2. Source checks: the app advertises through mDNSResponder (no multicast
   entitlement), only on iOS 27 and later, keeps the session alive until the
   accept returns, stores the result through the same validation as an import,
   logs no PIN or device name, and offers the three JIT choices in both setup
   screens; Info.plist, the Xcode project, .gitignore and the notices are in
   step.
"""
from pathlib import Path
import os
import plistlib
import re
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
crate = root / 'build/rppairing-ios'
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def block(text, header):
    start = text.index(header)
    brace = text.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


rust = (crate / 'src/lib.rs').read_text()
header = (app / 'MadeiraRPPairing.h').read_text()
pairing = (app / 'JITPairing.swift').read_text()
setup = (app / 'JITSetup.swift').read_text()
onboarding = (app / 'Onboarding.swift').read_text()
bridging = (app / 'Madeira-Bridging-Header.h').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
gitignore = (root / '.gitignore').read_text()

# ------------------------------------------------------------------ the C interface
exported = set(re.findall(r'#\[unsafe\(no_mangle\)\]\s*pub (?:unsafe )?extern "C" fn (\w+)', rust))
declared = set(re.findall(r'\b(madeira_rppairing_\w+)\s*\(', header))
require(len(exported) == 12 and exported == declared,
        f'MadeiraRPPairing.h declares exactly the exported functions ({sorted(exported ^ declared) or "in step"})')
require('#import "MadeiraRPPairing.h"' in bridging, 'the bridging header imports the pairing interface')
require('PairableHost' in rust and 'RpPairingSocket::new_device' in rust and 'mdns' not in rust.lower().replace('mdns_txt_records', ''),
        "the library uses idevice's pairable host and does no mDNS itself")
require(re.search(r'idevice = \{ version = "=[0-9.]+"', (crate / 'Cargo.toml').read_text()) is not None
        and (crate / 'Cargo.lock').exists(), 'idevice is pinned to an exact version with a lockfile')

cargo = shutil.which('cargo')
if cargo:
    run = subprocess.run([cargo, 'test', '--locked', '--quiet'], cwd=crate, capture_output=True, text=True, timeout=900)
    require(run.returncode == 0, 'cargo test: the pairing library\'s host tests pass')
    if run.returncode:
        sys.stdout.write((run.stdout + run.stderr)[-4000:])
else:
    print('SKIP: cargo not on PATH, library tests not run')

# ------------------------------------------------------------------ the app side
require('DNSServiceRegister(' in pairing and '"_remotepairing-pairable-host._tcp"' in pairing
        and 'NetService' not in pairing,
        'the service is published through mDNSResponder (dns_sd) as a pairable host')
require('majorVersion: 27' in pairing and 'static var isSupported' in pairing, 'on-device pairing is offered from iOS 27')
finished = block(pairing, 'private func finished(')
require('madeira_rppairing_free(session)' in finished and pairing.count('madeira_rppairing_free(') == 2,
        'the session is freed only after its accept returned (or when it never started)')
require('madeira_rppairing_cancel(session)' in block(pairing, 'func cancel(reason:'),
        'cancelling signals the running accept')
require('try JITCoordinator.shared.storeOnDevicePairing(data)' in finished, 'a pairing is stored through the coordinator')
store = block(setup, 'func storeOnDevicePairing(')
require('JITPairingFileStore.store(data, source: .onDevice)' in store and 'method = .builtIn' in store,
        'the stored pairing selects Built-in StikJIT')
# The pairing file is a credential for the device: Keychain, this device only, never Documents.
pstore = setup[setup.index('enum JITPairingFileStore {'):setup.index('final class JITCoordinator')]
require('SecItemAdd(add as CFDictionary, nil)' in pstore
        and 'kSecAttrAccessibleWhenUnlockedThisDeviceOnly' in pstore
        and 'SecItemCopyMatching(' in pstore,
        'the pairing file is kept in the Keychain, this device only, readable while unlocked')
require('data.write(' not in pstore and pstore.count('.documentDirectory') == 1
        and 'private static var legacyFolder' in pstore,
        'the pairing file is never written to Documents (only the old copy is read there)')
legacy = block(setup, 'private static func moveLegacyFile(')
require(legacy.index('try? store(data, source: kept)') < legacy.index('removeItem(at: file)'),
        'an old Documents copy is deleted only after the Keychain holds it')
require('try store(try Data(contentsOf: source), source: .imported)' in setup
        and 'dictionary["public_key"]' in block(setup, 'static func store('),
        'imports and on-device pairings share one validation')
require('OnDevicePairing.shared.cancel()' in block(setup, 'func importPairingFile('),
        'an import stops a waiting on-device pairing, so it cannot overwrite the import')
for line in pairing.splitlines():
    if 'log(' in line and ('\\(' in line):
        require(re.search(r'\\\((pin|code|device|name|identifier)', line) is None,
                f'no PIN or device name in "{line.strip()[:70]}"')
require('".pairing.*"' in pairing and '"session"' in pairing, 'the background task uses the permitted .pairing.* identifier')

with (app / 'Info.plist').open('rb') as f:
    plist = plistlib.load(f)
require('_remotepairing-pairable-host._tcp' in plist.get('NSBonjourServices', []), 'Info.plist declares the Bonjour service')
require(bool(plist.get('NSLocalNetworkUsageDescription')), 'Info.plist explains Local Network access')
require('$(PRODUCT_BUNDLE_IDENTIFIER).pairing.*' in plist.get('BGTaskSchedulerPermittedIdentifiers', []),
        'Info.plist permits the pairing background task')

# ------------------------------------------------------------------ the three choices
choices = block(onboarding, 'private var jitChoices')
require(all(f'jitChoice("{title}"' in choices for title in ['In-app', 'In-app with pairing file', 'StikDebug'])
        and 'enabled: OnDevicePairing.isSupported' in choices,
        'setup: In-app (iOS 27), In-app with pairing file, StikDebug')
require('OnDevicePairingPanel()' in block(onboarding, 'private var onDeviceGuide')
        and 'pairing.start()' in block(onboarding, 'private func startPairing'),
        'setup: the on-device guide pairs and shows its progress')
require('pairing.start()' in block(setup, 'struct JITSetupView: View'), 'Settings › JIT setup can pair on the device')

# ------------------------------------------------------------------ packaging
for marker in ['JITPairing.swift in Sources', 'libmadeira_rppairing.a in Frameworks', 'MadeiraRPPairing.h */ = {isa = PBXFileReference']:
    require(marker in project, f'Xcode project contains {marker}')
require('app/Madeira/libmadeira_rppairing.a' in gitignore and 'build/rppairing-ios/target/' in gitignore,
        'the built library and cargo output are ignored')
notices = app / 'legal/LICENSES-rppairing-crates.txt'
require(notices.exists() and 'idevice 0.1.68 (MIT)' in notices.read_text(), 'crate notices are bundled')
for path in ['THIRD-PARTY-NOTICES.md', 'app/Madeira/legal/THIRD-PARTY-NOTICES.md']:
    require('libmadeira_rppairing.a' in (root / path).read_text(), f'{path} lists on-device pairing')

if failures:
    print(f'check-jit-pairing: {failures} FAILED')
    sys.exit(1)
print('check-jit-pairing: PASS')
