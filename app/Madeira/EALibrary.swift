// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CryptoKit
import Foundation
import UIKit

// The EA app's library in Madeira (docs/EA.md): the signed-in account's PC
// games, what is installed, the download queue, and what a game needs to start
// (its licence, the EA app's environment and the local service the game talks
// to). EA's protocol work follows Maxima (GPL-3.0); no Maxima code is included.

/// An installed EA game, as recorded by Madeira.
struct EAInstalledGame: Codable, Sendable {
    var offerID: String
    var title: String
    /// Relative to drive_c, forward slashes: "Program Files/EA Games/Mass Effect".
    var folder: String
    var buildID: String
    var version: String
    /// The id a licence names; empty when neither the catalog nor the build said.
    var contentID: String
    var multiplayerID: String
    /// The program, relative to `folder`, forward slashes.
    var launchExe: String
    var arguments: String
    var installBytes: Int64
    /// The registry key (under HKLM, backslashes) and value the game's manifest named for
    /// its install folder, which Madeira writes so the game finds its files.
    var registryKey: String?
    var registryValue: String?

    var programPath: String { folder + "/" + launchExe }
    var windowsInstallPath: String { "C:\\" + folder.replacingOccurrences(of: "/", with: "\\") }
}

@MainActor final class EALibrary: ObservableObject {
    static let shared = EALibrary()

    /// Off with `env.MADEIRA_EA = 0`.
    static var enabled: Bool { SteamSignIn.flag("MADEIRA_EA", default: true) }

    @Published private(set) var signedIn = false
    @Published private(set) var accountName: String?
    @Published private(set) var owned: [EAOwnedGame] = []
    @Published private(set) var installed: [String: EAInstalledGame] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var libraryUpdated: Date?
    /// The newest build id seen for each installed game (checked when its page opens).
    @Published private(set) var latestBuild: [String: String] = [:]
    /// A game's download and installed size (the live build's archive), or why EA gave none.
    enum Size: Equatable { case known(download: Int64, install: Int64), unavailable(String) }
    @Published private(set) var sizes: [String: Size] = [:]
    @Published var error: String?

    struct Download: Equatable {
        enum Kind: String { case install, update, repair }
        enum State: Equatable { case queued, active, paused, failed(String) }
        var kind: Kind
        var state: State
        var progress = EADownloadProgress()
    }
    @Published private(set) var downloads: [String: Download] = [:]
    private var queue: [String] = []
    private var active: (id: String, task: Task<Void, Never>)?
    private var inSession = false
    private var resumeAfterSession = Set<String>()
    private var resumeAfterBackground = Set<String>()
    private var started = false
    private var timer: Timer?
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private let api = EAAPI.shared
    private let downloader = EADownloader()
    /// The game whose launch Madeira prepared (its environment and service), until the session ends.
    private var launched: String?

    private init() { loadInstalled() }

    var hasActiveDownload: Bool { downloads.values.contains { $0.state == .active || $0.state == .queued } }
    func game(_ id: String) -> EAOwnedGame? { owned.first { $0.id == id } }

    // MARK: Files

    static var drive: URL { LibraryModel.drive }
    static let installRoot = "Program Files/EA Games"
    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Madeira", isDirectory: true)
    }
    private static var cacheURL: URL { support.appendingPathComponent("ea-library.json") }
    private static var installedURL: URL { support.appendingPathComponent("ea-installed.json") }
    /// The installed build's file list, so an update keeps unchanged files without reading them.
    private static func filesURL(_ id: String) -> URL {
        support.appendingPathComponent("ea-manifests", isDirectory: true).appendingPathComponent(safeName(id) + ".json")
    }
    private static func journalURL(_ id: String) -> URL {
        support.appendingPathComponent("ea-downloads", isDirectory: true).appendingPathComponent(safeName(id) + ".journal")
    }
    /// A file or folder name made from EA's text: no separators, no dots at the ends.
    nonisolated static func safeName(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = String(text.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return cleaned.isEmpty ? "game" : String(cleaned.prefix(120))
    }
    private struct Cache: Codable { var version: Int; var updated: Date; var account: String; var games: [EAOwnedGame] }
    private static func accountKey(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Lifecycle

    /// Called when the library shows the EA section; once per app run.
    func start() {
        guard Self.enabled, !started else { return }
        started = true
        if let session = api.account() {
            signedIn = true
            accountName = session.displayName.isEmpty ? nil : session.displayName
            loadCache(account: session.userID)
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginGrace() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endGrace(); self?.resumeFromBackground() }
        }
        if signedIn, owned.isEmpty { Task { await refreshLibrary(interactive: false) } }
    }

    private func loadCache(account: String) {
        guard let data = try? Data(contentsOf: Self.cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == 1, cache.account == Self.accountKey(account) else { return }
        owned = cache.games
        libraryUpdated = cache.updated
    }

    private func writeCache(account: String) {
        let cache = Cache(version: 1, updated: libraryUpdated ?? Date(), account: Self.accountKey(account), games: owned)
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: Self.cacheURL, options: .atomic)
    }

    private func loadInstalled() {
        guard let data = try? Data(contentsOf: Self.installedURL),
              let records = try? JSONDecoder().decode([EAInstalledGame].self, from: data) else { return }
        installed = Dictionary(records.map { ($0.offerID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func writeInstalled() {
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(installed.values.sorted { $0.offerID < $1.offerID }).write(to: Self.installedURL, options: .atomic)
    }

    // MARK: Account

    /// PCI vendor ids of the GPUs Madeira's Wine reports.
    private static let appleVendor: UInt16 = 0x106b, nvidiaVendor: UInt16 = 0x10de

    /// The machine as the sign-in describes it (the device's own GPU, no AVX).
    private func signInProfile() -> EAHardwareProfile {
        EAHardware.profile(drive: Self.drive, gpuVendor: Self.appleVendor, gpuDevice: 0x0001, avx: false)
    }

    /// EA's login page for this device (a fresh challenge each time).
    func loginURL() -> URL { api.loginURL(profile: signInProfile()) }

    /// The code from EA's login page (EASignInView).
    func signIn(code: String) async throws {
        let session = try await api.signIn(authorizationCode: code)
        signedIn = true
        accountName = session.displayName.isEmpty ? nil : session.displayName
        owned = []; libraryUpdated = nil
        await refreshLibrary(interactive: true)
    }

    /// Removes the tokens and the cached list. Installed games stay, but an EA game needs
    /// the sign-in to start: its licence and the EA app's environment come from the account.
    func signOut() {
        for id in Array(downloads.keys) { pause(id) }
        api.signOut()
        try? FileManager.default.removeItem(at: Self.cacheURL)
        signedIn = false; accountName = nil; owned = []; libraryUpdated = nil
    }

    private func handle(_ error: Error, context: String, report: Bool) {
        if case EAAPIError.signedOut = error {
            signedIn = false; accountName = nil
        }
        let reason = (error as? EAAPIError)?.reason ?? (error as? URLError).map { "url-\($0.code.rawValue)" } ?? String(describing: type(of: error))
        EALog.event("[ea-library] \(context) failed reason=\(reason)")
        if report { self.error = error.localizedDescription }
    }

    // MARK: Library

    func refreshLibrary(interactive: Bool = true) async {
        guard Self.enabled, signedIn, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            var games = try await api.ownedGames()
            let known = Dictionary(owned.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // Artwork for games not seen before; at most eight lookups at once.
            let wanted = games.indices.filter { known[games[$0].id]?.cover == nil }
            var art: [String: (URL?, URL?)] = [:]
            await withTaskGroup(of: (String, (URL?, URL?)).self) { group in
                var next = 0
                func add() {
                    guard next < wanted.count else { return }
                    let game = games[wanted[next]]; next += 1
                    group.addTask { [api] in (game.id, await api.images(slug: game.slug)) }
                }
                for _ in 0..<8 { add() }
                while let (id, images) = await group.next() {
                    art[id] = images
                    add()
                }
            }
            for index in games.indices {
                let id = games[index].id
                games[index].cover = art[id]?.0 ?? known[id]?.cover
                games[index].wide = art[id]?.1 ?? known[id]?.wide
            }
            owned = games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            libraryUpdated = Date()
            if let account = api.account() {
                writeCache(account: account.userID)
                if accountName == nil, !account.displayName.isEmpty { accountName = account.displayName }
            }
            EALog.event("[ea-library] owned games=\(owned.count)")
        } catch {
            handle(error, context: "library", report: interactive)
        }
    }

    /// A game's sizes from its live build's archive (the download sheet); once per app run.
    func loadSize(_ id: String) async {
        guard signedIn, sizes[id] == nil else { return }
        do {
            let build = try await api.liveBuild(offerID: id)
            let url = try await api.downloadURL(offerID: id, buildID: build.buildID)
            let archive = try await downloader.archive(url)
            sizes[id] = .known(download: archive.compressedBytes, install: archive.installBytes)
        } catch {
            sizes[id] = .unavailable((error as? EAAPIError)?.errorDescription ?? "EA did not say how large this game is.")
            handle(error, context: "size id=\(id)", report: false)
        }
    }

    /// Notes the newest build (the Game details page shows Update when it differs).
    func checkForUpdate(_ id: String) async {
        guard signedIn, installed[id] != nil, latestBuild[id] == nil else { return }
        if let build = try? await api.liveBuild(offerID: id) { latestBuild[id] = build.buildID }
    }

    func updateAvailable(_ id: String) -> Bool {
        guard let record = installed[id], let latest = latestBuild[id] else { return false }
        return latest != record.buildID
    }

    /// A first install was paused or failed: its journal is on disk.
    func hasPartialDownload(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.journalURL(id).path)
    }

    // MARK: Downloads

    func install(_ id: String) { enqueue(id, kind: installed[id] == nil ? .install : .update) }
    func repair(_ id: String) { enqueue(id, kind: .repair) }

    private func enqueue(_ id: String, kind: Download.Kind) {
        guard signedIn || installed[id] != nil else { error = "Sign in to EA to download games."; return }
        guard signedIn else { error = EAAPIError.signedOut.localizedDescription; return }
        if let current = downloads[id], current.state == .active || current.state == .queued { return }
        downloads[id] = Download(kind: kind, state: .queued)
        if !queue.contains(id) { queue.append(id) }
        startTimer()
        pump()
    }

    /// Stops a download, keeping its finished files; Resume continues from them.
    func pause(_ id: String) {
        if let current = active, current.id == id {
            current.task.cancel()
        } else if let index = queue.firstIndex(of: id) {
            queue.remove(at: index)
            downloads[id]?.state = .paused
        }
        resumeAfterSession.remove(id); resumeAfterBackground.remove(id)
    }

    /// Removes a first install's partial files; stops an update or repair without deleting the game.
    func cancel(_ id: String) {
        pause(id)
        let kind = downloads[id]?.kind ?? .install
        downloads[id] = nil
        let journal = Self.journalURL(id)
        if kind == .install {
            let sidecar = journal.deletingPathExtension().appendingPathExtension("folder")
            if let folder = try? String(contentsOf: sidecar, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty,
               folder.hasPrefix(Self.installRoot + "/") {
                try? FileManager.default.removeItem(at: Self.drive.appendingPathComponent(folder, isDirectory: true))
            }
            try? FileManager.default.removeItem(at: sidecar)
            try? FileManager.default.removeItem(at: journal)
        }
        EALog.event("[ea-download] cancelled id=\(id) kind=\(kind.rawValue)")
    }

    /// Deletes the game's files and records; its library entry goes with them.
    func uninstall(_ id: String) {
        pause(id)
        downloads[id] = nil
        guard let record = installed[id] else { return }
        if record.folder.hasPrefix(Self.installRoot + "/") {
            try? FileManager.default.removeItem(at: Self.drive.appendingPathComponent(record.folder, isDirectory: true))
        }
        try? FileManager.default.removeItem(at: Self.filesURL(id))
        try? FileManager.default.removeItem(at: Self.journalURL(id))
        installed[id] = nil
        writeInstalled()
        LibraryModel.shared.removeEA(offerID: id)
        EALog.event("[ea-library] uninstalled id=\(id)")
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
            let game = self.game(id)
            guard let title = game?.title ?? installed[id]?.title else { throw EAAPIError.invalid("unknown-game") }
            func step(_ text: String) {
                downloads[id]?.progress.step = text
                EALog.event("[ea-download] prepare id=\(id) step=\"\(text)\"")
            }
            step("Finding the newest build")
            let build = try await api.liveBuild(offerID: id)
            step("Getting the download address")
            let url = try await api.downloadURL(offerID: id, buildID: build.buildID)
            step("Reading the build's file list")
            let archive = try await downloader.archive(url)
            let record = installed[id]
            let folder = record?.folder ?? (Self.installRoot + "/" + Self.safeName(game?.installFolder ?? title))
            try? FileManager.default.createDirectory(at: Self.journalURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? folder.write(to: Self.journalURL(id).deletingPathExtension().appendingPathExtension("folder"), atomically: true, encoding: .utf8)
            let previousData = try? Data(contentsOf: Self.filesURL(id))
            let previous = previousData.flatMap { try? JSONDecoder().decode([EAZipEntry].self, from: $0) }
            EALog.event("[ea-download] start id=\(id) kind=\(kind.rawValue) build=\(build.buildID) files=\(archive.files.count) bytes=\(archive.compressedBytes)")
            let result = try await downloader.install(
                archive: archive, folder: Self.drive.appendingPathComponent(folder, isDirectory: true),
                previous: kind == .repair ? nil : previous, verifyAll: kind == .repair, journal: Self.journalURL(id)) { progress in
                    Task { @MainActor in EALibrary.shared.downloads[id]?.progress = progress }
                }
            try? FileManager.default.createDirectory(at: Self.filesURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(archive.entries).write(to: Self.filesURL(id), options: .atomic)
            try? FileManager.default.removeItem(at: Self.journalURL(id).deletingPathExtension().appendingPathExtension("folder"))
            let launch = try Self.launch(folder: Self.drive.appendingPathComponent(folder, isDirectory: true), catalogPath: game?.executePath)
            let finished = EAInstalledGame(
                offerID: id, title: title, folder: folder, buildID: build.buildID, version: launch.version ?? build.version,
                contentID: game?.contentID ?? launch.contentID ?? record?.contentID ?? "", multiplayerID: game?.multiplayerID ?? record?.multiplayerID ?? "",
                launchExe: launch.exe, arguments: launch.arguments, installBytes: result.installBytes,
                registryKey: launch.registryKey, registryValue: launch.registryValue)
            if finished.contentID.isEmpty { EALog.event("[ea-download] id=\(id): no content id (licence requests will not work)") }
            installed[id] = finished
            latestBuild[id] = build.buildID
            writeInstalled()
            downloads[id] = nil
            Self.writeRegistry(finished)
            await LibraryModel.shared.upsertEA(finished, previous: record, cover: game?.cover)
            EALog.event("[ea-download] done id=\(id) written=\(result.filesWritten) kept=\(result.filesKept) fetched=\(result.bytesFetched)")
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if downloads[id] != nil { downloads[id]?.state = .paused }
                EALog.event("[ea-download] paused id=\(id)")
            } else {
                downloads[id]?.state = .failed(error.localizedDescription)
                handle(error, context: "download id=\(id)", report: false)
            }
        }
        active = nil
        pump()
    }

    // MARK: What starts the game

    struct Launch: Equatable {
        var exe: String          // relative to the game's folder, forward slashes
        var arguments: String
        var version: String?
        var contentID: String?
        var registryKey: String?
        var registryValue: String?
    }

    /// How the EA app starts the game: the launcher of `__Installer/installerdata.xml`,
    /// else the catalog's program. A path behind a registry key is taken relative to the
    /// game's folder, and the key is remembered for the registry.
    nonisolated static func launch(folder: URL, catalogPath: String?) throws -> Launch {
        var data: EAInstallerData?
        if let installer = EALicense.child(of: folder, named: "__Installer"), let file = EALicense.child(of: installer, named: "installerdata.xml"),
           let bytes = try? Data(contentsOf: file) {
            data = EAInstallerData.parse(bytes)
        }
        guard let text = data?.launcher?.filePath ?? catalogPath else { throw EAAPIError.noLauncher }
        let path = EARegistryPath(text)
        let relative = path.relative.replacingOccurrences(of: "\\", with: "/")
        guard let parts = EAZipDirectory.safeComponents(relative), !parts.isEmpty else { throw EAAPIError.noLauncher }
        let exe = parts.joined(separator: "/")
        guard EALicense.child(of: parts.dropLast().reduce(folder) { $0.appendingPathComponent($1) }, named: parts.last!) != nil else {
            EALog.event("[ea-library] launcher not found: \(exe)")
            throw EAAPIError.noLauncher
        }
        return Launch(exe: exe, arguments: data?.launcher?.parameters ?? "", version: data?.gameVersion, contentID: data?.contentIDs.first,
                      registryKey: path.key, registryValue: path.valueName)
    }

    /// The registry keys an EA game expects: the EA app's install marker and, when the
    /// game's manifest named one, its own install folder. Only while no session runs.
    nonisolated static func writeRegistry(_ record: EAInstalledGame) {
        guard wine_process_is_running() == 0, wineserver_is_running() == 0 else { return }
        var values = [
            SteamInstallValue(hive: .machine, key: "Software\\Electronic Arts\\EA Desktop", name: "InstallSuccessful", data: .string("true"), followsInstall: false),
            SteamInstallValue(hive: .machine, key: "Software\\Electronic Arts\\Origin", name: "InstallSuccessful", data: .string("true"), followsInstall: false),
            SteamInstallValue(hive: .machine, key: "Software\\Electronic Arts\\Origin", name: "ClientPath",
                              data: .string("C:\\Windows\\System32\\conhost.exe"), followsInstall: false),
        ]
        if let key = record.registryKey, let name = record.registryValue, !key.isEmpty {
            values.append(SteamInstallValue(hive: .machine, key: key, name: name, data: .string(record.windowsInstallPath + "\\"), followsInstall: true))
        }
        do {
            let changed = try SteamInstallRegistry.write(values, prefix: MadeiraDock.prefix)
            EALog.event("[ea-library] registry values=\(values.count) written=\(changed) game-key=\(record.registryKey == nil ? 0 : 1)")
        } catch {
            EALog.event("[ea-library] registry write failed: \(error.localizedDescription)")
        }
    }

    // MARK: Starting a game

    /// The environment the EA app gives a game; cleared before every other launch.
    static let environmentNames = ["EAAuthCode", "EAEgsProxyIpcPort", "EAEntitlementSource", "EAExternalSource", "EAFreeTrialGame", "EAGameLocale",
                                   "EAGenericAuthToken", "EALaunchCode", "EALaunchOwner", "EALaunchEAID", "EALaunchEnv", "EALaunchOfflineMode",
                                   "EALsxPort", "EARtPLaunchCode", "EASecureLaunchTokenTemp", "EASteamProxyIpcPort", "OriginSessionKey", "ContentId",
                                   "EAOnErrorExitRetCode", "EAConnectionId", "EALicenseToken", "EALaunchUserAuthToken", "EAAccessTokenJWS"]

    nonisolated static func clearEnvironment() {
        for name in environmentNames { unsetenv(name) }
    }

    /// Everything an EA game needs before its session starts: a valid sign-in, its
    /// licence for this machine, the registry keys, the EA app's environment and the
    /// local service. Throws with a message for the player when something is missing.
    func prepareLaunch(_ entry: LibraryEntry) async throws {
        guard let id = entry.eaOfferID, let record = installed[id] else { throw EAAPIError.invalid("not-installed") }
        let session: EASession
        do { session = try await api.validSession() } catch {
            handle(error, context: "launch id=\(id)", report: false)
            throw error
        }
        // The GPU Madeira's Wine reports (build/win32u-unix/sysparams_ios.c): the NVIDIA
        // card the game's setting picks, otherwise the device's own.
        let nvidia = LibraryPrefs.nvidia(entry.windowsPath)
        let profile = EAHardware.profile(drive: Self.drive, gpuVendor: nvidia ? Self.nvidiaVendor : Self.appleVendor,
                                         gpuDevice: nvidia ? 0x2544 : 0x0001, avx: LibraryPrefs.avx(entry.windowsPath))
        let folder = Self.drive.appendingPathComponent(record.folder, isDirectory: true)
        let activation = EALicense.activation(gameFolder: folder)
        if activation.required {
            guard !record.contentID.isEmpty else { throw EAAPIError.license("the game's content id is unknown") }
            let (hash, _) = profile.machineHash(version: activation.hashVersion)
            let current = EALicense.current(contentID: record.contentID, drive: Self.drive)
            if EALicense.needsRenewal(current, machineHash: hash, userID: session.userID) {
                _ = try await EALicense.renew(api: api, contentID: record.contentID, profile: profile, activation: activation, drive: Self.drive)
            } else {
                EALog.event("[ea-license] kept content=\(record.contentID) hash-version=\(activation.hashVersion)")
            }
        }
        Self.writeRegistry(record)
        // The short-lived token the EA app hands a game (EALaunchUserAuthToken); a game
        // that never reads it still starts, so a failure here is logged, not fatal.
        var opaque = ""
        do {
            opaque = try await api.exchange(clientID: EAAPI.clientID, responseType: "token",
                                            scopes: ["basic.commerce.cartv2", "service.atom", "dp.client.default", "signin", "social_recommendation_user",
                                                     "basic.optin.write", "basic.commerce.cartv2.write", "basic.billing", "external.social_information_ups_admin"],
                                            tokenFormat: "OPAQUE", expiresIn: 550, profile: profile)
        } catch {
            handle(error, context: "launch token id=\(id)", report: false)
        }
        let launchID = UUID().uuidString.lowercased()
        let environment: [String: String] = [
            "EAAuthCode": "unavailable", "EAEgsProxyIpcPort": "0", "EAEntitlementSource": "EA", "EAExternalSource": "EA", "EAFreeTrialGame": "false",
            "EAGameLocale": "en_US", "EAGenericAuthToken": session.accessToken, "EALaunchCode": "unavailable", "EALaunchOwner": "EA",
            "EALaunchEAID": session.displayName, "EALaunchEnv": "production", "EALaunchOfflineMode": "false", "EALsxPort": String(EAService.port),
            "EARtPLaunchCode": String(EALSXCrypto.launchCode()), "EASecureLaunchTokenTemp": session.userID, "EASteamProxyIpcPort": "0",
            "OriginSessionKey": launchID, "ContentId": record.contentID, "EAOnErrorExitRetCode": "1", "EAConnectionId": id, "EALicenseToken": id,
            "EALaunchUserAuthToken": opaque, "EAAccessTokenJWS": session.accessToken,
        ]
        Self.clearEnvironment()
        for (name, value) in environment { setenv(name, value, 1) }
        try EAService.shared.start(EAServiceContext(
            offerID: id, contentID: record.contentID, title: record.title, version: record.version, multiplayerID: record.multiplayerID,
            userID: session.userID, personaID: session.personaID, displayName: session.displayName, profile: profile, hashVersion: activation.hashVersion))
        launched = id
        startTimer()
        let hasUserToken = !opaque.isEmpty
        EALog.event("[ea-launch] id=\(id) content=\(record.contentID) licence=\(activation.required ? "checked" : "none") token=\(hasUserToken ? 1 : 0)")
    }

    /// The session ended: the service stops and the EA app's environment goes.
    private func launchEnded() {
        guard launched != nil else { return }
        launched = nil
        EAService.shared.stop()
        Self.clearEnvironment()
    }

    // MARK: Sessions

    /// A game session is starting or ended: downloads pause for it and continue afterwards. Idempotent.
    func sessionChanged(active running: Bool) {
        if !running { launchEnded() }
        guard running != inSession else { return }
        inSession = running
        if running {
            if let current = active { resumeAfterSession.insert(current.id); current.task.cancel() }
            for id in queue { resumeAfterSession.insert(id); downloads[id]?.state = .paused }
            queue.removeAll()
            if !resumeAfterSession.isEmpty { EALog.event("[ea-download] paused for a game session count=\(resumeAfterSession.count)") }
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
                if !self.hasActiveDownload, self.launched == nil { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }

    private func beginGrace() {
        guard hasActiveDownload, grace == .invalid else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "EA download") { [weak self] in
            MainActor.assumeIsolated {
                self?.pauseForBackground()
                self?.endGrace()
            }
        }
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    private func pauseForBackground() {
        if let current = active { resumeAfterBackground.insert(current.id); current.task.cancel() }
        for id in queue { resumeAfterBackground.insert(id); downloads[id]?.state = .paused }
        queue.removeAll()
        EALog.event("[ea-download] paused for the background count=\(resumeAfterBackground.count)")
    }

    private func resumeFromBackground() {
        let ids = resumeAfterBackground.sorted()
        resumeAfterBackground.removeAll()
        for id in ids { enqueue(id, kind: downloads[id]?.kind ?? .install) }
    }
}
