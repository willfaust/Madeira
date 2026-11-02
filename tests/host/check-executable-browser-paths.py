#!/usr/bin/env python3
"""Executable browser: registered external roots stay visible without escaping roots.

Compiles LibraryModel.relativeToDrive from production with temporary internal and
external folders. Requires swift on PATH; does not access real game folders.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
library = (root / 'app/Madeira/Library.swift').read_text()
start = library.index('    static func relativeToDrive(')
brace = library.index('{', start)
depth, end = 1, brace + 1
while depth:
    depth += (library[end] == '{') - (library[end] == '}')
    end += 1
method = library[start:end]

source = r'''
import Foundation
struct ExternalRoot { let name: String; let path: String }
final class ExternalDrives {
    static let shared = ExternalDrives()
    var roots: [ExternalRoot] = []
}
struct LibraryModel {
    static var drive: URL { URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath().standardizedFileURL }
'''+ method + r'''
}
let fm = FileManager.default
let base = LibraryModel.drive.deletingLastPathComponent()
let external = base.appendingPathComponent("ssd", isDirectory: true)
let outside = base.appendingPathComponent("outside", isDirectory: true)
let sibling = base.appendingPathComponent("ssd-other", isDirectory: true)
let internalGame = LibraryModel.drive.appendingPathComponent("Games/Game", isDirectory: true)
for directory in [external, outside, sibling, internalGame, LibraryModel.drive.appendingPathComponent("External")] {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
}
ExternalDrives.shared.roots = [ExternalRoot(name: "SSD", path: external.resolvingSymlinksInPath().standardizedFileURL.path)]
let link = LibraryModel.drive.appendingPathComponent("External/SSD", isDirectory: true)
try fm.createSymbolicLink(at: link, withDestinationURL: external)
let escape = external.appendingPathComponent("escape", isDirectory: true)
try fm.createSymbolicLink(at: escape, withDestinationURL: outside)
let internalEscape = LibraryModel.drive.appendingPathComponent("escape", isDirectory: true)
try fm.createSymbolicLink(at: internalEscape, withDestinationURL: outside)
for file in [external.appendingPathComponent("game.exe"), outside.appendingPathComponent("game.exe"), internalGame.appendingPathComponent("game.exe")] {
    try Data().write(to: file)
}
var failed = 0
func expect(_ condition: Bool, _ label: String) {
    print((condition ? "PASS: " : "FAIL: ") + label)
    if !condition { failed += 1 }
}
expect(LibraryModel.relativeToDrive(external) == "External/SSD", "registered external root maps to its entry")
expect(LibraryModel.relativeToDrive(link) == "External/SSD", "linked external root maps to its entry")
let visible = try fm.contentsOfDirectory(at: LibraryModel.drive.appendingPathComponent("External"), includingPropertiesForKeys: nil)
    .filter { LibraryModel.relativeToDrive($0) != nil }
expect(visible.map(\.lastPathComponent) == ["SSD"], "external drive root survives the browser's path filter")
expect(LibraryModel.relativeToDrive(external.appendingPathComponent("game.exe")) == "External/SSD/game.exe", "external executable maps under its drive")
expect(LibraryModel.relativeToDrive(link.appendingPathComponent("Games/game.exe")) == "External/SSD/Games/game.exe", "linked external descendant maps under its drive")
expect(LibraryModel.relativeToDrive(internalGame) == "Games/Game", "internal directory stays available")
expect(LibraryModel.relativeToDrive(internalGame.appendingPathComponent("game.exe")) == "Games/Game/game.exe", "internal executable stays available")
expect(LibraryModel.relativeToDrive(LibraryModel.drive) == nil, "internal root keeps its existing behavior")
expect(LibraryModel.relativeToDrive(sibling) == nil, "similarly named unregistered root is rejected")
expect(LibraryModel.relativeToDrive(sibling.appendingPathComponent("game.exe")) == nil, "similarly named root's descendant is rejected")
expect(LibraryModel.relativeToDrive(outside) == nil, "unregistered root is rejected")
expect(LibraryModel.relativeToDrive(escape.appendingPathComponent("game.exe")) == nil, "external symlink cannot escape to unregistered storage")
expect(LibraryModel.relativeToDrive(internalEscape.appendingPathComponent("game.exe")) == nil, "internal symlink cannot escape to unregistered storage")
expect(LibraryModel.relativeToDrive(external.appendingPathComponent("../outside/game.exe")) == nil, "parent traversal cannot escape to unregistered storage")
exit(failed == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix='madeira-browser-') as tmp:
    folder = Path(tmp).resolve()
    script = folder / 'browser.swift'
    script.write_text(source)
    subprocess.run(['swift', str(script), str(folder / 'drive_c')], check=True)
print('check-executable-browser-paths: PASS')
