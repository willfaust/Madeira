// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//  Steam Workshop (docs/STEAM_WORKSHOP.md): a game's Steam Workshop page
//  (Game details › Steam Workshop) and the library's Workshop area, which
//  lists the installed games. Over the app's own Steam connection the page
//  lists the account's subscribed items, browses and searches the game's
//  Workshop, subscribes and unsubscribes, and downloads items into Valve's
//  Workshop folder with the item record Valve's client reads
//  (SteamWorkshopFiles.swift). A game started through Madeira Dock then finds
//  them installed. Nothing runs while a game session holds the account.
//

import SwiftUI

@MainActor
final class SteamWorkshopModel: ObservableObject {
    static let shared = SteamWorkshopModel()

    /// The account's subscribed items, per app, in Steam's order.
    @Published private(set) var subscribed: [UInt32: [SteamWorkshopItem]] = [:]
    /// Items on disk that are no longer subscribed, per app.
    @Published private(set) var unsubscribedInstalled: [UInt32: [SteamWorkshopItem]] = [:]
    @Published private(set) var records: [UInt32: SteamWorkshopRecord] = [:]
    @Published private(set) var loading = Set<UInt32>()
    @Published var error: String?

    enum Job: Equatable {
        case queued
        case active(SteamDownloadProgress)
        case failed(String)
    }
    /// Downloads by item ID: waiting, running, or failed with a reason.
    @Published private(set) var jobs: [UInt64: Job] = [:]
    private var queue: [SteamWorkshopItem] = []
    private var worker: Task<Void, Never>?
    /// Subscribe and unsubscribe calls in flight.
    @Published private(set) var changing = Set<UInt64>()

    private var steam: SteamOwnedLibrary { SteamOwnedLibrary.shared }

    /// The Steam library folder the game is installed in: its items go beside it.
    func steamApps(_ appID: UInt32) -> URL? {
        guard let game = SteamGamesModel.shared.games.first(where: { $0.id == Int(appID) }) else { return nil }
        return SteamOwnedLibrary.drive.appendingPathComponent(game.library, isDirectory: true)
    }

    func record(_ appID: UInt32) -> SteamWorkshopRecord { records[appID] ?? SteamWorkshopRecord(appID: appID) }

    /// Reads the item record again (off the main thread).
    func reloadRecord(_ appID: UInt32) async {
        guard let steamApps = steamApps(appID) else { records[appID] = nil; return }
        records[appID] = await Task.detached(priority: .utility) {
            SteamWorkshopRecord.read(appID: appID, steamApps: steamApps)
        }.value
    }

    func isOnDisk(_ item: SteamWorkshopItem, appID: UInt32) -> Bool {
        guard let steamApps = steamApps(appID) else { return false }
        return record(appID).isOnDisk(item.id, steamApps: steamApps)
    }

    /// Subscribed items that are not on disk or have a newer version on Steam.
    func pending(_ appID: UInt32) -> [SteamWorkshopItem] {
        (subscribed[appID] ?? []).filter { $0.downloadable && (!isOnDisk($0, appID: appID) || record(appID).needsUpdate($0)) }
    }

    // MARK: Steam

    /// The subscribed items (every page, at most 1000) and the details of
    /// installed items that are no longer subscribed.
    func refresh(_ appID: UInt32) async {
        await reloadRecord(appID)
        guard steam.workshopReady, !loading.contains(appID) else { return }
        loading.insert(appID)
        defer { loading.remove(appID) }
        do {
            var items: [SteamWorkshopItem] = []
            var page: UInt32 = 1
            while page <= 10 {
                let response = try await steam.workshopCall(.workshopGetUserFiles) {
                    SteamWorkshopRequests.subscribed(steamID: $0, appID: appID, page: page)
                }
                try Self.check(response.eresult)
                let result = try SteamWorkshopRequests.page(response.body, itemsField: 3)
                let known = Set(items.map(\.id))
                items += result.items.filter { !known.contains($0.id) }
                if result.items.count < Int(SteamWorkshopRequests.subscribedPageSize) || items.count >= result.total { break }
                page += 1
            }
            subscribed[appID] = items
            let subscribedIDs = Set(items.map(\.id))
            let others = record(appID).installed.keys.filter { !subscribedIDs.contains($0) }.sorted()
            if others.isEmpty {
                unsubscribedInstalled[appID] = []
            } else {
                let response = try await steam.workshopCall(.workshopGetDetails) { _ in
                    SteamWorkshopRequests.details(appID: appID, ids: Array(others))
                }
                let found = (try? SteamWorkshopRequests.page(response.body, itemsField: 1, totalField: nil).items) ?? []
                unsubscribedInstalled[appID] = others.map { id in found.first { $0.id == id } ?? SteamWorkshopItem(id: id, appID: appID, title: "Item \(id)") }
            }
            SteamLog.event("[steam-workshop] app=\(appID) subscribed=\(items.count) installed=\(record(appID).installed.count) pending=\(pending(appID).count)")
        } catch {
            report(error, context: "list app=\(appID)")
        }
    }

    /// One page of the game's Workshop.
    func browse(_ appID: UInt32, order: SteamWorkshopRequests.Order, text: String, page: UInt32) async throws -> SteamWorkshopPage {
        let response = try await steam.workshopCall(.workshopQueryFiles) { _ in
            SteamWorkshopRequests.query(appID: appID, order: order, text: text, page: page)
        }
        try Self.check(response.eresult)
        let result = try SteamWorkshopRequests.page(response.body, itemsField: 2)
        SteamLog.event("[steam-workshop] browse app=\(appID) order=\(order.rawValue) page=\(page) items=\(result.items.count) total=\(result.total)")
        return result
    }

    func isSubscribed(_ item: SteamWorkshopItem, appID: UInt32) -> Bool {
        subscribed[appID]?.contains { $0.id == item.id } ?? false
    }

    /// Subscribes on Steam (as the Workshop's Subscribe button does) and
    /// downloads the item.
    func subscribe(_ item: SteamWorkshopItem, appID: UInt32) async {
        guard !changing.contains(item.id) else { return }
        changing.insert(item.id)
        defer { changing.remove(item.id) }
        do {
            let response = try await steam.workshopCall(.workshopSubscribe) { _ in
                SteamWorkshopRequests.subscription(itemID: item.id, appID: appID)
            }
            try Self.check(response.eresult)
            SteamLog.event("[steam-workshop] subscribed app=\(appID) item=\(item.id)")
            if !isSubscribed(item, appID: appID) { subscribed[appID, default: []].insert(item, at: 0) }
            unsubscribedInstalled[appID]?.removeAll { $0.id == item.id }
            download(item, appID: appID)
        } catch {
            report(error, context: "subscribe app=\(appID) item=\(item.id)")
        }
    }

    /// Unsubscribes on Steam and, with `remove`, deletes the item's files.
    func unsubscribe(_ item: SteamWorkshopItem, appID: UInt32, remove: Bool) async {
        guard !changing.contains(item.id) else { return }
        changing.insert(item.id)
        defer { changing.remove(item.id) }
        do {
            let response = try await steam.workshopCall(.workshopUnsubscribe) { _ in
                SteamWorkshopRequests.subscription(itemID: item.id, appID: appID)
            }
            try Self.check(response.eresult)
            SteamLog.event("[steam-workshop] unsubscribed app=\(appID) item=\(item.id) remove=\(remove ? 1 : 0)")
            subscribed[appID]?.removeAll { $0.id == item.id }
            if remove {
                await self.remove(item, appID: appID)
            } else if isOnDisk(item, appID: appID) {
                unsubscribedInstalled[appID, default: []].append(item)
            }
        } catch {
            report(error, context: "unsubscribe app=\(appID) item=\(item.id)")
        }
    }

    /// Deletes an item's files and its record entry.
    func remove(_ item: SteamWorkshopItem, appID: UInt32) async {
        guard let steamApps = steamApps(appID) else { return }
        cancel(item.id)
        do {
            try await Task.detached(priority: .userInitiated) {
                try? FileManager.default.removeItem(at: SteamWorkshopRecord.itemFolder(appID: appID, itemID: item.id, steamApps: steamApps))
                try? FileManager.default.removeItem(at: SteamWorkshopRecord.journalFolder(appID: appID, itemID: item.id, steamApps: steamApps))
                var record = SteamWorkshopRecord.read(appID: appID, steamApps: steamApps)
                guard record.entries[item.id] != nil else { return }
                record.entries[item.id] = nil
                try record.write(steamApps: steamApps)
            }.value
            SteamLog.event("[steam-workshop] removed app=\(appID) item=\(item.id)")
        } catch {
            report(error, context: "remove app=\(appID) item=\(item.id)")
        }
        unsubscribedInstalled[appID]?.removeAll { $0.id == item.id }
        await reloadRecord(appID)
    }

    // MARK: Downloads

    func download(_ item: SteamWorkshopItem, appID: UInt32) {
        guard item.downloadable, steamApps(appID) != nil else { return }
        if case .active = jobs[item.id] { return }
        if jobs[item.id] == .queued { return }
        var item = item
        item.appID = appID
        jobs[item.id] = .queued
        queue.append(item)
        runQueue()
    }

    func downloadAll(_ appID: UInt32) {
        for item in pending(appID) { download(item, appID: appID) }
    }

    func cancel(_ itemID: UInt64) {
        queue.removeAll { $0.id == itemID }
        jobs[itemID] = nil
        if current == itemID { worker?.cancel() }
    }

    /// A game session starts: Valve's client takes the account, so downloads stop
    /// (finished chunks stay journaled; Download continues them later).
    func stopForSession() {
        guard worker != nil || !queue.isEmpty else { return }
        for item in queue { jobs[item.id] = nil }
        queue.removeAll()
        worker?.cancel()
        SteamLog.event("[steam-workshop] downloads stopped for a game session")
    }

    private var current: UInt64?

    private func runQueue() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.queue.isEmpty {
                let item = self.queue.removeFirst()
                self.current = item.id
                await self.run(item)
                self.current = nil
            }
            self?.worker = nil
            if let self, !self.queue.isEmpty { self.runQueue() }
        }
    }

    private func run(_ item: SteamWorkshopItem) async {
        let appID = item.appID
        guard let steamApps = steamApps(appID) else { jobs[item.id] = nil; return }
        jobs[item.id] = .active(SteamDownloadProgress())
        let folder = SteamWorkshopRecord.itemFolder(appID: appID, itemID: item.id, steamApps: steamApps)
        let journal = SteamWorkshopRecord.journalFolder(appID: appID, itemID: item.id, steamApps: steamApps)
        let previous = SteamWorkshopRecord.read(appID: appID, steamApps: steamApps).entries[item.id]
        do {
            // A new version replaces the item's files, as Valve's client does.
            if let previous, previous.installed, previous.manifest != item.content || item.content == 0 {
                try? FileManager.default.removeItem(at: folder)
            }
            let size: UInt64
            if item.content != 0 && item.fileURL.isEmpty {
                size = try await steam.downloadWorkshopItem(appID: appID, itemID: item.id, manifestGID: item.content,
                                                            into: folder, journalDir: journal) { [weak self] progress in
                    Task { @MainActor in
                        if case .active = self?.jobs[item.id] { self?.jobs[item.id] = .active(progress) }
                    }
                }
            } else {
                size = try await Self.downloadFile(item, into: folder)
            }
            try Task.checkCancellation()
            let accountID = steam.workshopAccountID
            try await Task.detached(priority: .userInitiated) {
                var record = SteamWorkshopRecord.read(appID: appID, steamApps: steamApps)
                var entry = record.entries[item.id] ?? SteamWorkshopRecord.Entry()
                entry.installed = true
                entry.size = size
                entry.manifest = item.content
                entry.timeUpdated = item.timeUpdated
                entry.timeTouched = UInt32(Date().timeIntervalSince1970)
                if entry.subscribedBy == 0 { entry.subscribedBy = accountID }
                record.entries[item.id] = entry
                try record.write(steamApps: steamApps)
            }.value
            jobs[item.id] = nil
            SteamLog.event("[steam-workshop] installed app=\(appID) item=\(item.id) bytes=\(size) legacy=\(item.content == 0 || !item.fileURL.isEmpty ? 1 : 0)")
        } catch is CancellationError {
            jobs[item.id] = nil
        } catch {
            if Task.isCancelled { jobs[item.id] = nil; return }
            jobs[item.id] = .failed(SteamSignIn.message(error))
            SteamLog.event("[steam-workshop] download failed app=\(appID) item=\(item.id) reason=\(SteamOwnedLibrary.reason(error))")
        }
        await reloadRecord(appID)
    }

    /// An older item: one file at a Steam URL, saved in the item's folder.
    private nonisolated static func downloadFile(_ item: SteamWorkshopItem, into folder: URL) async throws -> UInt64 {
        var text = item.fileURL
        if text.hasPrefix("http://") { text = "https://" + text.dropFirst("http://".count) }
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased(),
              host.hasSuffix(".steamusercontent.com") || host.hasSuffix(".steamstatic.com") || host.hasSuffix(".steampowered.com")
                || host.hasSuffix(".akamaihd.net") else {
            throw SteamError.chunkDownloadFailed("Steam gave no usable download address for this item.")
        }
        let (temporary, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
            throw SteamError.chunkDownloadFailed("Steam returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for this item.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(SteamWorkshopRecord.legacyFileName(item))
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return UInt64(max(size, 0))
    }

    // MARK: Errors

    struct Refused: LocalizedError {
        let eresult: Int32
        var errorDescription: String? {
            switch eresult {
            case 2: return "Steam could not do this right now (generic failure). Try again later."
            case 9: return "Steam does not know this item. It may have been removed."
            case 15: return "Steam refused: this item is not available to this account."
            case 25: return "Steam's subscription limit was reached."
            case 84: return "Steam is limiting requests. Wait a minute and try again."
            default: return "Steam refused the request (error \(eresult))."
            }
        }
    }

    private static func check(_ eresult: Int32) throws {
        guard eresult == 1 || eresult == 0 else { throw Refused(eresult: eresult) }
    }

    private func report(_ error: Error, context: String) {
        self.error = (error as? Refused)?.errorDescription ?? SteamSignIn.message(error)
        SteamLog.event("[steam-workshop] \(context) failed reason=\((error as? Refused).map { "eresult-\($0.eresult)" } ?? SteamOwnedLibrary.reason(error))")
    }
}

// MARK: - Views

private func workshopBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

/// One item: its preview, title and state.
struct SteamWorkshopItemRow: View {
    let item: SteamWorkshopItem
    let appID: UInt32
    @ObservedObject private var model = SteamWorkshopModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: URL(string: item.previewURL)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 56)
            .background(Color(uiColor: .tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body).lineLimit(2)
                status
                if !item.summary.isEmpty {
                    Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var status: some View {
        switch model.jobs[item.id] {
        case .queued:
            Text("Waiting to download…").font(.caption).foregroundStyle(.secondary)
        case .active(let progress):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress.fraction)
                Text(progress.totalBytes > 0 ? "\(Int(progress.fraction * 100))% of \(workshopBytes(progress.totalBytes))" : "Preparing…")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange)
        case nil:
            Text(caption).font(.caption).foregroundStyle(captionIsWarning ? Color.orange : Color.secondary)
        }
    }

    private var caption: String {
        if item.isCollection { return "Collection: subscribe to its items on Steam" }
        if item.banned { return "Removed by Steam" }
        if item.result != 1 && item.result != 0 { return "Not available on Steam" }
        if !item.isContent { return "Not game content" }
        let record = model.record(appID)
        if model.isOnDisk(item, appID: appID) {
            let size = record.entries[item.id]?.size ?? 0
            let installed = size > 0 ? "Installed · \(workshopBytes(size))" : "Installed"
            return record.needsUpdate(item) ? installed + " · Update available" : installed
        }
        return item.fileSize > 0 ? "Not downloaded · \(workshopBytes(item.fileSize))" : "Not downloaded"
    }

    private var captionIsWarning: Bool {
        model.record(appID).needsUpdate(item) || item.banned
    }
}

/// Game details › Steam Workshop: the account's subscribed items for the game,
/// what is installed, Browse, and the actions on each.
struct SteamWorkshopSections: View {
    let appID: UInt32
    let title: String
    @ObservedObject private var model = SteamWorkshopModel.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared

    var body: some View {
        let installed = model.steamApps(appID) != nil
        let subscribed = model.subscribed[appID]
        let pending = model.pending(appID)
        Section {
            if !installed {
                Text("Install \(title) to download its Workshop items.").foregroundStyle(.secondary)
            } else if !steam.signedIn {
                Text("Sign in to Steam (Settings › Steam) to see your Workshop items.").foregroundStyle(.secondary)
            } else if !steam.workshopReady {
                Text("Not available while a game runs. Steam gives your account to the game until it ends.")
                    .foregroundStyle(.secondary)
            }
            NavigationLink {
                SteamWorkshopBrowseView(appID: appID, title: title)
            } label: {
                Label("Browse the Workshop", systemImage: "magnifyingglass")
            }.disabled(!steam.workshopReady || !installed)
            if !pending.isEmpty {
                Button {
                    model.downloadAll(appID)
                } label: {
                    Label(pending.count == 1 ? "Download 1 item" : "Download \(pending.count) items", systemImage: "arrow.down.circle")
                }.disabled(!steam.workshopReady)
            }
            if let url = URL(string: "https://steamcommunity.com/app/\(appID)/workshop/") {
                Link(destination: url) { Label("Open the Workshop in Safari", systemImage: "safari") }
            }
        } footer: {
            Text("Items download from Steam with your account into Steam's Workshop folder beside the game, so the game finds them when it starts through Madeira Dock. Subscriptions are your Steam account's, the same as on a PC.")
        }
        .task(id: "\(appID) \(steam.workshopReady) \(installed)") { await model.refresh(appID) }
        .alert("Steam Workshop", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        Section {
            if model.loading.contains(appID) && subscribed == nil {
                LabeledContent("Subscribed") { ProgressView() }
            } else if let subscribed {
                if subscribed.isEmpty {
                    Text("No subscribed items. Browse the Workshop to add some.").foregroundStyle(.secondary)
                }
                ForEach(subscribed) { item in
                    row(item, subscribed: true)
                }
            }
        } header: {
            Text(subscribed.map { "Subscribed (\($0.count))" } ?? "Subscribed")
        }
        if let others = model.unsubscribedInstalled[appID], !others.isEmpty {
            Section {
                ForEach(others) { item in row(item, subscribed: false) }
            } header: {
                Text("Installed, not subscribed")
            } footer: {
                Text("Items still on this device that your account no longer subscribes to, for example ones a game downloaded for a server.")
            }
        }
    }

    @ViewBuilder private func row(_ item: SteamWorkshopItem, subscribed: Bool) -> some View {
        let onDisk = model.isOnDisk(item, appID: appID)
        let job = model.jobs[item.id]
        SteamWorkshopItemRow(item: item, appID: appID)
            .contextMenu { actions(item, subscribed: subscribed, onDisk: onDisk, job: job) }
            .swipeActions(edge: .trailing) {
                if subscribed {
                    Button("Unsubscribe", role: .destructive) {
                        Task { await model.unsubscribe(item, appID: appID, remove: true) }
                    }.disabled(!steam.workshopReady)
                } else if onDisk {
                    Button("Remove", role: .destructive) { Task { await model.remove(item, appID: appID) } }
                }
            }
            .swipeActions(edge: .leading) {
                if job == nil, item.downloadable, !onDisk || model.record(appID).needsUpdate(item) {
                    Button(onDisk ? "Update" : "Download") { model.download(item, appID: appID) }.tint(.accentColor)
                }
            }
    }

    @ViewBuilder private func actions(_ item: SteamWorkshopItem, subscribed: Bool, onDisk: Bool, job: SteamWorkshopModel.Job?) -> some View {
        if job == nil, item.downloadable, steam.workshopReady {
            if !onDisk {
                Button { model.download(item, appID: appID) } label: { Label("Download", systemImage: "arrow.down.circle") }
            } else {
                Button { model.download(item, appID: appID) } label: {
                    Label(model.record(appID).needsUpdate(item) ? "Update" : "Download again", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
        if job != nil {
            Button { model.cancel(item.id) } label: { Label("Stop download", systemImage: "stop.circle") }
        }
        if let url = item.storeURL {
            Link(destination: url) { Label("View on Steam", systemImage: "safari") }
        }
        if subscribed {
            Button(role: .destructive) { Task { await model.unsubscribe(item, appID: appID, remove: true) } } label: {
                Label("Unsubscribe and remove", systemImage: "minus.circle")
            }.disabled(!steam.workshopReady)
            if onDisk {
                Button { Task { await model.unsubscribe(item, appID: appID, remove: false) } } label: {
                    Label("Unsubscribe, keep files", systemImage: "minus.circle")
                }.disabled(!steam.workshopReady)
            }
        } else {
            Button { Task { await model.subscribe(item, appID: appID) } } label: {
                Label("Subscribe", systemImage: "plus.circle")
            }.disabled(!steam.workshopReady)
            if onDisk {
                Button(role: .destructive) { Task { await model.remove(item, appID: appID) } } label: {
                    Label("Remove files", systemImage: "trash")
                }
            }
        }
    }
}

/// Browse: the game's Workshop by popularity, subscriptions or date, or a search.
struct SteamWorkshopBrowseView: View {
    let appID: UInt32
    let title: String
    @ObservedObject private var model = SteamWorkshopModel.shared
    @State private var order: SteamWorkshopRequests.Order = .trend
    @State private var search = ""
    @State private var items: [SteamWorkshopItem] = []
    @State private var total = 0
    @State private var page: UInt32 = 0
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $order) {
                    ForEach(SteamWorkshopRequests.Order.allCases.filter { $0 != .search }) { Text($0.label).tag($0) }
                    if order == .search { Text("Search results").tag(SteamWorkshopRequests.Order.search) }
                }
            }
            Section {
                ForEach(items) { item in
                    HStack {
                        SteamWorkshopItemRow(item: item, appID: appID)
                        Spacer(minLength: 8)
                        subscribeButton(item)
                    }
                }
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(.orange)
                }
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if items.count < total, failure == nil {
                    Button("Load more") { Task { await load(reset: false) } }
                } else if items.isEmpty, failure == nil, page > 0 {
                    Text(order == .search ? "Nothing found." : "This game's Workshop has no items to show.").foregroundStyle(.secondary)
                }
            } footer: {
                if total > 0 { Text("\(items.count) of \(total)") }
            }
        }
        .navigationTitle("\(title) Workshop").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search the Workshop")
        .onSubmit(of: .search) {
            // A new order loads through .task(id:); a new search in Search loads here.
            if order == .search { Task { await load(reset: true) } } else { order = .search }
        }
        .onChange(of: search) { _, text in
            if text.isEmpty && order == .search { order = .trend }
        }
        .task(id: order) { await load(reset: true) }
    }

    @ViewBuilder private func subscribeButton(_ item: SteamWorkshopItem) -> some View {
        if model.changing.contains(item.id) {
            ProgressView()
        } else if model.isSubscribed(item, appID: appID) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Subscribed")
        } else if item.isContent || item.isCollection {
            Button("Subscribe") { Task { await model.subscribe(item, appID: appID) } }
                .buttonStyle(.bordered).font(.callout)
                .disabled(!SteamOwnedLibrary.shared.workshopReady || item.isCollection)
        }
    }

    private func load(reset: Bool) async {
        if order == .search && search.trimmingCharacters(in: .whitespaces).isEmpty { return }
        if reset { items = []; total = 0; page = 0 }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            let next = page + 1
            let result = try await model.browse(appID, order: order, text: search, page: next)
            let known = Set(items.map(\.id))
            items += result.items.filter { !known.contains($0.id) }
            total = result.items.isEmpty ? items.count : result.total
            page = next
        } catch {
            failure = (error as? SteamWorkshopModel.Refused)?.errorDescription ?? SteamSignIn.message(error)
            page = max(page, 1)
        }
    }
}

/// The library's Workshop area: the installed Steam games, those with a
/// Workshop first, each opening its Workshop page.
struct SteamWorkshopHub: View {
    @ObservedObject private var games = SteamGamesModel.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var model = SteamWorkshopModel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let installed = games.games.filter(\.installed).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let withWorkshop = installed.filter { steam.game($0.id)?.workshop == true || !model.record(UInt32($0.id)).installed.isEmpty }
        let others = installed.filter { game in steam.game(game.id)?.workshop != false && !withWorkshop.contains(game) }
        NavigationStack {
            List {
                if !steam.workshopReady {
                    Text(steam.signedIn ? "Not available while a game runs." : "Sign in to Steam (Settings › Steam) to use the Workshop.")
                        .foregroundStyle(.secondary)
                }
                if installed.isEmpty {
                    Text("No Steam games are installed yet.").foregroundStyle(.secondary)
                }
                if !withWorkshop.isEmpty {
                    Section("Games with a Workshop") { ForEach(withWorkshop) { link($0) } }
                }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { link($0) }
                    } header: {
                        Text("Other installed games")
                    } footer: {
                        Text("Steam has not said yet whether these games have a Workshop. Pull down on the library to refresh it.")
                    }
                }
            }
            .navigationTitle("Steam Workshop").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: installed.map(\.id)) {
                for game in installed.prefix(200) { await model.reloadRecord(UInt32(game.id)) }
            }
        }
    }

    private func link(_ game: DockGame) -> some View {
        let appID = UInt32(game.id)
        let count = model.record(appID).installed.count
        let pending = model.subscribed[appID].map { _ in model.pending(appID).count } ?? 0
        return NavigationLink {
            Form { SteamWorkshopSections(appID: appID, title: game.name) }
                .navigationTitle(game.name).navigationBarTitleDisplayMode(.inline)
        } label: {
            HStack(spacing: 12) {
                SteamGameArtwork(appID: game.id).frame(width: 40, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name)
                    Text(count == 0 ? "No items installed" : count == 1 ? "1 item installed" : "\(count) items installed")
                        .font(.caption).foregroundStyle(.secondary)
                    if pending > 0 {
                        Text(pending == 1 ? "1 item to download" : "\(pending) items to download")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
