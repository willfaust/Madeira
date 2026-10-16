// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
// Ported from Legendary's models/manifest.py, json_manifest.py and api/egs.py.

import Foundation

struct EpicManifest {
    struct Meta {
        var featureLevel = 18
        var appName = "", buildVersion = "", launchExe = "", launchCommand = ""
        var prereqIDs: [String] = []
        var prereqName = "", prereqPath = "", prereqArgs = ""
    }
    struct Chunk {
        var guid = ""
        var hash: UInt64 = 0
        var sha = Data()
        var group = 0, windowSize = 0, fileSize = 0
        var secret = Data(repeating: 0, count: 16)

        func path(featureLevel: Int) throws -> String {
            if featureLevel >= 22 {
                guard secret.allSatisfy({ $0 == 0 }) else { throw EpicContentError.invalid("Encrypted Epic chunks need a content secret.") }
                func base64(_ data: Data) -> String {
                    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                }
                let words = try EpicManifest.hex(guid, count: 16)
                var littleGUID = Data()
                for i in stride(from: 0, to: 16, by: 4) { littleGUID.append(contentsOf: words[i..<i + 4].reversed()) }
                let littleHash = Data((0..<8).map { UInt8(truncatingIfNeeded: hash >> ($0 * 8)) })
                return "ChunksV5/plain/\(String(format: "%02d", group))/\(base64(littleHash))_\(base64(littleGUID)).chunk"
            }
            let directory = featureLevel >= 15 ? "ChunksV4" : featureLevel >= 6 ? "ChunksV3" : featureLevel >= 3 ? "ChunksV2" : "Chunks"
            return String(format: "%@/%02d/%016llX_%@.chunk", directory, group, hash, guid)
        }
    }
    struct Part { var guid: String; var offset: Int; var size: Int }
    struct File {
        var filename = "", symlink = ""
        var sha = Data()
        var flags: UInt64 = 0
        var tags: [String] = []
        var parts: [Part] = []
        var size: UInt64 { parts.reduce(0) { $0 + UInt64($1.size) } }
    }
    var meta = Meta()
    var chunks: [Chunk] = []
    var files: [File] = []
    var customFields: [String: String] = [:]
    static let maximumSize = 128 * 1024 * 1024

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumSize else { throw EpicContentError.invalid("Epic manifest is too large.") }
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 123 { return try json(data) }
        var header = EpicReader(data: data)
        guard try header.u32() == 0x44BEC00C else { throw EpicContentError.invalid("Invalid Epic manifest magic.") }
        let headerSize = try header.u32(), size = try header.u32(), compressedSize = try header.u32()
        let sha = try header.bytes(20), stored = try header.number(1), version = try header.u32()
        guard stored & ~1 == 0 else { throw EpicContentError.invalid("Encrypted Epic manifests are not supported.") }
        if version >= 22 { _ = try header.bytes(32) }
        guard headerSize >= header.position, headerSize <= data.count, compressedSize == data.count - headerSize else {
            throw EpicContentError.invalid("Invalid Epic manifest size.")
        }
        _ = try header.bytes(headerSize - header.position)
        let payload = try header.bytes(compressedSize)
        let body = stored & 1 != 0 ? try EpicChunk.inflate(payload, size: size, limit: maximumSize) : payload
        guard body.count == size, EpicSHA1.hash(body) == sha else { throw EpicContentError.invalid("Epic manifest SHA-1 mismatch.") }
        var r = EpicReader(data: body), result = Self()
        var m = try r.section()
        let metaVersion = try m.number(1)
        result.meta.featureLevel = try m.u32()
        guard try m.number(1) == 0 else { throw EpicContentError.invalid("Legacy file-data manifests are not supported.") }
        _ = try m.u32()
        result.meta.appName = try m.string(); result.meta.buildVersion = try m.string()
        result.meta.launchExe = try m.string(); result.meta.launchCommand = try m.string()
        result.meta.prereqIDs = try m.strings()
        result.meta.prereqName = try m.string(); result.meta.prereqPath = try m.string(); result.meta.prereqArgs = try m.string()
        if metaVersion >= 1 { _ = try m.string() }
        if metaVersion >= 2 { _ = try m.string(); _ = try m.string() }

        // These lists are columnar: all GUIDs, then all hashes, rather than one record at a time.
        var c = try r.section()
        _ = try c.number(1)
        let chunkCount = try c.boundedCount()
        guard chunkCount <= c.data.count / 57 else { throw EpicContentError.invalid("Invalid Epic chunk count.") }
        result.chunks = [Chunk](repeating: Chunk(), count: chunkCount)
        for i in 0..<chunkCount { result.chunks[i].guid = try c.guid() }
        for i in 0..<chunkCount { result.chunks[i].hash = try c.number(8) }
        for i in 0..<chunkCount { result.chunks[i].sha = try c.bytes(20) }
        for i in 0..<chunkCount { result.chunks[i].group = Int(try c.number(1)) }
        for i in 0..<chunkCount { result.chunks[i].windowSize = try c.u32() }
        for i in 0..<chunkCount {
            let size = try c.number(8)
            guard size <= UInt64(Int.max) else { throw EpicContentError.invalid("Invalid Epic chunk file size.") }
            result.chunks[i].fileSize = Int(size)
        }
        if result.meta.featureLevel >= 22 {
            for i in 0..<chunkCount { result.chunks[i].secret = try c.bytes(16) }
            _ = try c.bytes(chunkCount * 20)
        }
        var f = try r.section()
        let fileVersion = try f.number(1), fileCount = try f.boundedCount()
        guard fileCount <= f.data.count / 37 else { throw EpicContentError.invalid("Invalid Epic file count.") }
        result.files = [File](repeating: File(), count: fileCount)
        for i in 0..<fileCount { result.files[i].filename = try f.string() }
        for i in 0..<fileCount { result.files[i].symlink = try f.string() }
        for i in 0..<fileCount { result.files[i].sha = try f.bytes(20) }
        for i in 0..<fileCount { result.files[i].flags = try f.number(1) }
        for i in 0..<fileCount { result.files[i].tags = try f.strings() }
        for i in 0..<fileCount {
            let count = try f.boundedCount()
            for _ in 0..<count {
                var p = try f.section()
                result.files[i].parts.append(Part(guid: try p.guid(), offset: try p.u32(), size: try p.u32()))
            }
        }
        if fileVersion >= 1 {
            for _ in 0..<fileCount { if try f.u32() != 0 { _ = try f.bytes(16) } }
            for _ in 0..<fileCount { _ = try f.string() }
        }
        if fileVersion >= 2 { _ = try f.bytes(fileCount * 32) }
        var fields = try r.section()
        _ = try fields.number(1)
        let fieldCount = try fields.boundedCount()
        let keys = try (0..<fieldCount).map { _ in try fields.string() }
        for key in keys { result.customFields[key] = try fields.string() }
        return result
    }

    static func hex(_ string: String, count: Int) throws -> Data {
        let chars = Array(string.utf8)
        guard chars.count == count * 2 else { throw EpicContentError.invalid("Invalid Epic hexadecimal field.") }
        var result = Data()
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else {
                throw EpicContentError.invalid("Invalid Epic hexadecimal field.")
            }
            result.append(byte)
        }
        return result
    }
    private static func blob(_ value: Any?) throws -> Data {
        guard let value = value as? String, value.utf8.count % 3 == 0 else { throw EpicContentError.invalid("Invalid Epic JSON blob.") }
        let chars = Array(value.utf8)
        var data = Data()
        for i in stride(from: 0, to: chars.count, by: 3) {
            guard let byte = UInt8(String(decoding: chars[i..<i + 3], as: UTF8.self)) else {
                throw EpicContentError.invalid("Invalid Epic JSON byte.")
            }
            data.append(byte)
        }
        return data
    }
    private static func number(_ value: Any?) throws -> UInt64 {
        let data = try blob(value)
        guard data.count <= 8 else { throw EpicContentError.invalid("Invalid Epic JSON number.") }
        var r = EpicReader(data: data)
        return try r.number(data.count)
    }
    private static func json(_ data: Data) throws -> Self {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sizes = j["ChunkFilesizeList"] as? [String: String],
              let hashes = j["ChunkHashList"] as? [String: String],
              let shas = j["ChunkShaList"] as? [String: String],
              let groups = j["DataGroupList"] as? [String: String],
              let files = j["FileManifestList"] as? [[String: Any]], j["bIsFileData"] as? Bool != true else {
            throw EpicContentError.invalid("Invalid or unsupported Epic JSON manifest.")
        }
        func integer(_ value: Any?) throws -> Int {
            let n = try number(value)
            guard n <= UInt64(Int.max) else { throw EpicContentError.invalid("Invalid Epic JSON size.") }
            return Int(n)
        }
        var result = Self()
        result.meta.featureLevel = try integer(j["ManifestFileVersion"] ?? "013000000000")
        result.meta.appName = j["AppNameString"] as? String ?? ""
        result.meta.buildVersion = j["BuildVersionString"] as? String ?? ""
        result.meta.launchExe = j["LaunchExeString"] as? String ?? ""
        result.meta.launchCommand = j["LaunchCommand"] as? String ?? ""
        result.meta.prereqIDs = j["PrereqIds"] as? [String] ?? []
        result.meta.prereqName = j["PrereqName"] as? String ?? ""
        result.meta.prereqPath = j["PrereqPath"] as? String ?? ""
        result.meta.prereqArgs = j["PrereqArgs"] as? String ?? ""
        for guid in sizes.keys.sorted() {
            _ = try hex(guid, count: 16)
            result.chunks.append(Chunk(guid: guid.uppercased(), hash: try number(hashes[guid]),
                                       sha: try hex(shas[guid] ?? "", count: 20), group: try integer(groups[guid]),
                                       windowSize: 1024 * 1024, fileSize: try integer(sizes[guid])))
        }
        for item in files {
            guard let name = item["Filename"] as? String, let parts = item["FileChunkParts"] as? [[String: String]] else {
                throw EpicContentError.invalid("Invalid Epic JSON file.")
            }
            var file = File(filename: name, sha: try blob(item["FileHash"]))
            guard file.sha.count == 20 else { throw EpicContentError.invalid("Invalid Epic file SHA-1.") }
            file.tags = item["InstallTags"] as? [String] ?? []
            file.flags = (item["bIsReadOnly"] as? Bool == true ? 1 : 0) |
                (item["bIsCompressed"] as? Bool == true ? 2 : 0) | (item["bIsUnixExecutable"] as? Bool == true ? 4 : 0)
            for part in parts {
                let guid = part["Guid"] ?? ""
                _ = try hex(guid, count: 16)
                file.parts.append(Part(guid: guid.uppercased(), offset: try integer(part["Offset"]), size: try integer(part["Size"])))
            }
            result.files.append(file)
        }
        result.customFields = j["CustomFields"] as? [String: String] ?? [:]
        return result
    }

    private static let launcherHost = "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/public/assets"

    private static func launcherRequest(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("UELauncher/11.0.1-14907503+++Portal+Release-Live Windows/10.0.19041.1.256.64bit", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The library can list an entitlement under an app name that has no Windows
    /// build (Dead Cells: a hex id, 404). Legendary takes app names from the Windows
    /// asset list instead; look the game up there by namespace and catalog item.
    private static func windowsAppName(namespace: String, catalogItemID: String, token: String) async throws -> String? {
        var components = URLComponents(string: launcherHost + "/Windows")!
        components.queryItems = [URLQueryItem(name: "label", value: "Live")]
        let data = try await download(launcherRequest(components.url!, token: token), limit: 16 * 1024 * 1024)
        let assets = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? [])
            .filter { $0["namespace"] as? String == namespace }
        let match = assets.first { $0["catalogItemId"] as? String == catalogItemID } ?? (assets.count == 1 ? assets[0] : nil)
        return match?["appName"] as? String
    }

    static func fetch(namespace: String, catalogItemID: String, appName: String, token: String) async throws -> (Self, URL) {
        func assetURL(_ app: String) -> URL {
            var url = URL(string: launcherHost + "/v2/platform/Windows/namespace")!
            for part in [namespace, "catalogItem", catalogItemID, "app", app, "label", "Live"] { url.appendPathComponent(part) }
            return url
        }
        let data: Data
        do {
            data = try await download(launcherRequest(assetURL(appName), token: token), limit: 4 * 1024 * 1024)
        } catch EpicContentError.httpStatus(404) {
            guard let windowsName = try await windowsAppName(namespace: namespace, catalogItemID: catalogItemID, token: token),
                  windowsName != appName
            else { throw EpicContentError.invalid("Epic has no Windows version of this game for your account.") }
            data = try await download(launcherRequest(assetURL(windowsName), token: token), limit: 4 * 1024 * 1024)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let element = (json["elements"] as? [[String: Any]])?.first,
              let manifests = element["manifests"] as? [[String: Any]], !manifests.isEmpty
        else { throw EpicContentError.invalid("Epic did not return a Windows manifest.") }
        // Epic lists the same manifest on several CDNs, each with its own signed query.
        // One often refuses a given game (403/404): try them in order, as Legendary
        // does, and keep the base of the one that answered for the chunks.
        var lastError: Error = EpicContentError.invalid("Epic did not return a Windows manifest.")
        for manifest in manifests {
            guard let uri = manifest["uri"] as? String, var components = URLComponents(string: uri),
                  let original = components.url else { continue }
            if let params = manifest["queryParams"] as? [[String: String]] {
                components.queryItems = (components.queryItems ?? []) + params.compactMap { param in
                    param["name"].map { URLQueryItem(name: $0, value: param["value"]) }
                }
            }
            guard let manifestURL = components.url else { continue }
            let bytes: Data
            do { bytes = try await download(URLRequest(url: manifestURL), limit: maximumSize) }
            catch { lastError = error; continue }
            if let hash = element["hash"] as? String, EpicSHA1.hash(bytes) != (try hex(hash, count: 20)) {
                lastError = EpicContentError.invalid("Epic CDN manifest SHA-1 mismatch.")
                continue
            }
            var base = URLComponents(url: original.deletingLastPathComponent(), resolvingAgainstBaseURL: false)!
            base.query = nil; base.fragment = nil
            return (try parse(bytes), base.url!)
        }
        throw lastError
    }

    /// URLSession spools responses to disk so a bad CDN response cannot fill RAM.
    static func download(_ request: URLRequest, limit: Int) async throws -> Data {
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw EpicContentError.httpStatus(status) }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw EpicContentError.invalid("Epic download exceeds the size limit.") }
        return try Data(contentsOf: file)
    }
}
