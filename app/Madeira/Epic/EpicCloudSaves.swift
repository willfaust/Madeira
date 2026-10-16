// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Epic Cloud saves: the protocol and the sync decision, Foundation only.
//
// Ported from Legendary (GPL-3.0-or-later, https://github.com/derrod/legendary):
// api/egs.py (get_user_cloud_saves, create_game_cloud_saves), core.py (get_save_path,
// upload_save, download_saves), utils/savegame_helper.py (package_savegame),
// models/chunk.py and models/manifest.py (the writers), utils/rolling_hash.py.
//
// A cloud save is a snapshot: manifests/<yyyy.MM.dd-HH.mm.ss>.manifest plus the 1 MiB
// chunks it names, all under the account's savesync/<app> folder. A newer upload is a
// new snapshot and the older ones stay, which is also this file's safety net: nothing
// is ever overwritten or deleted in the cloud.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import zlib

// MARK: - Writing chunks and manifests

/// Little-endian byte writer for Epic's binary formats.
struct EpicWriter {
    private(set) var bytes = [UInt8]()

    mutating func u8(_ value: Int) { bytes.append(UInt8(truncatingIfNeeded: value)) }
    mutating func u32(_ value: Int) { for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: value >> (i * 8))) } }
    mutating func i32(_ value: Int32) { u32(Int(UInt32(bitPattern: value))) }
    mutating func u64(_ value: UInt64) { for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: value >> (UInt64(i) * 8))) } }
    mutating func raw(_ data: Data) { bytes.append(contentsOf: data) }
    /// Legendary's write_fstring: length including the terminator, negative for UTF-16.
    mutating func string(_ text: String) {
        if text.isEmpty { i32(0); return }
        if text.unicodeScalars.allSatisfy({ $0.isASCII }) {
            i32(Int32(text.unicodeScalars.count + 1))
            bytes.append(contentsOf: Array(text.utf8)); bytes.append(0)
        } else {
            let units = Array(text.utf16)
            i32(-Int32(units.count + 1))
            for unit in units { bytes.append(UInt8(unit & 0xFF)); bytes.append(UInt8(unit >> 8)) }
            bytes.append(0); bytes.append(0)
        }
    }
    /// Starts a section: its size (itself included) is filled in by `close`.
    mutating func open() -> Int { let at = bytes.count; u32(0); return at }
    mutating func close(_ at: Int) {
        let size = bytes.count - at
        for i in 0..<4 { bytes[at + i] = UInt8(truncatingIfNeeded: size >> (i * 8)) }
    }
    var data: Data { Data(bytes) }
}

enum EpicSaveWriter {
    static let chunkSize = 1024 * 1024
    static let featureLevel = 18   // Legendary's default serialisation version for saves

    // The rolling hash Epic uses (a CRC-64-ECMA variation), utils/rolling_hash.py.
    private static let table: [UInt64] = (0..<256).map { index in
        var value = UInt64(index)
        for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0xC96C5795D7870F42 : value >> 1 }
        return value
    }
    static func rollingHash(_ data: Data) -> UInt64 {
        var h: UInt64 = 0
        for byte in data { h = ((h << 1) | (h >> 63)) ^ table[Int(byte)] }
        return h
    }

    static func deflate(_ input: Data) throws -> Data {
        var length = compressBound(uLong(input.count))
        var output = Data(count: Int(length))
        let status = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compress(dst.bindMemory(to: Bytef.self).baseAddress, &length,
                         src.bindMemory(to: Bytef.self).baseAddress, uLong(input.count))
            }
        }
        guard status == Z_OK else { throw EpicContentError.invalid("Could not compress a save chunk.") }
        return output.prefix(Int(length))
    }

    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
    }

    struct BuiltChunk {
        var guid: [UInt32]          // four little-endian words
        var hash: UInt64
        var sha: Data
        var group: Int
        var file: Data              // the whole .chunk file
        var path: String
    }

    /// A chunk file: header version 3 (66 bytes) and the zlib-compressed payload, padded
    /// with zeros to 1 MiB first, as Legendary's Chunk.data setter and write() do.
    static func chunk(_ payload: Data, guid: [UInt32]) throws -> BuiltChunk {
        guard payload.count <= chunkSize else { throw EpicContentError.invalid("A save chunk is larger than 1 MiB.") }
        var padded = payload
        if padded.count < chunkSize { padded.append(Data(count: chunkSize - padded.count)) }
        let hash = rollingHash(padded), sha = EpicSHA1.hash(padded)
        let packed = try deflate(padded)
        var w = EpicWriter()
        w.u32(0xB1FE3AA2); w.u32(3); w.u32(66); w.u32(packed.count)
        for word in guid { w.u32(Int(word)) }
        w.u64(hash); w.u8(1)                       // stored_as: compressed
        w.raw(sha); w.u8(3)                        // hash_type: rolling + SHA-1
        w.u32(padded.count)                        // uncompressed size
        w.raw(packed)
        var guidBytes = Data()
        for word in guid { for i in 0..<4 { guidBytes.append(UInt8(truncatingIfNeeded: word >> UInt32(i * 8))) } }
        let group = Int(crc32(guidBytes) % 100)
        let path = String(format: "ChunksV4/%02d/%016llX_%@.chunk", group, hash,
                          guid.map { String(format: "%08X", $0) }.joined())
        return BuiltChunk(guid: guid, hash: hash, sha: sha, group: group, file: w.data, path: path)
    }

    static func randomGUID() -> [UInt32] {
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in UInt32.random(in: 0...UInt32.max, using: &generator) }
    }

    struct SaveFile { var path: String; var data: Data }
    struct Package {
        var manifestPath: String
        var buildVersion: String
        /// Chunks first and the manifest last, so a manifest never names a missing chunk.
        var uploads: [(path: String, data: Data)]
        var fileCount: Int
    }

    static func buildVersion(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy.MM.dd-HH.mm.ss"
        return f.string(from: date)
    }

    /// utils/savegame_helper.py package_savegame: files sorted case-insensitively and packed
    /// back to back into 1 MiB chunks; one chunk part per piece of a file.
    static func package(files: [SaveFile], appName: String, accountID: String, saveFolder: String, date: Date,
                        guid: () -> [UInt32] = randomGUID) throws -> Package {
        struct Part { var guid: [UInt32]; var offset: Int; var size: Int }
        struct Item { var path: String; var sha: Data; var parts: [Part] }
        var items = [Item](), built = [BuiltChunk]()
        var currentGUID: [UInt32]?, buffer = Data()

        func flush() throws {
            guard let id = currentGUID else { return }
            built.append(try chunk(buffer, guid: id))
            currentGUID = nil; buffer = Data()
        }
        for file in files.sorted(by: { $0.path.lowercased() < $1.path.lowercased() }) {
            var item = Item(path: file.path, sha: EpicSHA1.hash(file.data), parts: [])
            var offset = 0
            while offset < file.data.count {
                if currentGUID == nil { currentGUID = guid() }
                let size = min(file.data.count - offset, chunkSize - buffer.count)
                item.parts.append(Part(guid: currentGUID!, offset: buffer.count, size: size))
                buffer.append(file.data.subdata(in: offset..<offset + size))
                offset += size
                if buffer.count >= chunkSize { try flush() }
            }
            items.append(item)
        }
        try flush()

        let version = buildVersion(date)
        var body = EpicWriter()
        // metadata
        var at = body.open()
        body.u8(0); body.u32(featureLevel); body.u8(0); body.u32(0)          // data_version, feature level, is_file_data, app_id
        body.string(appName + accountID); body.string(version); body.string(""); body.string("")
        body.u32(0); body.string(""); body.string(""); body.string("")       // prerequisites
        body.close(at)
        // chunk data list
        at = body.open()
        body.u8(0); body.u32(built.count)
        for c in built { for word in c.guid { body.u32(Int(word)) } }
        for c in built { body.u64(c.hash) }
        for c in built { body.raw(c.sha) }
        for c in built { body.u8(c.group) }
        for _ in built { body.u32(chunkSize) }
        for c in built { body.u64(UInt64(c.file.count)) }
        body.close(at)
        // file manifest list
        at = body.open()
        body.u8(0); body.u32(items.count)
        for i in items { body.string(i.path) }
        for _ in items { body.string("") }                                   // symlink targets
        for i in items { body.raw(i.sha) }
        for _ in items { body.u8(0) }                                        // flags
        for _ in items { body.u32(0) }                                       // install tags
        for i in items {
            body.u32(i.parts.count)
            for p in i.parts {
                body.u32(28)
                for word in p.guid { body.u32(Int(word)) }
                body.u32(p.offset); body.u32(p.size)
            }
        }
        body.close(at)
        // custom fields
        at = body.open()
        body.u8(0); body.u32(1)
        body.string("CloudSaveFolder"); body.string(saveFolder)
        body.close(at)

        let raw = body.data, packed = try deflate(raw)
        var m = EpicWriter()
        m.u32(0x44BEC00C); m.u32(41); m.u32(raw.count); m.u32(packed.count)
        m.raw(EpicSHA1.hash(raw)); m.u8(1); m.u32(featureLevel)
        m.raw(packed)

        let manifestPath = "manifests/\(version).manifest"
        var uploads = built.map { (path: $0.path, data: $0.file) }
        uploads.append((path: manifestPath, data: m.data))
        return Package(manifestPath: manifestPath, buildVersion: version, uploads: uploads, fileCount: items.count)
    }
}

// MARK: - Where a game keeps its saves

/// What the game's catalog entry says about its cloud saves (customAttributes).
struct EpicSaveConfig: Codable, Equatable {
    var folder: String
    var include: [String]
    var exclude: [String]

    /// customAttributes of a catalog item: CloudSaveFolder, CloudIncludeList, CloudExcludeList.
    static func from(customAttributes: [String: Any]?) -> EpicSaveConfig? {
        func value(_ key: String) -> String? { ((customAttributes?[key] as? [String: Any])?["value"] as? String) }
        guard let folder = value("CloudSaveFolder"), !folder.isEmpty else { return nil }
        func list(_ s: String?) -> [String] {
            (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return EpicSaveConfig(folder: folder, include: list(value("CloudIncludeList")), exclude: list(value("CloudExcludeList")))
    }

    /// utils/savegame_helper.py _filename_matches.
    static func matches(_ name: String, _ patterns: [String]) -> Bool {
        for pattern in patterns {
            if pattern.hasSuffix("/"), name.hasPrefix(pattern) { return true }
            if name.hasSuffix(pattern) { return true }
            if fnmatch(pattern, name, 0) == 0 { return true }
        }
        return false
    }
    func includes(_ relative: String) -> Bool {
        if !include.isEmpty { return Self.matches(relative, include) }
        if !exclude.isEmpty { return !Self.matches(relative, exclude) }
        return true
    }
}

/// The Windows folders of Madeira's Wine prefix that Epic's save-folder variables stand for.
struct EpicSavePaths {
    var drive: URL            // drive_c
    var userFolder: URL       // drive_c/users/<name>
    var installFolder: URL    // the game's install folder
    var accountID: String

    /// core.py get_save_path for a Wine prefix. nil: an unknown variable, no base folder, or
    /// a path that would leave drive_c.
    func resolve(_ template: String) -> URL? {
        let parts = template.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return nil }
        let base: URL
        switch first.lowercased() {
        case "{installdir}": base = installFolder
        case "{appdata}": base = userFolder.appendingPathComponent("AppData/Local", isDirectory: true)
        case "{userdir}": base = userFolder.appendingPathComponent("Documents", isDirectory: true)
        case "{userprofile}": base = userFolder
        case "{usersavedgames}": base = userFolder.appendingPathComponent("Saved Games", isDirectory: true)
        default: return nil
        }
        var stack = base.standardizedFileURL.pathComponents
        for part in parts.dropFirst() {
            switch part.lowercased() {
            case ".": continue
            case "..": if stack.count > 1 { stack.removeLast() }
            case "{epicid}": stack.append(accountID)
            default:
                if part.hasPrefix("{") && part.hasSuffix("}") { return nil }
                if part.contains(":") || part.utf8.count > 255 { return nil }
                stack.append(part)
            }
        }
        let root = drive.standardizedFileURL.pathComponents
        guard stack.count > root.count, Array(stack.prefix(root.count)) == root else { return nil }
        return Self.resolveCase(base: drive, parts: Array(stack.dropFirst(root.count)))
    }

    /// Wine ignores case and iOS does not: follow each part by case-insensitive match.
    static func resolveCase(base: URL, parts: [String]) -> URL {
        var url = base
        for (index, part) in parts.enumerated() {
            let exact = url.appendingPathComponent(part, isDirectory: index < parts.count - 1)
            if FileManager.default.fileExists(atPath: exact.path) { url = exact; continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if let match = names.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                url = url.appendingPathComponent(match, isDirectory: index < parts.count - 1)
            } else {
                url = exact
            }
        }
        return url
    }
}

// MARK: - The device's side

struct EpicDeviceSave: Equatable {
    var path: String          // relative, forward slashes
    var size: UInt64
    var sha: String           // hex SHA-1
    var modified: Date
    var url: URL
}

enum EpicSaveScan {
    static let maximumFiles = 2000
    static let maximumFileSize: UInt64 = 64 * 1024 * 1024
    static let maximumTotal: UInt64 = 128 * 1024 * 1024

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// The regular files under `folder` that pass the game's filters. A missing folder is an
    /// empty save. Symlinks are never followed.
    static func scan(_ folder: URL, config: EpicSaveConfig) throws -> [EpicDeviceSave] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        let root = folder.standardizedFileURL.path
        var result = [EpicDeviceSave](), total: UInt64 = 0
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(root + "/") else { continue }
            let relative = String(full.dropFirst(root.count + 1))
            guard config.includes(relative) else { continue }
            let size = UInt64(values.fileSize ?? 0)
            guard size <= maximumFileSize else { throw EpicContentError.invalid("A save file is larger than 64 MB.") }
            total += size
            guard result.count < maximumFiles, total <= maximumTotal else {
                throw EpicContentError.invalid("This game's saves are too large to sync (over 2000 files or 128 MB).")
            }
            result.append(EpicDeviceSave(path: relative, size: size, sha: hex(try EpicSHA1.file(url)),
                                         modified: values.contentModificationDate ?? Date(timeIntervalSince1970: 0), url: url))
        }
        return result.sorted { $0.path.lowercased() < $1.path.lowercased() }
    }
}

// MARK: - The decision

/// What was identical the last time the device and the cloud were synced.
struct EpicSaveBaseline: Codable, Equatable {
    var device: [String: String]   // path -> SHA-1 on the device after that sync
    var cloud: [String: String]    // path -> SHA-1 in the cloud snapshot after it
    var snapshot: String?          // that snapshot's build version
}

enum EpicSaveVerdict: Equatable {
    case empty        // no saves on either side
    case inSync
    case download     // the cloud changed, this device did not
    case upload       // this device changed, the cloud did not
    case conflict     // both changed, or they differ and nothing says which is newer
}

enum EpicSavePlanner {
    /// `cloud` nil: the account has no save snapshot for the game. Maps are path -> SHA-1.
    static func decide(device: [String: String], cloud: [String: String]?, baseline: EpicSaveBaseline?) -> EpicSaveVerdict {
        let cloudMap = cloud ?? [:]
        if device.isEmpty && cloudMap.isEmpty { return .empty }
        if device == cloudMap { return .inSync }
        guard let baseline else {
            if device.isEmpty { return .download }
            if cloudMap.isEmpty { return .upload }
            return .conflict
        }
        let deviceChanged = device != baseline.device
        // Nothing in the cloud any more (deleted elsewhere): never fetched back, and not a conflict.
        if cloudMap.isEmpty { return deviceChanged ? .upload : .inSync }
        switch (deviceChanged, cloudMap != baseline.cloud) {
        case (false, false): return .inSync
        case (false, true): return .download
        case (true, false): return .upload
        case (true, true): return .conflict
        }
    }
}

// MARK: - The cloud's side

struct EpicCloudObject: Equatable {
    var path: String
    var readLink: String?
    var writeLink: String?
}

/// The datastorage service, or a stand-in for tests.
protocol EpicCloudTransport {
    /// Every file the account has for the game (keys are full remote paths).
    func list(app: String) async throws -> [EpicCloudObject]
    func read(_ object: EpicCloudObject) async throws -> Data
    /// Upload targets for the given paths relative to the game's folder.
    func writeTargets(app: String, paths: [String]) async throws -> [EpicCloudObject]
    func write(_ object: EpicCloudObject, data: Data) async throws
}

/// api/egs.py get_user_cloud_saves / create_game_cloud_saves over URLSession.
struct EpicCloudHTTP: EpicCloudTransport {
    static let host = "datastorage-public-service-liveegs.live.use1a.on.epicgames.com"
    static let userAgent = "UELauncher/11.0.1-14907503+++Portal+Release-Live Windows/10.0.19041.1.256.64bit"
    var token: String
    var accountID: String
    static let sizeLimit = 128 * 1024 * 1024

    private func decode(_ data: Data) throws -> [EpicCloudObject] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [String: Any] else { throw EpicContentError.invalid("Unexpected answer from Epic's save service.") }
        return files.keys.sorted().map { key in
            let entry = files[key] as? [String: Any]
            return EpicCloudObject(path: key, readLink: entry?["readLink"] as? String, writeLink: entry?["writeLink"] as? String)
        }
    }
    private func request(_ url: URL, method: String = "GET", json: Any? = nil) async throws -> Data {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 30
        r.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await URLSession.shared.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw EpicContentError.httpStatus(status) }
        return data
    }
    private func savesyncURL(_ app: String) throws -> URL {
        guard let url = URL(string: "https://\(Self.host)/api/v1/access/egstore/savesync/\(accountID)/\(app)/") else {
            throw EpicContentError.invalid("Invalid Epic save URL.")
        }
        return url
    }
    func list(app: String) async throws -> [EpicCloudObject] {
        try decode(try await request(try savesyncURL(app)))
    }
    func read(_ object: EpicCloudObject) async throws -> Data {
        guard let link = object.readLink, let url = URL(string: link), url.scheme == "https" else {
            throw EpicContentError.invalid("Epic gave no download link for a save file.")
        }
        // A pre-signed link: no Authorization header.
        return try await EpicManifest.download(URLRequest(url: url), limit: Self.sizeLimit)
    }
    func writeTargets(app: String, paths: [String]) async throws -> [EpicCloudObject] {
        try decode(try await request(try savesyncURL(app), method: "POST", json: ["files": paths]))
    }
    func write(_ object: EpicCloudObject, data: Data) async throws {
        guard let link = object.writeLink, let url = URL(string: link), url.scheme == "https" else {
            throw EpicContentError.invalid("Epic gave no upload link for a save file.")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "PUT"
        r.timeoutInterval = 60
        let (_, response) = try await URLSession.shared.upload(for: r, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw EpicContentError.httpStatus(status) }
    }
}

/// The newest snapshot the cloud holds for a game.
struct EpicCloudSnapshot {
    var buildVersion: String
    var manifest: EpicManifest
    var prefix: String            // remote folder of the snapshot's files, before "manifests/"
    var files: [String: String]   // path -> SHA-1 hex
    var sizes: [String: UInt64]
    var date: Date?
}

struct EpicDownloadResult { var files: Int; var backedUp: Int }

enum EpicCloudSaves {
    static func date(ofBuildVersion version: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy.MM.dd-HH.mm.ss"
        return f.date(from: version)
    }

    /// The remote folder and name of a manifest object, or nil for any other file.
    static func manifestName(_ path: String) -> (prefix: String, version: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard let at = parts.lastIndex(of: "manifests"), at == parts.count - 2, parts[at + 1].hasSuffix(".manifest") else { return nil }
        return (parts[..<at].joined(separator: "/"), String(parts[at + 1].dropLast(".manifest".count)))
    }

    /// The newest snapshot (named by its build version, which sorts as a date), or nil when the
    /// account has none. A manifest that cannot be read is an error, not "no save".
    static func latest(app: String, transport: EpicCloudTransport) async throws -> (snapshot: EpicCloudSnapshot, all: [EpicCloudObject])? {
        let all = try await transport.list(app: app)
        let manifests = all.compactMap { object -> (EpicCloudObject, String, String)? in
            manifestName(object.path).map { (object, $0.prefix, $0.version) }
        }.sorted { $0.2 < $1.2 }
        guard let newest = manifests.last else { return nil }
        let manifest = try EpicManifest.parse(try await transport.read(newest.0))
        var files = [String: String](), sizes = [String: UInt64]()
        for file in manifest.files {
            files[file.filename] = EpicSaveScan.hex(file.sha)
            sizes[file.filename] = file.size
        }
        let snapshot = EpicCloudSnapshot(buildVersion: newest.2, manifest: manifest, prefix: newest.1, files: files, sizes: sizes,
                                         date: date(ofBuildVersion: newest.2))
        return (snapshot, all)
    }

    /// Writes a snapshot over `folder`. Everything is downloaded, assembled and checked in memory
    /// first; only then are files written (each atomically), the ones they replace copied to
    /// `backup` before. Files the snapshot does not name are left alone.
    static func download(_ snapshot: EpicCloudSnapshot, all: [EpicCloudObject], into folder: URL, backup: URL,
                         transport: EpicCloudTransport) async throws -> EpicDownloadResult {
        let manifest = snapshot.manifest
        let level = manifest.meta.featureLevel
        var byPath = [String: EpicCloudObject]()
        for object in all { byPath[object.path] = object }
        var chunkData = [String: Data]()
        var needed = Set<String>()
        for file in manifest.files { for part in file.parts { needed.insert(part.guid) } }
        for chunk in manifest.chunks where needed.contains(chunk.guid) {
            let remote = snapshot.prefix + "/" + (try chunk.path(featureLevel: level))
            guard let object = byPath[remote] else { throw EpicContentError.invalid("A save chunk is missing in Epic's cloud; nothing was changed.") }
            let raw = try await transport.read(object)
            // Chunks written by Epic's launcher may not match the manifest's size fields exactly;
            // the file hashes below are the check that counts.
            if let strict = try? EpicChunk.parse(raw, expected: chunk) {
                chunkData[chunk.guid] = strict
            } else {
                chunkData[chunk.guid] = try EpicChunk.parse(raw)
            }
        }
        var assembled = [(file: EpicManifest.File, data: Data)]()
        var total = 0
        for file in manifest.files {
            var data = Data()
            for part in file.parts {
                guard let chunk = chunkData[part.guid], part.offset >= 0, part.size >= 0, part.offset + part.size <= chunk.count else {
                    throw EpicContentError.invalid("A save file refers to missing data; nothing was changed.")
                }
                data.append(chunk.subdata(in: part.offset..<part.offset + part.size))
            }
            guard EpicSHA1.hash(data) == file.sha else { throw EpicContentError.invalid("A downloaded save file failed its check; nothing was changed.") }
            total += data.count
            guard total <= EpicSaveScan.maximumTotal else { throw EpicContentError.invalid("The cloud save is too large to sync.") }
            assembled.append((file, data))
        }
        let stamp = snapshot.date ?? Date()
        var backedUp = 0
        for item in assembled {
            let parts = item.file.filename.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.contains(":") }) else {
                throw EpicContentError.invalid("The cloud save names a file outside the save folder; nothing was changed.")
            }
            let target = EpicSavePaths.resolveCase(base: folder, parts: parts)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                if (try? EpicSHA1.file(target)) == item.file.sha { continue }   // identical already
                let saved = parts.reduce(backup) { $0.appendingPathComponent($1) }
                try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: saved)
                try FileManager.default.copyItem(at: target, to: saved)
                backedUp += 1
            }
            try item.data.write(to: target, options: .atomic)
            try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: target.path)
        }
        return EpicDownloadResult(files: assembled.count, backedUp: backedUp)
    }

    /// Uploads the device's files as a new snapshot (chunks first, then its manifest).
    static func upload(_ saves: [EpicDeviceSave], app: String, accountID: String, config: EpicSaveConfig,
                       transport: EpicCloudTransport, date: Date = Date()) async throws -> (version: String, files: Int) {
        guard !saves.isEmpty else { throw EpicContentError.invalid("There are no saves to upload.") }
        var files = [EpicSaveWriter.SaveFile]()
        for save in saves {
            let data = try Data(contentsOf: save.url)
            guard EpicSaveScan.hex(EpicSHA1.hash(data)) == save.sha else {
                throw EpicContentError.invalid("A save file changed while it was being read. Try again when the game is not writing.")
            }
            files.append(EpicSaveWriter.SaveFile(path: save.path, data: data))
        }
        let package = try EpicSaveWriter.package(files: files, appName: app, accountID: accountID, saveFolder: config.folder, date: date)
        let targets = try await transport.writeTargets(app: app, paths: package.uploads.map(\.path))
        var byPath = [String: EpicCloudObject]()
        for target in targets { byPath[target.path] = target }
        for upload in package.uploads where byPath[upload.path] == nil {
            throw EpicContentError.invalid("Epic gave no upload target for \(upload.path).")
        }
        for upload in package.uploads { try await transport.write(byPath[upload.path]!, data: upload.data) }
        return (package.buildVersion, package.fileCount)
    }
}
