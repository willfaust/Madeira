// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Akshay CM
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import WebKit

// The library's Epic Games section, a game's download sheet, its Game details
// section, Settings › Epic Games and the sign-in sheet (docs/EPIC_GAMES.md).

/// One game in the section: owned, installed by Madeira, or both.
struct EpicItem: Identifiable {
    let id: String
    var title: String
    var cover: URL?
    var owned: EpicOwnedGame?
    var installed: EpicInstalledGame?
}

enum EpicGamesRules {
    /// Installed games and the account's other games, by title, filtered by the search.
    @MainActor static func items(_ epic: EpicLibrary, search: String) -> [EpicItem] {
        var items: [String: EpicItem] = [:]
        for game in epic.owned {
            items[game.appName] = EpicItem(id: game.appName, title: game.title, cover: game.cover, owned: game)
        }
        for (app, record) in epic.installed {
            items[app, default: EpicItem(id: app, title: record.title)].installed = record
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        return items.values
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

extension LibraryModel {
    /// An installed Epic game's library entry (its Game details page and settings); a
    /// game without one gets a new entry, saved when its details page closes.
    func epicEntry(_ game: EpicInstalledGame) -> LibraryEntry {
        if var entry = entries.first(where: { $0.epicAppName == game.appName }) {
            entry.relativePath = game.programPath
            return entry
        }
        var entry = LibraryEntry(title: game.title, relativePath: game.programPath, bits: 0)
        entry.epicAppName = game.appName
        entry.folderBytes = game.installBytes
        return entry
    }
}

private func epicBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

// MARK: - Library section

struct EpicGamesSection: View {
    let search: String
    var layout = "cards"
    var width: CGFloat = 390
    /// Opens a game's Game details page (LibraryView's details sheet).
    let open: (LibraryEntry) -> Void
    @ObservedObject private var epic = EpicLibrary.shared
    @ObservedObject private var library = LibraryModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("madeiraLibraryHideEpic") private var hidden = false
    @AppStorage("madeiraEpicShowUninstalled") private var showUninstalled = true
    @State private var selected: EpicSelection?
    @State private var showSignIn = false

    private struct EpicSelection: Identifiable { let id: String }

    var body: some View {
        let items = EpicGamesRules.items(epic, search: search)
        let mine = items.filter { $0.installed != nil || epic.downloads[$0.id] != nil }
        let others = items.filter { $0.installed == nil && epic.downloads[$0.id] == nil }
        let collapsible = SteamGamesSection.collapsible
        VStack(alignment: .leading, spacing: 14) {
            LibrarySectionHeader(title: "Epic Games", count: mine.count, collapsed: collapsible ? $hidden : nil) {
                if epic.refreshing { ProgressView().accessibilityLabel("Refreshing Epic Games library") }
            }
            if !(hidden && collapsible) {
                if !epic.signedIn {
                    EpicSignInCard { showSignIn = true }
                }
                if !mine.isEmpty {
                    LibraryCells(items: mine, layout: layout, width: width) { item, list, dense in cell(item, list: list, dense: dense) }
                } else if epic.signedIn && !epic.refreshing && others.isEmpty && search.isEmpty {
                    Text(epic.libraryUpdated == nil ? "Pull down to load your Epic Games library."
                         : "No Windows games were found in this Epic Games library.").foregroundStyle(.secondary)
                }
                if epic.signedIn && !others.isEmpty {
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
        // The library reappears after every session: downloads continue then.
        .onAppear { epic.start(); epic.reconcileSession() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { epic.reconcileSession() } }
        .sheet(item: $selected) { selection in
            EpicGameSheet(appName: selection.id) { entry in
                // Let the download sheet finish dismissing before presenting the details page.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open(entry) }
            }
        }
        .sheet(isPresented: $showSignIn) { EpicSignInView() }
        .alert("Epic Games", isPresented: Binding(get: { epic.error != nil }, set: { if !$0 { epic.error = nil } })) {
            Button("OK", role: .cancel) { epic.error = nil }
        } message: { Text(epic.error ?? "") }
    }

    private func cell(_ item: EpicItem, list: Bool, dense: Bool) -> some View {
        Button {
            if let installed = item.installed, epic.downloads[item.id] == nil {
                open(library.epicEntry(installed))
            } else {
                selected = EpicSelection(id: item.id)
            }
        } label: { EpicGameCell(item: item, list: list, dense: dense) }
            .libraryCardButtonStyle(grid: !list)
    }
}

/// The signed-out section's invitation to sign in.
struct EpicSignInCard: View {
    var signIn: () -> Void
    var body: some View {
        Button(action: signIn) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to Epic Games").font(.headline)
                    Text("See your Epic Games games here and install them without leaving Madeira.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}

/// A game's artwork: the library entry's cover once installed, else Epic's.
struct EpicGameArtwork: View {
    let item: EpicItem
    @ObservedObject private var library = LibraryModel.shared
    var body: some View {
        if let entry = library.entries.first(where: { $0.epicAppName == item.id }), entry.coverFile != nil {
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

struct EpicGameCell: View {
    let item: EpicItem
    var list = false
    var dense = false
    @ObservedObject private var epic = EpicLibrary.shared
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        let download = epic.downloads[item.id]
        let entry = library.entries.first { $0.epicAppName == item.id }
        Group {
            if list && dense {
                HStack(spacing: 10) {
                    EpicGameArtwork(item: item).frame(width: 28, height: 42).clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    pills(download, entry).fixedSize()
                }.padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            } else if list {
                HStack(spacing: 14) {
                    EpicGameArtwork(item: item).frame(width: 48, height: 72)
                        .overlay { overlay(download) }.clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.headline).lineLimit(2)
                        if let download { EpicDownloadStatus(download: download) } else { pills(nil, entry) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    EpicGameArtwork(item: item).aspectRatio(2.0 / 3.0, contentMode: .fit)
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

    @ViewBuilder private func pills(_ download: EpicLibrary.Download?, _ entry: LibraryEntry?) -> some View {
        if let download {
            badge(state(download))
        } else if item.installed != nil, let entry {
            LibraryBadges(entry: entry, note: epic.updateAvailable(item.id) ? "Update" : nil).foregroundStyle(.secondary)
        } else if item.installed == nil {
            badge("Not installed")
        }
    }

    private func state(_ download: EpicLibrary.Download) -> String {
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

    @ViewBuilder private func overlay(_ download: EpicLibrary.Download?) -> some View {
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

/// Progress, speed and the state of one download.
struct EpicDownloadStatus: View {
    let download: EpicLibrary.Download
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
            case .verifying: return "Checking installed files… \(Int(p.fraction * 100))%"
            case .finishing: return "Finishing…"
            case .downloading:
                var parts = ["\(Int(p.fraction * 100))%", "\(epicBytes(p.doneBytes)) of \(epicBytes(p.totalBytes))"]
                if p.bytesPerSecond > 0 {
                    parts.append("\(epicBytes(UInt64(p.bytesPerSecond)))/s")
                    let left = Double(p.totalBytes - min(p.doneBytes, p.totalBytes)) / p.bytesPerSecond
                    if left.isFinite, left > 60 { parts.append("about \(Int(left / 60) + 1) min left") }
                }
                return parts.joined(separator: " · ")
            }
        }
    }
}

// MARK: - Download sheet

struct EpicGameSheet: View {
    let appName: String
    /// Opens the installed game's Game details page (after this sheet closes).
    var open: (LibraryEntry) -> Void
    @ObservedObject private var epic = EpicLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var freeSpace: Int64?
    @State private var confirmCancel = false

    var body: some View {
        let item = EpicGamesRules.items(epic, search: "").first { $0.id == appName }
        NavigationStack {
            Form {
                if let item {
                    Section {
                        HStack(spacing: 20) {
                            EpicGameArtwork(item: item).frame(width: 120, height: 180).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 12) {
                                Text(item.title).font(.title2.bold())
                                primaryAction(item)
                            }
                        }.padding(.vertical, 24)
                    }
                    if let download = epic.downloads[appName] {
                        Section("Download") {
                            EpicDownloadStatus(download: download)
                            Button("Cancel download", role: .destructive) { confirmCancel = true }
                            if case .failed = download.state {
                                Text("Finished files are kept. Try again to continue where it stopped.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        if let freeSpace { LabeledContent("Free space on this device", value: ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)) }
                        Text("Games download directly from Epic with your account into C:\\Program Files\\Epic Games. On iOS 26 and later the download continues in the background, with its progress shown by iOS. On earlier iOS, keep Madeira open while it downloads: in the background iOS allows only a short time, then the download pauses and continues when you return. A download also pauses while a game is running.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("Game unavailable", systemImage: "questionmark.square.dashed",
                                           description: Text("Refresh your Epic Games library and try again."))
                }
            }
            .navigationTitle("Epic Games").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: epic.downloads[appName]?.state) {
                freeSpace = EpicDownloader.freeSpace(at: URL.documentsDirectory)
            }
            .confirmationDialog(epic.installed[appName] == nil ? "Cancel this download? Downloaded files are deleted." : "Stop this download?",
                                isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Cancel download", role: .destructive) { epic.cancel(appName) }
                Button("Keep downloading", role: .cancel) {}
            }
        }
    }

    @ViewBuilder private func primaryAction(_ item: EpicItem) -> some View {
        if let download = epic.downloads[appName] {
            switch download.state {
            case .active, .queued:
                Button { epic.pause(appName) } label: { steamActionLabel("Pause", symbol: "pause.fill") }.buttonStyle(.bordered)
            case .paused:
                Button { epic.install(appName) } label: { steamActionLabel("Resume", symbol: "arrow.down.circle.fill") }.buttonStyle(.borderedProminent)
            case .failed:
                Button { epic.install(appName) } label: { steamActionLabel("Try again", symbol: "arrow.clockwise") }.buttonStyle(.borderedProminent)
            }
        } else if let installed = item.installed {
            Button {
                let entry = LibraryModel.shared.epicEntry(installed)
                dismiss(); open(entry)
            } label: {
                HStack(spacing: 10) { Image(systemName: "play.fill"); Text("Open").fontWeight(.semibold) }.frame(minWidth: 100, minHeight: 30)
            }.buttonStyle(.borderedProminent)
        } else if item.owned != nil {
            Button { epic.install(appName) } label: {
                steamActionLabel(epic.hasPartialDownload(appName) ? "Resume download" : "Install", symbol: "arrow.down.circle.fill")
            }.buttonStyle(.borderedProminent).disabled(!epic.signedIn)
        }
    }
}

// MARK: - Game details

/// The Epic Games section of an Epic game's Game details page.
struct EpicEntrySection: View {
    @Binding var entry: LibraryEntry
    /// The game was uninstalled: the page closes without saving.
    var uninstalled: () -> Void
    @ObservedObject private var epic = EpicLibrary.shared
    @State private var confirmUninstall = false

    var body: some View {
        let app = entry.epicAppName ?? ""
        let record = epic.installed[app]
        let download = epic.downloads[app]
        Section {
            if !epic.signedIn {
                Text("Sign in to Epic Games in Settings › Epic Games to play online and to update this game.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let download {
                EpicDownloadStatus(download: download)
                switch download.state {
                case .active, .queued: Button("Pause download") { epic.pause(app) }
                case .paused, .failed: Button("Resume download") { epic.install(app) }
                }
            } else if epic.updateAvailable(app) {
                Button { epic.install(app) } label: { Label("Update available — download", systemImage: "arrow.down.circle") }
                    .disabled(!epic.signedIn)
            }
            if download == nil, record != nil {
                Button { epic.repair(app) } label: { Label("Repair installed files", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(!epic.signedIn)
                Text("Checks every installed file against Epic's current build and downloads what is missing or changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let record {
                LabeledContent("Version", value: record.buildVersion)
                if !record.canRunOffline {
                    Text("Epic marks this game as online only: it starts only while Madeira can reach Epic.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if LibraryEntry.epicAntiCheatOffProgram[app] != nil {
                Toggle("Start without Easy Anti-Cheat", isOn: Binding(get: { entry.epicAntiCheatOff != false },
                                                                       set: { entry.epicAntiCheatOff = $0 ? nil : false }))
                Text("Easy Anti-Cheat cannot run in Wine on iOS. With this on, the game starts in its own offline mode without it: offline matches, training, LAN and replays work, online matches do not.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("App name", value: app)
            if record != nil, download == nil {
                Button("Uninstall", role: .destructive) { confirmUninstall = true }
            }
        } header: {
            Text("Epic Games")
        } footer: {
            Text("The game starts its own program in Wine. At every start Madeira asks Epic for a one-use sign-in code and passes it to the game, as Epic's launcher does, so the game signs in to Epic with your account. There is no Epic launcher in Madeira.")
        }
        .confirmationDialog("Uninstall \(entry.title)? Its downloaded files are deleted from this device. Saves stored elsewhere are kept.",
                            isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                epic.uninstall(app)
                uninstalled()
            }
        }
    }
}

// MARK: - Settings

struct EpicSettingsSection: View {
    let open: (SettingsSheet) -> Void
    @ObservedObject private var epic = EpicLibrary.shared
    @State private var confirmSignOut = false

    var body: some View {
        Section {
            if epic.signedIn {
                LabeledContent("Signed in as", value: epic.accountName ?? "Epic Games account")
                Button("Sign out of Epic Games", role: .destructive) { confirmSignOut = true }
            } else {
                Button { open(.epicSignIn) } label: { Label("Sign in to Epic Games", systemImage: "person.crop.circle.badge.plus") }
            }
        } header: {
            Text("Epic Games")
        } footer: {
            Text("Madeira keeps an Epic Games sign-in token in this device's Keychain, for this device only. Signing out removes it; installed games stay.")
        }
        .onAppear { epic.start() }
        .confirmationDialog("Sign out of Epic Games?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { epic.signOut() }
        }
    }
}

// MARK: - Sign-in

/// Epic's own login page in a web view. When the login finishes, Epic shows a
/// page with a one-use authorization code; Madeira reads it and signs in. The code
/// can also be pasted, for logins the web view cannot complete.
struct EpicSignInView: View {
    @ObservedObject private var epic = EpicLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var failure: String?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var reload = 0

    var body: some View {
        NavigationStack {
            Group {
                if epic.signedIn {
                    Form {
                        LabeledContent("Signed in as", value: epic.accountName ?? "Epic Games account")
                        Button("Sign out", role: .destructive) { epic.signOut() }
                    }
                } else {
                    EpicLoginWebView(reload: reload) { code in submit(code) }
                        .ignoresSafeArea(edges: .bottom)
                        .overlay {
                            if busy {
                                ProgressView("Signing in…").padding(20)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                }
            }
            .navigationTitle("Epic Games").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !epic.signedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Paste a sign-in code", systemImage: "doc.on.clipboard") { pasted = ""; pasting = true }
                            Link(destination: EpicAPI.loginURL) { Label("Open the login page in Safari", systemImage: "safari") }
                            Button("Reload", systemImage: "arrow.clockwise") { reload += 1 }
                        } label: { Label("More", systemImage: "ellipsis.circle") }
                    }
                }
            }
            .alert("Sign in with a code", isPresented: $pasting) {
                TextField("authorizationCode", text: $pasted).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Sign in") { submit(pasted) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Open the login page in Safari and sign in. Epic then shows a short text with \"authorizationCode\". Copy the whole text, or only the code, and paste it here.")
            }
            .alert("Epic Games", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil; reload += 1 }
            } message: { Text(failure ?? "") }
        }
    }

    private func submit(_ text: String) {
        guard !busy else { return }
        guard let code = EpicAPI.authorizationCode(in: text) else {
            failure = EpicAPI.correctiveAction(in: text).map(EpicAPI.correctiveMessage)
                ?? "This is not an Epic sign-in code. Copy the text Epic shows after you sign in."
            return
        }
        busy = true
        Task {
            do {
                try await epic.signIn(code: code)
                busy = false
                dismiss()
            } catch {
                busy = false
                failure = error.localizedDescription
            }
        }
    }
}

/// WKWebView with Epic's login page, in a private (non-persistent) data store.
struct EpicLoginWebView: UIViewRepresentable {
    var reload: Int
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: EpicAPI.loginURL))
        context.coordinator.loadedReload = reload
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onCode = onCode
        if context.coordinator.loadedReload != reload {
            context.coordinator.loadedReload = reload
            context.coordinator.delivered = false
            view.load(URLRequest(url: EpicAPI.loginURL))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onCode: (String) -> Void
        var loadedReload = 0
        var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !delivered, EpicAPI.isRedirectPage(webView.url) else { return }
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
                // A code, or Epic's request for an action on the account (shown as a message).
                guard let self, !self.delivered, let text = result as? String,
                      EpicAPI.authorizationCode(in: text) != nil || EpicAPI.correctiveAction(in: text) != nil else { return }
                self.delivered = true
                self.onCode(text)
            }
        }

        /// Links that open a new window (some sign-in providers) load in this one.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
