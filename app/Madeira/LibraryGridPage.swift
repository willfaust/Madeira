// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import Combine
import UIKit

// The zoomable library page (docs/zoomable-grid.md). In the card layouts the
// library page is one UICollectionView (LibraryGridHost.swift) that can be pinched between column counts (LibraryGridZoom.swift).
// This file is its SwiftUI side: which arm runs, the page's content as a model (the same sections and groups the SwiftUI page
// shows, from the same rules), and the sheets, alerts and refreshes the SwiftUI sections own on the other arm.

/// Which grid the card layouts use: the original SwiftUI page (LazyVGrid, LibraryCells) or the zoomable UIKit page. Settings >
/// Appearance > "New library grid" (off by default). What is not part of the grid but depends on it (the touch frame-rate
/// request, the background library writer, the glow renderer) follows the same setting. The list layouts are the original page either way.
enum LibraryGridArm {
    static let key = "madeiraLibraryNewGrid"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? false }
    static let releaseMemory = Notification.Name("madeiraLibraryGridReleaseMemory")
    static func zoomable(setting: Bool, layout: String) -> Bool {
        setting && (layout == "cards" || layout == "compact")
    }
}

// MARK: - The page's content

enum LibraryGridCard: Hashable {
    case entry(UUID)
    case steam(Int)
    var key: String {
        switch self {
        case .entry(let id): return "entry-" + id.uuidString
        case .steam(let id): return "steam-\(id)"
        }
    }
}

/// An element of the page that is not a card: full width, its own height.
enum LibraryGridFixed: Hashable {
    case desktop
    /// A section or group title; `collapse` names its stored collapsed state
    /// ("others", "installed", "group:<key>"), nil when it does not collapse.
    case header(id: String, title: String, count: Int?, collapse: String?, collapsed: Bool)
    case signIn
    case cloudNotice(String)
    case syncing(String)
    case note(id: String, text: String)
    case notInstalledToggle(count: Int, shown: Bool)
    case emptyLibrary

    var id: String {
        switch self {
        case .desktop: return "desktop"
        case .header(let id, _, _, _, _): return "header." + id
        case .signIn: return "signIn"
        case .cloudNotice: return "cloud"
        case .syncing: return "syncing"
        case .note(let id, _): return "note." + id
        case .notInstalledToggle: return "toggle.notInstalled"
        case .emptyLibrary: return "empty"
        }
    }
}

/// SteamGamesRules.items over the account's whole library, computed once per change of its inputs. A page build asks for it up
/// to five times, at thousands of games its sort is the build's whole cost, and a landing's size write re-renders the page.
/// Array equality is a buffer identity check when nothing changed.
@MainActor enum LibraryGridSteamItems {
    private static var memo: [String: (installed: [DockGame], owned: [SteamOwnedGame], items: [SteamGamesRules.Item])] = [:]

    static func items(installed: [DockGame], owned: [SteamOwnedGame], search: String) -> [SteamGamesRules.Item] {
        if let kept = memo[search], kept.installed == installed, kept.owned == owned { return kept.items }
        let items = SteamGamesRules.items(installed: installed, owned: owned, search: search)
        if memo.count >= 4 { memo = [:] }   // the empty search and the one typed
        memo[search] = (installed, owned, items)
        return items
    }

    static var shown: Bool {
        let library = SteamOwnedLibrary.enabled, account = SteamOwnedLibrary.shared
        let owned = library ? account.owned : []
        let total = items(installed: SteamGamesModel.shared.games, owned: owned, search: "").count
        return SteamGamesRules.showsSection(dock: MadeiraDock.enabled, library: library,
                                            signedIn: library && account.signedIn, count: total)
    }

    static var hasInstalled: Bool {
        let library = SteamOwnedLibrary.enabled, account = SteamOwnedLibrary.shared
        let owned = library ? account.owned : []
        let all = items(installed: SteamGamesModel.shared.games, owned: owned, search: "")
        let groups = SteamGamesRules.groups(all, downloading: Set(account.downloads.keys))
        return !groups.installed.isEmpty || !groups.downloading.isEmpty
    }
}

/// One block of the page, top to bottom: a fixed element or a grid section.
struct LibraryGridBlock: Equatable {
    enum Kind: Equatable {
        case fixed(LibraryGridFixed)
        case grid(id: String, cards: [LibraryGridCard])
    }
    var kind: Kind
    var spacing: CGFloat
}

/// The library page as data. Built from the same rules the SwiftUI page uses (SteamGamesRules.items/groups/sorted,
/// LibraryGrouping.groups, SteamGamesSection.shown/hasInstalled's rules through LibraryGridSteamItems); tests/host/check-library-zoom.py
/// checks that it keeps calling them.
struct LibraryGridPageModel: Equatable {
    var blocks: [LibraryGridBlock] = []
    var entries: [UUID: LibraryEntry] = [:]
    var steam: [Int: SteamGamesRules.Item] = [:]

    static func == (a: Self, b: Self) -> Bool {
        a.blocks == b.blocks && a.steam == b.steam && a.entries.mapValues(\.title) == b.entries.mapValues(\.title)
    }

    struct Inputs {
        var search: String
        var sort: String
        var group: String
        var others: [LibraryEntry]
        var hideOthers: Bool
        var hideInstalled: Bool
        var showUninstalled: Bool
        var collapsedGroups: String
    }

    @MainActor static func build(_ inputs: Inputs) -> LibraryGridPageModel {
        var page = LibraryGridPageModel()
        page.append(.fixed(.desktop), spacing: 0)
        if inputs.group != "platform" {
            page.grouped(inputs)
        } else {
            let steamFirst = MadeiraDock.enabled && LibraryGridSteamItems.hasInstalled
            if steamFirst { page.steamSection(inputs, part: .installed) }
            if LibraryGridSteamItems.shown {
                page.othersSection(inputs)
                if MadeiraDock.enabled { page.steamSection(inputs, part: steamFirst ? .notInstalled : .all) }
            } else if LibraryModel.shared.entries.filter({ $0.desktop != true && $0.steamAppID == nil }).isEmpty {
                page.append(.fixed(.emptyLibrary), spacing: LibraryGridGeometry.blockSpacing)
            } else {
                page.grid("others", inputs.others, spacing: LibraryGridGeometry.blockSpacing)
            }
        }
        return page
    }

    private mutating func append(_ kind: LibraryGridBlock.Kind, spacing: CGFloat) {
        blocks.append(LibraryGridBlock(kind: kind, spacing: blocks.isEmpty ? 0 : spacing))
    }

    private mutating func grid(_ id: String, _ list: [LibraryEntry], spacing: CGFloat) {
        for entry in list { entries[entry.id] = entry }
        append(.grid(id: id, cards: list.map { .entry($0.id) }), spacing: spacing)
    }

    private mutating func othersSection(_ inputs: Inputs) {
        let collapsible = SteamGamesSection.collapsible
        append(.fixed(.header(id: "others", title: "Other games", count: inputs.others.count,
                              collapse: collapsible ? "others" : nil, collapsed: inputs.hideOthers)),
               spacing: LibraryGridGeometry.blockSpacing)
        if inputs.hideOthers && collapsible {
            return
        } else if inputs.others.isEmpty {
            let text = inputs.search.isEmpty
                ? "Copy a game's folder into Madeira › wine › drive_c with the Files app, then tap + and choose its .exe."
                : "No other games match your search."
            append(.fixed(.note(id: "others", text: text)), spacing: LibraryGridGeometry.sectionSpacing)
        } else {
            grid("others", inputs.others, spacing: LibraryGridGeometry.sectionSpacing)
        }
    }

    @MainActor private mutating func steamSection(_ inputs: Inputs, part: SteamGamesSection.Part) {
        guard LibraryGridSteamItems.shown else { return }
        let account = SteamOwnedLibrary.shared, model = SteamGamesModel.shared
        let libraryEnabled = SteamOwnedLibrary.enabled
        let owned = libraryEnabled ? account.owned : []
        let signedIn = libraryEnabled && account.signedIn
        let items = LibraryGridSteamItems.items(installed: model.games, owned: owned, search: inputs.search)
        let groups = SteamGamesRules.groups(items, downloading: Set(account.downloads.keys))
        let installed = SteamGamesRules.sorted(groups.installed, by: inputs.sort, recorded: Self.recorded())
        let collapsible = SteamGamesSection.collapsible
        var first = true
        func add(_ kind: LibraryGridBlock.Kind) {
            append(kind, spacing: first ? LibraryGridGeometry.blockSpacing : LibraryGridGeometry.sectionSpacing)
            first = false
        }
        if part != .notInstalled {
            add(.fixed(.header(id: "steam", title: "Steam", count: installed.count,
                               collapse: collapsible ? "installed" : nil, collapsed: inputs.hideInstalled)))
            if SteamGamesRules.showsSignIn(library: libraryEnabled, signedIn: account.signedIn) { add(.fixed(.signIn)) }
            if SteamOwnedLibrary.cloudEnabled, !account.cloudUndecided.isEmpty {
                let names = account.cloudUndecided.compactMap { id in model.games.first { $0.id == id }?.name }
                add(.fixed(.cloudNotice("Steam Cloud: \(names.joined(separator: ", ")) \(names.count == 1 ? "has" : "have") saves that differ from this device's. Open the game's details to choose which to keep.")))
            }
            if let waiting = account.cloudWaitingFor {
                add(.fixed(.syncing("Syncing \(model.games.first { $0.id == waiting }?.name ?? "the game")'s Steam Cloud saves, then starting it…")))
            }
            if inputs.hideInstalled && collapsible {
            } else if !groups.downloading.isEmpty || !installed.isEmpty {
                let cards = groups.downloading + installed
                for item in cards { steam[item.id] = item }
                add(.grid(id: "steam.installed", cards: cards.map { .steam($0.id) }))
            } else if signedIn && !account.refreshing && groups.notInstalled.isEmpty && inputs.search.isEmpty {
                add(.fixed(.note(id: "steam", text: account.libraryUpdated == nil ? "Pull down to load your Steam library."
                                 : "No Windows games were found in this Steam library.")))
            }
        }
        if part != .installed && signedIn && !groups.notInstalled.isEmpty {
            add(.fixed(.notInstalledToggle(count: groups.notInstalled.count, shown: inputs.showUninstalled)))
            if inputs.showUninstalled {
                for item in groups.notInstalled { steam[item.id] = item }
                add(.grid(id: "steam.notInstalled", cards: groups.notInstalled.map { .steam($0.id) }))
            }
        }
    }

    @MainActor private static func recorded() -> [Int: SteamGamesRules.Recorded] {
        var result: [Int: SteamGamesRules.Recorded] = [:]
        for (position, entry) in LibraryModel.shared.entries.enumerated() {
            if let appID = entry.steamAppID {
                result[appID] = SteamGamesRules.Recorded(lastPlayed: entry.lastPlayed, bytes: entry.folderBytes, position: position)
            }
        }
        return result
    }

    @MainActor private mutating func grouped(_ inputs: Inputs) {
        let library = LibraryModel.shared, account = SteamOwnedLibrary.shared
        let query = inputs.search.trimmingCharacters(in: .whitespaces)
        var games: [LibraryGrouping.Game] = []
        var steamEntries: [Int: (position: Int, entry: LibraryEntry)] = [:]
        for (position, entry) in library.entries.enumerated() where entry.desktop != true {
            if let appID = entry.steamAppID { steamEntries[appID] = (position, entry) }
            else if query.isEmpty || entry.title.localizedCaseInsensitiveContains(query) {
                entries[entry.id] = entry
                games.append(LibraryGrouping.Game(entry: entry, position: position))
            }
        }
        if LibraryGridSteamItems.shown {
            let enabled = SteamOwnedLibrary.enabled
            let downloading = Set(account.downloads.keys)
            for item in LibraryGridSteamItems.items(installed: SteamGamesModel.shared.games, owned: enabled ? account.owned : [], search: query) {
                let installed = item.installed != nil || downloading.contains(item.id)
                guard installed || (enabled && account.signedIn) else { continue }
                let recorded = steamEntries[item.id]
                let steamPlayed = account.playtime[item.id].flatMap {
                    $0.lastPlayed > 0 ? Date(timeIntervalSince1970: TimeInterval($0.lastPlayed)) : nil
                }
                steam[item.id] = item
                games.append(LibraryGrouping.Game(source: .steam(item.id), title: item.name, installed: installed,
                                                  lastPlayed: [recorded?.entry.lastPlayed, steamPlayed].compactMap { $0 }.max(),
                                                  bytes: recorded?.entry.folderBytes, position: recorded?.position))
            }
        }
        let groups = LibraryGrouping.groups(games, by: inputs.group, sort: inputs.sort)
        let collapsed = LibraryGrouping.collapsed(inputs.collapsedGroups)
        if groups.isEmpty {
            append(.fixed(inputs.search.isEmpty ? .emptyLibrary : .note(id: "grouped", text: "No games match your search.")),
                   spacing: LibraryGridGeometry.blockSpacing)
        }
        for group in groups {
            let key = inputs.group + "." + group.id
            let collapsible = SteamGamesSection.collapsible
            var first = true
            if let title = group.title {
                append(.fixed(.header(id: "group." + key, title: title, count: group.games.count,
                                      collapse: collapsible ? "group:" + key : nil, collapsed: collapsed.contains(key))),
                       spacing: LibraryGridGeometry.blockSpacing)
                first = false
            }
            if !(collapsed.contains(key) && collapsible) {
                let cards: [LibraryGridCard] = group.games.map {
                    switch $0.source {
                    case .entry(let id): return .entry(id)
                    case .steam(let id): return .steam(id)
                    }
                }
                append(.grid(id: "group." + key, cards: cards),
                       spacing: first ? LibraryGridGeometry.blockSpacing : LibraryGridGeometry.sectionSpacing)
            }
        }
    }

    // MARK: Labels

    @MainActor func labels() -> [LibraryGridCard: LibraryCardLabel] {
        let context = LabelContext()
        var result: [LibraryGridCard: LibraryCardLabel] = [:]
        for block in blocks {
            guard case .grid(_, let cards) = block.kind else { continue }
            for card in cards { if let label = label(for: card, context) { result[card] = label } }
        }
        return result
    }

    @MainActor struct LabelContext {
        let account = SteamOwnedLibrary.shared, games = SteamGamesModel.shared
        var steamEntries: [Int: LibraryEntry] = [:]
        init() {
            for entry in LibraryModel.shared.entries { if let id = entry.steamAppID, steamEntries[id] == nil { steamEntries[id] = entry } }
        }
    }

    @MainActor private func label(for card: LibraryGridCard, _ context: LabelContext) -> LibraryCardLabel? {
        switch card {
        case .entry(let id):
            guard let entry = entries[id] else { return nil }
            return LibraryCardLabel(title: entry.title, format: LibraryBadges.formatTexts(entry, note: nil),
                                    size: LibraryBadges.sizeText(entry))
        case .steam(let id):
            guard let item = steam[id] else { return nil }
            let account = context.account
            let download = account.downloads[id]
            let status = SteamGamesRules.status(installed: item.installed, transfer: download?.transfer,
                                                updateAvailable: account.updateAvailable(appID: id, installedBuild: context.games.builds[id]))
            var label = LibraryCardLabel(title: item.name, played: account.playtime[id]?.played)
            if status.showsFormat, let entry = context.steamEntries[id] {
                label.format = LibraryBadges.formatTexts(entry, note: status.badge)
                label.size = LibraryBadges.sizeText(entry)
            } else if let badge = status.badge {
                label.status = badge
            }
            return label
        }
    }

    /// The delta for a metadata-only publication (LibraryPublication.metadata): the changed entries are read again into this page and
    /// only their cards' labels are made again. Blocks, order and every other label are kept; the caller has established that
    /// nothing else changed (LibraryGridHostController.metadataDelta).
    @MainActor mutating func applyMetadata(ids: Set<UUID>, labels current: [LibraryGridCard: LibraryCardLabel]) -> [LibraryGridCard: LibraryCardLabel] {
        let context = LabelContext()
        var result = current
        for entry in LibraryModel.shared.entries where ids.contains(entry.id) {
            var card: LibraryGridCard?
            if entries[entry.id] != nil { entries[entry.id] = entry; card = .entry(entry.id) }
            else if let appID = entry.steamAppID, steam[appID] != nil { card = .steam(appID) }
            if let card { result[card] = label(for: card, context) }
        }
        return result
    }
}

/// What the page model is built from besides the library document, as a value: two equal keys and no other
/// published change between them mean the library document is the ONLY thing that changed (the metadata delta).
struct LibraryGridInputsKey: Hashable {
    var search: String, sort: String, group: String
    var hideOthers: Bool, hideInstalled: Bool, showUninstalled: Bool
    var collapsedGroups: String
    var otherIDs: [UUID]
    var switches: [Bool]
    /// Sort by size reads the metadata, and sort by added orders by the entries a metadata change can create, so a
    /// metadata change can move a card: never a delta.
    var metadataMovesCards: Bool

    @MainActor init(_ i: LibraryGridPageModel.Inputs) {
        search = i.search; sort = i.sort; group = i.group
        hideOthers = i.hideOthers; hideInstalled = i.hideInstalled; showUninstalled = i.showUninstalled
        collapsedGroups = i.collapsedGroups
        otherIDs = i.others.map(\.id)
        switches = [SteamGamesSection.collapsible, MadeiraDock.enabled, LibraryGridSteamItems.shown, SteamOwnedLibrary.enabled]
        metadataMovesCards = i.sort == "size" || i.sort == "added"
    }
}

/// Counts every publication of the two models besides the library document that feed the page (Steam's owned
/// library and installed games). The counter is not state: reading it never invalidates a view.
@MainActor final class LibraryGridOtherChanges {
    static let shared = LibraryGridOtherChanges()
    private(set) var revision = 0
    private var subscriptions: [AnyCancellable] = []
    private init() {
        subscriptions = [SteamOwnedLibrary.shared.objectWillChange.sink { [unowned self] _ in revision += 1 },
                         SteamGamesModel.shared.objectWillChange.sink { [unowned self] _ in revision += 1 }]
    }
}

// MARK: - The SwiftUI side

/// The zoomable page: the collection view, plus what SteamGamesSection and LibraryGroupedGames own on the SwiftUI page (the
/// download sheet, the sign-in sheet, the Steam alert, the refreshes when the library appears).
struct LibraryGridPage: View {
    let search: String
    let sort: String
    let group: String
    @Binding var layout: String
    let others: [LibraryEntry]
    @Binding var hideOthers: Bool
    let focused: UUID?
    let open: (LibraryEntry) -> Void
    let desktop: () -> AnyView

    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var steamGames = SteamGamesModel.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("madeiraLibraryHideInstalled") private var hideInstalled = false
    @AppStorage("madeiraSteamShowUninstalled") private var showUninstalled = true
    @AppStorage("madeiraLibraryCollapsedGroups") private var collapsedGroups = ""
    @AppStorage(LibraryGridSize.key) private var position: Double = -1
    @State private var steamSheet: SteamSheetID?
    @State private var showSignIn = false

    private struct SteamSheetID: Identifiable { let id: Int }

    var body: some View {
        let inputs = LibraryGridPageModel.Inputs(search: search, sort: sort, group: group, others: others,
                                                 hideOthers: hideOthers, hideInstalled: hideInstalled,
                                                 showUninstalled: showUninstalled, collapsedGroups: collapsedGroups)
        LibraryGridHostView(
            build: { LibraryGridPageModel.build(inputs) }, inputsKey: LibraryGridInputsKey(inputs),
            otherRevision: LibraryGridOtherChanges.shared.revision, layout: layout, position: position, focused: focused,
            fixed: { fixedView($0) },
            open: { card, page in activate(card, page) },
            landed: { newPosition, cardWidth in
                position = newPosition
                let picked = LibraryGridSize.layout(forCardWidth: cardWidth)
                if layout != picked { layout = picked }
            })
            .ignoresSafeArea()
            // As SteamGamesSection and LibraryGroupedGames: the library reappears after every session.
            .onAppear {
                steamGames.refresh()
                if SteamOwnedLibrary.enabled { steam.start(); steam.reconcileSession() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { steamGames.refresh(); if SteamOwnedLibrary.enabled { steam.reconcileSession() } }
            }
            .sheet(item: $steamSheet) { selection in
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

    /// What a card's button did: a library game or an installed Steam game opens its details, any other Steam game its download sheet.
    private func activate(_ card: LibraryGridCard, _ page: LibraryGridPageModel) {
        switch card {
        case .entry(let id):
            // The library's own copy: the page's equality compares titles only, so its entry can be an older one.
            if let entry = library.entries.first(where: { $0.id == id }) ?? page.entries[id] { open(entry) }
        case .steam(let appID):
            guard let item = page.steam[appID] else { return }
            if let installed = item.installed { open(LibraryModel.shared.steamEntry(installed, title: item.name)) }
            else { steamSheet = SteamSheetID(id: appID) }
        }
    }

    private func fixedView(_ fixed: LibraryGridFixed) -> AnyView {
        switch fixed {
        case .desktop:
            return desktop()
        case .header(_, let title, let count, let collapse, _):
            return AnyView(LibraryGridHeader(title: title, count: count, collapse: collapse, hideOthers: $hideOthers))
        case .signIn:
            return AnyView(SteamSignInCard { showSignIn = true })
        case .cloudNotice(let text):
            return AnyView(Label(text, systemImage: "exclamationmark.icloud").font(.footnote).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading))
        case .syncing(let text):
            return AnyView(HStack(spacing: 8) { ProgressView(); Text(text) }.font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading))
        case .note(_, let text):
            return AnyView(Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading))
        case .notInstalledToggle(let count, _):
            return AnyView(LibraryGridNotInstalledToggle(count: count))
        case .emptyLibrary:
            return AnyView(ContentUnavailableView("Make yourself at home", systemImage: "gamecontroller", description: Text("Copy a game's folder into Madeira › wine › drive_c with the Files app, then tap + and choose its .exe.")))
        }
    }
}

private struct LibraryGridHeader: View {
    let title: String
    let count: Int?
    let collapse: String?
    @Binding var hideOthers: Bool
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @AppStorage("madeiraLibraryHideInstalled") private var hideInstalled = false
    @AppStorage("madeiraLibraryCollapsedGroups") private var collapsedGroups = ""

    var body: some View {
        LibrarySectionHeader(title: title, count: count, collapsed: binding) {
            if collapse == "installed", steam.refreshing { ProgressView().accessibilityLabel("Refreshing Steam library") }
        }
    }

    private var binding: Binding<Bool>? {
        guard let collapse else { return nil }
        if collapse == "others" { return $hideOthers }
        if collapse == "installed" { return $hideInstalled }
        let key = String(collapse.dropFirst("group:".count))
        return Binding(get: { LibraryGrouping.collapsed(collapsedGroups).contains(key) }, set: { on in
            var set = LibraryGrouping.collapsed(collapsedGroups)
            if on { set.insert(key) } else { set.remove(key) }
            collapsedGroups = LibraryGrouping.storing(set)
        })
    }
}

private struct LibraryGridNotInstalledToggle: View {
    let count: Int
    @AppStorage("madeiraSteamShowUninstalled") private var showUninstalled = true
    var body: some View {
        Button {
            withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) { showUninstalled.toggle() }
        } label: {
            HStack {
                Text("Not installed").font(.headline)
                Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(showUninstalled ? 90 : 0)).foregroundStyle(.secondary)
            }.contentShape(Rectangle()).frame(minHeight: 44)
        }.buttonStyle(.plain)
            .accessibilityValue(showUninstalled ? "Shown" : "Hidden")
    }
}
