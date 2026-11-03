// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CryptoKit
import Foundation
import UIKit

// The GOG account's games and their downloads (docs/GOG.md).
//
// GOG decides ownership: the list is the account's library, and a build's chunks
// are only served through addresses GOG signs for an account that owns the game.
// Games download unmodified from GOG's CDN into C:\GOG Games\<folder> and start as
// their own program in Wine, as the build's goggame-<id>.info names it (GOG
// Galaxy's own "play task"). There is no GOG Galaxy client in the prefix (Madeira
// answers for it while a game runs: GOGGalaxy.swift); GOG games are DRM-free and
// need no sign-in to start. DLC the account owns installs
// with the game. `env.MADEIRA_GOG = 0` turns the whole thing off.
// Log tags: [gog-library], [gog-download] (product ids, counts and short reason
// codes; never account data).

/// A game the account owns.
struct GOGOwnedGame: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    /// GOG's tall cover, when its game database has one.
    var cover: URL?
    /// The library listing's wide picture.
    var wide: URL?
}

/// A game Madeira installed: where, which build and how it starts.
struct GOGInstalledGame: Codable, Sendable {
    var productID: String
    var title: String
    /// The install folder, relative to drive_c ("GOG Games/Witcher 3 Wild Hunt").
    var folder: String
    var buildID: String
    var versionName: String
    var language: String
    /// The program, relative to the install folder, with "/" separators.
    var launchExe: String
    var arguments: String
    /// The play task's working folder, relative to the install folder ("/" separators); nil: the program's.
    var workingDir: String?
    var installBytes: Int64
    /// DLC whose files were installed with the game.
    var dlc: [String]
    /// The build's Galaxy client, for GOG's game services while it runs (GOGGalaxy); nil: none.
    var galaxy: GOGGalaxyClient?
    /// Redistributables' installers the game's first start runs (GOGSetup); nil in a record
    /// from before Madeira installed them (Repair adds them).
    var setup: [GOGSetupProgram]?
    /// Redistributables left out, and why.
    var setupNotes: [GOGSetupNote]?
    /// The program the player chose on the game's page (relative to the install folder),
    /// kept over updates while it exists; nil: GOG's primary play task.
    var chosenProgram: String?
    var programPath: String { folder + "/" + launchExe }
    /// The working folder as a C:\ path, or nil.
    var workingWindowsPath: String? {
        guard let workingDir, !workingDir.isEmpty else { return nil }
        return "C:\\" + (folder + "/" + workingDir).replacingOccurrences(of: "/", with: "\\")
    }
}

@MainActor final class GOGLibrary: ObservableObject {
    static let shared = GOGLibrary()

    /// Off with `env.MADEIRA_GOG = 0`.
    static var enabled: Bool { SteamSignIn.flag("MADEIRA_GOG", default: true) }

    @Published private(set) var signedIn = false
    @Published private(set) var accountName: String?
    @Published private(set) var owned: [GOGOwnedGame] = []
    @Published private(set) var installed: [String: GOGInstalledGame] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var libraryUpdated: Date?
    /// The newest build id seen for each installed game (checked when its page opens).
    @Published private(set) var latestBuild: [String: String] = [:]
    /// A game's download and installed size for what Madeira would install (the
    /// newest build's chosen depots, owned DLC included), or why GOG gave none.
    enum Size: Equatable { case known(download: Int64, install: Int64), unavailable(String) }
    @Published private(set) var sizes: [String: Size] = [:]
    @Published var error: String?

    struct Download: Equatable {
        enum Kind: String { case install, update, repair }
        enum State: Equatable { case queued, active, paused, failed(String) }
        var kind: Kind
        var state: State
        var progress = GOGDownloadProgress()
    }
    @Published private(set) var downloads: [String: Download] = [:]
    private var queue: [String] = []
    private var active: (id: String, task: Task<Void, Never>)?
    private var inSession = false
    private var resumeAfterSession = Set<String>()
    private var resumeAfterBackground = Set<String>()
    private var started = false
    private var timer: Timer?
    /// In the background a download keeps going while Madeira keeps running
    /// (BackgroundRun.swift), else for the grace period iOS allows; then it
    /// pauses cleanly and continues when Madeira is active again.
    private var grace: BackgroundRun.Token?
    private let api = GOGAPI.shared
    private let downloader = GOGDownloader()

    private init() { loadInstalled() }

    var hasActiveDownload: Bool { downloads.values.contains { $0.state == .active || $0.state == .queued } }
    func game(_ id: String) -> GOGOwnedGame? { owned.first { $0.id == id } }

    // MARK: Files

    static var drive: URL { LibraryModel.drive }
    static let installRoot = "GOG Games"
    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Madeira", isDirectory: true)
    }
    private static var cacheURL: URL { support.appendingPathComponent("gog-library.json") }
    private static var installedURL: URL { support.appendingPathComponent("gog-installed.json") }
    /// The installed build's file list, so an update keeps unchanged files without reading them.
    private static func filesURL(_ id: String) -> URL {
        support.appendingPathComponent("gog-manifests", isDirectory: true).appendingPathComponent(GOGLibrary.safeName(id) + ".json")
    }
    private static func journalURL(_ id: String) -> URL {
        support.appendingPathComponent("gog-downloads", isDirectory: true).appendingPathComponent(GOGLibrary.safeName(id) + ".journal")
    }
    /// A file or folder name made from GOG's text: no separators, no dots at the ends.
    nonisolated static func safeName(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = String(text.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return cleaned.isEmpty ? "game" : String(cleaned.prefix(120))
    }
    private struct Cache: Codable { var version: Int; var updated: Date; var account: String; var games: [GOGOwnedGame] }
    private static func accountKey(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Lifecycle

    /// Called when the library shows the GOG section; once per app run.
    func start() {
        guard Self.enabled, !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginGrace() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endGrace()
                self.resumeFromBackground()
                self.reconcileSession()
            }
        }
        Task {
            let account = await api.account()
            signedIn = account != nil
            accountName = account?.name
            if let account { loadCache(account: account.id) }
            GOGLog.event("[gog-library] start signed-in=\(signedIn ? 1 : 0) cached=\(owned.count) installed=\(installed.count)")
            if signedIn, Date().timeIntervalSince(libraryUpdated ?? .distantPast) > 6 * 3600 {
                await refreshLibrary(interactive: false)
            }
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
              let records = try? JSONDecoder().decode([String: GOGInstalledGame].self, from: data) else { return }
        // A record whose program is gone (the folder was deleted in Files) is dropped. One
        // saved with the .info file's spelling of the program takes the name on disk.
        var repaired = false
        installed = records.compactMapValues { record in
            var record = record
            let root = Self.drive.appendingPathComponent(record.folder, isDirectory: true)
            guard let exe = Self.onDisk(record.launchExe, folder: root) else { return nil }
            if exe != record.launchExe {
                if record.chosenProgram == record.launchExe { record.chosenProgram = exe }
                record.launchExe = exe
                repaired = true
            }
            if let dir = record.workingDir, let found = Self.onDisk(dir, folder: root), found != dir {
                record.workingDir = found
                repaired = true
            }
            return record
        }
        if repaired { writeInstalled() }
    }

    private func writeInstalled() {
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(installed).write(to: Self.installedURL, options: .atomic)
    }

    // MARK: Account

    /// The code from GOG's login page (GOGSignInView).
    func signIn(code: String) async throws {
        let session = try await api.signIn(authorizationCode: code)
        signedIn = true
        accountName = session.userName.isEmpty ? nil : session.userName
        owned = []; libraryUpdated = nil
        await refreshLibrary(interactive: true)
    }

    /// Removes the tokens and the cached list. Installed games stay and still start:
    /// GOG games need no sign-in to play, only to download and update.
    func signOut() {
        for id in Array(downloads.keys) { pause(id) }
        Task { await api.signOut() }
        try? FileManager.default.removeItem(at: Self.cacheURL)
        signedIn = false; accountName = nil; owned = []; libraryUpdated = nil
    }

    private func handle(_ error: Error, context: String, report: Bool) {
        if case GOGAPIError.signedOut = error {
            signedIn = false; accountName = nil
        }
        var reason = (error as? GOGAPIError)?.reason ?? (error as? URLError).map { "url-\($0.code.rawValue)" } ?? String(describing: type(of: error))
        if case let .chunk(why)? = error as? GOGDownloadError { reason = "chunk \(why)" }
        GOGLog.event("[gog-library] \(context) failed reason=\(reason)")
        if report { self.error = error.localizedDescription }
    }

    // MARK: Library

    func refreshLibrary(interactive: Bool = true) async {
        guard Self.enabled, signedIn, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let products = try await api.products().filter(\.windows)
            let known = Dictionary(owned.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // Tall covers for games not seen before; at most eight lookups at once.
            let wanted = products.filter { known[$0.id] == nil }
            var covers: [String: URL] = [:]
            await withTaskGroup(of: (String, URL?).self) { group in
                var next = 0
                func add() {
                    guard next < wanted.count else { return }
                    let id = wanted[next].id; next += 1
                    group.addTask { [api] in (id, await api.verticalCover(id)) }
                }
                for _ in 0..<8 { add() }
                while let (id, cover) = await group.next() {
                    if let cover { covers[id] = cover }
                    add()
                }
            }
            owned = products.map { product in
                GOGOwnedGame(id: product.id, title: product.title, cover: covers[product.id] ?? known[product.id]?.cover ?? product.image,
                             wide: product.image)
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            libraryUpdated = Date()
            if let account = await api.account() { writeCache(account: account.id) }
            GOGLog.event("[gog-library] owned games=\(owned.count)")
        } catch {
            handle(error, context: "library", report: interactive)
        }
    }

    /// Reads a game's sizes from its newest build's details (the download sheet); once per app run.
    func loadSize(_ id: String) async {
        guard signedIn, sizes[id] == nil else { return }
        do {
            let build = try await api.latestBuild(id)
            let manifest = try GOGBuildManifest.parse(try GOGCodec.json(try await api.buildManifest(build), what: "build"))
            let owned = try await api.ownedIDs()
            let depots = manifest.selected(ownedDLC: owned.subtracting([manifest.baseProductID])).depots
            guard !depots.isEmpty else { throw GOGAPIError.noWindowsBuild }
            sizes[id] = .known(download: depots.reduce(0) { $0 + $1.compressedSize }, install: depots.reduce(0) { $0 + $1.size })
        } catch {
            let reason = (error as? GOGAPIError)?.reason ?? (error as? URLError).map { "url-\($0.code.rawValue)" } ?? "error"
            GOGLog.event("[gog-library] size id=\(id) failed reason=\(reason)")
            // A connection problem is tried again next time; GOG's own answer is kept.
            if error is GOGAPIError || error is GOGFormatError { sizes[id] = .unavailable(error.localizedDescription) }
        }
    }

    /// Looks up the newest build of an installed game (its Game details page).
    func checkForUpdate(_ id: String) async {
        guard signedIn, installed[id] != nil, let build = try? await api.latestBuild(id) else { return }
        latestBuild[id] = build.buildID
        // An install from before Madeira kept the build's Galaxy client: read it from the same build.
        if let record = installed[id], record.setup == nil, record.galaxy == nil, record.buildID == build.buildID,
           let data = try? await api.buildManifest(build), let json = try? GOGCodec.json(data, what: "build"),
           let client = (try? GOGBuildManifest.parse(json))?.galaxy {
            installed[id]?.galaxy = client
            writeInstalled()
            GOGLog.event("[gog-library] galaxy client read id=\(id)")
        }
    }

    func updateAvailable(_ id: String) -> Bool {
        guard let record = installed[id], let latest = latestBuild[id], !latest.isEmpty else { return false }
        return latest != record.buildID
    }

    func hasPartialDownload(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.journalURL(id).path)
    }

    // MARK: Downloads

    func install(_ id: String) { enqueue(id, kind: installed[id] == nil ? .install : .update) }
    func repair(_ id: String) { enqueue(id, kind: .repair) }

    private func enqueue(_ id: String, kind: Download.Kind) {
        guard Self.enabled else { return }
        guard signedIn else { error = "Sign in to GOG to download games."; return }
        if active?.id == id || queue.contains(id) { return }
        if inSession { resumeAfterSession.insert(id); downloads[id] = Download(kind: kind, state: .paused); return }
        var item = downloads[id] ?? Download(kind: kind, state: .queued)
        item.state = .queued
        downloads[id] = item
        queue.append(id)
        startTimer()
        pump()
    }

    func pause(_ id: String) {
        if let current = active, current.id == id {
            current.task.cancel()
        } else if let index = queue.firstIndex(of: id) {
            queue.remove(at: index)
            downloads[id]?.state = .paused
        }
        resumeAfterSession.remove(id)
    }

    /// Stops a download. A first install also loses its partial files; an update
    /// or a repair is only stopped.
    func cancel(_ id: String) {
        let running = active?.id == id ? active?.task : nil
        let firstInstall = installed[id] == nil
        pause(id)
        downloads[id] = nil
        guard firstInstall else { return }
        let folderFile = Self.journalURL(id).deletingPathExtension().appendingPathExtension("folder")
        Task {
            await running?.value
            // The folder the download chose, recorded when it started.
            if let folder = try? String(contentsOf: folderFile, encoding: .utf8), !folder.isEmpty,
               folder.hasPrefix(Self.installRoot + "/") {
                try? FileManager.default.removeItem(at: Self.drive.appendingPathComponent(folder, isDirectory: true))
            }
            try? FileManager.default.removeItem(at: folderFile)
            try? FileManager.default.removeItem(at: Self.journalURL(id))
            GOGLog.event("[gog-download] cancelled id=\(id) partial-files-removed=1")
        }
    }

    /// Deletes the game's files and its library entry (its per-game settings).
    func uninstall(_ id: String) {
        guard let record = installed[id], !inSession else { return }
        pause(id); downloads[id] = nil
        installed[id] = nil
        writeInstalled()
        LibraryModel.shared.removeGOG(productID: id)
        let folder = Self.drive.appendingPathComponent(record.folder, isDirectory: true)
        let files = Self.filesURL(id), journal = Self.journalURL(id)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: files)
            try? FileManager.default.removeItem(at: journal)
        }
        GOGLog.event("[gog-download] uninstalled id=\(id)")
    }

    private func pump() {
        guard active == nil, !inSession, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        downloads[id]?.state = .active
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(id)
        }
        active = (id, task)
    }

    private func run(_ id: String) async {
        let kind = downloads[id]?.kind ?? .install
        do {
            guard let title = game(id)?.title ?? installed[id]?.title else { throw GOGAPIError.invalid("unknown-game") }
            // What the download is waiting for before its first chunk, shown and logged.
            func step(_ text: String) {
                downloads[id]?.progress.step = text
                GOGLog.event("[gog-download] prepare id=\(id) step=\"\(text)\"")
            }
            step("Finding the newest build")
            let build = try await api.latestBuild(id)
            step("Getting the build's details")
            let manifest = try GOGBuildManifest.parse(try GOGCodec.json(try await api.buildManifest(build), what: "build"))
            step("Checking which DLC you own")
            let ownedIDs = try await api.ownedIDs()
            let (depots, language) = manifest.selected(ownedDLC: ownedIDs.subtracting([manifest.baseProductID]))
            guard !depots.isEmpty else { throw GOGAPIError.noWindowsBuild }
            var files: [GOGFile] = []
            for (index, depot) in depots.enumerated() {
                try Task.checkCancellation()
                step("Getting the file list (\(index + 1) of \(depots.count))")
                let data = try await api.depotManifest(depot.manifest)
                files += try await Task.detached(priority: .userInitiated) { try GOGDepot.files(data, product: depot.productID) }.value
            }
            files = GOGDepot.unique(files)
            let record = installed[id]
            let folder = record?.folder ?? (Self.installRoot + "/" + GOGLibrary.safeName(manifest.installDirectory))
            try? FileManager.default.createDirectory(at: Self.journalURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? folder.write(to: Self.journalURL(id).deletingPathExtension().appendingPathExtension("folder"), atomically: true, encoding: .utf8)
            let previousData = try? Data(contentsOf: Self.filesURL(id))
            let previous = previousData.flatMap { try? JSONDecoder().decode([GOGFile].self, from: $0) }
            let dlc = Set(depots.map(\.productID)).subtracting([manifest.baseProductID]).sorted()
            GOGLog.event("[gog-download] start id=\(id) kind=\(kind.rawValue) build=\(build.buildID) depots=\(depots.count) dlc=\(dlc.count) files=\(files.count)")
            let api = self.api
            let links = GOGLinks { product in try await api.secureLinks(product) }
            let result = try await downloader.install(
                files: files, build: id + "#" + build.buildID + "#" + language, links: links,
                folder: Self.drive.appendingPathComponent(folder, isDirectory: true),
                previous: kind == .repair ? nil : previous, verifyAll: kind == .repair, journal: Self.journalURL(id)) { progress in
                    Task { @MainActor in GOGLibrary.shared.downloads[id]?.progress = progress }
                }
            try? FileManager.default.createDirectory(at: Self.filesURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(files).write(to: Self.filesURL(id), options: .atomic)
            let setup = try await installRedistributables(id, manifest: manifest, folder: folder, repair: kind == .repair, step: step)
            try? FileManager.default.removeItem(at: Self.journalURL(id).deletingPathExtension().appendingPathExtension("folder"))
            let root = Self.drive.appendingPathComponent(folder, isDirectory: true)
            var task = try Self.playTask(folder: root, product: id)
            // The player's own choice of program stays while the new build still has it.
            if let chosen = record?.chosenProgram, let choice = Self.programChoices(folder: root, product: id).first(where: { $0.task.path == chosen }) {
                task = choice.task
            }
            var finished = GOGInstalledGame(
                productID: id, title: title, folder: folder, buildID: build.buildID, versionName: build.versionName,
                language: language, launchExe: task.path, arguments: task.arguments, workingDir: task.workingDir,
                installBytes: result.installBytes, dlc: dlc, galaxy: manifest.galaxy, setup: setup.run, setupNotes: setup.notes)
            if task.path == record?.chosenProgram { finished.chosenProgram = task.path }
            installed[id] = finished
            latestBuild[id] = build.buildID
            writeInstalled()
            downloads[id] = nil
            // Repair also runs the game's redistributable installers again at its next start.
            if kind == .repair { GOGSetup.forget(setup.run.map(\.id), drive: Self.drive) }
            await LibraryModel.shared.upsertGOG(finished, previous: record, cover: game(id)?.cover)
            GOGLog.event("[gog-download] done id=\(id) written=\(result.filesWritten) kept=\(result.filesKept) fetched=\(result.bytesFetched) galaxy=\(manifest.galaxy == nil ? 0 : 1) setup=\(setup.run.count) setup-skipped=\(setup.notes.count)")
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if downloads[id] != nil { downloads[id]?.state = .paused }
                GOGLog.event("[gog-download] paused id=\(id)")
            } else {
                downloads[id]?.state = .failed(error.localizedDescription)
                handle(error, context: "download id=\(id)", report: false)
            }
        }
        active = nil
        pump()
    }

    // MARK: Redistributables

    /// Downloads the build's redistributables into the game's folder and says which
    /// installers its first start runs (GOGSetup). A failure here does not fail the
    /// game's download: the game is kept, the page says so and Repair tries again. Only a
    /// pause or cancel is thrown.
    private func installRedistributables(_ id: String, manifest: GOGBuildManifest, folder: String, repair: Bool,
                                         step: (String) -> Void) async throws -> GOGSetup.Plan {
        guard !manifest.dependencies.isEmpty else { return GOGSetup.Plan() }
        do {
            step("Checking the game's redistributables")
            let repository = try await api.dependencyRepository()
            var plan = GOGSetup.plan(manifest.dependencies, repository: repository, hasMsiexec: DockInstallers.bundleHasMsiexec)
            var files: [GOGFile] = []
            for (index, dependency) in plan.download.enumerated() {
                try Task.checkCancellation()
                step("Getting redistributable \(index + 1) of \(plan.download.count)")
                let data = try await api.dependencyDepot(dependency.manifest)
                files += try await Task.detached(priority: .userInitiated) { try GOGDepot.files(data, product: "redist") }.value
            }
            if !files.isEmpty {
                step("Downloading redistributables")
                let api = self.api
                let links = GOGLinks { _ in try await api.dependencyLinks() }
                let result = try await downloader.install(
                    files: files, build: id + "#redist#" + plan.download.map(\.manifest).joined(separator: ","), links: links,
                    folder: Self.drive.appendingPathComponent(folder, isDirectory: true), previous: nil, verifyAll: repair,
                    journal: Self.journalURL(id + "-redist")) { progress in
                        Task { @MainActor in GOGLibrary.shared.downloads[id]?.progress = progress }
                    }
                GOGLog.event("[gog-setup] files id=\(id) written=\(result.filesWritten) kept=\(result.filesKept)")
            }
            GOGLog.event("[gog-setup] plan id=\(id) ids=\(manifest.dependencies.joined(separator: ",")) run=\(plan.run.map(\.id).joined(separator: ",")) skipped=\(plan.notes.map(\.id).joined(separator: ","))")
            plan.download = []
            return plan
        } catch {
            // A pause or cancel stops the whole download, as during the game's own files.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            var reason = (error as? GOGAPIError)?.reason ?? (error as? URLError).map { "url-\($0.code.rawValue)" } ?? String(describing: type(of: error))
            if case let .chunk(why)? = error as? GOGDownloadError { reason = "chunk \(why)" }
            GOGLog.event("[gog-setup] redistributables not downloaded id=\(id) reason=\(reason)")
            var plan = GOGSetup.Plan()
            plan.notes = [GOGSetupNote(id: "", name: "Redistributables",
                                       note: "Could not be downloaded this time. Repair installed files tries again.")]
            return plan
        }
    }

    /// The batch lines a GOG game's start runs before the game (LibraryEntry.setGOGSetup), or nil.
    func setupBatch(for entry: LibraryEntry) -> String? {
        guard let product = entry.gogProductID, let record = installed[product], let programs = record.setup, !programs.isEmpty else { return nil }
        let folder = "C:\\" + record.folder.replacingOccurrences(of: "/", with: "\\")
        let lines = GOGSetup.batchLines(programs, folder: folder, drive: Self.drive)
        guard !lines.isEmpty else { return nil }
        GOGLog.event("[gog-setup] this start runs installers id=\(product) count=\(lines.filter { $0.hasPrefix("echo [gog-setup]") }.count)")
        return lines.joined(separator: "\r\n")
    }

    // MARK: Install script

    /// The installed GOG game whose folder holds `entry`'s program: the entry's own
    /// game, or one whose folder an added program sits in (System\witcher.exe).
    func installedGame(for entry: LibraryEntry) -> GOGInstalledGame? {
        if let product = entry.gogProductID, let record = installed[product] { return record }
        let path = entry.relativePath.lowercased()
        return installed.values.first { path.hasPrefix($0.folder.lowercased() + "/") }
    }

    /// Called right before a library game starts, while no session runs: the registry
    /// values of the game's install scripts (GOGInstallScript), which GOG Galaxy's
    /// script interpreter would have written. A value the prefix has stays as it is,
    /// except one made from the game's folder, which follows the folder.
    func writeInstallScriptRegistry(for entry: LibraryEntry) {
        guard entry.desktop != true, let record = installedGame(for: entry),
              wineserver_is_running() == 0, wine_process_is_running() == 0 else { return }
        let folderURL = Self.drive.appendingPathComponent(record.folder, isDirectory: true)
        let folder = "C:\\" + record.folder.replacingOccurrences(of: "/", with: "\\")
        var values: [SteamInstallValue] = []
        for file in GOGInstallScript.scripts(in: folderURL) {
            guard let data = try? Data(contentsOf: file), let script = GOGInstallScript.parse(data) else {
                GOGLog.event("[gog-script] \(file.lastPathComponent) could not be read")
                continue
            }
            let plan = script.plan(folder: folder, language: record.language)
            for note in plan.notes { GOGLog.event("[gog-script] \(note)") }
            values += plan.values.map { value in
                let data: SteamInstallValue.Content
                switch value.data {
                case .string(let text): data = .string(text)
                case .dword(let number): data = .dword(number)
                }
                return SteamInstallValue(hive: value.root == .machine ? .machine : .user, key: value.key,
                                         name: value.name, data: data, followsInstall: value.followsInstall)
            }
        }
        guard !values.isEmpty else { return }
        do {
            let changed = try SteamInstallRegistry.write(values, prefix: Self.drive.deletingLastPathComponent())
            GOGLog.event("[gog-script] id=\(record.productID) registry values=\(values.count) written=\(changed)")
        } catch {
            GOGLog.event("[gog-script] id=\(record.productID) registry not written: \(error.localizedDescription)")
        }
    }

    // MARK: Play task

    struct PlayTask: Equatable, Sendable { var path: String; var arguments: String; var workingDir: String? }

    /// How GOG Galaxy starts the game: the primary file task of goggame-<id>.info in the
    /// install folder, else the folder's only program.
    nonisolated static func playTask(folder: URL, product: String) throws -> PlayTask {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        if let name = names.first(where: { $0.lowercased() == "goggame-\(product).info" }),
           let data = try? Data(contentsOf: folder.appendingPathComponent(name)), data.count < 4 << 20,
           let task = playTask(info: data) {
            return onDisk(task, folder: folder)
        }
        let programs = names.filter { $0.lowercased().hasSuffix(".exe") && !$0.lowercased().hasPrefix("unins") }
        if programs.count == 1 { return PlayTask(path: programs[0], arguments: "", workingDir: nil) }
        throw GOGAPIError.noPlayTask
    }

    /// The task with its program and working folder spelled as on disk: GOG's .info files
    /// name them as Windows would match them, ignoring case ("dosbox.exe" for DOSBox.exe),
    /// and this file system does not.
    nonisolated static func onDisk(_ task: PlayTask, folder: URL) -> PlayTask {
        var task = task
        task.path = onDisk(task.path, folder: folder) ?? task.path
        if let dir = task.workingDir { task.workingDir = onDisk(dir, folder: folder) ?? dir }
        return task
    }

    /// A "/"-separated path below the folder, each part matched ignoring case; nil: not there.
    nonisolated static func onDisk(_ relative: String, folder: URL) -> String? {
        let fm = FileManager.default
        var url = folder
        var parts: [String] = []
        for part in relative.split(separator: "/").map(String.init) {
            let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            guard let name = names.first(where: { $0 == part }) ?? names.first(where: { $0.lowercased() == part.lowercased() }) else { return nil }
            parts.append(name)
            url.appendPathComponent(name)
        }
        return parts.joined(separator: "/")
    }

    /// A program the game's page offers: GOG's play tasks first (its name, such as
    /// "Launcher" or "The Witcher"), then the other programs in the install folder and
    /// one folder below it (a launcher that quits leaves the game itself one tap away).
    struct ProgramChoice: Equatable, Identifiable, Sendable {
        var name: String
        var task: PlayTask
        var id: String { task.path.lowercased() }
    }

    nonisolated static func programChoices(folder: URL, product: String) -> [ProgramChoice] {
        let fm = FileManager.default
        var choices: [ProgramChoice] = []
        func add(_ choice: ProgramChoice) {
            if !choices.contains(where: { $0.id == choice.id }), choices.count < 40 { choices.append(choice) }
        }
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        if let name = names.first(where: { $0.lowercased() == "goggame-\(product).info" }),
           let data = try? Data(contentsOf: folder.appendingPathComponent(name)), data.count < 4 << 20 {
            for (title, task) in playTasks(info: data) { add(ProgramChoice(name: title, task: onDisk(task, folder: folder))) }
        }
        func programs(_ relative: String) -> [String] {
            let url = relative.isEmpty ? folder : folder.appendingPathComponent(relative, isDirectory: true)
            return ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted().filter {
                let lower = $0.lowercased()
                return lower.hasSuffix(".exe") && !lower.hasPrefix("unins") && !lower.hasPrefix("madeira-")
            }.map { relative.isEmpty ? $0 : relative + "/" + $0 }
        }
        var folders: [String] = []
        for name in names.sorted() where !name.hasPrefix(".") && !name.hasPrefix("__") {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue { folders.append(name) }
        }
        for path in programs("") + folders.prefix(40).flatMap(programs) {
            add(ProgramChoice(name: (path as NSString).lastPathComponent, task: PlayTask(path: path, arguments: "", workingDir: nil)))
        }
        return choices
    }

    /// Starts the game with another program (the game's page). The library entry follows
    /// in the page itself; this keeps the choice over updates.
    func chooseProgram(_ id: String, _ choice: ProgramChoice) {
        guard var record = installed[id] else { return }
        record.launchExe = choice.task.path
        record.arguments = choice.task.arguments
        record.workingDir = choice.task.workingDir
        record.chosenProgram = choice.task.path
        installed[id] = record
        writeInstalled()
        GOGLog.event("[gog-library] program chosen id=\(id)")
    }

    /// Every file task of a goggame-<id>.info file, with its name, primary first.
    nonisolated static func playTasks(info data: Data) -> [(String, PlayTask)] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = json["playTasks"] as? [[String: Any]] else { return [] }
        let files = tasks.filter { ($0["type"] as? String ?? "FileTask") == "FileTask" && $0["path"] is String }
        let ordered = files.filter { $0["isPrimary"] as? Bool == true } + files.filter { $0["isPrimary"] as? Bool != true }
        return ordered.compactMap { task in
            guard let one = try? JSONSerialization.data(withJSONObject: ["playTasks": [task.merging(["isPrimary": true]) { _, new in new }]]),
                  let parsed = playTask(info: one) else { return nil }
            return ((task["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? parsed.path, parsed)
        }
    }

    /// The play task from a goggame-<id>.info file's JSON.
    nonisolated static func playTask(info data: Data) -> PlayTask? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = json["playTasks"] as? [[String: Any]] else { return nil }
        let files = tasks.filter { ($0["type"] as? String ?? "FileTask") == "FileTask" && $0["path"] is String }
        guard let task = files.first(where: { $0["isPrimary"] as? Bool == true })
                ?? files.first(where: { ($0["category"] as? String ?? "game") == "game" }) ?? files.first,
              let raw = task["path"] as? String else { return nil }
        let path = raw.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard GOGCodec.components(path) != nil else { return nil }
        var arguments = ""
        if let text = task["arguments"] as? String { arguments = text }
        else if let list = task["arguments"] as? [String] { arguments = list.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") }
        var workingDir = (task["workingDir"] as? String)?.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let dir = workingDir, dir.isEmpty || GOGCodec.components(dir) == nil { workingDir = nil }
        return PlayTask(path: path, arguments: arguments.trimmingCharacters(in: .whitespaces), workingDir: workingDir)
    }

    // MARK: Sessions and the background

    /// A game session is starting or ended: downloads pause for it (memory, I/O
    /// and CPU belong to the game) and continue afterwards. Idempotent.
    func sessionChanged(active running: Bool) {
        guard running != inSession else { return }
        inSession = running
        if running {
            if let current = active { resumeAfterSession.insert(current.id); current.task.cancel() }
            for id in queue { resumeAfterSession.insert(id); downloads[id]?.state = .paused }
            queue.removeAll()
            if !resumeAfterSession.isEmpty { GOGLog.event("[gog-download] paused for a game session count=\(resumeAfterSession.count)") }
        } else {
            let resume = resumeAfterSession.sorted()
            resumeAfterSession.removeAll()
            for id in resume { enqueue(id, kind: downloads[id]?.kind ?? .install) }
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

    /// Madeira went to the background during a download: iOS's grace period, then a clean pause.
    private func beginGrace() {
        guard hasActiveDownload, grace == nil else { return }
        grace = BackgroundRun.shared.beginTask("GOG download") { [weak self] in
            MainActor.assumeIsolated {
                self?.pauseForBackground()
                self?.endGrace()
            }
        }
    }

    private func endGrace() {
        guard let task = grace else { return }
        grace = nil
        BackgroundRun.shared.endTask(task)
    }

    /// iOS ended Madeira's background time: downloads pause cleanly (finished files
    /// are journaled) and continue when Madeira is active.
    private func pauseForBackground() {
        if let current = active { resumeAfterBackground.insert(current.id); current.task.cancel() }
        for id in queue { resumeAfterBackground.insert(id); downloads[id]?.state = .paused }
        queue.removeAll()
        GOGLog.event("[gog-download] paused for the background count=\(resumeAfterBackground.count)")
    }

    private func resumeFromBackground() {
        let ids = resumeAfterBackground.sorted()
        resumeAfterBackground.removeAll()
        for id in ids { enqueue(id, kind: downloads[id]?.kind ?? .install) }
    }
}
