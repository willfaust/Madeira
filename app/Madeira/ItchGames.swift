// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

// The library's itch.io section, Find a game, a game's download sheet, its Game details
// section and Settings › itch.io (docs/ITCH.md).

/// One game in the section: owned, installed by Madeira, or both.
struct ItchItem: Identifiable {
    let id: Int
    var title: String
    var cover: URL?
    var owned: ItchOwnedGame?
    var installed: ItchInstalledGame?
}

enum ItchGamesRules {
    /// Installed games and the account's other games, by title, filtered by the search.
    @MainActor static func items(_ itch: ItchLibrary, search: String) -> [ItchItem] {
        var items: [Int: ItchItem] = [:]
        for game in itch.owned { items[game.id] = ItchItem(id: game.id, title: game.title, cover: game.cover, owned: game) }
        for (id, record) in itch.installed { items[id, default: ItchItem(id: id, title: record.title)].installed = record }
        let query = search.trimmingCharacters(in: .whitespaces)
        return items.values
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

extension LibraryModel {
    /// An installed itch.io game's library entry; a game without one gets a new entry,
    /// saved when its details page closes.
    func itchEntry(_ game: ItchInstalledGame) -> LibraryEntry {
        if var entry = entries.first(where: { $0.itchGameID == game.gameID }) {
            entry.relativePath = game.programPath
            return entry
        }
        var entry = LibraryEntry(title: game.title, relativePath: game.programPath, bits: 0)
        entry.itchGameID = game.gameID
        entry.folderBytes = game.installBytes
        return entry
    }
}

// MARK: - Library section

struct ItchGamesSection: View {
    let search: String
    var layout = "cards"
    var width: CGFloat = 390
    let open: (LibraryEntry) -> Void
    @ObservedObject private var itch = ItchLibrary.shared
    @ObservedObject private var library = LibraryModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("madeiraLibraryHideItch") private var hidden = false
    @AppStorage("madeiraItchShowUninstalled") private var showUninstalled = true
    @State private var selected: ItchSelection?
    @State private var showSignIn = false
    @State private var showFind = false

    private struct ItchSelection: Identifiable { let id: Int }

    var body: some View {
        let items = ItchGamesRules.items(itch, search: search)
        let mine = items.filter { $0.installed != nil || itch.downloads[$0.id] != nil }
        let others = items.filter { $0.installed == nil && itch.downloads[$0.id] == nil }
        let collapsible = SteamGamesSection.collapsible
        VStack(alignment: .leading, spacing: 14) {
            LibrarySectionHeader(title: "itch.io", count: mine.count, collapsed: collapsible ? $hidden : nil) {
                if itch.refreshing { ProgressView().accessibilityLabel("Refreshing itch.io library") }
            }
            if !(hidden && collapsible) {
                if !itch.signedIn {
                    Button { showSignIn = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 30)).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sign in to itch.io").font(.headline)
                                Text("See the games you bought or claimed on itch.io here and install them without leaving Madeira.")
                                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.padding(14)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain)
                }
                if !mine.isEmpty {
                    LibraryCells(items: mine, layout: layout, width: width) { item, list, dense in cell(item, list: list, dense: dense) }
                } else if itch.signedIn && !itch.refreshing && others.isEmpty && search.isEmpty {
                    Text(itch.libraryUpdated == nil ? "Pull down to load your itch.io library."
                         : "No Windows games yet. Games you buy or claim on itch.io show here, and so do the games in your itch.io collections. For a free game, use Find a game.")
                        .foregroundStyle(.secondary)
                }
                if itch.signedIn {
                    Button { showFind = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "magnifyingglass.circle.fill").font(.system(size: 30)).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Find a game on itch.io").font(.headline)
                                Text("Search itch.io or paste a game's link, add free games to this library and install them here.")
                                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.padding(14)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain)
                }
                if itch.signedIn && !others.isEmpty {
                    Button {
                        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) { showUninstalled.toggle() }
                    } label: {
                        HStack {
                            Text("Not installed").font(.headline)
                            Text("\(others.count)").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(showUninstalled ? 90 : 0)).foregroundStyle(.secondary)
                        }.contentShape(Rectangle()).frame(minHeight: 44)
                    }.buttonStyle(.plain)
                        .accessibilityValue(showUninstalled ? "Shown" : "Hidden")
                    if showUninstalled {
                        LibraryCells(items: others, layout: layout, width: width) { item, list, dense in cell(item, list: list, dense: dense) }
                    }
                }
            }
        }
        .onAppear { itch.start(); itch.reconcileSession() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { itch.reconcileSession() } }
        .sheet(item: $selected) { selection in
            ItchGameSheet(gameID: selection.id) { entry in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open(entry) }
            }
        }
        .sheet(isPresented: $showSignIn) { ItchSignInView() }
        .sheet(isPresented: $showFind) {
            ItchFindView { id in
                showFind = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { selected = ItchSelection(id: id) }
            }
        }
        .alert("itch.io", isPresented: Binding(get: { itch.error != nil }, set: { if !$0 { itch.error = nil } })) {
            Button("OK", role: .cancel) { itch.error = nil }
        } message: { Text(itch.error ?? "") }
    }

    private func cell(_ item: ItchItem, list: Bool, dense: Bool) -> some View {
        Button {
            if let installed = item.installed, itch.downloads[item.id] == nil {
                open(library.itchEntry(installed))
            } else {
                selected = ItchSelection(id: item.id)
            }
        } label: { ItchGameCell(item: item, list: list, dense: dense) }
            .libraryCardButtonStyle(grid: !list)
    }
}

/// A game's artwork: the library entry's cover once installed, else itch.io's.
struct ItchGameArtwork: View {
    let item: ItchItem
    @ObservedObject private var library = LibraryModel.shared
    var body: some View {
        if let entry = library.entries.first(where: { $0.itchGameID == item.id }), entry.coverFile != nil {
            LibraryArtwork(entry: entry)
        } else {
            GeometryReader { geometry in
                ZStack {
                    Color(uiColor: .secondarySystemFill)
                    Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(.secondary)
                    AsyncImage(url: item.cover) { image in
                        image.resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } placeholder: { Color.clear }
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }.accessibilityHidden(true)
        }
    }
}

struct ItchGameCell: View {
    let item: ItchItem
    var list = false
    var dense = false
    @ObservedObject private var itch = ItchLibrary.shared
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        let download = itch.downloads[item.id]
        let entry = library.entries.first { $0.itchGameID == item.id }
        Group {
            if list && dense {
                HStack(spacing: 10) {
                    ItchGameArtwork(item: item).frame(width: 42, height: 33).clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    pills(download, entry).fixedSize()
                }.padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            } else if list {
                HStack(spacing: 14) {
                    ItchGameArtwork(item: item).frame(width: 72, height: 57)
                        .overlay { overlay(download) }.clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.headline).lineLimit(2)
                        if let download { ItchDownloadStatus(download: download) } else { pills(nil, entry) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    // itch.io's covers are 315x250.
                    ItchGameArtwork(item: item).aspectRatio(315.0 / 250.0, contentMode: .fit)
                        .overlay { overlay(download) }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    pills(download, entry)
                }.padding(4)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        .task(id: entry?.id, priority: .utility) { if let id = entry?.id { await library.refreshMetadata(id) } }
    }

    @ViewBuilder private func pills(_ download: ItchLibrary.Download?, _ entry: LibraryEntry?) -> some View {
        if let download {
            badge(ItchDownloadStatus.state(download))
        } else if item.installed != nil, let entry {
            LibraryBadges(entry: entry, note: itch.updateAvailable(item.id) ? "Update" : item.installed?.setup != nil ? "Installer" : nil)
                .foregroundStyle(.secondary)
        } else if item.installed == nil {
            badge("Not installed")
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private func overlay(_ download: ItchLibrary.Download?) -> some View {
        if let download {
            ZStack {
                Color.black.opacity(0.45)
                switch download.state {
                case .active: ProgressView(value: download.progress.fraction).progressViewStyle(.circular).tint(.white)
                case .queued: Image(systemName: "clock").font(.title2).foregroundStyle(.white)
                case .paused: Image(systemName: "pause.circle.fill").font(.title).foregroundStyle(.white)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.yellow)
                }
            }
        }
    }
}

private func itchBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

/// Progress, speed and the state of one download.
struct ItchDownloadStatus: View {
    let download: ItchLibrary.Download

    static func state(_ download: ItchLibrary.Download) -> String {
        switch download.state {
        case .queued: return "Waiting"
        case .active: return download.progress.phase == .unpacking ? "Unpacking" : "Downloading \(Int(download.progress.fraction * 100))%"
        case .paused: return "Paused"
        case .failed: return "Download failed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: download.progress.fraction)
            Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var caption: String {
        let p = download.progress
        switch download.state {
        case .queued: return "Waiting for the other itch.io download to finish…"
        case .paused: return p.totalBytes > 0 ? "Paused at \(Int(p.fraction * 100))%" : "Paused"
        case .failed(let message): return message
        case .active:
            switch p.phase {
            case .preparing: return "Finding the game's Windows download…"
            case .unpacking: return p.totalBytes > 0 ? "Unpacking… \(Int(p.fraction * 100))%" : "Unpacking…"
            case .downloading:
                var parts = ["\(Int(p.fraction * 100))%", "\(itchBytes(p.doneBytes)) of \(itchBytes(p.totalBytes))"]
                if p.bytesPerSecond > 0 {
                    parts.append("\(itchBytes(UInt64(p.bytesPerSecond)))/s")
                    let left = Double(p.totalBytes - min(p.doneBytes, p.totalBytes)) / p.bytesPerSecond
                    if left.isFinite, left > 60 { parts.append("about \(Int(left / 60) + 1) min left") }
                }
                return parts.joined(separator: " · ")
            }
        }
    }
}

// MARK: - Download sheet

struct ItchGameSheet: View {
    let gameID: Int
    var open: (LibraryEntry) -> Void
    @ObservedObject private var itch = ItchLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var freeSpace: Int64?
    @State private var confirmCancel = false

    var body: some View {
        let item = ItchGamesRules.items(itch, search: "").first { $0.id == gameID }
        NavigationStack {
            Form {
                if let item {
                    Section {
                        HStack(spacing: 20) {
                            ItchGameArtwork(item: item).frame(width: 150, height: 119).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 12) {
                                Text(item.title).font(.title2.bold())
                                primaryAction(item)
                            }
                        }.padding(.vertical, 24)
                    }
                    if let record = item.installed, record.setup != nil, itch.downloads[gameID] == nil {
                        Section("Installer") {
                            Text("This game comes with an installer. Run installer starts it in the Wine desktop, where it installs into the game's folder on its own (some installers ask a question or two). When it closes, leave the session: Madeira finds the game it installed, and from then on Play starts the game.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let download = itch.downloads[gameID] {
                        Section("Download") {
                            ItchDownloadStatus(download: download)
                            Button("Cancel download", role: .destructive) { confirmCancel = true }
                        }
                    }
                    Section {
                        if item.installed == nil {
                            switch itch.choices[gameID] {
                            case .upload(let upload):
                                LabeledContent("File", value: upload.displayName.isEmpty ? upload.filename : upload.displayName)
                                if upload.size > 0 { LabeledContent("Download size", value: ByteCountFormatter.string(fromByteCount: upload.size, countStyle: .file)) }
                                if upload.demo { Text("itch.io only offers a demo of this game for Windows.").font(.caption).foregroundStyle(.secondary) }
                                if [".exe", ".msi"].contains(where: { upload.filename.lowercased().hasSuffix($0) }) {
                                    Text("If this file is an installer, Play runs it once in the Wine desktop, into C:\\itch; after that, Play starts the game.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            case .unavailable(let reason):
                                if let owned = item.owned, !owned.owned, (owned.minPrice ?? 0) > 0 {
                                    Text("This game is not free and this itch.io account has not bought it. Buy it on its store page, then refresh the library.")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            case nil:
                                if itch.signedIn { LabeledContent("Download size") { ProgressView() } }
                            }
                        }
                        if let freeSpace { LabeledContent("Free space on this device", value: ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)) }
                        if let url = item.owned?.url { Link(destination: url) { Label("Store page", systemImage: "safari") } }
                        if item.installed == nil, itch.downloads[gameID] == nil, itch.added.contains(where: { $0.id == gameID }) {
                            Button("Remove from this library", role: .destructive) { itch.removeAdded(gameID); dismiss() }
                        }
                        Text("Games download directly from itch.io with your account into C:\\itch. Keep Madeira open while it downloads: in the background iOS allows only a short time, then the download pauses and continues when you return. A download also pauses while a game is running.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("Game unavailable", systemImage: "questionmark.square.dashed",
                                           description: Text("Refresh your itch.io library and try again."))
                }
            }
            .navigationTitle("itch.io").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: itch.downloads[gameID]?.state) { freeSpace = ItchLibrary.freeSpace(at: URL.documentsDirectory) }
            .task(id: gameID) { await itch.loadChoice(gameID) }
            .confirmationDialog("Cancel this download? What was downloaded is deleted.", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Cancel download", role: .destructive) { itch.cancel(gameID) }
                Button("Keep downloading", role: .cancel) {}
            }
        }
    }

    @ViewBuilder private func primaryAction(_ item: ItchItem) -> some View {
        if let download = itch.downloads[gameID] {
            switch download.state {
            case .active, .queued:
                Button { itch.pause(gameID) } label: { steamActionLabel("Pause", symbol: "pause.fill") }.buttonStyle(.bordered)
            case .paused:
                Button { itch.install(gameID) } label: { steamActionLabel("Resume", symbol: "arrow.down.circle.fill") }.buttonStyle(.borderedProminent)
            case .failed:
                Button { itch.install(gameID) } label: { steamActionLabel("Try again", symbol: "arrow.clockwise") }.buttonStyle(.borderedProminent)
            }
        } else if let installed = item.installed {
            Button {
                let entry = LibraryModel.shared.itchEntry(installed)
                dismiss(); open(entry)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: installed.setup != nil ? "shippingbox.fill" : "play.fill")
                    Text(installed.setup != nil ? "Run installer" : "Open").fontWeight(.semibold)
                }.frame(minWidth: 100, minHeight: 30)
            }.buttonStyle(.borderedProminent)
        } else if item.owned != nil {
            Button { itch.install(gameID) } label: {
                steamActionLabel(itch.hasPartialDownload(gameID) ? "Resume download" : "Install", symbol: "arrow.down.circle.fill")
            }.buttonStyle(.borderedProminent).disabled(!itch.signedIn)
        }
    }
}

// MARK: - Game details

/// The itch.io section of an itch.io game's Game details page.
struct ItchEntrySection: View {
    @Binding var entry: LibraryEntry
    var uninstalled: () -> Void
    @ObservedObject private var itch = ItchLibrary.shared
    @State private var confirmUninstall = false

    var body: some View {
        let id = entry.itchGameID ?? 0
        let record = itch.installed[id]
        let download = itch.downloads[id]
        Section {
            if !itch.signedIn {
                Text("Sign in to itch.io in Settings › itch.io to update this game. It plays without a sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let download {
                ItchDownloadStatus(download: download)
                switch download.state {
                case .active, .queued: Button("Pause download") { itch.pause(id) }
                case .paused, .failed: Button("Resume download") { itch.install(id) }
                }
            } else if itch.updateAvailable(id) {
                Button { itch.install(id) } label: { Label("Update available — download", systemImage: "arrow.down.circle") }
                    .disabled(!itch.signedIn)
            }
            if let record {
                if !record.version.isEmpty { LabeledContent("Version", value: record.version) }
                LabeledContent(record.setup != nil ? "Installer" : "Program", value: record.launchExe)
            }
            LabeledContent("itch.io game ID", value: "\(id)")
            if record != nil, download == nil {
                Button("Uninstall", role: .destructive) { confirmUninstall = true }
            }
        } header: {
            Text("itch.io")
        } footer: {
            Text(record?.setup != nil
                 ? "Play runs this game's installer in the Wine desktop. Once it has installed the game, Madeira switches Play to the game's own program."
                 : "The game starts its own program in Wine. If Madeira picked the wrong program, change it in Launch.")
        }
        .task(id: id) { await itch.loadChoice(id, force: true) }
        .confirmationDialog("Uninstall \(entry.title)? Its downloaded files are deleted from this device. Saves stored elsewhere are kept.",
                            isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                itch.uninstall(id)
                uninstalled()
            }
        }
    }
}

// MARK: - Find a game

/// Search itch.io, or paste a game's link, and add a game to the itch.io library.
struct ItchFindView: View {
    /// A game was added (or was already there): its download sheet opens.
    var chosen: (Int) -> Void
    @ObservedObject private var itch = ItchLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var results: [ItchOwnedGame] = []
    @State private var busy = false
    @State private var failure: String?
    @State private var searched = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Game name, or its itch.io link", text: $text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search).onSubmit(run)
                    Button { run() } label: {
                        HStack { Label(ItchLibrary.isLink(text) ? "Open this link" : "Search itch.io", systemImage: "magnifyingglass"); if busy { Spacer(); ProgressView() } }
                    }.disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Free games (and pay-what-you-want ones) install without buying. A paid game needs buying on itch.io first; it then shows in the library by itself, as do the games in your itch.io collections.")
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
                if searched && results.isEmpty && failure == nil && !busy {
                    Section { Text("No Windows games found.").foregroundStyle(.secondary) }
                }
                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { game in row(game) }
                    }
                }
            }
            .navigationTitle("Find a game").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func row(_ game: ItchOwnedGame) -> some View {
        let inLibrary = itch.owned.first { $0.id == game.id }
        let free = (game.minPrice ?? 0) == 0
        return HStack(spacing: 12) {
            AsyncImage(url: game.cover) { image in image.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                Color.secondary.opacity(0.15)
            }.frame(width: 63, height: 50).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(game.title).font(.headline).lineLimit(2)
                Text([game.author, inLibrary != nil ? "In your library" : free ? "Free" : "Paid"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if inLibrary != nil {
                Button("Open") { chosen(game.id) }.buttonStyle(.bordered)
            } else if free {
                Button("Add") { itch.add(game); chosen(game.id) }.buttonStyle(.borderedProminent)
            } else if let url = game.url {
                Link("Buy", destination: url).buttonStyle(.bordered)
            }
        }
    }

    private func run() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !busy else { return }
        busy = true; failure = nil
        Task {
            do {
                if ItchLibrary.isLink(query) { results = [try await itch.lookUp(link: query)] }
                else { results = try await itch.search(query) }
            } catch {
                results = []
                failure = error.localizedDescription
            }
            searched = true
            busy = false
        }
    }
}

// MARK: - Settings and sign-in

struct ItchSettingsSection: View {
    @ObservedObject private var itch = ItchLibrary.shared
    @State private var confirmSignOut = false
    @State private var showSignIn = false

    var body: some View {
        Section {
            if itch.signedIn {
                LabeledContent("Signed in as", value: itch.accountName ?? "itch.io account")
                Button("Sign out of itch.io", role: .destructive) { confirmSignOut = true }
            } else {
                Button { showSignIn = true } label: { Label("Sign in to itch.io", systemImage: "person.crop.circle.badge.plus") }
            }
        } header: {
            Text("itch.io")
        } footer: {
            Text("Madeira signs in with an API key you make on itch.io, kept in this device's Keychain for this device only. Signing out removes it; installed games stay and still play. You can also delete the key on itch.io at any time.")
        }
        .onAppear { itch.start() }
        .sheet(isPresented: $showSignIn) { ItchSignInView() }
        .confirmationDialog("Sign out of itch.io?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { itch.signOut() }
        }
    }
}

/// Signing in with an API key: itch.io's own page makes one, the player pastes it.
struct ItchSignInView: View {
    @ObservedObject private var itch = ItchLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Link(destination: ItchAPI.keysPage) { Label("1. Open itch.io's API keys page", systemImage: "safari") }
                    Text("2. Sign in there if asked, tap Generate new API key, then copy the key it shows.")
                    SecureField("3. Paste the key here", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.password)
                } footer: {
                    Text("The key lets Madeira see your itch.io library and download your games. It stays on this device.")
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .navigationTitle("itch.io").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Sign in") { submit() }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func submit() {
        busy = true; failure = nil
        Task {
            do {
                try await itch.signIn(key: key)
                busy = false
                dismiss()
            } catch {
                busy = false
                failure = error.localizedDescription
            }
        }
    }
}
