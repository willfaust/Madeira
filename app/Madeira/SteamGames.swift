// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

// Steam games in the library (docs/LIBRARY.md, "Steam setup", and
// docs/STEAM_LIBRARY.md): the games Steam has installed in the prefix, which is
// Madeira Dock's own discovery (MadeiraDock.games: Steam's
// appmanifest_<appid>.acf records in the client's library and the other C:
// libraries its libraryfolders.vdf lists), and the account's owned games that
// are not installed yet (SteamOwnedLibrary), which can be installed here.
// Play starts an installed game through Madeira Dock's launch path
// (ContentView.startDock), so Valve's own client signs in, checks the licence
// and starts it. No program names are involved: a game is its App ID.
// Log tag: [steam-games] (App IDs and counts only).

// MARK: - Rules (Foundation only; tests/host/check-onboarding.py compiles this part)

enum SteamGamesRules {
    /// One game of the section: installed by Steam, owned by the account, or both.
    struct Item: Identifiable, Equatable {
        let id: Int
        var name: String
        var installed: DockGame?
        var owned: SteamOwnedGame?
    }

    /// What a game's card says about it.
    enum Status: Equatable {
        case notInstalled, partlyInstalled, installed, updateAvailable
        case queued, downloading(Int), paused, failed

        /// The card's state pill, or nil for an installed game: its card shows only
        /// the pills of any library game (32-bit or 64-bit, graphics API, install
        /// size), and a newer build adds "Update" to them.
        var badge: String? {
            switch self {
            case .notInstalled: return "Not installed"
            case .partlyInstalled: return "Not fully installed"
            case .installed: return nil
            case .updateAvailable: return "Update"
            case .queued: return "Waiting"
            case .downloading(let percent): return "Downloading \(percent)%"
            case .paused: return "Paused"
            case .failed: return "Download failed"
            }
        }

        /// Whether the card shows the installed game's library pills.
        var showsFormat: Bool { self == .installed || self == .updateAvailable }
    }

    /// A download's state, as far as the status needs it.
    enum Transfer: Equatable { case queued, active(percent: Int), paused, failed }

    static func status(installed: DockGame?, transfer: Transfer?, updateAvailable: Bool) -> Status {
        if let transfer {
            switch transfer {
            case .queued: return .queued
            case .active(let percent): return .downloading(max(0, min(100, percent)))
            case .paused: return .paused
            case .failed: return .failed
            }
        }
        guard let installed else { return .notInstalled }
        if !installed.installed { return .partlyInstalled }
        return updateAvailable ? .updateAvailable : .installed
    }

    /// The games of both lists by App ID, installed ones first (each group by
    /// name), filtered by the library's search text. A game Steam installed
    /// but the account does not list (or that is listed before the library
    /// loaded) keeps the name of its install record.
    static func items(installed: [DockGame], owned: [SteamOwnedGame], search: String) -> [Item] {
        var byID: [Int: Item] = [:]
        for game in owned { byID[game.id] = Item(id: game.id, name: game.name, installed: nil, owned: game) }
        for game in installed {
            if var item = byID[game.id] { item.installed = game; byID[game.id] = item }
            else { byID[game.id] = Item(id: game.id, name: game.name, installed: game, owned: nil) }
        }
        let text = search.trimmingCharacters(in: .whitespaces)
        let all = byID.values.filter { text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) }
        return all.sorted {
            let a = $0.installed != nil, b = $1.installed != nil
            if a != b { return a }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// The Steam section's groups, as in the fork's sectioned library: games
    /// being downloaded that Steam has no install record for yet, the games
    /// Steam has installed (both listed under the section's title), and the
    /// account's other games (its "Not installed" group). Each keeps `items`'
    /// order.
    struct Groups: Equatable {
        var downloading: [Item] = []
        var installed: [Item] = []
        var notInstalled: [Item] = []
    }

    static func groups(_ items: [Item], downloading: Set<Int>) -> Groups {
        var groups = Groups()
        for item in items {
            if item.installed != nil { groups.installed.append(item) }
            else if downloading.contains(item.id) { groups.downloading.append(item) }
            else { groups.notInstalled.append(item) }
        }
        return groups
    }

    /// What a game's library entry records, for the library's Sort by menu:
    /// when Madeira last started it, its size, and its place in the library.
    struct Recorded: Equatable {
        var lastPlayed: Date?
        var bytes: Int64?
        var position: Int
    }

    /// Installed games in the library's Sort by order ("played", "name",
    /// "added" or "size"), compared as the library compares the games you
    /// added. A game without a library entry yet (never opened, or installed
    /// by Steam's client) sorts as never played, of unknown size and, for
    /// "added", after the games that have one; ties go by name.
    static func sorted(_ items: [Item], by sort: String, recorded: [Int: Recorded]) -> [Item] {
        func byName(_ a: Item, _ b: Item) -> Bool {
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
        return items.sorted { a, b in
            let ra = recorded[a.id], rb = recorded[b.id]
            switch sort {
            case "added":
                if ra?.position != rb?.position { return (ra?.position ?? -1) > (rb?.position ?? -1) }
            case "played":
                if ra?.lastPlayed != rb?.lastPlayed { return (ra?.lastPlayed ?? .distantPast) > (rb?.lastPlayed ?? .distantPast) }
            case "size":
                if ra?.bytes != rb?.bytes { return (ra?.bytes ?? -1) > (rb?.bytes ?? -1) }
            default:
                break
            }
            return byName(a, b)
        }
    }

    /// Whether the library shows the Steam section: Dock is available, and there is
    /// a game to show, a sign-in whose library is on its way, or (with the owned
    /// library on) a signed-out account the section invites to sign in.
    static func showsSection(dock: Bool, library: Bool = false, signedIn: Bool, count: Int) -> Bool {
        dock && (count > 0 || signedIn || library)
    }

    /// Whether the section shows its "Sign in to Steam" card instead of the account's games.
    static func showsSignIn(library: Bool, signedIn: Bool) -> Bool { library && !signedIn }

    /// Why Play is not offered yet, or nil when Dock can be asked to start the game.
    /// Valve's client still decides at launch.
    static func blocker(installed: Bool, client: Bool, signedIn: Bool, updating: Bool = false) -> String? {
        if !installed { return "Steam does not list this game as fully installed yet." }
        if updating { return "This game is being downloaded. Play is available when it is done." }
        if !client { return "Madeira Dock needs Valve's client components. Download them in Settings › Steam › Madeira Dock." }
        if !signedIn { return "Sign in to Steam in Settings › Steam to play." }
        return nil
    }

    /// Steam's public store artwork for an App ID (no account data).
    static func cover(_ appID: Int) -> URL? {
        guard appID > 0 else { return nil }
        return URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_600x900.jpg")
    }

    static let assetBase = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/"

    /// A store artwork file name is a relative path of plain characters.
    static func safeAssetName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 256 && !name.hasPrefix("/") && !name.contains("..") &&
            name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)) }
    }

    /// Artwork candidates for an App ID, in order: the capsule named in the
    /// game's product info (newer apps publish it only under a hashed folder),
    /// the legacy path, the same for a demo's full game, then the header image.
    /// A card tries them one after another.
    static func artwork(appID: Int, owned: (Int) -> SteamOwnedGame?) -> [URL] {
        var urls: [URL] = []
        func add(_ url: URL?) { if let url, !urls.contains(url) { urls.append(url) } }
        func asset(_ id: Int, _ name: String?) -> URL? {
            guard let name, safeAssetName(name) else { return nil }
            return URL(string: assetBase + "\(id)/" + name)
        }
        func direct(_ id: Int) {
            add(asset(id, owned(id)?.libraryCapsule))
            add(cover(id))
        }
        direct(appID)
        if let parent = owned(appID)?.parentID, parent != appID { direct(parent) }
        add(asset(appID, owned(appID)?.headerImage))
        return urls
    }
}

/// "Start with: The game" on a Steam game's Game details page: the game's own
/// program runs in Wine without Steam, which suits games that do not need Steam
/// (DRM-free ones). Which program is Steam's own launch configuration for the app
/// (its product info's `config.launch`), never a list of program names; when that
/// names nothing that can run here, the user picks one of the install folder's
/// programs. Madeira Dock stays the default.
enum SteamDirectStart {
    /// LibraryEntry.steamStart for this start; nil there is Madeira Dock.
    static let mode = "game"

    /// What "The game" starts: the program, relative to the install folder and
    /// spelt as on disk, its arguments, and its working folder (nil: the program's
    /// own folder; "": the install folder).
    struct Choice: Equatable {
        var program: String
        var arguments: String
        var folder: String?
        var launchIndex: UInt32? = nil
    }

    /// Launch types Steam gives entries that are not the game itself.
    static let otherKinds: Set<String> = ["server", "editor", "vr", "othervr", "openvroverlay", "osvr", "manual"]

    /// A path from Steam's launch configuration in slash form (bin/game.exe), or nil
    /// for anything that could leave the install folder or is not a plain name: an
    /// absolute path, a drive, "..", a control or reserved character. "." parts go.
    static func relativePath(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        guard !text.hasPrefix("/"), text.utf8.count <= 512,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || "<>:\"|?*".unicodeScalars.contains($0) }) else { return nil }
        var parts: [Substring] = []
        for part in text.split(separator: "/") where part != "." {
            if part == ".." { return nil }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    /// `relative` found under `root` one name at a time, exactly or else without case
    /// (as Windows finds it): its spelling on disk, or nil when a name is missing, the
    /// last one is not of the kind asked for, or the result leaves `root`.
    static func onDisk(_ relative: String, in root: URL, directory: Bool) -> String? {
        let fm = FileManager.default
        var url = root
        var spelled: [String] = []
        for part in relative.split(separator: "/").map(String.init) {
            guard let names = try? fm.contentsOfDirectory(atPath: url.path),
                  let name = names.first(where: { $0 == part }) ?? names.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame })
            else { return nil }
            url.appendPathComponent(name)
            spelled.append(name)
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue == directory else { return nil }
        let base = root.resolvingSymlinksInPath().path
        let target = url.resolvingSymlinksInPath().path
        guard target == base ? directory : target.hasPrefix(base + "/") else { return nil }
        return spelled.joined(separator: "/")
    }

    /// The launch entry "The game" starts. Candidates are the Windows entries (no
    /// platform list, or one naming Windows) outside beta branches and of a kind that is
    /// the game itself; Steam's default comes first ("default", then no type or "none",
    /// then the other options), each in Steam's order with a 64-bit entry before one
    /// for any architecture before a 32-bit one. The first candidate whose program is a
    /// Windows program (.exe) inside the install folder, and whose working folder (when
    /// it names one) exists there, is taken.
    static func choose(_ options: [SteamLaunchOption], installFolder root: URL) -> Choice? {
        func rank(_ option: SteamLaunchOption) -> Int? {
            let type = option.type.lowercased()
            guard option.betaKey.isEmpty, !otherKinds.contains(type),
                  option.requiredDLC == nil || option.requiredDLC == "" || option.requiredDLC == "0",
                  option.oslist.isEmpty || option.oslist.lowercased().contains("windows") else { return nil }
            let kind: Int
            if type == "default" { kind = 0 } else if type.isEmpty || type == "none" { kind = 1 } else { kind = 2 }
            let arch: Int
            if option.osarch == "64" { arch = 0 } else if option.osarch.isEmpty { arch = 1 } else { arch = 2 }
            return kind * 3 + arch
        }
        var ranked: [(rank: Int, index: Int, option: SteamLaunchOption)] = []
        for (index, option) in options.enumerated() {
            if let value = rank(option) { ranked.append((rank: value, index: index, option: option)) }
        }
        ranked.sort { a, b in a.rank != b.rank ? a.rank < b.rank : a.index < b.index }
        let spaces = CharacterSet.whitespaces
        for entry in ranked {
            let option = entry.option
            guard let path = relativePath(option.executable), !path.isEmpty,
                  URL(fileURLWithPath: path).pathExtension.lowercased() == "exe",
                  let program = onDisk(path, in: root, directory: false) else { continue }
            var folder: String? = nil
            if !option.workingDir.trimmingCharacters(in: spaces).isEmpty {
                guard let relative = relativePath(option.workingDir) else { continue }
                if relative.isEmpty {
                    folder = ""
                } else {
                    guard let found = onDisk(relative, in: root, directory: true) else { continue }
                    folder = found
                }
            }
            return Choice(program: program, arguments: option.arguments.trimmingCharacters(in: spaces), folder: folder,
                          launchIndex: option.index)
        }
        return nil
    }

    /// The install folder's Windows programs for the Program picker: every .exe up to
    /// six folders deep (linked folders are not followed), at most 400, sorted.
    static func programs(in root: URL) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        func walk(_ url: URL, _ prefix: String, _ depth: Int) {
            guard depth <= 6, let names = try? fm.contentsOfDirectory(atPath: url.path) else { return }
            for name in names.sorted() where !name.hasPrefix(".") && found.count < 400 {
                let child = url.appendingPathComponent(name)
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: child.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    if (try? fm.destinationOfSymbolicLink(atPath: child.path)) == nil { walk(child, relative, depth + 1) }
                } else if child.pathExtension.lowercased() == "exe" {
                    found.append(relative)
                }
            }
        }
        walk(root, "", 0)
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The program a Steam game's library pills describe (32-bit or 64-bit, graphics
    /// API), found as "The game" finds it: the user's pick while it is installed, else
    /// Steam's launch configuration, else the install folder's only program; nil when
    /// none is known (the card then shows only the install size).
    static func program(picked: String?, options: [SteamLaunchOption]?, installFolder root: URL) -> String? {
        if let picked, !picked.isEmpty, let found = onDisk(picked, in: root, directory: false) { return found }
        if let options, let choice = choose(options, installFolder: root) { return choice.program }
        let found = programs(in: root)
        return found.count == 1 ? found[0] : nil
    }

    /// Why Play is not offered for "The game" yet, or nil. No Steam client or sign-in
    /// is involved; the game's own program must be chosen.
    static func blocker(installed: Bool, program: String?, updating: Bool = false) -> String? {
        if !installed { return "Steam does not list this game as fully installed yet." }
        if updating { return "This game is being downloaded. Play is available when it is done." }
        if (program ?? "").isEmpty { return "Choose the program to start in Game details › Steam › Program." }
        return nil
    }
}

// MARK: - Model

/// The games Steam has installed in the prefix (Dock's discovery, off the main
/// thread), with the build each Madeira-managed install records.
@MainActor final class SteamGamesModel: ObservableObject {
    static let shared = SteamGamesModel()
    @Published private(set) var games: [DockGame] = []
    /// `buildid` of each install in Madeira's own library folder, by App ID.
    @Published private(set) var builds: [Int: Int] = [:]
    private var scanning = false
    /// A refresh was asked for while a scan ran (an install record was just
    /// written): scan again once it ends.
    private var rescan = false
    private var lastCount = -1

    /// Reads the install records again, off the main thread.
    func refresh() {
        guard MadeiraDock.enabled else { return }
        guard !scanning else { rescan = true; return }
        scanning = true
        let drive = MadeiraDock.drive
        Task.detached(priority: .utility) {
            let found = MadeiraDock.games(drive: drive)
            var builds: [Int: Int] = [:]
            for game in found where SteamInstallPaths.isManaged(library: game.library) && game.installed {
                if let build = SteamInstallFiles.buildID(appID: game.id, steamApps: SteamInstallPaths.steamApps(drive: drive)) {
                    builds[game.id] = build
                }
            }
            let recorded = builds
            await MainActor.run {
                self.scanning = false
                let again = self.rescan
                self.rescan = false
                if self.games != found { self.games = found }
                if self.builds != recorded { self.builds = recorded }
                if found.count != self.lastCount {
                    self.lastCount = found.count
                    LogStore.shared.log("[steam-games] installed=\(found.count) ready=\(found.filter(\.installed).count)")
                }
                if again { self.refresh() }
            }
        }
    }
}

// MARK: - Library section

private struct SteamGameSelection: Identifiable { let id: Int }

/// The library's Steam section, laid out as the fork's sectioned library: under
/// the **Steam** title the games being downloaded and the games Steam has
/// installed in the prefix (the title collapses them), then the account's
/// other games under **Not installed**, which folds on its own. The library's
/// **Other games** section (LibraryView) follows. An installed game opens its
/// Game details page (the library's own, LibraryDetail, with the Steam section
/// below), where Play starts it through Madeira Dock; a game that is not
/// installed opens its download sheet. Cards follow the library's layout, and
/// installed games its Sort by choice. Pull down on the library to read the
/// install records and the account's library again.
struct SteamGamesSection: View {
    /// Which half the library asks for: the installed games under the Steam
    /// title, the Not installed group, or both together (the old layout).
    enum Part { case all, installed, notInstalled }
    let search: String
    /// The library's layout and Sort by choices and its width (LibraryView).
    var layout = "cards"
    var sort = "played"
    var width: CGFloat = 390
    var part: Part = .all
    /// Opens a game's Game details page (LibraryView's details sheet).
    let open: (LibraryEntry) -> Void
    @ObservedObject private var model = SteamGamesModel.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var library = LibraryModel.shared
    @Environment(\.scenePhase) private var scenePhase
    // Collapsed state of the installed games (the Steam title) and of Not installed.
    @AppStorage("madeiraLibraryHideInstalled") private var hideInstalled = false
    @AppStorage("madeiraSteamShowUninstalled") private var showUninstalled = true
    @State private var selected: SteamGameSelection?
    @State private var showSignIn = false

    /// MADEIRA_LIBRARY_COLLAPSE=0: the section titles do not collapse.
    static var collapsible: Bool { MadeiraConfig.flag("MADEIRA_LIBRARY_COLLAPSE") }
    private var libraryEnabled: Bool { SteamOwnedLibrary.enabled }

    /// Whether the library shows this section, and with it the sectioned
    /// layout (the games you added then sit under Other games).
    /// True when the account has installed or downloading games: the library
    /// then shows them first and its own games after; otherwise its own games
    /// come first and the Steam section (sign-in, Not installed) follows.
    @MainActor static var hasInstalled: Bool {
        let library = SteamOwnedLibrary.enabled, account = SteamOwnedLibrary.shared
        let owned = library ? account.owned : []
        let items = SteamGamesRules.items(installed: SteamGamesModel.shared.games, owned: owned, search: "")
        let groups = SteamGamesRules.groups(items, downloading: Set(account.downloads.keys))
        return !groups.installed.isEmpty || !groups.downloading.isEmpty
    }

    @MainActor static var shown: Bool {
        let library = SteamOwnedLibrary.enabled, account = SteamOwnedLibrary.shared
        let owned = library ? account.owned : []
        let total = SteamGamesRules.items(installed: SteamGamesModel.shared.games, owned: owned, search: "").count
        return SteamGamesRules.showsSection(dock: MadeiraDock.enabled, library: library,
                                            signedIn: library && account.signedIn, count: total)
    }

    /// Pull to refresh on the library: the install records again and, when
    /// signed in, the account's library.
    @MainActor static func refresh() async {
        SteamGamesModel.shared.refresh()
        if SteamOwnedLibrary.enabled && SteamOwnedLibrary.shared.signedIn {
            await SteamOwnedLibrary.shared.refreshLibrary(interactive: true)
        }
    }

    /// Sort by data from the Steam games' library entries.
    private var recorded: [Int: SteamGamesRules.Recorded] {
        var result: [Int: SteamGamesRules.Recorded] = [:]
        for (position, entry) in library.entries.enumerated() {
            if let appID = entry.steamAppID {
                result[appID] = SteamGamesRules.Recorded(lastPlayed: entry.lastPlayed, bytes: entry.folderBytes, position: position)
            }
        }
        return result
    }

    var body: some View {
        let owned = libraryEnabled ? steam.owned : []
        let signedIn = libraryEnabled && steam.signedIn
        let items = SteamGamesRules.items(installed: model.games, owned: owned, search: search)
        let groups = SteamGamesRules.groups(items, downloading: Set(steam.downloads.keys))
        let installed = SteamGamesRules.sorted(groups.installed, by: sort, recorded: recorded)
        let collapsible = Self.collapsible
        Group {
            if Self.shown {
                VStack(alignment: .leading, spacing: 14) {
                    if part != .notInstalled {
                    LibrarySectionHeader(title: "Steam", count: installed.count,
                                         collapsed: collapsible ? $hideInstalled : nil) {
                        if steam.refreshing { ProgressView().accessibilityLabel("Refreshing Steam library") }
                    }
                    // Signed out: the account's games need a sign-in; say so here rather
                    // than hiding the section until someone finds Settings › Steam.
                    if SteamGamesRules.showsSignIn(library: libraryEnabled, signedIn: steam.signedIn) {
                        SteamSignInCard { showSignIn = true }
                    }
                    // Saves that differ on the two sides wait for a choice on the game's page.
                    // A line here, not an alert: an alert would close a page that is open.
                    if SteamOwnedLibrary.cloudEnabled, !steam.cloudUndecided.isEmpty {
                        let names = steam.cloudUndecided.compactMap { id in model.games.first { $0.id == id }?.name }
                        Label("Steam Cloud: \(names.joined(separator: ", ")) \(names.count == 1 ? "has" : "have") saves that differ from this device's. Open the game's details to choose which to keep.",
                              systemImage: "exclamationmark.icloud")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if let waiting = steam.cloudWaitingFor {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Syncing \(model.games.first { $0.id == waiting }?.name ?? "the game")'s Steam Cloud saves, then starting it…")
                        }.font(.footnote).foregroundStyle(.secondary)
                    }
                    if hideInstalled && collapsible {
                        EmptyView()
                    } else if !groups.downloading.isEmpty || !installed.isEmpty {
                        LibraryCells(items: groups.downloading + installed, layout: layout, width: width) { item, list, dense in
                            cell(item, list: list, dense: dense)
                        }
                    } else if signedIn && !steam.refreshing && groups.notInstalled.isEmpty && search.isEmpty {
                        Text(steam.libraryUpdated == nil ? "Pull down to load your Steam library."
                             : "No Windows games were found in this Steam library.").foregroundStyle(.secondary)
                    }
                    }
                    if part != .installed && signedIn && !groups.notInstalled.isEmpty {
                        Button {
                            withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) { showUninstalled.toggle() }
                        } label: {
                            HStack {
                                Text("Not installed").font(.headline)
                                Text("\(groups.notInstalled.count)").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                    .rotationEffect(.degrees(showUninstalled ? 90 : 0)).foregroundStyle(.secondary)
                            }.contentShape(Rectangle()).frame(minHeight: 44)
                        }.buttonStyle(.plain)
                            .accessibilityValue(showUninstalled ? "Shown" : "Hidden")
                        if showUninstalled {
                            LibraryCells(items: groups.notInstalled, layout: layout, width: width) { item, list, dense in
                                cell(item, list: list, dense: dense)
                            }
                        }
                    }
                }
            } else {
                // Nothing to show yet: an empty placeholder keeps the scan below running.
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }
        // The library reappears after every session, so this also rereads after a game.
        .onAppear {
            model.refresh()
            if libraryEnabled { steam.start(); steam.reconcileSession() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh(); if libraryEnabled { steam.reconcileSession() } }
        }
        .sheet(item: $selected) { selection in
            SteamGameSheet(appID: selection.id) { entry in
                // Let the download sheet finish dismissing before presenting the details page.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open(entry) }
            }
        }
        .sheet(isPresented: $showSignIn) { SteamSignInView() }
        .alert("Steam", isPresented: Binding(get: { steam.error != nil }, set: { if !$0 { steam.error = nil } })) {
            Button("OK", role: .cancel) { steam.error = nil }
        } message: { Text(steam.error ?? "") }
    }

    private func cell(_ item: SteamGamesRules.Item, list: Bool, dense: Bool) -> some View {
        Button { select(item) } label: { SteamGameCell(item: item, list: list, dense: dense) }
            .libraryCardButtonStyle(grid: !list)
    }

    /// An installed game (by Madeira's download or by Steam's client) opens its
    /// Game details page; any other game opens its download sheet.
    private func select(_ item: SteamGamesRules.Item) {
        if let installed = item.installed {
            open(LibraryModel.shared.steamEntry(installed, title: item.name))
        } else {
            selected = SteamGameSelection(id: item.id)
        }
    }
}

/// The signed-out Steam section's invitation to sign in.
struct SteamSignInCard: View {
    var signIn: () -> Void
    var body: some View {
        Button(action: signIn) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to Steam").font(.headline)
                    Text("See your Steam games here and install them without leaving Madeira.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}

// MARK: - Artwork

/// A game's artwork: its candidates in turn until one loads.
struct SteamGameArtwork: View {
    let appID: Int
    /// A game that is not downloaded: no controller glyph while the artwork loads (the
    /// card draws its download glyph instead), and a soft circle of blur in the middle
    /// of the art for that glyph to sit on.
    var notDownloaded = false
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @State private var index = 0

    var body: some View {
        let urls = SteamGamesRules.artwork(appID: appID) { steam.game($0) }
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .secondarySystemFill)
                if !notDownloaded {
                    Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(.secondary)
                }
                AsyncImage(url: index < urls.count ? urls[index] : nil) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            .overlay { if notDownloaded { SteamArtworkBlurSpot(image: image, size: geometry.size) } }
                    case .failure:
                        Color.clear.onAppear { if index + 1 < urls.count { index += 1 } }
                    default:
                        Color.clear
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .accessibilityHidden(true)
        .task(id: appID) { index = 0 }
    }
}

/// A soft circle of progressive blur in the middle of a game's artwork, under a
/// not-downloaded game's download glyph. There is no variable blur for views, so
/// it stacks copies of the same loaded image, each blurred more and masked to a
/// smaller radial fade: the blur ramps from the centre out to the sharp artwork
/// with no edge. Sizes follow the artwork's shorter side, so a list thumbnail gets
/// the same look as a grid card.
struct SteamArtworkBlurSpot: View {
    let image: Image
    let size: CGSize
    /// (blur radius, fade radius) as fractions of the shorter side, outermost first.
    private static let steps: [(blur: CGFloat, radius: CGFloat)] = [(0.008, 0.55), (0.015, 0.42), (0.025, 0.30)]

    var body: some View {
        let side = min(size.width, size.height)
        ZStack {
            ForEach(Self.steps.indices, id: \.self) { i in
                image.resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
                    .blur(radius: side * Self.steps[i].blur, opaque: true)
                    .mask {
                        RadialGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.85), location: 0.35),
                                               .init(color: .black.opacity(0.35), location: 0.7), .init(color: .clear, location: 1)],
                                       center: .center, startRadius: 0, endRadius: side * Self.steps[i].radius)
                    }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Cards

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}

private extension SteamOwnedLibrary.Download {
    var transfer: SteamGamesRules.Transfer {
        switch state {
        case .queued: return .queued
        case .active: return .active(percent: Int(progress.fraction * 100))
        case .paused: return .paused
        case .failed: return .failed
        }
    }
}

/// A game's card, or its row in the library's list layouts (as the fork's
/// library rows: artwork, name, state and playtime, or the download's progress).
struct SteamGameCell: View {
    let item: SteamGamesRules.Item
    var list = false
    var dense = false
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var games = SteamGamesModel.shared
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        let download = steam.downloads[item.id]
        let status = SteamGamesRules.status(installed: item.installed, transfer: download?.transfer,
                                            updateAvailable: steam.updateAvailable(appID: item.id, installedBuild: games.builds[item.id]))
        // An installed game's format (bits, graphics API, size) is kept on its library entry.
        let entry = library.entries.first { $0.steamAppID == item.id }
        let notDownloaded = item.installed?.installed != true && download == nil
        Group {
            if list && dense {
                // One short row per game.
                HStack(spacing: 10) {
                    SteamGameArtwork(appID: item.id, notDownloaded: notDownloaded).frame(width: 28, height: 42)
                        .overlay { if notDownloaded { notDownloadedFace(.caption) } }
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let download { SteamDownloadStatus(download: download) }
                        else if let summary = steam.playtime[item.id]?.summary {
                            Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    pills(status, entry).fixedSize()
                }.padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            } else if list {
                HStack(spacing: 14) {
                    SteamGameArtwork(appID: item.id, notDownloaded: notDownloaded).frame(width: 48, height: 72)
                        .overlay { overlay(download) }
                        .overlay { if notDownloaded { notDownloadedFace(.title3) } }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.name).font(.headline).lineLimit(2)
                        if let download { SteamDownloadStatus(download: download) } else { pills(status, entry) }
                        if download == nil, let summary = steam.playtime[item.id]?.summary {
                            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    SteamGameArtwork(appID: item.id, notDownloaded: notDownloaded).aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .overlay { overlay(download) }
                        .overlay { if notDownloaded { notDownloadedFace(.largeTitle) } }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .modifier(LibraryCardArtworkPress { pressed, bounds in
                            AmbientGlowItem(id: "steam-\(item.id)", seed: item.id, art: .steam(item.id), dimmed: notDownloaded,
                                            pressed: pressed, bounds: bounds)
                        })
                    Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    pills(status, entry)
                    if let played = steam.playtime[item.id]?.played {
                        Text(played).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.padding(4)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        // Read once per install folder, build and picked program, and again when Steam's
        // launch configuration arrives (LibraryModel.refreshSteamMetadata).
        .task(id: "\(status.showsFormat) \(item.installed?.windowsInstallPath ?? "") \(games.builds[item.id] ?? 0) " +
                  "\(entry?.steamProgram ?? "") \(steam.game(item.id)?.launches != nil)", priority: .utility) {
            if status.showsFormat, let game = item.installed { await library.refreshSteamMetadata(game, title: item.name) }
        }
    }

    /// An installed game shows the pills of any library game (bits, graphics API,
    /// size, and "Update" when a newer build exists); any other state its badge.
    @ViewBuilder private func pills(_ status: SteamGamesRules.Status, _ entry: LibraryEntry?) -> some View {
        if status.showsFormat, let entry {
            LibraryBadges(entry: entry, note: status.badge).foregroundStyle(.secondary)
        } else if let text = status.badge {
            badge(text)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.secondary)
    }

    /// A game that is not downloaded: its artwork dimmed with black, which darkens it
    /// in light and dark mode alike (fading it instead lightened it in light mode and
    /// let the placeholder controller show through the art), under an iCloud-style
    /// download glyph at half opacity. The artwork blurs softly under the glyph
    /// (SteamArtworkBlurSpot).
    private func notDownloadedFace(_ font: Font) -> some View {
        ZStack {
            Color.black.opacity(0.4)
            Image(systemName: "icloud.and.arrow.down").font(font.weight(.medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder private func overlay(_ download: SteamOwnedLibrary.Download?) -> some View {
        if let download {
            ZStack {
                Color.black.opacity(0.45)
                switch download.state {
                case .active:
                    ProgressView(value: download.progress.fraction).progressViewStyle(.circular).tint(.white)
                case .queued: Image(systemName: "clock").font(.title2).foregroundStyle(.white)
                case .paused: Image(systemName: "pause.circle.fill").font(.title).foregroundStyle(.white)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.yellow)
                }
            }
        }
    }
}

/// Progress, speed and the state of one download.
struct SteamDownloadStatus: View {
    let download: SteamOwnedLibrary.Download
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: download.progress.fraction)
            Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
    private var caption: String {
        let p = download.progress
        switch download.state {
        case .queued: return "Waiting to start…"
        case .paused: return p.totalBytes > 0 ? "Paused at \(Int(p.fraction * 100))%" : "Paused"
        case .failed(let message): return message
        case .active:
            switch p.phase {
            case .preparing: return "Preparing download…"
            case .finishing: return "Finishing…"
            case .downloading:
                var parts = ["\(Int(p.fraction * 100))%", "\(formatBytes(Int64(p.doneBytes))) of \(formatBytes(Int64(p.totalBytes)))"]
                if p.bytesPerSecond > 0 {
                    parts.append("\(formatBytes(Int64(p.bytesPerSecond)))/s")
                    let left = Double(p.totalBytes - min(p.doneBytes, p.totalBytes)) / p.bytesPerSecond
                    if left.isFinite, left > 60 { parts.append("about \(Int(left / 60) + 1) min left") }
                }
                return parts.joined(separator: " · ")
            }
        }
    }
}

// MARK: - Download sheet

/// A game the account owns that is not installed: Install, Pause, Resume and
/// Cancel of its download. When the download finishes the sheet's button reads
/// Open, which opens the game's Game details page, where Play starts it.
struct SteamGameSheet: View {
    let appID: Int
    /// Opens the installed game's Game details page (after this sheet closes).
    var open: (LibraryEntry) -> Void
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var games = SteamGamesModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var freeSpace: Int64?
    @State private var partial = false
    @State private var confirmCancel = false

    var body: some View {
        let owned = SteamOwnedLibrary.enabled ? steam.owned : []
        let item = SteamGamesRules.items(installed: games.games, owned: owned, search: "").first { $0.id == appID }
        NavigationStack {
            Form {
                if let item {
                    Section {
                        HStack(spacing: 20) {
                            SteamGameArtwork(appID: appID).frame(width: 120, height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 12) {
                                Text(item.name).font(.title2.bold())
                                if let summary = steam.playtime[appID]?.summary {
                                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                                }
                                primaryAction(item)
                            }
                        }.padding(.vertical, 24)
                            .listRowBackground(
                                SteamGameArtwork(appID: appID).blur(radius: 4)
                                    .overlay(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.55))
                                    .clipped()
                            )
                    }
                    if let download = steam.downloads[appID] {
                        Section("Download") {
                            SteamDownloadStatus(download: download)
                            Button("Cancel download", role: .destructive) { confirmCancel = true }
                            if case .failed = download.state {
                                Text("Downloaded parts are kept. Try again to continue where it stopped.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        if let freeSpace { LabeledContent("Free space on this device", value: formatBytes(freeSpace)) }
                        Text(SteamGameSheet.downloadNote)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                        Link(destination: URL(string: "https://store.steampowered.com/app/\(appID)/")!) {
                            Label("View in the Steam Store", systemImage: "safari")
                        }
                    }
                } else {
                    ContentUnavailableView("Game unavailable", systemImage: "questionmark.square.dashed",
                                           description: Text("Refresh your Steam library and try again."))
                }
            }
            .navigationTitle("Steam").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: steam.downloads[appID]?.state) {
                partial = steam.hasPartialDownload(appID)
                let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                freeSpace = values?.volumeAvailableCapacityForImportantUsage
            }
            .confirmationDialog("Cancel this download? Downloaded files are deleted.", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Cancel download", role: .destructive) {
                    steam.cancelInstall(appID, installed: games.games.contains { $0.id == appID })
                }
                Button("Keep downloading", role: .cancel) {}
            }
        }
    }

    static let downloadNote = "Games download directly from Steam with your account into C:\\Program Files (x86)\\Steam\\steamapps\\common. You can leave Madeira while it downloads: on iOS 26 and later iOS shows the download's progress and keeps it going; on earlier versions it pauses after a short while and continues when you return. A download pauses while a game is running and continues afterwards."

    @ViewBuilder private func primaryAction(_ item: SteamGamesRules.Item) -> some View {
        if let installed = item.installed {
            // The download finished (or Steam's client installed the game): its Game details page.
            Button {
                let entry = LibraryModel.shared.steamEntry(installed, title: item.name)
                dismiss(); open(entry)
            } label: {
                HStack(spacing: 10) { Image(systemName: "play.fill"); Text("Open").fontWeight(.semibold) }.frame(minWidth: 100, minHeight: 30)
            }.buttonStyle(.borderedProminent)
        } else if let download = steam.downloads[appID] {
            switch download.state {
            case .active, .queued:
                Button { steam.pause(appID) } label: { steamActionLabel("Pause", symbol: "pause.fill") }
                    .buttonStyle(.bordered)
            case .paused:
                Button { steam.install(appID) } label: { steamActionLabel("Resume", symbol: "arrow.down.circle.fill") }
                    .buttonStyle(.borderedProminent)
            case .failed:
                Button { steam.install(appID) } label: { steamActionLabel("Try again", symbol: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
            }
        } else if item.owned != nil {
            Button { steam.install(appID) } label: {
                steamActionLabel(partial ? "Resume download" : "Install", symbol: "arrow.down.circle.fill")
            }.buttonStyle(.borderedProminent).disabled(!steam.signedIn)
        }
    }
}

/// Explicit glyph and title: a Label inside a bordered button in a Form row
/// renders title-only, so the icon is drawn directly.
func steamActionLabel(_ title: String, symbol: String) -> some View {
    HStack(spacing: 8) {
        Image(systemName: symbol)
        Text(title).fontWeight(.semibold)
    }.frame(minWidth: 100, minHeight: 30)
}

// MARK: - Game details: Steam Cloud

/// The Steam Cloud section of a Steam game's Game details page: how the
/// account's cloud saves compare with the saves in the prefix, and the
/// download of cloud saves. A save that differs on the two sides is never
/// replaced without the user choosing it here (docs/STEAM_CLOUD.md).
/// The session menu's "Upload saves and close Madeira" (SteamOwnedLibrary.uploadForQuit).
struct SteamCloudQuitRow: View {
    let appID: Int
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @State private var confirmReplace = false

    private var working: Bool { if case .working = steam.cloudQuit { return true }; if case .done = steam.cloudQuit { return true }; return false }

    private func run(replaceCloud: Bool) {
        Task {
            await steam.uploadForQuit(appID, replaceCloud: replaceCloud)
            guard case .done(let count) = steam.cloudQuit else { return }
            LogStore.shared.log("[steam-cloud] app=\(appID) quit-upload done files=\(count): closing Madeira")
            try? await Task.sleep(nanoseconds: 1_200_000_000)   // long enough to read the result
            exit(0)
        }
    }

    var body: some View {
        if SteamOwnedLibrary.cloudQuitEnabled, steam.signedIn {
            VStack(alignment: .leading, spacing: 8) {
                Button("Upload saves and close Madeira", systemImage: "icloud.and.arrow.up") { run(replaceCloud: false) }
                    .disabled(working)
                switch steam.cloudQuit {
                case .working(let text):
                    HStack(spacing: 10) { ProgressView(); Text(text).font(.callout) }
                case .done(let count):
                    Label(count == 0 ? "Steam Cloud is already up to date. Closing…" : "Uploaded \(count) save\(count == 1 ? "" : "s"). Closing…",
                          systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                case .failed(let message):
                    Text("Not uploaded, Madeira stays open: \(message)").font(.callout).foregroundStyle(.orange)
                case .conflict(let count):
                    Text("Not uploaded: \(count) save\(count == 1 ? " was" : "s were") also changed in Steam Cloud, by another device or with no record of a sync here. Uploading would replace the cloud's \(count == 1 ? "copy" : "copies").")
                        .font(.callout).foregroundStyle(.orange)
                    Button("Replace the Steam Cloud saves and close", role: .destructive) { confirmReplace = true }
                        .confirmationDialog("Replace the Steam Cloud saves with this device's?", isPresented: $confirmReplace, titleVisibility: .visible) {
                            Button("Replace the cloud saves", role: .destructive) { run(replaceCloud: true) }
                            Button("Cancel", role: .cancel) { }
                        } message: { Text("The saves in Steam Cloud are overwritten for every device. Their current copies are saved first, in Files › Madeira › Steam Cloud Backups.") }
                case nil:
                    EmptyView()
                }
                Text("Save in the game first. Uploads this game's saves to Steam Cloud, then closes Madeira; Steam in this session is signed out when the upload starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Whether Steam Cloud saves sync: Settings › Steam Cloud saves, kept in madeira.cfg as
/// env.MADEIRA_STEAM_CLOUD (on unless it is 0; docs/STEAM_CLOUD.md). Turning it back on
/// syncs the installed games at once.
@MainActor final class SteamCloudSetting: ObservableObject {
    static let shared = SteamCloudSetting()
    @Published var on = SteamSignIn.flag("MADEIRA_STEAM_CLOUD", default: true) {
        didSet {
            guard on != oldValue else { return }
            MadeiraConfig.set("env.MADEIRA_STEAM_CLOUD", on ? nil : "0")
            SteamLog.event("[steam-cloud] setting on=\(on ? 1 : 0)")
            if on { SteamOwnedLibrary.shared.cloudTurnedOn() } else { SteamOwnedLibrary.shared.objectWillChange.send() }
        }
    }
}

struct SteamCloudSection: View {
    let appID: Int
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @State private var confirmCloud = false
    @State private var confirmDevice = false

    private static func when(_ seconds: UInt64) -> String {
        seconds == 0 ? "unknown date" : Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .shortened)
    }
    private static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
    private static func saves(_ count: Int) -> String { "\(count) save\(count == 1 ? "" : "s")" }

    var body: some View {
        if SteamOwnedLibrary.cloudEnabled {
            Section {
                rows
            } header: {
                Text("Steam Cloud")
            } footer: {
                Text("Saves sync with Steam Cloud when Madeira starts and when this page opens, not while you play: use Upload saves and close Madeira in the game menu when you stop, or what you played is uploaded the next time Madeira starts. A save that differs on both sides, or that is missing on this device, is never replaced without asking, and a save a sync replaces is kept in Files › Madeira › Steam Cloud Backups.")
            }
        }
    }

    @ViewBuilder private var rows: some View {
        let state = steam.cloud[appID]
        if !steam.signedIn {
            Text("Sign in to Steam to use Steam Cloud.").foregroundStyle(.secondary)
        } else if let state {
            switch state.phase {
            case .checking:
                HStack(spacing: 10) { ProgressView(); Text("Checking Steam Cloud…").foregroundStyle(.secondary) }
            case .downloading(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1))) { Text("Downloading \(done) of \(total)") }
            case .uploading(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1))) { Text("Uploading \(done) of \(total)") }
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.orange)
                Button("Try again") { Task { await steam.syncCloud(appID) } }
            case .ready:
                ready(state)
            }
        } else {
            Text("Not synced yet.").foregroundStyle(.secondary)
                .task { await steam.syncCloud(appID) }
            Button("Sync now") { Task { await steam.syncCloud(appID) } }
        }
    }

    @ViewBuilder private func ready(_ state: SteamCloudState) -> some View {
        let audit = state.audit
        let conflicts = state.conflicts
        let same = audit.count(.same)
        if audit.entries.isEmpty {
            Text("No saves in Steam Cloud or on this device for this game.").foregroundStyle(.secondary)
        }
        if !conflicts.isEmpty {
            let missing = conflicts.filter { $0.kind == .cloudOnly }.count
            Label(missing == conflicts.count ? "\(Self.saves(missing)) synced here before \(missing == 1 ? "is" : "are") missing on this device"
                  : "\(Self.saves(conflicts.count)) differ between Steam Cloud and this device", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            ForEach(conflicts) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.subheadline.weight(.medium))
                    Text("Steam Cloud: \(Self.when(entry.cloudTime)) · \(Self.size(entry.cloudSize))\(entry.kind != .cloudOnly && entry.cloudTime > entry.localTime ? " · newer" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(entry.kind == .cloudOnly ? "This device: missing (it was synced here before)"
                         : "This device: \(Self.when(entry.localTime)) · \(Self.size(entry.localSize))\(entry.localTime > entry.cloudTime ? " · newer" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Nothing is changed until you choose which to keep.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Keep the Steam Cloud saves…") { confirmCloud = true }
                .confirmationDialog("Use the Steam Cloud version of \(Self.saves(conflicts.count)) on this device? This device's copies are saved first, in Files › Madeira › Steam Cloud Backups.",
                                    isPresented: $confirmCloud, titleVisibility: .visible) {
                    Button("Use the Steam Cloud saves", role: .destructive) { Task { await steam.resolveCloud(appID, useCloud: true) } }
                    Button("Cancel", role: .cancel) {}
                }
            Button("Keep this device's saves…") { confirmDevice = true }
                .confirmationDialog("Keep this device's version of \(Self.saves(conflicts.count))? Saves that differ replace Steam Cloud's for every device; the cloud's copies are saved first, in Files › Madeira › Steam Cloud Backups. Saves missing on this device stay missing, and Steam Cloud keeps them.",
                                    isPresented: $confirmDevice, titleVisibility: .visible) {
                    Button("Keep this device's saves", role: .destructive) { Task { await steam.resolveCloud(appID, useCloud: false) } }
                    Button("Cancel", role: .cancel) {}
                }
        } else if !audit.entries.isEmpty {
            let waiting = audit.count(.differ) + audit.count(.cloudOnly) + audit.count(.localOnly)
            if waiting == 0 {
                Label("In sync", systemImage: "checkmark.icloud").foregroundStyle(.secondary)
            } else {
                // One-sided leftovers: a file deleted on one side, or automatic sync turned off.
                LabeledContent("Not synced", value: Self.saves(waiting))
            }
        }
        if same > 0 { LabeledContent("Same on both", value: "\(same)") }
        if let problem = state.problem {
            Text(problem).font(.callout).foregroundStyle(.orange)
        }
        if let last = state.lastDownload, last.files > 0 {
            Text("Downloaded \(Self.saves(last.files))."
                 + (last.backedUp > 0 ? " \(Self.saves(last.backedUp)) replaced on this device \(last.backedUp == 1 ? "was" : "were") backed up." : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        if let last = state.lastUpload, last > 0 {
            Text("Uploaded \(Self.saves(last)).").font(.caption).foregroundStyle(.secondary)
        }
        Button("Sync now") { Task { await steam.syncCloud(appID) } }
    }
}

// MARK: - Game details: the Steam section

/// The Steam section of a Steam game's Game details page (LibraryDetail): how
/// the game starts (Madeira Dock, the default, with its per-launch pool choice and
/// one-time installs; or The game, its own program without Steam, SteamDirectStart),
/// its update, a repair of its files and Uninstall.
struct SteamEntrySection: View {
    @Binding var entry: LibraryEntry
    /// The game was uninstalled: the page closes without saving.
    var uninstalled: () -> Void
    @ObservedObject private var dock = MadeiraDockModel.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var games = SteamGamesModel.shared
    @State private var confirmUninstall = false
    @State private var freeSpace: Int64?
    /// "The game": the install folder's programs (the Program picker) and whether
    /// Steam's launch configuration is being read.
    @State private var programs: [String] = []
    @State private var resolving = false

    var body: some View {
        let appID = entry.steamAppID ?? 0
        let installed = games.games.first { $0.id == appID }
        let download = steam.downloads[appID]
        // Madeira manages (updates, repairs, removes) only what it downloaded into Dock's own library folder.
        let managed = installed.map { SteamInstallPaths.isManaged(library: $0.library) } ?? false
        let downloads = SteamOwnedLibrary.enabled && managed
        let direct = entry.startsSteamGameDirectly
        Section {
            Picker("Start with", selection: Binding(get: { direct ? SteamDirectStart.mode : "dock" }, set: { choose($0) })) {
                Text("Madeira Dock").tag("dock")
                Text("The game").tag(SteamDirectStart.mode)
            }
            if direct {
                // The game's own program, from Steam's launch configuration or chosen here.
                if resolving && entry.steamProgram == nil {
                    LabeledContent("Program") { ProgressView() }
                } else if programs.isEmpty && entry.steamProgram == nil {
                    Text("No Windows program was found in this game's install folder.")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Picker("Program", selection: Binding(get: { entry.steamProgram ?? "" }, set: { pick($0) })) {
                        if entry.steamProgram == nil { Text("Choose…").tag("") }
                        ForEach(pickerPrograms, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.navigationLink)
                    if entry.steamProgramSource == "steam" {
                        if (entry.steamProgramArguments ?? "").isEmpty {
                            Text("From Steam's launch configuration for this game.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("From Steam's launch configuration for this game, with its arguments.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                if !dock.clientInstalled {
                    Text("Madeira Dock needs Valve's client components. Download them in Settings › Steam › Madeira Dock.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Smaller JIT pool (512 MB) for this launch", isOn: $dock.compactPool)
                // The game's One-time installs choice (Madeira Dock, DockInstallers).
                if DockInstallers.choiceEnabled, dock.installPrograms[appID] != nil {
                    Picker("One-time installs", selection: Binding(get: { dock.installRunNext[appID] ?? true },
                                                                   set: { dock.setRunsInstallers(appID, $0) })) {
                        Text("Run at next start").tag(true)
                        Text("Skip").tag(false)
                    }.pickerStyle(.menu)
                }
            }
            if let download {
                SteamDownloadStatus(download: download)
                switch download.state {
                case .active, .queued: Button("Pause update") { steam.pause(appID) }
                case .paused, .failed: Button("Resume update") { steam.install(appID) }
                }
            } else if downloads, steam.updateAvailable(appID: appID, installedBuild: games.builds[appID]) {
                Button { steam.install(appID) } label: { Label("Update available — download", systemImage: "arrow.down.circle") }
                    .disabled(!steam.signedIn)
            }
            if downloads, download == nil {
                Button { steam.repair(appID) } label: { Label("Repair installed files", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(!steam.signedIn)
                Text("Checks installed content and downloads missing or changed files from the current Steam build.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("App ID", value: String(appID))
            if let freeSpace { LabeledContent("Free space on this device", value: formatBytes(freeSpace)) }
            if let status = dock.status {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Dock result").font(.caption).foregroundStyle(.secondary)
                    Text(status).font(.footnote)
                }
            }
            if managed, download == nil {
                Button("Uninstall", role: .destructive) { confirmUninstall = true }
            }
        } header: {
            Text("Steam")
        } footer: {
            if direct {
                Text("The game starts its own program in Wine, without Steam. This suits games that run without Steam (DRM-free); a game that needs Steam or its licence check does not start this way, so choose Madeira Dock for it.")
            } else {
                Text("Madeira Dock starts the game through Valve's own Steam client, without the Steam desktop window. Valve's client signs in with your account and decides whether the game may run.")
            }
        }
        .onAppear { dock.refresh(); games.refresh() }
        .task(id: download?.state) {
            let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            freeSpace = values?.volumeAvailableCapacityForImportantUsage
        }
        .task(id: "\(entry.steamStart ?? "dock") \(installed?.installed == true) \(download == nil)") { await resolveProgram() }
        .confirmationDialog("Uninstall \(entry.title)? Its downloaded files are deleted from this device. Saves stored elsewhere are kept.",
                            isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                if let installed { steam.uninstall(installed) }
                uninstalled()
            }
        }
    }

    /// The Program picker's rows: the folder's programs, and a kept choice that is not among them.
    private var pickerPrograms: [String] {
        guard let chosen = entry.steamProgram, !programs.contains(chosen) else { return programs }
        return [chosen] + programs
    }

    /// Start with: Madeira Dock (stored as no choice, the default) or The game.
    private func choose(_ mode: String) {
        let next: String? = mode == SteamDirectStart.mode ? mode : nil
        guard next != entry.steamStart else { return }
        entry.steamStart = next
        LogStore.shared.log("[steam-start] app=\(entry.steamAppID ?? 0) mode=\(next == nil ? "dock" : "game")")
    }

    /// The Program picker's choice; it is kept over Steam's launch configuration.
    private func pick(_ program: String) {
        guard !program.isEmpty, program != entry.steamProgram else { return }
        entry.steamProgram = program
        entry.steamProgramArguments = nil
        entry.steamProgramFolder = nil
        entry.steamProgramSource = "choice"
        LogStore.shared.log("[steam-start] app=\(entry.steamAppID ?? 0) program=choice")
    }

    /// "The game": lists the install folder's programs and, unless the user picked one that
    /// is still there, takes Steam's launch configuration for the app (SteamDirectStart.choose);
    /// failing that, the only program when there is exactly one.
    private func resolveProgram() async {
        guard entry.startsSteamGameDirectly, let appID = entry.steamAppID else { return }
        let folder = LibraryModel.drive.appendingPathComponent(entry.relativePath, isDirectory: true)
        let found = await Task.detached(priority: .userInitiated) { SteamDirectStart.programs(in: folder) }.value
        programs = found
        if entry.steamProgramSource == "choice", let program = entry.steamProgram, found.contains(program) { return }
        resolving = true
        let options = await steam.launchOptions(appID: appID) ?? []
        resolving = false
        guard entry.startsSteamGameDirectly, entry.steamAppID == appID else { return }
        let choice = await Task.detached(priority: .userInitiated) { SteamDirectStart.choose(options, installFolder: folder) }.value
        if let choice {
            entry.steamProgram = choice.program
            entry.steamProgramArguments = choice.arguments.isEmpty ? nil : choice.arguments
            entry.steamProgramFolder = choice.folder
            entry.steamProgramSource = "steam"
        } else if let program = entry.steamProgram, found.contains(program) {
            // Kept: an earlier choice that is still installed.
        } else if found.count == 1 {
            entry.steamProgram = found[0]
            entry.steamProgramArguments = nil; entry.steamProgramFolder = nil
            entry.steamProgramSource = "only"
        } else {
            entry.steamProgram = nil
            entry.steamProgramArguments = nil; entry.steamProgramFolder = nil
            entry.steamProgramSource = nil
        }
        LogStore.shared.log("[steam-start] app=\(appID) launch-entries=\(options.count) programs=\(found.count) source=\(entry.steamProgramSource ?? "none")")
    }
}
