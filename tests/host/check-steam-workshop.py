#!/usr/bin/env python3
"""Steam Workshop (docs/STEAM_WORKSHOP.md): the PublishedFile requests and
item decoding, and Valve's Workshop record (appworkshop_<app>.acf) that a game
started through Madeira Dock reads. Compiles SteamWorkshopFiles.swift with the
protobuf helpers and runs it under AddressSanitizer; the rest are source checks
(the app is needed to build the views). Never contacts Steam.
Needs swiftc (Linux or macOS); SWIFTC overrides it.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


files = (app / 'SteamWorkshopFiles.swift').read_text(encoding='utf-8')
model = (app / 'SteamWorkshop.swift').read_text(encoding='utf-8')
owned = (app / 'SteamOwnedLibrary.swift').read_text(encoding='utf-8')
games = (app / 'SteamGames.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
downloader = (app / 'SwiftSteam/Content/DepotDownloader.swift').read_text(encoding='utf-8')
protocol = (app / 'SwiftSteam/Core/SteamProtocol.swift').read_text(encoding='utf-8')
session = (app / 'SwiftSteam/Core/SteamSession.swift').read_text(encoding='utf-8')
appinfo = (app / 'SwiftSteam/Library/SteamAppInfo.swift').read_text(encoding='utf-8')
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
doc = (root / 'docs/STEAM_WORKSHOP.md').read_text(encoding='utf-8')

# Source checks.
for name in ['SteamWorkshop.swift', 'SteamWorkshopFiles.swift']:
    check(project.count(f'/* {name} in Sources */') == 2 and project.count(f'/* {name} */') >= 2, f'{name} is in the app target')
for method in ['PublishedFile.GetUserFiles#1', 'PublishedFile.QueryFiles#1', 'PublishedFile.GetDetails#1',
               'PublishedFile.Subscribe#1', 'PublishedFile.Unsubscribe#1']:
    check(f'"{method}"' in protocol, f'service method {method}')
check('func callServiceMethodWithResult(' in session and 'return (response.header.eresult, response.body)' in session,
      'service calls can read the response EResult')
check('try await callServiceMethodWithResult(method: method, body: body, timeout: timeout).body' in session,
      'callServiceMethod keeps its behaviour')
check('info.workshopVisible = (common["workshop_visible"] as? String) == "1"' in appinfo and 'workshop = info.workshopVisible' in owned,
      'the owned library records which games have a Workshop')
check('SteamSignIn.flag("MADEIRA_STEAM_WORKSHOP", default: true)' in owned, 'env.MADEIRA_STEAM_WORKSHOP = 0 turns it off')
check('var workshopReady: Bool { Self.workshopEnabled && signedIn && !inSession }' in owned,
      'Workshop calls only while signed in and no game session holds the account')
check('guard workshopReady else { throw SteamError.disconnected }' in owned and owned.count('guard workshopReady else') == 2,
      'calls and downloads refuse during a session')
check('SteamWorkshopModel.shared.stopForSession()' in owned, 'a game session stops Workshop downloads')
check('func installWorkshopItem(' in downloader and 'depotKey(depotID: appID, appID: appID)' in downloader
      and 'fetchManifest(depotID: appID, appID: appID, manifestGID: manifestGID' in downloader,
      "an item is a manifest of the app's own Workshop depot")
check('[steam-workshop] download begin' in downloader and '[steam-workshop] download complete' in downloader, 'downloads are logged')
check('case .workshop:' in library and 'SteamWorkshopSections(appID: UInt32(appID), title: entry.title)' in library,
      'Game details has a Steam Workshop page')
check('SteamOwnedLibrary.shared.game(appID)?.workshop != false' in library, 'the page is hidden only when Steam says there is no Workshop')
check('.sheet(isPresented: $showWorkshop) { SteamWorkshopHub() }' in games and 'Label("Workshop", systemImage: "square.stack.3d.up")' in games,
      "the library's Steam section opens the Workshop area")
check('host.hasSuffix(".steamusercontent.com")' in model and 'url.scheme == "https"' in model,
      'older single-file items download only from Steam hosts over HTTPS')
check('SteamWorkshopRecord.itemFolder(' in model and 'try record.write(steamApps: steamApps)' in model,
      'a download writes the record after the files')
check('[steam-workshop] subscribed' in model and '[steam-workshop] unsubscribed' in model and '[steam-workshop] installed' in model,
      'subscriptions and installs are logged')
check('MADEIRA_STEAM_WORKSHOP' in doc and 'appworkshop_' in doc, 'docs/STEAM_WORKSHOP.md describes the switch and the record')

checks = r'''
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

enum SteamLog { static func event(_ m: String) {}; static func trace(_ m: @autoclosure () -> String) {} }
enum ExternalDrives { static var steamLibraries: [String] { [] } }
enum MadeiraConfig { static func get(_ key: String) -> String? { nil } }

var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}

func details(id: UInt64, fixedID: Bool = false, title: String, content: UInt64, updated: UInt32, type: UInt32 = 0,
             url: String = "", file: String = "") -> Data {
    var e = ProtobufEncoder()
    e.writeUInt32(fieldNumber: 1, value: 1)
    if fixedID { e.writeFixed64(fieldNumber: 2, value: id) } else { e.writeUInt64(fieldNumber: 2, value: id) }
    e.writeFixed64(fieldNumber: 3, value: 76561197960287930)
    e.writeUInt32(fieldNumber: 5, value: 4000)
    e.writeString(fieldNumber: 7, value: file)
    e.writeUInt64(fieldNumber: 8, value: 123_456)
    e.writeString(fieldNumber: 10, value: url)
    e.writeString(fieldNumber: 11, value: "https://images.steamusercontent.com/ugc/1/")
    e.writeFixed64(fieldNumber: 14, value: content)
    e.writeString(fieldNumber: 16, value: title)
    e.writeString(fieldNumber: 18, value: "A map.\u{0}\u{7}")
    e.writeUInt32(fieldNumber: 20, value: updated)
    e.writeUInt32(fieldNumber: 34, value: type)
    var vote = ProtobufEncoder(); vote.writeUInt32(fieldNumber: 2, value: 5)
    e.writeSubmessage(fieldNumber: 55, value: vote.data)
    return e.data
}

func fields(_ data: Data) throws -> [UInt32: [ProtoWireType]] {
    var d = ProtobufDecoder(data), out: [UInt32: [ProtoWireType]] = [:]
    while let tag = try d.readTag() { out[tag.fieldNumber, default: []].append(tag.wireType); try d.skip(wireType: tag.wireType) }
    return out
}

@main struct Checks {
    static func main() throws {
        // Items.
        let item = try SteamWorkshopItem.parse(details(id: 104_479_831, title: "gm_construct_13", content: 0xAABBCCDD11223344, updated: 1_700_000_000))
        require(item.id == 104_479_831 && item.appID == 4000 && item.title == "gm_construct_13", "an item's ID, app and title")
        require(item.content == 0xAABBCCDD11223344 && item.timeUpdated == 1_700_000_000 && item.fileSize == 123_456, "its content manifest, update time and size")
        require(item.summary == "A map." && item.downloadable && item.isContent, "control characters are dropped; a content item is downloadable")
        let fixedID = try SteamWorkshopItem.parse(details(id: 7, fixedID: true, title: "x", content: 1, updated: 1))
        require(fixedID.id == 7, "an ID sent as fixed64 is read too")
        let collection = try SteamWorkshopItem.parse(details(id: 8, title: "Pack", content: 0, updated: 1, type: 2))
        require(collection.isCollection && !collection.downloadable, "a collection is not downloaded")
        let legacy = try SteamWorkshopItem.parse(details(id: 9, title: "Old", content: 0, updated: 1, url: "http://cloud-3.steamusercontent.com/ugc/9/", file: "../../addons/old.gma"))
        require(legacy.downloadable && SteamWorkshopRecord.legacyFileName(legacy) == "old.gma", "an older item's file name stays inside its folder")
        require(SteamWorkshopRecord.legacyFileName(SteamWorkshopItem(id: 10, fileName: "..")) == "10_legacy.bin", "an unusable name falls back to the item ID")
        require((try? SteamWorkshopItem.parse(Data([0x0a, 0xff]))) == nil, "a truncated item throws instead of reading past the end")

        // Pages: GetUserFiles puts items at 3, QueryFiles at 2, GetDetails at 1.
        var response = ProtobufEncoder()
        response.writeUInt32(fieldNumber: 1, value: 2)
        response.writeUInt32(fieldNumber: 2, value: 0)
        response.writeSubmessage(fieldNumber: 3, value: details(id: 1, title: "a", content: 1, updated: 1))
        response.writeSubmessage(fieldNumber: 3, value: details(id: 2, title: "b", content: 2, updated: 1))
        let page = try SteamWorkshopRequests.page(response.data, itemsField: 3)
        require(page.total == 2 && page.items.map(\.id) == [1, 2], "a page's total and items")

        // Requests.
        let subscribed = try fields(SteamWorkshopRequests.subscribed(steamID: 76561197960287930, appID: 4000, page: 2))
        require(subscribed[1] == [.fixed64] && subscribed[2] == [.varint] && subscribed[4] == [.varint] && subscribed[5] == [.varint] && subscribed[6] == [.lengthDelimited],
                "GetUserFiles: steamid fixed64, appid, page, numperpage, type")
        require(String(decoding: SteamWorkshopRequests.subscribed(steamID: 1, appID: 4000, page: 1), as: UTF8.self).contains("mysubscriptions"), "it asks for the subscription list")
        let query = try fields(SteamWorkshopRequests.query(appID: 4000, order: .search, text: " maps ", page: 1))
        require(query[1] == [.varint] && query[5] == [.varint] && query[11] == [.lengthDelimited] && query[37] == [.varint], "QueryFiles: type, appid, search text, return_details")
        let trend = try fields(SteamWorkshopRequests.query(appID: 4000, order: .trend, text: "x", page: 1))
        require(trend[14] == [.varint], "Popular asks for the last 7 days")
        require(trend[11] == nil, "only Search sends text")
        let sub = try fields(SteamWorkshopRequests.subscription(itemID: 104_479_831, appID: 4000))
        require(sub[1] == [.varint] && sub[2] == [.varint] && sub[3] == [.varint] && sub[4] == [.varint], "Subscribe: item, list, app, notify the client")
        let many = try fields(SteamWorkshopRequests.details(appID: 4000, ids: Array(1...150)))
        require(many[1]?.count == 100, "GetDetails asks for at most 100 items")

        // The record.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("workshop-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let steamApps = dir.appendingPathComponent("steamapps")
        let valve = """
        "AppWorkshop"
        {
        \t"appid"\t\t"4000"
        \t"SizeOnDisk"\t\t"500"
        \t"NeedsUpdate"\t\t"0"
        \t"NeedsDownload"\t\t"1"
        \t"TimeLastUpdated"\t\t"1"
        \t"TimeLastAppRan"\t\t"1690000000"
        \t"LastBuildID"\t\t"777"
        \t"WorkshopItemsInstalled"
        \t{
        \t\t"555"
        \t\t{
        \t\t\t"size"\t\t"500"
        \t\t\t"timeupdated"\t\t"10"
        \t\t\t"manifest"\t\t"42"
        \t\t}
        \t}
        \t"WorkshopItemDetails"
        \t{
        \t\t"555"
        \t\t{
        \t\t\t"manifest"\t\t"42"
        \t\t\t"timeupdated"\t\t"10"
        \t\t\t"timetouched"\t\t"11"
        \t\t\t"subscribedby"\t\t"22202"
        \t\t}
        \t\t"666"
        \t\t{
        \t\t\t"manifest"\t\t"0"
        \t\t\t"timeupdated"\t\t"0"
        \t\t\t"timetouched"\t\t"12"
        \t\t\t"subscribedby"\t\t"22202"
        \t\t}
        \t}
        }
        """
        let url = SteamWorkshopRecord.url(appID: 4000, steamApps: steamApps)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(valve.utf8).write(to: url)
        var record = SteamWorkshopRecord.read(appID: 4000, steamApps: steamApps)
        require(record.lastBuildID == 777 && record.timeLastAppRan == 1_690_000_000, "Valve's record is read")
        require(record.installed.keys.sorted() == [555] && record.entries[666]?.installed == false && record.entries[555]?.subscribedBy == 22202,
                "installed and still-to-download items are told apart")
        require(!record.isOnDisk(555, steamApps: steamApps), "an item whose folder is gone is not on disk")
        try FileManager.default.createDirectory(at: SteamWorkshopRecord.itemFolder(appID: 4000, itemID: 555, steamApps: steamApps), withIntermediateDirectories: true)
        require(record.isOnDisk(555, steamApps: steamApps), "an item with its folder is on disk")
        require(SteamWorkshopRecord.itemFolder(appID: 4000, itemID: 555, steamApps: steamApps).path.hasSuffix("steamapps/workshop/content/4000/555"), "items live in workshop/content/<app>/<item>")
        require(record.needsUpdate(SteamWorkshopItem(id: 555, content: 43)) && !record.needsUpdate(SteamWorkshopItem(id: 555, content: 42)), "a new manifest is an update")
        require(record.needsUpdate(SteamWorkshopItem(id: 555, timeUpdated: 11)) && !record.needsUpdate(SteamWorkshopItem(id: 777, content: 1)), "else a newer time; unknown items are not updates")

        record.entries[1234] = SteamWorkshopRecord.Entry(installed: true, size: 1000, timeUpdated: 20, manifest: 99, timeTouched: 21, subscribedBy: 22202)
        try record.write(steamApps: steamApps)
        let text = try String(contentsOf: url, encoding: .utf8)
        require(text.hasPrefix("\"AppWorkshop\"\n{\n\t\"appid\"\t\t\"4000\"\n\t\"SizeOnDisk\"\t\t\"1500\""), "the record starts as Valve's does, with the installed size")
        require(text.contains("\t\"NeedsDownload\"\t\t\"1\"") && text.contains("\t\"LastBuildID\"\t\t\"777\""), "Valve's fields are kept")
        let again = SteamWorkshopRecord.read(appID: 4000, steamApps: steamApps)
        require(again.entries == record.entries && again.lastBuildID == 777, "the written record reads back the same")
        require(again.entries[1234]?.manifest == 99 && text.contains("\"latest_manifest\"\t\t\"99\""), "a new item is recorded installed and current")
        record.entries[666] = nil
        try record.write(steamApps: steamApps)
        let complete = try String(contentsOf: url, encoding: .utf8)
        require(complete.contains("\t\"NeedsDownload\"\t\t\"0\""), "with everything installed nothing needs downloading")
        require(SteamWorkshopRecord.parse(Data("garbage {".utf8), appID: 1).entries.isEmpty, "an unreadable record reads as empty")

        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all Steam Workshop Swift checks")
    }
}
'''

SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc')
if not SWIFTC:
    print('SKIP: swiftc not found (set SWIFTC); source checks only')
else:
    with tempfile.TemporaryDirectory(prefix='madeira-steam-workshop-') as tmp:
        tmp = Path(tmp)
        (tmp / 'checks.swift').write_text(checks)
        exe = tmp / 'check'
        build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-o', str(exe),
                                str(tmp / 'checks.swift'), str(app / 'SteamWorkshopFiles.swift'),
                                str(app / 'SwiftSteam/Proto/SteamProtoMessages.swift'), str(app / 'SwiftSteam/Core/SteamError.swift'),
                                str(app / 'SteamKeyValues.swift'), str(app / 'SteamInstall.swift'), str(app / 'ExternalStorage.swift')],
                               capture_output=True, text=True)
        check(build.returncode == 0, 'SteamWorkshopFiles.swift compiles on the host')
        if build.returncode:
            sys.stdout.write(build.stderr[-4000:])
        else:
            run = subprocess.run([str(exe)], env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'), capture_output=True, text=True)
            sys.stdout.write(run.stdout)
            if run.returncode:
                sys.stdout.write(run.stderr[-4000:])
            check(run.returncode == 0, 'Steam Workshop checks pass under AddressSanitizer')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
