// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Steam Cloud saves for games in Madeira Dock's Steam library
// (docs/STEAM_CLOUD.md). Written from Steam's published service messages
// (Cloud.GetAppFileChangelist) and the app's `ufs` product info; the same
// model as other open-source Steam clients use.
//
// It asks Steam which save files the account has in the cloud for a game,
// finds the same files in the Wine prefix and compares them, then downloads
// and uploads what changed on one side only. A save that changed on both
// sides, or that differs with no record of an earlier sync, is left alone
// until the user chooses a side. A file a download replaces is copied to a
// backup folder first. Log tag: [steam-cloud] (App IDs, counts, save file
// names under their Steam folder names; never account data or user folder
// names).

import Compression
import CryptoKit
import Foundation

// MARK: - The cloud's file list

/// One file of an app's Steam Cloud, as Cloud.GetAppFileChangelist lists it.
struct SteamCloudFile: Equatable, Sendable {
    /// Folder part, usually starting with a `%Root%` placeholder; may be empty.
    var prefix: String
    var name: String
    var sha: Data
    /// Unix seconds.
    var timestamp: UInt64
    var size: UInt64
    /// persist_state: 0 = present; anything else is a forgotten or deleted file.
    var persistState: UInt32

    var path: String { prefix + name }
}

struct SteamCloudListing: Equatable, Sendable {
    var changeNumber: UInt64 = 0
    var files: [SteamCloudFile] = []

    /// CCloud_GetAppFileChangelist_Response: current_change_number = 1,
    /// files = 2 { file_name = 1, sha_file = 2, time_stamp = 3, raw_file_size = 4,
    /// persist_state = 5, path_prefix_index = 7 }, path_prefixes = 4.
    static func parse(_ data: Data) throws -> SteamCloudListing {
        var decoder = ProtobufDecoder(data)
        var listing = SteamCloudListing()
        var prefixes: [String] = []
        var raw: [(file: SteamCloudFile, prefixIndex: Int?)] = []
        while let tag = try decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, .varint): listing.changeNumber = try decoder.readVarint()
            case (4, .lengthDelimited): prefixes.append(try decoder.readString())
            case (2, .lengthDelimited):
                var sub = ProtobufDecoder(try decoder.readBytes())
                var file = SteamCloudFile(prefix: "", name: "", sha: Data(), timestamp: 0, size: 0, persistState: 0)
                var prefixIndex: Int?
                while let field = try sub.readTag() {
                    switch (field.fieldNumber, field.wireType) {
                    case (1, .lengthDelimited): file.name = try sub.readString()
                    case (2, .lengthDelimited): file.sha = try sub.readBytes()
                    case (3, .varint): file.timestamp = try sub.readVarint()
                    case (4, .varint): file.size = try sub.readVarint()
                    case (5, .varint): file.persistState = UInt32(truncatingIfNeeded: try sub.readVarint())
                    case (7, .varint): prefixIndex = Int(truncatingIfNeeded: try sub.readVarint())
                    default: try sub.skip(wireType: field.wireType)
                    }
                }
                raw.append((file, prefixIndex))
                if raw.count > 20_000 { throw SteamFileError.invalid("Too many Steam Cloud files.") }
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        listing.files = raw.map { entry in
            var file = entry.file
            if let index = entry.prefixIndex, prefixes.indices.contains(index) { file.prefix = prefixes[index] }
            return file
        }
        return listing
    }
}

// MARK: - Where a cloud path lives in the Wine prefix

/// Maps Steam's save folders to folders of Madeira Dock's Wine prefix.
/// Foundation only.
struct SteamCloudPaths: Sendable {
    /// drive_c
    var drive: URL
    /// drive_c/users/<name>
    var userFolder: URL
    /// The game's folder under steamapps/common.
    var installFolder: URL
    /// Steam's own folder for files written through the Steam Cloud API:
    /// userdata/<account>/<app>/remote.
    var remoteFolder: URL
    var steamID: UInt64
    var overrides: [SteamAppInfo.RootOverride]
    /// Present only for an SSD install. Internal Wine user-folder links retain
    /// their existing behaviour; GameInstall saves must stay inside this library.
    var externalLibraryRoot: URL? = nil
    var externalLibraryID: String? = nil

    /// The Windows user folder games write to. A prefix can hold several
    /// folders under users (the template's, earlier builds'). Games find theirs
    /// through the profile the registry names (ProfileList's
    /// ProfileImagePath, from which Wine sets %USERPROFILE%): the prefix
    /// template names C:\users\mythic, while the unix user is "mobile", and
    /// syncing the $USER folder left a game's saves where it never looked. So
    /// the registry's profile first, then $USER, then the passwd name, then the
    /// most recently changed. nil when the prefix has none yet.
    static func userFolder(drive: URL) -> (url: URL, candidates: Int, how: String)? {
        let users = drive.appendingPathComponent("users", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: users.path) else { return nil }
        let own = names.filter { !$0.hasPrefix(".") && $0.caseInsensitiveCompare("Public") != .orderedSame }
        func find(_ name: String?) -> URL? {
            guard let name, let match = own.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
            return users.appendingPathComponent(match, isDirectory: true)
        }
        if let url = find(profileName(prefix: drive.deletingLastPathComponent())) { return (url, own.count, "profile") }
        if let url = find(getenv("USER").map { String(cString: $0) }) { return (url, own.count, "env") }
        if let entry = getpwuid(getuid()), let url = find(String(cString: entry.pointee.pw_name)) { return (url, own.count, "passwd") }
        func changed(_ name: String) -> Date {
            let appData = users.appendingPathComponent(name + "/AppData", isDirectory: true)
            return (try? appData.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        guard let newest = own.max(by: { changed($0) < changed($1) }) else { return nil }
        return (users.appendingPathComponent(newest, isDirectory: true), own.count, "newest")
    }

    /// The folder name under C:\users of the interactive user's profile in the
    /// prefix's system.reg (ProfileList\S-1-5-21-...\ProfileImagePath), or nil.
    static func profileName(prefix: URL) -> String? {
        let url = prefix.appendingPathComponent("system.reg")
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 64 << 20,
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        var inUserProfile = false
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[") {
                inUserProfile = line.lowercased().contains(#"\\profilelist\\s-1-5-21-"#)
                continue
            }
            guard inUserProfile, line.hasPrefix(#""ProfileImagePath"="#) else { continue }
            // "C:\\users\\name" or str(2):"%SystemDrive%\\users\\name"
            guard let open = line.firstIndex(of: "\""),
                  let value = line[line.index(after: open)...].split(separator: "=", maxSplits: 1).last else { continue }
            let path = value.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).replacingOccurrences(of: #"\\"#, with: #"\"#)
            let parts = path.split(separator: "\\")
            guard let index = parts.lastIndex(where: { $0.caseInsensitiveCompare("users") == .orderedSame }),
                  index + 1 < parts.count else { continue }
            let name = String(parts[index + 1])
            return name.isEmpty || name.contains("/") || name == "." || name == ".." ? nil : name
        }
        return nil
    }

    /// The local folder a Steam root name stands for on Windows, or nil for a
    /// root this prefix has no folder for (another platform's).
    func folder(root: String) -> URL? {
        switch root.lowercased() {
        case "gameinstall": return installFolder
        case "winmydocuments": return userFolder.appendingPathComponent("Documents", isDirectory: true)
        case "winappdatalocal": return userFolder.appendingPathComponent("AppData/Local", isDirectory: true)
        case "winappdatalocallow": return userFolder.appendingPathComponent("AppData/LocalLow", isDirectory: true)
        case "winappdataroaming": return userFolder.appendingPathComponent("AppData/Roaming", isDirectory: true)
        case "winsavedgames": return userFolder.appendingPathComponent("Saved Games", isDirectory: true)
        default: return nil
        }
    }

    /// Steam's own spelling of a root name (product info is not consistent about case).
    static func canonical(root: String) -> String {
        ["GameInstall", "WinMyDocuments", "WinAppDataLocal", "WinAppDataLocalLow", "WinAppDataRoaming", "WinSavedGames"]
            .first { $0.caseInsensitiveCompare(root) == .orderedSame } ?? root
    }

    /// Splits "%Root%rest" into its root name and the rest; no placeholder
    /// gives a nil root (Steam's `remote` folder).
    static func split(_ path: String) -> (root: String?, rest: String) {
        guard path.hasPrefix("%"), let end = path.dropFirst().firstIndex(of: "%") else { return (nil, path) }
        let root = String(path[path.index(after: path.startIndex)..<end])
        return (root, String(path[path.index(after: end)...]))
    }

    /// The path components of a relative save path, or nil when it is not a
    /// plain relative path (empty, absolute, or leaving its folder).
    func components(_ relative: String) -> [String]? {
        // Placeholders match in any case (Sifu writes {64bitsteamid}), and a "." part is
        // dropped rather than refusing the path (100% Orange Juice ends its path in "/.").
        let text = relative.replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "{64BitSteamID}", with: String(steamID), options: .caseInsensitive)
            .replacingOccurrences(of: "{Steam3AccountID}", with: String(steamID & 0xFFFF_FFFF), options: .caseInsensitive)
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !parts.isEmpty, parts.count <= 32,
              !parts.contains(where: { $0 == ".." || $0.contains(":") || $0.utf8.count > 255 }) else { return nil }
        return parts
    }

    /// The base folder and relative components a cloud path maps to, with the
    /// Windows root override applied. nil: no folder here, or an unsafe path.
    func location(cloudPath: String) -> (base: URL, parts: [String])? {
        var (root, rest) = Self.split(cloudPath)
        if let name = root,
           let override = overrides.first(where: { $0.root.caseInsensitiveCompare(name) == .orderedSame
                                                   && $0.os.caseInsensitiveCompare("Windows") == .orderedSame }) {
            if !override.useInstead.isEmpty { root = override.useInstead }
            if !override.addPath.isEmpty { rest = override.addPath + "/" + rest }
        }
        guard let parts = components(rest) else { return nil }
        if let root {
            guard let base = folder(root: root) else { return nil }
            return (base, parts)
        }
        return (remoteFolder, parts)
    }

    /// Wine treats names without regard to case and iOS does not: follow the
    /// components by case-insensitive match, falling back to the given
    /// spelling for the part that does not exist yet.
    func resolve(base: URL, parts: [String]) throws -> URL {
        var url = try validateInstallURL(base)
        for (index, part) in parts.enumerated() {
            let exact = try validateInstallURL(url.appendingPathComponent(part, isDirectory: index < parts.count - 1))
            if FileManager.default.fileExists(atPath: exact.path) { url = exact; continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if let match = names.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                url = try validateInstallURL(url.appendingPathComponent(match, isDirectory: index < parts.count - 1))
            } else {
                url = exact
            }
        }
        return url
    }

    /// Check lexical components before following them, including dangling links.
    /// Enumeration also calls this before inspecting a local-only save.
    func validateInstallURL(_ url: URL) throws -> URL {
        guard let externalLibraryRoot else { return url }
        guard try externalLibraryRoot.checkResourceIsReachable() else { throw ExternalStorageError.unavailable }
        if let externalLibraryID { try ExternalStorageIdentity.verify(externalLibraryID, root: externalLibraryRoot) }
        let path = url.standardizedFileURL.path
        let install = installFolder.standardizedFileURL.path
        guard path == install || path.hasPrefix(install + "/") else { return url }
        let root = externalLibraryRoot.resolvingSymlinksInPath().standardizedFileURL
        guard path.hasPrefix(root.path + "/") else { throw ExternalStorageError.unsafePath }
        return try ExternalStoragePath.native(String(path.dropFirst(root.path.count + 1)), root: root)
    }
}

// MARK: - One Windows profile per prefix

/// madeira-bcd: the prefix template names its Windows profile C:\users\mythic
/// (ProfileList's ProfileImagePath, Volatile Environment, shell folders), but
/// Wine names the account after the unix user, "mobile" on a device. A game
/// started with the session's environment then writes under mythic, while a
/// game Valve's client starts in a Madeira Dock session gets an environment
/// block built from the account name (userenv: profiles folder + "mobile") and
/// writes under mobile: The Adventures of Elliot kept its saves under mobile
/// while Steam Cloud put the cloud's saves under mythic. The profile is now the
/// unix user's everywhere: the registry's paths are rewritten to it and the
/// template profile's files are copied into it, once, before Wine starts (run
/// from MadeiraApp.init; the wineserver rewrites the .reg files from memory, so
/// it must not be running).
///
/// A file present in both folders keeps the newer copy; the other is copied to
/// Files › Madeira › Profile Merge Backups. After such a collision the Steam
/// Cloud record is dropped, so a save that now differs from the cloud is shown
/// as a choice instead of being uploaded or downloaded unasked.
enum ProfileUnification {
    private static var ran = false

    static func run() {
        guard !ran else { return }
        ran = true
        let fm = FileManager.default
        let prefix = MadeiraDock.prefix
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        guard let user = unixUser(), let old = SteamCloudPaths.profileName(prefix: prefix),
              old.caseInsensitiveCompare(user) != .orderedSame else { return }

        let source = users.appendingPathComponent(old, isDirectory: true)
        let target = users.appendingPathComponent(user, isDirectory: true)
        var moved = 0, collisions = 0
        let backup = prefix.deletingLastPathComponent()
            .appendingPathComponent("Profile Merge Backups/\(UUID().uuidString)", isDirectory: true)
        do {
            // Invalidate the old sync record before any save can change.
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Madeira/steam-cloud-sync.json")
            if fm.fileExists(atPath: support.path) { try fm.removeItem(at: support) }
            if fm.fileExists(atPath: source.path) {
                let sourceType = try fm.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType
                let targetType = (try? fm.attributesOfItem(atPath: target.path)[.type]) as? FileAttributeType
                guard sourceType == .typeDirectory, targetType == nil || targetType == .typeDirectory
                else { throw CocoaError(.fileWriteInvalidFileName) }
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try merge(source, into: target, backup: backup, depth: 24, moved: &moved, collisions: &collisions)
            }
        } catch {
            LogStore.shared.log("[profile] could not copy the profile; old files and registry paths are kept: \(error)", level: .error)
            return
        }
        // Keep the old profile as a recovery copy, including after a partial registry write.
        var rewritten = 0
        for name in ["system.reg", "user.reg", "userdef.reg"] {
            let url = prefix.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            guard let hits = rewrite(url, from: old, to: user) else {
                LogStore.shared.log("[profile] could not rewrite \(name); both profile copies are kept", level: .error)
                return
            }
            rewritten += hits
        }
        if collisions > 0 {
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Madeira/steam-cloud-sync.json")
            try? fm.removeItem(at: support)
        }
        LogStore.shared.log("[profile] one Windows profile: \(rewritten) registry path(s) now name the unix user's folder; "
            + "\(moved) item(s) copied from the template profile, \(collisions) collision(s) kept newer"
            + (collisions > 0 ? " (older copies in Files › Madeira › Profile Merge Backups; Steam Cloud record reset)" : ""),
            level: .success)
    }

    /// The account name Wine uses (ntdll's set_home_dir): $USER, else the passwd name.
    private static func unixUser() -> String? {
        var name = getenv("USER").map { String(cString: $0) } ?? ""
        if name.isEmpty, let entry = getpwuid(getuid()) { name = String(cString: entry.pointee.pw_name) }
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) { name = String(name[name.index(after: slash)...]) }
        return name.isEmpty || name == "." || name == ".." ? nil : name
    }

    /// `users\\<old>` followed by `\\` or `"` becomes `users\\<new>` (.reg text,
    /// backslashes doubled), without regard to case. Written via a temporary file;
    /// nil when the file cannot be read or written.
    private static func rewrite(_ url: URL, from old: String, to new: String) -> Int? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 64 << 20,
              let read = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Volatile Environment's USERNAME names the profile's user too.
        let text = read.replacingOccurrences(of: #""USERNAME"=""# + old + "\"",
                                             with: #""USERNAME"=""# + new + "\"", options: .caseInsensitive)
        let needle = #"users\\"# + old
        var out = "", hits = 0
        var rest = text[...]
        while let range = rest.range(of: needle, options: .caseInsensitive) {
            let after = rest[range.upperBound...]
            out += rest[..<range.lowerBound]
            if after.hasPrefix(#"\\"#) || after.hasPrefix("\"") {
                out += #"users\\"# + new
                hits += 1
            } else {
                out += rest[range]
            }
            rest = after
        }
        guard hits > 0 || text != read else { return 0 }
        out += rest
        do { try out.write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return hits
    }

    /// Copies saves before changing registry paths. The old profile stays as a recovery copy.
    private static func merge(_ source: URL, into target: URL, backup: URL, depth: Int,
                              moved: inout Int, collisions: inout Int) throws {
        let fm = FileManager.default
        guard depth > 0 else { throw CocoaError(.fileReadTooLarge) }
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            let from = source.appendingPathComponent(name), to = target.appendingPathComponent(name)
            let fromType = try fm.attributesOfItem(atPath: from.path)[.type] as? FileAttributeType
            let toType = (try? fm.attributesOfItem(atPath: to.path)[.type]) as? FileAttributeType
            guard let toType else {
                try fm.copyItem(at: from, to: to)
                moved += 1
                continue
            }
            if fromType == .typeDirectory && toType == .typeDirectory {
                try merge(from, into: to, backup: backup.appendingPathComponent(name, isDirectory: true), depth: depth - 1,
                          moved: &moved, collisions: &collisions)
                continue
            }
            // Do not follow Windows junctions or symbolic links into another tree.
            guard fromType != .typeSymbolicLink && toType != .typeSymbolicLink else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            collisions += 1
            func date(_ url: URL) throws -> Date {
                try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            }
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            let saved = backup.appendingPathComponent(name)
            if try date(from) > date(to) {
                try fm.copyItem(at: to, to: saved)
                try fm.removeItem(at: to)
                do { try fm.copyItem(at: from, to: to) }
                catch {
                    if fm.fileExists(atPath: to.path) { try? fm.removeItem(at: to) }
                    try fm.copyItem(at: saved, to: to)
                    throw error
                }
                moved += 1
            } else {
                try fm.copyItem(at: from, to: saved)
            }
        }
    }

}

// MARK: - Comparison

/// One save file, on either side or both.
struct SteamCloudEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case same, differ, cloudOnly, localOnly }
    /// The cloud path with its %Root% placeholder (for a local-only file, the
    /// path it would have).
    var path: String
    var kind: Kind
    var cloudSize: UInt64 = 0
    var cloudTime: UInt64 = 0
    var localSize: UInt64 = 0
    var localTime: UInt64 = 0
    var cloudSHA = Data()
    var localSHA = Data()

    var id: String { path }
    /// Baseline key: one spelling per file.
    var key: String { path.lowercased() }
    /// The file name without its folders, for display.
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// How one app's cloud and local save files compare.
struct SteamCloudAudit: Equatable, Sendable {
    var changeNumber: UInt64 = 0
    var cloudFiles = 0
    var entries: [SteamCloudEntry] = []
    /// Cloud paths under a root this prefix has no folder for.
    var unmapped: [String] = []

    func count(_ kind: SteamCloudEntry.Kind) -> Int { entries.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) } }
    func paths(_ kind: SteamCloudEntry.Kind) -> [String] { entries.filter { $0.kind == kind }.map(\.path) }

    static func sha1(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil  // A partial digest is not a checksum of this save.
        }
        return Data(hasher.finalize())
    }

    private static func attributes(_ url: URL) -> (size: UInt64, time: UInt64)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return (UInt64(max(0, values.fileSize ?? 0)), UInt64(max(0, values.contentModificationDate?.timeIntervalSince1970 ?? 0)))
    }

    /// One spelling per file, whatever route led to it and whatever its case.
    private static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().path.lowercased() }

    /// Compares the listing with the prefix. Reads files; changes nothing.
    static func run(listing: SteamCloudListing, saveFiles: [SteamAppInfo.SaveFile], paths: SteamCloudPaths) throws -> SteamCloudAudit {
        _ = try paths.validateInstallURL(paths.installFolder)
        var audit = SteamCloudAudit()
        audit.changeNumber = listing.changeNumber
        var known = Set<String>()   // local paths the cloud lists
        for file in listing.files where file.persistState == 0 {
            audit.cloudFiles += 1
            guard let place = paths.location(cloudPath: file.path) else { audit.unmapped.append(file.path); continue }
            let url = try paths.resolve(base: place.base, parts: place.parts)
            known.insert(key(url))
            var entry = SteamCloudEntry(path: file.path, kind: .cloudOnly, cloudSize: file.size, cloudTime: file.timestamp, cloudSHA: file.sha)
            if let local = attributes(url) {
                entry.localSize = local.size; entry.localTime = local.time
                entry.localSHA = sha1(of: url) ?? Data()
                entry.kind = (local.size == file.size && entry.localSHA == file.sha) ? .same : .differ
            }
            audit.entries.append(entry)
        }
        // Local files the game's save patterns cover that the cloud does not list.
        var folders: [(label: String, url: URL, pattern: String, recursive: Bool)] = []
        // "all" is how many games list every platform (Psychonauts, Dark Souls: Prepare
        // to Die Edition); dropping it left their local saves never offered for upload.
        for save in saveFiles where save.platforms.isEmpty || save.platforms.contains("windows")
                                     || save.platforms.contains("all") {
            guard let place = paths.location(cloudPath: "%\(save.root)%" + (save.path.isEmpty ? "x" : save.path + "/x")) else { continue }
            let folder = try paths.resolve(base: place.base, parts: Array(place.parts.dropLast()))
            // A Windows override moves the folder: its cloud name is not this one, so
            // files found there are not offered for upload.
            if paths.overrides.contains(where: { $0.root.caseInsensitiveCompare(save.root) == .orderedSame
                                                 && $0.os.caseInsensitiveCompare("Windows") == .orderedSame }) { continue }
            // The cloud name has the account IDs filled in ({64BitSteamID} and
            // {Steam3AccountID}), as the device folder does: Steam does not commit
            // an upload named with the placeholder itself.
            let folderPath = save.path.isEmpty ? "" : (paths.components(save.path)?.joined(separator: "/") ?? save.path) + "/"
            let label = "%\(SteamCloudPaths.canonical(root: save.root))%" + folderPath
            folders.append((label, folder, save.pattern.isEmpty ? "*" : save.pattern, save.recursive))
        }
        folders.append(("", paths.remoteFolder, "*", true))
        var seen = Set<String>()
        for folder in folders {
            let options: FileManager.DirectoryEnumerationOptions = folder.recursive ? [] : [.skipsSubdirectoryDescendants]
            guard let walk = FileManager.default.enumerator(at: folder.url, includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: options) else { continue }
            let base = folder.url.resolvingSymlinksInPath().path
            var visited = 0
            for case let url as URL in walk {
                visited += 1
                if visited > 5_000 { break }
                _ = try paths.validateInstallURL(url)
                guard fnmatch(folder.pattern, url.lastPathComponent, FNM_CASEFOLD) == 0, let local = attributes(url) else { continue }
                let fileKey = key(url)
                guard !known.contains(fileKey), seen.insert(fileKey).inserted else { continue }
                // Both resolved: the enumerator may spell the same folder differently (/private/var).
                let relative = url.resolvingSymlinksInPath().path.dropFirst(base.count).drop { $0 == "/" }
                audit.entries.append(SteamCloudEntry(path: folder.label + String(relative), kind: .localOnly,
                                                     localSize: local.size, localTime: local.time,
                                                     localSHA: sha1(of: url) ?? Data()))
            }
        }
        return audit
    }

    /// Where saves the cloud lists, and this prefix lacks, might really be: the
    /// first file of that name, or folder named like the saves' folder, under
    /// any user folder, as a path relative to `users` with the user folder's
    /// name left out. Diagnostic for a game that keeps its saves somewhere Steam
    /// does not say.
    static func findElsewhere(cloudPath: String, drive: URL) -> String? {
        let parts = SteamCloudPaths.split(cloudPath).rest.split(separator: "/").map(String.init)
        guard let name = parts.last else { return nil }
        let folderName = parts.count >= 2 ? parts[parts.count - 2] : nil
        let users = drive.appendingPathComponent("users", isDirectory: true)
        let userNames = ((try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []).sorted()
        for (index, user) in userNames.enumerated() {
            let root = users.appendingPathComponent(user, isDirectory: true)
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            let base = root.resolvingSymlinksInPath().path
            var visited = 0
            for case let url as URL in walk {
                visited += 1
                if visited > 60_000 { break }
                if walk.level > 8 { walk.skipDescendants(); continue }
                let last = url.lastPathComponent
                // Browser caches and the like: large, and never where a game saves.
                if last == "htmlcache" || last == "Temp" || last == "INetCache" { walk.skipDescendants(); continue }
                if last.caseInsensitiveCompare(name) == .orderedSame
                    || (folderName.map { last.caseInsensitiveCompare($0) == .orderedSame } ?? false) {
                    let relative = url.resolvingSymlinksInPath().path.dropFirst(base.count).drop { $0 == "/" }
                    return "<user \(index)>/" + String(relative)
                }
            }
        }
        return nil
    }

    var summary: String {
        "cloud-change=\(changeNumber) cloud-files=\(cloudFiles) same=\(count(.same)) differ=\(count(.differ)) " +
        "missing-local=\(count(.cloudOnly)) local-only=\(count(.localOnly)) unmapped=\(unmapped.count)"
    }
}

// MARK: - Download

/// Where Steam says a cloud file can be fetched (Cloud.ClientFileDownload).
struct SteamCloudDownloadInfo: Sendable {
    var fileSize: UInt64 = 0      // bytes on the wire
    var rawSize: UInt64 = 0       // bytes of the file itself
    var host = ""
    var path = ""
    var https = true
    var headers: [(name: String, value: String)] = []
    var encrypted = false

    /// CCloud_ClientFileDownload_Response: file_size = 2, raw_file_size = 3,
    /// url_host = 7, url_path = 8, use_https = 9, request_headers = 10
    /// { name = 1, value = 2 }, encrypted = 11.
    static func parse(_ data: Data) throws -> SteamCloudDownloadInfo {
        var decoder = ProtobufDecoder(data)
        var info = SteamCloudDownloadInfo()
        while let tag = try decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (2, .varint): info.fileSize = try decoder.readVarint()
            case (3, .varint): info.rawSize = try decoder.readVarint()
            case (7, .lengthDelimited): info.host = try decoder.readString()
            case (8, .lengthDelimited): info.path = try decoder.readString()
            case (9, .varint): info.https = try decoder.readVarint() != 0
            case (11, .varint): info.encrypted = try decoder.readVarint() != 0
            case (10, .lengthDelimited):
                var sub = ProtobufDecoder(try decoder.readBytes())
                var name = "", value = ""
                while let field = try sub.readTag() {
                    switch (field.fieldNumber, field.wireType) {
                    case (1, .lengthDelimited): name = try sub.readString()
                    case (2, .lengthDelimited): value = try sub.readString()
                    default: try sub.skip(wireType: field.wireType)
                    }
                }
                if !name.isEmpty, info.headers.count < 32 { info.headers.append((name, value)) }
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return info
    }

    var url: URL? {
        guard !host.isEmpty, !host.contains("/"), !host.contains("@") else { return nil }
        // Saves and request headers always go over TLS, whatever use_https says.
        return URL(string: "https://" + host + (path.hasPrefix("/") ? path : "/" + path))
    }
}

enum SteamCloudTransfer {
    /// Saves are small; anything larger than this is refused.
    static let maxFileBytes = 256 << 20

    private static let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// The first entry of a ZIP archive (Steam sends a compressed cloud file
    /// as a one-entry archive): stored or deflated. Sizes come from the
    /// central directory, which is always filled in.
    static func unzipFirstEntry(_ data: Data, rawSize: Int) -> Data? {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard bytes.count >= 30, u32(0) == 0x04034b50, rawSize >= 0, rawSize <= maxFileBytes else { return nil }
        let method = u16(8)
        let start = 30 + u16(26) + u16(28)
        var packed = u32(18)
        if packed == 0 {   // sizes deferred to the central directory
            var at = bytes.count - 46
            var found = false
            while at >= start {
                if u32(at) == 0x02014b50 { packed = u32(at + 20); found = true; break }
                at -= 1
            }
            guard found else { return nil }
        }
        guard start <= bytes.count, packed >= 0, start + packed <= bytes.count else { return nil }
        let payload = Array(bytes[start..<(start + packed)])
        if method == 0 { return payload.count == rawSize ? Data(payload) : nil }
        guard method == 8, rawSize > 0 else { return rawSize == 0 && method == 8 ? Data() : nil }
        let capacity = rawSize + 64
        var output = [UInt8](repeating: 0, count: capacity)
        let written = compression_decode_buffer(&output, capacity, payload, payload.count, nil, COMPRESSION_ZLIB)
        return written == rawSize ? Data(output[0..<rawSize]) : nil
    }

    /// Fetches one cloud file's bytes and checks them against the SHA-1 the
    /// cloud's own list gives. Throws rather than return anything unverified.
    static func fetch(_ info: SteamCloudDownloadInfo, expectedSHA: Data) async throws -> Data {
        guard !info.encrypted else { throw SteamFileError.invalid("This Steam Cloud file is encrypted, which is not supported.") }
        guard let url = info.url, info.fileSize <= UInt64(maxFileBytes), info.rawSize <= UInt64(maxFileBytes) else {
            throw SteamFileError.invalid("Steam gave no usable address for this Steam Cloud file.")
        }
        var request = URLRequest(url: url)
        for header in info.headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
        let (body, response) = try await http.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SteamFileError.invalid("Steam Cloud download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        var file = body
        if info.fileSize != info.rawSize || (body.count != Int(info.rawSize) && body.starts(with: [0x50, 0x4b, 0x03, 0x04])) {
            guard let unpacked = unzipFirstEntry(body, rawSize: Int(info.rawSize)) else {
                throw SteamFileError.invalid("A Steam Cloud file could not be unpacked.")
            }
            file = unpacked
        }
        guard Data(Insecure.SHA1.hash(data: file)) == expectedSHA else {
            throw SteamFileError.invalid("A Steam Cloud file did not match its checksum.")
        }
        return file
    }

    /// Puts downloaded bytes in place. An existing file is first copied under
    /// `backup` (same relative path); the new file replaces it atomically and
    /// takes the cloud's modification time.
    static func place(_ file: Data, at url: URL, backupTo backup: URL, relative: [String], time: UInt64) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            var target = backup
            for part in relative { target.appendPathComponent(part) }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.copyItem(at: url, to: target)
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.write(to: url, options: .atomic)
        if time > 0 {
            try? manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(time))], ofItemAtPath: url.path)
        }
    }
}

// MARK: - Valve's client's file list

/// madeira-bcd: userdata/<account>/<app>/remotecache.vdf, the list of an
/// app's Steam Cloud API files that Valve's client in a Madeira Dock session
/// answers ISteamRemoteStorage from. That client syncs an app only at its
/// "init" (the launch download never runs: Madeira starts the game itself), and
/// an init with no list deletes the file and leaves the list empty. So the
/// files Madeira downloaded into `remote` were invisible to the game: Slay the
/// Spire 2 saw no saves, started a new profile and wrote it over the
/// downloaded progress.save, which the next sync then uploaded as a change
/// made on this device (cloud_log.txt: only "Starting sync (init,)" for the
/// app; remotecache.vdf: ChangeNumber 0 and the two files the game wrote).
///
/// After each comparison, while no session runs, the list is rewritten from
/// what is on the device: a file identical to the cloud's is listed as synced
/// (syncstate 1) at the cloud's change number; a file that differs or that only
/// the device has keeps the client's entry, or gets the one the client gives a
/// file the game wrote (syncstate 3); a file only the cloud has is left out.
/// Entries for files not under `remote` (AutoCloud roots) are kept as they are.
/// Foundation only.
enum SteamRemoteCache {
    typealias Fields = [(key: String, value: String)]

    struct List: Equatable {
        var appID = ""
        var header: Fields = []
        var files: [(name: String, fields: Fields)] = []

        static func == (a: List, b: List) -> Bool {
            func same(_ x: Fields, _ y: Fields) -> Bool { x.elementsEqual(y) { $0.key == $1.key && $0.value == $1.value } }
            return a.appID == b.appID && same(a.header, b.header)
                && a.files.elementsEqual(b.files) { $0.name == $1.name && same($0.fields, $1.fields) }
        }
    }

    private enum Token: Equatable { case text(String), open, close }

    private static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var chars = Array(text)[...]
        while let char = chars.popFirst() {
            switch char {
            case "{": out.append(.open)
            case "}": out.append(.close)
            case "\"":
                var value = ""
                while let c = chars.popFirst(), c != "\"" {
                    if c == "\\", let next = chars.popFirst() { value.append(next) } else { value.append(c) }
                }
                out.append(.text(value))
            default: continue
            }
        }
        return out
    }

    /// The flat two-level layout the client writes: "app" { "Key" "value" ... "file" { "key" "value" ... } }.
    static func parse(_ text: String) -> List? {
        var t = tokens(text)[...]
        guard case .text(let app)? = t.popFirst(), t.popFirst() == .open else { return nil }
        var list = List(appID: app)
        while let token = t.popFirst() {
            guard case .text(let key) = token else { return token == .close ? list : nil }
            switch t.popFirst() {
            case .text(let value)?: list.header.append((key, value))
            case .open?:
                var fields: Fields = []
                while let inner = t.popFirst(), inner != .close {
                    guard case .text(let k) = inner, case .text(let v)? = t.popFirst() else { return nil }
                    fields.append((k, v))
                }
                list.files.append((key, fields))
            default: return nil
            }
        }
        return nil   // no closing brace
    }

    static func format(_ list: List) -> String {
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var out = quoted(list.appID) + "\n{\n"
        for field in list.header { out += "\t" + quoted(field.key) + "\t\t" + quoted(field.value) + "\n" }
        for file in list.files {
            out += "\t" + quoted(file.name) + "\n\t{\n"
            for field in file.fields { out += "\t\t" + quoted(field.key) + "\t\t" + quoted(field.value) + "\n" }
            out += "\t}\n"
        }
        return out + "}\n"
    }

    /// Rewrites the app's list from a comparison. Returns the counts written,
    /// or nil when there is nothing to write (no `remote` files, or no change).
    static func write(appID: Int, audit: SteamCloudAudit, paths: SteamCloudPaths) -> (synced: Int, local: Int, dropped: Int)? {
        let url = paths.remoteFolder.deletingLastPathComponent().appendingPathComponent("remotecache.vdf")
        let remote = audit.entries.filter { SteamCloudPaths.split($0.path).root == nil }
        let existing = (try? String(contentsOf: url, encoding: .utf8)).flatMap(parse)
        guard !remote.isEmpty || existing != nil else { return nil }
        var list = existing ?? List()
        list.appID = String(appID)
        func setHeader(_ key: String, _ value: String) {
            if let at = list.header.firstIndex(where: { $0.key == key }) { list.header[at].value = value } else { list.header.append((key, value)) }
        }
        setHeader("ChangeNumber", String(audit.changeNumber))
        if !list.header.contains(where: { $0.key == "OSType" }) { setHeader("OSType", "0") }
        func at(_ name: String) -> Int? { list.files.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        func isRemote(_ fields: Fields) -> Bool { (fields.first { $0.key == "root" }?.value ?? "0") == "0" }
        var synced = 0, local = 0, dropped = 0
        for entry in remote {
            let index = at(entry.path)
            if let index, !isRemote(list.files[index].fields) { continue }
            switch entry.kind {
            case .same:
                let fields: Fields = [("root", "0"), ("size", String(entry.localSize)), ("localtime", String(entry.localTime)),
                                      ("time", String(entry.cloudTime)), ("remotetime", String(entry.cloudTime)),
                                      ("sha", SteamCloudPlan.hex(entry.localSHA)), ("syncstate", "1"),
                                      ("persiststate", "0"), ("platformstosync2", "-1")]
                if let index { list.files[index] = (list.files[index].name, fields) } else { list.files.append((entry.path, fields)) }
                synced += 1
            case .differ, .localOnly:
                if index == nil {
                    list.files.append((entry.path, [("root", "0"), ("size", String(entry.localSize)), ("localtime", String(entry.localTime)),
                                                    ("time", String(entry.localTime)), ("remotetime", "0"),
                                                    ("sha", SteamCloudPlan.hex(entry.localSHA)), ("syncstate", "3"),
                                                    ("persiststate", "0"), ("platformstosync2", "-1")]))
                }
                local += 1
            case .cloudOnly:
                if let index { list.files.remove(at: index); dropped += 1 }
            }
        }
        guard list != existing else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(format(list).utf8).write(to: url, options: .atomic)
        } catch { return nil }
        return (synced, local, dropped)
    }
}

// MARK: - What to do with a comparison

/// Decides, from a comparison and the record of what was last in sync, which
/// files changed on one side only (and can be copied without asking) and
/// which need the user's choice. Foundation only.
struct SteamCloudPlan: Equatable, Sendable {
    var download: [SteamCloudEntry] = []
    var upload: [SteamCloudEntry] = []
    /// Differ, and either both sides changed since the last sync or there is
    /// no record of one.
    var conflicts: [SteamCloudEntry] = []
    /// New record entries: SHA-1 of the files identical on both sides now, and
    /// the marks below.
    var settled: [String: String] = [:]

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// Record marks besides a SHA-1. `missing:<sha>`: a save synced here at
    /// <sha> is gone from this device while the cloud still has it, and no
    /// choice was made yet. `deleted:<sha>`: the user chose to leave it gone
    /// while the cloud held <sha>.
    static let missingMark = "missing:", deletedMark = "deleted:"

    /// `baseline`: SHA-1 (hex) of each file when it was last the same on both
    /// sides, or a mark, by `SteamCloudEntry.key`.
    static func make(audit: SteamCloudAudit, baseline: [String: String]) -> SteamCloudPlan {
        var plan = SteamCloudPlan()
        for entry in audit.entries {
            let known = baseline[entry.key]
            let marked = known.map { $0.hasPrefix(missingMark) || $0.hasPrefix(deletedMark) } ?? false
            switch entry.kind {
            case .same:
                plan.settled[entry.key] = hex(entry.cloudSHA)
            case .differ:
                // Without a complete local checksum neither side can be chosen automatically.
                guard !entry.localSHA.isEmpty else { plan.conflicts.append(entry); continue }
                // A save that was missing here and is back is a new file, not a
                // change of the synced one: never copied over the cloud's unasked.
                let cloud = hex(entry.cloudSHA), local = hex(entry.localSHA)
                if let known, !marked, known == cloud, known != local { plan.upload.append(entry) }
                else if let known, !marked, known == local, known != cloud { plan.download.append(entry) }
                else { plan.conflicts.append(entry) }
            case .cloudOnly:
                let cloud = hex(entry.cloudSHA)
                if known == nil {
                    plan.download.append(entry)          // new in the cloud
                } else if known == deletedMark + cloud {
                    break                                // left gone, by the user's choice
                } else if known?.hasPrefix(deletedMark) == true {
                    plan.download.append(entry)          // changed in the cloud since: nothing here to lose
                } else {
                    // Synced here once and gone now: lost with the prefix or deleted
                    // by the game. The user chooses; until then the mark keeps a new
                    // save of that name from going up over the cloud's copy.
                    plan.conflicts.append(entry)
                    if !marked { plan.settled[entry.key] = missingMark + (known ?? "") }
                }
            case .localOnly:
                // New on this device. A file the cloud once had and no longer has was
                // deleted elsewhere: it is not sent back.
                if known == nil, !entry.localSHA.isEmpty { plan.upload.append(entry) }
            }
        }
        return plan
    }
}

// MARK: - Upload

/// One HTTP request of a file upload (ClientCloudFileUploadBlockDetails).
struct SteamCloudUploadBlock: Sendable {
    var host = ""
    var path = ""
    var https = true
    var method: Int32 = 0
    var headers: [(name: String, value: String)] = []
    var offset: UInt64 = 0
    var length: UInt64 = 0
    var explicitBody = Data()

    /// CCloud_ClientBeginFileUpload_Response: encrypt_file = 1, block_requests = 2
    /// { url_host = 1, url_path = 2, use_https = 3, http_method = 4,
    /// request_headers = 5 { name = 1, value = 2 }, block_offset = 6,
    /// block_length = 7, explicit_body_data = 8 }.
    static func parse(_ data: Data) throws -> (encrypt: Bool, blocks: [SteamCloudUploadBlock]) {
        var decoder = ProtobufDecoder(data)
        var encrypt = false
        var blocks: [SteamCloudUploadBlock] = []
        while let tag = try decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, .varint): encrypt = try decoder.readVarint() != 0
            case (2, .lengthDelimited):
                var sub = ProtobufDecoder(try decoder.readBytes())
                var block = SteamCloudUploadBlock()
                while let field = try sub.readTag() {
                    switch (field.fieldNumber, field.wireType) {
                    case (1, .lengthDelimited): block.host = try sub.readString()
                    case (2, .lengthDelimited): block.path = try sub.readString()
                    case (3, .varint): block.https = try sub.readVarint() != 0
                    case (4, .varint): block.method = Int32(truncatingIfNeeded: try sub.readVarint())
                    case (6, .varint): block.offset = try sub.readVarint()
                    case (7, .varint): block.length = try sub.readVarint()
                    case (8, .lengthDelimited): block.explicitBody = try sub.readBytes()
                    case (5, .lengthDelimited):
                        var header = ProtobufDecoder(try sub.readBytes())
                        var name = "", value = ""
                        while let part = try header.readTag() {
                            switch (part.fieldNumber, part.wireType) {
                            case (1, .lengthDelimited): name = try header.readString()
                            case (2, .lengthDelimited): value = try header.readString()
                            default: try header.skip(wireType: part.wireType)
                            }
                        }
                        if !name.isEmpty, block.headers.count < 32 { block.headers.append((name, value)) }
                    default: try sub.skip(wireType: field.wireType)
                    }
                }
                blocks.append(block)
                if blocks.count > 4096 { throw SteamFileError.invalid("Steam asked for too many upload parts.") }
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return (encrypt, blocks)
    }

    var url: URL? {
        guard !host.isEmpty, !host.contains("/"), !host.contains("@") else { return nil }
        // Saves and request headers always go over TLS, whatever use_https says.
        return URL(string: "https://" + host + (path.hasPrefix("/") ? path : "/" + path))
    }
}

extension SteamCloudTransfer {
    /// Sends the parts of one file where Steam asked for them. k_EHTTPMethodPOST
    /// is 3; Steam's storage otherwise takes PUT. Returns each part's HTTP status.
    @discardableResult
    static func send(_ file: Data, blocks: [SteamCloudUploadBlock]) async throws -> [Int] {
        var statuses: [Int] = []
        for block in blocks {
            guard let url = block.url else { throw SteamFileError.invalid("Steam gave no usable address for an upload.") }
            var body = block.explicitBody
            if body.isEmpty {
                let start = Int(min(block.offset, UInt64(file.count)))
                let end = Int(min(block.offset + block.length, UInt64(file.count)))
                guard end - start == Int(block.length) else { throw SteamFileError.invalid("Steam asked for a part outside the file.") }
                body = file.subdata(in: start..<end)
            }
            var request = URLRequest(url: url)
            request.httpMethod = block.method == 3 ? "POST" : "PUT"
            for header in block.headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
            let (_, response) = try await uploadSession.upload(for: request, from: body)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            statuses.append(status)
            guard (200..<300).contains(status) else { throw SteamFileError.invalid("Steam Cloud upload failed (HTTP \(status)).") }
        }
        return statuses
    }

    private static let uploadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
}

// MARK: - State the interface shows

/// One game's Steam Cloud state, as its Game details page shows it.
struct SteamCloudState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case checking, ready, failed(String)
        case downloading(done: Int, of: Int), uploading(done: Int, of: Int)
    }
    /// What the last comparison leaves to the user.
    var conflicts: [SteamCloudEntry] = []
    var phase: Phase = .checking
    var audit = SteamCloudAudit()
    var checked: Date?
    /// The last download: how many files arrived, and how many replaced files were backed up.
    var lastDownload: (files: Int, backedUp: Int)?
    /// How many files the last upload sent.
    var lastUpload: Int?
    /// Why the last download or upload stopped, shown on the game's page.
    var problem: String?

    mutating func retryFailedCheck() {
        guard case .failed = phase else { return }
        phase = .ready
        checked = nil // cloudHold treats this as stale and requires a fresh audit.
        problem = nil
    }

    static func == (a: SteamCloudState, b: SteamCloudState) -> Bool {
        a.phase == b.phase && a.audit == b.audit && a.checked == b.checked && a.conflicts == b.conflicts
            && a.lastUpload == b.lastUpload && a.problem == b.problem
            && a.lastDownload?.files == b.lastDownload?.files && a.lastDownload?.backedUp == b.lastDownload?.backedUp
    }
}
