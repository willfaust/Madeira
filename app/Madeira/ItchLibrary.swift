// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CryptoKit
import Foundation
import UIKit

// The itch.io account's games and their downloads (docs/ITCH.md).
//
// itch.io decides ownership: the list is the account's owned keys (bought and claimed
// games), the games in its collections and the free games added in Madeira (Find a
// game), and a paid game's files are only served for its download key. A game is one
// upload, its Windows file: a .zip unpacks into C:\itch\<folder>, a lone .exe goes
// there as it is, and the game starts as its own program in Wine (the folder's
// .itch.toml action, else its one program). An installer (ItchSetup) runs once in the
// Wine desktop, into that folder; then Play starts the game it installed. itch.io
// games are DRM-free and need no sign-in to start. `env.MADEIRA_ITCH = 0` turns the
// whole thing off.
// Log tags: [itch-library], [itch-download] (game ids, counts and short reason codes;
// never the key or account data).

/// A game Madeira installed: where, which upload and how it starts.
struct ItchInstalledGame: Codable, Sendable {
    var gameID: Int
    var title: String
    /// The install folder, relative to drive_c ("itch/Celeste").
    var folder: String
    var uploadID: Int
    var buildID: Int
    var version: String
    /// The program, relative to the install folder, with "/" separators.
    var launchExe: String
    var arguments: String
    var installBytes: Int64
    /// Set while the download is an installer that has not installed the game yet:
    /// `launchExe` is then ItchSetup's batch file, and Play runs the installer.
    var setup: ItchSetup.Kind? = nil
    /// When the installer was downloaded: a folder it made elsewhere is newer.
    var setupSince: Date? = nil
    var programPath: String { folder + "/" + launchExe }
}

struct ItchDownloadProgress: Equatable, Sendable {
    enum Phase: String, Sendable { case preparing, downloading, unpacking }
    var phase: Phase = .preparing
    var totalBytes: UInt64 = 0
    var doneBytes: UInt64 = 0
    var bytesPerSecond: Double = 0
    var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
}

enum ItchInstallError: LocalizedError {
    case diskSpace(needed: Int64)
    case unsupportedFile(String)
    case noProgram

    var errorDescription: String? {
        switch self {
        case .diskSpace(let needed):
            return "Not enough free space on this device: this download needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) more. Free some space, then try again."
        case .unsupportedFile(let name):
            return "This game comes as \(name), which Madeira cannot unpack yet. Only .zip archives, .exe files and .msi installers install from itch.io for now."
        case .noProgram:
            return "Madeira could not tell which program starts this game. Open its folder in drive_c\\itch and add the game's .exe with + in the library."
        }
    }

    var reason: String {
        switch self {
        case .diskSpace: return "disk-space"
        case .unsupportedFile: return "unsupported-file"
        case .noProgram: return "no-program"
        }
    }
}

/// Installer downloads, the kinds the itch app's installers handle (hush: Inno Setup,
/// NSIS, MSI), found the way it finds them, by the file's own markers. Each runs once,
/// through a batch file in the game's hidden `.madeira-setup` folder, in the Wine
/// desktop with Windows services first, with its unattended switches and the game's
/// own folder as the destination; another installer runs as it is, so the player
/// answers its questions. After the session (or the next start of Madeira), the
/// folder's program, or a new folder of the installer's own, becomes the game.
enum ItchSetup {
    enum Kind: String, Codable, Sendable { case inno, nsis, msi, other }
    static let folderName = ".madeira-setup"
    static let scriptName = "install.bat"
    /// Written by the batch file once the installer has ended.
    static let ranName = "ran"

    /// nil: not an installer (the game itself, or a file Madeira does not know).
    static func kind(fileName: String, head: Data) -> Kind? {
        let name = fileName.lowercased()
        if name.hasSuffix(".msi") || head.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return .msi }
        guard head.starts(with: [0x4D, 0x5A]) else { return nil }
        func has(_ marker: String) -> Bool { head.range(of: Data(marker.utf8)) != nil }
        if has("Inno Setup Setup Data") || has("JR.Inno.Setup") || has("InnoSetupLdrWindow") { return .inno }
        if has("NullsoftInst") || has("Nullsoft.NSIS") { return .nsis }
        let key = name.filter { $0.isLetter || $0.isNumber }
        if (key.contains("setup") || key.contains("install")) && !key.contains("uninst") { return .other }
        return nil
    }

    /// The file's first 8 MB, where installers keep their markers.
    static func kind(of url: URL, fileName: String) -> Kind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return kind(fileName: fileName, head: (try? handle.read(upToCount: 8 << 20)) ?? Data())
    }

    /// C:\-style path of a folder or file relative to drive_c.
    static func windowsPath(_ relative: String) -> String { "C:\\" + relative.replacingOccurrences(of: "/", with: "\\") }

    /// The batch file: the installer, into `target`, waiting until it ends.
    static func script(kind: Kind, installer rawInstaller: String, target rawTarget: String, title: String) -> String {
        // A batch file doubles %; NSIS's unquoted /D= also needs cmd's other specials escaped.
        let installer = rawInstaller.replacingOccurrences(of: "%", with: "%%")
        let target = rawTarget.replacingOccurrences(of: "%", with: "%%")
        let bare = ["^", "&", "|", "<", ">", "(", ")"].reduce(target) { $0.replacingOccurrences(of: $1, with: "^" + $1) }
        let command: String
        switch kind {
        case .inno:
            command = "start \"\" /wait \"\(installer)\" /SP- /SILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL /DIR=\"\(target)\""
        case .nsis:
            // NSIS takes /D= last and unquoted, spaces and all.
            command = "start \"\" /wait \"\(installer)\" /S /D=\(bare)"
        case .msi:
            command = "start \"\" /wait msiexec /i \"\(installer)\" /qb /norestart TARGETDIR=\"\(target)\" INSTALLDIR=\"\(target)\" INSTALLFOLDER=\"\(target)\""
        case .other:
            command = "start \"\" /wait \"\(installer)\""
        }
        let safeTitle = title.filter { $0 != "%" && $0 != "\r" && $0 != "\n" && $0 != "^" && $0 != "&" && $0 != "|" && $0 != "<" && $0 != ">" }
        return ["@echo off", "rem Madeira: the itch.io installer of \(safeTitle), into its own folder (ItchLibrary.swift).", command,
                "echo ran>\"%~dp0\(ranName)\"", ""]
            .joined(separator: "\r\n")
    }

    /// The folder's one installer, relative to it: the hidden setup folder's, else the
    /// only program within two levels that is an installer.
    static func installer(in folder: URL) -> (ItchSetup.Kind, String)? {
        let fm = FileManager.default
        let hidden = folder.appendingPathComponent(ItchSetup.folderName, isDirectory: true)
        var found: [(ItchSetup.Kind, String)] = []
        for name in (try? fm.contentsOfDirectory(atPath: hidden.path)) ?? [] where name.lowercased() != scriptName && name != ranName {
            if let kind = ItchSetup.kind(of: hidden.appendingPathComponent(name), fileName: name) { found.append((kind, ItchSetup.folderName + "/" + name)) }
        }
        if found.isEmpty, let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
            for case let url as URL in walker {
                let relative = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(base.count + 1))
                if relative.split(separator: "/").count > 2 { walker.skipDescendants(); continue }
                let ext = url.pathExtension.lowercased()
                guard ext == "exe" || ext == "msi" else { continue }
                if let kind = ItchSetup.kind(of: url, fileName: url.lastPathComponent) { found.append((kind, relative)) }
            }
        }
        return found.count == 1 ? found[0] : nil
    }

    /// A folder the installer made somewhere else (its own choice of Program Files,
    /// AppData\Local\Programs or C:\): the one named like the game, else the only new
    /// one. Relative to drive_c.
    static func installedElsewhere(drive: URL, title: String, since: Date) -> String? {
        let fm = FileManager.default
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let skip: Set<String> = ["windows", "users", "programdata", "program files", "program files (x86)", "itch", "madeira downloads",
                                 "madeira-games", "common files", "windows nt", "internet explorer", "windows media player",
                                 "windowspowershell", "microsoft", "steam", "gog games", "epic games"]
        var roots = ["Program Files", "Program Files (x86)", ""]
        for user in (try? fm.contentsOfDirectory(atPath: drive.appendingPathComponent("users").path)) ?? [] where !user.hasPrefix(".") {
            roots.append("users/\(user)/AppData/Local/Programs")
        }
        var fresh: [String] = []
        for root in roots {
            let url = root.isEmpty ? drive : drive.appendingPathComponent(root, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey]) else { continue }
            for child in names where !child.lastPathComponent.hasPrefix(".") && !skip.contains(child.lastPathComponent.lowercased())
                && !child.lastPathComponent.lowercased().hasPrefix("madeira") {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
                guard values?.isDirectory == true, let made = values?.creationDate, made >= since.addingTimeInterval(-60) else { continue }
                fresh.append(root.isEmpty ? child.lastPathComponent : root + "/" + child.lastPathComponent)
            }
        }
        let wanted = key(title)
        let named = fresh.filter { let k = key(($0 as NSString).lastPathComponent); return !wanted.isEmpty && (k == wanted || k.contains(wanted) || wanted.contains(k)) && !k.isEmpty }
        if named.count == 1 { return named[0] }
        return fresh.count == 1 ? fresh[0] : nil
    }
}

/// Which program starts an unpacked game.
enum ItchProgram {
    /// Programs that are never the game: uninstallers, crash reporters, redistributables.
    static func helper(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("unins") || n.contains("crashhandler") || n.contains("crashreport") || n.contains("redist")
            || n.hasPrefix("vcredist") || n.hasPrefix("dxsetup") || n.hasPrefix("dxwebsetup") || n.hasPrefix("oalinst")
            || n.contains("setup") || n.hasPrefix("notification_helper") || n == "zsync.exe" || n.hasPrefix("ue4prereq")
            || n.hasPrefix("dotnet") || n.hasPrefix("ndp")
    }

    /// The first [[actions]] path of an .itch.toml manifest (the author's own launch
    /// action), relative to the folder, or nil.
    static func manifestAction(_ text: String) -> String? {
        var inAction = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[[") { inAction = line == "[[actions]]"; continue }
            guard inAction, line.hasPrefix("path"), let eq = line.firstIndex(of: "=") else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // A basic string ("bin\\Game.exe" in the file) has TOML's escapes; a literal one ('...') none.
            if value.hasPrefix("\""), let end = value.dropFirst().firstIndex(of: "\"") {
                value = String(value[value.index(after: value.startIndex)..<end]).replacingOccurrences(of: "\\\\", with: "\\")
            } else if value.hasPrefix("'"), let end = value.dropFirst().firstIndex(of: "'") { value = String(value[value.index(after: value.startIndex)..<end]) }
            let path = value.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard path.lowercased().hasSuffix(".exe"), ItchArchive.safeName(path) == path else { continue }
            return path
        }
        return nil
    }

    /// The program, relative to `folder`: the manifest's action when it names one there,
    /// else the only program (helpers aside) within three folder levels, else the one
    /// named like the game, else the one nearest the top. nil when there is none or
    /// several equally likely.
    static func find(in folder: URL, title: String) -> String? {
        let fm = FileManager.default
        if let text = try? String(contentsOf: folder.appendingPathComponent(".itch.toml"), encoding: .utf8),
           let path = manifestAction(text), fm.fileExists(atPath: folder.appendingPathComponent(path).path) {
            return path
        }
        var programs: [String] = []
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        if let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                let relative = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(base.count + 1))
                if relative.split(separator: "/").count > 4 { walker.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "exe", !helper(url.lastPathComponent) { programs.append(relative) }
            }
        }
        return choose(programs, title: title)
    }

    static func choose(_ programs: [String], title: String) -> String? {
        if programs.count == 1 { return programs[0] }
        guard !programs.isEmpty else { return nil }
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = key(title)
        let named = programs.filter { key(($0 as NSString).lastPathComponent.replacingOccurrences(of: ".exe", with: "", options: .caseInsensitive)) == wanted }
        if named.count == 1 { return named[0] }
        let depth = { (p: String) in p.split(separator: "/").count }
        let top = programs.map(depth).min()!
        let shallow = programs.filter { depth($0) == top }
        return shallow.count == 1 ? shallow[0] : nil
    }
}

/// One file download with pause (resume data) and progress.
final class ItchTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private let destination: URL
    private let resumeFile: URL
    private let progress: @Sendable (UInt64, UInt64) -> Void
    private var moveError: Error?

    init(destination: URL, resumeFile: URL, progress: @escaping @Sendable (UInt64, UInt64) -> Void) {
        self.destination = destination; self.resumeFile = resumeFile; self.progress = progress
    }

    func run(_ request: URLRequest) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                self.session = session
                let task: URLSessionDownloadTask
                if let data = try? Data(contentsOf: resumeFile), !data.isEmpty {
                    task = session.downloadTask(withResumeData: data)
                } else {
                    task = session.downloadTask(with: request)
                }
                self.task = task
                // Paused before the task existed: stop at once (the handler below found no task).
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            // Pause: keep what came so far for the next try.
            task?.cancel(byProducingResumeData: { [resumeFile] data in
                if let data { try? data.write(to: resumeFile, options: .atomic) }
            })
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(UInt64(max(0, totalBytesWritten)), UInt64(max(0, totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { moveError = ItchAPIError.http(status); return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        let resume = (error as? URLError)?.downloadTaskResumeData
        if let resume { try? resume.write(to: resumeFile, options: .atomic) }
        else if error == nil { try? FileManager.default.removeItem(at: resumeFile) }
        let result = error ?? moveError
        continuation?.resume(with: result.map { .failure($0) } ?? .success(()))
        continuation = nil
    }
}

@MainActor final class ItchLibrary: ObservableObject {
    static let shared = ItchLibrary()

    /// Off with `env.MADEIRA_ITCH = 0`.
    static var enabled: Bool { SteamSignIn.flag("MADEIRA_ITCH", default: true) }

    @Published private(set) var signedIn = false
    @Published private(set) var accountName: String?
    /// The library: owned keys, then the account's collections, then the games added
    /// in Madeira; a game appears once, with its key when the account has one.
    @Published private(set) var owned: [ItchOwnedGame] = []
    /// The free games added in Madeira (Find a game).
    @Published private(set) var added: [ItchOwnedGame] = []
    @Published private(set) var installed: [Int: ItchInstalledGame] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var libraryUpdated: Date?
    /// The upload Madeira would install now, per game (its sheet and update check), or why there is none.
    enum Choice: Equatable { case upload(ItchUpload), unavailable(String) }
    @Published private(set) var choices: [Int: Choice] = [:]
    @Published var error: String?

    struct Download: Equatable {
        enum Kind: String { case install, update }
        enum State: Equatable { case queued, active, paused, failed(String) }
        var kind: Kind
        var state: State
        var progress = ItchDownloadProgress()
    }
    @Published private(set) var downloads: [Int: Download] = [:]
    private var queue: [Int] = []
    private var active: (id: Int, task: Task<Void, Never>)?
    private var inSession = false
    private var resumeAfterSession = Set<Int>()
    private var resumeAfterBackground = Set<Int>()
    private var started = false
    private var timer: Timer?
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private let api = ItchAPI.shared

    private init() { loadInstalled() }

    var hasActiveDownload: Bool { downloads.values.contains { $0.state == .active || $0.state == .queued } }
    func game(_ id: Int) -> ItchOwnedGame? { owned.first { $0.id == id } }

    // MARK: Files

    static var drive: URL { LibraryModel.drive }
    static let installRoot = "itch"
    /// A file or folder name safe on Windows and iOS, at most 120 characters.
    nonisolated static func safeName(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = String(text.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return cleaned.isEmpty ? "game" : String(cleaned.prefix(120))
    }
    /// Free bytes on the volume of `url`, or nil when the volume does not say. Some
    /// volumes report zero for the important-usage estimate although they have free
    /// blocks, so the plain capacity is the fallback.
    nonisolated static func freeSpace(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage, plain = values.volumeAvailableCapacity.map(Int64.init)
        if important == nil && plain == nil { return nil }
        return max(important ?? 0, plain ?? 0)
    }
    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Madeira", isDirectory: true)
    }
    private static var cacheURL: URL { support.appendingPathComponent("itch-library.json") }
    private static var installedURL: URL { support.appendingPathComponent("itch-installed.json") }
    /// The free games added in Madeira (Find a game), per account.
    private static var addedURL: URL { support.appendingPathComponent("itch-added.json") }
    private struct Added: Codable { var account: String; var games: [ItchOwnedGame] }
    /// Downloads in progress: the file, and what a pause kept for resuming it.
    private static var downloadsFolder: URL { support.appendingPathComponent("itch-downloads", isDirectory: true) }
    private static func archiveURL(_ id: Int, upload: ItchUpload) -> URL {
        let ext = (upload.filename as NSString).pathExtension.lowercased()
        return downloadsFolder.appendingPathComponent("\(id)-\(upload.id)" + (ext.isEmpty ? "" : "." + ext))
    }
    private static func resumeURL(_ id: Int) -> URL { downloadsFolder.appendingPathComponent("\(id).resume") }
    private struct Cache: Codable { var version: Int; var updated: Date; var account: String; var games: [ItchOwnedGame] }
    private static func accountKey(_ name: String) -> String {
        SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Lifecycle

    /// Called when the library shows the itch.io section; once per app run.
    func start() {
        guard Self.enabled, !started else { return }
        started = true
        finishSetups()
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
            let name = await api.accountName()
            signedIn = await api.signedIn
            accountName = name
            if let name { loadCache(account: name); loadAdded(account: name) }
            ItchLog.event("[itch-library] start signed-in=\(signedIn ? 1 : 0) cached=\(owned.count) installed=\(installed.count)")
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

    private func writeCache() {
        guard let updated = libraryUpdated, let accountName else { return }
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Cache(version: 1, updated: updated, account: Self.accountKey(accountName), games: owned))
            .write(to: Self.cacheURL, options: .atomic)
    }

    private func loadAdded(account: String) {
        guard let data = try? Data(contentsOf: Self.addedURL), data.count <= 8 << 20,
              let list = try? JSONDecoder().decode(Added.self, from: data), list.account == Self.accountKey(account) else { added = []; return }
        added = list.games
        owned = Self.merge(owned, added)
    }

    private func writeAdded() {
        guard let accountName else { return }
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Added(account: Self.accountKey(accountName), games: added)).write(to: Self.addedURL, options: .atomic)
    }

    /// Lists in order of precedence; a game keeps its first appearance (an owned key first).
    static func merge(_ lists: [ItchOwnedGame]...) -> [ItchOwnedGame] {
        var seen = Set<Int>()
        return lists.joined().filter { seen.insert($0.id).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func loadInstalled() {
        guard let data = try? Data(contentsOf: Self.installedURL),
              let records = try? JSONDecoder().decode([Int: ItchInstalledGame].self, from: data) else { return }
        // A record whose program is gone (the folder was deleted in Files) is dropped.
        installed = records.filter { FileManager.default.fileExists(atPath: Self.drive.appendingPathComponent($0.value.programPath).path) }
    }

    private func writeInstalled() {
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(installed).write(to: Self.installedURL, options: .atomic)
    }

    // MARK: Account

    /// An API key from itch.io's Settings › API keys (ItchSettingsSection).
    func signIn(key: String) async throws {
        let name = try await api.signIn(key: key)
        signedIn = true
        accountName = name
        owned = []; libraryUpdated = nil; choices = [:]
        loadAdded(account: name)
        ItchLog.event("[itch-library] signed in")
        await refreshLibrary(interactive: true)
    }

    /// Removes the key and the cached list. Installed games stay and still start:
    /// itch.io games need no sign-in to play, only to download and update.
    func signOut() {
        for id in Array(downloads.keys) { pause(id) }
        Task { await api.signOut() }
        try? FileManager.default.removeItem(at: Self.cacheURL)
        signedIn = false; accountName = nil; owned = []; added = []; libraryUpdated = nil; choices = [:]
        ItchLog.event("[itch-library] signed out")
    }

    private func handle(_ error: Error, context: String, report: Bool) {
        if case ItchAPIError.signedOut = error { signedIn = false; accountName = nil }
        let reason = (error as? ItchAPIError)?.reason ?? (error as? ItchArchiveError)?.reason ?? (error as? ItchInstallError)?.reason
            ?? (error as? URLError).map { "url-\($0.code.rawValue)" } ?? String(describing: type(of: error))
        ItchLog.event("[itch-library] \(context) failed reason=\(reason)")
        if report { self.error = error.localizedDescription }
    }

    // MARK: Library

    func refreshLibrary(interactive: Bool = true) async {
        guard Self.enabled, signedIn, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let bought = try await api.ownedGames()
            // Collections are extra: one that fails leaves the owned games.
            var collected: [ItchOwnedGame] = []
            do { collected = try await api.collectionGames() } catch {
                handle(error, context: "collections", report: false)
            }
            owned = Self.merge(bought, collected, added)
            libraryUpdated = Date()
            writeCache()
            ItchLog.event("[itch-library] owned games=\(bought.count) collections=\(collected.count) added=\(added.count) shown=\(owned.count)")
        } catch {
            handle(error, context: "library", report: interactive)
        }
    }

    // MARK: Finding games

    /// itch.io's search, for Find a game.
    func search(_ query: String) async throws -> [ItchOwnedGame] { try await api.search(query) }

    /// The game a pasted itch.io link names.
    func lookUp(link: String) async throws -> ItchOwnedGame { try await api.game(link: link) }

    /// Whether a pasted text is an itch.io game link.
    nonisolated static func isLink(_ text: String) -> Bool { ItchFormat.dataURL(text) != nil && text.contains(".itch.io") }

    /// Adds a game found in Madeira to the library (this device's list for the account).
    func add(_ game: ItchOwnedGame) {
        guard !owned.contains(where: { $0.id == game.id }) else { return }
        added.append(game)
        writeAdded()
        owned = Self.merge(owned, [game])
        writeCache()
        ItchLog.event("[itch-library] added id=\(game.id) free=\((game.minPrice ?? 0) == 0 ? 1 : 0)")
    }

    /// Takes an added game off the list (one that is not installed).
    func removeAdded(_ id: Int) {
        guard installed[id] == nil, added.contains(where: { $0.id == id }) else { return }
        added.removeAll { $0.id == id }
        writeAdded()
        owned.removeAll { $0.id == id && $0.downloadKeyID == 0 }
        writeCache()
    }

    /// Looks up the upload Madeira would install (the download sheet, the update check).
    func loadChoice(_ id: Int, force: Bool = false) async {
        guard signedIn, force || choices[id] == nil, let game = self.game(id) else { return }
        do {
            let uploads = try await api.uploads(game: id, downloadKey: game.downloadKeyID)
            if let upload = ItchFormat.choose(uploads) { choices[id] = .upload(upload) }
            else { choices[id] = .unavailable(ItchAPIError.noWindowsUpload.localizedDescription) }
        } catch {
            let reason = (error as? ItchAPIError)?.reason ?? (error as? URLError).map { "url-\($0.code.rawValue)" } ?? "error"
            ItchLog.event("[itch-library] uploads id=\(id) failed reason=\(reason)")
            if error is ItchAPIError { choices[id] = .unavailable(error.localizedDescription) }
        }
    }

    func updateAvailable(_ id: Int) -> Bool {
        guard let record = installed[id], case .upload(let upload)? = choices[id] else { return false }
        return upload.id != record.uploadID || upload.buildID != record.buildID || (!upload.version.isEmpty && upload.version != record.version)
    }

    func hasPartialDownload(_ id: Int) -> Bool { FileManager.default.fileExists(atPath: Self.resumeURL(id).path) }

    // MARK: Downloads

    func install(_ id: Int) { enqueue(id, kind: installed[id] == nil ? .install : .update) }

    private func enqueue(_ id: Int, kind: Download.Kind) {
        guard Self.enabled else { return }
        guard signedIn else { error = "Sign in to itch.io to download games."; return }
        if active?.id == id || queue.contains(id) { return }
        if inSession { resumeAfterSession.insert(id); downloads[id] = Download(kind: kind, state: .paused); return }
        var item = downloads[id] ?? Download(kind: kind, state: .queued)
        item.state = .queued
        downloads[id] = item
        queue.append(id)
        startTimer()
        pump()
    }

    func pause(_ id: Int) {
        if let current = active, current.id == id {
            current.task.cancel()
        } else if let index = queue.firstIndex(of: id) {
            queue.remove(at: index)
            downloads[id]?.state = .paused
        }
        resumeAfterSession.remove(id)
    }

    /// Stops a download and deletes what it fetched; an installed game stays as it is.
    func cancel(_ id: Int) {
        let running = active?.id == id ? active?.task : nil
        pause(id)
        downloads[id] = nil
        Task {
            await running?.value
            let fm = FileManager.default
            try? fm.removeItem(at: Self.resumeURL(id))
            for name in (try? fm.contentsOfDirectory(atPath: Self.downloadsFolder.path)) ?? [] where name.hasPrefix("\(id)-") {
                try? fm.removeItem(at: Self.downloadsFolder.appendingPathComponent(name))
            }
            ItchLog.event("[itch-download] cancelled id=\(id) partial-files-removed=1")
        }
    }

    /// Deletes the game's files and its library entry (its per-game settings).
    func uninstall(_ id: Int) {
        guard let record = installed[id], !inSession else { return }
        pause(id); downloads[id] = nil
        installed[id] = nil
        writeInstalled()
        LibraryModel.shared.removeItch(gameID: id)
        let folder = Self.drive.appendingPathComponent(record.folder, isDirectory: true)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
        ItchLog.event("[itch-download] uninstalled id=\(id)")
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

    private func run(_ id: Int) async {
        let kind = downloads[id]?.kind ?? .install
        do {
            guard let game = self.game(id) else { throw ItchAPIError.invalid("unknown-game") }
            downloads[id]?.progress = ItchDownloadProgress(phase: .preparing)
            await loadChoice(id, force: true)
            guard case .upload(let upload)? = choices[id] else { throw ItchAPIError.noWindowsUpload }
            let name = upload.filename.lowercased()
            let isZip = name.hasSuffix(".zip"), isExe = name.hasSuffix(".exe") || name.hasSuffix(".msi")
            // A butler build's download is a .zip of the build whatever the upload's name.
            guard isZip || isExe || upload.buildID != 0 else {
                throw ItchInstallError.unsupportedFile("." + ((upload.filename as NSString).pathExtension.isEmpty ? "unknown" : (upload.filename as NSString).pathExtension))
            }
            let record = installed[id]
            let folder = record?.folder ?? (Self.installRoot + "/" + Self.safeName(game.title))
            let target = Self.drive.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: Self.downloadsFolder, withIntermediateDirectories: true)
            if let free = Self.freeSpace(at: URL.documentsDirectory), upload.size > 0 {
                // The archive, and about as much again unpacked.
                let needed = upload.size * (isExe ? 1 : 3) - free
                if needed > 0 { throw ItchInstallError.diskSpace(needed: needed) }
            }
            ItchLog.event("[itch-download] start id=\(id) kind=\(kind.rawValue) upload=\(upload.id) build=\(upload.buildID) bytes=\(upload.size)")
            let archive = Self.archiveURL(id, upload: upload)
            if !FileManager.default.fileExists(atPath: archive.path) {
                let request = try await api.downloadRequest(upload: upload.id, downloadKey: game.downloadKeyID)
                downloads[id]?.progress = ItchDownloadProgress(phase: .downloading, totalBytes: UInt64(max(0, upload.size)))
                let started = Date()
                let transfer = ItchTransfer(destination: archive, resumeFile: Self.resumeURL(id)) { done, total in
                    Task { @MainActor in
                        guard var item = ItchLibrary.shared.downloads[id] else { return }
                        item.progress.phase = .downloading
                        item.progress.doneBytes = done
                        if total > 0 { item.progress.totalBytes = total }
                        let elapsed = Date().timeIntervalSince(started)
                        if elapsed > 1 { item.progress.bytesPerSecond = Double(done) / elapsed }
                        ItchLibrary.shared.downloads[id] = item
                    }
                }
                try await transfer.run(request)
            }
            try Task.checkCancellation()
            downloads[id]?.progress = ItchDownloadProgress(phase: .unpacking)
            let title = game.title
            let wasSetup = record?.setup != nil
            let installBytes: Int64 = try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if ItchArchive.isZip(archive) {
                    let bytes = try ItchArchive.unpack(archive, to: target) { done, total in
                        Task { @MainActor in
                            ItchLibrary.shared.downloads[id]?.progress = ItchDownloadProgress(phase: .unpacking, totalBytes: total, doneBytes: done)
                        }
                    }
                    try? fm.removeItem(at: archive)
                    return Int64(bytes)
                }
                // A lone program: the game itself, or its installer (ItchSetup), kept in the
                // hidden setup folder so that the game it installs is the folder's program.
                guard isExe else { throw ItchArchiveError.notZip }
                let file = Self.safeName(upload.filename)
                let setup = ItchSetup.kind(of: archive, fileName: file) != nil
                // An update of a game that was installed by its installer replaces only the
                // installer: the installer updates the folder itself.
                let keepGame = setup && record != nil && !wasSetup
                if fm.fileExists(atPath: target.path) && !keepGame { try fm.removeItem(at: target) }
                let place = setup ? target.appendingPathComponent(ItchSetup.folderName, isDirectory: true) : target
                if setup, fm.fileExists(atPath: place.path) { try fm.removeItem(at: place) }
                try fm.createDirectory(at: place, withIntermediateDirectories: true)
                let program = place.appendingPathComponent(file)
                try fm.moveItem(at: archive, to: program)
                return (try? fm.attributesOfItem(atPath: program.path)[.size] as? Int64) ?? upload.size
            }.value
            var finished = ItchInstalledGame(gameID: id, title: title, folder: folder, uploadID: upload.id, buildID: upload.buildID,
                                             version: upload.version, launchExe: "", arguments: "", installBytes: installBytes)
            // A downloaded installer waits in the hidden setup folder (it runs even when an
            // update finds the game it installed before); else the folder's program; else
            // the archive's one installer.
            let downloadedSetup = FileManager.default.fileExists(atPath: target.appendingPathComponent(ItchSetup.folderName).path)
            let program = downloadedSetup ? nil : ItchProgram.find(in: target, title: title)
            if let program {
                finished.launchExe = program
            } else if let found = ItchSetup.installer(in: target) {
                let (kind, installer) = found
                // An installer (alone, or the only one in the archive): Play runs it once.
                let script = target.appendingPathComponent(ItchSetup.folderName + "/" + ItchSetup.scriptName)
                try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(ItchSetup.script(kind: kind, installer: ItchSetup.windowsPath(folder + "/" + installer),
                                          target: ItchSetup.windowsPath(folder), title: title).utf8).write(to: script, options: .atomic)
                finished.launchExe = ItchSetup.folderName + "/" + ItchSetup.scriptName
                finished.setup = kind
                finished.setupSince = Date()
                ItchLog.event("[itch-setup] ready id=\(id) kind=\(kind.rawValue)")
            } else {
                throw ItchInstallError.noProgram
            }
            installed[id] = finished
            writeInstalled()
            downloads[id] = nil
            await LibraryModel.shared.upsertItch(finished, cover: game.cover)
            ItchLog.event("[itch-download] done id=\(id) bytes=\(installBytes)")
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if downloads[id] != nil { downloads[id]?.state = .paused }
                ItchLog.event("[itch-download] paused id=\(id)")
            } else {
                downloads[id]?.state = .failed(error.localizedDescription)
                handle(error, context: "download id=\(id)", report: false)
            }
        }
        active = nil
        pump()
    }

    // MARK: Installers

    /// Installers that ran: the game they installed becomes the program (its own folder,
    /// or the one the installer chose), and the installer goes. One that has not run yet,
    /// or found nothing, stays for Play to run again. After every session and at start.
    func finishSetups() {
        guard !inSession else { return }
        for (id, record) in installed where record.setup != nil {
            let target = Self.drive.appendingPathComponent(record.folder, isDirectory: true)
            // Only once the installer has run (an update's installer finds the old game there).
            guard FileManager.default.fileExists(atPath: target.appendingPathComponent(ItchSetup.folderName + "/" + ItchSetup.ranName).path) else { continue }
            var folder = record.folder
            var program = ItchProgram.find(in: target, title: record.title)
            if program == nil, let since = record.setupSince,
               let other = ItchSetup.installedElsewhere(drive: Self.drive, title: record.title, since: since) {
                program = ItchProgram.find(in: Self.drive.appendingPathComponent(other, isDirectory: true), title: record.title)
                if program != nil { folder = other }
            }
            guard let program else {
                // It ran and installed nothing Madeira can find: Play runs it again.
                try? FileManager.default.removeItem(at: target.appendingPathComponent(ItchSetup.folderName + "/" + ItchSetup.ranName))
                ItchLog.event("[itch-setup] nothing installed id=\(id)")
                continue
            }
            let fm = FileManager.default
            try? fm.removeItem(at: target.appendingPathComponent(ItchSetup.folderName, isDirectory: true))
            if folder != record.folder, ((try? fm.contentsOfDirectory(atPath: target.path)) ?? []).isEmpty { try? fm.removeItem(at: target) }
            var done = record
            done.folder = folder
            done.launchExe = program
            done.setup = nil
            done.setupSince = nil
            installed[id] = done
            writeInstalled()
            let cover = game(id)?.cover, finished = done
            Task { await LibraryModel.shared.upsertItch(finished, cover: cover, setupFinished: true) }
            ItchLog.event("[itch-setup] installed id=\(id) kind=\(record.setup?.rawValue ?? "") own-folder=\(folder == record.folder ? 1 : 0)")
        }
    }

    // MARK: Sessions and the background

    /// A game session is starting or ended: downloads pause for it and continue afterwards. Idempotent.
    func sessionChanged(active running: Bool) {
        guard running != inSession else { return }
        inSession = running
        if running {
            if let current = active { resumeAfterSession.insert(current.id); current.task.cancel() }
            for id in queue { resumeAfterSession.insert(id); downloads[id]?.state = .paused }
            queue.removeAll()
        } else {
            finishSetups()
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

    private func beginGrace() {
        guard hasActiveDownload, grace == .invalid else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "itch.io download") { [weak self] in
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
        ItchLog.event("[itch-download] paused for the background count=\(resumeAfterBackground.count)")
    }

    private func resumeFromBackground() {
        let ids = resumeAfterBackground.sorted()
        resumeAfterBackground.removeAll()
        for id in ids { enqueue(id, kind: downloads[id]?.kind ?? .install) }
    }
}
