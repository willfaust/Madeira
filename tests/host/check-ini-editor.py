#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Game details > Settings files (app/Madeira/GameIniFiles.swift).

A game's own .ini files, added per game ("Add .ini file") from its folder and
Documents/My Games, edited section by section in the app. Saving rewrites only the
changed values: line endings, encoding, comments and order stay. A file the game
rewrote since it was saved here is noted when it opens.

Source checks (every host): the page is in Game details, the file is in the project,
saving refuses a file that changed while open.

Swift fixture (macOS CI with --require-swift; skipped without a compiler): the part
of GameIniFiles.swift above "MARK: Views" on synthetic files.
"""
from pathlib import Path
import argparse, shutil, subprocess, sys, tempfile

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


source = (app / 'GameIniFiles.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')

check('case .iniFiles: return "Settings files"' in library and
      'case .iniFiles: GameIniFilesSection(windowsPath: entry.windowsPath, gameFolder: iniGameFolder)' in library,
      'Game details has a Settings files page')
check('[.library, .iniFiles, .advanced]' in library, 'for every game but the Desktop')
check('Label("Add .ini file", systemImage: "plus")' in source and '.sheet(' not in source,
      'the page offers "Add .ini file", pushed rather than a sheet that closed by itself')
check(sum('GameIniFiles.swift' in line for line in project.splitlines()) == 4,
      'GameIniFiles.swift is in the Xcode project (file, build file, group, sources)')
save = source[source.index('    private func save() {'):]
check(save.index('now != original') < save.index('try out.write(to: url, options: .atomic)'),
      'a file that changed while open is not overwritten')
check('GameIniFiles.setSavedFingerprint(' in save and 'GameIniFiles.savedFingerprint(file), saved != GameIniFiles.fingerprint(data)' in source,
      'a game rewriting the file is noted when it opens')
foundation = source[:source.index('// MARK: Views')]
check('LibraryModel' not in foundation and 'LogStore' not in foundation, 'the model part is Foundation only')

check('Image(systemName: "info.circle")' in source and 'IniSettingHelp.describe(key: setting.key)' in source,
      'each setting has a blue info button with its description')

main_swift = r'''
import Foundation
func show(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: "<CR>").replacingOccurrences(of: "\n", with: "<LF>") }
let crlf = "; comment\r\n[Display]\r\niSize W=1280\r\nbFull Screen=0\r\nsD3DDevice=\"Apple M4 GPU\"\r\n\r\n[General]\r\n  sLanguage = ENGLISH  \r\nbUseThreadedAI=1\r\n"
var d = IniDocument(text: crlf)
print("sections=" + d.sections.map { "\($0.name):\($0.settings.count)" }.joined(separator: ","))
print("same=\(d.text == crlf)")
d.set(line: 2, to: "1600")
d.set(line: 7, to: "FRENCH")
print("edited=" + show(d.text))
print("value=" + (d.value(section: "display", key: "isize w") ?? "nil"))
let lf = "a=1\nb = 2"
var e = IniDocument(text: lf)
e.set(line: 1, to: "3")
print("lf=" + show(e.text))
print("switch=\(GameIniFiles.isSwitch(key: "bFull Screen", value: "1")),\(GameIniFiles.isSwitch(key: "iSize W", value: "1")),\(GameIniFiles.isSwitch(key: "bob", value: "0"))")
let latin = Data([0x61, 0x3D, 0xE9, 0x0A])
let t = IniFileText(data: latin)!
print("latin=\(t.utf8),\(t.text == "a=é\n"),\(t.data(t.text) == latin)")
let bom = Data([0xEF, 0xBB, 0xBF, 0x61, 0x3D, 0x31, 0x0A])
let u = IniFileText(data: bom)!
print("bom=\(u.bom),\(u.text == "a=1\n"),\(u.data(u.text) == bom)")
let wide = Data([0xFF, 0xFE]) + "[Display]\r\niSize W=1280\r\niSize H=720\r\n".data(using: .utf16LittleEndian)!
let w = IniFileText(data: wide)!
var wd = IniDocument(text: w.text)
let wideOpened = wd.sections.map(\.name) == ["Display"] && wd.value(section: "Display", key: "iSize W") == "1280"
wd.set(line: 1, to: "1600")
let wideSaved = w.data(wd.text)
print("utf16=\(w.utf16),\(wideOpened),\(w.data(w.text) == wide),\(wideSaved == Data([0xFF, 0xFE]) + "[Display]\r\niSize W=1600\r\niSize H=720\r\n".data(using: .utf16LittleEndian)!)")
print("utf16odd=\(IniFileText(data: Data([0xFF, 0xFE, 0x61])) == nil)")
print("label=" + GameIniFiles.label("users/steamuser/Documents/My Games/FalloutNV/Fallout.ini", gameFolder: nil) + "|" +
      GameIniFiles.label("Program Files (x86)/Steam/steamapps/common/Fallout New Vegas/Fallout_default.ini",
                         gameFolder: "Program Files (x86)/Steam/steamapps/common/Fallout New Vegas"))
print("folder=" + GameIniFiles.gameFolder(relativePath: "Games/NV/FalloutNV.exe", isDirectory: false) + "|" +
      GameIniFiles.gameFolder(relativePath: "Games/NV", isDirectory: true))
let defaults = UserDefaults(suiteName: "check-ini-editor")!
defaults.removePersistentDomain(forName: "check-ini-editor")
GameIniFiles.add("x/A.ini", for: "C:\\Game", defaults: defaults)
GameIniFiles.add("x/a.ini", for: "c:\\game", defaults: defaults)
GameIniFiles.add("x/B.ini", for: "C:\\Game", defaults: defaults)
GameIniFiles.remove("x/A.ini", for: "C:\\Game", defaults: defaults)
print("list=" + GameIniFiles.files("C:\\GAME", defaults: defaults).joined(separator: ","))
print("help=" + [IniSettingHelp.describe(key: "uGridsToLoad") != nil, IniSettingHelp.describe(key: "iSize W")?.hasPrefix("The game's width") == true,
                  IniSettingHelp.describe(key: "bSomethingNew") == "A switch: 1 is on, 0 is off.", IniSettingHelp.describe(key: "whatever") == nil]
                  .map { "\($0)" }.joined(separator: ","))
let drive = URL(fileURLWithPath: CommandLine.arguments[1])
print("found=" + GameIniFiles.candidates(drive: drive, gameFolder: "Games/NV").sorted().joined(separator: ","))
'''

compiler = shutil.which('swiftc')
if not compiler:
    print('SKIP: Swift compiler unavailable locally; macOS CI must run this check with --require-swift')
    if args.require_swift:
        failures += 1
else:
    with tempfile.TemporaryDirectory(prefix='madeira-ini-') as directory:
        temporary = Path(directory)
        model = foundation.replace('import SwiftUI\n', '')
        (temporary / 'GameIniFiles.swift').write_text(model)
        (temporary / 'main.swift').write_text(main_swift)
        binary = temporary / 'ini'
        subprocess.run([compiler, '-swift-version', '5', str(temporary / 'GameIniFiles.swift'), str(temporary / 'main.swift'),
                        '-o', str(binary)], check=True)
        drive = temporary / 'drive_c'
        (drive / 'users/steamuser/Documents/My Games/FalloutNV').mkdir(parents=True)
        (drive / 'users/steamuser/Documents/My Games/FalloutNV/Fallout.ini').write_text('a=1\n')
        (drive / 'Games/NV/Data').mkdir(parents=True)
        (drive / 'Games/NV/Fallout_default.ini').write_text('a=1\n')
        (drive / 'Games/NV/Data/readme.txt').write_text('x')
        (drive / 'Games/Other').mkdir(parents=True)
        (drive / 'Games/Other/other.ini').write_text('a=1\n')
        out = dict(line.split('=', 1) for line in subprocess.run([str(binary), str(drive)], capture_output=True, text=True,
                                                                 check=True).stdout.splitlines())
        check(out['sections'] == 'Display:3,General:2', 'sections and settings in file order')
        check(out['same'] == 'true', 'an unchanged file comes back byte for byte')
        check(out['edited'] == '; comment<CR><LF>[Display]<CR><LF>iSize W=1600<CR><LF>bFull Screen=0<CR><LF>'
              'sD3DDevice="Apple M4 GPU"<CR><LF><CR><LF>[General]<CR><LF>  sLanguage = FRENCH  <CR><LF>bUseThreadedAI=1<CR><LF>',
              'only the changed values are rewritten; CRLF, spacing and comments stay')
        check(out['value'] == '1600', 'values are found by section and key in any case')
        check(out['lf'] == 'a=1<LF>b = 3', 'LF files without a last newline stay so')
        check(out['switch'] == 'true,false,false', 'Bethesda 0/1 switches (bName) show as switches')
        check(out['latin'] == 'false,true,true', 'a Windows Latin 1 file is saved in Latin 1')
        check(out['bom'] == 'true,true,true', 'a UTF-8 byte order mark is kept')
        check(out['utf16'] == 'true,true,true,true', 'a UTF-16 LE file (FF FE) opens with its sections and is saved as UTF-16 LE')
        check(out['utf16odd'] == 'true', 'a broken UTF-16 file does not open, so it is never saved damaged')
        check(out['label'] == 'My Games\\FalloutNV\\Fallout.ini|Fallout New Vegas\\Fallout_default.ini', 'short names')
        check(out['folder'] == 'Games/NV|Games/NV', "the game's folder: the program's, or a Steam install folder")
        check(out['list'] == 'x/B.ini', 'each game keeps its own list, once per file')
        check(out['help'] == 'true,true,true,true', 'the info button: known settings, then the kind from the name')
        check(out['found'] == 'Games/NV/Fallout_default.ini,users/steamuser/Documents/My Games/FalloutNV/Fallout.ini',
              "candidates: the game's folder and My Games, not other games")

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
