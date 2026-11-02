#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Two depots listing one file: only the later depot writes it. No network.

Valve's client keeps the copy from the depot mounted later. Compiles the
production DepotDownloader.prepare() and overlapKey() with small stubs and
checks, in a temporary install folder:
  - a path listed by depots A and B (any case, either slash) is skipped by A
    (empty path, no pending chunks) and kept by B;
  - files only one depot lists, and directories, are untouched (a directory's
    path entry is empty by design: it has no chunks);
  - one depot alone is unchanged.
Needs swiftc (SWIFTC=wrapper, see the host-tests notes) and python3.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/SwiftSteam/Content/DepotDownloader.swift').read_text()
install = (root / 'app/Madeira/SteamInstall.swift').read_text()


def block(text, signature):
    start = text.index(signature)
    brace = text.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


parts = '\n'.join(block(source, s) for s in (
    'struct DepotPlan:', 'struct WorkItem:', 'struct Prepared:',
    'private nonisolated static func prepare(', 'private nonisolated static func overlapKey(',
    'private nonisolated static func sizeFile('))
journal = block(source, 'final class JournalWriter')
safe = block(install, 'nonisolated static func safeRelativePath(')

code = r'''
import Foundation
#if canImport(Glibc)
import Glibc
#endif
enum SteamError: Error { case chunkDownloadFailed(String) }
enum SteamLog { static func trace(_ t: String) {}; static func event(_ t: String) { print(t) } }
final class ContentHostHealth: @unchecked Sendable {}
struct DepotManifest: Sendable {
    struct ChunkEntry: Sendable { let sha: Data; let crc: UInt32; let offset: UInt64; let compressedSize: UInt32; let uncompressedSize: UInt32 }
    struct FileEntry: Sendable {
        let filename: String; let size: UInt64; let flags: UInt32; var chunks: [ChunkEntry]
        var isDirectory: Bool { flags & 0x40 != 0 }
    }
    var files: [FileEntry]
}
enum SteamInstallFiles {
''' + safe + r'''
}
''' + journal + r'''
final class DepotDownloader {
''' + parts + r'''
    static func run() -> Int32 {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("overlap-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let game = dir.appendingPathComponent("game"), jdir = dir.appendingPathComponent("j")
        try! FileManager.default.createDirectory(at: jdir, withIntermediateDirectories: true)
        func chunk() -> DepotManifest.ChunkEntry { .init(sha: Data(count: 20), crc: 0, offset: 0, compressedSize: 8, uncompressedSize: 16) }
        func file(_ n: String, dir: Bool = false) -> DepotManifest.FileEntry { .init(filename: n, size: dir ? 0 : 16, flags: dir ? 0x40 : 0, chunks: dir ? [] : [chunk()]) }
        func plan(_ id: UInt32, _ files: [DepotManifest.FileEntry]) -> DepotPlan {
            DepotPlan(depotID: id, manifestGID: UInt64(id), key: Data(), manifest: .init(files: files), hosts: [], auth: [:],
                      declaredSize: 0, health: ContentHostHealth())
        }
        let a = plan(1, [file("Binaries", dir: true), file("Binaries\\Win32\\Game.exe"), file("WillowGame/CookedPCConsole/a.upk"), file("only-a.txt")])
        let b = plan(2, [file("binaries/win32/game.EXE"), file("WillowGame\\CookedPCConsole\\A.upk"), file("only-b.txt")])
        let p = try! prepare(plans: [a, b], installURL: game, journalDir: jdir)
        var fails = 0
        func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); fails += 1 } }
        check(p.paths[0][1] == "" && p.paths[0][2] == "", "depot A still writes the shared files: \(p.paths[0])")
        check(!p.paths[0][3].isEmpty, "depot A lost its own file: \(p.paths[0])")
        var isDir: ObjCBool = false
        check(FileManager.default.fileExists(atPath: game.appendingPathComponent("Binaries").path, isDirectory: &isDir) && isDir.boolValue, "depot A's folder was not made")
        check(p.paths[1].allSatisfy { !$0.isEmpty }, "depot B lost a file: \(p.paths[1])")
        check(Set(p.pending[0].map(\.file)) == [3], "depot A pending chunks: \(p.pending[0].map(\.file))")
        check(Set(p.pending[1].map(\.file)) == [0, 1, 2], "depot B pending chunks: \(p.pending[1].map(\.file))")
        let solo = try! prepare(plans: [a], installURL: game, journalDir: jdir)
        check(solo.paths[0].dropFirst().allSatisfy { !$0.isEmpty }, "a lone depot skipped files: \(solo.paths[0])")
        return fails == 0 ? 0 : 1
    }
}
exit(DepotDownloader.run())
'''

with tempfile.TemporaryDirectory(prefix='madeira-depot-overlap-', dir='/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(code)
    swiftc = os.environ.get('SWIFTC', 'swiftc').split()
    r = subprocess.run(swiftc + [str(folder / 'main.swift'), '-o', str(folder / 'check')], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    r = subprocess.run([str(folder / 'check')], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert '[steam-depot] overlap files=2' in r.stdout, r.stdout
print('PASS: a file two depots list is written only by the later depot (any case, either slash); other files untouched')
