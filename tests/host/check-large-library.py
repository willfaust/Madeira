#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Optimized host probe of production discovery and owned-library conversion.

No network, devices, or user library. Fixtures are filesystem-warm after writes;
first scan and repeats are reported separately, not claimed as cold storage/UI.
Use --benchmark-only to record an unfixed baseline without the 3,600-title gate.
"""
from pathlib import Path
import os
import argparse
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
parser = argparse.ArgumentParser()
parser.add_argument('--source-ref', help='local git ref for an identical baseline fixture')
parser.add_argument('--benchmark-only', action='store_true')
args = parser.parse_args()
def source(name):
    if args.source_ref:
        return subprocess.check_output(['git', 'show', f'{args.source_ref}:app/Madeira/{name}'], cwd=root, text=True)
    return (app / name).read_text()
dock = source('MadeiraDock.swift')
owned = source('SteamOwnedLibrary.swift')
fetcher = source('SwiftSteam/Library/SteamLibraryFetcher.swift')
head = dock[dock.index('struct DockGame:'):dock.index('/// Madeira Dock:')]
methods = dock[dock.index('    static func validAppID'):dock.index('    /// Everything a launch needs')]
owned = owned[owned.index('struct SteamOwnedGame:'):owned.index('// MARK: - Playtime')]
vdf = fetcher[fetcher.index('// MARK: - Simple VDF Binary Parser'):]
games_source = source('SteamGames.swift')
refresh = games_source[games_source.index('            let discovery = MadeiraDock.discovery' if 'let discovery = MadeiraDock.discovery' in games_source else '            let found = MadeiraDock.games'):games_source.index('            let recorded = builds,')]
refresh = 'func refresh(_ drive: URL) -> (games: [DockGame], builds: [Int: Int], languages: [Int: String], depots: [Int: Set<Int>], dlc: [Int: [Int: Int64]], branches: [Int: String]) {\n' + refresh + '\nreturn (found, builds, languages, depots, dlc, branches)\n}\n'
page = source('LibraryGridPage.swift')
memo = page[page.index('@MainActor enum LibraryGridSteamItems {'):page.index('/// One block of the page')]
# Only the pure memo entry point, leaving UI/model state out of the host probe.
memo = memo[:memo.index('    static var shown:')] + '}\n'
rules = games_source[games_source.index('enum SteamGamesRules {'):games_source.index('// MARK: - Model')]
rules = 'var itemComputations = 0\n' + rules.replace(' -> [Item] {\n        var byID:', ' -> [Item] {\n        itemComputations += 1\n        var byID:', 1)

stubs = r'''
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
enum SteamLog { static func event(_ message: String) {} }
enum ExternalDrives { static var steamLibraries: [String] = [] }
enum SteamRuntimeFiles { static let relativeRoot = "Program Files (x86)/Steam" }
enum MadeiraConfig {
    static func get(_ key: String) -> String? { nil }
    static func set(_ key: String, _ value: String?) {}
    static func gameValue(_ key: String) -> String? { nil }
}
'''
index_setup = 'let index = SteamOwnedDLC.Index(owned: dlc)' if 'struct Index {' in owned else 'let index = dlc'
checks = r'''
import Foundation
func elapsed<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try work()
    print("TIME \(label) \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) ms")
    return value
}
@main struct Checks {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let drive = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("drive_c")
        let apps = drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot + "/steamapps")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        for id in 1...3600 {
            let manifest = """
            "AppState" { "appid" "\(id)" "name" "Game \(id)" "installdir" "Game\(id)"
            "StateFlags" "4" "buildid" "77" "UserConfig" { "language" "German" "BetaKey" "preview" }
            "InstalledDepots" { "\(id + 10000)" { "manifest" "42" "size" "512" "dlcappid" "\(id + 20000)" } } }
            """
            try Data(manifest.utf8).write(to: apps.appendingPathComponent("appmanifest_\(id).acf"))
        }
        // Unrelated names must not consume a discovery budget.
        for id in 1...100 { try Data().write(to: apps.appendingPathComponent("aaa_\(id)")) }
        for pass in 0..<3 {
            let found = elapsed("discovery-\(pass == 0 ? "first-after-fixture-write" : "warm-repeat")") {
                MadeiraDock.games(drive: drive)
            }
            print("COUNT discovered=\(found.count) expected=3600")
            if !CommandLine.arguments.contains("--benchmark-only") { precondition(found.count == 3600) }
        }
        for _ in 0..<3 {
            let count = elapsed("installed-refresh-scan-and-metadata-warm") { refresh(drive).games.count }
            if !CommandLine.arguments.contains("--benchmark-only") { precondition(count == 3600) }
        }
        let refreshed = refresh(drive)
        for game in refreshed.games {
            precondition(refreshed.builds[game.id] == 77 && refreshed.languages[game.id] == "german")
            precondition(refreshed.branches[game.id] == "preview")
            precondition(refreshed.depots[game.id] == [game.id + 10000])
            precondition(refreshed.dlc[game.id] == [game.id + 20000: 512])
        }
        precondition(SteamInstallFiles.buildID(appID: 1, steamApps: apps) == 77)
        precondition(SteamInstallFiles.language(appID: 1, steamApps: apps) == "german")
        precondition(SteamInstallFiles.betaKey(appID: 1, steamApps: apps) == "preview")
        precondition(SteamInstallFiles.depots(appID: 1, steamApps: apps) == [10001])
        precondition(SteamInstallFiles.installedDLC(appID: 1, steamApps: apps) == [20001: 512])
        let games = (1...3600).map { id -> SteamAppInfo in
            var game = SteamAppInfo(appID: UInt32(id)); game.name = "Game \(id)"; game.installDir = game.name
            game.oslist = "windows,linux"; game.buildID = 123456
            game.libraryCapsule = String(repeating: "a", count: 40) + "/library_600x900.jpg"
            game.libraryHero = String(repeating: "b", count: 40) + "/library_hero.jpg"
            game.headerImage = "header.jpg"
            game.languages = ["english", "german", "french", "spanish", "japanese"]
            game.launches = [SteamLaunchOption(executable: "bin/game.exe", index: 0, arguments: "-launch", workingDir: "bin", oslist: "windows", osarch: "64")]
            game.branches = [.init(name: "public", buildID: 123456, description: "", passwordRequired: false, updated: 1700000000),
                             .init(name: "preview", buildID: 123457, description: "Preview version", passwordRequired: false, updated: 1700000001)]
            game.depots = [.init(depotID: UInt32(id + 30000), maxSize: 4_000_000_000, oslist: "windows", manifests: ["public": 42], publicDownloadBytes: 2_000_000_000, publicSizeBytes: 4_000_000_000)]
            return game
        }
        let dlc = Dictionary(uniqueKeysWithValues: (1...3600).map { id -> (UInt32, SteamAppInfo) in
            var info = SteamAppInfo(appID: UInt32(id + 10000)); info.type = .dlc
            info.parentID = UInt32(id); info.name = "DLC \(id)"
            return (info.appID, info)
        })
        for _ in 0..<5 {
            let converted = elapsed("owned-conversion-3600-games-3600-dlc") {
                INDEX_SETUP
                return games.map { SteamOwnedGame($0, ownedDLC: index) }
            }
            precondition(converted.count == 3600 && converted.allSatisfy { $0.dlc?.count == 1 })
            let data = try elapsed("cache-encode") { try JSONEncoder().encode(converted) }
            let decoded = try elapsed("cache-decode") { try JSONDecoder().decode([SteamOwnedGame].self, from: data) }
            precondition(decoded == converted)
            print("COUNT cache-bytes=\(data.count)")
        }
        var host = games[0]; host.dlcList = [10001, 10002, 10003, 1]
        var related = dlc
        related[10002]?.parentID = 2
        related[10003]?.type = .game
        related[10004]?.parentID = 1
        var selfDLC = SteamAppInfo(appID: 1); selfDLC.type = .dlc; selfDLC.parentID = 1
        related[1] = selfDLC
        DLC_INDEX_SETUP
        let associated = SteamOwnedGame(host, ownedDLC: relatedIndex).dlc!.map(\.id)
        precondition(Set(associated) == [10001, 10002, 10004], "parent OR known IDs, playable/self exclusions, deduplication")
        let items = games.map { SteamOwnedGame($0) }
        itemComputations = 0
        for _ in 0..<5 {
            let result = elapsed("nine-ui-list-requests-unchanged-inputs") {
                var count = 0
                for _ in 0..<9 { count += UI_ITEMS(installed: [], owned: items, search: "").count }
                return count
            }
            precondition(result == 9 * 3600)
        }
        print("COUNT list-computations=\(itemComputations) requests=45")
        precondition(itemComputations == EXPECTED_COMPUTATIONS)
        UPDATE_CHECK
        print("PASS: large library discovery, metadata and owned conversion")
    }
}
'''
checks = checks.replace('DLC_INDEX_SETUP', 'let relatedIndex = SteamOwnedDLC.Index(owned: related)' if 'struct Index {' in owned else 'let relatedIndex = related')
checks = checks.replace('INDEX_SETUP', index_setup)
checks = checks.replace('UI_ITEMS', 'SteamGamesRules.items' if args.source_ref else 'LibraryGridSteamItems.items')
checks = checks.replace('EXPECTED_COMPUTATIONS', '45' if args.source_ref else '1')
checks = checks.replace('UPDATE_CHECK', '' if args.source_ref else r'''
        let one = apps.appendingPathComponent("appmanifest_1.acf")
        let changed = try String(contentsOf: one, encoding: .utf8).replacingOccurrences(of: "\"77\"", with: "\"88\"")
        try Data(changed.utf8).write(to: one)
        let changedScan = MadeiraDock.discovery(drive: drive)
        precondition(SteamInstallFiles.Metadata(state: changedScan.records[1]!).buildID == 88,
                     "fresh scans must observe external file edits")
        var renamed = items; renamed[0].name = "Changed title"
        let changedItems = LibraryGridSteamItems.items(installed: [], owned: renamed, search: "")
        precondition(changedItems.first { $0.id == 1 }?.name == "Changed title", "memo invalidates metadata at an existing search key")
        let searched = LibraryGridSteamItems.items(installed: [], owned: renamed, search: "Changed title")
        precondition(searched.count == 1 && searched[0].id == 1, "search is independently applied")
        // The first library wins, while a noncanonical filename still reads
        // metadata from appmanifest_<appid>.acf, as the old refresh did.
        let alias = apps.appendingPathComponent("appmanifest_0000.acf")
        try Data("\"AppState\" { \"appid\" \"2\" \"name\" \"Alias\" \"installdir\" \"Game2\" \"StateFlags\" \"4\" \"buildid\" \"999\" }".utf8).write(to: alias)
        let externalLibrary = "External/fixture/steamapps"
        let external = drive.appendingPathComponent(externalLibrary)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        let second = try String(contentsOf: apps.appendingPathComponent("appmanifest_2.acf"), encoding: .utf8)
        try Data(second.replacingOccurrences(of: "Game 2", with: "Duplicate in second library").utf8)
            .write(to: external.appendingPathComponent("appmanifest_2.acf"))
        ExternalDrives.steamLibraries = [externalLibrary]
        let duplicates = refresh(drive)
        precondition(duplicates.games.count == 3600 && duplicates.games.first { $0.id == 2 }?.name == "Alias")
        precondition(duplicates.games.first { $0.id == 2 }?.library == SteamRuntimeFiles.relativeRoot + "/steamapps")
        precondition(duplicates.builds[2] == 77 && duplicates.languages[2] == "german" && duplicates.branches[2] == "preview")
        precondition(duplicates.depots[2] == [10002] && duplicates.dlc[2] == [20002: 512])
        var many: [UInt32: SteamAppInfo] = [:]
        for id in 50000..<51200 {
            var info = SteamAppInfo(appID: UInt32(id)); info.type = .dlc; info.parentID = 1; info.name = "DLC \(id)"
            many[info.appID] = info
        }
        let capped = SteamOwnedGame(games[0], ownedDLC: SteamOwnedDLC.Index(owned: many)).dlc!
        precondition(capped.count == 1024 && Set(capped.map(\.id)) == Set(50000..<51024), "DLC bound has deterministic selection")
        print("PASS: all five metadata maps, existing-key memo invalidation, duplicate precedence, canonical fallback, DLC cap")
''')
private_root = Path.home() / 'tmp'
private_root.mkdir(mode=0o700, exist_ok=True)
private_root.chmod(0o700)
with tempfile.TemporaryDirectory(prefix='pi-large-library.', dir=private_root) as tmp:
    folder = Path(tmp)
    env = dict(os.environ, TMPDIR=tmp, TMP=tmp, TEMP=tmp)
    program = folder / 'probe.swift'
    program.write_text(stubs + head + '\nenum MadeiraDock {\n' + methods + '\n}\n' + owned + vdf + rules + memo + refresh + checks)
    exe = folder / 'probe'
    dependencies = []
    for name in ['SteamKeyValues.swift', 'SteamInstall.swift', 'ExternalStorage.swift', 'SwiftSteam/Library/SteamAppInfo.swift']:
        path = folder / Path(name).name
        path.write_text(source(name))
        dependencies.append(str(path))
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-swift-version', '5', str(program),
                    *dependencies,
                    '-o', str(exe)], check=True, env=env)
    subprocess.run([str(exe)] + (['--benchmark-only'] if args.benchmark_only else []), check=True, env=env)
