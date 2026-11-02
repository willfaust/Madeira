#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml2320, from a tester's log of 2026-10-31: the Epic copy of a game started a publisher's launcher that
looked for the Epic client's process, did not find it ("Failed to relaunch from third party platform") and
showed the game's store page as if it were not owned. On Windows the Epic client starts every game.

- build/epic-parent: EpicGamesLauncher.exe, an x86-64 GUI program that starts the rest of its command line,
  waits for it and returns its exit code; installed in the arm64ec-windows farm (C:\\windows\\system32);
- app/Madeira/Library.swift: an Epic entry's x64 program starts as its child, in the Wine desktop or directly,
  unless env.MADEIRA_EPIC_LAUNCHER_PARENT = 0; a batch or a 32-bit program starts as before.

Static anchors, and the bundled program's PE header.
"""
import struct, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(src, name, stop='\n    }\n'):
    i = src.index(name)
    return src[i:src.index(stop, i)]

c = (ROOT / 'build/epic-parent/epic_parent.c').read_text(encoding='utf-8')
check('CreateProcessW( NULL, line, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process )' in c,
      'the rest of the command line starts as it is, in this working folder and environment')
check('WaitForSingleObject( process.hProcess, INFINITE );' in c and 'GetExitCodeProcess( process.hProcess, &code );' in c,
      'it waits for the program and returns its exit code')
build = (ROOT / 'build/epic-parent/build.sh').read_text(encoding='utf-8')
check('-municode -mwindows' in build and 'x86_64-w64-mingw32-clang' in build, 'built as an x86-64 GUI program (no console)')

exe = ROOT / 'app/Madeira/arm64ec-windows/EpicGamesLauncher.exe'
if exe.exists():
    data = exe.read_bytes()
    pe = struct.unpack_from('<I', data, 60)[0]
    machine = struct.unpack_from('<H', data, pe + 4)[0]
    subsystem = struct.unpack_from('<H', data, pe + 24 + 68)[0]
    check(data[pe:pe + 4] == b'PE\0\0' and machine == 0x8664 and subsystem == 2,
          'the bundled EpicGamesLauncher.exe is an x86-64 GUI program')
else:
    check(False, 'app/Madeira/arm64ec-windows/EpicGamesLauncher.exe is bundled')

lib = (ROOT / 'app/Madeira/Library.swift').read_text(encoding='utf-8')
parent = body(lib, 'var epicParent: String? {')
check('epicAppName != nil, !isBatch, servicesScript == nil' in parent, 'only an Epic entry\'s program, never a batch')
check('MadeiraConfig.get("env.MADEIRA_EPIC_LAUNCHER_PARENT") != "0"' in parent, 'env.MADEIRA_EPIC_LAUNCHER_PARENT=0 starts it directly')
check('Self.peMachine(url) == 0x8664' in parent, 'only an x64 program (a 32-bit one keeps its own session)')
check('return "C:\\\\windows\\\\system32\\\\EpicGamesLauncher.exe"' in parent, 'the farm\'s program')
cmd = body(lib, 'private func launchCommand(parent: String?)')
check('let parent = batch ? nil : parent' in cmd, 'a batch never starts under it')
check('parent.map { quoted($0) + " " + quoted(path) } ?? quoted(path)' in cmd, 'Wine desktop: explorer starts "<parent>" "<program>" args')
check('if let parent { return (parent, withExtra(quoted(path))) }' in cmd, 'direct: the parent is the first program, the game its argument')
check('private var launchCommand: (exe: String, args: String) { launchCommand(parent: nil) }' in lib,
      'the details page\'s command and the length check read no file')
conf = body(lib, 'func configureLaunch() {')
check('let parent = desktop == true ? nil : epicParent' in conf and 'launchCommand(parent: parent)' in conf,
      'decided once per launch, never for the Desktop entry')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    check('key: "env.MADEIRA_EPIC_LAUNCHER_PARENT"' in catalog.read_text(encoding='utf-8'),
          'the config catalog documents env.MADEIRA_EPIC_LAUNCHER_PARENT')

print(f'check-epic-parent: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
