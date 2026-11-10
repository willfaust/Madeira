#!/usr/bin/env python3
"""Get Help looks closer by itself (get-help-files).

The player only taps Get Help. Round 1 says which files the app can collect (can_send);
when the answer names some (need), the app reads them, scrubs them and asks once more
(follow_up + files), with nothing on screen but "Looking closer at your game…".

Source checks: the request and answer fields the Worker reads (get-help-server
worker/src/files.ts), the sheet's second round and its fallback, the new file in the
Xcode project, the new text in all six languages.

With swiftc (--require-swift makes it required), GetHelp.swift and GetHelpFiles.swift
are compiled with a test main on a made-up Steam client and game folder.
"""
from pathlib import Path
import json
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
core = (app / 'GetHelp.swift').read_text()
files = (app / 'GetHelpFiles.swift').read_text()
view = (app / 'GetHelpView.swift').read_text()
pbx = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
strings = json.loads((app / 'Localizable.xcstrings').read_text(encoding='utf-8'))['strings']
failures = []


def check(cond, what):
    print(('PASS: ' if cond else 'FAIL: ') + what)
    if not cond:
        failures.append(what)


# The server's contract (files.ts): the same five kinds, the same field names.
kinds = ['steam_libraries', 'steam_logs', 'game_folder', 'game_settings', 'full_log']
check('static let kinds = ' + json.dumps(kinds) in files, 'the five kinds the server knows')
for field in ['can_send', 'follow_up', 'files']:
    check(re.search(rf'var {field}: ', core) is not None, f'request field {field}')
check('var need: [String]?' in core, 'answer field need')
check('maxFile = 23_000' in files, 'each file under the server\'s 24,000 characters')
check('need.prefix(2)' in files, 'at most 2 files, as the server asks')
check('foundation' in files.lower() and 'import SwiftUI' not in files and 'LibraryModel' not in files, 'GetHelpFiles is Foundation only')

# The sheet: nothing for the player to do.
check('request.can_send = GetHelpFiles.available(places)' in view, 'round 1 says what this device can send')
check('lookClose(request, need: need, followUp: id, places: places, fallback: answer)' in view, 'a need starts round 2 by itself')
look = view[view.index('private func lookClose('):]
look = look[:look.index('\n    }\n') + 6]
check('PrivacyScrub.text' in look, 'round 2 files are scrubbed in the app too')
check('again.can_send = nil' in look and 'again.follow_up = followUp' in look, 'round 2 never asks again')
check(look.count('show(fallback)') == 2, 'no files or a failed round 2 shows the first answer')
check('guard phase == .sending, lookingCloser' in look, 'closing or Try Again during round 2 drops it')
check('Button(' not in look and 'alert' not in look.lower(), 'no buttons or questions in round 2')
check('"Looking closer at your game…"' in view, 'the screen just says it is looking closer')

# Project and languages.
check(len([l for l in pbx.splitlines() if 'GetHelpFiles.swift' in l]) == 4, 'GetHelpFiles.swift is in the Xcode project (file, group, build file, sources)')
langs = {'de', 'es', 'ko', 'pt-BR', 'ru', 'zh-Hans'}
entry = strings.get('Looking closer at your game…', {}).get('localizations', {})
check(set(entry) == langs and all(v['stringUnit']['state'] == 'translated' for v in entry.values()), '"Looking closer" in all six languages')

swiftc = shutil.which('swiftc')
if not swiftc:
    print('SKIP: swiftc not found' + (' (required)' if '--require-swift' in sys.argv else ''))
    if '--require-swift' in sys.argv:
        failures.append('swiftc required')
else:
    test = r'''
import Foundation
var bad = 0
func expect(_ c: Bool, _ what: String) { print((c ? "PASS: " : "FAIL: ") + what); if !c { bad += 1 } }
let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("ghf-\(UUID().uuidString)")
func put(_ path: String, _ text: String) {
    let url = base.appendingPathComponent(path)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}
let drive = base.appendingPathComponent("drive_c")
put("drive_c/Steam/config/libraryfolders.vdf", "\"libraryfolders\" { \"0\" { \"path\" \"C:\\\\External\\\\steam\" } }")
put("drive_c/Steam/steamapps/libraryfolders.vdf", "\"libraryfolders\" { \"1\" { \"path\" \"C:\\\\Steam\" } }")
put("drive_c/Steam/Logs/Service_Log.txt", String(repeating: "old line\n", count: 3000) + "[2026-11-08] service quit code 55\n")
put("drive_c/Steam/steamapps/common/KH3/KINGDOM HEARTS III/Binaries/Win64/KINGDOM HEARTS III.exe", "MZ")
put("drive_c/Steam/steamapps/common/KH3/Engine/Config/BaseEngine.ini", "[Core]\nfoo=1\n")
put("drive_c/Steam/steamapps/common/KH3/big.json", String(repeating: "x", count: 20_000))
put("run.txt", String(repeating: "noise\n", count: 10_000) + "[run-end] #3 crashed\n")

let folder = GetHelpFiles.gameFolder(drive: drive, relativePath: "Steam/steamapps/common/KH3/KINGDOM HEARTS III/Binaries/Win64/KINGDOM HEARTS III.exe")
expect(folder?.lastPathComponent == "KH3", "a Steam game's folder is its steamapps/common folder")
expect(GetHelpFiles.gameFolder(drive: drive, relativePath: "Games/Foo/foo.exe")?.lastPathComponent == "Foo", "another game's folder is the program's folder")
expect(GetHelpFiles.gameFolder(drive: drive, relativePath: "foo.exe") == nil && GetHelpFiles.gameFolder(drive: drive, relativePath: "a/../b.exe") == nil, "no folder for odd paths")

var places = GetHelpFiles.Places(steamRoot: drive.appendingPathComponent("Steam"), gameFolder: folder,
                                 runLog: { base.appendingPathComponent("run.txt") }, hasRun: true)
expect(GetHelpFiles.available(places) == GetHelpFiles.kinds, "everything is available here")
let none = GetHelpFiles.Places(steamRoot: base.appendingPathComponent("nope"), gameFolder: nil, runLog: { nil }, hasRun: false)
expect(GetHelpFiles.available(none).isEmpty, "nothing is offered that isn't there")

let got = GetHelpFiles.collect(["steam_libraries", "steam_logs", "game_folder"], at: places, scrub: { $0.replacingOccurrences(of: "External", with: "<hidden>") })
expect(got.map(\.kind) == ["steam_libraries", "steam_logs"], "at most 2, in the asked order")
expect(got[0].text.contains("### config/libraryfolders.vdf") && got[0].text.contains("### steamapps/libraryfolders.vdf"), "both library lists")
expect(got[0].text.contains("<hidden>") && !got[0].text.contains("External"), "the scrub runs on every file")
expect(got[1].text.contains("service quit code 55") && got[1].text.utf8.count < 8_000, "the end of Steam's service log, any letter case")

let more = GetHelpFiles.collect(["game_folder", "game_settings", "bogus"], at: places, scrub: { $0 })
expect(more.map(\.kind) == ["game_folder", "game_settings"], "unknown kinds are skipped")
expect(more[0].text.contains("KINGDOM HEARTS III/Binaries/") && more[0].text.contains("big.json  20 KB"), "the folder list has names and sizes")
expect(more[1].text.contains("### Engine/Config/BaseEngine.ini") && more[1].text.contains("foo=1") && !more[1].text.contains("big.json"), "small settings files only")

let log = GetHelpFiles.collect(["full_log"], at: places, scrub: { $0 })
expect(log.first?.text.hasSuffix("[run-end] #3 crashed\n") == true && log[0].text.count <= GetHelpFiles.maxFile, "the end of the run, under the limit")

places.runLog = { nil }
expect(GetHelpFiles.collect(["full_log"], at: places, scrub: { $0 }).isEmpty, "nothing sent when a file can't be read")

// The request: nil fields are left out (old servers), set ones go as the Worker reads them.
var req = GetHelpCore.Request(install_id: UUID().uuidString, game: "KH3", app_version: "v", reason: "player", report: "r", keep_report: true)
var body = try! JSONSerialization.jsonObject(with: GetHelpCore.body(req)) as! [String: Any]
expect(body["can_send"] == nil && body["files"] == nil && body["follow_up"] == nil, "round 1 without places sends no new fields")
req.follow_up = "6f1c2b9e-0000-4000-8000-000000000000"; req.files = got
body = try! JSONSerialization.jsonObject(with: GetHelpCore.body(req)) as! [String: Any]
expect((body["files"] as? [[String: String]])?.first?["kind"] == "steam_libraries" && body["follow_up"] as? String == req.follow_up, "round 2 fields")
let a = GetHelpCore.outcome(data: #"{"ok":true,"request_id":"6f1c2b9e-0000-4000-8000-000000000000","kind":"answer","answer":"x","steps":[],"need":["steam_logs"]}"#.data(using: .utf8), status: 200, error: nil)
if case .answer(let ans) = a { expect(ans.need == ["steam_logs"], "need is read from the answer") } else { expect(false, "need answer decodes") }

try? fm.removeItem(at: base)
exit(bad == 0 ? 0 : 1)
'''
    with tempfile.TemporaryDirectory() as tmp:
        main = Path(tmp) / 'main.swift'
        main.write_text(test)
        exe = Path(tmp) / 'ghf'
        build = subprocess.run([swiftc, '-O', str(app / 'GetHelp.swift'), str(app / 'GetHelpFiles.swift'), str(main), '-o', str(exe)],
                               capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stdout + build.stderr)
            failures.append('swiftc build')
        else:
            run = subprocess.run([str(exe)], capture_output=True, text=True)
            print(run.stdout + run.stderr, end='')
            if run.returncode != 0:
                failures.append('swift test run')

print('\nall checks pass' if not failures else f'\n{len(failures)} failed: ' + '; '.join(failures))
sys.exit(1 if failures else 0)
