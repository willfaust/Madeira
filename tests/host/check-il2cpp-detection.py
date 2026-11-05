#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Compile the production IL2CPP detector and launch-path mapping on temporary games."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
bcd = (root / 'app/Madeira/LibraryBCD.swift').read_text()
library = (root / 'app/Madeira/Library.swift').read_text()


def block(source, header):
    start = source.index(header)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


swift = '''import Foundation
struct LibraryEntry {
    var relativePath: String
    var steamAppID: Int? = nil
    var steamStart: String? = nil
    var steamProgram: String? = nil
    var epicAppName: String? = nil
    var epicAntiCheatOff: Bool? = nil
    static let epicAntiCheatOffProgram: [String: String] = [:]
    static let hostDrive = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
'''
for header in ['    var windowsPath:', '    var startsSteamGameDirectly:',
               '    var launchRelativePath:', '    var launchWindowsPath:',
               '    static func hostURL(ofWindowsPath']:
    swift += block(library, header) + '\n'
swift += '}\nenum BCDLaunch {\n' + block(bcd, '    static func isUnityIL2CPP(') + '\n}\n'
swift += r'''
let fm = FileManager.default
let drive = LibraryEntry.hostDrive
func create(_ path: String) throws {
    let file = drive.appendingPathComponent(path)
    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: file)
}
for path in ["Nested/bin/game.exe", "Nested/bin/GameAssembly.dll", "Root/game.exe",
             "Root/GameAssembly.dll", "Plain/game.exe", "Other/game.exe", "Other/GameAssembly.dll"] {
    try create(path)
}
try fm.createSymbolicLink(at: drive.appendingPathComponent("Plain/escape"),
                         withDestinationURL: drive.appendingPathComponent("Other"))
var failed = 0
func expect(_ value: Bool, _ label: String) {
    print((value ? "PASS: " : "FAIL: ") + label)
    if !value { failed += 1 }
}
let directSteam = LibraryEntry(relativePath: "Nested", steamAppID: 1, steamStart: "game", steamProgram: "bin/game.exe")
expect(BCDLaunch.isUnityIL2CPP(directSteam), "known nested Steam executable is detected")
expect(BCDLaunch.isUnityIL2CPP(LibraryEntry(relativePath: "Nested/bin/game.exe")), "local nested executable is detected")
expect(BCDLaunch.isUnityIL2CPP(LibraryEntry(relativePath: "Root", steamAppID: 2)), "root-level Steam DLL is still detected")
expect(BCDLaunch.isUnityIL2CPP(LibraryEntry(relativePath: "Root/game.exe")), "local root-level DLL is still detected")
expect(!BCDLaunch.isUnityIL2CPP(LibraryEntry(relativePath: "Plain/game.exe")), "non-IL2CPP game is not detected")
expect(!BCDLaunch.isUnityIL2CPP(LibraryEntry(relativePath: "Plain", steamAppID: 3, steamStart: "game", steamProgram: "../Other/game.exe")), "parent traversal cannot select another game's assembly")
expect(!BCDLaunch.isUnityIL2CPP(LibraryEntry(relativePath: "Plain", steamAppID: 3, steamStart: "game", steamProgram: "escape/game.exe")), "launch symlink cannot select another game's assembly")
expect(!BCDLaunch.isUnityIL2CPP(LibraryEntry(relativePath: "../Other/game.exe")), "invalid entry path is rejected")
expect(!BCDLaunch.isUnityIL2CPP(LibraryEntry(relativePath: "Nested", steamAppID: 1)), "unknown Dock program does not scan arbitrary subdirectories")
expect(!BCDLaunch.isUnityIL2CPP(LibraryEntry(relativePath: "Nested", steamAppID: 1, steamProgram: "bin/game.exe")), "a dormant direct-start choice does not change a Dock launch")
exit(failed == 0 ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix='madeira-il2cpp-detection-') as tmp:
    directory = Path(tmp)
    program = directory / 'detect.swift'
    program.write_text(swift)
    subprocess.run(['swift', str(program), str(directory / 'drive_c')], check=True)
print('check-il2cpp-detection: PASS')
