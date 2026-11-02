// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import WebKit

// The EA app section of the library (docs/EA.md): the account's games, their
// download sheet, the EA page of an installed game's details, the Settings
// section and the sign-in sheet. The model is EALibrary.swift.

struct EAItem: Identifiable {
    let id: String
    var title: String
    var cover: URL?
    var owned: EAOwnedGame?
    var installed: EAInstalledGame?
}

enum EAGamesRules {
    /// Installed games and the account's other games, by title, filtered by the search.
    @MainActor static func items(_ ea: EALibrary, search: String) -> [EAItem] {
        var items: [String: EAItem] = [:]
        for game in ea.owned {
            items[game.id] = EAItem(id: game.id, title: game.title, cover: game.cover, owned: game)
        }
        for (id, record) in ea.installed {
            items[id, default: EAItem(id: id, title: record.title)].installed = record
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        return items.values
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

extension LibraryModel {
    /// An installed EA game's library entry (its Game details page and settings); a
    /// game without one gets a new entry, saved when its details page closes.
    func eaEntry(_ game: EAInstalledGame) -> LibraryEntry {
        if var entry = entries.first(where: { $0.eaOfferID == game.offerID }) {
            entry.relativePath = game.programPath
            return entry
        }
        var entry = LibraryEntry(title: game.title, relativePath: game.programPath, bits: 0)
        entry.eaOfferID = game.offerID
        entry.arguments = game.arguments
        entry.folderBytes = game.installBytes
        return entry
    }
}

// MARK: - Library section

struct EAGamesSection: View {
    let search: String
    var layout = "cards"
    var width: CGFloat = 390
    /// Opens a game's Game details page (LibraryView's details sheet).
    let open: (LibraryEntry) -> Void
    @ObservedObject private var ea = EALibrary.shared
    @ObservedObject private var library = LibraryModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("madeiraLibraryHideEA") private var hidden = false
    @AppStorage("madeiraEAShowUninstalled") private var showUninstalled = true
    @State private var selected: EASelection?
    @State private var showSignIn = false

    private struct EASelection: Identifiable { let id: String }

    var body: some View {
        let items = EAGamesRules.items(ea, search: search)
        let mine = items.filter { $0.installed != nil || ea.downloads[$0.id] != nil }
        let others = items.filter { $0.installed == nil && ea.downloads[$0.id] == nil }
        let collapsible = SteamGamesSection.collapsible
        VStack(alignment: .leading, spacing: 14) {
            LibrarySectionHeader(title: "EA app", count: mine.count, collapsed: collapsible ? $hidden : nil) {
                if ea.refreshing { ProgressView().accessibilityLabel("Refreshing EA library") }
            }
            if !(hidden && collapsible) {
                if !ea.signedIn {
                    EASignInCard { showSignIn = true }
                }
                if !mine.isEmpty {
                    LibraryCells(items: mine, layout: layout, width: width) { item, list, dense in cell(item, list: list, dense: dense) }
                } else if ea.signedIn && !ea.refreshing && others.isEmpty && search.isEmpty {
                    Text(ea.libraryUpdated == nil ? "Pull down to load your EA library."
                         : "No PC games were found in this EA account.").foregroundStyle(.secondary)
                }
                if ea.signedIn && !others.isEmpty {
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
        .onAppear { ea.start(); ea.reconcileSession() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { ea.reconcileSession() } }
        .sheet(item: $selected) { selection in
            EAGameSheet(offerID: selection.id) { entry in
                // Let the download sheet finish dismissing before presenting the details page.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open(entry) }
            }
        }
        .sheet(isPresented: $showSignIn) { EASignInView() }
        .alert("EA app", isPresented: Binding(get: { ea.error != nil }, set: { if !$0 { ea.error = nil } })) {
            Button("OK", role: .cancel) { ea.error = nil }
        } message: { Text(ea.error ?? "") }
    }

    private func cell(_ item: EAItem, list: Bool, dense: Bool) -> some View {
        Button {
            if let installed = item.installed, ea.downloads[item.id] == nil {
                open(library.eaEntry(installed))
            } else {
                selected = EASelection(id: item.id)
            }
        } label: { EAGameCell(item: item, list: list, dense: dense) }
            .libraryCardButtonStyle(grid: !list)
    }
}

/// The signed-out section's invitation to sign in.
struct EASignInCard: View {
    var signIn: () -> Void
    var body: some View {
        Button(action: signIn) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to EA").font(.headline)
                    Text("See your EA app games here and install them without the EA app.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}

/// A game's artwork: the library entry's cover once installed, else EA's.
struct EAGameArtwork: View {
    let item: EAItem
    @ObservedObject private var library = LibraryModel.shared
    var body: some View {
        if let entry = library.entries.first(where: { $0.eaOfferID == item.id }), entry.coverFile != nil {
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

struct EAGameCell: View {
    let item: EAItem
    var list = false
    var dense = false
    @ObservedObject private var ea = EALibrary.shared
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        let download = ea.downloads[item.id]
        let entry = library.entries.first { $0.eaOfferID == item.id }
        Group {
            if list && dense {
                HStack(spacing: 10) {
                    EAGameArtwork(item: item).frame(width: 28, height: 42).clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    pills(download, entry).fixedSize()
                }.padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            } else if list {
                HStack(spacing: 14) {
                    EAGameArtwork(item: item).frame(width: 48, height: 72)
                        .overlay { overlay(download) }.clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.headline).lineLimit(2)
                        if let download { EADownloadStatus(download: download) } else { pills(nil, entry) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    EAGameArtwork(item: item).aspectRatio(2.0 / 3.0, contentMode: .fit)
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
        .task(id: entry?.id, priority: .utility) { if let id = entry?.id { await library.refreshMetadata(id) } }
    }

    @ViewBuilder private func pills(_ download: EALibrary.Download?, _ entry: LibraryEntry?) -> some View {
        if let download {
            badge(state(download))
        } else if item.installed != nil, let entry {
            LibraryBadges(entry: entry, note: ea.updateAvailable(item.id) ? "Update" : nil).foregroundStyle(.secondary)
        } else if item.installed == nil {
            badge(item.owned?.downloadable == false ? "Not downloadable" : "Not installed")
        }
    }

    private func state(_ download: EALibrary.Download) -> String {
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

    @ViewBuilder private func overlay(_ download: EALibrary.Download?) -> some View {
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

private func eaBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

/// Progress, speed and the state of one download.
struct EADownloadStatus: View {
    let download: EALibrary.Download
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: download.progress.fraction)
            Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
    private var caption: String {
        let p = download.progress
        switch download.state {
        case .queued: return "Waiting for the other EA download to finish…"
        case .paused: return p.totalBytes > 0 ? "Paused at \(Int(p.fraction * 100))%" : "Paused"
        case .failed(let message): return message
        case .active:
            switch p.phase {
            case .preparing: return p.step.map { $0 + "…" } ?? "Preparing download…"
            case .verifying: return "Checking installed files… \(Int(p.fraction * 100))%"
            case .finishing: return "Finishing…"
            case .downloading:
                var parts = ["\(Int(p.fraction * 100))%", "\(eaBytes(p.doneBytes)) of \(eaBytes(p.totalBytes))"]
                if p.bytesPerSecond > 0 {
                    parts.append("\(eaBytes(UInt64(p.bytesPerSecond)))/s")
                    let left = Double(p.totalBytes - min(p.doneBytes, p.totalBytes)) / p.bytesPerSecond
                    if left.isFinite, left > 60 { parts.append("about \(Int(left / 60) + 1) min left") }
                }
                return parts.joined(separator: " · ")
            }
        }
    }
}

// MARK: - Download sheet

struct EAGameSheet: View {
    let offerID: String
    /// Opens the installed game's Game details page (after this sheet closes).
    var open: (LibraryEntry) -> Void
    @ObservedObject private var ea = EALibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var freeSpace: Int64?
    @State private var confirmCancel = false

    var body: some View {
        let item = EAGamesRules.items(ea, search: "").first { $0.id == offerID }
        NavigationStack {
            Form {
                if let item {
                    Section {
                        HStack(spacing: 20) {
                            EAGameArtwork(item: item).frame(width: 120, height: 180).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 12) {
                                Text(item.title).font(.title2.bold())
                                primaryAction(item)
                            }
                        }.padding(.vertical, 24)
                    }
                    if let download = ea.downloads[offerID] {
                        Section("Download") {
                            EADownloadStatus(download: download)
                            Button("Cancel download", role: .destructive) { confirmCancel = true }
                            if case .failed = download.state {
                                Text("Finished files are kept. Try again to continue where it stopped.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        if item.installed == nil {
                            switch ea.sizes[offerID] {
                            case .known(let download, let install):
                                if download > 0 { LabeledContent("Download size", value: "About " + ByteCountFormatter.string(fromByteCount: download, countStyle: .file)) }
                                if install > 0 { LabeledContent("Size on this device", value: "About " + ByteCountFormatter.string(fromByteCount: install, countStyle: .file)) }
                            case .unavailable(let reason):
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            case nil:
                                if ea.signedIn { LabeledContent("Download size") { ProgressView() } }
                            }
                        }
                        if let freeSpace { LabeledContent("Free space on this device", value: ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)) }
                        Text("Games download directly from EA with your account into C:\\Program Files\\EA Games. Keep Madeira open while it downloads: in the background iOS allows only a short time, then the download pauses and continues when you return. A download also pauses while a game is running. Games with EA's anti-cheat (Battlefield 2042 and later, EA SPORTS FC) cannot run in Madeira.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("Game unavailable", systemImage: "questionmark.square.dashed",
                                           description: Text("Refresh your EA library and try again."))
                }
            }
            .navigationTitle("EA app").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: ea.downloads[offerID]?.state) {
                freeSpace = EADownloader.freeSpace(at: URL.documentsDirectory)
            }
            .task(id: offerID) { await ea.loadSize(offerID) }
            .confirmationDialog(ea.installed[offerID] == nil ? "Cancel this download? Downloaded files are deleted." : "Stop this download?",
                                isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Cancel download", role: .destructive) { ea.cancel(offerID) }
                Button("Keep downloading", role: .cancel) {}
            }
        }
    }

    @ViewBuilder private func primaryAction(_ item: EAItem) -> some View {
        if let download = ea.downloads[offerID] {
            switch download.state {
            case .active, .queued:
                Button { ea.pause(offerID) } label: { steamActionLabel("Pause", symbol: "pause.fill") }.buttonStyle(.bordered)
            case .paused:
                Button { ea.install(offerID) } label: { steamActionLabel("Resume", symbol: "arrow.down.circle.fill") }.buttonStyle(.borderedProminent)
            case .failed:
                Button { ea.install(offerID) } label: { steamActionLabel("Try again", symbol: "arrow.clockwise") }.buttonStyle(.borderedProminent)
            }
        } else if let installed = item.installed {
            Button {
                let entry = LibraryModel.shared.eaEntry(installed)
                dismiss(); open(entry)
            } label: {
                HStack(spacing: 10) { Image(systemName: "play.fill"); Text("Open").fontWeight(.semibold) }.frame(minWidth: 100, minHeight: 30)
            }.buttonStyle(.borderedProminent)
        } else if let owned = item.owned {
            Button { ea.install(offerID) } label: {
                steamActionLabel(ea.hasPartialDownload(offerID) ? "Resume download" : "Install", symbol: "arrow.down.circle.fill")
            }.buttonStyle(.borderedProminent).disabled(!ea.signedIn || !owned.downloadable)
        }
    }
}

// MARK: - Game details

/// The EA section of an EA game's Game details page.
struct EAEntrySection: View {
    @Binding var entry: LibraryEntry
    /// The game was uninstalled: the page closes without saving.
    var uninstalled: () -> Void
    @ObservedObject private var ea = EALibrary.shared
    @State private var confirmUninstall = false

    var body: some View {
        let id = entry.eaOfferID ?? ""
        let record = ea.installed[id]
        let download = ea.downloads[id]
        Section {
            if !ea.signedIn {
                Text("Sign in to EA in Settings › EA app to play or update this game. An EA game needs the sign-in to start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let download {
                EADownloadStatus(download: download)
                switch download.state {
                case .active, .queued: Button("Pause download") { ea.pause(id) }
                case .paused, .failed: Button("Resume download") { ea.install(id) }
                }
            } else if ea.updateAvailable(id) {
                Button { ea.install(id) } label: { Label("Update available — download", systemImage: "arrow.down.circle") }
                    .disabled(!ea.signedIn)
            }
            if download == nil, record != nil {
                Button { ea.repair(id) } label: { Label("Repair installed files", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(!ea.signedIn)
                Text("Checks every installed file against EA's current build and downloads what is missing or changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let record {
                LabeledContent("Version", value: record.version.isEmpty ? record.buildID : record.version)
                if !record.contentID.isEmpty { LabeledContent("Content ID", value: record.contentID) }
            }
            LabeledContent("Offer ID", value: id)
            if record != nil, download == nil {
                Button("Uninstall", role: .destructive) { confirmUninstall = true }
            }
        } header: {
            Text("EA app")
        } footer: {
            Text("Madeira starts the game the way the EA app would: it fetches the game's licence for your account, and stands in for the EA app's local service while the game runs. There is no EA app in Madeira, so friends, the overlay and cloud saves are not available.")
        }
        .task(id: id) { await ea.checkForUpdate(id) }
        .confirmationDialog("Uninstall \(entry.title)? Its downloaded files are deleted from this device. Saves stored elsewhere are kept.",
                            isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                ea.uninstall(id)
                uninstalled()
            }
        }
    }
}

// MARK: - Settings

struct EASettingsSection: View {
    let open: (SettingsSheet) -> Void
    @ObservedObject private var ea = EALibrary.shared
    @State private var confirmSignOut = false

    var body: some View {
        Section {
            if ea.signedIn {
                LabeledContent("Signed in as", value: ea.accountName ?? "EA account")
                Button("Sign out of EA", role: .destructive) { confirmSignOut = true }
            } else {
                Button { open(.eaSignIn) } label: { Label("Sign in to EA", systemImage: "person.crop.circle.badge.plus") }
            }
        } header: {
            Text("EA app")
        } footer: {
            Text("Madeira keeps an EA sign-in token in this device's Keychain, for this device only. Signing out removes it; installed games stay, but need the sign-in to start.")
        }
        .onAppear { ea.start() }
        .confirmationDialog("Sign out of EA?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { ea.signOut() }
        }
    }
}

// MARK: - Sign-in

/// EA's own login page in a web view. When the login finishes, EA sends the page
/// to the EA app's private address (qrc:///html/login_successful.html) with a
/// one-use code; Madeira stops that navigation, reads the code and signs in. That
/// address can also be pasted, for logins the web view cannot complete.
struct EASignInView: View {
    @ObservedObject private var ea = EALibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var failure: String?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var reload = 0

    var body: some View {
        NavigationStack {
            Group {
                if ea.signedIn {
                    Form {
                        LabeledContent("Signed in as", value: ea.accountName ?? "EA account")
                        Button("Sign out", role: .destructive) { ea.signOut() }
                    }
                } else {
                    EALoginWebView(reload: reload) { code in submit(code) }
                        .ignoresSafeArea(edges: .bottom)
                        .overlay {
                            if busy {
                                ProgressView("Signing in…").padding(20)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                }
            }
            .navigationTitle("EA app").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !ea.signedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Paste the sign-in address", systemImage: "doc.on.clipboard") { pasted = ""; pasting = true }
                            Button("Reload", systemImage: "arrow.clockwise") { reload += 1 }
                        } label: { Label("More", systemImage: "ellipsis.circle") }
                    }
                }
            }
            .alert("Sign in with an address", isPresented: $pasting) {
                TextField("qrc:///html/login_successful.html?code=…", text: $pasted).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Sign in") { submit(pasted) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("If the page shows an address that ends in login_successful.html with a code, copy that whole address and paste it here.")
            }
            .alert("EA app", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil; reload += 1 }
            } message: { Text(failure ?? "") }
        }
    }

    private func submit(_ text: String) {
        guard !busy else { return }
        guard let code = EAAPI.authorizationCode(in: text) else {
            failure = "This is not an EA sign-in address. Copy the address of the page EA opens after you sign in."
            return
        }
        busy = true
        Task {
            do {
                try await ea.signIn(code: code)
                busy = false
                dismiss()
            } catch {
                busy = false
                failure = error.localizedDescription
            }
        }
    }
}

/// WKWebView with EA's login page, in a private (non-persistent) data store. The
/// navigation to the EA app's private end-of-login address is stopped and handed on.
struct EALoginWebView: UIViewRepresentable {
    var reload: Int
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: EALibrary.shared.loginURL()))
        context.coordinator.loadedReload = reload
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onCode = onCode
        if context.coordinator.loadedReload != reload {
            context.coordinator.loadedReload = reload
            context.coordinator.delivered = false
            view.load(URLRequest(url: EALibrary.shared.loginURL()))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onCode: (String) -> Void
        var loadedReload = 0
        var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, EAAPI.isRedirectPage(url) {
                decisionHandler(.cancel)
                deliver(url)
                return
            }
            decisionHandler(.allow)
        }

        /// The private scheme could not load (the web view has no handler for it): its address has the code.
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if let url = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL, EAAPI.isRedirectPage(url) { deliver(url) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url, EAAPI.isRedirectPage(url) { deliver(url) }
        }

        private func deliver(_ url: URL) {
            guard !delivered, EAAPI.authorizationCode(in: url.absoluteString) != nil else { return }
            delivered = true
            onCode(url.absoluteString)
        }

        /// Links that open a new window load in this one.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
