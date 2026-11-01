#!/usr/bin/env python3
"""Compile actual native-client launch preparation with real VDF parsing on macOS."""
from pathlib import Path
import subprocess,tempfile,os
root=Path(__file__).resolve().parents[2]
s=(root/'app/Madeira/SteamRuntime.swift').read_text();helper=s[s.index('enum NativeSteamPlay {'):]
assert '-applaunch \\(game.id)' in helper and 'clientArguments' in helper
assert all(x not in helper for x in ['removeItem','refreshToken','credentialsForDock','writeHandoff','DockStartProgram.apply'])
content=(root/'app/Madeira/ContentView.swift').read_text();a=content.index('entry.steamStart == NativeSteamPlay.mode');b=content.index('if let appID = entry.steamAppID, !entry.startsSteamGameDirectly',a)
assert 'launch.steamAppID = nil' in content[a:b] and 'NativeSteamPlay.prepare' in content[a:b]
assert 'startDock(' not in content[a:b] and 'SteamSignIn' not in content[a:b]
if os.uname().sysname!='Darwin':
 print('PASS native launch source scope; Swift execution runs in macOS Actions');raise SystemExit(0)
dock=(root/'app/Madeira/MadeiraDock.swift').read_text()
def fn(marker):
 a=dock.index(marker);i=dock.index('{',a)+1;depth=1
 while depth:depth+=(dock[i]=='{')-(dock[i]=='}');i+=1
 return dock[a:i]
game=dock[dock.index('struct DockGame:'):dock.index('\n/// Madeira Dock:')]
code='import Foundation\n'+game+'\nenum DockError:Error{case message(String)}\nenum MadeiraDock{\n'+ '\n'.join(fn(x) for x in ['static func validAppID(', 'static func validFolderName(', 'static func game(manifest', 'static func libraryRelative('])+'\n}\n'+helper+r'''
@main struct Check {
 static func main() throws {
  let fm=FileManager.default,drive=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? fm.removeItem(at:drive)}
  let root=drive.appendingPathComponent("Program Files (x86)/Steam")
  let apps=root.appendingPathComponent("steamapps"),folder=apps.appendingPathComponent("common/Counter-Strike Global Offensive")
  try fm.createDirectory(at:folder.appendingPathComponent("game/bin/win64"),withIntermediateDirectories:true)
  try Data("game-fixture".utf8).write(to:folder.appendingPathComponent("game/bin/win64/cs2.exe"))
  let exe=root.appendingPathComponent("steam.exe"),login=root.appendingPathComponent("loginusers.vdf"),manifest=apps.appendingPathComponent("appmanifest_730.acf")
  try Data("genuine-fixture".utf8).write(to:exe);try Data("auth-fixture-must-stay".utf8).write(to:login)
  let data=Data(#"""
  "AppState" {"appid" "730" "StateFlags" "4" "installdir" "Counter-Strike Global Offensive"}
  """#.utf8);try data.write(to:manifest)
  let game=MadeiraDock.game(manifest:data,library:"Program Files (x86)/Steam/steamapps")!
  let other=DockGame(id:730,name:"CS2",installDir:game.installDir,library:"Other/steamapps",installed:true,customExecutables:false)
  assert(!NativeSteamPlay.libraryListed(other,root:"Program Files (x86)/Steam",drive:drive))
  let vdf=Data(#"""
  "libraryfolders" {"1" {"path" "C:\\Other"}}
  """#.utf8)
  try vdf.write(to:apps.appendingPathComponent("libraryfolders.vdf"))
  assert(NativeSteamPlay.libraryListed(other,root:"Program Files (x86)/Steam",drive:drive))
  let script=try NativeSteamPlay.prepare(game,drive:drive)
  let body=try String(contentsOf:drive.appendingPathComponent(script),encoding:.utf8)
  assert(body.contains("steam.exe\" \(NativeSteamPlay.clientArguments) -applaunch 730"))
  assert(try Data(contentsOf:manifest)==data);assert(try String(contentsOf:login,encoding:.utf8)=="auth-fixture-must-stay")
  try fm.removeItem(at:folder.appendingPathComponent("game/bin/win64/cs2.exe"))
  do {_=try NativeSteamPlay.prepare(game,drive:drive);assertionFailure("missing CS2 image must reject")}catch{}
  try Data("game-fixture".utf8).write(to:folder.appendingPathComponent("game/bin/win64/cs2.exe"))
  try fm.removeItem(at:manifest)
  do {_=try NativeSteamPlay.prepare(game,drive:drive);assertionFailure("missing manifest must reject")}catch{}
  try data.write(to:manifest);try fm.removeItem(at:folder)
  do {_=try NativeSteamPlay.prepare(game,drive:drive);assertionFailure("missing install directory must reject")}catch{}
  print("PASS actual native Steam launch: real appmanifest parser, numeric AppID, service prerequisite, unchanged client flags plus normal applaunch; installed/auth files unchanged and missing data rejected")
 }
}
'''
# Throwing expressions cannot be passed directly to assert's nonthrowing autoclosure.
code=code.replace('assert(try Data(contentsOf:manifest)==data);assert(try String(contentsOf:login,encoding:.utf8)=="auth-fixture-must-stay")','let unchanged=try Data(contentsOf:manifest);let auth=try String(contentsOf:login,encoding:.utf8);assert(unchanged==data);assert(auth=="auth-fixture-must-stay")')
with tempfile.TemporaryDirectory() as t:
 p=Path(t)/'check.swift';p.write_text(code);exe=Path(t)/'check'
 subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(root/'app/Madeira/SteamKeyValues.swift'),str(p),'-o',str(exe)],check=True);subprocess.run([str(exe)],check=True)
