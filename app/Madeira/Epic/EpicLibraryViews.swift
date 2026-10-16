// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// The account's Epic Games in Madeira's library: cards in the Steam section's style
// (tall box art, title, format pills or the download state), the library's Epic Games
// section with its Not installed group, and a game page using the shared download and
// Play controls.

import SwiftUI

/// An Epic artwork URL. A game that is not downloaded gets the Steam cards' soft
/// circle of blur for the download glyph (SteamArtworkBlurSpot).
struct EpicArtwork: View {
    let url: URL?
    var notDownloaded = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .secondarySystemFill)
                if !notDownloaded {
                    Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(.secondary)
                }
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            .overlay { if notDownloaded { SteamArtworkBlurSpot(image: image, size: geometry.size) } }
                    } else {
                        Color.clear
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .accessibilityHidden(true)
    }
}

/// An Epic game's card, or its row in the list layouts, as SteamGameCell.
struct EpicGameCard: View {
    let game: EpicGame
    var list = false
    var dense = false
    @ObservedObject private var installer = EpicInstaller.shared

    /// Neither installed nor downloading.
    private var notDownloaded: Bool { installer.installed[game.appName] == nil && !installer.isDownloading(game.appName) }

    var body: some View {
        let download = installer.installs[game.appName]?.download
        Group {
            if list && dense {
                HStack(spacing: 10) {
                    EpicArtwork(url: game.artworkURL, notDownloaded: notDownloaded).frame(width: 28, height: 42)
                        .overlay { if notDownloaded { notDownloadedFace(.caption) } }
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let download { SteamDownloadStatus(download: download) }
                    }
                    Spacer(minLength: 6)
                    pills.fixedSize()
                }.padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            } else if list {
                HStack(spacing: 14) {
                    EpicArtwork(url: game.artworkURL, notDownloaded: notDownloaded).frame(width: 48, height: 72)
                        .overlay { overlay(download) }
                        .overlay { if notDownloaded { notDownloadedFace(.title3) } }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(game.title).font(.headline).lineLimit(2)
                        if let download { SteamDownloadStatus(download: download) } else { pills }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    EpicArtwork(url: game.artworkURL, notDownloaded: notDownloaded).aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .overlay { overlay(download) }
                        .overlay { if notDownloaded { notDownloadedFace(.largeTitle) } }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .modifier(LibraryCardArtworkPress { pressed, bounds in
                            AmbientGlowItem(id: "epic-\(game.appName)", seed: game.appName.hashValue, art: .epic(game.artworkURL),
                                            dimmed: notDownloaded, pressed: pressed, bounds: bounds)
                        })
                    Text(game.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    pills
                }.padding(4)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }

    /// Once installed, the pills of any library game (bits, graphics API, size);
    /// otherwise the download state in Steam's wording.
    @ViewBuilder private var pills: some View {
        if !installer.isDownloading(game.appName), let entry = installer.entry(game.appName) {
            LibraryBadges(entry: entry).foregroundStyle(.secondary)
        } else {
            Text(state)
                .font(.caption2.weight(.medium)).lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 4)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.secondary)
        }
    }

    private var state: String {
        guard let download = installer.installs[game.appName]?.download else { return "Not installed" }
        switch download.state {
        case .queued: return "Waiting"
        case .active: return "Downloading \(Int(download.progress.fraction * 100))%"
        case .paused: return "Paused"
        case .failed: return "Download failed"
        }
    }

    /// The Steam cards' not-downloaded face: dimmed art under a download glyph.
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
                case .active: ProgressView(value: download.progress.fraction).progressViewStyle(.circular).tint(.white)
                case .queued: Image(systemName: "clock").font(.title2).foregroundStyle(.white)
                case .paused: Image(systemName: "pause.circle.fill").font(.title).foregroundStyle(.white)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.yellow)
                }
            }
        }
    }
}

/// The library's Epic Games section, after Steam's: installed and downloading games
/// under the title, then the account's other games under Not installed. An installed
/// game opens its Game details page; any other its install page.
struct EpicGamesSection: View {
    let search: String
    var layout = "cards"
    var width: CGFloat = 390
    var open: (LibraryEntry) -> Void
    @ObservedObject private var library = EpicLibrary.shared
    @ObservedObject private var auth = EpicAuth.shared
    @ObservedObject private var installer = EpicInstaller.shared
    @AppStorage("madeiraEpicHideInstalled") private var hideInstalled = false
    @AppStorage("madeiraEpicShowUninstalled") private var showUninstalled = true
    @State private var selected: EpicGame?

    /// Whether the library has Epic games to show at all.
    static var shown: Bool { !EpicInstaller.shared.installed.isEmpty || (EpicAuth.shared.signedIn && !EpicLibrary.shared.games.isEmpty) }

    /// Pull to refresh on the library.
    @MainActor static func refresh() async {
        if EpicAuth.shared.signedIn { await EpicLibrary.shared.refresh() }
    }

    private var games: [EpicGame] {
        var games = auth.signedIn ? library.games : []
        let known = Set(games.map(\.appName))
        games += installer.installed.values.map(\.game).filter { !known.contains($0.appName) }
        return games.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        let all = games
        let onDevice = all.filter { installer.installed[$0.appName] != nil || installer.isDownloading($0.appName) }
        let notInstalled = all.filter { installer.installed[$0.appName] == nil && !installer.isDownloading($0.appName) }
        let collapsible = SteamGamesSection.collapsible
        Group {
            if Self.shown {
                VStack(alignment: .leading, spacing: 14) {
                    LibrarySectionHeader(title: "Epic Games", count: onDevice.count,
                                         collapsed: collapsible ? $hideInstalled : nil) {
                        if library.isLoading { ProgressView().accessibilityLabel("Refreshing Epic library") }
                    }
                    if !(hideInstalled && collapsible), !onDevice.isEmpty {
                        LibraryCells(items: onDevice, layout: layout, width: width) { game, list, dense in
                            card(game, list: list, dense: dense)
                        }
                    }
                    if !notInstalled.isEmpty {
                        Button {
                            withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) { showUninstalled.toggle() }
                        } label: {
                            HStack {
                                Text("Not installed").font(.headline)
                                Text("\(notInstalled.count)").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                    .rotationEffect(.degrees(showUninstalled ? 90 : 0)).foregroundStyle(.secondary)
                            }.contentShape(Rectangle()).frame(minHeight: 44)
                        }.buttonStyle(.plain)
                            .accessibilityValue(showUninstalled ? "Shown" : "Hidden")
                        if showUninstalled {
                            LibraryCells(items: notInstalled, layout: layout, width: width) { game, list, dense in
                                card(game, list: list, dense: dense)
                            }
                        }
                    }
                }
            } else {
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }
        .onAppear { library.refreshIfStale() }
        .sheet(item: $selected) { game in EpicGameSheet(game: game, open: open) }
    }

    private func card(_ game: EpicGame, list: Bool, dense: Bool) -> some View {
        Button {
            if !installer.isDownloading(game.appName), let entry = installer.entry(game.appName) { open(entry) }
            else { selected = game }
        } label: { EpicGameCard(game: game, list: list, dense: dense) }
            .libraryCardButtonStyle(grid: !list)
    }
}

/// An Epic game's install page, laid out exactly as Steam's (SteamGameSheet): the cover
/// with the name and one action (Install, Pause, Resume, Try again, Open) over the blurred
/// art, the download, the sizes beside the free space, then the store link.
struct EpicGameSheet: View {
    let game: EpicGame
    /// Opens the installed game's Game details page (after this sheet closes).
    var open: (LibraryEntry) -> Void
    @ObservedObject private var installer = EpicInstaller.shared
    @ObservedObject private var sizes = EpicSizes.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCancel = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 20) {
                        EpicArtwork(url: game.artworkURL).frame(width: 120, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 12) {
                            Text(game.title).font(.title2.bold())
                            primaryAction
                        }
                    }.padding(.vertical, 24)
                        .listRowBackground(
                            EpicArtwork(url: game.heroURL ?? game.artworkURL).blur(radius: 4)
                                .overlay(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.55))
                                .clipped()
                        )
                }
                if let download = installer.installs[game.appName]?.download {
                    Section("Download") {
                        SteamDownloadStatus(download: download)
                        Button("Cancel download", role: .destructive) { confirmCancel = true }
                        if case .failed = download.state {
                            Text("Downloaded files are kept. Try again to continue where it stopped.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    // The game's sizes from its manifest, before Install, next to the free
                    // space (red when the installed game would not fit).
                    let installed = installer.installed[game.appName] != nil
                    let size = sizes.sizes[game.appName]
                    let free = Int64(clamping: EpicSizes.free)
                    if !installed {
                        if let size {
                            LabeledContent("Download size", value: EpicSizeRow.format(size.download))
                            LabeledContent("Installed size", value: EpicSizeRow.format(size.install))
                        } else {
                            LabeledContent("Download size") { ProgressView() }
                        }
                    }
                    let tooBig = !installed && size.map { Int64(clamping: $0.install) > free } == true
                    LabeledContent("Free space on this device") {
                        Text(EpicSizeRow.format(UInt64(max(0, free)))).foregroundStyle(tooBig ? Color.red : Color.secondary)
                    }
                }
                Section {
                    if let url = URL(string: "https://store.epicgames.com/browse?q=" + (game.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) {
                        Link(destination: url) { Label("View in the Epic Games Store", systemImage: "safari") }
                    }
                }
                if let error = installer.error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Epic Games").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { sizes.load(game) }
            .confirmationDialog("Cancel this download? Downloaded files are deleted.", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Cancel download", role: .destructive) { installer.cancel(game.appName) }
                Button("Keep downloading", role: .cancel) {}
            }
        }
    }


    @ViewBuilder private var primaryAction: some View {
        if installer.installed[game.appName] != nil, !installer.isDownloading(game.appName),
           let entry = installer.entry(game.appName) {
            // Installed: its Game details page.
            Button { dismiss(); open(entry) } label: {
                HStack(spacing: 10) { Image(systemName: "play.fill"); Text("Open").fontWeight(.semibold) }.frame(minWidth: 100, minHeight: 30)
            }.buttonStyle(.borderedProminent)
        } else if let download = installer.installs[game.appName]?.download {
            switch download.state {
            case .active, .queued:
                Button { installer.pause(game.appName) } label: { steamActionLabel("Pause", symbol: "pause.fill") }
                    .buttonStyle(.bordered)
            case .paused:
                Button { installer.install(game) } label: { steamActionLabel("Resume", symbol: "arrow.down.circle.fill") }
                    .buttonStyle(.borderedProminent)
            case .failed:
                Button { installer.install(game) } label: { steamActionLabel("Try again", symbol: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            Button { installer.install(game) } label: { steamActionLabel("Install", symbol: "arrow.down.circle.fill") }
                .buttonStyle(.borderedProminent).disabled(!installer.ready)
        }
    }
}

/// "Download 2.1 GB · Installed 4.8 GB · 37 GB free", red when the game will not fit.
struct EpicSizeRow: View {
    let game: EpicGame
    @ObservedObject private var sizes = EpicSizes.shared

    var body: some View {
        let free = EpicSizes.free
        Group {
            if let size = sizes.sizes[game.appName] {
                let fits = free >= size.install + 128 * 1024 * 1024
                HStack(spacing: 6) {
                    Text("Download \(Self.format(size.download))")
                    Text("·")
                    Text("Installed \(Self.format(size.install))")
                    Text("·")
                    Text("\(Self.format(free)) free").foregroundStyle(fits ? Color.secondary : Color.red)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking size · \(Self.format(free)) free")
                }
            }
        }
        .font(.footnote).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        .task { sizes.load(game) }
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}

/// Game details › Epic Games, for an installed Epic game (as SteamEntrySection is for
/// Steam's): its version, its prerequisites installer, and Uninstall.
struct EpicEntrySection: View {
    let appName: String
    /// Starts a program as a library session (the prerequisites installer).
    var run: (LibraryEntry) -> Void
    /// Closes the details page (after Uninstall).
    var leave: () -> Void
    @ObservedObject private var installer = EpicInstaller.shared
    @State private var confirmUninstall = false

    var body: some View {
        if let record = installer.installed[appName] {
            Section {
                if !record.buildVersion.isEmpty { LabeledContent("Version", value: record.buildVersion) }
                if !record.prereqPath.isEmpty {
                    Button("Install prerequisites", systemImage: "shippingbox") {
                        var prerequisite = LibraryEntry(title: record.prereqName.isEmpty ? "Prerequisites" : record.prereqName,
                                                        relativePath: record.installDir + "/" + record.prereqPath.replacingOccurrences(of: "\\", with: "/"),
                                                        bits: 0)
                        prerequisite.arguments = record.prereqArgs
                        run(prerequisite)
                    }
                }
                Button("Uninstall", role: .destructive) { confirmUninstall = true }
            } header: { Text("Epic Games") }
            .confirmationDialog("Uninstall \(record.game.title)? Its files are deleted from this device.",
                                isPresented: $confirmUninstall, titleVisibility: .visible) {
                Button("Uninstall", role: .destructive) {
                    installer.uninstall(appName)
                    leave()
                }
            }
        }
    }
}

/// What an Epic game will take, shown on its page before Install: the download (the
/// compressed chunks) and the installed size (the files), from the game's manifest,
/// with the device's free space. Fetched when the page opens; kept per game.
@MainActor final class EpicSizes: ObservableObject {
    static let shared = EpicSizes()
    struct Size { var download: UInt64; var install: UInt64 }
    @Published private(set) var sizes: [String: Size] = [:]
    private var loading: Set<String> = []

    func load(_ game: EpicGame) {
        guard sizes[game.appName] == nil, !loading.contains(game.appName),
              let catalog = game.catalogItemId, !catalog.isEmpty else { return }
        loading.insert(game.appName)
        Task {
            defer { loading.remove(game.appName) }
            guard let token = try? await EpicAuth.shared.validAccessToken(),
                  let (manifest, _) = try? await EpicManifest.fetch(namespace: game.namespace, catalogItemID: catalog,
                                                                    appName: game.appName, token: token) else { return }
            sizes[game.appName] = Size(download: manifest.chunks.reduce(0) { $0 + UInt64(max(0, $1.fileSize)) },
                                       install: manifest.files.reduce(0) { $0 + $1.size })
        }
    }

    /// Free space where games are installed (the same measure the installer checks).
    nonisolated static var free: UInt64 {
        let values = try? LibraryModel.drive.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                                      .volumeAvailableCapacityKey])
        return UInt64(max(0, max(values?.volumeAvailableCapacityForImportantUsage ?? 0,
                                 Int64(values?.volumeAvailableCapacity ?? 0))))
    }
}
