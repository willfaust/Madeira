#!/usr/bin/env python3
"""Run production external-storage guards against temporary files; no drive or Steam account needed."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile

app = Path(__file__).resolve().parents[2] / 'app/Madeira'
swiftc = os.environ.get('SWIFTC') or shutil.which('swiftc')
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text()
for object_id in ['A1000921', 'A2000921']:
    assert len(re.findall(r'^\s*' + object_id + r' /\*.*?\*/ = ', project, re.M)) == 1, 'one Xcode definition for ' + object_id
assert 'path = "ExternalStorage.swift";' in project
main = r'''
import Foundation

var failures = 0
func check(_ ok: Bool, _ label: String) {
    print((ok ? "PASS: " : "FAIL: ") + label)
    if !ok { failures += 1 }
}
func rejects(_ label: String, _ body: () throws -> Void) {
    do { try body(); check(false, label) } catch { check(true, label) }
}
let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }
let root = tmp.appendingPathComponent("ssd")
let other = tmp.appendingPathComponent("other")
let registration = ExternalFolder(name: "SSD", letter: "e", bookmark: Data([1]))
try RegistrationFixture.validate([registration])
var second = ExternalFolder(name: "Other", letter: "f", bookmark: Data([2]))
try RegistrationFixture.validate([registration, second])
check(true, "valid legacy registrations remain readable without a marker")
second.name = "ssd"
rejects("duplicate folder names are rejected") { try RegistrationFixture.validate([registration, second]) }
second.name = "Other"; second.letter = "e"
rejects("duplicate drive letters are rejected") { try RegistrationFixture.validate([registration, second]) }
second.letter = "c"
rejects("the internal drive letter cannot be registered") { try RegistrationFixture.validate([second]) }
second.letter = "f"; second.name = "../outside"
rejects("a registration name cannot escape its mapping") { try RegistrationFixture.validate([second]) }
second.name = "Other"; second.libraryID = "bad-id"
rejects("a malformed folder identity is rejected") { try RegistrationFixture.validate([second]) }
second.libraryID = nil; second.bookmark = Data()
rejects("an empty bookmark is rejected") { try RegistrationFixture.validate([second]) }
try fm.createDirectory(at: root, withIntermediateDirectories: true)
try fm.createDirectory(at: other, withIntermediateDirectories: true)
let link = tmp.appendingPathComponent("e:")
try fm.createDirectory(at: link, withIntermediateDirectories: true)
let keep = link.appendingPathComponent("keep.txt")
try Data("keep".utf8).write(to: keep)
rejects("a real mapping directory is kept") { try ExternalStorageMapping.replace(link, root: root, owned: true) }
check(fm.fileExists(atPath: keep.path), "mapping collision preserves directory contents")
try fm.removeItem(at: link)
try Data("keep".utf8).write(to: link)
rejects("a real mapping file is kept") { try ExternalStorageMapping.replace(link, root: root, owned: true) }
check(try String(contentsOf: link, encoding: .utf8) == "keep", "mapping collision preserves file bytes")
try fm.removeItem(at: link)
try fm.createSymbolicLink(at: link, withDestinationURL: other)
rejects("new registration cannot replace a foreign link") { try ExternalStorageMapping.replace(link, root: root, owned: false) }
check(try fm.destinationOfSymbolicLink(atPath: link.path) == other.path, "foreign link target is unchanged")
try ExternalStorageMapping.replace(link, root: root, owned: true)
check(try fm.destinationOfSymbolicLink(atPath: link.path) == root.path, "an owned mapping can be refreshed")
try fm.removeItem(at: link)
try fm.createSymbolicLink(at: link, withDestinationURL: tmp.appendingPathComponent("missing"))
rejects("new registration cannot replace a dangling link") { try ExternalStorageMapping.replace(link, root: root, owned: false) }

let id = try ExternalStorageIdentity.register(root: root)
try ExternalStorageIdentity.verify(id, root: root)
check(try ExternalStorageIdentity.register(root: root) == id, "repeat registration keeps the folder identity")
rejects("another identity cannot use the folder") { try ExternalStorageIdentity.verify(UUID().uuidString, root: root) }
let marker = root.appendingPathComponent(ExternalStorageIdentity.marker)
try Data("invalid".utf8).write(to: marker)
rejects("a bad marker is not overwritten") { _ = try ExternalStorageIdentity.register(root: root) }
check(try String(contentsOf: marker, encoding: .utf8) == "invalid", "bad marker bytes are kept")
try fm.removeItem(at: marker)
rejects("a missing marker does not prove the drive identity") { try ExternalStorageIdentity.verify(id, root: root) }
try fm.createSymbolicLink(at: marker, withDestinationURL: other.appendingPathComponent("missing"))
rejects("a dangling marker is rejected") { _ = try ExternalStorageIdentity.register(root: root) }

for path in ["../outside", "/absolute", "a/../../outside", "a//b", "C:/other", "a/./b", "a\u{0}b"] {
    rejects("unsafe path rejected: \(path.debugDescription)") { _ = try ExternalStoragePath.native(path, root: root) }
}
try fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: other)
rejects("a nested link cannot reach an outside file") { _ = try ExternalStoragePath.native("escape/new/save.dat", root: root) }
try fm.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: other.appendingPathComponent("missing"))
rejects("a dangling ancestor cannot create an outside file") { _ = try ExternalStoragePath.native("dangling/new/save.dat", root: root) }
check(try ExternalStoragePath.native("SteamLibrary/steamapps", root: root).path == root.appendingPathComponent("SteamLibrary/steamapps").path,
      "a normal missing destination can be created")

let old = Data(#"""
"LibraryFolders" {
    "TimeNextStatsReport" "123"
    "0" { "path" "C:\\Steam" "label" "A \"quoted\" label" "apps" { "9000" "42" } }
    "2" "D:\\OldLibrary"
}
"OtherMetadata" "keep"
"""#.utf8)
let paths = ["External/SSD/SteamLibrary", "external/ssd/steamlibrary"]
let updated = try ExternalSteamLibraries.add(paths: paths, to: old)
var parser = try SteamKeyValues(updated)
let value = try parser.read()
let folders = value["libraryfolders"]!
check(folders.fields.count == 4, "one external library is added, without a case duplicate")
check(folders["0"]?["apps"]?["9000"]?.string == "42" && folders["0"]?["label"]?.string == "A \"quoted\" label",
      "library update keeps app data and escaped labels")
check(folders["2"]?.string == "D:\\OldLibrary" && value["othermetadata"]?.string == "keep",
      "legacy paths and unrelated metadata are kept")
check(try ExternalSteamLibraries.add(paths: paths, to: updated) == updated, "repeat updates do not duplicate paths")
// A leftover entry for the top of a drive (C:\External\steam) sits above the drive's real
// library (C:\External\steam\SteamLibrary): it is replaced, other entries stay (code 41 fix).
let leftover = Data(#"""
"libraryfolders" {
    "0" { "path" "C:\\Program Files (x86)\\Steam" "apps" { "228980" "1" } }
    "1" { "path" "C:\\External\\steam" "contentid" "18" "apps" { } }
    "2" { "path" "C:\\External\\SteamUSB\\SteamLibrary" "apps" { } }
    "3" { "path" "C:\\Games" "apps" { } }
}
"""#.utf8)
let drivePaths = ["Program Files (x86)/Steam", "External/steam/SteamLibrary"]
var pruned = try SteamKeyValues(try ExternalSteamLibraries.add(paths: drivePaths, to: leftover))
let prunedPaths = Set(try pruned.read()["libraryfolders"]!.fields.values.compactMap { $0["path"]?.string?.lowercased() })
check(prunedPaths == ["c:\\program files (x86)\\steam", "c:\\external\\steam\\steamlibrary", "c:\\external\\steamusb\\steamlibrary", "c:\\games"],
      "a leftover drive entry above the library is replaced by the library")
var kept = try SteamKeyValues(try ExternalSteamLibraries.add(paths: drivePaths, to: leftover, pruneParents: false))
check(try kept.read()["libraryfolders"]!.fields.count == 5, "pruneParents false keeps the leftover entry")
check(ExternalSteamLibraries.staleParents(of: [#"C:\External\steam"#, #"C:\External\steam\SteamLibrary"#],
                                          in: [#"C:\External\steam\"#]).isEmpty,
      "an entry that is itself a library being added stays")
check(ExternalSteamLibraries.staleParents(of: [#"C:\Games\Steam\SteamLibrary"#], in: [#"C:\Games\Steam"#]).isEmpty,
      "entries outside C:\\External are never removed")
check(ExternalSteamLibraries.staleParents(of: [#"C:\External\steam2\SteamLibrary"#], in: [#"C:\External\steam"#]).isEmpty,
      "a sibling folder whose name starts the same is not a parent")
for bad in ["\"libraryfolders\" {", "\"libraryfolders\" \"bad\"", "\"unrelated\" \"x\""] {
    rejects("invalid library metadata is not replaced") { _ = try ExternalSteamLibraries.add(paths: paths, to: Data(bad.utf8)) }
}
check(ExternalInstallTarget.select(existing: "SSD-A", installed: "SSD-B", requested: "SSD-C", fallback: "internal") == "SSD-A",
      "a paused install keeps its first destination")
check(ExternalInstallTarget.select(existing: nil, installed: "SSD-B", requested: "SSD-C", fallback: "internal") == "SSD-B",
      "a repair keeps the installed game's destination")
check(ExternalInstallTarget.select(existing: nil, installed: nil, requested: "SSD-C", fallback: "internal") == "SSD-C",
      "a new install uses the selected destination")
check(ExternalInstallTarget.select(existing: nil, installed: nil, requested: nil, fallback: "offline-SSD") == "offline-SSD",
      "a disconnected default does not fall back to internal storage")

let apps = tmp.appendingPathComponent("steamapps")
try fm.createDirectory(at: apps.appendingPathComponent("common/Game"), withIntermediateDirectories: true)
let manifest = apps.appendingPathComponent("appmanifest_9000.acf")
try Data("record".utf8).write(to: manifest)
try fm.createSymbolicLink(at: apps.appendingPathComponent("downloading"), withDestinationURL: other)
rejects("uninstall refuses a linked journal directory") { try SteamInstallFiles.delete(appID: 9000, folderName: "Game", steamApps: apps) }
check(fm.fileExists(atPath: manifest.path) && fm.fileExists(atPath: apps.appendingPathComponent("common/Game").path),
      "failed uninstall keeps the install record and payload")
try fm.removeItem(at: apps.appendingPathComponent("downloading"))
try SteamInstallFiles.delete(appID: 9000, folderName: "Game", steamApps: apps)
check(!fm.fileExists(atPath: manifest.path) && !fm.fileExists(atPath: apps.appendingPathComponent("common/Game").path),
      "successful uninstall removes payload and record")
rejects("uninstall rejects an unavailable library") { try SteamInstallFiles.delete(appID: 9000, folderName: "Game", steamApps: tmp.appendingPathComponent("offline")) }
rejects("uninstall rejects a folder traversal") { try SteamInstallFiles.delete(appID: 9000, folderName: "../other", steamApps: apps) }
exit(failures == 0 ? 0 : 1)
'''
with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / 'main.swift'
    drives = (app / 'ExternalDrives.swift').read_text()
    folder = drives[drives.index('struct ExternalFolder:'):drives.index('final class ExternalDrives:')]
    start = drives.index('private static func validate(')
    end = drives.index('\n    private func save(', start)
    validate = drives[start:end].replace('private static func', 'static func', 1)
    source.write_text('import Foundation\n' + folder + '\nenum RegistrationFixture {\n' + validate + '\n}\n' + main)
    executable = Path(tmp) / 'check'
    subprocess.run([swiftc, '-swift-version', '5', '-sanitize=address', str(source),
                    *[str(app / name) for name in ['ExternalStorage.swift', 'SteamInstall.swift', 'SteamKeyValues.swift']],
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))
