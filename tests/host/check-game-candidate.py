#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Add a game (app/Madeira/GameCandidate.swift, AddGame.swift).

Source checks: one sheet replaces the old browser as the Add a game entry, the external-drive
scan shares GameCandidate's skip list, both files are in the project. The Swift fixture compiles
the real GameCandidate.swift and checks the ranking (folder-name match beats size, installers and
helpers last), the installer test, titles and folder slugs. Hosts without Swift run the source
checks; --require-swift fails instead.
"""
from pathlib import Path
import argparse, os, shutil, subprocess, tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
cand = (app / 'GameCandidate.swift').read_text()
pe = (app / 'PEResources.swift').read_text()
add = (app / 'AddGame.swift').read_text()
library = (app / 'Library.swift').read_text()
drives = (app / 'ExternalDrives.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
failures = 0


def check(ok, label):
    global failures
    print(('PASS: ' if ok else 'FAIL: ') + label)
    failures += 0 if ok else 1


check('AddGameSheet { entry in' in library, 'the Add a game sheet opens AddGameSheet')
check('ExecutableBrowser(folder: LibraryModel.drive' in add, 'the old browser stays as the last row')
check('GameCandidate.isSkipped(name)' in drives and 'private static let skipNames' not in drives,
      'the external scan uses the shared skip list')
check('entry(running: url)' in add, 'adding a program that already has an entry opens that entry')
check('createDirectory' in add and 'removeItem(at: dest)' in add, 'an import that fails leaves no half folder')
check('GameMetadata.apply(entry)' in library and 'model.entries.contains { $0.id == entry.id } ? entry' in library,
      'a new entry takes its program\'s name and icon; one already in the library is left alone')
check('Button("Change executable")' in library and 'ExecutableBrowser(folder:' in library, 'the game page can change the executable')
check('LaunchFlagChips(arguments: $entry.arguments, graphicsAPI: entry.graphicsAPI)' in library
      and 'static func flags(for api: String?)' in library, 'launch flag chips follow the detected graphics API')
check('InstallerWatch.begin(entry.id)' in add and 'InstallerWatch.reconcile()' in library, 'a setup program can be run as an installer and is watched')
for name in ('GameCandidate.swift', 'AddGame.swift', 'PEResources.swift', 'InstallerWatch.swift'):
    check(project.count(name) >= 4, name + ' is in the project')

PE_BUILDER = r'''
import struct


def build_pe(path):
    """A minimal PE32+ whose .rsrc holds an icon (a 1x1 PNG), its group and a version string."""
    import zlib
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    pixels = b''.join(b'\0' + b'\xff\x66\x00\xff' * 64 for _ in range(64))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')
    grp = struct.pack('<HHH', 0, 1, 1) + struct.pack('<BBBBHHIH', 64, 64, 0, 0, 1, 32, len(png), 1)
    key = lambda k: (k + '\0').encode('utf-16-le')
    ver = b'\0' * 8 + key('StringFileInfo')
    while len(ver) % 4: ver += b'\0'
    ver += key('ProductName')
    while len(ver) % 4: ver += b'\0'
    ver += ('Cool Game\0').encode('utf-16-le')
    sec_va, raw_at = 0x1000, 0x400
    blobs = [png, grp, ver]
    # directories: root(3 entries) 40, three type dirs, three language dirs, three data entries
    root, tdir, ldir, dent = 0, 40, 112, 184
    blob_at = 232
    rs = bytearray(blob_at)
    def dirhdr(at, n): rs[at:at + 16] = struct.pack('<IIHHHH', 0, 0, 0, 0, 0, n)
    dirhdr(root, 3)
    types = [3, 14, 16]
    offs, o = [], blob_at
    for b in blobs:
        offs.append(o); o += (len(b) + 3) & ~3
    for i, t in enumerate(types):
        rs[root + 16 + i * 8:root + 24 + i * 8] = struct.pack('<II', t, 0x80000000 | (tdir + i * 24))
        dirhdr(tdir + i * 24, 1)
        rs[tdir + i * 24 + 16:tdir + i * 24 + 24] = struct.pack('<II', 1, 0x80000000 | (ldir + i * 24))
        dirhdr(ldir + i * 24, 1)
        rs[ldir + i * 24 + 16:ldir + i * 24 + 24] = struct.pack('<II', 0x409, dent + i * 16)
        rs[dent + i * 16:dent + i * 16 + 16] = struct.pack('<IIII', sec_va + offs[i], len(blobs[i]), 0, 0)
    for b in blobs:
        rs += b + b'\0' * (((len(b) + 3) & ~3) - len(b))
    raw = bytes(rs) + b'\0' * (-len(rs) % 0x200)
    dos = bytearray(64); dos[0:2] = b'MZ'; dos[60:64] = struct.pack('<I', 64)
    opt = bytearray(240); opt[0:2] = struct.pack('<H', 0x20b)
    opt[112 + 16:112 + 24] = struct.pack('<II', sec_va, len(rs))  # data directory 2: resources
    coff = struct.pack('<HHIIIHH', 0x8664, 1, 0, 0, 0, 240, 0x22)
    sec = b'.rsrc\0\0\0' + struct.pack('<IIIIIIHHI', len(rs), sec_va, len(raw), raw_at, 0, 0, 0, 0, 0x40000040)
    head = bytes(dos) + b'PE\0\0' + coff + bytes(opt) + sec
    open(path, 'wb').write(head + b'\0' * (raw_at - len(head)) + raw)
'''
exec(PE_BUILDER)

main = r'''
import Foundation
var bad = 0
func expect(_ c: Bool, _ l: String) { if !c { print("FAIL:", l); bad += 1 } }
let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent("gc-" + UUID().uuidString)
let game = dir.appendingPathComponent("Cool_Game")
try fm.createDirectory(at: game.appendingPathComponent("bin"), withIntermediateDirectories: true)
func put(_ p: String, _ n: Int) { fm.createFile(atPath: game.appendingPathComponent(p).path, contents: Data(count: n)) }
put("setup.exe", 90_000_000); put("CoolGame.exe", 2_000_000); put("bin/Helper.exe", 50_000_000); put("bin/other.exe", 5_000_000)
let found = GameCandidate.programs(in: game)
expect(found.count == 4, "finds four programs")
let order = GameCandidate.ranked(found, in: game).map { $0.lastPathComponent }
expect(order.first == "CoolGame.exe", "folder-name match first: \(order)")
expect(order.last == "setup.exe" || order.last == "Helper.exe", "installer or helper last: \(order)")
expect(GameCandidate.isInstaller("Setup_x64.exe") && GameCandidate.isInstaller("unins000.exe"), "installers")
expect(!GameCandidate.isInstaller("CoolGame.exe") && !GameCandidate.isInstaller("helper.exe"), "game and helper are not installers")
expect(GameCandidate.isSkipped("vc_redist.x64.exe") && !GameCandidate.isSkipped("game.exe"), "skip list")
expect(GameCandidate.title("Cool_Game") == "Cool Game" && GameCandidate.title("a_b.exe") == "a b", "title")
expect(GameCandidate.slug("a/b:c*") == "a b c" && GameCandidate.slug("..") == "Game" && GameCandidate.slug("").count == 4, "slug")
// The PE reader on a PE built by the check.
let resources = PEResources(url: URL(fileURLWithPath: CommandLine.arguments[1]))
expect(resources?.productName == "Cool Game", "product name from the version resource: \(String(describing: resources?.productName))")
if let ico = resources?.icon {
    expect(ico.count > 22 && ico[2] == 1 && ico[4] == 1, "icon comes as a one-image .ico")
    expect(ico.suffix(8).count == 8 && ico.contains(0x89), "the icon's own bytes follow the header")
} else { expect(false, "icon") }
expect(PEResources(url: URL(fileURLWithPath: CommandLine.arguments[2])) == nil, "a file that is not a PE has no resources")
try? fm.removeItem(at: dir)
exit(bad == 0 ? 0 : 1)
'''
compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
if compiler:
    with tempfile.TemporaryDirectory(prefix='madeira-gc-') as d:
        t = Path(d)
        (t / 'GameCandidate.swift').write_text(cand)
        (t / 'PEResources.swift').write_text(pe)
        (t / 'main.swift').write_text(main)
        build_pe(t / 'cool.exe')
        (t / 'text.exe').write_text('not a program')
        subprocess.run([compiler, str(t / 'GameCandidate.swift'), str(t / 'PEResources.swift'), str(t / 'main.swift'), '-o', str(t / 'gc')], check=True)
        check(subprocess.run([str(t / 'gc'), str(t / 'cool.exe'), str(t / 'text.exe')]).returncode == 0, 'Swift fixture')
elif args.require_swift:
    check(False, 'swiftc is required')
else:
    print('SKIP: no swiftc, source checks only')
raise SystemExit(1 if failures else 0)
