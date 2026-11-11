#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Add a game (app/Madeira/GameCandidate.swift, AddGame.swift).

Source checks: one sheet replaces the old browser as the Add a game entry, the external-drive
scan shares GameCandidate's skip list, both files are in the project. The Swift fixture compiles
the real GameCandidate.swift and checks the ranking (folder-name match beats size, installers and
helpers last), the installer test, titles and folder slugs. Hosts without Swift run the source
checks; --require-swift fails instead.
"""
from pathlib import Path
import argparse, os, shutil, subprocess, tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
cand = (app / 'GameCandidate.swift').read_text()
add = (app / 'AddGame.swift').read_text()
library = (app / 'Library.swift').read_text()
drives = (app / 'ExternalDrives.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
failures = 0


def check(ok, label):
    global failures
    print(('PASS: ' if ok else 'FAIL: ') + label)
    failures += 0 if ok else 1


check('AddGameSheet { entry in' in library, 'the Add a game sheet opens AddGameSheet')
check('ExecutableBrowser(folder: LibraryModel.drive' in add, 'the old browser stays as the last row')
check('GameCandidate.isSkipped(name)' in drives and 'private static let skipNames' not in drives,
      'the external scan uses the shared skip list')
check('entry(running: url)' in add, 'adding a program that already has an entry opens that entry')
check('createDirectory' in add and 'removeItem(at: dest)' in add, 'an import that fails leaves no half folder')
for name in ('GameCandidate.swift', 'AddGame.swift'):
    check(project.count(name) >= 4, name + ' is in the project')

main = r'''
import Foundation
var bad = 0
func expect(_ c: Bool, _ l: String) { if !c { print("FAIL:", l); bad += 1 } }
let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent("gc-" + UUID().uuidString)
let game = dir.appendingPathComponent("Cool_Game")
try fm.createDirectory(at: game.appendingPathComponent("bin"), withIntermediateDirectories: true)
func put(_ p: String, _ n: Int) { fm.createFile(atPath: game.appendingPathComponent(p).path, contents: Data(count: n)) }
put("setup.exe", 90_000_000); put("CoolGame.exe", 2_000_000); put("bin/Helper.exe", 50_000_000); put("bin/other.exe", 5_000_000)
let found = GameCandidate.programs(in: game)
expect(found.count == 4, "finds four programs")
let order = GameCandidate.ranked(found, in: game).map { $0.lastPathComponent }
expect(order.first == "CoolGame.exe", "folder-name match first: \(order)")
expect(order.last == "setup.exe" || order.last == "Helper.exe", "installer or helper last: \(order)")
expect(GameCandidate.isInstaller("Setup_x64.exe") && GameCandidate.isInstaller("unins000.exe"), "installers")
expect(!GameCandidate.isInstaller("CoolGame.exe") && !GameCandidate.isInstaller("helper.exe"), "game and helper are not installers")
expect(GameCandidate.isSkipped("vc_redist.x64.exe") && !GameCandidate.isSkipped("game.exe"), "skip list")
expect(GameCandidate.title("Cool_Game") == "Cool Game" && GameCandidate.title("a_b.exe") == "a b", "title")
expect(GameCandidate.slug("a/b:c*") == "a b c" && GameCandidate.slug("..") == "Game" && GameCandidate.slug("").count == 4, "slug")
try? fm.removeItem(at: dir)
exit(bad == 0 ? 0 : 1)
'''
compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
if compiler:
    with tempfile.TemporaryDirectory(prefix='madeira-gc-') as d:
        t = Path(d)
        (t / 'GameCandidate.swift').write_text(cand)
        (t / 'main.swift').write_text(main)
        subprocess.run([compiler, str(t / 'GameCandidate.swift'), str(t / 'main.swift'), '-o', str(t / 'gc')], check=True)
        check(subprocess.run([str(t / 'gc')]).returncode == 0, 'Swift fixture')
elif args.require_swift:
    check(False, 'swiftc is required')
else:
    print('SKIP: no swiftc, source checks only')
raise SystemExit(1 if failures else 0)
