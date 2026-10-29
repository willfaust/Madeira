// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Akshay CM
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CryptoKit
import Foundation
import GameBrowserKit
import UIKit

// The Epic Games account's games and their downloads (docs/EPIC.md).
//
// Epic decides ownership: the list is the account's Windows assets, and a build's
// manifest is only served to an account that owns it. Games download unmodified
// from Epic's CDN into C:\Program Files\Epic Games\<folder> and start as their own
// program in Wine, with a one-use Epic sign-in code on the command line (the
// launcher's own -AUTH_PASSWORD/-AUTH_TYPE=exchangecode arguments), so the game
// signs in to Epic Online Services itself. There is no Epic launcher in the
// prefix. `env.MADEIRA_EPIC = 0` turns the whole thing off.
// Log tags: [epic-library], [epic-download], [epic-launch] (app names, counts and
// short reason codes; never account data).

/// A game the account owns.
struct EpicOwnedGame: Codable, Identifiable, Hashable, Sendable {
    var appName: String
    var title: String
    var namespace: String
    var catalogItemID: String
    var buildVersion: String
    var cover: URL?
    var wide: URL?
    var folderName: String
    var canRunOffline: Bool
    var requiresOwnershipToken: Bool
    var additionalCommandLine: String?
    /// The catalog's category paths ("games", "engines", ...); nil in a list cached
    /// before they were kept, which looks the game up again.
    var categories: [String]? = nil
    var id: String { appName }
}

/// A game Madeira installed: where, which build and how it starts.
struct EpicInstalledGame: Codable, Sendable {
    var appName: String
    var title: String
    var namespace: String
    var catalogItemID: String
    /// The install folder, relative to drive_c ("Program Files/Epic Games/rocketleague").
    var folder: String
    var buildVersion: String
    /// The program, relative to the install folder, with "/" separators.
    var launchExe: String
    var launchCommand: String
    var installBytes: Int64
    var canRunOffline: Bool
    var requiresOwnershipToken: Bool
    var additionalCommandLine: String?
    /// The build's content keys (encrypted builds only), to read the saved manifest again.
    var secrets: [String: String]?
    var programPath: String { folder + "/" + launchExe }
}

@MainActor final class EpicLibrary: ObservableObject {
    static let shared = EpicLibrary()

    /// Off with `env.MADEIRA_EPIC = 0`.
    static var enabled: Bool { SteamSignIn.flag("MADEIRA_EPIC", default: true) }

    @Published private(set) var signedIn = false
    private(set) var accountID: String?
    @Published private(set) var accountName: String?
    @Published private(set) var owned: [EpicOwnedGame] = []
    @Published private(set) var installed: [String: EpicInstalledGame] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var libraryUpdated: Date?
    @Published var error: String?

    struct Download: Equatable {
        enum Kind: String { case install, update, repair }
        enum State: Equatable { case queued, active, paused, failed(String) }
        var kind: Kind
        var state: State
        var progress = EpicDownloadProgress()
    }
    @Published private(set) var downloads: [String: Download] = [:]
    private var queue: [String] = []
    private var active: (app: String, task: Task<Void, Never>)?
    private var inSession = false
    private var resumeAfterSession = Set<String>()
    private var resumeAfterBackground = Set<String>()
    private var started = false
    private var timer: Timer?
    /// iOS 26 and later: a continued-processing task keeps the queue running in the
    /// background ("<bundle id>.download.epic"); earlier iOS: the short grace period,
    /// then a clean pause. Ported from willfaust/Madeira#207 (iediot).
    private lazy var background = SteamDownloadBackground(source: "Epic Games", suffix: "epic")
    private let api = EpicAPI.shared
    private let downloader = EpicDownloader()

    private init() { loadInstalled() }

    var hasActiveDownload: Bool { downloads.values.contains { $0.state == .active || $0.state == .queued } }
    func game(_ app: String) -> EpicOwnedGame? { owned.first { $0.appName == app } }

    // MARK: Files

    static var drive: URL { LibraryModel.drive }
    static let installRoot = "Program Files/Epic Games"
    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Madeira", isDirectory: true)
    }
    private static var cacheURL: URL { support.appendingPathComponent("epic-library.json") }
    private static var installedURL: URL { support.appendingPathComponent("epic-installed.json") }
    private static func manifestURL(_ app: String) -> URL {
        support.appendingPathComponent("epic-manifests", isDirectory: true).appendingPathComponent(safeName(app) + ".manifest")
    }
    private static func journalURL(_ app: String) -> URL {
        support.appendingPathComponent("epic-downloads", isDirectory: true).appendingPathComponent(safeName(app) + ".journal")
    }
    /// A file or folder name made from Epic's text: no separators, no dots at the ends.
    static func safeName(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = String(text.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return cleaned.isEmpty ? "game" : String(cleaned.prefix(120))
    }
    private struct Cache: Codable { var version: Int; var updated: Date; var account: String; var games: [EpicOwnedGame] }
    private static func accountKey(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Lifecycle

    /// Called when the library shows the Epic section; once per app run.
    func start() {
        guard Self.enabled, !started else { return }
        started = true
        background.attach(active: { [weak self] in self?.hasActiveDownload == true },
                          pause: { [weak self] in self?.pauseForBackground() },
                          resume: { [weak self] in self?.resumeFromBackground(); self?.reconcileSession() })
        Task {
            let account = await api.account()
            signedIn = account != nil
            accountID = account?.id
            accountName = account?.name
            if let account { loadCache(account: account.id) }
            EpicLog.event("[epic-library] start signed-in=\(signedIn ? 1 : 0) cached=\(owned.count) installed=\(installed.count)")
            if signedIn, Date().timeIntervalSince(libraryUpdated ?? .distantPast) > 6 * 3600 {
                await refreshLibrary(interactive: false)
            }
            if signedIn { EpicCloud.shared.startupCheck() }
        }
    }

    private func loadCache(account: String) {
        guard let data = try? Data(contentsOf: Self.cacheURL), data.count <= 32 << 20,
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 1,
              cache.account == Self.accountKey(account) else { return }
        owned = cache.games; libraryUpdated = cache.updated
    }

    private func writeCache(account: String) {
        guard let updated = libraryUpdated else { return }
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Cache(version: 1, updated: updated, account: Self.accountKey(account), games: owned))
            .write(to: Self.cacheURL, options: .atomic)
    }

    private func loadInstalled() {
        guard let data = try? Data(contentsOf: Self.installedURL),
              let records = try? JSONDecoder().decode([String: EpicInstalledGame].self, from: data) else { return }
        // A record whose program is gone (the folder was deleted in Files) is dropped.
        installed = records.filter { FileManager.default.fileExists(atPath: Self.drive.appendingPathComponent($0.value.programPath).path) }
    }

    private func writeInstalled() {
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(installed).write(to: Self.installedURL, options: .atomic)
    }

    // MARK: Account

    /// The authorization code from Epic's login page (EpicSignInView).
    func signIn(code: String) async throws {
        let session = try await api.signIn(authorizationCode: code)
        signedIn = true
        accountName = session.displayName
        accountID = session.accountID
        owned = []; libraryUpdated = nil
        await refreshLibrary(interactive: true)
        EpicCloud.shared.startupCheck()
    }

    /// Removes the tokens and the cached list. Installed games stay; they need a
    /// sign-in again to start online or to update.
    func signOut() {
        for app in Array(downloads.keys) { pause(app) }
        Task { await api.signOut() }
        try? FileManager.default.removeItem(at: Self.cacheURL)
        signedIn = false; accountName = nil; accountID = nil; owned = []; libraryUpdated = nil
    }

    private func handle(_ error: Error, context: String, report: Bool) {
        if case EpicAPIError.signedOut = error {
            signedIn = false; accountName = nil; accountID = nil
        }
        let reason = (error as? EpicAPIError)?.reason ?? (error as? URLError).map { "url-\($0.code.rawValue)" } ?? String(describing: type(of: error))
        EpicLog.event("[epic-library] \(context) failed reason=\(reason)")
        if report { self.error = error.localizedDescription }
    }

    // MARK: Library

    func refreshLibrary(interactive: Bool = true) async {
        guard Self.enabled, signedIn, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let assets = try await api.assets().filter { $0.namespace != "ue" }
            var known = Dictionary(owned.map { ($0.appName, $0) }, uniquingKeysWith: { a, _ in a })
            // Catalog details for new games, games whose build changed and games cached without
            // their categories; at most eight at once.
            let wanted = assets.filter {
                known[$0.appName] == nil || known[$0.appName]?.buildVersion != $0.buildVersion || known[$0.appName]?.categories == nil
            }
            var details: [String: EpicCatalogItem] = [:]
            try await withThrowingTaskGroup(of: (String, EpicCatalogItem?).self) { group in
                var next = 0
                func add() {
                    guard next < wanted.count else { return }
                    let asset = wanted[next]; next += 1
                    group.addTask { [api] in (asset.appName, try? await api.catalogItem(namespace: asset.namespace, id: asset.catalogItemId)) }
                }
                for _ in 0..<8 { add() }
                while let (app, item) = try await group.next() {
                    if let item { details[app] = item }
                    add()
                }
            }
            var games: [EpicOwnedGame] = []
            for asset in assets {
                if let item = details[asset.appName] {
                    if item.isDLC || item.attributes["ThirdPartyManagedApp"] != nil || !Self.isGame(categories: item.categories) {
                        known[asset.appName] = nil; continue
                    }
                    let images = item.images
                    games.append(EpicOwnedGame(
                        appName: asset.appName, title: item.title.isEmpty ? asset.appName : item.title, namespace: asset.namespace,
                        catalogItemID: asset.catalogItemId, buildVersion: asset.buildVersion,
                        cover: images["DieselGameBoxTall"] ?? images["OfferImageTall"] ?? images["Thumbnail"],
                        wide: images["DieselGameBox"] ?? images["OfferImageWide"],
                        folderName: Self.safeName(item.attributes["FolderName"] ?? asset.appName),
                        canRunOffline: (item.attributes["CanRunOffline"] ?? "true").lowercased() == "true",
                        requiresOwnershipToken: (item.attributes["OwnershipToken"] ?? "false").lowercased() == "true",
                        additionalCommandLine: item.attributes["AdditionalCommandLine"], categories: item.categories))
                } else if var game = known[asset.appName], Self.isGame(categories: game.categories ?? []) {
                    game.buildVersion = asset.buildVersion
                    games.append(game)
                }
            }
            owned = games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            libraryUpdated = Date()
            if let account = await api.account() { writeCache(account: account.id); accountName = account.name }
            EpicLog.event("[epic-library] owned assets=\(assets.count) games=\(owned.count)")
        } catch {
            handle(error, context: "library", report: interactive)
        }
    }

    /// Whether a catalog item with these categories belongs in the games list. Not games:
    /// mods (as Legendary) and add-ons ("addons/durable", "addons/consumable": ported from
    /// willfaust/Madeira#207, iediot), and Unreal Engine content outside the "ue"
    /// namespace: marketplace assets, plugins and sample projects ("Animation Starter
    /// Pack"), and engines and editors ("ARK ModKit (UE4)" is filed under "engines" and
    /// "applications"). An item filed under "games" always stays.
    static func isGame(categories: [String]) -> Bool {
        let roots = Set(categories.map { $0.split(separator: "/").first.map(String.init) ?? $0 })
        if roots.contains("mods") || roots.contains("addons") { return false }
        if roots.contains("games") { return true }
        return roots.isDisjoint(with: ["assets", "plugins", "projects", "engines"])
    }

    func updateAvailable(_ app: String) -> Bool {
        guard let record = installed[app], let latest = game(app)?.buildVersion, !latest.isEmpty else { return false }
        return latest != record.buildVersion
    }

    func hasPartialDownload(_ app: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.journalURL(app).path)
    }

    // MARK: Downloads

    func install(_ app: String) { enqueue(app, kind: installed[app] == nil ? .install : .update) }
    func repair(_ app: String) { enqueue(app, kind: .repair) }

    private func enqueue(_ app: String, kind: Download.Kind) {
        guard Self.enabled else { return }
        guard signedIn else { error = "Sign in to Epic Games to download games."; return }
        guard !EpicCloud.shared.isBusy else { error = "Wait for Epic save sync to finish, then try again."; return }
        if active?.app == app || queue.contains(app) { return }
        if inSession { resumeAfterSession.insert(app); downloads[app] = Download(kind: kind, state: .paused); return }
        var item = downloads[app] ?? Download(kind: kind, state: .queued)
        item.state = .queued
        downloads[app] = item
        queue.append(app)
        startTimer()
        pump()
    }

    func pause(_ app: String) {
        if let current = active, current.app == app {
            current.task.cancel()
        } else if let index = queue.firstIndex(of: app) {
            queue.remove(at: index)
            downloads[app]?.state = .paused
        }
        resumeAfterSession.remove(app)
    }

    /// Stops a download. A first install also loses its partial files; an update
    /// or a repair is only stopped.
    func cancel(_ app: String) {
        let running = active?.app == app ? active?.task : nil
        let firstInstall = installed[app] == nil
        pause(app)
        downloads[app] = nil
        guard firstInstall, let game = game(app) else { return }
        let folder = Self.drive.appendingPathComponent(Self.installRoot).appendingPathComponent(game.folderName)
        Task {
            await running?.value
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: Self.journalURL(app))
            EpicLog.event("[epic-download] cancelled app=\(app) partial-files-removed=1")
        }
    }

    /// Deletes the game's files and its library entry (its per-game settings).
    func uninstall(_ app: String) {
        guard let record = installed[app], !inSession, !EpicCloud.shared.isBusy else { return }
        pause(app); downloads[app] = nil
        installed[app] = nil
        writeInstalled()
        LibraryModel.shared.removeEpic(appName: app)
        let folder = Self.drive.appendingPathComponent(record.folder, isDirectory: true)
        let manifest = Self.manifestURL(app), journal = Self.journalURL(app)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: manifest)
            try? FileManager.default.removeItem(at: journal)
        }
        EpicLog.event("[epic-download] uninstalled app=\(app)")
    }

    private func pump() {
        guard active == nil, !inSession, !queue.isEmpty else { return }
        let app = queue.removeFirst()
        downloads[app]?.state = .active
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(app)
        }
        active = (app, task)
        background.downloadStarted(appID: 0, name: game(app)?.title ?? installed[app]?.title ?? "Epic game")
    }

    private func run(_ app: String) async {
        let kind = downloads[app]?.kind ?? .install
        var outcome = SteamDownloadBackground.Outcome.paused
        do {
            guard let game = game(app) ?? installed[app].map({ record in
                EpicOwnedGame(appName: record.appName, title: record.title, namespace: record.namespace, catalogItemID: record.catalogItemID,
                              buildVersion: record.buildVersion, folderName: URL(fileURLWithPath: record.folder).lastPathComponent,
                              canRunOffline: record.canRunOffline, requiresOwnershipToken: record.requiresOwnershipToken,
                              additionalCommandLine: record.additionalCommandLine)
            }) else { throw EpicAPIError.invalid("unknown-game") }
            let asset = EpicAsset(appName: game.appName, labelName: "Live", buildVersion: game.buildVersion,
                                  catalogItemId: game.catalogItemID, namespace: game.namespace)
            let location = try await api.manifestLocation(asset)
            let data = try await api.manifest(location)
            let manifest = try await Task.detached(priority: .userInitiated) { try EpicManifest.parse(data, secrets: location.secrets) }.value
            let launch = manifest.launchExe.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !launch.isEmpty, EpicManifest.components(launch) != nil else {
                throw EpicFormatError.unsupported("no start program in the manifest")
            }
            let record = installed[app]
            let folder = record?.folder ?? (Self.installRoot + "/" + game.folderName)
            // The installed build's file list, so an update keeps unchanged files without reading them.
            let previousData = try? Data(contentsOf: Self.manifestURL(app))
            let previousSecrets = record?.secrets ?? [:]
            let previous = await Task.detached(priority: .utility) { previousData.flatMap { try? EpicManifest.parse($0, secrets: previousSecrets) } }.value
            EpicLog.event("[epic-download] start app=\(app) kind=\(kind.rawValue) files=\(manifest.files.count) chunks=\(manifest.chunks.count) level=\(manifest.featureLevel)")
            let result = try await downloader.install(
                manifest: manifest, baseURLs: location.baseURLs, secrets: location.secrets,
                folder: Self.drive.appendingPathComponent(folder, isDirectory: true),
                previous: kind == .repair ? nil : previous, verifyAll: kind == .repair, journal: Self.journalURL(app)) { progress in
                    Task { @MainActor in
                        EpicLibrary.shared.downloads[app]?.progress = progress
                        EpicLibrary.shared.background.progress(doneBytes: progress.doneBytes, totalBytes: progress.totalBytes)
                    }
                }
            try? FileManager.default.createDirectory(at: Self.manifestURL(app).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.manifestURL(app), options: .atomic)
            let finished = EpicInstalledGame(
                appName: app, title: game.title, namespace: game.namespace, catalogItemID: game.catalogItemID, folder: folder,
                buildVersion: manifest.buildVersion.isEmpty ? location.buildVersion : manifest.buildVersion,
                launchExe: launch, launchCommand: manifest.launchCommand, installBytes: result.installBytes,
                canRunOffline: game.canRunOffline, requiresOwnershipToken: game.requiresOwnershipToken,
                additionalCommandLine: game.additionalCommandLine, secrets: location.secrets.isEmpty ? nil : location.secrets)
            installed[app] = finished
            writeInstalled()
            downloads[app] = nil
            outcome = .completed
            await LibraryModel.shared.upsertEpic(finished, cover: game.cover)
            EpicLog.event("[epic-download] done app=\(app) written=\(result.filesWritten) kept=\(result.filesKept) fetched=\(result.bytesFetched)")
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if downloads[app] != nil { downloads[app]?.state = .paused }
                EpicLog.event("[epic-download] paused app=\(app)")
            } else {
                downloads[app]?.state = .failed(error.localizedDescription)
                outcome = .failed(error.localizedDescription)
                handle(error, context: "download app=\(app)", report: false)
            }
        }
        active = nil
        background.downloadEnded(appID: 0, name: game(app)?.title ?? installed[app]?.title ?? "Epic game",
                                 outcome: outcome, queueEmpty: queue.isEmpty)
        pump()
    }

    // MARK: Sessions and the background

    /// A game session is starting or ended: downloads pause for it (memory, I/O
    /// and CPU belong to the game) and continue afterwards. Idempotent.
    func sessionChanged(active running: Bool) {
        guard running != inSession else { return }
        inSession = running
        if running {
            if let current = active { resumeAfterSession.insert(current.app); current.task.cancel() }
            for app in queue { resumeAfterSession.insert(app); downloads[app]?.state = .paused }
            queue.removeAll()
            if !resumeAfterSession.isEmpty { EpicLog.event("[epic-download] paused for a game session count=\(resumeAfterSession.count)") }
        } else {
            let resume = resumeAfterSession.sorted()
            resumeAfterSession.removeAll()
            for app in resume { enqueue(app, kind: downloads[app]?.kind ?? .install) }
        }
    }

    var sessionRunning: Bool {
        LibraryModel.shared.current != nil || wine_process_is_running() != 0 || wineserver_is_running() != 0
    }

    func reconcileSession() { sessionChanged(active: sessionRunning) }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconcileSession()
                if !self.hasActiveDownload { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }

    /// iOS ended Madeira's background time (the grace period before iOS 26, or the
    /// continued-processing task): downloads pause cleanly (finished files are
    /// journaled) and continue when Madeira is active.
    private func pauseForBackground() {
        if let current = active { resumeAfterBackground.insert(current.app); current.task.cancel() }
        for app in queue { resumeAfterBackground.insert(app); downloads[app]?.state = .paused }
        queue.removeAll()
        EpicLog.event("[epic-download] paused for the background count=\(resumeAfterBackground.count)")
    }

    private func resumeFromBackground() {
        let apps = resumeAfterBackground.sorted()
        resumeAfterBackground.removeAll()
        for app in apps { enqueue(app, kind: downloads[app]?.kind ?? .install) }
    }

    func browserActivationURL(_ request: UrlOpenRequest) async -> URL {
        guard request.kind == .epicActivation, signedIn,
              LibraryModel.shared.activeEntry?.epicAppName != nil,
              let code = try? await api.exchangeCode(), let url = request.epicSignInURL(exchangeCode: code) else { return request.url }
        return url
    }

    // MARK: Launch

    /// The arguments Epic's launcher gives a game: a fresh one-use sign-in code for
    /// the account, the app and the account's name and id. Without a connection,
    /// a game Epic marks as playable offline starts without the code.
    func launchArguments(appName app: String) async throws -> String {
        guard let record = installed[app] else { throw EpicAPIError.invalid("not-installed") }
        var code = ""
        var ownershipFile: String?
        do {
            code = try await api.exchangeCode()
            if record.requiresOwnershipToken {
                let token = try await api.ownershipToken(namespace: record.namespace, catalogItemID: record.catalogItemID)
                let name = "epic-\(Self.safeName(record.namespace + record.catalogItemID)).ovt"
                let url = Self.drive.appendingPathComponent("madeira-games", isDirectory: true).appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try token.write(to: url, options: .atomic)
                ownershipFile = "C:\\madeira-games\\" + name
            }
        } catch let error as URLError where record.canRunOffline {
            EpicLog.event("[epic-launch] app=\(app) offline reason=url-\(error.code.rawValue)")
        } catch EpicAPIError.signedOut {
            signedIn = false; accountName = nil; accountID = nil
            throw EpicAPIError.signedOut
        }
        let account = await api.account()
        func quoted(_ s: String) -> String { s.contains(" ") ? "\"\(s)\"" : s }
        let name = (account?.name ?? "").replacingOccurrences(of: "\"", with: "")
        var args: [String] = []
        if !record.launchCommand.isEmpty { args.append(record.launchCommand) }
        if let extra = record.additionalCommandLine, !extra.isEmpty { args.append(extra) }
        args += ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=\(code)", "-AUTH_TYPE=exchangecode", "-epicapp=\(app)", "-epicenv=Prod"]
        if let ownershipFile { args.append(quoted("-epicovt=\(ownershipFile)")) }
        args += ["-EpicPortal", quoted("-epicusername=\(name)"), "-epicuserid=\(account?.id ?? "")", "-epiclocale=en",
                 "-epicsandboxid=\(record.namespace)"]
        EpicLog.event("[epic-launch] app=\(app) online=\(code.isEmpty ? 0 : 1) ovt=\(ownershipFile == nil ? 0 : 1)")
        return args.joined(separator: " ")
    }
}
