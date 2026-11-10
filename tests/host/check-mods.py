#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Game details > Mods (app/Madeira/ModsCore.swift, ModsArchive.swift, ModsView.swift).

A game's mods: a .zip, .7z, .rar or .fomod file, or a folder, unpacked into the
game's own mod store and turned on and off with a switch. Turning one on copies its
files into the game's folder (the game's own files backed up first); off brings
them back. FOMOD installers show their pages; Bethesda plugins go into
plugins.txt; BepInEx gets its winhttp line in the game's own config.

Source checks (every host): the Mods row sits above Advanced and is on the
controller's ring, the files are in the project, a mod never replaces a Steam file
or the game's program and is checked before anything is written, plugins.txt and
Fallout.ini, the BepInEx line is the game's own config (never madeira.cfg), the
install sheet can't be swiped away, the pickers copy, and every new text has six
languages.

Swift fixture (skipped without a compiler, required with --require-swift):
ModsCore.swift with tests/host/mods/main.swift: a FOMOD with two pages and a flag
condition, two mods that clash, on -> off -> on -> Remove leaving the game's folder
byte for byte as it was, the guards, plugins.txt, Fallout.ini and BepInEx.
"""
from pathlib import Path
import argparse, json, re, shutil, subprocess, sys, tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


core = (app / 'ModsCore.swift').read_text(encoding='utf-8')
archive = (app / 'ModsArchive.swift').read_text(encoding='utf-8')
view = (app / 'ModsView.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
strings = json.loads((app / 'Localizable.xcstrings').read_text(encoding='utf-8'))['strings']

# 1. The row on Game details, above Advanced, on the ring.
check('case .mods: return "Mods"' in library and 'case .mods: return "puzzlepiece.extension"' in library,
      'Game details has a Mods page with its title and icon')
check('[.library, .iniFiles, .mods, .advanced]' in library, 'the Mods row sits above Advanced, for every game but the Desktop')
check('detailRow("page:\\(item)", last: item == group.last, tap: { open(item) }) { pageRowLabel(item) }' in library and
      'pageGroups.flatMap { $0 }.map { "page:\\($0)" }' in library,
      'its row is a detailRow, so the controller ring stops on it and A opens it')
check('case .mods: ModsPage(game: modGame)' in library, 'the page opens ModsPage')
model = library[library.index('    private var modGame: ModGame {'):]
model = model[:model.index('\n    }\n') + 6]
check('GameProfile(windowsPath: windowsPath).text' in model and 'madeira.cfg' not in core + archive + view,
      "the BepInEx line goes into this game's own config, never madeira.cfg")
for name in ('ModsCore.swift', 'ModsArchive.swift', 'ModsView.swift'):
    check(sum(name in line for line in project.splitlines()) == 4, f'{name} is in the Xcode project (file, build file, group, sources)')

# 2. What a mod may not touch, checked before anything is written.
check(all(f'"{p}"' in core for p in ('steam_api', 'steamclient', 'tier0_s', 'vstdlib_s', 'gameoverlayrenderer')),
      "Valve's files are refused (steam_api*, steamclient* and the rest)")
check('throw ModError.gameProgram(name)' in core and 'game.program' in core, "the game's program (.exe) is refused")
check('throw ModError.outside(relative)' in core and 'ModPath.inside(' in core, "nothing lands outside the game's folder")
enable = core[core.index('    func enable(_ id: String'):]
enable = enable[:enable.index('\n    }\n')]
check(enable.index('for (relative, _) in list { try guardFile(relative) }') < enable.index('try put('),
      'every file is checked before the first one is written')
check(enable.index('try fm.moveItem(at: current, to: backups.appendingPathComponent(name))') < enable.index('try put('),
      "the game's own file is backed up before a mod's replaces it")

# 3. Bethesda games and BepInEx.
check('"/AppData/Local/" + bethesda.folder + "/plugins.txt"' in core and 'var starred: Bool { self == .skyrimSE || self == .fallout4 }' in core,
      'plugins.txt in AppData/Local/<game>, with * for Skyrim SE and Fallout 4')
check(all(str(i) in core for i in (22380, 22300, 22370, 22330, 72850, 489830, 377160)), 'the games are known by their Steam app ids')
check('"bInvalidateOlderFiles", value: "1"' in core and '"SInvalidationFile", value: ""' in core and 'section: "Archive"' in core,
      'Fallout NV and 3: bInvalidateOlderFiles=1 and SInvalidationFile= under [Archive]')
check('static let entry = "winhttp=n,b"' in core, 'BepInEx: winhttp=n,b')

# 4. The page and the sheet.
check('.interactiveDismissDisabled(true)' in view, "the install sheet can't be swiped away while it works")
check('asCopy: true' in view and 'folder ? [.folder]' in view, 'Choose a File and Choose a Folder both copy what is picked')
check('if ModInstaller.isPickerCopy(source) { try? FileManager.default.removeItem(at: source) }' in view,
      "only the picker's own copy is deleted after an install, never the person's file or folder")
check('ItchArchive.unpackAny(' in archive and 'ItchArchive.unpackInner(' in archive, '.zip and .7z (and archives inside) through ItchArchive')
check('dlopen("/usr/lib/libarchive.2.dylib"' in archive and 'throw ModError.rar(' in archive, '.rar through the system libarchive, with a plain message without it')
check('confirmationDialog(Text("Remove \\(removingName)?")' in view, 'Remove asks first')
check(not re.search(r'^import (SwiftUI|UIKit)', core, re.M), 'ModsCore.swift is Foundation only')

# 5. Every new text has six languages.
pattern = re.compile(r'\b(?:Text|Button|Label|Toggle|Section|navigationTitle|confirmationDialog|L)\(\s*"((?:[^"\\]|\\.)*)"')
keys = {re.sub(r'\\\([^()"]*\)', '%@', m.group(1)) for m in pattern.finditer(view)}
keys = {k for k in keys if '\\(' not in k}
languages = ['de', 'es', 'ko', 'pt-BR', 'ru', 'zh-Hans']
missing = sorted(k for k in keys if any(not strings.get(k, {}).get('localizations', {}).get(l, {}).get('stringUnit', {}).get('value') for l in languages))
check(not missing and len(keys) >= 40, f'{len(keys)} Mods texts, each in six languages' + (f' (missing: {missing[:4]})' if missing else ''))

# 6. The Swift fixture.
compiler = shutil.which('swiftc')
if not compiler:
    print('SKIP: Swift compiler unavailable locally; run with swiftc on PATH (or --require-swift on CI)')
    if args.require_swift:
        failures += 1
else:
    with tempfile.TemporaryDirectory(prefix='madeira-mods-') as directory:
        binary = Path(directory) / 'mods'
        build = subprocess.run([compiler, '-swift-version', '5', str(app / 'ModsCore.swift'), str(root / 'tests/host/mods/main.swift'),
                                '-o', str(binary)], capture_output=True, text=True)
        check(build.returncode == 0, 'ModsCore.swift and the fixture compile' + ('' if build.returncode == 0 else '\n' + build.stderr[-3000:]))
        if build.returncode == 0:
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=300)
            lines = run.stdout.splitlines()
            for line in lines:
                if line.startswith('FAIL: '):
                    print('  ' + line)
            passed = sum(line.startswith('PASS: ') for line in lines)
            check(run.returncode == 0 and 'ALL PASS' in lines, f'the fixture: {passed} checks pass' + ('' if run.returncode == 0 else ' ' + run.stderr[-1000:]))

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
