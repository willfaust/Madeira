// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Akshay CM
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Compression
import CryptoKit
import Foundation

// Epic's content formats (docs/EPIC_GAMES.md, "How it works"): the binary build
// manifest (header, metadata, chunk list, file list, custom fields and, from
// feature level 24, an encrypted block with the file names), the older JSON
// manifest, and the chunk container the CDN serves. Little-endian throughout. Everything here is pure
// Foundation, CryptoKit and Compression, so the host test compiles it as is.
// Hostile input throws; it never traps.

enum EpicFormatError: LocalizedError, Equatable {
    case truncated
    case badMagic(String)
    case checksum(String)
    case decompress(String)
    case missingKey
    case decrypt(String)
    case unsupported(String)
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .truncated: return "Epic sent incomplete data."
        case .badMagic(let what): return "Epic sent data that is not a \(what)."
        case .checksum(let what): return "A downloaded \(what) failed its checksum."
        case .decompress(let what): return "A downloaded \(what) could not be decompressed."
        case .missingKey: return "Epic did not send the key for this encrypted game."
        case .decrypt(let what): return "A downloaded \(what) could not be decrypted."
        case .unsupported(let what): return "This game uses a format Madeira cannot read yet (\(what))."
        case .unsafePath: return "This game's file list names a path outside its install folder."
        }
    }
}

/// A 128-bit GUID as Epic stores it: four little-endian 32-bit words.
struct EpicGUID: Hashable, Sendable, Codable {
    var a: UInt32, b: UInt32, c: UInt32, d: UInt32
    var hex: String { String(format: "%08X%08X%08X%08X", a, b, c, d) }
    var isZero: Bool { a == 0 && b == 0 && c == 0 && d == 0 }
    /// The words in file order (little-endian), as the v22+ chunk paths encode them.
    var bytes: Data {
        var data = Data()
        for word in [a, b, c, d] { withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }
}

/// A bounds-checked little-endian reader.
struct EpicReader {
    private let bytes: [UInt8]
    private(set) var offset = 0
    init(_ data: Data) { bytes = [UInt8](data) }
    var count: Int { bytes.count }
    var remaining: Int { bytes.count - offset }

    mutating func seek(_ position: Int) throws {
        guard position >= 0, position <= bytes.count else { throw EpicFormatError.truncated }
        offset = position
    }
    mutating func skip(_ n: Int) throws { try seek(offset + n) }
    mutating func data(_ n: Int) throws -> Data {
        guard n >= 0, n <= remaining else { throw EpicFormatError.truncated }
        defer { offset += n }
        return Data(bytes[offset..<offset + n])
    }
    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw EpicFormatError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }
    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw EpicFormatError.truncated }
        defer { offset += 4 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func u64() throws -> UInt64 {
        let low = UInt64(try u32()), high = UInt64(try u32())
        return low | high << 32
    }
    mutating func guid() throws -> EpicGUID { EpicGUID(a: try u32(), b: try u32(), c: try u32(), d: try u32()) }
    /// A count of `elementSize`-byte items that must still fit in the input.
    mutating func count(elementSize: Int) throws -> Int {
        let n = Int(try u32())
        guard n <= remaining / max(1, elementSize) else { throw EpicFormatError.truncated }
        return n
    }
    /// Unreal's FString: a signed length with the terminator; negative is UTF-16LE.
    mutating func fstring() throws -> String {
        let length = Int(try i32())
        if length == 0 { return "" }
        if length < 0 {
            let units = -length
            guard units <= remaining / 2 else { throw EpicFormatError.truncated }
            let raw = try data(units * 2)
            var codeUnits = [UInt16](repeating: 0, count: units)
            raw.withUnsafeBytes { buffer in
                for i in 0..<units { codeUnits[i] = UInt16(buffer[2 * i]) | UInt16(buffer[2 * i + 1]) << 8 }
            }
            if codeUnits.last == 0 { codeUnits.removeLast() }
            return String(decoding: codeUnits, as: UTF16.self)
        }
        guard length <= remaining else { throw EpicFormatError.truncated }
        var raw = try data(length)
        if raw.last == 0 { raw.removeLast() }
        return String(decoding: raw, as: UTF8.self)
    }
}

enum EpicCodec {
    /// A zlib stream (RFC 1950) of known decompressed size. Compression's ZLIB
    /// algorithm is raw DEFLATE, so the two-byte header is skipped here.
    static func inflate(_ data: Data, size: Int, what: String) throws -> Data {
        guard data.count >= 2, data[data.startIndex] & 0x0F == 8,
              (UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])) % 31 == 0,
              data[data.startIndex + 1] & 0x20 == 0, size >= 0, size <= 512 << 20 else {
            throw EpicFormatError.decompress(what)
        }
        if size == 0 { return Data() }
        let body = data.dropFirst(2)
        var output = Data(count: size + 1)
        let written = output.withUnsafeMutableBytes { out -> Int in
            body.withUnsafeBytes { input -> Int in
                guard let dst = out.bindMemory(to: UInt8.self).baseAddress,
                      let src = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, size + 1, src, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw EpicFormatError.decompress(what) }
        output.count = size
        return output
    }

    static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }

    static func open(_ ciphertext: Data, key: Data, nonce: Data, tag: Data, what: String) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw EpicFormatError.decrypt(what)
        }
    }

    /// A key from the manifest API's `secrets` (GUID in upper hex → key in hex).
    static func key(_ guid: EpicGUID, in secrets: [String: String]) throws -> Data {
        let wanted = guid.hex
        guard let hex = secrets[wanted] ?? secrets.first(where: { $0.key.uppercased() == wanted })?.value,
              let key = Data(hex: hex), [16, 24, 32].contains(key.count) else { throw EpicFormatError.missingKey }
        return key
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Data {
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let high = nibble(chars[i]), let low = nibble(chars[i + 1]) else { return nil }
            out.append(high << 4 | low)
            i += 2
        }
        self = out
    }
    var epicHex: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Manifest

struct EpicChunkInfo: Sendable {
    var guid: EpicGUID
    var hash: UInt64
    var sha1: Data
    var group: UInt8
    /// Decompressed size.
    var windowSize: UInt32
    /// Download size.
    var fileSize: Int64
    var secretGUID = EpicGUID(a: 0, b: 0, c: 0, d: 0)
    /// The CDN path below a base URL, which depends on the feature level.
    var path = ""
}

struct EpicChunkPart: Sendable {
    var guid: EpicGUID
    var offset: UInt32
    var size: UInt32
}

struct EpicFileEntry: Sendable {
    var name: String
    var symlinkTarget: String
    var sha1: Data
    var flags: UInt8
    var parts: [EpicChunkPart]
    var size: Int64 { parts.reduce(0) { $0 + Int64($1.size) } }
}

struct EpicManifest: Sendable {
    var featureLevel: UInt32
    var appName: String
    var buildVersion: String
    var launchExe: String
    var launchCommand: String
    var prerequisiteName: String
    var prerequisitePath: String
    var prerequisiteArgs: String
    var chunks: [EpicGUID: EpicChunkInfo]
    var files: [EpicFileEntry]

    static let magic: UInt32 = 0x44BE_C00C

    static func chunkFolder(_ level: UInt32) -> String {
        level >= 22 ? "ChunksV5" : level >= 15 ? "ChunksV4" : level >= 6 ? "ChunksV3" : level >= 3 ? "ChunksV2" : "Chunks"
    }

    /// The CDN folder of a chunk: CRC-32 of its GUID's bytes modulo 100. Epic's
    /// manifests store the same number; the path is computed from the GUID, as the
    /// CDN lays it out.
    static func group(of guid: EpicGUID) -> Int {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in guid.bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return Int(~crc % 100)
    }

    static func path(of chunk: EpicChunkInfo, level: UInt32) -> String {
        let group = String(format: "%02d", group(of: chunk.guid))
        if level >= 22 {
            var hash = chunk.hash.littleEndian
            let hashPart = EpicCodec.base64URL(Data(bytes: &hash, count: 8))
            let secret = chunk.secretGUID.isZero ? "plain" : EpicCodec.base64URL(chunk.secretGUID.bytes)
            return "\(chunkFolder(level))/\(secret)/\(group)/\(hashPart)_\(EpicCodec.base64URL(chunk.guid.bytes)).chunk"
        }
        return "\(chunkFolder(level))/\(group)/\(String(format: "%016llX", chunk.hash))_\(chunk.guid.hex).chunk"
    }

    /// Parses a manifest as served (and checked against the API's hash by the caller).
    static func parse(_ data: Data, secrets: [String: String] = [:]) throws -> EpicManifest {
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == UInt8(ascii: "{") { return try json(data) }
        var header = EpicReader(data)
        guard try header.u32() == magic else { throw EpicFormatError.badMagic("manifest") }
        let headerSize = Int(try header.u32())
        let sizeUncompressed = Int(try header.u32())
        _ = try header.u32()   // compressed size: the rest of the file
        let sha = try header.data(20)
        let storedAs = try header.u8()
        let version = try header.u32()
        var secretGUID = EpicGUID(a: 0, b: 0, c: 0, d: 0), tag = Data()
        if version >= 22 { secretGUID = try header.guid(); tag = try header.data(16) }
        try header.seek(headerSize)
        var body = try header.data(header.remaining)
        if storedAs & 1 != 0 {
            body = try EpicCodec.inflate(body, size: sizeUncompressed, what: "manifest")
            guard EpicCodec.sha1(body) == sha else { throw EpicFormatError.checksum("manifest") }
        }
        var r = EpicReader(body)

        // Metadata.
        let metaStart = r.offset
        let metaSize = Int(try r.u32())
        let dataVersion = try r.u8()
        let level = try r.u32()
        _ = try r.u8()        // is file data (pre-chunk manifests)
        _ = try r.u32()       // app id
        let appName = try r.fstring()
        let buildVersion = try r.fstring()
        var launchExe = try r.fstring()
        var launchCommand = try r.fstring()
        for _ in 0..<(try r.count(elementSize: 4)) { _ = try r.fstring() }   // prerequisite ids
        var prereqName = try r.fstring(), prereqPath = try r.fstring(), prereqArgs = try r.fstring()
        if dataVersion >= 1 { _ = try r.fstring() }                         // build id
        if dataVersion >= 2 { _ = try r.fstring(); _ = try r.fstring() }    // uninstall action
        try r.seek(metaStart + metaSize)

        // Chunk data list: one array per field.
        let cdlStart = r.offset
        let cdlSize = Int(try r.u32())
        _ = try r.u8()
        let chunkCount = try r.count(elementSize: 16 + 8 + 20 + 1 + 4 + 8)
        var chunks = [EpicChunkInfo]()
        chunks.reserveCapacity(chunkCount)
        for _ in 0..<chunkCount { chunks.append(EpicChunkInfo(guid: try r.guid(), hash: 0, sha1: Data(), group: 0, windowSize: 0, fileSize: 0)) }
        for i in 0..<chunkCount { chunks[i].hash = try r.u64() }
        for i in 0..<chunkCount { chunks[i].sha1 = try r.data(20) }
        for i in 0..<chunkCount { chunks[i].group = try r.u8() }
        for i in 0..<chunkCount { chunks[i].windowSize = try r.u32() }
        for i in 0..<chunkCount { chunks[i].fileSize = Int64(bitPattern: try r.u64()) }
        if level >= 22 {
            for i in 0..<chunkCount { chunks[i].secretGUID = try r.guid() }
            for _ in 0..<chunkCount { _ = try r.u32() }       // compressed window size
            for _ in 0..<chunkCount { _ = try r.data(16) }    // per-chunk tag (the chunk header repeats it)
        }
        try r.seek(cdlStart + cdlSize)

        // File manifest list.
        let fmlStart = r.offset
        let fmlSize = Int(try r.u32())
        let fmlVersion = try r.u8()
        let fileCount = try r.count(elementSize: 4 + 4 + 20 + 1 + 4 + 4)
        var files = [EpicFileEntry]()
        files.reserveCapacity(fileCount)
        for _ in 0..<fileCount { files.append(EpicFileEntry(name: try r.fstring(), symlinkTarget: "", sha1: Data(), flags: 0, parts: [])) }
        for i in 0..<fileCount { files[i].symlinkTarget = try r.fstring() }
        for i in 0..<fileCount { files[i].sha1 = try r.data(20) }
        for i in 0..<fileCount { files[i].flags = try r.u8() }
        for _ in 0..<fileCount { for _ in 0..<(try r.count(elementSize: 4)) { _ = try r.fstring() } }   // install tags
        for i in 0..<fileCount {
            let partCount = try r.count(elementSize: 28)
            files[i].parts.reserveCapacity(partCount)
            for _ in 0..<partCount {
                let start = r.offset
                let structSize = Int(try r.u32())
                guard structSize >= 28 else { throw EpicFormatError.truncated }
                let part = EpicChunkPart(guid: try r.guid(), offset: try r.u32(), size: try r.u32())
                try r.seek(start + structSize)
                files[i].parts.append(part)
            }
        }
        _ = fmlVersion   // MD5, MIME type and SHA-256 follow from version 1 and 2: not used
        try r.seek(fmlStart + fmlSize)

        // Custom fields.
        let cfStart = r.offset
        let cfSize = Int(try r.u32())
        try r.seek(cfStart + cfSize)

        // Feature level 24: launch data and file names, encrypted with the manifest's key.
        if storedAs & 2 != 0 {
            guard level >= 24 else { throw EpicFormatError.unsupported("encrypted manifest \(level)") }
            let key = try EpicCodec.key(secretGUID, in: secrets)
            let edStart = r.offset
            let edSize = Int(try r.u32())
            _ = try r.u8()
            _ = try r.u32()   // cipher block size
            let ehStart = r.offset
            let ehSize = Int(try r.u32())
            _ = try r.u32()
            let ehStoredAs = try r.u8()
            let plainSize = Int(try r.u32())
            _ = try r.u32()
            let iv = try r.data(Int(try r.count(elementSize: 1)))
            try r.seek(ehStart + ehSize)
            let ciphertext = try r.data(Int(try r.count(elementSize: 1)))
            try r.seek(edStart + edSize)
            var plain = try EpicCodec.open(ciphertext, key: key, nonce: iv, tag: tag, what: "manifest")
            if ehStoredAs & 1 != 0 { plain = try EpicCodec.inflate(plain, size: plainSize, what: "manifest") }
            var p = EpicReader(plain)
            launchExe = try p.fstring()
            launchCommand = try p.fstring()
            for _ in 0..<(try p.count(elementSize: 4)) { _ = try p.fstring() }
            prereqName = try p.fstring(); prereqPath = try p.fstring(); prereqArgs = try p.fstring()
            _ = try p.fstring(); _ = try p.fstring()
            for i in 0..<fileCount { files[i].name = try p.fstring(); files[i].symlinkTarget = try p.fstring() }
        }

        var byGUID = [EpicGUID: EpicChunkInfo](minimumCapacity: chunks.count)
        for var chunk in chunks {
            chunk.path = path(of: chunk, level: level)
            byGUID[chunk.guid] = chunk
        }
        return EpicManifest(featureLevel: level, appName: appName, buildVersion: buildVersion, launchExe: launchExe,
                            launchCommand: launchCommand, prerequisiteName: prereqName, prerequisitePath: prereqPath,
                            prerequisiteArgs: prereqArgs, chunks: byGUID, files: files)
    }

    // MARK: JSON manifests

    // Older builds have a JSON manifest: the same lists, keyed by chunk GUID, with
    // numbers and hashes as "blobs" (three decimal digits per byte, little-endian).
    // Ported from willfaust/Madeira#207 (iediot), after Legendary's json_manifest.py.

    /// A blob's bytes: "012255" is [12, 255].
    static func blob(_ value: Any?) throws -> Data {
        guard let text = value as? String else { throw EpicFormatError.badMagic("manifest") }
        let digits = Array(text.utf8)
        guard digits.count % 3 == 0, digits.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { throw EpicFormatError.badMagic("manifest") }
        var out = Data(capacity: digits.count / 3)
        for i in stride(from: 0, to: digits.count, by: 3) {
            let byte = Int(digits[i] - 48) * 100 + Int(digits[i + 1] - 48) * 10 + Int(digits[i + 2] - 48)
            guard byte <= 255 else { throw EpicFormatError.badMagic("manifest") }
            out.append(UInt8(byte))
        }
        return out
    }

    /// A blob read as a little-endian number of up to eight bytes.
    static func number(_ value: Any?) throws -> UInt64 {
        let bytes = try blob(value)
        guard bytes.count <= 8 else { throw EpicFormatError.badMagic("manifest") }
        return bytes.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// A GUID as the JSON keys write it: 32 hex digits, four big-endian words.
    static func guid(json text: String) throws -> EpicGUID {
        let chars = Array(text.utf8)
        guard chars.count == 32 else { throw EpicFormatError.badMagic("manifest") }
        var words = [UInt32]()
        for i in stride(from: 0, to: 32, by: 8) {
            guard let word = UInt32(String(decoding: chars[i..<i + 8], as: UTF8.self), radix: 16) else { throw EpicFormatError.badMagic("manifest") }
            words.append(word)
        }
        return EpicGUID(a: words[0], b: words[1], c: words[2], d: words[3])
    }

    static func json(_ data: Data) throws -> EpicManifest {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sizes = j["ChunkFilesizeList"] as? [String: Any], let hashes = j["ChunkHashList"] as? [String: Any],
              let groups = j["DataGroupList"] as? [String: Any], let fileList = j["FileManifestList"] as? [[String: Any]] else {
            throw EpicFormatError.badMagic("manifest")
        }
        if j["bIsFileData"] as? Bool == true { throw EpicFormatError.unsupported("file-data manifest") }
        let shas = j["ChunkShaList"] as? [String: Any] ?? [:]
        func size(_ value: Any?) throws -> UInt64 {
            let n = try number(value)
            guard n <= UInt64(Int32.max) else { throw EpicFormatError.badMagic("manifest") }
            return n
        }
        let level = UInt32(truncatingIfNeeded: try number(j["ManifestFileVersion"] ?? "013000000000"))

        var byGUID = [EpicGUID: EpicChunkInfo](minimumCapacity: sizes.count)
        for (key, fileSize) in sizes {
            let id = try guid(json: key)
            var sha = Data()
            if let hex = shas[key] as? String {
                guard let bytes = Data(hex: hex), bytes.count == 20 else { throw EpicFormatError.badMagic("manifest") }
                sha = bytes
            }
            // JSON manifests do not store a window size: chunks of this era are always 1 MiB.
            var chunk = EpicChunkInfo(guid: id, hash: try number(hashes[key]), sha1: sha,
                                      group: UInt8(truncatingIfNeeded: try number(groups[key])), windowSize: 1 << 20,
                                      fileSize: Int64(try size(fileSize)))
            chunk.path = path(of: chunk, level: level)
            byGUID[id] = chunk
        }

        var files = [EpicFileEntry]()
        files.reserveCapacity(fileList.count)
        for item in fileList {
            guard let name = item["Filename"] as? String, let parts = item["FileChunkParts"] as? [[String: Any]] else {
                throw EpicFormatError.badMagic("manifest")
            }
            let sha = try blob(item["FileHash"])
            guard sha.count == 20 else { throw EpicFormatError.badMagic("manifest") }
            let flags = (item["bIsReadOnly"] as? Bool == true ? 1 : 0) | (item["bIsCompressed"] as? Bool == true ? 2 : 0)
                | (item["bIsUnixExecutable"] as? Bool == true ? 4 : 0)
            var file = EpicFileEntry(name: name, symlinkTarget: "", sha1: sha, flags: UInt8(flags), parts: [])
            for part in parts {
                guard let key = part["Guid"] as? String else { throw EpicFormatError.badMagic("manifest") }
                file.parts.append(EpicChunkPart(guid: try guid(json: key), offset: UInt32(try size(part["Offset"])),
                                                size: UInt32(try size(part["Size"]))))
            }
            files.append(file)
        }
        func text(_ key: String) -> String { j[key] as? String ?? "" }
        return EpicManifest(featureLevel: level, appName: text("AppNameString"), buildVersion: text("BuildVersionString"),
                            launchExe: text("LaunchExeString"), launchCommand: text("LaunchCommand"),
                            prerequisiteName: text("PrereqName"), prerequisitePath: text("PrereqPath"),
                            prerequisiteArgs: text("PrereqArgs"), chunks: byGUID, files: files)
    }

    /// A path from the file list as folder components, or nil when it would leave the
    /// install folder (".." elements, a drive letter, control characters).
    static func components(_ name: String) -> [String]? {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        for part in parts {
            guard part != ".", part != "..", !part.contains(":"),
                  !part.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        }
        return parts
    }
}

// MARK: - Chunk

enum EpicChunk {
    static let magic: UInt32 = 0xB1FE_3AA2

    /// A chunk file from the CDN: checked against the manifest's entry, decrypted and
    /// decompressed. Returns the chunk's window (its decompressed bytes).
    static func decode(_ data: Data, expected: EpicChunkInfo, secrets: [String: String]) throws -> Data {
        var r = EpicReader(data)
        guard try r.u32() == magic else { throw EpicFormatError.badMagic("chunk") }
        let version = try r.u32()
        let headerSize = Int(try r.u32())
        let compressedSize = Int(try r.u32())
        let guid = try r.guid()
        _ = try r.u64()   // rolling hash
        let storedAs = try r.u8()
        var sha = Data(), size = Int(expected.windowSize)
        var secret = EpicGUID(a: 0, b: 0, c: 0, d: 0), tag = Data()
        if version >= 2 { sha = try r.data(20); _ = try r.u8() }
        if version >= 3 { size = Int(try r.u32()) }
        if version >= 4 { secret = try r.guid(); tag = try r.data(16) }
        guard guid == expected.guid else { throw EpicFormatError.checksum("chunk") }
        try r.seek(headerSize)
        var payload = try r.data(compressedSize)
        if storedAs & 2 != 0 {
            guard sha.count == 20 else { throw EpicFormatError.decrypt("chunk") }
            payload = try EpicCodec.open(payload, key: try EpicCodec.key(secret, in: secrets), nonce: sha.prefix(12), tag: tag, what: "chunk")
        }
        if storedAs & 1 != 0 { payload = try EpicCodec.inflate(payload, size: size, what: "chunk") }
        guard payload.count == Int(expected.windowSize) else { throw EpicFormatError.checksum("chunk") }
        if expected.sha1.contains(where: { $0 != 0 }), EpicCodec.sha1(payload) != expected.sha1 {
            throw EpicFormatError.checksum("chunk")
        }
        return payload
    }
}
