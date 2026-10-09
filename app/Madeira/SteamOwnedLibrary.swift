// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// The library and download model is adapted from the account model built
// around Jfishin's Madeira Steam client (used with the author's permission,
// see docs/STEAM_SIGNIN.md, "Provenance"); the integration with sign-in,
// Madeira Dock and the library is 125hz's.

import CryptoKit
import Foundation
import UIKit

// The account's owned Steam games and their downloads (docs/STEAM_LIBRARY.md).
//
// Steam itself decides ownership: the library comes from the account's
// licenses over a Steam connection, and depot keys are only issued for
// depots the account owns. Games download unmodified from Steam's content
// servers into Madeira Dock's Steam library folder (SteamInstall.swift) and
// start through Madeira Dock like any installed game. The only sign-in is
// SteamSignIn's: the connection reads its token from the same Keychain item
// and never stores one of its own. `env.MADEIRA_STEAM_LIBRARY = 0` turns the
// whole thing off (the library then lists installed games only).
// Log tags: [steam-library], [steam-depot], [steam-playtime], [steam-account]
// (App IDs, counts and short reason codes; never account data).

// MARK: - Owned games

struct SteamOwnedGame: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var installDir: String
    var buildID: Int
    /// Store artwork names from PICS (see SteamArtwork); nil in older caches.
    var libraryCapsule: String?
    var libraryHero: String?
    var headerImage: String?
    var parentID: Int?
    /// Steam's launch configuration, for "Start with: The game" (SteamDirectStart);
    /// nil in older caches, which then ask Steam once (SteamOwnedLibrary.launchOptions).
    var launches: [SteamLaunchOption]?

    init(_ info: SteamAppInfo) {
        id = Int(info.appID)
        name = info.name
        installDir = info.installDir
        buildID = Int(info.buildID)
        libraryCapsule = info.libraryCapsule; libraryHero = info.libraryHero; headerImage = info.headerImage
        parentID = info.parentID.map(Int.init)
        launches = info.launches
    }

    var folderName: String { SteamInstallFiles.safeFolderName(installDir.isEmpty ? "app_\(id)" : installDir) }
}

// MARK: - Playtime

/// Steam's own playtime record for one app (Player.GetOwnedGames, the
/// signed-in account's own library through its existing connection): minutes
/// played in total and the last time played (Unix seconds, 0 = never).
struct SteamPlaytime: Codable, Equatable, Sendable {
    var minutes: Int
    var lastPlayed: Int

    var played: String? {
        guard minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes) min played" }
        let hours = Double(minutes) / 60
        return hours < 10 ? String(format: "%.1f hrs played", hours) : "\(Int(hours.rounded())) hrs played"
    }

    func lastPlayedText(formatter: DateFormatter = SteamPlaytime.dayFormatter) -> String? {
        guard lastPlayed > 0 else { return nil }
        return "Last played " + formatter.string(from: Date(timeIntervalSince1970: TimeInterval(lastPlayed)))
    }

    /// "12.5 hrs played · Last played Yesterday"
    var summary: String? {
        let parts = [played, lastPlayedText()].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .none; formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// CPlayer_GetOwnedGames_Response: games = 2 { appid = 1, playtime_forever = 4, rtime_last_played = 11 }.
    static func parse(_ data: Data) throws -> [Int: SteamPlaytime] {
        var decoder = ProtobufDecoder(data)
        var result: [Int: SteamPlaytime] = [:]
        while let tag = try decoder.readTag() {
            guard tag.fieldNumber == 2, tag.wireType == .lengthDelimited else { try decoder.skip(wireType: tag.wireType); continue }
            var game = ProtobufDecoder(try decoder.readBytes())
            var app = 0, minutes = 0, last = 0
            while let field = try game.readTag() {
                switch (field.fieldNumber, field.wireType) {
                case (1, .varint): app = Int(truncatingIfNeeded: Int32(truncatingIfNeeded: try game.readVarint()))
                case (4, .varint): minutes = Int(truncatingIfNeeded: Int32(truncatingIfNeeded: try game.readVarint()))
                case (11, .varint): last = Int(truncatingIfNeeded: UInt32(truncatingIfNeeded: try game.readVarint()))
                default: try game.skip(wireType: field.wireType)
                }
            }
            if app > 0, minutes > 0 || last > 0 { result[app] = SteamPlaytime(minutes: max(0, minutes), lastPlayed: max(0, last)) }
            if result.count > 100_000 { break }
        }
        return result
    }
}

// MARK: - The account between the app and a game session

/// One Steam account, two possible users: the app's own connection (library,
/// playtime, downloads) and Valve's client in a game session, to which Madeira
/// Dock hands the same sign-in. A second logon with the same account replaces
/// the first one's session, so only one may be logged on: the app's connection
/// logs off, and its socket is closed, before Dock writes the one-use sign-in
/// transfer, and it comes back only after the game session ended.
/// Foundation only (check-steam-library.py compiles and runs it).
@MainActor final class SteamConnectionGate {
    private let closeConnection: @MainActor () async -> Void
    private let reopenConnection: @MainActor () -> Void
    /// The app's connection may be used (no game session holds the account).
    private(set) var open = true
    /// Madeira Dock holds the account: from before its sign-in transfer is
    /// written until its session ended (or its start failed).
    private(set) var heldForDock = false
    private var closing: Task<Void, Never>?

    /// `close` logs the app's connection off and returns once its socket is
    /// closed; `reopen` lets it connect again.
    init(close: @escaping @MainActor () async -> Void, reopen: @escaping @MainActor () -> Void) {
        closeConnection = close
        reopenConnection = reopen
    }

    /// A game session starts. Idempotent: the task finishes when the socket is closed.
    @discardableResult func close() -> Task<Void, Never> {
        if let closing { return closing }
        open = false
        let task = Task { await closeConnection() }
        closing = task
        return task
    }

    /// Madeira Dock is about to hand the sign-in to Valve's client: returns only
    /// once the app's connection is logged off and closed. Until `releaseDock()`
    /// the connection stays closed whatever else happens.
    func holdForDock() async {
        heldForDock = true
        await close().value
    }

    /// Madeira Dock's session ended, or its start failed.
    func releaseDock() { heldForDock = false }

    /// The app takes the account back while the game session still runs, to upload
    /// its saves before the app quits. One way: the session's client loses its
    /// logon and the app does not hand the account back.
    func takeOver() async {
        await closing?.value
        open = true
        closing = nil
        reopenConnection()
    }

    /// Lets the app's connection back when no game session runs and Dock does
    /// not hold the account. Returns whether it reopened.
    @discardableResult func reopen(sessionRunning: Bool) -> Bool {
        guard !open, !sessionRunning, !heldForDock else { return false }
        open = true
        closing = nil
        reopenConnection()
        return true
    }
}

// MARK: - Model

@MainActor
final class SteamOwnedLibrary: ObservableObject {
    static let shared = SteamOwnedLibrary()

    /// Off with `env.MADEIRA_STEAM_LIBRARY = 0`, or without Madeira Dock (a
    /// downloaded game starts through it).
    static var enabled: Bool { MadeiraDock.enabled && SteamSignIn.flag("MADEIRA_STEAM_LIBRARY", default: true) }

    @Published private(set) var signedIn = false
    @Published private(set) var owned: [SteamOwnedGame] = []
    @Published private(set) var refreshing = false
    @Published private(set) var libraryUpdated: Date?
    /// Steam's playtime and last played, by App ID.
    @Published private(set) var playtime: [Int: SteamPlaytime] = [:]
    @Published var error: String?

    struct Download: Equatable {
        enum State: Equatable { case queued, active, paused, failed(String) }
        var state: State
        var progress = SteamDownloadProgress()
    }
    @Published private(set) var downloads: [Int: Download] = [:]
    private var queue: [Int] = []
    private var active: (id: Int, task: Task<Void, Never>)?
    /// A game session runs: downloads wait, and the Steam connection stays closed.
    private var inSession = false
    private var resumeAfterSession = Set<Int>()
    /// Downloads paused because iOS ended Madeira's background time.
    private var resumeAfterBackgroundIDs = Set<Int>()

    private let session = SteamSession()
    /// The app's connection is closed while a game session (or Madeira Dock) holds the account.
    private lazy var gate = SteamConnectionGate(close: { [session] in await session.suspend() },
                                                reopen: { [session] in session.resume() })
    private lazy var fetcher = SteamLibraryFetcher(session: session)
    private lazy var downloader = DepotDownloader(session: session)
    private var started = false
    /// Which account the cached list belongs to: a SHA-256 of the account name,
    /// so the cache file holds no name.
    private var cachedAccount: String?
    private static func accountKey(_ name: String?) -> String? {
        name.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }
    private var timer: Timer?

    var hasActiveDownload: Bool { downloads.values.contains { $0.state == .active || $0.state == .queued } }
    func game(_ appID: Int) -> SteamOwnedGame? { owned.first { $0.id == appID } }

    // MARK: Files

    static var drive: URL { MadeiraDock.drive }
    static var steamApps: URL { SteamInstallPaths.steamApps(drive: drive) }
    private static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Madeira", isDirectory: true)
    }
    private static var cacheURL: URL { supportFolder.appendingPathComponent("steam-library.json") }
    private static var playtimeURL: URL { supportFolder.appendingPathComponent("steam-playtime.json") }
    private struct Cache: Codable { var version: Int; var updated: Date; var account: String; var games: [SteamOwnedGame] }

    // MARK: Lifecycle

    /// Called when the library shows the Steam section. Reads the cached list
    /// and refreshes it when it is older than six hours; once per app run.
    func start() {
        guard Self.enabled, !started else { return }
        started = true
        for assigned in SteamStorageModel.shared.catalog.assignments.values where assigned.pending == true {
            var download = Download(state: .paused)
            if let snapshot = assigned.transferProgress {
                download.progress.totalBytes = snapshot.totalBytes
                download.progress.doneBytes = min(snapshot.doneBytes, snapshot.totalBytes)
            }
            downloads[assigned.appID] = download
        }
        NotificationCenter.default.addObserver(forName: SteamSignIn.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.signInChanged() }
        }
        SteamDownloadBackground.shared.attach(self)
        signedIn = SteamSignIn.isSignedIn
        if signedIn { loadCaches() }
        SteamLog.event("[steam-library] start signed-in=\(signedIn ? 1 : 0) cached=\(owned.count)")
        if signedIn { refreshIfStale() }
    }

    private func refreshIfStale() {
        if Date().timeIntervalSince(libraryUpdated ?? .distantPast) > 6 * 3600 {
            Task { await refreshLibrary(interactive: false) }
        } else {
            Task { await refreshPlaytime() }   // playtime changes more often than the library
        }
    }

    /// Sign-in was stored or removed (SteamSignIn.didChange).
    private func signInChanged() {
        let now = SteamSignIn.isSignedIn
        guard now != signedIn || (now && Self.accountKey(SteamSignIn.accountName) != cachedAccount) else { return }
        signedIn = now
        if !now {
            for id in Array(downloads.keys) { pause(id) }
            session.logoff()
            clearCaches()
            owned = []; libraryUpdated = nil; playtime = [:]; downloads = [:]
            SteamLog.event("[steam-library] signed out: list cleared")
        } else {
            owned = []; libraryUpdated = nil; playtime = [:]
            Task { await refreshLibrary(interactive: true) }
        }
    }

    private func loadCaches() {
        let account = Self.accountKey(SteamSignIn.accountName)
        cachedAccount = account
        if let data = try? Data(contentsOf: Self.cacheURL), data.count <= 64 << 20,
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 2, cache.account == account {
            owned = cache.games; libraryUpdated = cache.updated
        }
        if !owned.isEmpty, let data = try? Data(contentsOf: Self.playtimeURL), data.count <= 16 << 20,
           let cached = try? JSONDecoder().decode([Int: SteamPlaytime].self, from: data) {
            playtime = cached
        }
    }

    private func clearCaches() {
        cachedAccount = nil
        DockOffline.clear()   // the offline notes belonged to that account
        try? FileManager.default.removeItem(at: Self.cacheURL)
        try? FileManager.default.removeItem(at: Self.playtimeURL)
    }

    // MARK: Library

    /// `interactive` refreshes (sign-in, the Refresh button) tell the user
    /// about failures; the automatic one only logs transient ones, so an
    /// offline start does not raise an alert.
    func refreshLibrary(interactive: Bool = true) async {
        guard Self.enabled, signedIn, !refreshing, !inSession else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let apps = try await fetcher.fetchOwnedApps()
            let games = apps.filter(\.installableOnWindows).map(SteamOwnedGame.init)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            owned = games
            libraryUpdated = Date()
            cachedAccount = Self.accountKey(SteamSignIn.accountName)
            writeCache()
            SteamLog.event("[steam-library] owned apps=\(apps.count) windows-installable=\(games.count)")
            await refreshPlaytime()
        } catch {
            handleSessionError(error, context: "library", report: interactive)
        }
    }

    private func writeCache() {
        guard let account = cachedAccount, let updated = libraryUpdated else { return }
        try? FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Cache(version: 2, updated: updated, account: account, games: owned))
            .write(to: Self.cacheURL, options: .atomic)
    }

    /// Steam's launch configuration for an owned app, for "Start with: The game"
    /// (SteamDirectStart): from the cached library, else asked of Steam once over the
    /// app's own connection (signed in, no session running) and kept in the cache.
    /// nil when it cannot be had; the Program picker then decides.
    func launchOptions(appID: Int) async -> [SteamLaunchOption]? {
        if let cached = game(appID)?.launches, cached.allSatisfy({ $0.index != nil }) { return cached }
        guard Self.enabled, signedIn, !inSession, appID > 0, appID <= Int(UInt32.max) else { return nil }
        do {
            guard let info = try await fetcher.fetchAppInfo(appID: UInt32(appID)) else { return nil }
            if let index = owned.firstIndex(where: { $0.id == appID }) {
                owned[index].launches = info.launches
                writeCache()
            }
            SteamLog.event("[steam-start] launch configuration app=\(appID) entries=\(info.launches.count)")
            return info.launches
        } catch {
            handleSessionError(error, context: "start", report: false)
            return nil
        }
    }

    private func handleSessionError(_ error: Error, context: String, report: Bool = true) {
        if case SteamError.logonDenied(let code) = error, SteamError.signInExpiredCodes.contains(code) {
            self.error = "Your Steam sign-in is no longer valid. Sign out and sign in again in Settings › Steam."
            SteamLog.event("[steam-account] stored sign-in rejected code=\(code)")
            return
        }
        if report { self.error = SteamSignIn.message(error) }
        SteamLog.event("[steam-\(context)] failed reason=\(Self.reason(error)) reported=\(report ? 1 : 0)")
    }

    // MARK: Playtime

    /// The account's own Player.GetOwnedGames over the existing connection.
    private func requestOwnedGamesPlaytime() async throws -> Data {
        try await session.ensureConnected()
        var request = ProtobufEncoder()
        request.writeUInt64(fieldNumber: 1, value: session.steamID)   // steamid
        request.writeBool(fieldNumber: 2, value: false)                // include_appinfo
        request.writeBool(fieldNumber: 3, value: true)                 // include_played_free_games
        request.writeBool(fieldNumber: 5, value: true)                 // include_free_sub
        return try await session.callServiceMethod(method: .getOwnedGames, body: request.data, timeout: 20)
    }

    func refreshPlaytime() async {
        guard Self.enabled, signedIn, !inSession else { return }
        do {
            let parsed = try SteamPlaytime.parse(try await requestOwnedGamesPlaytime())
            playtime = parsed
            try? FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(parsed).write(to: Self.playtimeURL, options: .atomic)
            SteamLog.event("[steam-playtime] apps=\(parsed.count)")
            await auditCloudSaves()
        } catch {
            SteamLog.event("[steam-playtime] unavailable reason=\(Self.reason(error))")
        }
    }

    // MARK: Steam Cloud (docs/STEAM_CLOUD.md)

    /// Steam Cloud is on unless Settings › Steam Cloud saves turns it off, kept in
    /// madeira.cfg as `env.MADEIRA_STEAM_CLOUD = 0` (SteamCloudSetting). Off: no checks, no section.
    static var cloudEnabled: Bool { enabled && SteamSignIn.flag("MADEIRA_STEAM_CLOUD", default: true) }
    /// `env.MADEIRA_STEAM_CLOUD_AUTO = 0`: compare only; nothing is copied
    /// either way without the user asking on the game's page.
    static var cloudAutomatic: Bool { SteamSignIn.flag("MADEIRA_STEAM_CLOUD_AUTO", default: true) }

    /// Steam Cloud state of the games checked in this app run, by App ID.
    @Published private(set) var cloud: [Int: SteamCloudState] = [:]
    private var cloudAudited = false
    /// Copies of the saves a sync replaced, where the Files app shows them
    /// (Madeira › Steam Cloud Backups): `<game> (<App ID>)/<time>/device/...` for a
    /// device file a download replaced, `.../cloud/...` for a cloud file an upload
    /// replaced (Steam keeps none).
    static var cloudBackupsFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Steam Cloud Backups", isDirectory: true)
    }
    private static func cloudBackup(_ appID: Int) -> URL {
        let name = SteamGamesModel.shared.games.first { $0.id == appID }?.name ?? ""
        let safe = String(name.map { "/\\:*?\"<>|".contains($0) ? "-" : $0 }.prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return cloudBackupsFolder.appendingPathComponent(safe.isEmpty ? "\(appID)" : "\(safe) (\(appID))", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
    }

    // The record of what was last the same on both sides: SHA-1 (hex) by app
    // and file, or a mark (SteamCloudPlan.missingMark). Without it a difference
    // cannot be told from a change, so a file with no record is never copied
    // over the other side unasked.
    private static var cloudBaselineURL: URL { supportFolder.appendingPathComponent("steam-cloud-sync.json") }
    private struct CloudBaseline: Codable { var account: String; var apps: [String: [String: String]] }
    private var cloudBaseline: [String: [String: String]]?

    private func baseline(_ appID: Int) -> [String: String] {
        if cloudBaseline == nil {
            let account = Self.accountKey(SteamSignIn.accountName)
            if let data = try? Data(contentsOf: Self.cloudBaselineURL), data.count <= 16 << 20,
               let stored = try? JSONDecoder().decode(CloudBaseline.self, from: data), stored.account == account {
                cloudBaseline = stored.apps
            } else {
                cloudBaseline = [:]
            }
        }
        return cloudBaseline?["\(appID)"] ?? [:]
    }

    private func recordBaseline(_ appID: Int, settled: [String: String]) {
        guard !settled.isEmpty, let account = Self.accountKey(SteamSignIn.accountName) else { return }
        var files = baseline(appID)
        var changed = false
        for (key, sha) in settled where files[key] != sha { files[key] = sha; changed = true }
        guard changed else { return }
        cloudBaseline?["\(appID)"] = files
        try? FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(CloudBaseline(account: account, apps: cloudBaseline ?? [:]))
            .write(to: Self.cloudBaselineURL, options: .atomic)
    }

    /// Steam Cloud saves was turned on in Settings: sync the installed games now.
    func cloudTurnedOn() {
        objectWillChange.send()
        Task { await auditCloudSaves() }
    }

    /// Once per app run: syncs each installed Steam game, then says which
    /// games have saves that need a choice.
    private func auditCloudSaves() async {
        guard !cloudAudited, !inSession, Self.cloudEnabled else { return }
        cloudAudited = true
        let games = SteamGamesModel.shared.games.filter(\.installed).prefix(40)
        SteamLog.event("[steam-cloud] sync games=\(games.count) automatic=\(Self.cloudAutomatic ? 1 : 0)")
        for game in games {
            guard !inSession else { break }
            await syncCloud(game.id)
        }
    }

    /// App IDs of the games whose saves need the user's choice. The library
    /// says so in its Steam section; an alert would close an open game page.
    var cloudUndecided: [Int] { cloud.filter { !$0.value.conflicts.isEmpty }.keys.sorted() }

    /// What a cloud operation on one game needs: the app's save configuration
    /// and where its folders are in the prefix.
    private func cloudContext(_ appID: Int) async throws -> (info: SteamAppInfo, paths: SteamCloudPaths, access: SteamExternalLease?)? {
        guard appID > 0, appID <= Int(UInt32.max),
              let game = SteamGamesModel.shared.games.first(where: { $0.id == appID }),
              let user = SteamCloudPaths.userFolder(drive: Self.drive) else { return nil }
        let access = try await SteamStorageModel.shared.accessForOperation(libraryID: game.storageID, write: true)
        defer { access?.keepAlive() }
        let root = access?.root ?? Self.drive
        let installFolder = try SteamStoragePath.native(game.library + "/common/" + game.installDir, root: root)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: installFolder.path, isDirectory: &directory), directory.boolValue else {
            throw SteamStorageError.unavailable(.disconnected)
        }
        try await session.ensureConnected()
        let steamID = session.steamID
        guard let info = try await fetcher.fetchAppInfo(appID: UInt32(appID)) else { return nil }
        let drive = Self.drive
        let paths = SteamCloudPaths(
            drive: drive, userFolder: user.url,
            installFolder: installFolder,
            remoteFolder: MadeiraDock.clientRoot.appendingPathComponent("userdata/\(steamID & 0xFFFF_FFFF)/\(appID)/remote", isDirectory: true),
            steamID: steamID, overrides: info.rootOverrides, externalLibraryRoot: access?.root)
        return (info, paths, access)
    }

    private func cloudListing(_ appID: Int) async throws -> SteamCloudListing {
        var request = ProtobufEncoder()
        request.writeUInt32(fieldNumber: 1, value: UInt32(appID))      // appid
        request.writeUInt64(fieldNumber: 2, value: 0)                  // synced_change_number: the whole list
        return try SteamCloudListing.parse(
            try await session.callServiceMethod(method: .cloudGetAppFileChangelist, body: request.data, timeout: 20))
    }

    private var cloudBusy: Set<Int> = []

    /// A failed storage lookup must be checked again after access is restored;
    /// never turn it into a successful audit or clear a real save conflict.
    func storageReconnected(_ libraryID: String) {
        for assignment in SteamStorageModel.shared.catalog.assignments.values where assignment.location.libraryID == libraryID {
            cloud[assignment.appID]?.retryFailedCheck()
        }
    }

    /// Compares the game's cloud saves with the prefix and returns what to do
    /// about the differences. Reads only (it records files found identical).
    @discardableResult
    func checkCloud(_ appID: Int) async -> SteamCloudPlan? {
        guard Self.cloudEnabled, signedIn, !cloudBlocked else { return nil }
        var state = cloud[appID] ?? SteamCloudState()
        state.phase = .checking
        cloud[appID] = state
        do {
            guard let context = try await cloudContext(appID) else {
                state.phase = .failed(Self.cloudNoFolders); cloud[appID] = state; return nil
            }
            defer { context.access?.keepAlive() }
            let listing = try await cloudListing(appID)
            let saveFiles = context.info.saveFiles, paths = context.paths, drive = Self.drive
            let result = try await Task.detached(priority: .utility) { () throws -> (SteamCloudAudit, String?) in
                let audit = try SteamCloudAudit.run(listing: listing, saveFiles: saveFiles, paths: paths)
                // Every cloud file missing and nothing local: the game may keep its saves elsewhere.
                var elsewhere: String?
                if audit.cloudFiles > 0, audit.count(.cloudOnly) == audit.cloudFiles, audit.count(.localOnly) == 0,
                   let first = audit.entries.first {
                    elsewhere = SteamCloudAudit.findElsewhere(cloudPath: first.path, drive: drive) ?? "(not found)"
                }
                return (audit, elsewhere)
            }.value
            try context.access?.validate()
            let audit = result.0
            let plan = SteamCloudPlan.make(audit: audit, baseline: baseline(appID))
            recordBaseline(appID, settled: plan.settled)
            state.audit = audit; state.conflicts = plan.conflicts; state.checked = Date(); state.phase = .ready
            cloud[appID] = state
            let roots = Set(saveFiles.map(\.root)).sorted().joined(separator: ",")
            SteamLog.event("[steam-cloud] app=\(appID) \(audit.summary) patterns=\(saveFiles.count) roots=\(roots.isEmpty ? "-" : roots) overrides=\(context.info.rootOverrides.count) | plan download=\(plan.download.count) upload=\(plan.upload.count) ask=\(plan.conflicts.count)")
            if let elsewhere = result.1 { SteamLog.event("[steam-cloud] app=\(appID) saves-found-elsewhere=\(elsewhere == "(not found)" ? 0 : 1)") }
            return plan
        } catch {
            state.phase = .failed(SteamSignIn.message(error)); cloud[appID] = state
            SteamLog.event("[steam-cloud] app=\(appID) failed reason=\(Self.reason(error))")
            return nil
        }
    }

    /// Compares, then copies what changed on one side only: new and changed
    /// cloud saves come down, new and changed device saves go up. Saves that
    /// need a choice are left for the game's page.
    func syncCloud(_ appID: Int) async {
        guard !cloudBusy.contains(appID) else { return }
        cloudBusy.insert(appID)
        defer { cloudBusy.remove(appID) }
        guard let plan = await checkCloud(appID), Self.cloudAutomatic else { return }
        var changed = false
        if !plan.download.isEmpty { changed = await download(appID, plan.download) || changed }
        if !plan.upload.isEmpty, !inSession { changed = await upload(appID, plan.upload) || changed }
        if changed { await checkCloud(appID) }
    }

    /// The user's choice for the saves that differ: the cloud's replace the
    /// device's (which are backed up first), or the device's replace the cloud's.
    func resolveCloud(_ appID: Int, useCloud: Bool) async {
        guard !cloudBusy.contains(appID), let state = cloud[appID], state.phase == .ready, !state.conflicts.isEmpty else { return }
        cloudBusy.insert(appID)
        defer { cloudBusy.remove(appID) }
        let access: SteamExternalLease?
        do {
            guard let game = SteamGamesModel.shared.games.first(where: { $0.id == appID }) else { return }
            access = try await SteamStorageModel.shared.accessForOperation(libraryID: game.storageID, write: true)
            try access?.validate()
        } catch {
            cloud[appID]?.phase = .failed(error.localizedDescription)
            return
        }
        defer { access?.keepAlive() }
        SteamLog.event("[steam-cloud] app=\(appID) choice=\(useCloud ? "cloud" : "device") files=\(state.conflicts.count)")
        if useCloud {
            _ = await download(appID, state.conflicts)
        } else {
            // A save missing on this device stays missing; the cloud keeps its copy.
            let gone = state.conflicts.filter { $0.kind == .cloudOnly }
            recordBaseline(appID, settled: Dictionary(gone.map { ($0.key, SteamCloudPlan.deletedMark + SteamCloudPlan.hex($0.cloudSHA)) },
                                                      uniquingKeysWith: { a, _ in a }))
            let present = state.conflicts.filter { $0.kind != .cloudOnly }
            if !present.isEmpty { _ = await upload(appID, present) }
        }
        await checkCloud(appID)
    }

    /// Downloads the given cloud files into the prefix. Each is checked
    /// against Steam's checksum before anything is written, and a file it
    /// replaces is backed up first. Returns whether any file arrived.
    private func download(_ appID: Int, _ wanted: [SteamCloudEntry]) async -> Bool {
        guard Self.cloudEnabled, signedIn, !inSession, var state = cloud[appID], !wanted.isEmpty else { return false }
        state.phase = .downloading(done: 0, of: wanted.count); state.problem = nil; cloud[appID] = state
        let backup = Self.cloudBackup(appID).appendingPathComponent("device", isDirectory: true)
        var done = 0, backedUp = 0
        var settled: [String: String] = [:]
        do {
            guard let context = try await cloudContext(appID) else { throw SteamFileError.invalid("This game's save folders could not be found.") }
            defer { context.access?.keepAlive() }
            for entry in wanted {
                guard !inSession else { throw CancellationError() }
                guard let place = context.paths.location(cloudPath: entry.path) else { continue }
                let file = try await cloudFile(appID, entry)
                try context.access?.validate()
                let url = try context.paths.resolve(base: place.base, parts: place.parts)
                let existed = FileManager.default.fileExists(atPath: url.path)
                let label = SteamCloudPaths.split(entry.path).root ?? "remote"
                try SteamCloudTransfer.place(file, at: url, backupTo: backup, relative: [label] + place.parts, time: entry.cloudTime)
                done += 1; if existed { backedUp += 1 }
                settled[entry.key] = SteamCloudPlan.hex(entry.cloudSHA)
                state.phase = .downloading(done: done, of: wanted.count); cloud[appID] = state
            }
            SteamLog.event("[steam-cloud] app=\(appID) downloaded files=\(done) backed-up=\(backedUp)")
        } catch {
            SteamLog.event("[steam-cloud] app=\(appID) download failed after=\(done) reason=\(Self.reason(error))")
            state.problem = "Steam Cloud download stopped: \(SteamSignIn.message(error)) Saves already downloaded are in place; nothing else was changed."
        }
        recordBaseline(appID, settled: settled)
        state.lastDownload = (done, backedUp); state.phase = .ready; cloud[appID] = state
        return done > 0
    }

    /// One cloud file's bytes, checked against the SHA-1 of the comparison:
    /// a file that changed in the cloud since then throws.
    private func cloudFile(_ appID: Int, _ entry: SteamCloudEntry) async throws -> Data {
        var request = ProtobufEncoder()
        request.writeUInt32(fieldNumber: 1, value: UInt32(appID))    // appid
        request.writeString(fieldNumber: 2, value: entry.path)       // filename
        let info = try SteamCloudDownloadInfo.parse(
            try await session.callServiceMethod(method: .cloudClientFileDownload, body: request.data, timeout: 20))
        return try await SteamCloudTransfer.fetch(info, expectedSHA: entry.cloudSHA)
    }

    /// A number Steam uses to tell this device's uploads from other machines'.
    private static var cloudClientID: UInt64 {
        let url = supportFolder.appendingPathComponent("steam-cloud-client-id")
        if let text = try? String(contentsOf: url, encoding: .utf8), let stored = UInt64(text), stored != 0 { return stored }
        let fresh = UInt64.random(in: 1...UInt64(Int64.max))
        try? FileManager.default.createDirectory(at: supportFolder, withIntermediateDirectories: true)
        try? String(fresh).write(to: url, atomically: true, encoding: .utf8)
        return fresh
    }

    /// Uploads the given device saves to Steam Cloud as one batch. Returns
    /// whether Steam accepted any file; the comparison that follows is what
    /// confirms the cloud now holds them.
    private func upload(_ appID: Int, _ wanted: [SteamCloudEntry]) async -> Bool {
        guard Self.cloudEnabled, signedIn, !cloudBlocked, var state = cloud[appID], !wanted.isEmpty else { return false }
        state.phase = .uploading(done: 0, of: wanted.count); state.problem = nil; cloud[appID] = state
        var done = 0
        var batchID: UInt64 = 0
        func complete(_ ok: Bool) async {
            guard batchID != 0 else { return }
            var request = ProtobufEncoder()
            request.writeUInt32(fieldNumber: 1, value: UInt32(appID))        // appid
            request.writeUInt64(fieldNumber: 2, value: batchID)              // batch_id
            request.writeUInt32(fieldNumber: 3, value: ok ? 1 : 2)           // batch_eresult: OK / Fail
            _ = try? await session.callServiceMethod(method: .cloudCompleteAppUploadBatch, body: request.data, timeout: 30)
        }
        do {
            guard let context = try await cloudContext(appID) else { throw SteamFileError.invalid("This game's save folders could not be found.") }
            defer { context.access?.keepAlive() }
            // Steam keeps no copy of a cloud file an upload replaces: keep one here
            // first. If one cannot be fetched (or the cloud changed since the check),
            // nothing is uploaded.
            let replaced = wanted.filter { !$0.cloudSHA.isEmpty }
            if !replaced.isEmpty {
                let backup = Self.cloudBackup(appID).appendingPathComponent("cloud", isDirectory: true)
                for entry in replaced {
                    guard !cloudBlocked else { throw CancellationError() }
                    guard let place = context.paths.location(cloudPath: entry.path) else { continue }
                    let file = try await cloudFile(appID, entry)
                    var target = backup.appendingPathComponent(SteamCloudPaths.split(entry.path).root ?? "remote", isDirectory: true)
                    for part in place.parts { target.appendPathComponent(part) }
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try file.write(to: target, options: .atomic)
                }
                SteamLog.event("[steam-cloud] app=\(appID) cloud copies backed up before upload files=\(replaced.count)")
            }
            var begin = ProtobufEncoder()
            begin.writeUInt32(fieldNumber: 1, value: UInt32(appID))          // appid
            begin.writeString(fieldNumber: 2, value: "Madeira")              // machine_name
            for entry in wanted { begin.writeString(fieldNumber: 3, value: entry.path) }   // files_to_upload
            begin.writeUInt64(fieldNumber: 5, value: Self.cloudClientID)     // client_id
            begin.writeUInt64(fieldNumber: 6, value: UInt64(context.info.buildID))   // app_build_id
            var batch = ProtobufDecoder(try await session.callServiceMethod(method: .cloudBeginAppUploadBatch, body: begin.data, timeout: 30))
            while let tag = try batch.readTag() {
                if tag.fieldNumber == 1, tag.wireType == .varint { batchID = try batch.readVarint() } else { try batch.skip(wireType: tag.wireType) }
            }
            guard batchID != 0 else { throw SteamFileError.invalid("Steam did not open an upload for this game.") }
            for entry in wanted {
                guard !cloudBlocked else { throw CancellationError() }
                guard let place = context.paths.location(cloudPath: entry.path) else { continue }
                try context.access?.validate()
                let url = try context.paths.resolve(base: place.base, parts: place.parts)
                let file = try Data(contentsOf: url)
                guard file.count <= SteamCloudTransfer.maxFileBytes else { throw SteamFileError.invalid("A save is too large to upload.") }
                let sha = Data(Insecure.SHA1.hash(data: file))
                let time = UInt64(max(0, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970))
                var request = ProtobufEncoder()
                request.writeUInt32(fieldNumber: 1, value: UInt32(appID))            // appid
                request.writeUInt32(fieldNumber: 2, value: UInt32(file.count))       // file_size
                request.writeUInt32(fieldNumber: 3, value: UInt32(file.count))       // raw_file_size
                request.writeBytes(fieldNumber: 4, value: sha)                       // file_sha
                request.writeUInt64(fieldNumber: 5, value: time)                     // time_stamp
                request.writeString(fieldNumber: 6, value: entry.path)               // filename
                request.writeUInt32(fieldNumber: 7, value: 0xFFFF_FFFF)              // platforms_to_sync: all
                request.writeUInt32(fieldNumber: 9, value: session.cellID)           // cell_id
                request.writeUInt64(fieldNumber: 13, value: batchID)                 // upload_batch_id
                let answer = try SteamCloudUploadBlock.parse(
                    try await session.callServiceMethod(method: .cloudClientBeginFileUpload, body: request.data, timeout: 30))
                guard !answer.encrypt else { throw SteamFileError.invalid("Steam asked for an encrypted upload, which is not supported.") }
                var sent = true
                var statuses: [Int] = []
                do { statuses = try await SteamCloudTransfer.send(file, blocks: answer.blocks) } catch {
                    sent = false
                    SteamLog.event("[steam-cloud] app=\(appID) upload part failed reason=\(Self.reason(error))")
                }
                var commit = ProtobufEncoder()
                commit.writeBool(fieldNumber: 1, value: sent)                        // transfer_succeeded
                commit.writeUInt32(fieldNumber: 2, value: UInt32(appID))             // appid
                commit.writeBytes(fieldNumber: 3, value: sha)                        // file_sha
                commit.writeString(fieldNumber: 4, value: entry.path)                // filename
                var committed = false
                var reply = ProtobufDecoder(try await session.callServiceMethod(method: .cloudClientCommitFileUpload, body: commit.data, timeout: 30))
                while let tag = try reply.readTag() {
                    if tag.fieldNumber == 1, tag.wireType == .varint { committed = try reply.readVarint() != 0 } else { try reply.skip(wireType: tag.wireType) }
                }
                SteamLog.event("[steam-cloud] app=\(appID) upload file=\(done + 1)/\(wanted.count) bytes=\(file.count) parts=\(answer.blocks.count) http=\(statuses.map(String.init).joined(separator: ",")) committed=\(committed ? 1 : 0)")
                guard sent, committed else { throw SteamFileError.invalid("Steam did not accept a save file.") }
                done += 1
                state.phase = .uploading(done: done, of: wanted.count); cloud[appID] = state
            }
            await complete(true)
            SteamLog.event("[steam-cloud] app=\(appID) uploaded files=\(done) blocks-per-file=steam-decided")
        } catch {
            await complete(false)
            SteamLog.event("[steam-cloud] app=\(appID) upload failed after=\(done) reason=\(Self.reason(error))")
            state.problem = "Steam Cloud upload stopped: \(SteamSignIn.message(error)) This device's saves were not changed."
        }
        state.lastUpload = done; state.phase = .ready; cloud[appID] = state
        return done > 0
    }

    // MARK: Before Play

    private static let cloudNoFolders = "This game's save folders could not be found."

    /// Why a game should not start yet: its saves may not be the latest.
    /// `env.MADEIRA_STEAM_CLOUD_PLAY_CHECK = 0` starts games without asking.
    enum CloudHold: Equatable {
        /// A check or a transfer is running.
        case syncing
        /// Not checked in this app run yet (Play pressed before the start-up sync got
        /// to it), or the last check is older than `cloudFresh`: checked before the
        /// start, without asking.
        case stale
        /// The check or a transfer failed (why).
        case unchecked(String?)
        /// Saves that need the user's choice (count).
        case conflict(Int)
    }
    static var cloudPlayCheck: Bool { cloudEnabled && SteamSignIn.flag("MADEIRA_STEAM_CLOUD_PLAY_CHECK", default: true) }
    private static let cloudFresh: TimeInterval = 600
    /// The game whose saves are being synced before it starts (the library says so).
    @Published private(set) var cloudWaitingFor: Int?

    func cloudHold(_ appID: Int) -> CloudHold? {
        guard Self.cloudPlayCheck, signedIn, !inSession else { return nil }
        if cloudBusy.contains(appID) { return .syncing }
        guard let state = cloud[appID] else { return .stale }
        switch state.phase {
        case .checking, .downloading, .uploading: return .syncing
        // No prefix yet (first start): there is nothing to compare with.
        case .failed(let message): return message == Self.cloudNoFolders ? nil : .unchecked(message)
        case .ready: break
        }
        if let problem = state.problem { return .unchecked(problem) }
        if !state.conflicts.isEmpty { return .conflict(state.conflicts.count) }
        if Date().timeIntervalSince(state.checked ?? .distantPast) > Self.cloudFresh { return .stale }
        return nil
    }

    /// Waits for a running sync, syncs once more, and returns what still holds the start.
    func settleCloud(_ appID: Int) async -> CloudHold? {
        cloudWaitingFor = appID
        defer { cloudWaitingFor = nil }
        for _ in 0..<600 where cloudBusy.contains(appID) { try? await Task.sleep(nanoseconds: 200_000_000) }
        cloud[appID]?.problem = nil      // a transfer that stops again says so again
        await syncCloud(appID)
        let hold = cloudHold(appID)
        SteamLog.event("[steam-cloud] app=\(appID) before-play sync result=\(hold.map { "\($0)" } ?? "clear")")
        return hold == .stale ? nil : hold
    }

    // MARK: Upload and quit

    /// A game cannot be closed from Madeira, so its saves otherwise reach the
    /// cloud only at the next app start. The session menu's "Upload saves and
    /// close Madeira" sends them now: the app takes the account back from the
    /// session's client, uploads what changed on this device, and the app quits.
    /// Nothing is downloaded while the game runs. `env.MADEIRA_STEAM_CLOUD_QUIT = 0`
    /// hides the button.
    static var cloudQuitEnabled: Bool { cloudEnabled && SteamSignIn.flag("MADEIRA_STEAM_CLOUD_QUIT", default: true) }

    enum CloudQuit: Equatable {
        case working(String)
        /// The cloud's copies changed too (count): uploading would replace them.
        case conflict(Int)
        case failed(String)
        /// Uploaded (count) and confirmed; the app may quit.
        case done(Int)
    }
    @Published private(set) var cloudQuit: CloudQuit?
    /// The app holds the account although a session runs (uploadForQuit).
    private var cloudTakeover = false
    private var cloudBlocked: Bool { inSession && !cloudTakeover }

    /// Uploads the running game's changed saves. `replaceCloud` also sends the
    /// saves that changed in the cloud as well, replacing the cloud's copies.
    func uploadForQuit(_ appID: Int, replaceCloud: Bool = false) async {
        guard Self.cloudQuitEnabled, signedIn, !cloudBusy.contains(appID) else { return }
        if case .working = cloudQuit { return }
        cloudBusy.insert(appID)
        defer { cloudBusy.remove(appID) }
        cloudQuit = .working("Connecting to Steam…")
        if !cloudTakeover {
            cloudTakeover = true
            await gate.takeOver()
            SteamLog.event("[steam-cloud] app=\(appID) quit-upload: connection reopened during the session")
        }
        func failure() -> String {
            if case .failed(let message)? = cloud[appID]?.phase { return message }
            return cloud[appID]?.problem ?? "Steam Cloud could not be reached."
        }
        // The game is still running and may be writing: go on once two looks,
        // 2 s apart, find the same device files.
        var plan: SteamCloudPlan?
        var seen: [String: Data] = [:]
        for round in 0..<5 {
            cloudQuit = .working(round == 0 ? "Checking saves…" : "Waiting for the game to finish saving…")
            guard let look = await checkCloud(appID) else {
                SteamLog.event("[steam-cloud] app=\(appID) quit-upload: check failed")
                cloudQuit = .failed(failure()); return
            }
            let now = (look.upload + look.conflicts).reduce(into: [String: Data]()) { $0[$1.key] = $1.localSHA }
            plan = look
            if round > 0, now == seen { break }
            seen = now
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        guard let plan else { cloudQuit = .failed(failure()); return }
        // A save missing on this device has nothing to upload; it waits for its choice.
        let differing = plan.conflicts.filter { $0.kind != .cloudOnly }
        if !differing.isEmpty, !replaceCloud {
            SteamLog.event("[steam-cloud] app=\(appID) quit-upload: held, conflicts=\(differing.count) upload=\(plan.upload.count)")
            cloudQuit = .conflict(differing.count); return
        }
        let wanted = plan.upload + (replaceCloud ? differing : [])
        guard !wanted.isEmpty else {
            SteamLog.event("[steam-cloud] app=\(appID) quit-upload: nothing to upload")
            cloudQuit = .done(0); return
        }
        cloudQuit = .working("Uploading \(wanted.count) save\(wanted.count == 1 ? "" : "s")…")
        _ = await upload(appID, wanted)
        guard cloud[appID]?.problem == nil, cloud[appID]?.lastUpload == wanted.count else {
            cloudQuit = .failed(failure()); return
        }
        // The comparison records the uploaded files as in sync for the next start.
        cloudQuit = .working("Confirming…")
        guard let after = await checkCloud(appID) else { cloudQuit = .failed(failure()); return }
        let sent = Set(wanted.map(\.key))
        let left = (after.upload + after.conflicts).filter { sent.contains($0.key) }.count
        SteamLog.event("[steam-cloud] app=\(appID) quit-upload: uploaded=\(wanted.count) replaced-cloud=\(replaceCloud ? 1 : 0) changed-since=\(left)")
        cloudQuit = .done(wanted.count)
    }

    // MARK: Game sessions

    /// A game session is starting (ContentView starts the Wine session) or ended.
    /// Downloads pause for a session (memory and I/O belong to the game) and
    /// continue afterwards; the app's Steam connection is closed for the whole
    /// session (SteamConnectionGate). Idempotent.
    func sessionChanged(active running: Bool) {
        guard Self.enabled, running != inSession else { return }
        if running {
            inSession = true
            if let current = active {
                resumeAfterSession.insert(current.id)
                current.task.cancel()
            }
            for id in queue { resumeAfterSession.insert(id); downloads[id]?.state = .paused }
            queue.removeAll()
            gate.close()
            SteamLog.event("[steam-depot] paused for a game session count=\(resumeAfterSession.count)")
        } else {
            // Madeira Dock may still hold the account (dockEnded() releases it).
            guard gate.reopen(sessionRunning: false) else { return }
            inSession = false
            let resume = resumeAfterSession.sorted()
            resumeAfterSession.removeAll()
            for id in resume { install(id) }
            if !resume.isEmpty { SteamLog.event("[steam-depot] resumed after a game session count=\(resume.count)") }
            // Steam records the session's playtime when the game ends.
            Task { try? await Task.sleep(nanoseconds: 5_000_000_000); await self.refreshPlaytime() }
        }
    }

    /// Before Madeira Dock writes the one-use sign-in transfer for Valve's
    /// client (ContentView.startDock): downloads stop (the running one is
    /// awaited), and the app's own connection logs off and its socket closes.
    /// Returns when the account is free; the connection stays closed until
    /// `dockEnded()` and the end of the session.
    func prepareDock() async {
        let running = active?.task
        sessionChanged(active: true)
        await running?.value
        await gate.holdForDock()
        SteamLog.event("[steam-library] connection closed for Madeira Dock")
    }

    /// Madeira Dock's session ended, or its start failed (MadeiraDockModel,
    /// ContentView.startDock): the connection comes back once no session runs.
    func dockEnded() {
        guard gate.heldForDock else { return }
        gate.releaseDock()
        reconcileSession()
    }

    /// Whether a Wine session runs in this app run (any interface).
    private var sessionRunning: Bool {
        LibraryModel.shared.current != nil || wine_process_is_running() != 0 || wineserver_is_running() != 0
    }

    /// Compares the app's session state with what downloads assumed. Called
    /// when the section appears, when the app becomes active and every few
    /// seconds while something downloads.
    func reconcileSession() {
        sessionChanged(active: sessionRunning)
    }

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

    // MARK: Background

    /// iOS ended Madeira's background time: pause everything, to continue
    /// when Madeira is active again (SteamDownloadBackground). Finished
    /// chunks are journaled, so nothing is lost.
    func pauseForBackground() {
        if let current = active { resumeAfterBackgroundIDs.insert(current.id); current.task.cancel() }
        for id in queue { resumeAfterBackgroundIDs.insert(id); downloads[id]?.state = .paused }
        queue.removeAll()
        SteamLog.event("[steam-depot] paused for the background count=\(resumeAfterBackgroundIDs.count)")
    }

    func resumeAfterBackground() {
        guard !resumeAfterBackgroundIDs.isEmpty else { return }
        let ids = resumeAfterBackgroundIDs.sorted()
        resumeAfterBackgroundIDs.removeAll()
        for id in ids { install(id) }
        SteamLog.event("[steam-depot] resumed after the background count=\(ids.count)")
    }

    // MARK: Downloads

    /// Whether Steam lists a newer build than the installed record.
    func updateAvailable(appID: Int, installedBuild: Int?) -> Bool {
        guard let installedBuild, let latest = game(appID)?.buildID, latest > 0 else { return false }
        return latest > installedBuild
    }

    func hasPartialDownload(_ appID: Int) -> Bool {
        if let assigned = SteamStorageModel.shared.catalog.assignments[appID] { return assigned.pending == true || !assigned.installed }
        return DepotDownloader.hasPartialDownload(appID: UInt32(appID), steamApps: Self.steamApps)
    }

    /// Installs or updates a game: queues it and starts when nothing else downloads.
    private var removingApps: Set<Int> = []

    func install(_ appID: Int, libraryID: String? = nil) {
        guard !removingApps.contains(appID) else { return }
        guard Self.enabled else { return }
        guard signedIn else { error = "Sign in to Steam to download games."; return }
        if active?.id == appID || queue.contains(appID) { return }
        do {
            let installed = SteamGamesModel.shared.games.first { $0.id == appID }
            let existing = try installed.map { game in
                SteamStorageAssignment(appID: appID,
                    location: try SteamStorageLocation(libraryID: game.storageID,
                        relativePath: game.library + "/common/" + game.installDir),
                    name: game.name, installed: game.installed)
            }
            // Legacy partial downloads belong to the iPad, even if a new choice
            // asks for the SSD. Existing data must never be silently retargeted.
            let legacyPartial = DepotDownloader.hasPartialDownload(appID: UInt32(appID), steamApps: Self.steamApps)
            let selected = legacyPartial ? SteamStorageLibrary.internalID : (libraryID ?? SteamStorageLibrary.internalID)
            guard let owned = game(appID) else { throw SteamStorageError.invalidRecord }
            _ = try SteamStorageModel.shared.assign(appID: appID, name: owned.name, folder: owned.folderName,
                                                    libraryID: selected, existing: existing)
        } catch { self.error = error.localizedDescription; return }
        if inSession {
            resumeAfterSession.insert(appID); downloads[appID] = Download(state: .paused); return
        }
        var item = downloads[appID] ?? Download(state: .queued)
        item.state = .queued
        downloads[appID] = item
        queue.append(appID)
        startTimer()
        pump()
    }

    func pause(_ appID: Int) {
        if let current = active, current.id == appID {
            current.task.cancel()
        } else if let index = queue.firstIndex(of: appID) {
            queue.remove(at: index)
            downloads[appID]?.state = .paused
        }
        resumeAfterSession.remove(appID)
    }

    /// Stops a download. A first-time install also loses its partial files;
    /// an update of an installed game is only paused, never deleted.
    func cancelInstall(_ appID: Int, installed: Bool) {
        guard !removingApps.contains(appID) else { return }
        let running = active?.id == appID ? active?.task : nil
        pause(appID)
        // An interrupted update remains visibly paused as well as persisted;
        // hiding it could make the old manifest look ready to launch.
        if installed { return }
        guard let game = game(appID) else { return }
        removingApps.insert(appID)
        let assigned = SteamStorageModel.shared.catalog.assignments[appID]
        let storageID = assigned?.location.libraryID ?? SteamStorageLibrary.internalID
        let relative = assigned.map { $0.location.relativePath.split(separator: "/").dropLast(2).joined(separator: "/") }
            ?? SteamInstallPaths.libraryRelative
        Task { @MainActor in
            defer { removingApps.remove(appID) }
            await running?.value
            do {
                try await SteamStorageModel.shared.perform(libraryID: storageID, write: true) { root in
                    let apps = try SteamStoragePath.native(relative, root: root)
                    try SteamInstallFiles.delete(appID: appID, folderName: game.folderName, steamApps: apps)
                }
                try SteamStorageModel.shared.removed(appID: appID)
                downloads[appID] = nil
                SteamLog.event("[steam-depot] cancelled app=\(appID) partial-files-removed=1")
            } catch {
                self.error = "The partial download could not be removed. Reconnect its storage and try again."
                downloads[appID] = Download(state: .paused)
            }
        }
    }

    /// Checks an installed game's files against the current Steam build and
    /// downloads what is missing or changed: the downloader compares every chunk
    /// already on disk by its SHA-1 before fetching it.
    func repair(_ appID: Int) {
        SteamLog.event("[steam-repair] app=\(appID) requested=1")
        install(appID)
    }

    /// Removes an install that Madeira's downloads own (its library folder is
    /// Madeira Dock's own), with its library entry (its per-game settings).
    func uninstall(_ game: DockGame) {
        guard SteamInstallPaths.isManaged(library: game.library, storageID: game.storageID), !inSession,
              !removingApps.contains(game.id) else { return }
        let id = game.id, folder = game.installDir
        let running = active?.id == id ? active?.task : nil
        pause(id)
        removingApps.insert(id)
        Task { @MainActor in
            defer { removingApps.remove(id) }
            await running?.value
            do {
                try await SteamStorageModel.shared.perform(libraryID: game.storageID, write: true) { root in
                    let apps = try SteamStoragePath.native(game.library, root: root)
                    try SteamInstallFiles.delete(appID: id, folderName: folder, steamApps: apps)
                }
                try SteamStorageModel.shared.removed(appID: id)
                downloads[id] = nil
                LibraryModel.shared.removeSteam(appID: game.id)
                DockInstallers.setRunsNext(id, true, prefix: MadeiraDock.prefix)
                SteamGamesModel.shared.refresh()
                SteamLog.event("[steam-depot] uninstalled app=\(id)")
            } catch {
                self.error = "The game could not be fully removed. Its library entry has been kept. Reconnect its storage and try again."
            }
        }
    }

    private func pump() {
        guard active == nil, !inSession, !queue.isEmpty else { return }
        let appID = queue.removeFirst()
        downloads[appID]?.state = .active
        SteamDownloadBackground.shared.downloadStarted(appID: appID, name: game(appID)?.name ?? "Steam game")
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(appID)
        }
        active = (appID, task)
    }

    private var progressSavedAt: [Int: Date] = [:]

    private func saveTransferProgress(_ appID: Int, force: Bool = false) {
        guard let progress = downloads[appID]?.progress, progress.totalBytes > 0,
              var assigned = SteamStorageModel.shared.catalog.assignments[appID], assigned.pending == true else { return }
        let now = Date()
        guard force || now.timeIntervalSince(progressSavedAt[appID] ?? .distantPast) >= 5 else { return }
        assigned.transferProgress = SteamStorageTransferProgress(doneBytes: min(progress.doneBytes, progress.totalBytes), totalBytes: progress.totalBytes)
        do {
            try SteamStorageModel.shared.record(assigned)
            progressSavedAt[appID] = now
        } catch {
            // This display snapshot is not the downloader's authoritative journal.
            SteamLog.event("[steam-depot] progress-snapshot-save-failed app=\(appID)")
        }
    }

    private func run(_ appID: Int) async {
        var outcome = SteamDownloadBackground.Outcome.paused
        do {
            guard let info = try await fetcher.fetchInstallInfo(appID: UInt32(appID)) else {
                throw SteamError.appInfoNotFound(UInt32(appID))
            }
            guard var assigned = SteamStorageModel.shared.catalog.assignments[appID] else { throw SteamStorageError.invalidRecord }
            let parts = try SteamStoragePath.components(assigned.location.relativePath)
            let folderName = SteamInstallFiles.safeFolderName(info.installDir.isEmpty ? "app_\(appID)" : info.installDir)
            guard parts.last == folderName, parts.count >= 3, parts[parts.count - 2] == "common" else {
                throw SteamStorageError.invalidRecord
            }
            let relative = parts.dropLast(2).joined(separator: "/")
            let storageID = assigned.location.libraryID
            let bytes = try await SteamStorageModel.shared.perform(libraryID: storageID, write: true) { @MainActor [self] root in
                let apps = try SteamStoragePath.native(relative, root: root)
                _ = try await downloader.install(info, steamApps: apps,
                    ownedDepots: { [weak self] in try? await self?.fetcher.ownedDepotIDs() }) { [weak self] progress in
                        self?.downloads[appID]?.progress = progress
                        self?.saveTransferProgress(appID)
                        SteamDownloadBackground.shared.progress(progress)
                    }
                return SteamInstallFiles.sizeOnDisk(appID: appID, steamApps: apps)
            }
            assigned.installed = true; assigned.buildID = Int(info.buildID); assigned.bytes = bytes; assigned.pending = false
            try SteamStorageModel.shared.record(assigned)
            downloads[appID] = nil
            LibraryModel.shared.upsertSteam(DockGame(id: appID, name: info.name, installDir: folderName,
                library: relative, installed: true, customExecutables: false, storageID: storageID), title: info.name, bytes: bytes)
            SteamLog.event("[steam-depot] library entry app=\(appID)")
            SteamGamesModel.shared.refresh()
            outcome = .completed
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if downloads[appID] != nil { downloads[appID]?.state = .paused }
                SteamLog.event("[steam-depot] paused app=\(appID)")
            } else if case SteamError.logonDenied = error {
                downloads[appID]?.state = .failed(SteamSignIn.message(error))
                handleSessionError(error, context: "depot")
                outcome = .failed(SteamSignIn.message(error))
            } else {
                downloads[appID]?.state = .failed(SteamSignIn.message(error))
                SteamLog.event("[steam-depot] failed app=\(appID) reason=\(Self.reason(error))")
                outcome = .failed(SteamSignIn.message(error))
            }
        }
        saveTransferProgress(appID, force: true)
        progressSavedAt[appID] = nil
        active = nil
        SteamDownloadBackground.shared.downloadEnded(appID: appID, name: game(appID)?.name ?? "Steam game",
                                                     outcome: outcome, queueEmpty: queue.isEmpty)
        pump()
    }

    // MARK: Messages

    /// Short, credential-free reason for the log.
    static func reason(_ error: Error) -> String {
        switch error {
        case SteamError.logonDenied(let code): return "logon-\(code)"
        case SteamError.connectionTimeout: return "timeout"
        case SteamError.depotKeyNotFound: return "depot-key"
        case SteamError.depotNotFound: return "no-windows-depot"
        case SteamError.insufficientDiskSpace: return "disk-space"
        case SteamError.checksumMismatch: return "checksum"
        case SteamError.decompressionFailed: return "decompress"
        case SteamError.chunkDecodeFailed(let format): return "decode-\(format)"
        case SteamError.manifestFetchFailed: return "manifest"
        case SteamError.chunkDownloadFailed: return "chunk"
        case let url as URLError: return "url-\(url.code.rawValue)"
        default: return String(describing: type(of: error))
        }
    }
}
