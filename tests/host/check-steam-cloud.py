#!/usr/bin/env python3
"""Steam Cloud sync decisions (app/Madeira/SteamCloud.swift SteamCloudPlan); no Steam runs. Compiles
the production SteamCloudEntry and SteamCloudPlan and checks what each comparison leads to against
the record of the last sync: one-sided changes are copied, two-sided ones wait for a choice, and a
save synced before that is now missing on this device is a choice whose mark keeps a new save of
that name from going up over the cloud's copy unasked (the reset-prefix case), and runs the
production comparison (SteamCloudPaths, SteamCloudAudit) over a synthetic prefix: a save folder
named with {64BitSteamID} gets a cloud name with the ID filled in, the name the cloud lists for
that file. Source checks: Steam Cloud is on unless Settings › Steam turns it off, and off stops every
check, transfer and Play prompt; turning it back on starts clean; a game not checked yet syncs before
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

# ------------------------------------------------------------------ static
require('SteamSignIn.flag("MADEIRA_STEAM_CLOUD", default: true)' in owned,
        'Steam Cloud is on unless turned off (env.MADEIRA_STEAM_CLOUD = 0)')
onboarding = (app / 'Onboarding.swift').read_text()
games = (app / 'SteamGames.swift').read_text()
steam_settings = onboarding[onboarding.index('struct SteamSettingsSection'):onboarding.index('// MARK: - Madeira Dock in the library')]
require('Toggle("Steam Cloud saves", isOn: $cloud.on)' in steam_settings and 'SteamCloudSetting.shared' in steam_settings,
        'Settings › Steam has the Steam Cloud saves switch')
require('MadeiraConfig.set("env.MADEIRA_STEAM_CLOUD", on ? nil : "0")' in games
        and 'SteamOwnedLibrary.shared.cloudTurnedOff()' in games,
        'the switch is kept in madeira.cfg and turning it off reaches the library')
hold = owned[owned.index('func cloudHold('):owned.index('// MARK: Upload and quit')]
require('guard Self.cloudEnabled else { noteCloudOff(); return nil }' in hold
        and 'guard Self.cloudPlayCheck else { return nil }' in hold,
        'off: Play neither waits nor asks')
require('static var cloudQuitEnabled: Bool { cloudEnabled &&' in owned and 'if SteamOwnedLibrary.cloudEnabled {' in games
        and 'if SteamOwnedLibrary.cloudEnabled, !steam.cloudUndecided.isEmpty {' in games,
        "off: the game page's section, the library's note and the upload button are hidden")
require(owned.count('Self.cloudEnabled else { throw CancellationError() }') == 3
        and 'guard Self.cloudEnabled, !cloudBusy.contains(appID)' in owned,
        'off: a running transfer stops between files and no choice is applied')
turned_on = owned[owned.index('func cloudTurnedOn()'):owned.index('func cloudTurnedOff()')]
require('cloud.removeAll()' in turned_on and 'cloudAudited = false' in turned_on
        and turned_on.index('cloudBusy.isEmpty') < turned_on.index('cloud.removeAll()'),
        'turning it back on drops earlier results and syncs again once running transfers ended')
require(owned.count('"[steam-cloud] off (setting)"') == 1 and 'private var cloudOffLogged = false' in owned,
        'off is logged once per app run')
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
let local = SteamCloudAudit.run(listing: SteamCloudListing(), saveFiles: ufs, paths: paths)
check(local.entries.count == 1 && local.entries[0].kind == .localOnly, "a device-only save in a {64BitSteamID} folder is found")
check(local.entries.first?.path == name, "  its cloud name has the ID filled in (\(local.entries.first?.path ?? "-"))")
let listed = SteamCloudFile(prefix: "%GameInstall%savedata/\(steamID)/", name: "data_0.sav",
                            sha: SteamCloudAudit.sha1(of: saves.appendingPathComponent("data_0.sav"))!,
                            timestamp: 1, size: UInt64(bytes.count), persistState: 0)
let both = SteamCloudAudit.run(listing: SteamCloudListing(files: [listed]), saveFiles: ufs, paths: paths)
check(both.entries.count == 1 && both.entries[0].kind == .same, "  and once the cloud lists it under that name, the two are the same file")
try? FileManager.default.removeItem(at: tmp)

exit(failed == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / 'main.swift'
    src.write_text('import Foundation\nimport CryptoKit\n' + compare + '\n' + plan + '\n' + main.replace('import Foundation\n', '', 1))
    out = Path(tmp) / 'cloud'
    build = subprocess.run([SWIFTC, '-O', str(src), '-o', str(out)], capture_output=True, text=True)
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
