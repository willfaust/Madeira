// SPDX-License-Identifier: GPL-3.0-or-later
// Store identity (decision 0057): a copy of a game is `(store, store game ID)`
// end to end, never a name. Its catalogue title ID is store-qualified:
//
//   steam  app-<appID>          (as before)
//   gog    gog-<productID>
//   epic   epic-<appName>
//   local  dir-<lowercased folder> (as before: an imported or found folder)
//
// A store's install, and Playport's own import, writes a `StoreReceipt` under
// installs/<store>-<id>.json; Steam's `<appID>.json` (InstallReceipt) stays as it is.

import Foundation

public enum Store: String, Codable, CaseIterable, Sendable {
    case local, steam, gog, epic

    public var label: String {
        switch self {
        case .local: "Local"
        case .steam: "Steam"
        case .gog: "GOG"
        case .epic: "Epic Games"
        }
    }

    /// The title ID prefix (`app-`, `gog-`, `epic-`, `dir-`).
    public var titlePrefix: String {
        switch self {
        case .local: "dir-"
        case .steam: "app-"
        case .gog: "gog-"
        case .epic: "epic-"
        }
    }
}

/// A game in one store: what downloads, art, receipts and navigation key on.
public struct StoreGameKey: Codable, Hashable, Sendable, CustomStringConvertible {
    public var store: Store
    /// Steam: the app ID in decimal; GOG: the product ID; Epic: the app name;
    /// local: the folder under C:\Games, lowercased.
    public var id: String

    public init(store: Store, id: String) {
        self.store = store
        self.id = store == .local ? id.lowercased() : id
    }

    public static func steam(_ appID: UInt32) -> StoreGameKey { StoreGameKey(store: .steam, id: String(appID)) }

    /// The Steam app ID of a Steam key.
    public var steamAppID: UInt32? { store == .steam ? UInt32(id) : nil }

    /// `app-367520`, `gog-1207664663`, `epic-Fortnite`, `dir-hollow knight`.
    public var titleID: String { store.titlePrefix + id }

    /// The key a title ID names, or nil for an ID of no known shape.
    public init?(titleID: String) {
        for store in [Store.steam, .gog, .epic, .local] where titleID.hasPrefix(store.titlePrefix) {
            let id = String(titleID.dropFirst(store.titlePrefix.count))
            guard !id.isEmpty, store != .steam || UInt32(id) != nil else { return nil }
            self.init(store: store, id: id)
            return
        }
        return nil
    }

    /// `installs/<store>-<id>.json`'s base name: the ID made safe as one file name.
    public var fileStem: String {
        let safe = id.unicodeScalars.map { s -> String in
            CharacterSet.alphanumerics.contains(s) && s.isASCII || "-_.".unicodeScalars.contains(s) ? String(s)
                : String(format: "%%%02X", s.value & 0xFF)
        }.joined()
        return "\(store.rawValue)-\(safe)"
    }

    public var description: String { "\(store.rawValue):\(id)" }
}

/// What a store install or an import put in C:\Games, store-neutral: written
/// after the copy is in place, read by adoption, verify and uninstall. Not a
/// secret, and it names no path outside the container.
public struct StoreReceipt: Codable, Equatable, Sendable {
    public var store: Store
    public var storeID: String
    public var name: String
    /// The folder under C:\Games.
    public var installDir: String
    /// The store's build or version, as a string.
    public var version: String?
    /// Relative to the folder, `\`-separated; nil leaves it to adoption.
    public var executable: String?
    public var arguments: [String]?
    /// Relative to the folder; nil is the executable's own.
    public var workingDir: String?
    public var files: Int
    public var bytes: UInt64
    public var installedAt: Date
    /// An import: the name of what was picked (a folder, a .zip, an installer); never its path.
    public var importedFrom: String?
    /// A Steam app ID the imported files name (`steam_appid.txt`): a hint, not an identity (0045).
    public var hintSteamAppID: UInt32?

    public init(store: Store, storeID: String, name: String, installDir: String, version: String? = nil,
                executable: String? = nil, arguments: [String]? = nil, workingDir: String? = nil, files: Int, bytes: UInt64,
                installedAt: Date, importedFrom: String? = nil, hintSteamAppID: UInt32? = nil) {
        self.store = store
        self.storeID = storeID
        self.name = name
        self.installDir = installDir
        self.version = version
        self.executable = executable
        self.arguments = arguments
        self.workingDir = workingDir
        self.files = files
        self.bytes = bytes
        self.installedAt = installedAt
        self.importedFrom = importedFrom
        self.hintSteamAppID = hintSteamAppID
    }

    public var key: StoreGameKey { StoreGameKey(store: store, id: storeID) }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension InstallLayout {
    /// A store receipt's file: `installs/<store>-<id>.json`.
    public func receiptFile(_ key: StoreGameKey) -> URL { installsDir.appendingPathComponent(key.fileStem + ".json") }

    /// Every store receipt in installs/ (`<store>-*.json`); unreadable ones are skipped.
    public func storeReceipts() -> [StoreReceipt] {
        let files = (try? FileManager.default.contentsOfDirectory(at: installsDir, includingPropertiesForKeys: nil)) ?? []
        let prefixes = Store.allCases.map { $0.rawValue + "-" }
        return files.filter { u in u.pathExtension == "json" && prefixes.contains { u.lastPathComponent.hasPrefix($0) } }
            .sorted { $0.path < $1.path }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? StoreReceipt.decoder.decode(StoreReceipt.self, from: $0) } }
    }

    public func saveReceipt(_ r: StoreReceipt) throws {
        try InstallFS.makeDirectory(installsDir)
        try InstallFS.writeAtomically(receiptFile(r.key), StoreReceipt.encoder.encode(r))
    }

    public func removeReceipt(_ key: StoreGameKey) {
        try? FileManager.default.removeItem(at: receiptFile(key))
    }
}
