#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Pause threads fully, per game (app/Madeira/LibraryBCD.swift, BCDLaunch.realSuspend).

MADEIRA_REAL_SUSPEND makes a Wine SuspendThread really stop the thread (ml730). A
Unity IL2CPP game's garbage collector needs that (Megabonk crashed while loading
without it), so Automatic turns it on when GameAssembly.dll is in the game's folder.
The game's On or Off wins over madeira.cfg's real-suspend, which wins over Automatic;
with none of them the variable is unset, and wineserver reads it on every call so
the next session of the app run sees its own value.
"""
from pathlib import Path
import re, sys, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
bcd = (root / 'app/Madeira/LibraryBCD.swift').read_text(encoding='utf-8')
prefs = (root / 'app/Madeira/LibraryPrefs.swift').read_text(encoding='utf-8')
view = (root / 'app/Madeira/ContentView.swift').read_text(encoding='utf-8')
lib = (root / 'app/Madeira/Library.swift').read_text(encoding='utf-8')
server = (root / 'build/wineserver/mach_ios.c').read_text(encoding='utf-8')
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


m = re.search(r'static func realSuspend\(_ entry: LibraryEntry\?\).*?\n    \}\n', bcd, re.S)
fn = m.group(0) if m else ''
i_game = fn.find('LibraryPrefs.realSuspend(entry.windowsPath)')
i_cfg = fn.find('MadeiraConfig.get("real-suspend")')
i_auto = fn.find('isUnityIL2CPP(entry)')
check(fn != '', 'BCDLaunch.realSuspend exists')
check(0 <= i_game < i_cfg < i_auto, "the game's switch, then madeira.cfg, then Automatic")
check('entry.desktop != true' in fn, 'the Desktop entry has no per-game choice')
check('"GameAssembly.dll"' in bcd, 'Automatic looks for GameAssembly.dll')
check('static func realSuspend(_ windowsPath: String) -> Bool?' in prefs and 'setRealSuspend(_ on: Bool?' in prefs,
      'LibraryPrefs keeps Automatic (nil), On and Off')
check('BCDLaunch.realSuspend(profile)' in view and 'unsetenv("MADEIRA_REAL_SUSPEND")' in view,
      'the launch sets the variable from the choice and unsets it otherwise')
check('LibraryPrefs.setRealSuspend(' in lib and '"Pause threads fully"' in lib, 'Game details has the picker')
m = re.search(r'int ios_real_suspend_enabled\(void\)\n\{(.*?)\n\}', server, re.S)
body = m.group(1) if m else ''
check('getenv( "MADEIRA_REAL_SUSPEND" )' in body and 'static int env' not in body,
      'wineserver reads the variable on every call')

def block(source, header):
    start = source.index(header)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


swift = '''import Foundation
let suite = "madeira.test." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
struct LibraryEntry {
    var windowsPath: String
    var launchWindowsPath: String { windowsPath }
    var desktop: Bool? = nil
    static func hostURL(ofWindowsPath path: String) -> URL? { URL(fileURLWithPath: path) }
}
enum MadeiraConfig {
    static var setting: String? = nil
    static func get(_ key: String) -> String? { setting }
}
'''
swift += block(prefs, 'enum LibraryPrefs {').replace('UserDefaults.standard', 'defaults')
swift += '\nenum BCDLaunch {\n' + block(bcd, '    static func realSuspend(')
swift += '\n' + block(bcd, '    static func isUnityIL2CPP(') + '\n}\n'
swift += r'''
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let assembly = directory.appendingPathComponent("GameAssembly.dll")
let game = LibraryEntry(windowsPath: directory.appendingPathComponent("game.exe").path)
let folder = LibraryEntry(windowsPath: directory.path)
let desktop = LibraryEntry(windowsPath: directory.path, desktop: true)
precondition(BCDLaunch.realSuspend(game) == nil)
try Data().write(to: assembly)
precondition(BCDLaunch.realSuspend(game)?.value == "1" && BCDLaunch.realSuspend(folder)?.value == "1")
precondition(BCDLaunch.realSuspend(desktop) == nil && BCDLaunch.realSuspend(nil) == nil)
MadeiraConfig.setting = " 0\n"
precondition(BCDLaunch.realSuspend(game)?.value == "0")
LibraryPrefs.setRealSuspend(true, for: game.windowsPath)
precondition(BCDLaunch.realSuspend(game)?.value == "1")
LibraryPrefs.setRealSuspend(false, for: game.windowsPath)
precondition(BCDLaunch.realSuspend(game)?.value == "0")
LibraryPrefs.setRealSuspend(nil, for: game.windowsPath)
MadeiraConfig.setting = " \n"
precondition(BCDLaunch.realSuspend(game)?.value == "1")
try FileManager.default.removeItem(at: assembly)
precondition(BCDLaunch.realSuspend(game) == nil)
print("PASS actual suspension precedence, per-game storage and IL2CPP folder detection")
'''
native = '#include <stdlib.h>\n#include <stdio.h>\n#include <assert.h>\n'
native += block(server, 'int ios_real_suspend_enabled(void)')
native += '''
int main(void) {
    unsetenv("MADEIRA_REAL_SUSPEND"); assert(!ios_real_suspend_enabled());
    setenv("MADEIRA_REAL_SUSPEND", "1", 1); assert(ios_real_suspend_enabled());
    setenv("MADEIRA_REAL_SUSPEND", "0", 1); assert(!ios_real_suspend_enabled());
    setenv("MADEIRA_REAL_SUSPEND", "1", 1); assert(ios_real_suspend_enabled());
    unsetenv("MADEIRA_REAL_SUSPEND"); assert(!ios_real_suspend_enabled());
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-real-suspend-') as directory:
    directory = Path(directory)
    (directory / 'main.swift').write_text(swift)
    subprocess.run(['swiftc', str(directory / 'main.swift'), '-o', str(directory / 'swift')], check=True)
    subprocess.run([str(directory / 'swift'), str(directory)], check=True)
    (directory / 'main.c').write_text(native)
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                    str(directory / 'main.c'), '-o', str(directory / 'native')], check=True)
    subprocess.run([str(directory / 'native')], check=True)

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
