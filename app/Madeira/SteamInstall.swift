// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// Where Madeira's own Steam downloads live, and how one is read and removed
// (docs/STEAM_LIBRARY.md). Foundation only, so tests/host/check-steam-library.py
// compiles this file as it is.
//
// A download goes into Madeira Dock's own Steam library folder,
// C:\Program Files (x86)\Steam\steamapps, as `common/<installdir>` plus Steam's
// `appmanifest_<appid>.acf` install record. That is exactly the layout
// Madeira Dock's discovery (MadeiraDock.games) reads and Valve's client, which
// Dock starts the game through, understands: a game is "installed" for Dock
// once its record says so, and the record is written last.

enum SteamInstallPaths {
    /// The library folder, relative to drive_c (the value `DockGame.library` has).
    static let libraryRelative = "Program Files (x86)/Steam/steamapps"

    static func steamApps(drive: URL) -> URL { drive.appendingPathComponent(libraryRelative, isDirectory: true) }
    static func common(drive: URL) -> URL { steamApps(drive: drive).appendingPathComponent("common", isDirectory: true) }

    /// Whether an install (its drive-relative library folder) is in the library
    /// Madeira downloads into, and so can be updated or removed here.
    static func isManaged(library: String, storageID: String = "internal") -> Bool {
        library.caseInsensitiveCompare(storageID == "internal" ? libraryRelative : "steamapps") == .orderedSame
    }
}

/// Register the one external root with Valve's client while no Wine session is
/// running. Preserve existing libraries and unknown fields; refuse malformed
/// metadata instead of replacing it with an empty document.
enum SteamLibraryFolders {
    static func register(externalID: String, name: String, apps: [Int: Int64], drive: URL) throws {
        guard UUID(uuidString: externalID) != nil else { throw SteamStorageError.invalidRecord }
        let file = try SteamStoragePath.native(SteamInstallPaths.libraryRelative + "/libraryfolders.vdf", root: drive)
        var root: [String: SteamValue] = [:]
        do {
            let data = try Data(contentsOf: file)
            var parser = try SteamKeyValues(data)
            root = try parser.read().fields
            guard root["libraryfolders"] != nil else { throw SteamStorageError.invalidRecord }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { }
        var folders = root["libraryfolders"]?.fields ?? [:]
        if folders.isEmpty {
            folders["0"] = .object(["path": .text("C:\\Program Files (x86)\\Steam"), "apps": .object([:])])
        }
        let owned = folders.first { $0.value["madeira_library_id"]?.string == externalID }?.key
        let existingAlias = folders.first {
            let path = $0.value["path"]?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "\\/")).lowercased()
            return path == SteamStoragePath.externalWindowsRoot.lowercased()
        }?.key
        // Never adopt another library's alias, even when it has no Madeira ID.
        // An unrelated E: library also remains untouched.
        if let existingAlias, owned != existingAlias {
            throw SteamStorageError.unavailable(.identityMismatch)
        }
        let key = owned ?? String((folders.keys.compactMap(Int.init).max() ?? 0) + 1)
        var entry = folders[key]?.fields ?? [:]
        entry["path"] = .text(SteamStoragePath.externalWindowsRoot)
        entry["label"] = .text(name)
        entry["madeira_library_id"] = .text(externalID)
        entry["apps"] = .object(Dictionary(uniqueKeysWithValues: apps.map { (String($0.key), .text(String(max(0, $0.value)))) }))
        folders[key] = .object(entry)
        root["libraryfolders"] = .object(folders)
        func quote(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func encode(_ fields: [String: SteamValue], indent: String = "") -> String {
            fields.keys.sorted().map { key in
                switch fields[key]! {
                case .text(let value): return indent + quote(key) + "\t" + quote(value) + "\n"
                case .object(let nested): return indent + quote(key) + "\n" + indent + "{\n" + encode(nested, indent: indent + "\t") + indent + "}\n"
                }
            }.joined()
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(encode(root).utf8).write(to: file, options: .atomic)
    }
}

enum SteamInstallFiles {
    /// The `buildid` the install record of an app states, or nil when there is
    /// no readable record.
    static func buildID(appID: Int, steamApps: URL) -> Int? {
        guard let state = record(appID: appID, steamApps: steamApps) else { return nil }
        return state["buildid"]?.string.flatMap { Int($0) }
    }

    /// The install size the record states (`SizeOnDisk`, bytes), or nil.
    static func sizeOnDisk(appID: Int, steamApps: URL) -> Int64? {
        guard let state = record(appID: appID, steamApps: steamApps),
              let size = state["SizeOnDisk"]?.string.flatMap({ Int64($0) }), size > 0 else { return nil }
        return size
    }

    /// Removes an app's install: its folder under `common`, its record, its
    /// resume journal and the records of the apps that own its shared depots
    /// (those describe the same folder). Only paths strictly inside
    /// `steamApps/common` are removed.
    nonisolated static func delete(appID: Int, folderName: String, steamApps: URL) throws {
        guard appID > 0, folderName == safeFolderName(folderName) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let fm = FileManager.default
        let root = steamApps.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        // Validate every target before changing anything. Never follow common,
        // downloading, a game folder or an install record outside this library.
        func target(_ relative: String) throws -> URL {
            var url = root
            for component in relative.split(separator: "/") {
                url.appendPathComponent(String(component))
                do {
                    let attributes = try fm.attributesOfItem(atPath: url.path)
                    guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                        throw CocoaError(.fileWriteInvalidFileName)
                    }
                } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                    [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { }
            }
            return url
        }
        let folder = try target("common/" + folderName)
        let journal = try target("downloading/\(appID)")
        let recordURL = try target("appmanifest_\(appID).acf")
        var shared: [URL] = []
        if let state = record(appID: appID, steamApps: root) {
            for (_, owner) in (state["SharedDepots"]?.fields ?? [:]).sorted(by: { $0.key < $1.key }).prefix(64) {
                guard let ownerID = owner.string.flatMap({ Int($0) }), ownerID > 0, ownerID != appID else { continue }
                let ownerURL = try target("appmanifest_\(ownerID).acf")
                guard let ownerState = record(appID: ownerID, steamApps: root),
                      let dir = ownerState["installdir"]?.string,
                      dir.caseInsensitiveCompare(folderName) == .orderedSame else { continue }
                shared.append(ownerURL)
            }
        }
        // Missing targets are already removed; every other I/O failure is real.
        // Keep the primary install record until all payload/journal work succeeds.
        for url in [folder, journal] + shared + [recordURL] {
            do { try fm.removeItem(at: url) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { }
        }
    }

    /// Validates a manifest path and folds directory spelling to the first
    /// one seen (case-insensitively). Returns nil for anything that could
    /// escape the install folder.
    nonisolated static func safeRelativePath(_ name: String, folded: inout [String: String]) -> String? {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, name.utf8.count < 1024,
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains(":") ||
                  $0.unicodeScalars.contains(where: { $0.value < 0x20 }) }) else { return nil }
        var built: [String] = []
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1 { built.append(part); break }
            let key = (built + [part]).joined(separator: "/").lowercased()
            if let existing = folded[key] {
                built = existing.split(separator: "/").map(String.init)
            } else {
                built.append(part)
                folded[key] = built.joined(separator: "/")
            }
        }
        return built.joined(separator: "/")
    }

    /// Install folders come from app metadata; keep them to one safe component.
    nonisolated static func safeFolderName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.contains(":"),
              !cleaned.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return "app" }
        return cleaned
    }

    /// The `AppState` block of `appmanifest_<appid>.acf` when the file is
    /// readable, bounded, and names this app.
    private static func record(appID: Int, steamApps: URL) -> SteamValue? {
        let url = steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"], state["appid"]?.string == String(appID) else { return nil }
        return state
    }
}
