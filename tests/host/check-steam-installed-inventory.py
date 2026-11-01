#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Read-only install evidence, compiled from the actual scanner/probe on macOS."""
from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
probe = (root / 'app/Madeira/SteamInstalledInventory.swift').read_text()
model = (root / 'app/Madeira/SteamGames.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
assert all(term not in probe for term in ['removeItem', 'createDirectory', 'write(to:', 'setenv(', 'refreshToken', 'credentialsForDock'])
assert 'FileHandle(forReadingFrom:' in probe and 'read(upToCount: (1 << 20) + 1)' in probe
assert 'rememberedCS2' in model and 'inventoryLogLines < limit' in model
assert 'SteamInstalledInventory.swift in Sources' in project
if os.uname().sysname != 'Darwin':
    print('PASS inventory source scope: bounded readonly manifest probes, no installation/auth mutations; Swift fixtures run in macOS CI')
    raise SystemExit(0)

dock = (root / 'app/Madeira/MadeiraDock.swift').read_text()
def function(marker):
    start = dock.index(marker); end = dock.index('{', start) + 1; depth = 1
    while depth:
        depth += (dock[end] == '{') - (dock[end] == '}'); end += 1
    return dock[start:end]

game = dock[dock.index('struct DockGame:'):dock.index('\n/// Madeira Dock:')]
production = 'import Foundation\n' + game + '\nenum MadeiraDock {\n' + '\n'.join(function(x) for x in [
    'static func validAppID(', 'static func validFolderName(', 'static func game(manifest',
    'static func depots(manifest', 'static func games(drive:', 'static func libraryRelative('
]) + '\n}\n'
stubs = '''import Foundation
enum SteamRuntimeFiles {static let relativeRoot="Program Files (x86)/Steam"}
enum ExternalDrives {static var steamLibraries:[String]=[]}
'''
main = r'''
import Foundation
@main struct Check {
 static func main() throws {
  let fm=FileManager.default,drive=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? fm.removeItem(at:drive)}
  let client="Program Files (x86)/Steam",library=client+"/steamapps",apps=drive.appendingPathComponent(library)
  func write(_ path:String,_ text:String) throws {
   let file=drive.appendingPathComponent(path)
   try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
   try Data(text.utf8).write(to:file)
  }
  func manifest(_ id:Int,_ directory:String,_ flags:Int=4,_ extra:String="") -> String {
   #"""
   "AppState" {"appid" "\#(id)" "name" "SECRET_ACCOUNT_NAME" "installdir" "\#(directory)" "StateFlags" "\#(flags)" \#(extra)}
   """#
  }
  let cs2=manifest(730,"PRIVATE_DIRECTORY"),other=manifest(740,"Other")
  try write(client+"/steam.exe","client-fixture")
  try write(library+"/appmanifest_730.acf",cs2);try write(library+"/appmanifest_740.acf",other)
  try write(library+"/common/PRIVATE_DIRECTORY/game/bin/win64/cs2.exe","CS2_FILES_MUST_STAY")
  try write(client+"/config/loginusers.vdf","AUTH_FILES_MUST_STAY")
  var notes:[String]=[]
  let before=MadeiraDock.games(drive:drive,diagnostic:{notes.append($0)})
  assert(before.map(\.id).sorted()==[730,740]);assert(notes.contains{$0.contains("app=730 manifest=accepted ready=true")})
  let initial=SteamInstalledInventory.observe(drive:drive,previous:[],current:before,rememberedCS2:nil)
  assert(initial.lines.contains{$0.contains("app=730 scan-visible=true manifest-now=ready") && $0.contains("expected-program=present") && $0.contains("client-library-listed=true")})
  // Removing another fixture's manifest drops2->1 without losing CS2 or its files.
  try fm.removeItem(at:apps.appendingPathComponent("appmanifest_740.acf"))
  let after=MadeiraDock.games(drive:drive)
  let changed=SteamInstalledInventory.observe(drive:drive,previous:before,current:after,rememberedCS2:before.first{$0.id==730})
  assert(after.map(\.id)==[730]);assert(changed.lines[0].contains("removed=740"))
  assert(changed.lines.contains{$0.contains("app=730 scan-visible=true manifest-now=ready") && $0.contains("expected-program=present")})
  // A transient invalid manifest is diagnosed independently from intact game data.
  try write(library+"/appmanifest_730.acf","invalid")
  notes=[];let missing=MadeiraDock.games(drive:drive,diagnostic:{notes.append($0)})
  assert(missing.isEmpty && notes.contains{$0.contains("app=730 manifest=invalid")})
  let invalid=SteamInstalledInventory.observe(drive:drive,previous:after,current:missing,rememberedCS2:after[0])
  assert(invalid.fingerprint != changed.fingerprint)
  assert(invalid.lines.contains{$0.contains("manifest-now=invalid") && $0.contains("expected-program=present") && $0.contains("recorded-folder-present=true")})
  // Ready state is separate from enumeration count; do not invent readiness.
  try write(library+"/appmanifest_730.acf",manifest(730,"PRIVATE_DIRECTORY",1026))
  let updating=MadeiraDock.games(drive:drive);assert(updating.count==1 && !updating[0].installed)
  let update=SteamInstalledInventory.observe(drive:drive,previous:missing,current:updating,rememberedCS2:after[0])
  assert(update.lines.contains{$0.contains("manifest-now=not-ready")})
  // Exact shared-depot filtering is logged while discovery results stay unchanged.
  try write(library+"/appmanifest_3300.acf",manifest(3300,"Shared",4,#"""
  "InstalledDepots" {"3301" {"manifest" "1"}}
  """#))
  try write(library+"/appmanifest_3302.acf",manifest(3302,"Borrower",4,#"""
  "InstalledDepots" {"3303" {"manifest" "2"}} "SharedDepots" {"3301" "3300"}
  """#))
  notes=[];let filtered=MadeiraDock.games(drive:drive,diagnostic:{notes.append($0)})
  assert(filtered==MadeiraDock.games(drive:drive));assert(!filtered.contains{$0.id==3300})
  assert(notes.contains{$0.contains("app=3300 scan=shared-depot-only-filter")})
  // Diagnostics remain bounded and do not publish account or directory names.
  for id in 4000..<4050 {try write(library+"/appmanifest_\(id).acf","invalid")}
  notes=[];_=MadeiraDock.games(drive:drive,diagnostic:{notes.append($0)});assert(notes.count<=24)
  let output=(initial.lines+changed.lines+invalid.lines+update.lines+notes).joined(separator:"\n")
  assert(!output.contains("SECRET_ACCOUNT_NAME") && !output.contains("PRIVATE_DIRECTORY"))
  // A previously known secondary library can stop being enumerated without
  // deleting any manifest or executable; its path is represented only by a token.
  let secondary="PRIVATE_VOLUME_OWNER/SteamLibrary/steamapps"
  try write(secondary+"/appmanifest_730.acf",cs2)
  try write(secondary+"/common/PRIVATE_DIRECTORY/game/bin/win64/cs2.exe","SECONDARY_CS2_FILES")
  try write(library+"/libraryfolders.vdf",#"""
  "libraryfolders" {"1" {"path" "C:\\PRIVATE_VOLUME_OWNER\\SteamLibrary"}}
  """#)
  try fm.removeItem(at:apps.appendingPathComponent("appmanifest_730.acf"))
  let relocated=MadeiraDock.games(drive:drive),known=relocated.first{$0.id==730}!
  let located=SteamInstalledInventory.observe(drive:drive,previous:[],current:relocated,rememberedCS2:nil)
  assert(located.lines.contains{$0.contains("app=730 scan-visible=true manifest-now=ready") && $0.contains("client-library-listed=true")})
  try fm.removeItem(at:apps.appendingPathComponent("libraryfolders.vdf"))
  let omitted=MadeiraDock.games(drive:drive)
  let hidden=SteamInstalledInventory.observe(drive:drive,previous:relocated,current:omitted,rememberedCS2:known)
  assert(!omitted.contains{$0.id==730})
  assert(hidden.lines.contains{$0.contains("app=730 scan-visible=false manifest-now=ready") && $0.contains("client-library-listed=false") && $0.contains("expected-program=present")})
  assert(!hidden.lines.joined().contains("PRIVATE_VOLUME_OWNER"))
  let auth=try String(contentsOf:drive.appendingPathComponent(client+"/config/loginusers.vdf"),encoding:.utf8)
  let image=try String(contentsOf:apps.appendingPathComponent("common/PRIVATE_DIRECTORY/game/bin/win64/cs2.exe"),encoding:.utf8)
  assert(auth=="AUTH_FILES_MUST_STAY" && image=="CS2_FILES_MUST_STAY")
  print("PASS actual manifest discovery/probe:2->1 delta identifies removed app; CS2 readiness/files, invalid records, shared-depot filters, fingerprints and bounded privacy; game/auth data unchanged")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-installed-inventory-') as folder:
    directory=Path(folder);a=directory/'dock.swift';b=directory/'stubs.swift';c=directory/'main.swift';exe=directory/'check'
    a.write_text(production);b.write_text(stubs);c.write_text(main)
    subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(a),str(b),str(root/'app/Madeira/SteamKeyValues.swift'),str(root/'app/Madeira/SteamInstalledInventory.swift'),str(c),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
