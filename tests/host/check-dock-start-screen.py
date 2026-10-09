#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""The starting screen of a Madeira Dock start (app/Madeira/DockStartScreen.swift), on the host.

1. Swift: compiles the production rules (SteamLaunchScene, SteamLaunchHold,
   DockStartStatus) and checks which window a Dock start shows, decided by where
   the owning program lives (fixtures shaped like the census of a Dock session),
   when the starting screen hides or shows the desktop, and the status texts.
2. C: extracts the window census from app/Madeira/Winios/Winios.m and drives it
   with stubbed driver helpers under ASan/UBSan, then concurrently under
   ThreadSanitizer: top-level windows only, one path lookup per process, frames
   and swapchains, capacity, and the born-minimized restore (once, only for a
   window never shown, only while the census runs, MADEIRA_RESTORE_BORN_MINIMIZED=0
   off).
3. C: extracts winios_drv_process_image from build/win32u-unix/driver_ios.c and
   checks the path form the rules read.
4. Source checks: wiring into the library, the glyph row, no program-name lists,
   the Xcode project, licence headers.

Synthetic data only: no Wine, Steam or credentials.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
# The system C compiler: its ThreadSanitizer runtime links without libdispatch.
CC = os.environ.get('CC') or shutil.which('cc') or shutil.which('clang')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


screen = (app / 'DockStartScreen.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
content = (app / 'ContentView.swift').read_text(encoding='utf-8')
winios = (app / 'Winios/Winios.m').read_text(encoding='utf-8')
header = (app / 'Winios/Winios.h').read_text(encoding='utf-8')
driver = (root / 'build/win32u-unix/driver_ios.c').read_text(encoding='utf-8')
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
rules = screen[screen.index('// MARK: - Rules'):screen.index('// MARK: - Model')]

# ------------------------------------------------------------------ 4. static
require(screen.startswith('// SPDX-License-Identifier: GPL-3.0-or-later\n// Copyright 2026 125hz\n'
                          '// Madeira Converter Exception: see LICENSE-EXCEPTION.md\n'),
        'DockStartScreen.swift: GPL-3.0-or-later, Copyright 2026 125hz, Converter Exception')
require('/* DockStartScreen.swift in Sources */,' in project and 'path = "DockStartScreen.swift"' in project,
        'DockStartScreen.swift is built by the Xcode project')
require(re.search(r'\bView\b|SwiftUI|MadeiraDock\.|MadeiraConfig|getenv', rules.replace('// MARK: - Rules', '')) is None,
        'the rules are Foundation-only and pure (switches are passed in)')
for text in (screen, winios[winios.index('Top-level window census'):winios.index('void winios_pDestroyWindow(HWND hwnd)')]):
    require(not re.findall(r'"[^"\n]*\.exe"', text), 'no program names in the rules or the census')
require('clientImages' not in screen and 'helperImages' not in screen and 'helperPrefixes' not in screen,
        'no program-name lists: owners are classed by folder')
require('library.begin(.dockSession(title: game.name, width: width, height: height), remember: false, dock: game)' in content
        and 'library.begin(profile, dock: game)' in content,
        "a Dock start (from Settings or a Steam game's Game details page) tells the library which game it starts")
require('DockStartScreen.shared.begin(dock, at: launchStarted)' in library and 'DockStartScreen.shared.finish()' in library,
        'the library begins and ends the Dock starting screen with the session')
poll = library[library.index('    private func poll() {'):]
poll = poll[:poll.index('\n    }\n')]
require(poll.index('if dockStart.holding {') < poll.index('showGameView(reason: "surface")'),
        "while the hold is on, the desktop's first frame does not end the starting screen")
row = library[library.index("The starting screen's controls are one row of glyph-only buttons"):]
row = row[:row.index('if model.launchSlow')]
require('HStack(spacing: 14)' in row, 'one row of glyph buttons')
order = [row.index('"Close session", "stop.circle"'), row.index('"Hide live log" : "Show live log", "text.alignleft"'),
         row.index('"Show desktop", "macwindow"')]
require(order == sorted(order), 'glyph order: close session, live log, show desktop')
require('if dockStart.failure != nil {' in row and 'if dockStart.holding {' in row and 'dockStart.showDesktop(model)' in row,
        'close session only once the Dock stopped; show desktop only while the desktop is held back')
require('Text("Madeira Dock stopped")' in library and 'DockInstallers.note' in library and 'DockStartStatus.text(' in library,
        'the starting screen shows the Dock status, the one-time-install note, and a stop with its words')
status = library[library.index('    private var dockStatus: String {'):]
status = status[:status.index('\n    }\n')]
require(status.index('DockInstallers.poll(drive: MadeiraDock.drive)') < status.index('DockInstallers.finishedAt ?? model.launchStartedAt')
        and 'installsFinished: DockInstallers.finishedAt != nil' in status and 'waited: Date().timeIntervalSince(hostDue)' in status,
        "the status line reads the installs' end after polling them, and times the host from it (or from the start)")
require('SteamGameArtwork(appID: appID)' in library and 'SteamLaunchBackdrop(appID: appID)' in library,
        "a Dock start shows the game's cover and backdrop by App ID")
require('winios_window_census_enable(1)' in screen and screen.count('winios_window_census_enable(0)') == 1,
        'the census runs only while a Dock start holds the desktop back')
require('int winios_drv_foreground_if_owner( HWND hwnd )' in driver and 'GetCurrentThreadId()' in driver and
        'NtUserPostMessage( hwnd, WM_SYSCOMMAND, SC_RESTORE, 0 )' in driver, 'driver helpers: restore posted, front by the own thread')
events = winios[winios.index('BOOL winios_pProcessEvents(DWORD mask) {'):]
events = events[:events.index('static unsigned int cnt;')]
require('winios_drv_foreground_if_owner((HWND)fg)' in events and 'atomic_compare_exchange_strong(&g_restore_foreground, &fg, 0)' in events,
        "a restored born-minimized window is brought to the front by its own thread's event pump")
destroy = winios[winios.index('void winios_pDestroyWindow(HWND hwnd) {'):]
destroy = destroy[:destroy.index('\n}\n')]
require('atomic_compare_exchange_strong(&g_restore_foreground, &pending, 0)' in destroy and 'winios_census_forget(hwnd)' in destroy,
        'a destroyed window leaves the census and any pending front request')
require(winios.count('winios_census_note_frame(hwnd, x, y, w, h, visible);') == 1 and
        winios.count('winios_census_note_present(hwnd);') == 1 and winios.count('winios_census_note_metal((HWND)hwnd);') == 1,
        'the census is fed by the frame, GDI flush and swapchain hooks')
require('#include "Winios.h"' in winios, 'Winios.m includes the header Swift reads the census struct from')

# ------------------------------------------------------------------ 1. Swift
checks = r'''
import Foundation
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}
var nextHwnd: UInt64 = 0x100
func window(_ image: String, _ w: Int, _ h: Int, visible: Bool = true, drawn: Bool = true) -> SteamLaunchWindow {
    nextHwnd += 2
    return SteamLaunchWindow(image: image, width: w, height: h, visible: visible, drawn: drawn, pid: 0x40, hwnd: nextHwnd)
}

@main struct Checks {
    static func main() {
        typealias S = SteamLaunchScene
        let places = S.Places(clientRoot: "C:\\Program Files (x86)\\Steam")
        require(places.windows == "c:\\windows\\" && places.client == "c:\\program files (x86)\\steam\\" &&
                places.clientLibrary == "c:\\program files (x86)\\steam\\steamapps\\", "places: lower case, ending in a backslash")
        require(S.path("\\??\\C:\\Games\\X\\Game.EXE") == "c:\\games\\x\\game.exe" && S.path("\\\\?\\C:/Games/x.exe") == "c:\\games\\x.exe" &&
                S.path("c:\\a.exe") == "c:\\a.exe", "NT and Win32 path forms read the same")

        // --- Owner classes, by folder only.
        require(S.owner("\\??\\C:\\windows\\system32\\conhost.exe", places: places) == .helper, "a console host (Windows folder) is a helper")
        require(S.owner("c:\\windows\\explorer.exe", places: places) == .helper, "the shell is a helper")
        require(S.owner("C:\\windows\\system32\\dockhost.exe", places: places) == .helper, "the Dock host is a helper")
        require(S.owner("c:\\windowsapps\\tool.exe", places: places) == .other, "a sibling folder with the same prefix is not the Windows folder")
        require(S.owner("C:\\Program Files (x86)\\Steam\\reporter.exe", places: places) == .client, "a program in the client's folder is the client's")
        require(S.owner("C:\\Program Files (x86)\\Steam\\bin\\tool.exe", places: places) == .client, "and in its subfolders")
        require(S.owner("C:\\Program Files (x86)\\Steam\\steamapps\\common\\Fixture Game\\game.exe", places: places) == .other,
                "a game in the client's own library is not the client's")
        require(S.owner("C:\\Program Files (x86)\\SteamX\\a.exe", places: places) == .other, "a sibling of the client's folder is not the client's")
        require(S.owner("C:\\Games\\Library\\steamapps\\common\\Other\\x64\\run.exe", places: places) == .other, "a game in another library")
        require(S.owner("", places: places) == .unknown, "an unreadable owner")

        // --- Which window is up (a Dock session's census).
        let console = window("\\??\\C:\\windows\\system32\\conhost.exe", 665, 509)   // the host's console window
        let tray = window("c:\\windows\\explorer.exe", 166, 52)                       // explorer's small captioned window
        let host = window("c:\\windows\\system32\\dockhost.exe", 1280, 720, visible: false)
        let before = [console, tray, host]
        require(S.decide(before, rendered: false, places: places).scene == .waiting, "console, tray and the host's hidden window: keep waiting")
        require(S.decide(before, rendered: true, places: places).scene == .waiting, "D3D frames never make a helper's window the game's")
        let game = window("\\??\\C:\\Program Files (x86)\\Steam\\steamapps\\common\\Fixture Game\\bin\\Game.exe", 1280, 720)
        for externalPath in ["E:\\steamapps\\common\\Fixture Game\\game.exe",
                             "C:\\MadeiraExternalLibrary\\steamapps\\common\\Fixture Game\\game.exe"] {
            let external = window(externalPath, 1280, 720)
            require(S.owner(externalPath, places: places) == .other &&
                    S.decide(before + [external], rendered: false, places: places).scene == .game,
                    "external library: canonical E and scoped C alias both classify a drawn game window")
            require(S.decide(before + [external], rendered: false, places: places, early: [external.hwnd]).scene == .steamWindow,
                    "external library: prerequisite window remains an installer when first shown before the host")
        }
        let decided = S.decide(before + [game], rendered: false, places: places)
        require(decided.scene == .game && decided.window == game, "the game's shown, drawn window ends the wait")
        require(S.decide(before + [window("C:\\Program Files\\Publisher\\Launcher\\start.exe", 800, 600)], rendered: false, places: places).scene == .game,
                "a launcher outside the game's folder counts as the game")
        require(S.decide([window("c:\\games\\x\\game.exe", 1280, 720, drawn: false)], rendered: false, places: places).scene == .waiting,
                "an undrawn game window waits for its first frame")
        require(S.decide([window("c:\\games\\x\\game.exe", 1280, 720, drawn: false)], rendered: true, places: places).scene == .game,
                "D3D frames count as the game window's first frame")
        require(S.decide([window("c:\\games\\x\\game.exe", 150, 40)], rendered: true, places: places).scene == .waiting, "small windows are not the game")
        require(S.decide([window("c:\\games\\x\\game.exe", 1280, 720, visible: false)], rendered: true, places: places).scene == .waiting,
                "hidden windows are not the game")
        require(S.decide([window("", 1280, 720)], rendered: false, places: places).scene == .waiting &&
                S.decide([window("", 1280, 720)], rendered: true, places: places).scene == .game, "unknown owner: only D3D frames decide")

        // Valve's client's own dialogs may need the user.
        let reporter = window("C:\\Program Files (x86)\\Steam\\reporter.exe", 400, 300)
        let asked = S.decide(before + [reporter], rendered: false, places: places)
        require(asked.scene == .steamWindow && asked.window == reporter, "a shown client dialog needs the user")
        require(S.decide([window("C:\\Program Files (x86)\\Steam\\a.exe", 400, 300, drawn: false)], rendered: false, places: places).scene == .waiting,
                "an undrawn client window does not")
        require(S.decide([window("C:\\Program Files (x86)\\Steam\\a.exe", 200, 100)], rendered: false, places: places).scene == .waiting,
                "a small client window does not")
        require(S.decide([reporter, game], rendered: false, places: places).scene == .game, "the game's window wins over a client dialog")

        // One-time installs run before the host starts: their windows are never the game's.
        let setup = window("C:\\Program Files (x86)\\Steam\\steamapps\\common\\Fixture Game\\_CommonRedist\\setup.exe", 480, 360)
        let early: Set<UInt64> = [setup.hwnd]
        let installing = S.decide(before + [setup], rendered: true, places: places, early: early)
        require(installing.scene == .steamWindow && installing.window == setup, "an installer's dialog needs the user, never ends the wait")
        require(S.decide([setup], rendered: true, places: places, early: early, installerReveal: false).scene == .waiting,
                "MADEIRA_DOCK_INSTALLER_REVEAL=0 keeps installer dialogs hidden")
        var small = setup; small.width = 200; small.height = 100
        require(S.decide([small], rendered: false, places: places, early: early).scene == .waiting, "a small installer window does not")
        var undrawn = setup; undrawn.drawn = false
        require(S.decide([undrawn], rendered: false, places: places, early: early).scene == .waiting, "an undrawn installer window does not")
        let unknownEarly = window("", 800, 600)
        require(S.decide([unknownEarly], rendered: true, places: places, early: [unknownEarly.hwnd]).scene == .waiting,
                "an early unknown window is not the game either")
        require(S.decide([setup, game], rendered: false, places: places, early: early).scene == .game, "the game's window still wins")
        require(S.decide([setup], rendered: false, places: places).scene == .game,
                "the same program's window after the host started is the game's")
        require(S.decide([window("c:\\windows\\system32\\msiexec.exe", 326, 140)], rendered: false, places: places, early: []).scene == .waiting,
                "Windows-folder programs never reveal, before or after")

        // --- When the starting screen hides or shows the desktop.
        var hold = SteamLaunchHold(autoReveal: true)
        var actions: [SteamLaunchHold.Action] = []
        for (t, scene) in [(0.0, SteamLaunchScene.waiting), (1, .steamWindow), (2.5, .steamWindow), (3, .steamWindow)] {
            actions.append(hold.step(scene, now: t))
        }
        require(actions == [.none, .none, .none, .reveal] && hold.revealed && !hold.needsAttention, "reveal after the dialog stays 2 s (\(actions))")
        actions = [hold.step(.waiting, now: 4), hold.step(.steamWindow, now: 5), hold.step(.waiting, now: 6), hold.step(.waiting, now: 9.5), hold.step(.waiting, now: 10)]
        require(actions == [.none, .none, .none, .none, .cover] && !hold.revealed, "cover 4 s after it closed, restarted by a reappearance (\(actions))")
        _ = hold.step(.steamWindow, now: 11)
        require(hold.needsAttention, "attention while the dialog is behind the starting screen")
        require(hold.step(.game, now: 12) == .showGame && hold.finished && hold.step(.steamWindow, now: 20) == .none, "the game's window ends the hold")

        var manual = SteamLaunchHold(autoReveal: true)
        require(manual.showDesktop() && !manual.showDesktop() && manual.revealed, "Show desktop reveals at once, once")
        require(manual.step(.waiting, now: 100) == .none && manual.revealed, "a manual reveal is never covered again")
        require(manual.step(.game, now: 101) == .showGame, "game after a manual reveal")
        var done = SteamLaunchHold(autoReveal: true)
        _ = done.step(.game, now: 1)
        require(!done.showDesktop(), "no Show desktop after the game's window")

        var off = SteamLaunchHold(autoReveal: false)
        require((0..<20).allSatisfy { off.step(.steamWindow, now: Double($0)) == .none } && off.needsAttention, "auto-reveal off: button only")

        var flapping = SteamLaunchHold(autoReveal: true)
        var reveals = 0, covers = 0, t = 0.0
        for _ in 0..<20 {
            for _ in 0..<6 { if flapping.step(.steamWindow, now: t) == .reveal { reveals += 1 }; t += 0.5 }
            for _ in 0..<10 { if flapping.step(.waiting, now: t) == .cover { covers += 1 }; t += 0.5 }
        }
        require(reveals == SteamLaunchHold.maxAutoReveals && covers == SteamLaunchHold.maxAutoReveals - 1 && flapping.revealed,
                "a flapping dialog stops toggling and stays shown (reveals=\(reveals) covers=\(covers))")

        // --- The status line: the furthest stage the host reported.
        typealias D = DockStartStatus
        func text(_ fields: [String: String], installers: Bool = false, progress: String? = nil, finished: Bool = false,
                  waited: Double = 5) -> String {
            D.text(fields, installers: installers, installerProgress: progress, installsFinished: finished, waited: waited)
        }
        // Report fields in the order a device log's [dock-report] lines show them.
        let started: [String: String] = ["probe-start-bits": "64", "client-machine": "34404", "load-client-begin": "0",
                                      "session-client-adapter": "202601"]
        let loaded = started.merging(["public-client021-present": "1", "engine005-present": "1", "engine-factory-result": "0"]) { $1 }
        let submitted = loaded.merging(["session-private-abi-verified": "1", "session-native-token-submitted": "1",
                                        "session-logon-start-result": "1"]) { $1 }
        let online = submitted.merging(["session-authenticated-online": "1"]) { $1 }
        let listed = online.merging(["session-requested-app-entitled": "1", "session-subscription-count": "12",
                                     "session-requested-app-listed": "1"]) { $1 }
        let launched = listed.merging(["launch-client-error": "0"]) { $1 }
        require(text([:]) == "Starting Madeira Dock…", "no field yet: the host is starting")
        require(text([:], waited: 29) == "Starting Madeira Dock…" && text([:], waited: 30) == "Still starting Madeira Dock…",
                "after 30 s without its first field the host is late")
        require(text(started) == "Loading Steam…" && text(loaded) == "Loading Steam…", "host started: Valve's client loads")
        require(text(started, waited: 300) == "Loading Steam…", "late only matters before the host's first field")
        require(text(submitted) == "Signing in to Steam…" && text(["probe-start-bits": "64", "session-logon-start-result": "1"]) == "Signing in to Steam…",
                "the sign-in was submitted")
        require(text(online) == "Signed in. Waiting for Steam to confirm this game's license…", "signed in, the license check waits")
        require(text(online.merging(["session-authenticated-online": "0"]) { $1 }) == "Signing in to Steam…", "signed out again: signing in")
        require(text(online.merging(["session-requested-app-entitled": "1", "session-requested-app-listed": "0"]) { $1 }) ==
                "Signed in. Waiting for Steam to confirm this game's license…", "a license not listed is not confirmed")
        require(text(listed) == "License confirmed. Steam is starting the game…", "license confirmed")
        let preparing = listed.merging(["ceg-scm": "1", "ceg-request-result": "1", "ceg-request": "1"]) { $1 }
        require(text(preparing) == "Steam is preparing this game's executable…" &&
                text(listed.merging(["ceg-request-busy": "10"]) { $1 }) == "Steam is preparing this game's executable…",
                "a game whose executable Steam prepares per user")
        require(text(preparing.merging(["ceg-result": "1"]) { $1 }) == "License confirmed. Steam is starting the game…", "executable prepared")
        require(text(listed.merging(["ceg-disabled": "1"]) { $1 }) == "License confirmed. Steam is starting the game…", "no preparation")
        require(text(launched) == "The game is starting. Waiting for its window…" &&
                text(preparing.merging(["ceg-result": "1", "launch-client-error": "0"]) { $1 }) == "The game is starting. Waiting for its window…",
                "Steam accepted the launch: waiting for the game's window")
        require(text(listed.merging(["launch-client-error": "17"]) { $1 }) == "License confirmed. Steam is starting the game…",
                "a refusal without a wait keeps the last stage until the host's result")

        // Steam's own waits come first.
        let update = listed.merging(["launch-client-error": "17", "launch-update-wait": "17"]) { $1 }
        require(text(update).hasPrefix("Steam is installing content"), "content wait")
        require(text(update.merging(["launch-update-ready": "3", "launch-client-error": "0"]) { $1 }) == "The game is starting. Waiting for its window…",
                "content ready")
        let session = listed.merging(["launch-session-wait": "35", "launch-client-error": "35"]) { $1 }
        require(text(session).hasPrefix("Steam says this account is still playing in another session"), "session wait (35)")
        require(text(listed.merging(["launch-session-wait": "35", "launch-client-error": "22"]) { $1 }) == "License confirmed. Steam is starting the game…",
                "another error is not the session wait")
        require(text(session.merging(["launch-client-error": "0"]) { $1 }) == "The game is starting. Waiting for its window…", "session wait over")
        let config = listed.merging(["launch-config-wait": "22", "launch-client-error": "22"]) { $1 }
        require(text(config) == "Steam is still loading this game's configuration. Waiting for it…" &&
                text(config.merging(["launch-client-error": "23"]) { $1 }) == "Steam is still loading this game's configuration. Waiting for it…",
                "configuration wait (22, 23)")
        require(text(config.merging(["launch-client-error": "0"]) { $1 }) == "The game is starting. Waiting for its window…", "configuration loaded")

        // The one-time installs run before the host's first field.
        require(text([:], installers: true) == "Running this game's one-time installs…", "installs")
        require(text([:], installers: true, progress: "Running one-time install 1 of 2: a…", waited: 90) == "Running one-time install 1 of 2: a…",
                "installs with their progress, never late")
        let finishedWords = "One-time installs finished: 1 of 3 succeeded.\nFailed: b (exit 5), c (exit 7)"
        require(text([:], installers: true, progress: finishedWords, finished: true) == finishedWords + "\nStarting Madeira Dock…",
                "installs finished: how many succeeded, and the host starts next")
        require(text([:], installers: true, progress: finishedWords, finished: true, waited: 31) == finishedWords + "\nStill starting Madeira Dock…",
                "late counts from the installs' end")
        require(text([:], installers: true, progress: nil, finished: true) == "One-time installs finished.\nStarting Madeira Dock…",
                "installs finished without progress words")
        require(text(started, installers: true, progress: finishedWords, finished: true) == "Loading Steam…" &&
                text(started, installers: true, progress: "x") == "Loading Steam…", "the host's first field ends the installs")
        require(D.hostStarted(["probe-start-bits": "64"]) && !D.hostStarted([:]), "host start")
        require(D.failure(result: nil, words: nil, launching: true) == nil, "no result: the start goes on")
        require(D.failure(result: 0, words: nil, launching: false) == nil, "a normal end after the game's window is not a failure")
        require(D.failure(result: 0, words: nil, launching: true) == "Madeira Dock exited before a game window appeared. Export the diagnostic log.",
                "a normal end before any game window is")
        require(D.failure(result: 35, words: "words", launching: false) == "words", "a failure keeps the report's words")

        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all Dock starting-screen Swift checks")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-dock-start-') as tmp:
    tmp = Path(tmp)
    (tmp / 'rules.swift').write_text('import Foundation\n' + rules, encoding='utf-8')
    (tmp / 'checks.swift').write_text(checks, encoding='utf-8')
    exe = tmp / 'swift-checks'
    r = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-o', str(exe),
                        str(tmp / 'rules.swift'), str(tmp / 'checks.swift')])
    require(r.returncode == 0, 'Swift rules compile on the host')
    if r.returncode == 0:
        r = subprocess.run([str(exe)])
        require(r.returncode == 0, 'Swift rule checks')

# ------------------------------------------------------------------ 2. C census
census = winios[winios.index('#define WINIOS_WS_VISIBLE'):winios.index('void winios_pDestroyWindow(HWND hwnd)')]

c_prelude = r'''
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "Winios.h"
typedef void *HWND;

/* Stubbed driver helpers (build/win32u-unix/driver_ios.c): a table of fake windows. */
struct fake { HWND hwnd; unsigned style; int top; unsigned pid; };
static struct fake fakes[256];
static int nfakes;
static _Atomic int image_queries, restores;
static HWND last_restore;
static struct fake *lookup(HWND h) { for (int i = 0; i < nfakes; i++) if (fakes[i].hwnd == h) return &fakes[i]; return NULL; }
int winios_drv_census_owner(HWND hwnd, unsigned int *pid, unsigned int *style) {
    struct fake *f = lookup(hwnd);
    *pid = 0; *style = 0;
    if (!f || !f->top) return 0;
    *pid = f->pid; *style = f->style;
    return 1;
}
int winios_drv_process_image(unsigned int pid, char *out, unsigned int size) {
    atomic_fetch_add(&image_queries, 1);
    if (pid == 0x99) { out[0] = 0; return 0; }
    snprintf(out, size, "c:\\games\\pid%u\\game%u.exe", pid, pid);
    return 1;
}
int winios_drv_post_restore(HWND hwnd) { atomic_fetch_add(&restores, 1); last_restore = hwnd; return 1; }
int winios_drv_foreground_if_owner(HWND hwnd) { return hwnd ? 1 : 0; }
static HWND add(unsigned long h, unsigned style, int top, unsigned pid) {
    fakes[nfakes] = (struct fake){ (HWND)h, style, top, pid };
    return fakes[nfakes++].hwnd;
}
'''

c_checks = r'''
static int failures;
#define CHECK(c, label) do { if (c) printf("PASS: %s\n", label); else { printf("FAIL: %s\n", label); failures++; } } while (0)
static struct winios_census_window out[WINIOS_CENSUS_MAX];
static struct winios_census_window *find(HWND h, int n) { for (int i = 0; i < n; i++) if (out[i].hwnd == (unsigned long long)(uintptr_t)h) return &out[i]; return NULL; }

static void *writer(void *arg) {
    long base = (long)arg;
    for (int round = 0; round < 2000; round++) {
        HWND h = (HWND)(uintptr_t)(0x9000 + base * 16 + round % 16);
        winios_census_note_frame(h, 0, 0, 640, 480, round & 1);
        winios_census_note_present(h);
        if (round % 7 == 0) winios_census_forget(h);
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "restore-off")) {
        /* MADEIRA_RESTORE_BORN_MINIMIZED=0 in the environment. */
        HWND born = add(0x700, 0x34c80000, 1, 0x70);
        winios_window_census_enable(1);
        winios_census_note_frame(born, -32000, -32000, 160, 24, 1);
        int n = winios_window_census(out, WINIOS_CENSUS_MAX);
        CHECK(restores == 0 && find(born, n) && !find(born, n)->restore_sent && !atomic_load(&g_restore_foreground),
              "MADEIRA_RESTORE_BORN_MINIMIZED=0 leaves a born-minimized window alone");
        return failures ? 1 : 0;
    }
    HWND desktop = add(0x20, 0x96000000, 0, 1);
    HWND child = add(0x101, 0x50000000, 0, 7);            /* WS_CHILD|WS_VISIBLE */
    HWND dialog = add(0x100, 0x96ca0000, 1, 7);           /* visible dialog */
    HWND game = add(0x200, 0x94000000, 1, 0x44);          /* WS_POPUP|WS_VISIBLE */
    HWND game2 = add(0x201, 0x14c80000, 1, 0x44);         /* same process */
    HWND mini = add(0x202, 0x34c80000, 1, 0x44);          /* WS_VISIBLE|WS_MINIMIZE, never shown */
    HWND hidden = add(0x203, 0x84000000, 1, 0x44);        /* not WS_VISIBLE */
    HWND nameless = add(0x300, 0x94000000, 1, 0x99);      /* path lookup fails */

    winios_census_note_frame(game, 0, 0, 1280, 720, 1);
    winios_census_note_frame(mini, -32000, -32000, 160, 24, 1);
    CHECK(winios_window_census(out, WINIOS_CENSUS_MAX) == 0 && image_queries == 0 && restores == 0,
          "off: nothing recorded, nothing asked, nothing restored");

    winios_window_census_enable(1);
    winios_census_note_frame(desktop, 0, 0, 1280, 720, 1);
    winios_census_note_frame(child, 10, 10, 100, 100, 1);
    winios_census_note_frame(dialog, 287, 140, 705, 440, 1);
    winios_census_note_frame(game, 0, 0, 1280, 720, 1);
    winios_census_note_frame(game2, 0, 0, 640, 480, 1);
    winios_census_note_frame(hidden, 0, 0, 800, 600, 1);
    winios_census_note_frame(nameless, 0, 0, 800, 600, 1);
    int n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(n == 5 && !find(desktop, n) && !find(child, n), "top-level windows only: no desktop, no child");
    struct winios_census_window *d = find(dialog, n), *g = find(game, n), *u = find(nameless, n);
    CHECK(d && !strcmp(d->image, "c:\\games\\pid7\\game7.exe") && d->pid == 7 && d->visible && d->w == 705 && d->h == 440,
          "dialog window: owner path and pid");
    CHECK(g && !strcmp(g->image, "c:\\games\\pid68\\game68.exe") && g->visible && g->shown_once, "game window owner, shown once");
    CHECK(find(hidden, n) && !find(hidden, n)->visible, "a hidden window is not shown");
    CHECK(u && u->image[0] == 0 && u->pid == 0x99, "an unreadable owner stays empty");
    CHECK(image_queries == 3, "one path lookup per process");

    /* Born minimized: first shown minimized, never shown before. */
    winios_census_note_frame(mini, -32000, -32000, 160, 24, 1);
    n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(restores == 1 && last_restore == mini && find(mini, n)->restore_sent && !find(mini, n)->visible,
          "a window first shown minimized gets SC_RESTORE");
    CHECK(atomic_load(&g_restore_foreground) == (uintptr_t)mini, "and is queued to come to the front");
    winios_census_note_frame(mini, -32000, -32000, 160, 24, 1);
    CHECK(restores == 1, "only once");
    /* A window shown before and minimized later is left alone. */
    fakes[3].style = 0x34000000;
    winios_census_note_frame(game, -32000, -32000, 160, 24, 1);
    CHECK(restores == 1, "a window that was shown and then minimized is left alone");
    fakes[3].style = 0x94000000;
    winios_census_note_frame(game, 0, 0, 1280, 720, 1);

    winios_census_note_frame(game, 0, 0, 1280, 720, 0);
    n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(!find(game, n)->visible, "hidden by SetWindowPos");
    winios_census_note_present(game); winios_census_note_present(game); winios_census_note_present(child);
    winios_census_note_metal(game2);
    n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(find(game, n)->presents == 2 && find(game2, n)->metal && !find(game, n)->metal, "frames and swapchains per window");
    winios_census_forget(game);
    n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(n == 5 && !find(game, n) && find(game2, n), "destroyed windows leave");
    CHECK(winios_window_census(out, 2) == 2, "copy is bounded by the caller");

    for (unsigned long i = 0; i < 80; i++) winios_census_note_frame(add(0x1000 + i, 0x84000000, 1, 0x44), 0, 0, 10, 10, 1);
    n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(n == WINIOS_CENSUS_MAX, "capacity holds");
    HWND late = add(0x5000, 0x94000000, 1, 0x44);
    winios_census_note_frame(late, 0, 0, 1280, 720, 1);
    n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(find(late, n) && find(late, n)->visible && find(dialog, n), "a full census gives a hidden window's slot to a shown one");

    winios_window_census_enable(0);
    CHECK(winios_window_census(out, WINIOS_CENSUS_MAX) == 0, "off: emptied");
    winios_window_census_enable(1);
    int before = image_queries;
    winios_census_note_frame(dialog, 287, 140, 705, 440, 1);
    CHECK(image_queries == before + 1, "a new census forgets cached process paths");

    /* Concurrency: writers on "Wine threads", the app reading on the main thread. */
    for (long t = 0; t < 4; t++) for (int i = 0; i < 16; i++) add(0x9000 + t * 16 + i, 0x94000000, 1, 0x50 + (unsigned)t);
    pthread_t threads[4];
    for (long t = 0; t < 4; t++) pthread_create(&threads[t], NULL, writer, (void *)t);
    for (int i = 0; i < 2000; i++) winios_window_census(out, WINIOS_CENSUS_MAX);
    for (int t = 0; t < 4; t++) pthread_join(threads[t], NULL);
    n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(n > 0 && n <= WINIOS_CENSUS_MAX, "concurrent writers and reader");
    winios_window_census_enable(0);

    if (failures) { printf("FAILURES: %d\n", failures); return 1; }
    printf("PASS: all census checks\n");
    return 0;
}
'''

# ------------------------------------------------------------------ 3. driver path form
image = driver[driver.index('int winios_drv_process_image( unsigned int pid, char *out, unsigned int size )'):]
image = image[:image.index('\n}\n') + 3]
d_prelude = r'''
#include <stdio.h>
#include <string.h>
typedef unsigned short WCHAR;
typedef unsigned short USHORT;
typedef unsigned long ULONG_PTR;
typedef struct { USHORT Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { ULONG_PTR ProcessId; UNICODE_STRING ImageName; } SYSTEM_PROCESS_ID_INFORMATION;
#define MAX_PATH 260
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
enum { SystemProcessIdInformation = 88 };
static const char *next_path;
static const WCHAR *next_wide;
static int NtQuerySystemInformation(int cls, void *info, unsigned size, unsigned *ret) {
    SYSTEM_PROCESS_ID_INFORMATION *id = info;
    size_t n = 0;
    if (cls != SystemProcessIdInformation || size != sizeof(*id) || id->ImageName.Length || !id->ProcessId) return 0xc000000d;
    if (!next_path && !next_wide) return 0xc000000b;
    if (next_wide) { while (next_wide[n]) n++; } else n = strlen(next_path);
    if ((n + 1) * 2 > id->ImageName.MaximumLength) return 0xc0000004;
    for (size_t i = 0; i < n; i++) id->ImageName.Buffer[i] = next_wide ? next_wide[i] : (WCHAR)(unsigned char)next_path[i];
    id->ImageName.Length = (USHORT)(n * 2);
    (void)ret;
    return 0;
}
'''
d_checks = r'''
static int failures;
#define CHECK(c, label) do { if (c) printf("PASS: %s\n", label); else { printf("FAIL: %s\n", label); failures++; } } while (0)
int main(void) {
    char out[264], small[12];
    next_path = "\\??\\C:\\Windows\\System32\\Conhost.EXE";
    CHECK(winios_drv_process_image(7, out, sizeof(out)) == 1 && !strcmp(out, "c:\\windows\\system32\\conhost.exe"),
          "NT prefix removed, lower case");
    next_path = "C:/Games/X/Game.exe";
    CHECK(winios_drv_process_image(7, out, sizeof(out)) == 1 && !strcmp(out, "c:\\games\\x\\game.exe"), "slashes become backslashes");
    static const WCHAR wide[] = { 'C', ':', '\\', 0xe9, 'x', '.', 'e', 'x', 'e', 0 };
    next_path = NULL; next_wide = wide;
    CHECK(winios_drv_process_image(7, out, sizeof(out)) == 1 && !strcmp(out, "c:\\?x.exe"), "non-ASCII characters become '?'");
    next_wide = NULL; next_path = "\\??\\C:\\Program Files (x86)\\Steam\\steamapps\\common\\A\\a.exe";
    CHECK(winios_drv_process_image(7, small, sizeof(small)) == 1 && !strcmp(small, "c:\\program "), "a long path is cut to the buffer");
    next_path = NULL;
    CHECK(winios_drv_process_image(7, out, sizeof(out)) == 0 && out[0] == 0, "an unknown process has no path");
    CHECK(winios_drv_process_image(0, out, sizeof(out)) == 0 && out[0] == 0, "pid 0 is not asked");
    if (failures) { printf("FAILURES: %d\n", failures); return 1; }
    printf("PASS: all driver path checks\n");
    return 0;
}
'''

if not CC:
    require(False, 'a C compiler (clang or cc) for the census checks')
else:
    with tempfile.TemporaryDirectory(prefix='madeira-census-') as tmp:
        tmp = Path(tmp)
        (tmp / 'census.c').write_text(c_prelude + census + c_checks, encoding='utf-8')
        for name, flags in [('asan', ['-fsanitize=address,undefined', '-fno-sanitize-recover=undefined']), ('tsan', ['-fsanitize=thread'])]:
            exe = tmp / ('census-' + name)
            r = subprocess.run([CC, '-std=gnu11', '-O1', '-g', '-Wall', '-Wno-unused-function', '-Werror=implicit-function-declaration',
                                '-I', str(app / 'Winios'), *flags, str(tmp / 'census.c'), '-o', str(exe), '-lpthread'])
            require(r.returncode == 0, f'census compiles ({name})')
            if r.returncode:
                continue
            print(f'--- census under {name}')
            env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0', TSAN_OPTIONS='halt_on_error=1')
            env.pop('MADEIRA_RESTORE_BORN_MINIMIZED', None)
            require(subprocess.run([str(exe)], env=env).returncode == 0, f'census checks ({name})')
            env['MADEIRA_RESTORE_BORN_MINIMIZED'] = '0'
            require(subprocess.run([str(exe), 'restore-off'], env=env).returncode == 0, f'restore switch ({name})')
        (tmp / 'image.c').write_text(d_prelude + image + d_checks, encoding='utf-8')
        exe = tmp / 'image'
        r = subprocess.run([CC, '-std=gnu11', '-O1', '-g', '-Wall', '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined',
                            str(tmp / 'image.c'), '-o', str(exe)])
        require(r.returncode == 0 and subprocess.run([str(exe)], env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0')).returncode == 0,
                'driver path form')

print('FAILURES: %d' % failures if failures else 'PASS: all Dock starting-screen checks')
sys.exit(1 if failures else 0)
