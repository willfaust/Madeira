#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Keys on the Wine desktop (app/Madeira/DesktopKeys.swift): the on-screen keyboard's extra row, and
Command as Control (Settings > Controls, off by default).

Source checks: HardwareInput posts every Command press and release in a shortcut through one mapping
(so a held Command is never left down as Windows' key) but a lone tap of Command still posts the
Windows key; the setting is saved and only applies to the Desktop entry; the accessory bar is built
from DesktopKeys. The Swift fixture compiles the real DesktopKeys.swift: the row's codes, no
duplicate keys, F1 to F12 in order, the mapping both ways. Hosts without Swift run the source checks;
--require-swift fails instead.
"""
from pathlib import Path
import argparse, os, shutil, subprocess, tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
keys = (app / 'DesktopKeys.swift').read_text()
hw = (app / 'HardwareInput.swift').read_text()
library = (app / 'Library.swift').read_text()
content = (app / 'ContentView.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
failures = 0


def check(ok, label):
    global failures
    print(('PASS: ' if ok else 'FAIL: ') + label)
    failures += 0 if ok else 1


check(project.count('DesktopKeys.swift') >= 4, 'DesktopKeys.swift is in the project')
check('winios_post_key(postedKey(vk), 0)' in hw and 'winios_post_key(postedKey(vk), 1)' in hw
      and 'winios_post_key(postedKey(command), 1)' in hw, 'held and combined Command go through the one mapping')
check('winios_post_key(vk, 1); winios_post_key(vk, 0)' in hw, 'a lone tap of Command still posts the Windows key')
check('InputSettings.shared.commandIsControl && LibraryModel.shared.activeEntry?.desktop == true' in hw, 'only on the Desktop entry')
check('@Published var commandIsControl = false' in content and '"commandIsControl": commandIsControl' in content
      and 'j["commandIsControl"] as? Bool ?? false' in content, 'the setting is saved and off by default')
check('Toggle("Command works as Control", isOn: $input.commandIsControl)' in library, 'the toggle is on the Controls page')
check('for (title, key) in DesktopKeys.accessory {' in library and 'DesktopKeys.modifiers.contains(key)' in library,
      'the accessory bar is built from DesktopKeys')

main = r'''
import Foundation
var bad = 0
func expect(_ c: Bool, _ l: String) { if !c { print("FAIL:", l); bad += 1 } }
let row = DesktopKeys.accessory
let titles = row.map(\.title)
expect(Set(titles).count == titles.count, "no title twice")
let codes = row.map(\.vk).filter { $0 > 0 }
expect(Set(codes).count == codes.count, "no key twice")
func vk(_ t: String) -> Int32? { row.first { $0.title == t }?.vk }
expect(vk("Home") == 0x24 && vk("End") == 0x23 && vk("PgUp") == 0x21 && vk("PgDn") == 0x22 && vk("Del") == 0x2e, "navigation keys")
expect((1...12).allSatisfy { vk("F\($0)") == Int32(0x6f + $0) }, "F1 to F12 are 0x70 to 0x7B in order")
expect(vk("Paste") == -1 && vk("Done") == 0 && titles.first == "Paste" && titles.last == "Done", "Paste first, Done last")
expect(vk("Ctrl") == 0x11 && vk("Shift") == 0x10 && vk("Alt") == 0x12 && DesktopKeys.modifiers == [0x10, 0x11, 0x12], "modifiers")
expect(DesktopKeys.postedKey(0x5b, commandIsControl: true) == 0xa2 && DesktopKeys.postedKey(0x5c, commandIsControl: true) == 0xa3, "Command becomes Control")
expect(DesktopKeys.postedKey(0x5b, commandIsControl: false) == 0x5b && DesktopKeys.postedKey(0x5c, commandIsControl: false) == 0x5c, "off: Windows key")
expect(DesktopKeys.postedKey(0x41, commandIsControl: true) == 0x41 && DesktopKeys.postedKey(0x11, commandIsControl: true) == 0x11, "other keys are left alone")
exit(bad == 0 ? 0 : 1)
'''
compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
if compiler:
    with tempfile.TemporaryDirectory(prefix='madeira-keys-') as d:
        t = Path(d)
        (t / 'DesktopKeys.swift').write_text(keys)
        (t / 'main.swift').write_text(main)
        subprocess.run([compiler, str(t / 'DesktopKeys.swift'), str(t / 'main.swift'), '-o', str(t / 'dk')], check=True)
        check(subprocess.run([str(t / 'dk')]).returncode == 0, 'Swift fixture')
elif args.require_swift:
    check(False, 'swiftc is required')
else:
    print('SKIP: no swiftc, source checks only')
raise SystemExit(1 if failures else 0)
