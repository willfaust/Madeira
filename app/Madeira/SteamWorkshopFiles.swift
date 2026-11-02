// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//  Steam Workshop, the parts without UI (docs/STEAM_WORKSHOP.md): Workshop
//  items as Steam's PublishedFile service describes them, the requests the
//  Workshop page sends over the app's own Steam connection, and Valve's
//  on-disk layout for installed items (steamapps/workshop/content/<app>/<item>
//  and the appworkshop_<app>.acf record), which Valve's client in a Madeira
//  Dock session and the game's ISteamUGC calls read.
//  Foundation only (tests/host/check-steam-workshop.py compiles and runs it).
//

import Foundation

/// One Workshop item (PublishedFileDetails).
struct SteamWorkshopItem: Identifiable, Hashable, Codable, Sendable {
    var id: UInt64
    var appID: UInt32 = 0
    var result: UInt32 = 0
    var title = ""
    var summary = ""
    var previewURL = ""
    /// Older items are one file at a URL; current ones are a manifest of the
    /// app's Workshop depot (`content`, Steam's hcontent_file).
    var fileURL = ""
    var fileName = ""
    var fileSize: UInt64 = 0
    var content: UInt64 = 0
    var timeUpdated: UInt32 = 0
    var fileType: UInt32 = 0
    var banned = false
    var subscriptions: UInt32 = 0

    /// EWorkshopFileType: Community (0), Microtransaction (1) and Game managed
    /// (15) items are content a game loads; collections, guides, art and
    /// videos are not.
    var isContent: Bool { [0, 1, 15].contains(fileType) }
    var isCollection: Bool { fileType == 2 }
    /// Steam answered for the item (result 1) and it has files to fetch.
    var downloadable: Bool { result == 1 && !banned && isContent && (content != 0 || !fileURL.isEmpty) }
    var storeURL: URL? { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)") }

    /// Decodes PublishedFileDetails (steammessages_publishedfile). Wire types
    /// are taken as they come: a field in an unexpected encoding is skipped.
    static func parse(_ data: Data) throws -> SteamWorkshopItem {
        var item = SteamWorkshopItem(id: 0)
        var decoder = ProtobufDecoder(data)
        while let tag = try decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, .varint): item.result = UInt32(truncatingIfNeeded: try decoder.readVarint())
            case (2, .varint): item.id = try decoder.readVarint()
            case (2, .fixed64): item.id = try decoder.readFixed64()
            case (5, .varint): item.appID = UInt32(truncatingIfNeeded: try decoder.readVarint())
            case (7, .lengthDelimited): item.fileName = text(try decoder.readBytes(), limit: 260)
            case (8, .varint): item.fileSize = try decoder.readVarint()
            case (10, .lengthDelimited): item.fileURL = text(try decoder.readBytes(), limit: 2048)
            case (11, .lengthDelimited): item.previewURL = text(try decoder.readBytes(), limit: 2048)
            case (14, .fixed64): item.content = try decoder.readFixed64()
            case (14, .varint): item.content = try decoder.readVarint()
            case (16, .lengthDelimited): item.title = text(try decoder.readBytes(), limit: 200)
            case (18, .lengthDelimited): item.summary = text(try decoder.readBytes(), limit: 600)
            case (20, .varint): item.timeUpdated = UInt32(truncatingIfNeeded: try decoder.readVarint())
            case (28, .varint): item.banned = try decoder.readVarint() != 0
            case (34, .varint): item.fileType = UInt32(truncatingIfNeeded: try decoder.readVarint())
            case (36, .varint): item.subscriptions = UInt32(truncatingIfNeeded: try decoder.readVarint())
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        if item.title.isEmpty { item.title = "Item \(item.id)" }
        return item
    }

    private static func text(_ data: Data, limit: Int) -> String {
        let value = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" }.prefix(limit).map(Character.init))
    }
}

/// A page of items and how many Steam has in all.
struct SteamWorkshopPage: Equatable, Sendable {
    var total = 0
    var items: [SteamWorkshopItem] = []
}

/// Request bodies and response readers for Steam's PublishedFile service.
/// Field numbers are Valve's (steammessages_publishedfile.steamclient.proto).
enum SteamWorkshopRequests {
    /// What Browse lists.
    enum Order: String, CaseIterable, Identifiable, Sendable {
        case trend, subscribed, recent, search
        var id: String { rawValue }
        var label: String {
            switch self {
            case .trend: return "Popular this week"
            case .subscribed: return "Most subscribed"
            case .recent: return "Most recent"
            case .search: return "Search"
            }
        }
        /// EPublishedFileQueryType.
        var queryType: UInt32 {
            switch self {
            case .trend: return 3
            case .subscribed: return 9
            case .recent: return 1
            case .search: return 12
            }
        }
    }

    static let pageSize: UInt32 = 30
    static let subscribedPageSize: UInt32 = 100
    /// Steam's subscription list (EUCMListType subscribed).
    static let subscribedList: UInt32 = 1

    /// PublishedFile.GetUserFiles: the account's subscribed items for one app.
    static func subscribed(steamID: UInt64, appID: UInt32, page: UInt32) -> Data {
        var request = ProtobufEncoder()
        request.writeFixed64(fieldNumber: 1, value: steamID)              // steamid
        request.writeUInt32(fieldNumber: 2, value: appID)                 // appid
        request.writeUInt32(fieldNumber: 4, value: max(page, 1))          // page
        request.writeUInt32(fieldNumber: 5, value: subscribedPageSize)    // numperpage
        request.writeString(fieldNumber: 6, value: "mysubscriptions")     // type
        request.writeBool(fieldNumber: 24, value: true)                   // return_short_description
        request.writeBool(fieldNumber: 32, value: true)                   // strip_description_bbcode
        return request.data
    }

    /// PublishedFile.QueryFiles: one page of an app's items.
    static func query(appID: UInt32, order: Order, text: String, page: UInt32) -> Data {
        var request = ProtobufEncoder()
        request.writeUInt32(fieldNumber: 1, value: order.queryType)       // query_type
        request.writeUInt32(fieldNumber: 2, value: max(page, 1))          // page
        request.writeUInt32(fieldNumber: 3, value: pageSize)              // numperpage
        request.writeUInt32(fieldNumber: 5, value: appID)                 // appid
        if order == .search {
            request.writeString(fieldNumber: 11, value: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))
        }
        if order == .trend { request.writeUInt32(fieldNumber: 14, value: 7) }   // days
        request.writeBool(fieldNumber: 22, value: true)                   // return_short_description
        request.writeBool(fieldNumber: 37, value: true)                   // return_details
        request.writeBool(fieldNumber: 38, value: true)                   // strip_description_bbcode
        return request.data
    }

    /// PublishedFile.GetDetails: items by ID (installed items that are no longer subscribed).
    static func details(appID: UInt32, ids: [UInt64]) -> Data {
        var request = ProtobufEncoder()
        for id in ids.prefix(100) { request.writeFixed64(fieldNumber: 1, value: id) }   // publishedfileids
        request.writeBool(fieldNumber: 8, value: true)                    // short_description
        request.writeUInt32(fieldNumber: 14, value: appID)                // appid
        request.writeBool(fieldNumber: 15, value: true)                   // strip_description_bbcode
        return request.data
    }

    /// PublishedFile.Subscribe / Unsubscribe.
    static func subscription(itemID: UInt64, appID: UInt32) -> Data {
        var request = ProtobufEncoder()
        request.writeUInt64(fieldNumber: 1, value: itemID)                // publishedfileid
        request.writeUInt32(fieldNumber: 2, value: subscribedList)        // list_type
        request.writeInt32(fieldNumber: 3, value: Int32(bitPattern: appID)) // appid
        request.writeBool(fieldNumber: 4, value: true)                    // notify_client
        return request.data
    }

    /// The response's total and its PublishedFileDetails, which sit at
    /// `itemsField` (GetUserFiles 3, QueryFiles 2, GetDetails 1).
    static func page(_ data: Data, itemsField: UInt32, totalField: UInt32? = 1) throws -> SteamWorkshopPage {
        var page = SteamWorkshopPage()
        var decoder = ProtobufDecoder(data)
        while let tag = try decoder.readTag() {
            if tag.fieldNumber == itemsField, tag.wireType == .lengthDelimited {
                let item = try SteamWorkshopItem.parse(try decoder.readBytes())
                if item.id != 0, page.items.count < 1000 { page.items.append(item) }
            } else if tag.fieldNumber == totalField, tag.wireType == .varint {
                page.total = Int(truncatingIfNeeded: min(try decoder.readVarint(), 1_000_000))
            } else {
                try decoder.skip(wireType: tag.wireType)
            }
        }
        return page
    }
}

/// Valve's record of an app's installed Workshop items:
/// steamapps/workshop/appworkshop_<app>.acf. Valve's client reads it to know
/// which items are on disk and current; entries it wrote itself are kept.
struct SteamWorkshopRecord: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var installed = false
        var size: UInt64 = 0
        var timeUpdated: UInt32 = 0
        var manifest: UInt64 = 0
        var timeTouched: UInt32 = 0
        var subscribedBy: UInt32 = 0
    }
    var appID: UInt32
    var entries: [UInt64: Entry] = [:]
    var timeLastAppRan: UInt32 = 0
    var lastBuildID: UInt32 = 0

    var installed: [UInt64: Entry] { entries.filter(\.value.installed) }

    static func workshopFolder(_ steamApps: URL) -> URL { steamApps.appendingPathComponent("workshop", isDirectory: true) }
    static func url(appID: UInt32, steamApps: URL) -> URL {
        workshopFolder(steamApps).appendingPathComponent("appworkshop_\(appID).acf")
    }
    /// Where Valve's client keeps one item's files.
    static func itemFolder(appID: UInt32, itemID: UInt64, steamApps: URL) -> URL {
        workshopFolder(steamApps).appendingPathComponent("content/\(appID)/\(itemID)", isDirectory: true)
    }
    /// Madeira's resume journal for one item, apart from Valve's own downloads folder.
    static func journalFolder(appID: UInt32, itemID: UInt64, steamApps: URL) -> URL {
        workshopFolder(steamApps).appendingPathComponent("downloads/madeira/\(appID)_\(itemID)", isDirectory: true)
    }

    /// The record on disk, or an empty one. A record that does not read keeps
    /// nothing (Valve's client rebuilds it from the folders at its next start).
    static func read(appID: UInt32, steamApps: URL) -> SteamWorkshopRecord {
        guard let data = try? Data(contentsOf: url(appID: appID, steamApps: steamApps)) else { return SteamWorkshopRecord(appID: appID) }
        return parse(data, appID: appID)
    }

    static func parse(_ data: Data, appID: UInt32) -> SteamWorkshopRecord {
        var record = SteamWorkshopRecord(appID: appID)
        guard var reader = try? SteamKeyValues(data), let root = try? reader.read()["appworkshop"] else { return record }
        func number<T: FixedWidthInteger>(_ value: SteamValue?) -> T { value?.string.flatMap { T($0) } ?? 0 }
        record.timeLastAppRan = number(root["TimeLastAppRan"])
        record.lastBuildID = number(root["LastBuildID"])
        for (key, value) in root["WorkshopItemDetails"]?.fields ?? [:] {
            guard let id = UInt64(key), id != 0 else { continue }
            var entry = record.entries[id] ?? Entry()
            entry.manifest = number(value["manifest"])
            entry.timeUpdated = number(value["timeupdated"])
            entry.timeTouched = number(value["timetouched"])
            entry.subscribedBy = number(value["subscribedby"])
            record.entries[id] = entry
        }
        for (key, value) in root["WorkshopItemsInstalled"]?.fields ?? [:] {
            guard let id = UInt64(key), id != 0 else { continue }
            var entry = record.entries[id] ?? Entry()
            entry.installed = true
            entry.size = number(value["size"])
            let manifest: UInt64 = number(value["manifest"]), updated: UInt32 = number(value["timeupdated"])
            if manifest != 0 { entry.manifest = manifest }
            if updated != 0 { entry.timeUpdated = updated }
            record.entries[id] = entry
        }
        return record
    }

    /// The record as Valve's client writes it.
    func text(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> String {
        let ids = entries.keys.sorted()
        let installedIDs = ids.filter { entries[$0]!.installed }
        let size = installedIDs.reduce(UInt64(0)) { $0 &+ entries[$1]!.size }
        var lines = ["\"AppWorkshop\"", "{"]
        func field(_ indent: Int, _ key: String, _ value: CustomStringConvertible) {
            lines.append(String(repeating: "\t", count: indent) + "\"\(key)\"\t\t\"\(value)\"")
        }
        field(1, "appid", appID)
        field(1, "SizeOnDisk", size)
        field(1, "NeedsUpdate", 0)
        field(1, "NeedsDownload", installedIDs.count == ids.count ? 0 : 1)
        field(1, "TimeLastUpdated", now)
        field(1, "TimeLastAppRan", timeLastAppRan)
        field(1, "LastBuildID", lastBuildID)
        lines += ["\t\"WorkshopItemsInstalled\"", "\t{"]
        for id in installedIDs {
            let entry = entries[id]!
            lines += ["\t\t\"\(id)\"", "\t\t{"]
            field(3, "size", entry.size)
            field(3, "timeupdated", entry.timeUpdated)
            field(3, "manifest", entry.manifest)
            lines.append("\t\t}")
        }
        lines += ["\t}", "\t\"WorkshopItemDetails\"", "\t{"]
        for id in ids {
            let entry = entries[id]!
            lines += ["\t\t\"\(id)\"", "\t\t{"]
            field(3, "manifest", entry.manifest)
            field(3, "timeupdated", entry.timeUpdated)
            field(3, "timetouched", entry.timeTouched == 0 ? now : entry.timeTouched)
            field(3, "subscribedby", entry.subscribedBy)
            if entry.installed {
                field(3, "latest_timeupdated", entry.timeUpdated)
                field(3, "latest_manifest", entry.manifest)
            }
            lines.append("\t\t}")
        }
        lines += ["\t}", "}"]
        return lines.joined(separator: "\n") + "\n"
    }

    func write(steamApps: URL) throws {
        let url = Self.url(appID: appID, steamApps: steamApps)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text().utf8).write(to: url, options: .atomic)
    }

    /// Installed means recorded and its folder present (an item whose folder was
    /// removed by hand needs downloading again).
    func isOnDisk(_ itemID: UInt64, steamApps: URL) -> Bool {
        guard entries[itemID]?.installed == true else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: Self.itemFolder(appID: appID, itemID: itemID, steamApps: steamApps).path,
                                              isDirectory: &directory) && directory.boolValue
    }

    /// Whether Steam has a newer version than the one on disk.
    func needsUpdate(_ item: SteamWorkshopItem) -> Bool {
        guard let entry = entries[item.id], entry.installed else { return false }
        if item.content != 0, entry.manifest != 0 { return item.content != entry.manifest }
        return item.timeUpdated > entry.timeUpdated
    }

    /// The file name an older (single-file) item is saved under in its folder.
    static func legacyFileName(_ item: SteamWorkshopItem) -> String {
        let name = SteamInstallFiles.safeFolderName(item.fileName)
        return name == "app" || name.isEmpty ? "\(item.id)_legacy.bin" : name
    }
}
