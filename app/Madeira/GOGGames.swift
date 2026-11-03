// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import WebKit

// The library's GOG section, a game's download sheet, its Game details section,
// Settings › GOG and the sign-in sheet (docs/GOG.md). The same shapes as the Steam
// views (SteamGames.swift).

/// One game in the section: owned, installed by Madeira, or both.
struct GOGItem: Identifiable {
    let id: String
    var title: String
    var cover: URL?
    var owned: GOGOwnedGame?
    var installed: GOGInstalledGame?
}

enum GOGGamesRules {
    /// Installed games and the account's other games, by title, filtered by the search.
    @MainActor static func items(_ gog: GOGLibrary, search: String) -> [GOGItem] {
        var items: [String: GOGItem] = [:]
        for game in gog.owned {
            items[game.id] = GOGItem(id: game.id, title: game.title, cover: game.cover, owned: game)
        }
        for (id, record) in gog.installed {
            items[id, default: GOGItem(id: id, title: record.title)].installed = record
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        return items.values
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

extension LibraryModel {
    /// An installed GOG game's library entry (its Game details page and settings); a
    /// game without one gets a new entry, saved when its details page closes.
    func gogEntry(_ game: GOGInstalledGame) -> LibraryEntry {
        if var entry = entries.first(where: { $0.gogProductID == game.productID }) {
            entry.relativePath = game.programPath
            return entry
        }
        var entry = LibraryEntry(title: game.title, relativePath: game.programPath, bits: 0)
        entry.gogProductID = game.productID
        entry.arguments = game.arguments
        entry.workingDirectory = game.workingWindowsPath
        entry.folderBytes = game.installBytes
        return entry
    }
}

// MARK: - Library section

struct GOGGamesSection: View {
    let search: String
    var layout = "cards"
    var width: CGFloat = 390
    /// Opens a game's Game details page (LibraryView's details sheet).
    let open: (LibraryEntry) -> Void
    @ObservedObject private var gog = GOGLibrary.shared
    @ObservedObject private var library = LibraryModel.shared
    @AppStorage("madeiraLibraryHideGOG") private var hidden = false
    @AppStorage("madeiraGOGShowUninstalled") private var showUninstalled = true
    /// In the zoomable grid the section sits in a collection view cell: the grid's page attaches GOGSheets (LibraryGridPage.swift).
    var inGrid = false
    @ObservedObject private var sheets = LibraryStoreSheets.shared

    var body: some View {
        let items = GOGGamesRules.items(gog, search: search)
        let mine = items.filter { $0.installed != nil || gog.downloads[$0.id] != nil }
        let others = items.filter { $0.installed == nil && gog.downloads[$0.id] == nil }
        let collapsible = SteamGamesSection.collapsible
        VStack(alignment: .leading, spacing: 14) {
            LibrarySectionHeader(title: "GOG", count: mine.count, collapsed: collapsible ? $hidden : nil) {
                if gog.refreshing { ProgressView().accessibilityLabel("Refreshing GOG library") }
            }
            if !(hidden && collapsible) {
                if !gog.signedIn {
                    GOGSignInCard { sheets.gogSignIn = true }
                }
                if !mine.isEmpty {
                    LibraryCells(items: mine, layout: layout, width: width) { item, list, dense in cell(item, list: list, dense: dense) }
                } else if gog.signedIn && !gog.refreshing && others.isEmpty && search.isEmpty {
                    Text(gog.libraryUpdated == nil ? "Pull down to load your GOG library."
                         : "No Windows games were found in this GOG library.").foregroundStyle(.secondary)
                }
                if gog.signedIn && !others.isEmpty {
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
        .modifier(GOGSheets(open: open, attached: !inGrid))
    }

    private func cell(_ item: GOGItem, list: Bool, dense: Bool) -> some View {
        Button {
            if let installed = item.installed, gog.downloads[item.id] == nil {
                open(library.gogEntry(installed))
            } else {
                sheets.gogGame = .init(id: item.id)
            }
        } label: { GOGGameCell(item: item, list: list, dense: dense) }
            .libraryCardButtonStyle(grid: !list)
    }
}

/// What the GOG section's page owns: the library's start and its reconcile after every session, the download and sign-in
/// sheets and the error alert. The section attaches it on the original page; the zoomable grid's page attaches it itself,
/// as it does Steam's (a sheet would belong to a collection view cell, which the grid can reuse).
struct GOGSheets: ViewModifier {
    let open: (LibraryEntry) -> Void
    var attached = true
    @ObservedObject private var gog = GOGLibrary.shared
    @ObservedObject private var sheets = LibraryStoreSheets.shared
    @Environment(\.scenePhase) private var scenePhase

    @ViewBuilder func body(content: Content) -> some View {
        if attached {
            content
            // The library reappears after every session: downloads continue then.
            .onAppear { if GOGLibrary.enabled { gog.start(); gog.reconcileSession() } }
            .onChange(of: scenePhase) { _, phase in if phase == .active && GOGLibrary.enabled { gog.reconcileSession() } }
            .sheet(item: $sheets.gogGame) { selection in
                GOGGameSheet(productID: selection.id) { entry in
                    // Let the download sheet finish dismissing before presenting the details page.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open(entry) }
                }
            }
            .sheet(isPresented: $sheets.gogSignIn) { GOGSignInView() }
            .alert("GOG", isPresented: Binding(get: { gog.error != nil }, set: { if !$0 { gog.error = nil } })) {
                Button("OK", role: .cancel) { gog.error = nil }
            } message: { Text(gog.error ?? "") }
        } else {
            content
        }
    }
}

/// The signed-out section's invitation to sign in.
struct GOGSignInCard: View {
    var signIn: () -> Void
    var body: some View {
        Button(action: signIn) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to GOG").font(.headline)
                    Text("See your GOG games here and install them without leaving Madeira.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}

/// A game's artwork: the library entry's cover once installed, else GOG's.
struct GOGGameArtwork: View {
    let item: GOGItem
    @ObservedObject private var library = LibraryModel.shared
    var body: some View {
        if let entry = library.entries.first(where: { $0.gogProductID == item.id }), entry.coverFile != nil {
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

struct GOGGameCell: View {
    let item: GOGItem
    var list = false
    var dense = false
    @ObservedObject private var gog = GOGLibrary.shared
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        let download = gog.downloads[item.id]
        let entry = library.entries.first { $0.gogProductID == item.id }
        Group {
            if list && dense {
                HStack(spacing: 10) {
                    GOGGameArtwork(item: item).frame(width: 28, height: 42).clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    pills(download, entry).fixedSize()
                }.padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            } else if list {
                HStack(spacing: 14) {
                    GOGGameArtwork(item: item).frame(width: 48, height: 72)
                        .overlay { overlay(download) }.clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.headline).lineLimit(2)
                        if let download { GOGDownloadStatus(download: download) } else { pills(nil, entry) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    GOGGameArtwork(item: item).aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .overlay { overlay(download) }
                        .overlay { if item.installed == nil && download == nil { notDownloaded } }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    pills(download, entry)
                }.padding(4)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        // Install size and graphics API, as for any library game.
        .task(id: entry?.id, priority: .utility) { if let id = entry?.id { await library.refreshMetadata(id) } }
    }

    @ViewBuilder private func pills(_ download: GOGLibrary.Download?, _ entry: LibraryEntry?) -> some View {
        if let download {
            badge(state(download))
        } else if item.installed != nil, let entry {
            LibraryBadges(entry: entry, note: gog.updateAvailable(item.id) ? "Update" : nil).foregroundStyle(.secondary)
        } else if item.installed == nil {
            badge("Not installed")
        }
    }

    private func state(_ download: GOGLibrary.Download) -> String {
        switch download.state {
        case .queued: return "Waiting"
        case .active: return download.progress.phase == .verifying ? "Checking files" : "Downloading \(Int(download.progress.fraction * 100))%"
        case .paused: return "Paused"
        case .failed: return "Download failed"
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.secondary)
    }

    private var notDownloaded: some View {
        ZStack {
            Color.black.opacity(0.4)
            Image(systemName: "icloud.and.arrow.down").font(.largeTitle.weight(.medium)).foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder private func overlay(_ download: GOGLibrary.Download?) -> some View {
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

private func gogBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

/// Progress, speed and the state of one download.
struct GOGDownloadStatus: View {
    let download: GOGLibrary.Download
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: download.progress.fraction)
            Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
    private var caption: String {
        let p = download.progress
        switch download.state {
        case .queued: return "Waiting for the other GOG download to finish…"
        case .paused: return p.totalBytes > 0 ? "Paused at \(Int(p.fraction * 100))%" : "Paused"
        case .failed(let message): return message
        case .active:
            switch p.phase {
            case .preparing: return p.step.map { $0 + "…" } ?? "Preparing download…"
            case .verifying: return "Checking installed files… \(Int(p.fraction * 100))%"
            case .finishing: return "Finishing…"
            case .downloading:
                var parts = ["\(Int(p.fraction * 100))%", "\(gogBytes(p.doneBytes)) of \(gogBytes(p.totalBytes))"]
                if p.bytesPerSecond > 0 {
                    parts.append("\(gogBytes(UInt64(p.bytesPerSecond)))/s")
                    let left = Double(p.totalBytes - min(p.doneBytes, p.totalBytes)) / p.bytesPerSecond
                    if left.isFinite, left > 60 { parts.append("about \(Int(left / 60) + 1) min left") }
                }
                return parts.joined(separator: " · ")
            }
        }
    }
}

// MARK: - Download sheet

struct GOGGameSheet: View {
    let productID: String
    /// Opens the installed game's Game details page (after this sheet closes).
    var open: (LibraryEntry) -> Void
    @ObservedObject private var gog = GOGLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var freeSpace: Int64?
    @State private var confirmCancel = false

    var body: some View {
        let item = GOGGamesRules.items(gog, search: "").first { $0.id == productID }
        NavigationStack {
            Form {
                if let item {
                    Section {
                        HStack(spacing: 20) {
                            GOGGameArtwork(item: item).frame(width: 120, height: 180).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 12) {
                                Text(item.title).font(.title2.bold())
                                primaryAction(item)
                            }
                        }.padding(.vertical, 24)
                    }
                    if let download = gog.downloads[productID] {
                        Section("Download") {
                            GOGDownloadStatus(download: download)
                            Button("Cancel download", role: .destructive) { confirmCancel = true }
                            if case .failed = download.state {
                                Text("Finished files are kept. Try again to continue where it stopped.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        if item.installed == nil {
                            switch gog.sizes[productID] {
                            case .known(let download, let install):
                                if download > 0 { LabeledContent("Download size", value: "About " + ByteCountFormatter.string(fromByteCount: download, countStyle: .file)) }
                                if install > 0 { LabeledContent("Size on this device", value: "About " + ByteCountFormatter.string(fromByteCount: install, countStyle: .file)) }
                            case .unavailable(let reason):
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            case nil:
                                if gog.signedIn { LabeledContent("Download size") { ProgressView() } }
                            }
                        }
                        if let freeSpace { LabeledContent("Free space on this device", value: ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)) }
                        Text("Games download directly from GOG with your account into C:\\GOG Games, with the DLC you own. Keep Madeira open while it downloads: in the background iOS allows only a short time, then the download pauses and continues when you return. A download also pauses while a game is running.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("Game unavailable", systemImage: "questionmark.square.dashed",
                                           description: Text("Refresh your GOG library and try again."))
                }
            }
            .navigationTitle("GOG").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: gog.downloads[productID]?.state) {
                freeSpace = GOGDownloader.freeSpace(at: URL.documentsDirectory)
            }
            .task(id: productID) { await gog.loadSize(productID) }
            .confirmationDialog(gog.installed[productID] == nil ? "Cancel this download? Downloaded files are deleted." : "Stop this download?",
                                isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Cancel download", role: .destructive) { gog.cancel(productID) }
                Button("Keep downloading", role: .cancel) {}
            }
        }
    }

    @ViewBuilder private func primaryAction(_ item: GOGItem) -> some View {
        if let download = gog.downloads[productID] {
            switch download.state {
            case .active, .queued:
                Button { gog.pause(productID) } label: { steamActionLabel("Pause", symbol: "pause.fill") }.buttonStyle(.bordered)
            case .paused:
                Button { gog.install(productID) } label: { steamActionLabel("Resume", symbol: "arrow.down.circle.fill") }.buttonStyle(.borderedProminent)
            case .failed:
                Button { gog.install(productID) } label: { steamActionLabel("Try again", symbol: "arrow.clockwise") }.buttonStyle(.borderedProminent)
            }
        } else if let installed = item.installed {
            Button {
                let entry = LibraryModel.shared.gogEntry(installed)
                dismiss(); open(entry)
            } label: {
                HStack(spacing: 10) { Image(systemName: "play.fill"); Text("Open").fontWeight(.semibold) }.frame(minWidth: 100, minHeight: 30)
            }.buttonStyle(.borderedProminent)
        } else if item.owned != nil {
            Button { gog.install(productID) } label: {
                steamActionLabel(gog.hasPartialDownload(productID) ? "Resume download" : "Install", symbol: "arrow.down.circle.fill")
            }.buttonStyle(.borderedProminent).disabled(!gog.signedIn)
        }
    }
}

// MARK: - Game details

/// A GOG game's redistributables (GOGSetup): each installer's state in this prefix,
/// and those left out with the reason.
struct GOGSetupRows: View {
    let record: GOGInstalledGame

    var body: some View {
        let programs = record.setup ?? []
        let notes = record.setupNotes ?? []
        if record.setup == nil {
            Text("Installed before Madeira added GOG's redistributables. Repair installed files adds them.")
                .font(.caption).foregroundStyle(.secondary)
        } else if !programs.isEmpty || !notes.isEmpty {
            DisclosureGroup("Redistributables (\(programs.count + notes.count))") {
                ForEach(programs, id: \.id) { program in
                    LabeledContent(program.name, value: Self.text(GOGSetup.state(program.id, drive: LibraryModel.drive)))
                }
                ForEach(notes, id: \.name) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.name)
                        Text(note.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    static func text(_ state: GOGSetup.State) -> String {
        switch state {
        case .pending: return "Installs at the next start"
        case .done: return "Installed"
        case .failed(let code): return "Failed (code \(code)); Repair runs it again"
        }
    }
}

/// The GOG section of a GOG game's Game details page.
struct GOGEntrySection: View {
    @Binding var entry: LibraryEntry
    /// The game was uninstalled: the page closes without saving.
    var uninstalled: () -> Void
    @ObservedObject private var gog = GOGLibrary.shared
    @State private var confirmUninstall = false
    /// The programs the game can start with (GOGLibrary.programChoices), read when the page opens.
    @State private var programs: [GOGLibrary.ProgramChoice] = []

    var body: some View {
        let id = entry.gogProductID ?? ""
        let record = gog.installed[id]
        let download = gog.downloads[id]
        Section {
            if !gog.signedIn {
                Text("Sign in to GOG in Settings › GOG to update this game. It plays without a sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let download {
                GOGDownloadStatus(download: download)
                switch download.state {
                case .active, .queued: Button("Pause download") { gog.pause(id) }
                case .paused, .failed: Button("Resume download") { gog.install(id) }
                }
            } else if gog.updateAvailable(id) {
                Button { gog.install(id) } label: { Label("Update available — download", systemImage: "arrow.down.circle") }
                    .disabled(!gog.signedIn)
            }
            if download == nil, record != nil {
                Button { gog.repair(id) } label: { Label("Repair installed files", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(!gog.signedIn)
                Text("Checks every installed file against GOG's current build and downloads what is missing or changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let record {
                LabeledContent("Version", value: record.versionName.isEmpty ? record.buildID : record.versionName)
                LabeledContent("Language", value: record.language == "*" ? "Default" : record.language)
                if !record.dlc.isEmpty { LabeledContent("DLC installed", value: "\(record.dlc.count)") }
                if programs.count > 1, download == nil {
                    Picker("Program", selection: Binding(get: { record.launchExe.lowercased() }, set: { pick($0, id: id) })) {
                        ForEach(programs) { Text($0.name).tag($0.id) }
                    }
                    Text("Which program Play starts. Pick the game itself when its launcher closes without starting it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if record.galaxy != nil, GOGGalaxy.enabled {
                    LabeledContent("Achievements and stats", value: gog.signedIn ? "On while it runs" : "Sign in to GOG")
                }
                GOGSetupRows(record: record)
            }
            LabeledContent("Product ID", value: id)
            if record != nil, download == nil {
                Button("Uninstall", role: .destructive) { confirmUninstall = true }
            }
        } header: {
            Text("GOG")
        } footer: {
            Text("The game starts its own program in Wine, as GOG Galaxy would. Madeira stands in for GOG Galaxy while the game runs, so a game that uses Galaxy gets its achievements and stats. Galaxy cloud saves are not available yet.")
        }
        .task(id: id) {
            if let record = gog.installed[id] {
                let folder = GOGLibrary.drive.appendingPathComponent(record.folder, isDirectory: true)
                programs = await Task.detached(priority: .userInitiated) { GOGLibrary.programChoices(folder: folder, product: id) }.value
            }
            await gog.checkForUpdate(id)
        }
        .confirmationDialog("Uninstall \(entry.title)? Its downloaded files are deleted from this device. Saves stored elsewhere are kept.",
                            isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                gog.uninstall(id)
                uninstalled()
            }
        }
    }

    /// The page's entry follows the chosen program; arguments and working folder follow
    /// GOG's play task unless the player changed them.
    private func pick(_ key: String, id: String) {
        guard let previous = gog.installed[id], let choice = programs.first(where: { $0.id == key }) else { return }
        gog.chooseProgram(id, choice)
        guard let updated = gog.installed[id] else { return }
        entry.relativePath = updated.programPath
        if entry.arguments == previous.arguments { entry.arguments = updated.arguments }
        if entry.workingDirectory == previous.workingWindowsPath { entry.workingDirectory = updated.workingWindowsPath }
        if let inspected = try? LibraryModel.inspect(GOGLibrary.drive.appendingPathComponent(updated.programPath)) {
            entry.bits = inspected.bits
            entry.graphicsAPI = inspected.graphicsAPI ?? entry.graphicsAPI
        }
    }
}

// MARK: - Settings

struct GOGSettingsSection: View {
    let open: (SettingsSheet) -> Void
    @ObservedObject private var gog = GOGLibrary.shared
    @State private var confirmSignOut = false

    var body: some View {
        Section {
            if gog.signedIn {
                LabeledContent("Signed in as", value: gog.accountName ?? "GOG account")
                Button("Sign out of GOG", role: .destructive) { confirmSignOut = true }
            } else {
                Button { open(.gogSignIn) } label: { Label("Sign in to GOG", systemImage: "person.crop.circle.badge.plus") }
            }
        } header: {
            Text("GOG")
        } footer: {
            Text("Madeira keeps a GOG sign-in token in this device's Keychain, for this device only. Signing out removes it; installed games stay and still play.")
        }
        .onAppear { gog.start() }
        .confirmationDialog("Sign out of GOG?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { gog.signOut() }
        }
    }
}

// MARK: - Sign-in

/// GOG's own login page in a web view. When the login finishes, GOG sends the page
/// to embed.gog.com/on_login_success with a one-use code in the address; Madeira
/// reads it and signs in. That address can also be pasted, for logins the web view
/// cannot complete.
struct GOGSignInView: View {
    @ObservedObject private var gog = GOGLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var failure: String?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var reload = 0

    var body: some View {
        NavigationStack {
            Group {
                if gog.signedIn {
                    Form {
                        LabeledContent("Signed in as", value: gog.accountName ?? "GOG account")
                        Button("Sign out", role: .destructive) { gog.signOut() }
                    }
                } else {
                    GOGLoginWebView(reload: reload) { code in submit(code) }
                        .ignoresSafeArea(edges: .bottom)
                        .overlay {
                            if busy {
                                ProgressView("Signing in…").padding(20)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                }
            }
            .navigationTitle("GOG").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !gog.signedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Paste the sign-in address", systemImage: "doc.on.clipboard") { pasted = ""; pasting = true }
                            Link(destination: GOGAPI.loginURL) { Label("Open the login page in Safari", systemImage: "safari") }
                            Button("Reload", systemImage: "arrow.clockwise") { reload += 1 }
                        } label: { Label("More", systemImage: "ellipsis.circle") }
                    }
                }
            }
            .alert("Sign in with an address", isPresented: $pasting) {
                TextField("https://embed.gog.com/on_login_success?…", text: $pasted).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Sign in") { submit(pasted) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Open the login page in Safari and sign in. GOG then opens a page whose address starts with embed.gog.com/on_login_success. Copy that whole address and paste it here.")
            }
            .alert("GOG", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil; reload += 1 }
            } message: { Text(failure ?? "") }
        }
    }

    private func submit(_ text: String) {
        guard !busy else { return }
        guard let code = GOGAPI.authorizationCode(in: text) else {
            failure = "This is not a GOG sign-in address. Copy the address of the page GOG opens after you sign in."
            return
        }
        busy = true
        Task {
            do {
                try await gog.signIn(code: code)
                busy = false
                dismiss()
            } catch {
                busy = false
                failure = error.localizedDescription
            }
        }
    }
}

/// WKWebView with GOG's login page, in a private (non-persistent) data store. The
/// redirect to embed.gog.com/on_login_success is stopped and its address handed on.
struct GOGLoginWebView: UIViewRepresentable {
    var reload: Int
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: GOGAPI.loginURL))
        context.coordinator.loadedReload = reload
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onCode = onCode
        if context.coordinator.loadedReload != reload {
            context.coordinator.loadedReload = reload
            context.coordinator.delivered = false
            view.load(URLRequest(url: GOGAPI.loginURL))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onCode: (String) -> Void
        var loadedReload = 0
        var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, GOGAPI.isRedirectPage(url) {
                decisionHandler(.cancel)
                deliver(url)
                return
            }
            decisionHandler(.allow)
        }

        /// The redirect page loaded after all (a server-side redirect): its address has the code.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url, GOGAPI.isRedirectPage(url) { deliver(url) }
        }

        private func deliver(_ url: URL) {
            guard !delivered, GOGAPI.authorizationCode(in: url.absoluteString) != nil else { return }
            delivered = true
            onCode(url.absoluteString)
        }

        /// Links that open a new window (some sign-in providers) load in this one.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
