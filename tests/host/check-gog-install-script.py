#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Madeira contributors
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""GOG install scripts (goggame-<id>.script, docs/GOG.md "Install script").

Synthetic data only. Compiles app/Madeira/SwiftGOG/GOGInstallScript.swift with
tests/host/gog-script/main.swift and runs it (setRegistry values, placeholders,
language and bitness filters, script names), then checks statically that the
downloader keeps only the install script among GOG's support files, that depot
lists are de-duplicated, and that a play writes the values before Wine starts.
Needs `swiftc` (or SWIFTC=); without it the compiled part is skipped unless
--require-swift.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


downloader = (app / 'SwiftGOG/GOGDownloader.swift').read_text()
files = downloader[downloader.index('    static func files(_ data: Data, product: String)'):]
files = files[:files.index('\n    }\n')]
require('GOGInstallScript.isScriptName(name)' in files and 'path = name' in files,
        'downloader: of the support files only goggame-<id>.script is kept, at the folder root')
library = (app / 'GOGLibrary.swift').read_text()
require('files = GOGDepot.unique(files)' in library, 'download: each path once across depots')
write = library[library.index('    func writeInstallScriptRegistry('):]
write = write[:write.index('\n    }\n')]
require('wineserver_is_running() == 0' in write and 'wine_process_is_running() == 0' in write,
        'registry written only while no session runs')
require('SteamInstallRegistry.write(' in write, 'registry written with the Steam install-script writer (both views)')
content = (app / 'ContentView.swift').read_text()
at = content.index('GOGLibrary.shared.writeInstallScriptRegistry(for: entry)')
require(at < content.index('GOGGalaxy.shared.prepare(entry)'), 'a play writes the values before the game starts')
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text()
require('SwiftGOG/GOGInstallScript.swift in Sources' in project, 'GOGInstallScript.swift in the Xcode project')

swiftc = os.environ.get('SWIFTC') or shutil.which('swiftc')
if not swiftc:
    print('check-gog-install-script: swiftc unavailable; compiled part skipped')
    if '--require-swift' in sys.argv:
        failures += 1
else:
    with tempfile.TemporaryDirectory(dir='/tmp') as tmp:
        exe = Path(tmp) / 'gog-script'
        r = subprocess.run([swiftc, str(app / 'SwiftGOG/GOGInstallScript.swift'), str(root / 'tests/host/gog-script/main.swift'),
                            '-o', str(exe)], capture_output=True, text=True)
        run = subprocess.run([str(exe)], capture_output=True, text=True) if r.returncode == 0 else None
        if run is not None:
            print(run.stdout.strip())
        require(run is not None and 'ALL OK' in run.stdout,
                'GOGInstallScript host test' + ('' if run else ': does not compile\n' + r.stderr[-3000:]))
print('check-gog-install-script: ' + ('ok' if failures == 0 else f'{failures} FAILED'))
sys.exit(1 if failures else 0)
