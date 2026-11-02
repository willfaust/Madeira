#!/usr/bin/env python3
"""Game details > Share Setup and Apply Shared Setup (app/Madeira/GameSetupShare.swift).

A game's setup (entry fields, its config file, launch switches, settings files) as one
.madeirasetup file or one line of text, applied on another device in one tap.

Source checks (every host): the buttons are in Game details, the file is in the project,
Madeira opens .madeirasetup files and madeira://setup links.

Swift fixture (macOS CI with --require-swift; skipped without a compiler): the part of
GameSetupShare.swift above "MARK: Views" on synthetic setups.
"""
from pathlib import Path
import argparse, os, plistlib, shutil, subprocess, sys, tempfile

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


source = (app / 'GameSetupShare.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
madeira_app = (app / 'MadeiraApp.swift').read_text(encoding='utf-8')
prefs = (app / 'LibraryPrefs.swift').read_text(encoding='utf-8')
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
info = plistlib.loads((app / 'Info.plist').read_bytes())

check('Button("Share Setup"' in library and 'Button("Apply Shared Setup"' in library,
      'Game details has Share Setup and Apply Shared Setup')
check('DisclosureGroup("Config lines")' in source and 'setup.iniPlaces' in source,
      'the apply sheet lists the config lines and settings file places')
check('GameSetupShareSheet(entry: entry)' in library and 'pending.setup.apply(to: &entry' in library,
      'the buttons open the share sheet and apply into the open entry')
check('.modifier(GameSetupInboxPresenter())' in library, 'the library asks which game gets an opened setup')
check('GameSetupInbox.shared.handle(url)' in madeira_app, 'opened files and madeira://setup links reach the inbox')
check(project.count('A1009C01 /* GameSetupShare.swift in Sources */') == 2 and
      project.count('A2009C01 /* GameSetupShare.swift */') == 3, 'GameSetupShare.swift is in the app target')
types = [t for d in info.get('UTExportedTypeDeclarations', []) if d.get('UTTypeIdentifier') == 'app.madeira.setup'
         for t in d.get('UTTypeTagSpecification', {}).get('public.filename-extension', [])]
check(types == ['madeirasetup'], 'Info.plist declares the .madeirasetup type')
check(any('app.madeira.setup' in d.get('LSItemContentTypes', []) for d in info.get('CFBundleDocumentTypes', [])),
      'Madeira opens .madeirasetup files')
check('static func sharedSwitches' in prefs and 'static func applySharedSwitches' in prefs,
      "LibraryPrefs reads and writes a setup's switches")
foundation = source[:source.index('// MARK: Views')]
code = '\n'.join(l for l in foundation.splitlines() if not l.strip().startswith('//'))
check('LibraryModel' not in code and 'LogStore' not in code and 'LibraryEntry' not in code,
      'the model part is Foundation only')

main_swift = r'''
import Foundation
func keys(_ d: [String: Any]) -> String { d.keys.sorted().joined(separator: ",") }
let entryJSON: [String: Any] = ["id": "X", "title": "Fallout", "relativePath": "Games/NV/FalloutNV.exe", "bits": 32,
    "resolution": "1280x720", "fpsMode": 3, "arguments": "-x", "controls": [["k": 1]], "controllerMode": "keys",
    "lastPlayed": 5.0, "steamAppID": 22380, "steamProgram": "nv.exe", "config": "old", "metalFXUpscale": 1.5]
let shared = GameSetup.sharedFields(entryJSON)
print("shared=" + keys(shared))
let target: [String: Any] = ["id": "Y", "title": "Mine", "relativePath": "G/a.exe", "bits": 32, "resolution": "800x600",
    "fpsMode": 1, "arguments": "", "frameGeneration": true, "controls": [["k": 2]], "controllerMode": "dinput",
    "steamProgram": "mine.exe", "controlLayout": "Mine"]
let merged = GameSetup.merge(shared, into: target, controls: true, sameGame: false)
print("merged=" + keys(merged))
print("values=\(merged["resolution"]!)|\(merged["fpsMode"]!)|\(merged["title"]!)|\(merged["steamProgram"]!)|\(merged["controllerMode"]!)")
let keep = GameSetup.merge(shared, into: target, controls: false, sameGame: true)
print("keep=\(keep["controllerMode"]!)|\(keep["steamProgram"]!)|\(keep["frameGeneration"] == nil)")
print("ini=" + [GameSetup.sharedIniPath("Games/NV/Data/x.ini", gameFolder: "Games/NV"),
                GameSetup.sharedIniPath("users/steamuser/Documents/My Games/FalloutNV/Fallout.ini", gameFolder: "Games/NV")].joined(separator: "|"))
print("local=" + [GameSetup.localIniPath("game/Data/x.ini", gameFolder: "Other/NV"),
                  GameSetup.localIniPath("drive/users/a/b.ini", gameFolder: ""),
                  GameSetup.localIniPath("game/../../x.ini", gameFolder: "G"),
                  GameSetup.localIniPath("drive/windows/system32/evil.dll", gameFolder: "G"),
                  GameSetup.localIniPath("game/x.ini", gameFolder: "")].map { $0 ?? "nil" }.joined(separator: "|"))
let setup = GameSetup(title: "Fallout: New Vegas", steamAppID: 22380, program: "falloutnv.exe", entry: shared,
                      config: "# c\nfence-chain = 6\nenv.A = 1\n", switches: ["avx": true, "nvidia": true],
                      iniFiles: [.init(path: "game/x.ini", data: Data([0xEF, 0xBB, 0xBF, 0x61]))])
let back = try! GameSetup(data: try! setup.data())
print("round=\(back.title)|\(back.steamAppID!)|\(back.program!)|\(keys(back.entry))|\(back.config.count)|\(keys(back.switches))|\(back.iniFiles == setup.iniFiles)")
let line = "look: " + (try! setup.text()) + " (works on build 58)"
let fromText = try! GameSetup(text: line)
print("text=\(fromText.title)|\(fromText.iniFiles.count)|\(fromText.entry.count == shared.count)")
let link = "madeira://setup?d=" + (try! setup.text()).dropFirst(GameSetup.textPrefix.count)
print("link=\((try? GameSetup(text: link))?.title ?? "nil")")
print("contents=" + setup.contents.joined(separator: ","))
let places = GameSetup(title: "T", entry: [:], config: "", switches: [:],
                       iniFiles: [.init(path: "game/Data/x.ini", data: Data()), .init(path: "drive/users/a/b.ini", data: Data())])
print("shown=" + setup.configLines.joined(separator: ";") + "|" + places.iniPlaces.joined(separator: ";"))
print("file=" + GameSetup(title: "A/B: C?", entry: [:], config: "", switches: [:], iniFiles: []).fileName)
print("match=\(setup.match(steamAppID: 22380, program: nil))\(setup.match(steamAppID: nil, program: "FalloutNV.exe"))\(setup.match(steamAppID: 1, program: "x.exe"))")
var bad: [String] = []
for junk in ["hello", "madeira-setup:1:q!!", "{\"format\":\"other\"}"] {
    bad.append((try? GameSetup(text: junk)) == nil ? "refused" : "taken")
}
do { _ = try GameSetup(data: Data("{\"format\":\"madeira-setup\",\"version\":9}".utf8)); bad.append("taken") }
catch { bad.append(error.localizedDescription.contains("newer") ? "newer" : "other") }
print("bad=" + bad.joined(separator: ","))
'''

compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
if not compiler:
    print('SKIP: Swift compiler unavailable locally; macOS CI must run this check with --require-swift')
    if args.require_swift:
        failures += 1
else:
    with tempfile.TemporaryDirectory(prefix='madeira-setup-', dir=os.environ.get('TMPDIR')) as directory:
        temporary = Path(directory)
        body = foundation.replace('import SwiftUI\n', '').replace('import UniformTypeIdentifiers\n', '').replace('import UIKit\n', '')
        (temporary / 'GameSetupShare.swift').write_text(body)
        (temporary / 'main.swift').write_text(main_swift)
        binary = temporary / 'setup'
        subprocess.run(compiler.split() + ['-swift-version', '5', str(temporary / 'GameSetupShare.swift'),
                                           str(temporary / 'main.swift'), '-o', str(binary)], check=True)
        out = dict(line.split('=', 1) for line in subprocess.run([str(binary)], capture_output=True, text=True,
                                                                 check=True).stdout.splitlines())
        check(out['shared'] == 'arguments,controllerMode,controls,fpsMode,metalFXUpscale,resolution,steamProgram',
              "a setup leaves out this device's copy of the game, its history and its store")
        check(out['merged'] == 'arguments,bits,controlLayout,controllerMode,controls,fpsMode,id,metalFXUpscale,relativePath,resolution,steamProgram,title',
              'applying drops options the sharer left unset (frame generation) and keeps the local fields')
        check(out['values'] == '1280x720|3|Mine|mine.exe|keys',
              "the setup's values win; another game's Steam program is not taken")
        check(out['keep'] == 'dinput|nv.exe|true', 'controls can be kept; the same Steam game takes its program')
        check(out['ini'] == 'game/Data/x.ini|drive/users/steamuser/Documents/My Games/FalloutNV/Fallout.ini',
              "settings files by the game's folder or drive_c")
        check(out['local'] == 'Other/NV/Data/x.ini|users/a/b.ini|nil|nil|nil',
              "settings files land in this device's game folder, never outside drive_c, and only .ini files")
        check(out['round'] == 'Fallout: New Vegas|22380|falloutnv.exe|arguments,controllerMode,controls,fpsMode,metalFXUpscale,resolution,steamProgram|30|avx,nvidia|true',
              'a setup file reads back whole (byte-exact settings files)')
        check(out['text'] == 'Fallout: New Vegas|1|true', 'the text form is found inside a chat message')
        check(out['link'] == 'Fallout: New Vegas', 'a madeira://setup link reads too')
        check(out['contents'] == '4 game settings,2 config lines,2 launch switches,touch controls and controller,1 settings file',
              'Apply Shared Setup lists what the setup holds')
        check(out['shown'] == 'fence-chain = 6;env.A = 1|Game folder/Data/x.ini;C:\\users\\a\\b.ini',
              'the apply sheet shows each config line and where each settings file goes')
        check(out['file'] == 'A-B- C-.madeirasetup', 'the file name has no characters file systems refuse')
        check(out['match'] == '220', 'a setup knows its game by Steam app or program')
        check(out['bad'] == 'refused,refused,refused,newer', 'other text is refused; a newer format says to update')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
