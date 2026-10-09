#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Steam games in the library (app/Madeira/SteamGames.swift), on the host.

1. Swift: compiles the production SteamGamesRules with Madeira Dock's production
   discovery (MadeiraDock.games / game(manifest:), sliced as in
   check-dock-contract.py, and SteamKeyValues.swift) and checks, on a synthetic
   drive_c laid out as Steam's client writes it, that installed and partly
   installed games are found, plus the section, search, Play-blocker, card
   pill and artwork rules, the merge of installed and owned games (owned games
   come from the production SteamOwnedGame and SteamAppInfo), and the program
   an installed game's pills describe.
2. Source checks: the section uses Dock's discovery and Dock's launch path
   only (no environment, sign-in transfer, token or Wine call of its own), no
   program-name list, no account data in a log line, wired into the library,
   built by the Xcode project; an installed game's card shows the library
   pills, read once per install and kept on its library entry.

Synthetic data only: no Steam, Wine or credentials.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


games = (app / 'SteamGames.swift').read_text()
owned_source = (app / 'SteamOwnedLibrary.swift').read_text()
fetcher = (app / 'SwiftSteam/Library/SteamLibraryFetcher.swift').read_text()
dock = (app / 'MadeiraDock.swift').read_text()
library = (app / 'Library.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
rules = games[games.index('// MARK: - Rules'):games.index('// MARK: - Model')]

# ------------------------------------------------------------------ static
require(games.startswith('// SPDX-License-Identifier: GPL-3.0-or-later\n// Copyright 2026 125hz\n'
                         '// Madeira Converter Exception: see LICENSE-EXCEPTION.md\n'),
        'SteamGames.swift: GPL-3.0-or-later, Copyright 2026 125hz, Converter Exception')
require('/* SteamGames.swift in Sources */,' in project and 'path = "SteamGames.swift"' in project,
        'SteamGames.swift is built by the Xcode project')
content_view = (app / 'ContentView.swift').read_text()
require('SteamGamesSection(search: search, layout: layout, sort: sort, width: viewport.size.width,\n'
        '                                      part: .installed, open: { selected = $0 })' in library,
        "Library: the Steam section is in the library and opens the library's Game details page")
require('MadeiraDock.games(drive: drive)' in games and 'let drive = MadeiraDock.drive' in games,
        "the section lists exactly what Dock's own discovery finds")
# Game details: a Steam game is a library entry (its per-game settings) with a Steam section.
require('open(LibraryModel.shared.steamEntry(installed, title: item.name))' in games,
        'an installed Steam game opens its Game details page (its library entry)')
require(games.count('startDock(') == 0, 'the section never starts Dock itself: Play is on the Game details page')
# A finished download: the game becomes a library entry, and its sheet's button reads Open (Game details).
sheet = games[games.index('struct SteamGameSheet: View {'):games.index('struct SteamEntrySection')]
require('Text("Open")' in sheet and 'SteamGamesRules.canOpenInstalledGame(installed, hasTransfer: steam.downloads[appID] != nil)' in sheet and 'dismiss(); open(entry)' in sheet,
        "a finished download's sheet offers Open, which opens the Game details page")
require('SteamGameSheet(appID: selection.id) { entry in' in games and 'open(entry) }' in games,
        'Open presents the Game details page after the download sheet closes')
run_body = owned_source[owned_source.index('    private func run(_ appID: Int) async {'):]
run_body = run_body[:run_body.index('\n    }\n')]
require(run_body.index('try await downloader.install(') < run_body.index('LibraryModel.shared.upsertSteam(') < run_body.index('} catch {'),
        'a finished download (record written) gets its library entry; a failed or paused one does not')
require('LibraryModel.shared.removeSteam(appID: game.id)' in owned_source[owned_source.index('func uninstall(_ game: DockGame)'):],
        "Uninstall removes the game's library entry with its files")
detail = library[library.index('struct LibraryDetail: View {'):library.index('struct FPSChoice: View {')]
steam_section = games[games.index('struct SteamEntrySection'):]
require('@ObservedObject private var steam = SteamOwnedLibrary.shared' in detail and
        detail.index('let download = steam.downloads[appID]') < detail.index('Button(action: start)') and
        'SteamTransferControls(appID: appID, download: download,' in detail and
        'SteamDownloadStatus(download: download)' in detail,
        'Game details observes transfers and replaces Play with transfer controls and progress')
require('SteamTransferControls(' not in steam_section and 'SteamDownloadStatus(' not in steam_section,
        'Steam section does not duplicate the header transfer controls or progress')

require('SteamEntrySection(entry: $entry)' in detail and 'if entry.steamAppID != nil {' in detail,
        'Game details: the Steam section for a Steam game')
for label in ['"Start with"', '"Madeira Dock"', '"Smaller JIT pool (512 MB) for this launch"', '"One-time installs"',
              '"Run at next start"', '"Skip"', '"Repair installed files"', '"Uninstall"', '"App ID"',
              '"Free space in game library"', '"The game"', '"Program"', '"Choose…"']:
    require(label in steam_section, f'Steam section: {label}')
for label in ['"Library details"', '"Choose cover image"', '"Use Steam artwork"', '"Display"', '"Resolution"',
              '"Aspect & scaling"', '"Compatibility & performance"', '"Reduced-precision x87"', '"CPU cores reported"',
              '"D3D9 anisotropic filtering"', '"On screen"', '"Performance overlay"', '"Live logs"', '"Touch controls"',
              '"Control opacity"', '"Control size"', '"Executable"', '"Game details"']:
    require(label in detail, f'Game details: {label}')
require('if entry.desktop != true && entry.steamAppID == nil {' in detail,
        "no Launch arguments for a Steam game: Dock starts Steam's own launch option")
entries_start = library.index('private var entries: [LibraryEntry] {')
require('$0.steamAppID == nil' in library[entries_start:library.index('var body: some View {', entries_start)],
        'Steam games are listed in the Steam section only, not also under Games')
# A card's pills: an installed game shows a library game's (32-bit or 64-bit, graphics API, size), no
# "Madeira Dock" or "Steam" pill; "Update" joins them; any other state keeps its own pill.
cell = games[games.index('struct SteamGameCell: View {'):games.index('/// Progress, speed and the state of one download.')]
require('@ViewBuilder private func pills(_ status: SteamGamesRules.Status, _ entry: LibraryEntry?) -> some View {' in cell and
        'if status.showsFormat, let entry {\n            LibraryBadges(entry: entry, note: status.badge)' in cell and
        '} else if let text = status.badge {\n            badge(text)' in cell and
        cell.count('pills(status, entry)') == 3 and '.label' not in cell and
        '"Madeira Dock"' not in rules and '"Steam"' not in rules,
        "an installed game's card shows the library pills (and Update), any other state its own pill, in all three "
        "layouts (dense list, list, grid); no Dock or Steam pill")
badges = library[library.index('struct LibraryBadges: View {'):library.index('struct LibraryStatus: View {')]
require(badges.index('badge("\\(entry.bits)-bit")') < badges.index('LibraryRendererBadge.compact(entry.graphicsAPI)') <
        badges.index('if let note { badge(note) }') < badges.index('private var size'),
        'the pills in order: bits, graphics API, Update, then the size')
require('await library.refreshSteamMetadata(game, title: item.name)' in cell and 'if status.showsFormat, let game = item.installed' in cell,
        "an installed game's card reads its format through its library entry")
steam_meta = library[library.index('    func refreshSteamMetadata('):]
steam_meta = steam_meta[:steam_meta.index('\n    }\n')]
require(steam_meta.index('SteamInstallFiles.buildID(') <
        steam_meta.index('let install = "\\(game.storageID)#\\(folder)#\\(record.build ?? 0)#\\(picked ?? "")#\\(known ? 1 : 0)"') <
        steam_meta.index('stored.steamMetadataInstall == install') < steam_meta.index('launchOptions(appID: game.id)'),
        "the format is read again only for another install folder, build or picked program, once Steam's launch "
        "configuration is cached, or a day later while no program is known")
require('\\(steam.game(item.id)?.launches != nil)' in cell,
        "the card reads again when Steam's launch configuration arrives")
require('stored?.steamProgramSource == "choice" ? stored?.steamProgram : nil' in steam_meta and
        'let options = kept == nil ? await SteamOwnedLibrary.shared.launchOptions(appID: game.id) : nil' in steam_meta and
        'SteamDirectStart.program(picked: kept, options: options, installFolder: root)' in steam_meta and
        'LibraryModel.inspect(root.appendingPathComponent(path), root: drive)' in steam_meta and
        'LibraryMetadataScanner.shared.scan(program.url, drive: drive, countBytes: false)' in steam_meta,
        'the program is the one "The game" starts; bits from its PE header, the API as for any library game')
require(steam_meta.count('Task.detached(priority: .utility)') == 3 and 'updated.folderBytes = record.size ?? updated.folderBytes' in steam_meta
        and 'guard !Task.isCancelled else { return }' in steam_meta and 'save(updated)' in steam_meta,
        "file reads off the main thread; the size is the install record's; the result is kept on the game's entry")
require('LogStore.shared.log("[steam-games] metadata app=\\(game.id) bits=\\(updated.bits) api=\\(api ?? "unknown")")' in steam_meta
        and steam_meta.count('LogStore') == 1, '[steam-games] metadata logs the App ID, bits and API only')
save_body = library[library.index('    func save(_ entry: LibraryEntry) {'):library.index('    func remove(_ id: UUID) {')]
require('next.firstIndex(where: { entry.steamAppID != nil && $0.steamAppID == entry.steamAppID })' in save_body and
        'entry.bits = next[i].bits; entry.steamMetadataInstall = next[i].steamMetadataInstall' in save_body,
        "a Steam game keeps one entry, and a details page saved later keeps the card's newer format")
launch = content_view[content_view.index('private func launchLibraryEntry('):content_view.index('private func runWineFullSequence(')]
require('if let appID = entry.steamAppID, !entry.startsSteamGameDirectly {' in launch and
        'startDock(game, compactPool: MadeiraDockModel.shared.compactPool, profile: entry, storageChecked: storageChecked)' in launch,
        "Play on a Steam game's Game details page starts it through Madeira Dock with its own profile")
# "Start with: The game" (SteamDirectStart): the program from Steam's launch configuration or the
# Program picker starts like any library game, without Dock, a sign-in transfer or a client.
direct = launch[launch.index('if let appID = entry.steamAppID, !entry.startsSteamGameDirectly {'):]
require(direct.index('startDock(') < direct.index('guard entry.steamProgram?.isEmpty == false else {') <
        direct.index('LibraryModel.executable(entry.launchRelativePath, root: storageRoot)') < direct.index('entry.configureLaunch()') <
        direct.index('runWineFullSequence(profile: entry)'),
        '"The game": no program chosen, no start; otherwise the program is checked inside drive_c and started as a library game')
require('writeHandoff' not in direct[direct.index('guard entry.steamProgram'):] and 'credentialsForDock' not in launch,
        '"The game" hands no sign-in to anything')
dock_start = content_view[content_view.index('private func startDock('):]
dock_start = dock_start[:dock_start.index('\n    }\n') + 6]
require('if let profile { library.begin(profile, dock: game) }' in dock_start and 'runWineFullSequence(profile: profile)' in dock_start,
        "a Steam game's session takes its display, overlay and control settings")
configure = library[library.index('    func configureLaunch() {'):]
configure = configure[:configure.index('\n    }\n')]
require(configure.index('if steamAppID != nil {') < configure.index('if !startsSteamGameDirectly {') <
        configure.index('return') < configure.index('setenv("MADEIRA_EXE"'),
        "a Steam game's profile never replaces what Madeira Dock starts (only \"The game\" sets what starts)")
require(configure.index('unsetenv("MADEIRA_STEAM_APPID"); unsetenv("MADEIRA_STEAM_APPPATH"); unsetenv("MADEIRA_WORKDIR")') <
        configure.index('if steamAppID != nil {') and
        configure.index('if startsSteamGameDirectly, let steamAppID {') < configure.index(' setenv("MADEIRA_STEAM_APPID"') and
        configure.count(' setenv("MADEIRA_STEAM_APPID"') == 1,
        "the game's own Steam identity and working folder are exported for \"The game\" only, and cleared for every other launch")
bridge = (app / 'WineProcessBridge.m').read_text()
identity = bridge[bridge.index('const char *direct_app = getenv("MADEIRA_STEAM_APPID");'):]
identity = identity[:identity.index('unsetenv("MADEIRA_STEAM_APPPATH");')]
require('setenv("SteamAppId",  direct_app, 1);' in identity and 'strspn(direct_app, "0123456789") == strlen(direct_app)' in identity
        and '} else {' in identity and 'unsetenv("MADEIRA_STEAM_APPID");' in identity,
        "bridge: a direct start publishes its game's own identity once (digits only, a C: folder); every other launch keeps the previous identity")
workdir = bridge[bridge.index('const char *launch_workdir = getenv("MADEIRA_WORKDIR");'):]
workdir = workdir[:workdir.index('} else if (strchr(madeira_exe')]
require('unsetenv("MADEIRA_WORKDIR");' in workdir and '!strstr(launch_workdir, "..")' in workdir and 'chdir(unix_dir)' in workdir,
        "bridge: Steam's working folder applies to one launch, only as a C: folder of the prefix")
apply = library[library.index('    func applyEnvironment() {'):]
apply = apply[:apply.index('\n    }\n')]
require('if let cpuCount, (1..<64).contains(cpuCount) { setenv("MADEIRA_CPU_COUNT"' in apply and
        'if let anisotropyLimit, [1, 2, 4, 8].contains(anisotropyLimit) { setenv("DXMT_D9_ANISO_LIMIT"' in apply and
        'else { unsetenv("MADEIRA_CPU_COUNT") }' in apply and 'else { unsetenv("DXMT_D9_ANISO_LIMIT") }' in apply,
        'CPU cores and anisotropic filtering are exported when chosen and cleared for the next game otherwise')
for forbidden in ['setenv(', 'unsetenv(', 'runWineFullSequence', 'writeHandoff', 'credentialsForDock', 'SteamTokenStore',
                  'refreshToken', 'SecItem', 'MADEIRA_EXE', 'MADEIRA_ARGS', 'jit_', 'JITPool', 'poolSize',
                  'steamwebhelper', 'steam.exe', 'SteamSetup', 'FEX_', 'DXMT']:
    require(forbidden not in games, f'SteamGames.swift: no {forbidden}')
require(not re.findall(r'"[^"\n]*\.exe"', games), 'SteamGames.swift: no program names')
for line in games.splitlines():
    if re.search(r'LogStore|SteamLog\.|print\(|NSLog|fputs', line):
        require(re.search(r'\\\((game\.name|name|account|token|signIn|path|folder|status|error)', line) is None,
                f'no account data, name or path in "{line.strip()[:70]}"')
require(re.search(r'\bView\b|SwiftUI', rules.replace('// MARK: - Rules', '')) is None, 'the rules are Foundation-only')

# ------------------------------------------------------------------ compiled
head = dock[dock.index('enum DockPerformancePolicy {'):dock.index('enum MadeiraDock {')]
body = (dock[dock.index('enum MadeiraDock {'):dock.index('    @MainActor private static var lastReport =')] +
        dock[dock.index("    /// The host's environment for one launch."):])
stubs = r'''
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
enum SteamSignIn {
    static func flag(_ name: String, default fallback: Bool) -> Bool { getenv(name).map { String(cString: $0) != "0" } ?? fallback }
}
enum SteamLog { static func event(_ m: String) {}; static func trace(_ m: @autoclosure () -> String) {} }
enum SteamRuntimeFiles {
    static let relativeRoot = "Program Files (x86)/Steam"
    static let windowsRoot = "C:\\Program Files (x86)\\Steam"
}
'''
owned_game = owned_source[owned_source.index('struct SteamOwnedGame:'):owned_source.index('// MARK: - Playtime')]
vdf = fetcher[fetcher.index('// MARK: - Simple VDF Binary Parser'):]
checks = r'''
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}
func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
func record(_ appID: Int, _ name: String, _ folder: String, flags: Int) -> String {
    "\"AppState\"\n{\n\t\"appid\"\t\t\"\(appID)\"\n\t\"Universe\"\t\t\"1\"\n\t\"name\"\t\t\"\(name)\"\n\t\"StateFlags\"\t\t\"\(flags)\"\n" +
    "\t\"installdir\"\t\t\"\(folder)\"\n\t\"buildid\"\t\t\"100\"\n}\n"
}

@main struct Checks {
    static func main() throws {
        typealias R = SteamGamesRules
        let fm = FileManager.default
        let drive = fm.temporaryDirectory.appendingPathComponent("madeira-steam-games-" + UUID().uuidString)
        defer { try? fm.removeItem(at: drive) }
        // Madeira's Steam library, as Steam's client lays it out.
        let apps = drive.appendingPathComponent("Program Files (x86)/Steam/steamapps")
        try write(apps.appendingPathComponent("appmanifest_4242.acf"), record(4242, "Fixture Game", "Fixture Game", flags: 4))
        try fm.createDirectory(at: apps.appendingPathComponent("common/Fixture Game"), withIntermediateDirectories: true)
        try write(apps.appendingPathComponent("appmanifest_4343.acf"), record(4343, "Second Fixture", "Second", flags: 1026))
        try write(apps.appendingPathComponent("appmanifest_bad.acf"), "not a record")
        try write(apps.appendingPathComponent("appmanifest_4444.acf"), record(4444, "Escape", "../x", flags: 4))

        let found = MadeiraDock.games(drive: drive)
        require(found.map(\.id) == [4242, 4343], "Dock's discovery finds the valid records, sorted by name: \(found.map(\.id))")
        let first = found.first { $0.id == 4242 }
        require(first?.installed == true && first?.installDir == "Fixture Game" && first?.library == "Program Files (x86)/Steam/steamapps",
                "a fully installed game (StateFlags 4) in Madeira's Steam library")
        require(found.first { $0.id == 4343 }?.installed == false, "an update in progress is not offered for Play")
        require(first?.windowsInstallPath == "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Fixture Game", "Windows install path")
        // The size a Game details page shows comes from the install record.
        try write(apps.appendingPathComponent("appmanifest_4545.acf"),
                  record(4545, "Sized", "Sized", flags: 4).replacingOccurrences(of: "\n}\n", with: "\n\t\"SizeOnDisk\"\t\t\"12345\"\n}\n"))
        require(SteamInstallFiles.sizeOnDisk(appID: 4545, steamApps: apps) == 12345 &&
                SteamInstallFiles.sizeOnDisk(appID: 4242, steamApps: apps) == nil, "install size from the record's SizeOnDisk")
        try fm.removeItem(at: apps.appendingPathComponent("appmanifest_4545.acf"))

        require(R.showsSection(dock: true, signedIn: false, count: 2), "section shown with Dock and games")
        require(!R.showsSection(dock: false, signedIn: true, count: 2), "no section without Dock (MADEIRA_DOCK=0 or no host)")
        require(!R.showsSection(dock: true, signedIn: false, count: 0), "no empty section without a sign-in")
        require(R.showsSection(dock: true, signedIn: true, count: 0), "signed in: the section shows while the library loads")
        require(R.showsSection(dock: true, library: true, signedIn: false, count: 0), "owned library on, signed out: the section shows to invite a sign-in")
        require(!R.showsSection(dock: false, library: true, signedIn: false, count: 0), "no section without Dock even with the library on")
        require(R.showsSignIn(library: true, signedIn: false) && !R.showsSignIn(library: true, signedIn: true)
                && !R.showsSignIn(library: false, signedIn: false), "the sign-in card shows only when the owned library is on and signed out")
        require(R.items(installed: found, owned: [], search: "").count == 2 && R.items(installed: found, owned: [], search: "  ").count == 2,
                "empty search shows all")
        require(R.items(installed: found, owned: [], search: "second").map(\.id) == [4343], "search is case-insensitive on the name")
        require(R.items(installed: found, owned: [], search: "nothing").isEmpty, "search without a match")

        // Owned games (from the account) merged with what Steam installed.
        func own(_ id: Int, _ name: String, build: Int = 100, extra: String = "") -> SteamOwnedGame {
            let vdf = "\"appinfo\" { \"common\" { \"name\" \"\(name)\" \"type\" \"Game\" \"oslist\" \"windows\" \(extra) } " +
                "\"config\" { \"installdir\" \"\(name)\" } " +
                "\"depots\" { \"\(id + 1)\" { \"manifests\" { \"public\" { \"gid\" \"77\" \"download\" \"5\" } } } " +
                "\"branches\" { \"public\" { \"buildid\" \"\(build)\" } } } }"
            return SteamOwnedGame(SteamAppInfo.parse(appID: UInt32(id), from: Data(vdf.utf8))!)
        }
        let owned = [own(4242, "Fixture Game"), own(5001, "Beta"), own(5000, "Alpha"), own(5002, "Gamma")]
        let merged = R.items(installed: found, owned: owned, search: "")
        require(merged.map(\.id) == [4242, 4343, 5000, 5001, 5002], "installed games first, then owned ones, each by name: \(merged.map(\.id))")
        require(merged.first { $0.id == 4242 }.map { $0.installed != nil && $0.owned != nil } == true, "a game both installed and owned is one item")
        require(merged.first { $0.id == 4343 }.map { $0.installed != nil && $0.owned == nil && $0.name == "Second Fixture" } == true,
                "an installed game the account does not list keeps its install record's name")
        require(R.items(installed: found, owned: owned, search: "ALPHA").map(\.id) == [5000], "search covers owned games, without case")
        require(R.items(installed: [], owned: [], search: "").isEmpty, "nothing installed and nothing owned: no items")

        let ready = found[0], partial = found[1]
        require(R.status(installed: nil, transfer: nil, updateAvailable: false) == .notInstalled, "owned only: not installed")
        require(R.status(installed: partial, transfer: nil, updateAvailable: false) == .partlyInstalled, "an unfinished record is not playable")
        require(R.status(installed: ready, transfer: nil, updateAvailable: false) == .installed, "installed")
        require(R.canOpenInstalledGame(ready, hasTransfer: false), "completed install can open its details")
        require(!R.canOpenInstalledGame(ready, hasTransfer: true), "pending update keeps pause/resume controls instead of Open")
        require(!R.canOpenInstalledGame(partial, hasTransfer: false) && !R.canOpenInstalledGame(partial, hasTransfer: true),
                "rediscovered partial install keeps Install/Resume controls with or without an active transfer")
        require(R.status(installed: ready, transfer: nil, updateAvailable: true) == .updateAvailable, "installed with a newer build")
        require(R.status(installed: ready, transfer: .active(percent: 250), updateAvailable: true) == .downloading(100), "a download wins over the record; percent is clamped")
        require(R.status(installed: nil, transfer: .paused, updateAvailable: false).badge == "Paused", "paused pill")
        require(R.status(installed: nil, transfer: .queued, updateAvailable: false).badge == "Waiting", "queued pill")
        require(R.status(installed: nil, transfer: .failed, updateAvailable: false) == .failed, "failed")
        require(R.status(installed: nil, transfer: .active(percent: 42), updateAvailable: false).badge == "Downloading 42%", "progress pill")
        // A card's pills: an installed game shows a library game's (bits, graphics API, size), no state pill.
        let states: [R.Status] = [.notInstalled, .partlyInstalled, .installed, .updateAvailable, .queued, .downloading(42), .paused, .failed]
        require(states.map(\.badge) == ["Not installed", "Not fully installed", nil, "Update", "Waiting", "Downloading 42%", "Paused", "Download failed"],
                "card pills: none for an installed game (no \"Madeira Dock\" or \"Steam\"), \"Update\" for a newer build, the other states unchanged")
        require(states.filter(\.showsFormat) == [.installed, .updateAvailable],
                "only an installed game (with or without a newer build) shows the library pills")

        // The library's sections (check-library-sections.py): downloading and installed games under
        // the Steam title, the account's other games under Not installed, each in the items' order.
        let groups = R.groups(merged, downloading: [5001, 4242])
        require(groups.downloading.map(\.id) == [5001] && groups.installed.map(\.id) == [4242, 4343]
                && groups.notInstalled.map(\.id) == [5000, 5002],
                "groups: a download without an install record, installed games (updating too), not installed: \([groups.downloading, groups.installed, groups.notInstalled].map { $0.map(\.id) })")
        require(R.groups([], downloading: [1]) == R.Groups(), "no items: empty groups")
        // Installed games follow the library's Sort by, from their library entries.
        let a = R.Item(id: 1, name: "Bravo", installed: ready, owned: nil)
        let b = R.Item(id: 2, name: "alpha", installed: ready, owned: nil)
        let c = R.Item(id: 3, name: "Charlie", installed: ready, owned: nil)
        let now = Date()
        let recorded: [Int: R.Recorded] = [
            1: .init(lastPlayed: now.addingTimeInterval(-60), bytes: 10, position: 0),
            3: .init(lastPlayed: now, bytes: 30, position: 4)]
        func order(_ sort: String) -> [Int] { R.sorted([a, b, c], by: sort, recorded: recorded).map(\.id) }
        require(order("name") == [2, 1, 3], "sort by name, without case: \(order("name"))")
        require(order("played") == [3, 1, 2], "sort by last played; never played last, by name: \(order("played"))")
        require(order("size") == [3, 1, 2], "sort by size; unknown size last: \(order("size"))")
        require(order("added") == [3, 1, 2], "sort by recently added; no library entry last: \(order("added"))")
        require(R.sorted([c, a, b], by: "played", recorded: [:]).map(\.id) == [2, 1, 3], "no entries: by name")

        // The build an update compares with comes from the game's owned build.
        require(owned[0].buildID == 100 && owned[0].installDir == "Fixture Game" && owned[0].folderName == "Fixture Game",
                "the owned game carries the PICS build and install folder")

        require(R.blocker(installed: true, client: true, signedIn: true) == nil, "Play offered when installed, client ready, signed in")
        require(R.blocker(installed: false, client: true, signedIn: true)?.contains("fully installed") == true, "not installed first")
        require(R.blocker(installed: true, client: false, signedIn: true)?.contains("client components") == true, "client components next")
        require(R.blocker(installed: true, client: true, signedIn: false)?.contains("Sign in") == true, "sign-in last")
        require(R.blocker(installed: true, client: true, signedIn: true, updating: true)?.contains("downloaded") == true,
                "no Play while the game is being downloaded")

        let cover = R.cover(4242)
        require(cover?.scheme == "https" && cover?.host == "cdn.cloudflare.steamstatic.com" && cover?.path.contains("/4242/") == true,
                "artwork from Steam's public store CDN by App ID")
        require(R.cover(0) == nil, "no artwork URL for an invalid App ID")

        // Artwork candidates: PICS capsule, legacy path, a demo's full game, header image.
        let art = own(6000, "Artful", extra: "\"library_assets_full\" { \"library_capsule\" { \"image\" { \"english\" \"abc123/library_capsule.jpg\" } } } " +
                                            "\"header_image\" { \"english\" \"def456/header.jpg\" } \"parent\" \"6100\"")
        let urls = R.artwork(appID: 6000) { $0 == 6000 ? art : nil }
        require(urls.map(\.absoluteString) == [
            "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/6000/abc123/library_capsule.jpg",
            "https://cdn.cloudflare.steamstatic.com/steam/apps/6000/library_600x900.jpg",
            "https://cdn.cloudflare.steamstatic.com/steam/apps/6100/library_600x900.jpg",
            "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/6000/def456/header.jpg"], "artwork candidates in order: \(urls)")
        require(R.artwork(appID: 7) { _ in nil }.map(\.absoluteString) == ["https://cdn.cloudflare.steamstatic.com/steam/apps/7/library_600x900.jpg"],
                "unknown game: the legacy path only")
        require(R.safeAssetName("a1/b2.jpg") && !R.safeAssetName("../x") && !R.safeAssetName("/x") && !R.safeAssetName("a b") &&
                !R.safeAssetName("a?b=c") && !R.safeAssetName("a#b") && !R.safeAssetName("") && !R.safeAssetName("caf\u{e9}.jpg"),
                "artwork names are plain relative paths")
        // "Start with: The game": Steam's launch configuration names the program (SteamDirectStart).
        typealias D = SteamDirectStart
        let launchVDF = "\"appinfo\" { \"common\" { \"name\" \"Direct\" \"type\" \"Game\" \"oslist\" \"windows\" } " +
            "\"config\" { \"installdir\" \"Direct\" \"launch\" { " +
            "\"3\" { \"executable\" \"Bin64\\\\Game.exe\" \"arguments\" \" -dx11 -skipintro \" \"type\" \"default\" \"config\" { \"oslist\" \"windows\" \"osarch\" \"64\" } } " +
            "\"0\" { \"executable\" \"bin32\\game.exe\" \"type\" \"default\" \"config\" { \"oslist\" \"windows\" \"osarch\" \"32\" } } " +
            "\"1\" { \"executable\" \"server/srv.exe\" \"type\" \"server\" } " +
            "\"2\" { \"executable\" \"Direct.app\" \"config\" { \"oslist\" \"macos\" } } " +
            "\"4\" { \"executable\" \"beta/game.exe\" \"config\" { \"betakey\" \"public-beta\" } } " +
            "\"5\" { \"executable\" \"..\\escape.exe\" \"type\" \"default\" } " +
            "\"6\" { \"executable\" \"tools/launcher.exe\" \"workingdir\" \"Missing\" \"type\" \"option1\" \"config\" { \"osarch\" \"64\" } } " +
            "\"7\" { \"executable\" \"tools/launcher.exe\" \"workingdir\" \"DATA\" \"type\" \"option2\" } " +
            "\"x\" { \"executable\" \"not-numbered.exe\" } \"8\" { \"arguments\" \"-no-program\" } " +
            "} } \"depots\" { \"77\" { \"manifests\" { \"public\" { \"gid\" \"1\" } } } } }"
        let directInfo = SteamAppInfo.parse(appID: 7000, from: Data(launchVDF.utf8))!
        require(directInfo.launches.map(\.executable) == ["bin32\\game.exe", "server/srv.exe", "Direct.app", "Bin64\\Game.exe",
                                                          "beta/game.exe", "..\\escape.exe", "tools/launcher.exe", "tools/launcher.exe"],
                "config.launch is read in Steam's numeric order, without entries that name no program: \(directInfo.launches.map(\.executable))")
        require(directInfo.launches[1].type == "server" && directInfo.launches[4].betaKey == "public-beta" &&
                directInfo.launches[2].oslist == "macos" && directInfo.launches[3].osarch == "64",
                "each entry keeps its type, platform, architecture and beta branch")
        require(SteamOwnedGame(directInfo).launches == directInfo.launches, "the owned library caches the launch configuration")
        let oldCache = #"{"id":1,"name":"Old","installDir":"Old","buildID":1}"#
        require((try? JSONDecoder().decode(SteamOwnedGame.self, from: Data(oldCache.utf8)))?.launches == nil,
                "an older cache without it still loads (the configuration is then asked of Steam once)")
        var many = [String: Any]()
        for i in 0..<40 { many[String(i)] = ["executable": "g\(i).exe"] }
        many["41"] = ["executable": String(repeating: "a", count: 600)]
        require(SteamLaunchOption.parse(many).count == 32, "at most 32 entries are read")
        require(SteamLaunchOption.parse(["0": ["executable": "g.exe", "arguments": String(repeating: "a", count: 3000)]]).isEmpty,
                "oversized text drops the entry")

        require(D.relativePath("Bin64\\\\Game.exe") == "Bin64/Game.exe" && D.relativePath(".\\bin\\game.exe") == "bin/game.exe" &&
                D.relativePath("") == "" && D.relativePath(".") == "", "Steam's paths in slash form")
        for bad in ["C:\\game.exe", "/abs/game.exe", "\\abs\\game.exe", "a/../b.exe", "..", "a\u{1}b.exe", "a|b.exe", "a:b"] {
            require(D.relativePath(bad) == nil, "not a path inside the install folder: \(bad.debugDescription)")
        }

        let install = drive.appendingPathComponent("Program Files (x86)/Steam/steamapps/common/Direct")
        for file in ["bin64/game.exe", "bin32/game.exe", "server/srv.exe", "beta/game.exe", "tools/launcher.exe", "data/readme.txt",
                     "Direct.app", "notes.txt", "deep/1/2/3/4/5/6/7/too-deep.exe"] {
            try write(install.appendingPathComponent(file), "x")
        }
        try write(drive.appendingPathComponent("Program Files (x86)/Steam/steamapps/common/escape.exe"), "x")
        try fm.createSymbolicLink(at: install.appendingPathComponent("loop"), withDestinationURL: install)
        let options = directInfo.launches
        let sparse = SteamLaunchOption.parse([
            "1": ["executable": "tools/launcher.exe", "type": "default"],
            "7": ["executable": "tools/launcher.exe", "config": ["ownsdlc": "17"]],
        ])
        require(sparse.map(\.index) == [1, 7] && D.choose(sparse, installFolder: install)?.launchIndex == 1,
                "a launch table without zero keeps its original keys, not array offsets")
        require(D.choose(Array(sparse.suffix(1)), installFolder: install) == nil, "DLC-only entries are not the game")
        require(SteamLaunchOption.parse(["-1": ["executable": "g.exe"], "2147483648": ["executable": "g.exe"]]).isEmpty,
                "negative and oversized launch keys are rejected")
        let legacyLaunch = try JSONDecoder().decode(SteamLaunchOption.self,
            from: Data(#"{"executable":"g.exe","arguments":"","workingDir":"","type":"","oslist":"","osarch":"","betaKey":""}"#.utf8))
        require(legacyLaunch.index == nil && legacyLaunch.requiredDLC == nil, "older launch caches load without inventing a zero key")
        require(D.choose(options, installFolder: install) == D.Choice(program: "bin64/game.exe", arguments: "-dx11 -skipintro", folder: nil, launchIndex: 3),
                "Steam's 64-bit default entry, found without case, with its arguments: \(String(describing: D.choose(options, installFolder: install)))")
        try fm.removeItem(at: install.appendingPathComponent("bin64"))
        require(D.choose(options, installFolder: install) == D.Choice(program: "bin32/game.exe", arguments: "", folder: nil, launchIndex: 0),
                "its program missing: the next default entry (32-bit); never the server, macOS, beta or escaping entries")
        try fm.removeItem(at: install.appendingPathComponent("bin32"))
        require(D.choose(options, installFolder: install) == D.Choice(program: "tools/launcher.exe", arguments: "", folder: "data", launchIndex: 7),
                "then the other options in Steam's order; one whose working folder is missing is passed over")
        require(D.choose(Array(options.prefix(6)), installFolder: install) == nil, "nothing that runs here: no choice (the Program picker decides)")
        require(D.choose([SteamLaunchOption(executable: "tools/launcher.exe", workingDir: ".")], installFolder: install)?.folder == "",
                "working folder \".\" is the install folder")
        require(D.choose([SteamLaunchOption(executable: "Direct.app")], installFolder: install) == nil, "only Windows programs")
        require(D.choose([SteamLaunchOption(executable: "loop/tools/launcher.exe")], installFolder: install)?.program == "loop/tools/launcher.exe",
                "a program is found through a link that stays inside the install folder")
        require(D.onDisk("..", in: install, directory: true) == nil && D.onDisk("x/../../escape.exe", in: install, directory: false) == nil,
                "never outside the install folder")
        let programs = D.programs(in: install)
        require(programs == ["beta/game.exe", "server/srv.exe", "tools/launcher.exe"],
                "the Program picker lists the folder's .exe files, sorted, not through linked folders or deeper than six: \(programs)")
        // The card's bits and graphics API describe the program "The game" would start.
        require(D.program(picked: "SERVER/srv.EXE", options: options, installFolder: install) == "server/srv.exe",
                "pills: the user's picked program first, spelt as on disk")
        require(D.program(picked: "gone.exe", options: options, installFolder: install) == "tools/launcher.exe" &&
                D.program(picked: nil, options: options, installFolder: install) == "tools/launcher.exe",
                "pills: else the program of Steam's launch configuration")
        require(D.program(picked: nil, options: nil, installFolder: install) == nil &&
                D.program(picked: nil, options: [], installFolder: install) == nil &&
                D.program(picked: nil, options: Array(options.prefix(6)), installFolder: install) == nil,
                "pills: several programs and no usable launch configuration: unknown (only the size), never guessed from names")
        let single = drive.appendingPathComponent("Program Files (x86)/Steam/steamapps/common/Single")
        try write(single.appendingPathComponent("bin/only.exe"), "x")
        try write(single.appendingPathComponent("readme.txt"), "x")
        require(D.program(picked: nil, options: nil, installFolder: single) == "bin/only.exe", "pills: else the install folder's only program")
        require(D.program(picked: "../Direct/tools/launcher.exe", options: nil, installFolder: single) == "bin/only.exe",
                "pills: a picked program never leaves the install folder")
        require(D.blocker(installed: false, program: "a.exe")?.contains("fully installed") == true &&
                D.blocker(installed: true, program: "a.exe", updating: true)?.contains("downloaded") == true &&
                D.blocker(installed: true, program: nil)?.contains("Program") == true &&
                D.blocker(installed: true, program: "") != nil && D.blocker(installed: true, program: "a.exe") == nil,
                "Play for \"The game\": installed, not updating, a program chosen; no client or sign-in needed")
        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all Steam games Swift checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-steam-games-') as tmp:
    tmp = Path(tmp)
    (tmp / 'stubs.swift').write_text(stubs + head)
    (tmp / 'dock.swift').write_text(('import Foundation\n#if canImport(Glibc)\nimport Glibc\n#else\nimport Darwin\n#endif\n'
        '#if canImport(Network)\nimport Network\n#else\n'
        '/* Linux: no Network framework; DockOffline only needs these names. */\n'
        'final class NWPathMonitor { struct Path { enum Status { case satisfied, unsatisfied, requiresConnection }; '
        'var status = Status.satisfied }; var currentPath = Path(); func start(queue: DispatchQueue) {} }\n#endif\n') + body)
    (tmp / 'rules.swift').write_text('import Foundation\n' + rules)
    (tmp / 'owned.swift').write_text('import Foundation\n' + owned_game + '\n' + vdf)
    (tmp / 'checks.swift').write_text(checks)
    exe = tmp / 'check'
    build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-o', str(exe),
                            str(tmp / 'stubs.swift'), str(tmp / 'dock.swift'), str(tmp / 'rules.swift'),
                            str(tmp / 'checks.swift'), str(tmp / 'owned.swift'), str(app / 'SteamKeyValues.swift'),
                            str(app / 'SteamInstall.swift'), str(app / 'SteamStorage.swift'), str(app / 'SwiftSteam/Library/SteamAppInfo.swift')],
                           capture_output=True, text=True)
    require(build.returncode == 0, 'production Steam games rules and Dock discovery compile on the host')
    if build.returncode:
        sys.stdout.write(build.stderr[-4000:])
    else:
        run = subprocess.run([str(exe)], env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'), capture_output=True, text=True)
        sys.stdout.write(run.stdout)
        if run.returncode:
            sys.stdout.write(run.stderr[-4000:])
        require(run.returncode == 0, 'Steam games checks pass under AddressSanitizer')

if failures:
    print(f'check-steam-games: {failures} FAILED')
    sys.exit(1)
print('check-steam-games: PASS')
