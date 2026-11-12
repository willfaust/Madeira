#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Madeira Dock's "Steam starts" (app/Madeira/DockStartProgram.swift).

Madeira can start only one 32-bit program per session, so Fallout: New Vegas's 32-bit
launcher ends the session when it starts the game. With a program chosen in Game
details › Steam, a Dock start keeps the launcher beside it ("<name>.madeira-launcher")
and copies the chosen program in its place; with Steam's choice the launcher goes back.

Source checks (every host): the Dock start applies the choice before its session, with
Steam's launch entry; Game details offers the choice; the file is in the Xcode project.

Swift fixture (macOS CI with --require-swift; skipped without a compiler): the real
DockStartProgram.swift on a synthetic game folder: swap, a second start changes nothing,
a Steam repair is swapped again, another choice replaces the copy, Steam's choice puts
the launcher back, a missing program or a path out of the folder fails and touches
nothing, and the choice is stored per App ID.

Unity (7 Days to Die, Nov 8 2026): a Unity program copied in under the launcher's name
looked for "<launcher>_Data" and stopped with "Data folder not found". The swap now adds
a relative link "<launcher>_Data" -> "<program>_Data"; Steam's choice, a non-Unity choice
or the switch off take out only that link; a launcher's own real data folder is kept.
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


source = (app / 'DockStartProgram.swift').read_text(encoding='utf-8')
content = (app / 'ContentView.swift').read_text(encoding='utf-8')
games = (app / 'SteamGames.swift').read_text(encoding='utf-8')
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')

# ------------------------------------------------------------------ source checks
start = content[content.index('    private func startDock('):]
start = start[:start.index('MadeiraDock.requestLaunch(')]
check('let steamEntry = options.flatMap { SteamDirectStart.choose($0, installFolder: installFolder) }' in start and
      'let chosen = steamEntry?.launchIndex' in start, "the Dock start keeps Steam's launch entry, not only its index")
check(start.index('guard StikJITHelper.ready, wine_process_is_running() == 0') <
      start.index('DockStartProgram.apply(launcher: launcher, program: program, folder: installFolder,') <
      start.index('DockInstallers.prepare('),
      'the swap runs after the check that no session runs, before the session starts')
check('let program = DockStartProgram.chosen(game.id)' in start, "the choice is read by the game's App ID")
check('Picker("Steam starts"' in games and 'Text("Steam\'s choice").tag("")' in games and
      'DockStartProgram.setChosen(appID, next)' in games, 'Game details › Steam offers the choice and stores it')
check('dockProgram = DockStartProgram.chosen(appID)' in games, 'the page shows the stored choice')
check('guard entry.startsSteamGameDirectly else { return }' in games, "the program list is read for Madeira Dock too")
check(sum('DockStartProgram.swift' in line for line in project.splitlines()) == 4,
      'DockStartProgram.swift is in the Xcode project (file, build file, group, sources)')
check('removeItem(at: folder' not in source and 'keptSuffix = ".madeira-launcher"' in source,
      'the launcher is kept, never deleted, under a name the Program picker does not list')
check('unityData: MadeiraConfig.flag("MADEIRA_DOCK_START_UNITY_DATA"))' in start,
      'the Unity data link has its switch (env.MADEIRA_DOCK_START_UNITY_DATA = 0 turns it off)')
check('guard isLink(link, files: files) else { return false }' in source and
      'createSymbolicLink(atPath: link.path, withDestinationPath: destination)' in source and
      'relativePath(from: link.deletingLastPathComponent(), to: data)' in source,
      'the data link is relative, and only a link (never a real folder) is ever removed')

# ------------------------------------------------------------------ Swift fixture
main_swift = r'''
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let files = FileManager.default
func text(_ name: String) -> String {
    (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? "-"
}
func say(_ label: String, _ outcome: DockStartProgram.Outcome) {
    let kept = text("FalloutNVLauncher.exe.madeira-launcher")
    let kind: String
    switch outcome {
    case .unchanged: kind = "unchanged"
    case .swapped: kind = "swapped"
    case .swappedUnity: kind = "unity"
    case .restored: kind = "restored"
    case .failed: kind = "failed"
    }
    print("\(label)=\(kind) launcher=\(text("FalloutNVLauncher.exe")) kept=\(kept)")
}
let launcher = "FalloutNVLauncher.exe"
say("none", DockStartProgram.apply(launcher: launcher, program: nil, folder: folder))
say("swap", DockStartProgram.apply(launcher: launcher, program: "FalloutNV.exe", folder: folder))
say("again", DockStartProgram.apply(launcher: launcher, program: "FalloutNV.exe", folder: folder))
// A Steam repair puts the real launcher back while the kept one is there.
try! "launcher".write(to: folder.appendingPathComponent(launcher), atomically: true, encoding: .utf8)
say("repaired", DockStartProgram.apply(launcher: launcher, program: "FalloutNV.exe", folder: folder))
say("other", DockStartProgram.apply(launcher: launcher, program: "bin/Other.exe", folder: folder))
say("same", DockStartProgram.apply(launcher: launcher, program: "falloutnvlauncher.exe", folder: folder))
say("missing", DockStartProgram.apply(launcher: launcher, program: "Nope.exe", folder: folder))
say("outside", DockStartProgram.apply(launcher: launcher, program: "../Other Game/game.exe", folder: folder))
say("steam", DockStartProgram.apply(launcher: launcher, program: nil, folder: folder))
say("after", DockStartProgram.apply(launcher: launcher, program: nil, folder: folder))

let defaults = UserDefaults(suiteName: "madeira-dock-start-program-test")!
defaults.removePersistentDomain(forName: "madeira-dock-start-program-test")
DockStartProgram.setChosen(22380, "FalloutNV.exe", defaults: defaults)
DockStartProgram.setChosen(49520, "Binaries/Win32/Borderlands2.exe", defaults: defaults)
DockStartProgram.setChosen(49520, nil, defaults: defaults)
print("stored=\(DockStartProgram.chosen(22380, defaults: defaults) ?? "nil"),\(DockStartProgram.chosen(49520, defaults: defaults) ?? "nil")")
defaults.removePersistentDomain(forName: "madeira-dock-start-program-test")

// Unity: 7 Days to Die's launcher 7dLauncher.exe, the game 7DaysToDie.exe + 7DaysToDie_Data.
let unity = URL(fileURLWithPath: CommandLine.arguments[2])
func link() -> String {
    (try? files.destinationOfSymbolicLink(atPath: unity.appendingPathComponent("7dLauncher_Data").path)) ?? "-"
}
func through() -> String {
    (try? String(contentsOf: unity.appendingPathComponent("7dLauncher_Data/marker.txt"), encoding: .utf8)) ?? "-"
}
func u(_ label: String, _ outcome: DockStartProgram.Outcome) {
    let kind: String
    switch outcome {
    case .unchanged: kind = "unchanged"
    case .swapped: kind = "swapped"
    case .swappedUnity: kind = "unity"
    case .restored: kind = "restored"
    case .failed: kind = "failed"
    }
    print("\(label)=\(kind) link=\(link()) through=\(through())")
}
let ul = "7dLauncher.exe"
u("u-swap", DockStartProgram.apply(launcher: ul, program: "7DaysToDie.exe", folder: unity))
u("u-again", DockStartProgram.apply(launcher: ul, program: "7DaysToDie.exe", folder: unity))
u("u-plain", DockStartProgram.apply(launcher: ul, program: "Tool.exe", folder: unity))
u("u-back", DockStartProgram.apply(launcher: ul, program: "7DaysToDie.exe", folder: unity))
u("u-off", DockStartProgram.apply(launcher: ul, program: "7DaysToDie.exe", folder: unity, unityData: false))
u("u-on", DockStartProgram.apply(launcher: ul, program: "7DaysToDie.exe", folder: unity))
u("u-steam", DockStartProgram.apply(launcher: ul, program: nil, folder: unity))
// A launcher with a real data folder of its own (a Unity launcher) keeps it.
try! files.createDirectory(at: unity.appendingPathComponent("7dLauncher_Data"), withIntermediateDirectories: true)
u("u-real", DockStartProgram.apply(launcher: ul, program: "7DaysToDie.exe", folder: unity))
u("u-realsteam", DockStartProgram.apply(launcher: ul, program: nil, folder: unity))
print("u-realkept=\(files.fileExists(atPath: unity.appendingPathComponent("7dLauncher_Data").path) ? "yes" : "no")")
print("u-rel=\(DockStartProgram.relativePath(from: URL(fileURLWithPath: "/g"), to: URL(fileURLWithPath: "/g/bin/Game_Data")))," +
      "\(DockStartProgram.relativePath(from: URL(fileURLWithPath: "/g/a"), to: URL(fileURLWithPath: "/g/bin/Game_Data")))")
'''

with tempfile.TemporaryDirectory(prefix='madeira-dock-start-program-') as directory:
    temporary = Path(directory)
    compiler = shutil.which('swiftc')
    if not compiler:
        if args.require_swift:
            raise SystemExit('Swift compiler required for the Dock start program fixture')
        print('SKIP: Swift compiler unavailable locally; macOS CI runs this check with --require-swift')
    else:
        (temporary / 'main.swift').write_text(main_swift)
        binary = temporary / 'dockstartprogram'
        subprocess.run([compiler, '-swift-version', '5', str(app / 'DockStartProgram.swift'), str(temporary / 'main.swift'),
                        '-o', str(binary)], check=True)
        game = temporary / 'Fallout New Vegas'
        (game / 'bin').mkdir(parents=True)
        (game / 'FalloutNVLauncher.exe').write_text('launcher')
        (game / 'FalloutNV.exe').write_text('game')
        (game / 'bin/Other.exe').write_text('other')
        (temporary / 'Other Game').mkdir()
        (temporary / 'Other Game/game.exe').write_text('elsewhere')
        unity = temporary / '7 Days To Die'
        (unity / '7DaysToDie_Data').mkdir(parents=True)
        (unity / '7DaysToDie_Data/marker.txt').write_text('unity')
        (unity / '7dLauncher.exe').write_text('launcher')
        (unity / '7DaysToDie.exe').write_text('game')
        (unity / 'Tool.exe').write_text('tool')
        out = dict(line.split('=', 1) for line in subprocess.run([str(binary), str(game), str(unity)], capture_output=True, text=True,
                                                                 check=True).stdout.splitlines())
        check(out['none'] == 'unchanged launcher=launcher kept=-', "Steam's choice with nothing kept changes nothing")
        check(out['swap'] == 'swapped launcher=game kept=launcher', 'the launcher is kept and the game copied in its place')
        check(out['again'] == 'unchanged launcher=game kept=launcher', 'the next start changes nothing')
        check(out['repaired'] == 'swapped launcher=game kept=launcher', 'a launcher Steam put back is swapped again')
        check(out['other'] == 'swapped launcher=other kept=launcher', 'another choice replaces the copy; the launcher stays kept')
        check(out['same'] == 'restored launcher=launcher kept=-', "choosing Steam's own program puts the launcher back")
        check(out['missing'] == 'failed launcher=launcher kept=-', 'a program not in the folder fails and touches nothing')
        check(out['outside'] == 'failed launcher=launcher kept=-', 'a program outside the folder fails and touches nothing')
        check(out['steam'] == 'unchanged launcher=launcher kept=-' and out['after'] == 'unchanged launcher=launcher kept=-',
              "Steam's choice after a restore changes nothing")
        check((game / 'FalloutNV.exe').read_text() == 'game' and (temporary / 'Other Game/game.exe').read_text() == 'elsewhere',
              "the game's own program and other folders are never changed")
        check(out['stored'] == 'FalloutNV.exe,nil', 'the choice is stored per App ID; none clears it')
        check(out['u-swap'] == 'unity link=7DaysToDie_Data through=unity',
              "a Unity program gets a relative '<launcher>_Data' link to its data folder")
        check(out['u-again'] == 'unity link=7DaysToDie_Data through=unity', 'the next start keeps the link')
        check(out['u-plain'] == 'swapped link=- through=-', 'a program without a data folder takes the link out')
        check(out['u-back'] == 'unity link=7DaysToDie_Data through=unity', 'choosing the Unity program again links again')
        check(out['u-off'] == 'swapped link=- through=-' and out['u-on'] == 'unity link=7DaysToDie_Data through=unity',
              'the switch off takes the link out; on puts it back')
        check(out['u-steam'] == 'restored link=- through=-' and (unity / '7dLauncher.exe').read_text() == 'launcher',
              "Steam's choice puts the launcher back and takes the link out")
        check(out['u-real'].startswith('unity link=- ') and out['u-realsteam'].startswith('restored link=- ') and
              out['u-realkept'] == 'yes', "a launcher's own real data folder is never replaced or removed")
        check((unity / '7DaysToDie_Data/marker.txt').read_text() == 'unity', "the game's data folder is never changed")
        check(out['u-rel'] == 'bin/Game_Data,../bin/Game_Data', 'relative paths for the link')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
