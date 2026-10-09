#!/usr/bin/env python3
"""Steam Cloud sync decisions (app/Madeira/SteamCloud.swift SteamCloudPlan); no Steam runs. Compiles
the production SteamCloudEntry and SteamCloudPlan and checks what each comparison leads to against
the record of the last sync: one-sided changes are copied, two-sided ones wait for a choice, and a
save synced before that is now missing on this device is a choice whose mark keeps a new save of
that name from going up over the cloud's copy unasked (the reset-prefix case), and runs the
production comparison (SteamCloudPaths, SteamCloudAudit) over a synthetic prefix: a save folder
named with {64BitSteamID} gets a cloud name with the ID filled in, the name the cloud lists for
that file. Source checks: Steam Cloud is on unless turned off, a game not checked yet syncs before
Play, every upload that replaces a cloud file backs up the cloud's copy first, and backups are in
Documents.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


cloud = (app / 'SteamCloud.swift').read_text()
owned = (app / 'SteamOwnedLibrary.swift').read_text()
compare = cloud[cloud.index('// MARK: - Where a cloud path lives in the Wine prefix'):cloud.index('// MARK: - Download')]
plan = cloud[cloud.index('// MARK: - What to do with a comparison'):cloud.index('// MARK: - Upload')]
state = cloud[cloud.index('// MARK: - State the interface shows'):]

# ------------------------------------------------------------------ static
require('SteamSignIn.flag("MADEIRA_STEAM_CLOUD", default: true)' in owned,
        'Steam Cloud is on unless turned off (env.MADEIRA_STEAM_CLOUD = 0)')
require('guard let state = cloud[appID] else { return .stale }' in owned,
        'Play on a game not checked yet in this app run syncs it first, without asking')
upload = owned[owned.index('private func upload(_ appID: Int'):owned.index('// MARK: Before Play')]
require(upload.index('cloudFile(appID, entry)') < upload.index('.cloudBeginAppUploadBatch'),
        "an upload fetches the cloud's copy of every file it replaces before the batch opens")
require('appendingPathComponent("cloud", isDirectory: true)' in upload,
        "the cloud's copies go to the backup's cloud/ folder")
require('urls(for: .documentDirectory' in owned and '"Steam Cloud Backups"' in owned,
        'backups are in Documents (Files › Madeira › Steam Cloud Backups)')
require('$0.kind == .cloudOnly' in owned[owned.index('func resolveCloud'):owned.index('private func download(')],
        "keeping this device's side leaves a missing save missing instead of uploading nothing")

# ------------------------------------------------------------------ Swift
main = r'''
import Foundation
enum SteamAppInfo {
    struct SaveFile: Equatable { var root: String; var path: String; var pattern: String; var recursive: Bool; var platforms: [String] }
    struct RootOverride: Equatable { var root: String; var os: String; var useInstead: String; var addPath: String }
}
struct SteamCloudFile { var prefix: String; var name: String; var sha: Data; var timestamp: UInt64; var size: UInt64; var persistState: UInt32
    var path: String { prefix + name } }
struct SteamCloudListing { var changeNumber: UInt64 = 0; var files: [SteamCloudFile] = [] }

var failed = 0
func check(_ ok: Bool, _ label: String) { print((ok ? "PASS: " : "FAIL: ") + label); if !ok { failed += 1 } }

var reconnected = SteamCloudState()
reconnected.phase = .failed("storage unavailable")
reconnected.checked = Date()
reconnected.problem = "old provider error"
reconnected.conflicts = [SteamCloudEntry(path: "save.dat", kind: .cloudOnly)]
let savedConflicts = reconnected.conflicts
reconnected.retryFailedCheck()
check(reconnected.phase == .ready && reconnected.checked == nil && reconnected.problem == nil,
      "reconnected storage requires a fresh cloud audit instead of retaining its failed check")
check(reconnected.conflicts == savedConflicts, "reconnect preserves unresolved save decisions")
reconnected.phase = .uploading(done: 1, of: 2)
let uploading = reconnected
reconnected.retryFailedCheck()
check(reconnected == uploading, "reconnect does not disturb an active cloud transfer")

func sha(_ byte: UInt8) -> Data { Data(repeating: byte, count: 20) }
func hex(_ byte: UInt8) -> String { SteamCloudPlan.hex(sha(byte)) }
let path = "%WinAppDataLocalLow%Studio/Game/save.dat"
let key = path.lowercased()
func e(_ kind: SteamCloudEntry.Kind, cloud: UInt8? = nil, local: UInt8? = nil) -> SteamCloudEntry {
    var x = SteamCloudEntry(path: path, kind: kind)
    if let cloud { x.cloudSHA = sha(cloud) }
    if let local { x.localSHA = sha(local) }
    return x
}
func plan(_ x: SteamCloudEntry, _ known: String?) -> SteamCloudPlan {
    SteamCloudPlan.make(audit: SteamCloudAudit(entries: [x]), baseline: known.map { [key: $0] } ?? [:])
}
func only(_ p: SteamCloudPlan) -> String {
    p.download.count == 1 && p.upload.isEmpty && p.conflicts.isEmpty ? "download"
    : p.upload.count == 1 && p.download.isEmpty && p.conflicts.isEmpty ? "upload"
    : p.conflicts.count == 1 && p.download.isEmpty && p.upload.isEmpty ? "ask"
    : p.download.isEmpty && p.upload.isEmpty && p.conflicts.isEmpty ? "nothing" : "mixed"
}

// One-sided changes are copied; two-sided ones and no record wait for a choice.
check(only(plan(e(.differ, cloud: 1, local: 2), hex(1))) == "upload", "changed on this device only: uploaded")
check(only(plan(e(.differ, cloud: 2, local: 1), hex(1))) == "download", "changed in the cloud only: downloaded")
check(only(plan(e(.differ, cloud: 2, local: 3), hex(1))) == "ask", "changed on both sides: a choice")
check(only(plan(e(.differ, cloud: 2, local: 3), nil)) == "ask", "different with no record: a choice")
check(only(plan(e(.cloudOnly, cloud: 1), nil)) == "download", "new in the cloud: downloaded")
check(only(plan(e(.localOnly, local: 1), nil)) == "upload", "new on this device: uploaded")
check(only(plan(e(.localOnly, local: 1), hex(1))) == "nothing", "deleted in the cloud: not sent back")
let same = plan(e(.same, cloud: 4, local: 4), SteamCloudPlan.missingMark + hex(1))
check(only(same) == "nothing" && same.settled[key] == hex(4), "identical on both sides: recorded, replacing any mark")

// Synced before, missing on this device now: a choice, and the record is marked.
let lost = plan(e(.cloudOnly, cloud: 1), hex(1))
check(only(lost) == "ask", "synced before and missing here: a choice, not ignored")
check(lost.settled[key] == SteamCloudPlan.missingMark + hex(1), "  and the record is marked missing")
check(only(plan(e(.cloudOnly, cloud: 1), SteamCloudPlan.missingMark + hex(1))) == "ask", "  still a choice while marked")
check(plan(e(.cloudOnly, cloud: 1), SteamCloudPlan.missingMark + hex(1)).settled.isEmpty, "  the mark is not rewritten")

// The reset-prefix case: the device lost the save, the game started fresh and wrote a
// new one, and the cloud still holds the synced progress. Without the mark this was a
// change on this device only, uploaded over the cloud's progress.
check(only(plan(e(.differ, cloud: 1, local: 9), hex(1))) == "upload", "(no mark: a fresh save would go up unasked)")
check(only(plan(e(.differ, cloud: 1, local: 9), SteamCloudPlan.missingMark + hex(1))) == "ask",
      "a save that reappears after it went missing: a choice, never uploaded unasked")
check(only(plan(e(.differ, cloud: 2, local: 9), SteamCloudPlan.missingMark + hex(1))) == "ask", "  also when the cloud moved on")

// The user chose to leave it missing.
let deleted = SteamCloudPlan.deletedMark + hex(1)
check(only(plan(e(.cloudOnly, cloud: 1), deleted)) == "nothing", "left missing by choice: not asked again")
check(only(plan(e(.cloudOnly, cloud: 2), deleted)) == "download", "  the cloud's copy changed since: downloaded (nothing here to lose)")
check(only(plan(e(.differ, cloud: 1, local: 9), deleted)) == "ask", "  a new save of that name later: a choice")

// The production comparison over a prefix laid out like a game that keeps its saves in
// <install>/savedata/<64-bit Steam ID>/ (ufs path "savedata/{64BitSteamID}").
let steamID: UInt64 = 76561198000000001
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cloud-\(getpid())", isDirectory: true)
let drive = tmp.appendingPathComponent("drive_c", isDirectory: true)
let install = drive.appendingPathComponent("steamapps/common/Game", isDirectory: true)
let saves = install.appendingPathComponent("savedata/\(steamID)", isDirectory: true)
try! FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: drive.appendingPathComponent("users/player/AppData", isDirectory: true), withIntermediateDirectories: true)
let bytes = Data("progress".utf8)
try! bytes.write(to: saves.appendingPathComponent("data_0.sav"))
let paths = SteamCloudPaths(drive: drive, userFolder: drive.appendingPathComponent("users/player", isDirectory: true),
                            installFolder: install, remoteFolder: tmp.appendingPathComponent("remote", isDirectory: true),
                            steamID: steamID, overrides: [])
let ufs = [SteamAppInfo.SaveFile(root: "gameinstall", path: "savedata/{64BitSteamID}", pattern: "*", recursive: false, platforms: [])]
let name = "%GameInstall%savedata/\(steamID)/data_0.sav"
let local = try! SteamCloudAudit.run(listing: SteamCloudListing(), saveFiles: ufs, paths: paths)
check(local.entries.count == 1 && local.entries[0].kind == .localOnly, "a device-only save in a {64BitSteamID} folder is found")
check(local.entries.first?.path == name, "  its cloud name has the ID filled in (\(local.entries.first?.path ?? "-"))")
let listed = SteamCloudFile(prefix: "%GameInstall%savedata/\(steamID)/", name: "data_0.sav",
                            sha: SteamCloudAudit.sha1(of: saves.appendingPathComponent("data_0.sav"))!,
                            timestamp: 1, size: UInt64(bytes.count), persistState: 0)
let both = try! SteamCloudAudit.run(listing: SteamCloudListing(files: [listed]), saveFiles: ufs, paths: paths)
check(both.entries.count == 1 && both.entries[0].kind == .same, "  and once the cloud lists it under that name, the two are the same file")
// An external GameInstall folder must not follow a nested link outside its library.
let externalRoot = tmp.appendingPathComponent("external")
let externalInstall = externalRoot.appendingPathComponent("steamapps/common/External Game")
let outside = tmp.appendingPathComponent("outside")
try! FileManager.default.createDirectory(at: externalInstall, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
try! bytes.write(to: outside.appendingPathComponent("save.dat"))
try! FileManager.default.createSymbolicLink(at: externalInstall.appendingPathComponent("saves"), withDestinationURL: outside)
var externalPaths = paths
externalPaths.installFolder = externalInstall
externalPaths.externalLibraryRoot = externalRoot
let externalListed = SteamCloudFile(prefix: "%GameInstall%saves/", name: "save.dat",
                                   sha: SteamCloudAudit.sha1(of: outside.appendingPathComponent("save.dat"))!,
                                   timestamp: 1, size: UInt64(bytes.count), persistState: 0)
do {
    _ = try SteamCloudAudit.run(listing: SteamCloudListing(files: [externalListed]), saveFiles: [], paths: externalPaths)
    check(false, "external cloud: linked ancestor must fail the audit")
} catch { check(true, "external cloud: linked ancestor fails before reading an outside save") }
let externalPattern = [SteamAppInfo.SaveFile(root: "GameInstall", path: "saves", pattern: "*", recursive: true, platforms: [])]
do {
    _ = try SteamCloudAudit.run(listing: SteamCloudListing(), saveFiles: externalPattern, paths: externalPaths)
    check(false, "external cloud: linked local-only save folder must fail the audit")
} catch { check(true, "external cloud: linked local-only save folder fails before enumeration") }
try! FileManager.default.removeItem(at: externalInstall.appendingPathComponent("saves"))
try! FileManager.default.createDirectory(at: externalInstall.appendingPathComponent("Saves"), withIntermediateDirectories: true)
try! bytes.write(to: externalInstall.appendingPathComponent("Saves/save.dat"))
let externalSafe = try! SteamCloudAudit.run(listing: SteamCloudListing(files: [externalListed]), saveFiles: [], paths: externalPaths)
check(externalSafe.entries.count == 1 && externalSafe.entries[0].kind == .same,
      "external cloud: ordinary SSD save uses case-insensitive resolution and compares normally")
try! FileManager.default.createSymbolicLink(at: externalInstall.appendingPathComponent("Saves/linked.dat"), withDestinationURL: outside.appendingPathComponent("save.dat"))
do {
    _ = try SteamCloudAudit.run(listing: SteamCloudListing(), saveFiles: externalPattern, paths: externalPaths)
    check(false, "external cloud: linked file must fail local-only enumeration")
} catch { check(true, "external cloud: linked file fails before being offered for upload") }
try! FileManager.default.createSymbolicLink(at: externalInstall.appendingPathComponent("dangling"), withDestinationURL: outside.appendingPathComponent("missing"))
do {
    _ = try externalPaths.resolve(base: externalInstall, parts: ["dangling", "new.sav"])
    check(false, "external cloud: a download must not create a file through a dangling link")
} catch { check(true, "external cloud: destination validation rejects dangling links") }
try? FileManager.default.removeItem(at: tmp)

exit(failed == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / 'main.swift'
    src.write_text('import Foundation\nimport CryptoKit\n' + compare + '\n' + plan + '\n' + state + '\n' + main.replace('import Foundation\n', '', 1))
    out = Path(tmp) / 'cloud'
    build = subprocess.run([SWIFTC, '-O', str(src), str(app / 'SteamStorage.swift'), '-o', str(out)], capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-3000:])
        require(False, 'the production comparison and SteamCloudPlan compile on the host')
    else:
        run = subprocess.run([str(out)], capture_output=True, text=True)
        print(run.stdout, end='')
        if run.returncode != 0:
            failures += 1

print('\n%s' % ('ALL PASS' if failures == 0 else '%d FAILURE(S)' % failures))
sys.exit(0 if failures == 0 else 1)
