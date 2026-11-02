// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// The formats of the EA app's world (docs/EA.md): the small AES cipher its
// local service and game licences use, the LSX messages a game sends the
// service, the zip builds EA's CDN serves, a build's installerdata.xml, the
// licence file (.dlf) and the machine hash an EA game checks it against. The
// protocol work follows Maxima (ArmchairDevelopers, GPL-3.0); no Maxima code is
// included. Everything here is pure: no network, no UI, no Keychain, so the
// host check (tests/host/check-ea-formats.py) compiles and runs it on Linux.

// MARK: - Digests

#if canImport(CryptoKit)
/// SHA-1, SHA-256 and HMAC-SHA-256 through CryptoKit. The host check supplies the
/// same functions on a system without it.
enum EADigest {
    static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }
    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func hmacSHA256(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}
#endif

enum EAHex {
    static func encode(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    /// Hex digits anywhere in the text (letters of either case); nil when their count is odd.
    static func decode(_ text: String) -> Data? {
        let digits: [UInt8] = text.compactMap { character in
            guard character.isASCII, let value = character.hexDigitValue else { return nil }
            return UInt8(value)
        }
        guard digits.count % 2 == 0 else { return nil }
        var out = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count { out.append(digits[index] << 4 | digits[index + 1]); index += 2 }
        return out
    }
}

/// 64-bit FNV-1a, as the EA app hashes its machine identity.
enum EAFNV {
    static func hash64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }
}

// MARK: - AES-128

/// AES-128 in ECB and CBC with PKCS#7 padding: the whole of what EA's local
/// service protocol and its licence files use. Messages are short (a licence is
/// about a kilobyte), so a plain table implementation is enough. Pure Swift, so
/// the host check runs it too.
struct EAAES128 {
    private static let sbox: [UInt8] = {
        func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
            var a = a, b = b, p: UInt8 = 0
            for _ in 0..<8 {
                if b & 1 != 0 { p ^= a }
                let high = a & 0x80
                a <<= 1
                if high != 0 { a ^= 0x1b }
                b >>= 1
            }
            return p
        }
        var table = [UInt8](repeating: 0, count: 256)
        for x in 0..<256 {
            var inverse: UInt8 = 0
            if x != 0 { for y in 1..<256 where mul(UInt8(x), UInt8(y)) == 1 { inverse = UInt8(y); break } }
            var s = inverse
            for shift in 1...4 { s ^= (inverse << shift) | (inverse >> (8 - shift)) }
            table[x] = s ^ 0x63
        }
        return table
    }()
    private static let inverseSbox: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for (index, value) in sbox.enumerated() { table[Int(value)] = UInt8(index) }
        return table
    }()

    private let roundKeys: [[UInt8]]   // 11 keys of 16 bytes

    init(key: [UInt8]) {
        precondition(key.count == 16, "AES-128 takes a 16-byte key")
        var words: [[UInt8]] = (0..<4).map { Array(key[$0 * 4..<$0 * 4 + 4]) }
        var rcon: UInt8 = 1
        for index in 4..<44 {
            var temp = words[index - 1]
            if index % 4 == 0 {
                temp = [temp[1], temp[2], temp[3], temp[0]].map { Self.sbox[Int($0)] }
                temp[0] ^= rcon
                rcon = Self.xtime(rcon)
            }
            words.append(zip(words[index - 4], temp).map(^))
        }
        roundKeys = (0..<11).map { round in words[round * 4..<round * 4 + 4].flatMap { $0 } }
    }

    private static func xtime(_ a: UInt8) -> UInt8 { (a << 1) ^ (a & 0x80 != 0 ? 0x1b : 0) }
    private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a, b = b, p: UInt8 = 0
        while b != 0 {
            if b & 1 != 0 { p ^= a }
            a = xtime(a); b >>= 1
        }
        return p
    }

    /// One 16-byte block; the state is column-major, as the standard lays it out.
    func encryptBlock(_ input: [UInt8]) -> [UInt8] {
        var state = zip(input, roundKeys[0]).map(^)
        for round in 1...10 {
            state = state.map { Self.sbox[Int($0)] }
            state = Self.shiftRows(state)
            if round < 10 { state = Self.mixColumns(state, inverse: false) }
            state = zip(state, roundKeys[round]).map(^)
        }
        return state
    }

    func decryptBlock(_ input: [UInt8]) -> [UInt8] {
        var state = zip(input, roundKeys[10]).map(^)
        for round in stride(from: 9, through: 0, by: -1) {
            state = Self.shiftRows(state, inverse: true)
            state = state.map { Self.inverseSbox[Int($0)] }
            state = zip(state, roundKeys[round]).map(^)
            if round > 0 { state = Self.mixColumns(state, inverse: true) }
        }
        return state
    }

    private static func shiftRows(_ s: [UInt8], inverse: Bool = false) -> [UInt8] {
        var out = s
        for row in 1..<4 {
            for column in 0..<4 {
                let from = inverse ? (column - row + 4) % 4 : (column + row) % 4
                out[row + 4 * column] = s[row + 4 * from]
            }
        }
        return out
    }

    private static func mixColumns(_ s: [UInt8], inverse: Bool) -> [UInt8] {
        let m: [UInt8] = inverse ? [14, 11, 13, 9] : [2, 3, 1, 1]
        var out = s
        for column in 0..<4 {
            let a = Array(s[column * 4..<column * 4 + 4])
            for row in 0..<4 {
                var value: UInt8 = 0
                for k in 0..<4 { value ^= mul(m[(k - row + 4) % 4], a[k]) }
                out[column * 4 + row] = value
            }
        }
        return out
    }

    private static func pad(_ data: Data) -> [UInt8] {
        let padding = 16 - data.count % 16
        return Array(data) + [UInt8](repeating: UInt8(padding), count: padding)
    }

    private static func unpad(_ bytes: [UInt8]) -> Data? {
        guard let last = bytes.last, last >= 1, last <= 16, bytes.count >= Int(last),
              bytes.suffix(Int(last)).allSatisfy({ $0 == last }) else { return nil }
        return Data(bytes.dropLast(Int(last)))
    }

    func ecbEncrypt(_ data: Data) -> Data {
        let padded = Self.pad(data)
        var out: [UInt8] = []
        out.reserveCapacity(padded.count)
        for offset in stride(from: 0, to: padded.count, by: 16) { out += encryptBlock(Array(padded[offset..<offset + 16])) }
        return Data(out)
    }

    func ecbDecrypt(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count % 16 == 0 else { return nil }
        let bytes = Array(data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for offset in stride(from: 0, to: bytes.count, by: 16) { out += decryptBlock(Array(bytes[offset..<offset + 16])) }
        return Self.unpad(out)
    }

    func cbcEncrypt(_ data: Data, iv: [UInt8] = [UInt8](repeating: 0, count: 16)) -> Data {
        let padded = Self.pad(data)
        var previous = iv
        var out: [UInt8] = []
        out.reserveCapacity(padded.count)
        for offset in stride(from: 0, to: padded.count, by: 16) {
            previous = encryptBlock(zip(Array(padded[offset..<offset + 16]), previous).map(^))
            out += previous
        }
        return Data(out)
    }

    func cbcDecrypt(_ data: Data, iv: [UInt8] = [UInt8](repeating: 0, count: 16)) -> Data? {
        guard !data.isEmpty, data.count % 16 == 0 else { return nil }
        let bytes = Array(data)
        var previous = iv
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let block = Array(bytes[offset..<offset + 16])
            out += zip(decryptBlock(block), previous).map(^)
            previous = block
        }
        return Self.unpad(out)
    }
}

// MARK: - The local service's cipher

/// What a game and the EA app's local service agree on before they talk: the
/// service sends a challenge, the game answers with the challenge encrypted
/// under a fixed key, and from the game's own key the two derive the session key
/// every later message is encrypted with (AES-128-ECB, hex text).
enum EALSXCrypto {
    static let fixedKey: [UInt8] = Array(0..<16)

    static func encrypt(_ text: String, key: [UInt8]) -> String {
        EAHex.encode(EAAES128(key: key).ecbEncrypt(Data(text.utf8)))
    }

    static func decrypt(_ hexText: String, key: [UInt8]) -> String? {
        guard let data = EAHex.decode(hexText), let plain = EAAES128(key: key).ecbDecrypt(data) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// The answer to a challenge: the challenge text under the fixed key.
    static func challengeResponse(_ challenge: String) -> String { encrypt(challenge, key: fixedKey) }

    static func checkChallengeResponse(_ response: String, challenge: String) -> Bool {
        decrypt(response, key: fixedKey) == challenge
    }

    /// The session key: version 2 keeps the fixed key; version 3 seeds the C runtime's
    /// rand() with 7, adds the first two bytes of the accepted key to its first value
    /// and takes the next sixteen values' low bytes.
    static func sessionKey(version: String, acceptedKey: String) -> [UInt8]? {
        switch version {
        case "2": return fixedKey
        case "3":
            let bytes = Array(acceptedKey.utf8)
            guard bytes.count >= 2 else { return nil }
            let seed = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return derivedKey(seed: seed)
        default: return nil
        }
    }

    static func derivedKey(seed: UInt16) -> [UInt8] {
        if seed == 0 { return fixedKey }
        var state: UInt32 = 7
        func rand() -> UInt32 {
            state = state &* 214013 &+ 2531011
            return (state >> 16) & 0xFFFF
        }
        state = rand() &+ UInt32(seed)
        return (0..<16).map { _ in UInt8(truncatingIfNeeded: rand()) }
    }

    /// The day's launch code (EARtPLaunchCode): three primes against the UTC date, folded.
    static func launchCode(date: Date = Date()) -> UInt32 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = UInt32(parts.year ?? 1970), month = UInt32(parts.month ?? 1), day = UInt32(parts.day ?? 1)
        let time = (104_729 &* year) ^ (month &* 224_737) ^ (day &* 350_377)
        return time ^ (time << 16) ^ (time >> 16)
    }
}

// MARK: - XML

/// A small element tree, enough for installerdata.xml, a licence and LSX messages.
struct EAXMLNode {
    var name: String
    var attributes: [String: String] = [:]
    var children: [EAXMLNode] = []
    var text = ""

    func child(_ name: String) -> EAXMLNode? { children.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    func children(_ name: String) -> [EAXMLNode] { children.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    func attribute(_ name: String) -> String? {
        attributes.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    /// The text of a child element, trimmed, or nil when absent or empty.
    func value(_ name: String) -> String? {
        guard let text = child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    static func parse(_ data: Data) -> EAXMLNode? {
        let parser = XMLParser(data: data)
        let builder = Builder()
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse(), let root = builder.root else { return nil }
        return root
    }

    /// Text that may be UTF-8 or UTF-16 (installerdata.xml of some builds), as a document.
    static func parse(text data: Data) -> EAXMLNode? {
        if let node = parse(data) { return node }
        for encoding in [String.Encoding.utf16LittleEndian, .utf16, .utf16BigEndian] {
            if let text = String(data: data, encoding: encoding), let node = parse(Data(text.utf8)) { return node }
        }
        return nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: EAXMLNode?
        private var stack: [EAXMLNode] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            stack.append(EAXMLNode(name: elementName, attributes: attributeDict))
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard !stack.isEmpty, let text = String(data: CDATABlock, encoding: .utf8) else { return }
            stack[stack.count - 1].text += text
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let node = stack.popLast() else { return }
            if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
        }
    }
}

enum EAXML {
    /// Text safe inside an attribute value or element content.
    static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }

    /// `<Name a="1" b="2">children</Name>`, self-closing without children.
    static func element(_ name: String, _ attributes: [(String, String)] = [], children: String = "") -> String {
        var out = "<" + name
        for (key, value) in attributes { out += " \(key)=\"\(escape(value))\"" }
        return children.isEmpty ? out + "/>" : out + ">" + children + "</" + name + ">"
    }
}

// MARK: - LSX messages

/// One request a game sends the local service: `<LSX><Request recipient="EALS"
/// id="7"><GetProfile index="0" version="1.0"/></Request></LSX>`. The name is the
/// inner element's; its attributes and children are the request's parameters.
struct EALSXRequest {
    var recipient: String
    var id: String
    var name: String
    var body: EAXMLNode
    func attribute(_ name: String) -> String? { body.attribute(name) }
    func value(_ name: String) -> String? { body.value(name) }
}

enum EALSX {
    static let serviceSender = "EALS"

    /// Every complete `<LSX>…</LSX>` document in the text, in order (a packet may hold
    /// several, and a message may end with a NUL).
    static func documents(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: "<LSX>"), let end = rest[start.upperBound...].range(of: "</LSX>") {
            out.append(String(rest[start.lowerBound..<end.upperBound]))
            rest = rest[end.upperBound...]
        }
        return out
    }

    static func request(_ document: String) -> EALSXRequest? {
        guard let root = EAXMLNode.parse(Data(document.utf8)), root.name == "LSX",
              let request = root.child("Request"), let body = request.children.first else { return nil }
        return EALSXRequest(recipient: request.attribute("recipient") ?? serviceSender, id: request.attribute("id") ?? "0",
                            name: body.name, body: body)
    }

    /// Whether the document is an Event (which gets no answer) rather than a Request.
    static func isEvent(_ document: String) -> Bool {
        guard let root = EAXMLNode.parse(Data(document.utf8)) else { return false }
        return root.child("Event") != nil
    }

    static func event(_ body: String) -> String {
        "<LSX>" + EAXML.element("Event", [("sender", serviceSender)], children: body) + "</LSX>"
    }

    static func response(to request: EALSXRequest, _ body: String) -> String {
        "<LSX>" + EAXML.element("Response", [("sender", request.recipient), ("id", request.id)], children: body) + "</LSX>"
    }
}

// MARK: - Zip builds

/// One file of a build's zip (its central directory entry).
struct EAZipEntry: Codable, Sendable, Equatable {
    var name: String
    var crc32: UInt32
    /// 0 stored, 8 deflate.
    var method: UInt16
    var compressedSize: Int64
    var uncompressedSize: Int64
    var localHeaderOffset: Int64
    var isDirectory: Bool { name.hasSuffix("/") }
}

enum EAZipError: LocalizedError, Equatable {
    case noDirectory
    case bad(String)
    var errorDescription: String? {
        switch self {
        case .noDirectory: return "EA's build file is not a zip Madeira can read (no central directory)."
        case .bad(let what): return "EA's build file could not be read (\(what))."
        }
    }
}

/// Reading a zip's table of contents from its tail, the way the EA app installs
/// a build without downloading the whole archive: the end-of-central-directory
/// record (and its Zip64 forms) says where the central directory is.
enum EAZipDirectory {
    struct Location: Equatable { var offset: Int64; var size: Int64; var entries: Int64 }

    private static func u16(_ d: Data, _ at: Int) -> UInt16 { UInt16(d[d.startIndex + at]) | UInt16(d[d.startIndex + at + 1]) << 8 }
    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        UInt32(u16(d, at)) | UInt32(u16(d, at + 2)) << 16
    }
    private static func u64(_ d: Data, _ at: Int) -> UInt64 {
        UInt64(u32(d, at)) | UInt64(u32(d, at + 4)) << 32
    }

    /// Where the central directory is, from the archive's last bytes (`tail`, which
    /// ends at `fileSize`). A Zip64 record outside the tail is returned as
    /// `.needsRecord(offset)` for the caller to fetch and pass to `location(zip64Record:)`.
    enum TailResult: Equatable { case found(Location), needsRecord(Int64) }

    static func locate(tail: Data, fileSize: Int64) throws -> TailResult {
        let bytes = Data(tail)
        guard bytes.count >= 22 else { throw EAZipError.noDirectory }
        var eocd = -1
        var position = bytes.count - 22
        while position >= 0 {
            if u32(bytes, position) == 0x0605_4b50 { eocd = position; break }
            position -= 1
        }
        guard eocd >= 0 else { throw EAZipError.noDirectory }
        let entries = Int64(u16(bytes, eocd + 10))
        let size = Int64(u32(bytes, eocd + 12))
        let offset = Int64(u32(bytes, eocd + 16))
        let needs64 = entries == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF
        if !needs64 { return .found(Location(offset: offset, size: size, entries: entries)) }
        guard eocd >= 20, u32(bytes, eocd - 20) == 0x0706_4b50 else { throw EAZipError.bad("zip64 locator") }
        let recordOffset = Int64(bitPattern: u64(bytes, eocd - 20 + 8))
        let tailStart = fileSize - Int64(bytes.count)
        if recordOffset >= tailStart, recordOffset + 56 <= fileSize {
            return .found(try location(zip64Record: bytes.subdata(in: Int(recordOffset - tailStart)..<Int(recordOffset - tailStart) + 56)))
        }
        return .needsRecord(recordOffset)
    }

    static func location(zip64Record record: Data) throws -> Location {
        let bytes = Data(record)
        guard bytes.count >= 56, u32(bytes, 0) == 0x0606_4b50 else { throw EAZipError.bad("zip64 record") }
        return Location(offset: Int64(bitPattern: u64(bytes, 48)), size: Int64(bitPattern: u64(bytes, 40)),
                        entries: Int64(bitPattern: u64(bytes, 32)))
    }

    /// The entries of a central directory.
    static func entries(_ directory: Data) throws -> [EAZipEntry] {
        let bytes = Data(directory)
        var entries: [EAZipEntry] = []
        var position = 0
        while position + 46 <= bytes.count {
            guard u32(bytes, position) == 0x0201_4b50 else { break }
            let flags = u16(bytes, position + 8)
            let method = u16(bytes, position + 10)
            let crc = u32(bytes, position + 16)
            var compressed = Int64(u32(bytes, position + 20))
            var uncompressed = Int64(u32(bytes, position + 24))
            let nameLength = Int(u16(bytes, position + 28))
            let extraLength = Int(u16(bytes, position + 30))
            let commentLength = Int(u16(bytes, position + 32))
            var offset = Int64(u32(bytes, position + 42))
            let nameStart = position + 46
            guard nameStart + nameLength + extraLength + commentLength <= bytes.count else { throw EAZipError.bad("entry") }
            let nameData = bytes.subdata(in: nameStart..<nameStart + nameLength)
            let name = (flags & 0x800 != 0 ? String(data: nameData, encoding: .utf8) : String(data: nameData, encoding: .windowsCP1252))
                ?? String(decoding: nameData, as: UTF8.self)
            // The Zip64 extra field: 8-byte values for those the entry marks 0xFFFFFFFF, in this order.
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = u16(bytes, extra), size = Int(u16(bytes, extra + 2))
                var field = extra + 4
                if id == 0x0001 {
                    let end = min(field + size, extraEnd)
                    if uncompressed == 0xFFFF_FFFF, field + 8 <= end { uncompressed = Int64(bitPattern: u64(bytes, field)); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= end { compressed = Int64(bitPattern: u64(bytes, field)); field += 8 }
                    if offset == 0xFFFF_FFFF, field + 8 <= end { offset = Int64(bitPattern: u64(bytes, field)); field += 8 }
                    break
                }
                extra += 4 + size
            }
            entries.append(EAZipEntry(name: name, crc32: crc, method: method, compressedSize: compressed,
                                      uncompressedSize: uncompressed, localHeaderOffset: offset))
            position = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// A local file header's length: the fixed 30 bytes plus its own name and extra
    /// field (which may differ from the central directory's). nil when the 30 bytes
    /// are not a local header.
    static func localHeaderLength(_ header: Data) -> Int? {
        let bytes = Data(header)
        guard bytes.count >= 30, u32(bytes, 0) == 0x0403_4b50 else { return nil }
        return 30 + Int(u16(bytes, 26)) + Int(u16(bytes, 28))
    }

    /// The path's parts, or nil when it would leave the folder.
    static func safeComponents(_ name: String) -> [String]? {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(where: { $0.contains(":") || $0.contains("\0") }) else { return nil }
        return parts
    }
}

/// CRC-32 (IEEE), as zip entries carry it.
struct EACRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    private(set) var value: UInt32 = 0xFFFF_FFFF
    mutating func update(_ data: Data) {
        var c = value
        for byte in data { c = Self.table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        value = c
    }
    var checksum: UInt32 { value ^ 0xFFFF_FFFF }
}

/// A raw DEFLATE decoder (RFC 1951) that takes its input in pieces as they arrive:
/// each `feed` decodes what it can and keeps the unfinished symbol or block header for
/// the next piece. Madeira's own, so a zip entry inflates the same way on the device
/// and in the host checks. Build 64 showed the system decoder (Compression,
/// COMPRESSION_ZLIB, fed in pieces) returning some entries short.
struct EAInflate {
    enum Failure: Error, Equatable { case bad(String) }

    /// A canonical Huffman code as a lookup on its next `bits` input bits, bit-reversed:
    /// each entry is symbol << 5 | code length (length 0: no such code).
    private struct Table {
        var entries: [UInt32]
        var bits: Int
        init(lengths: [Int]) throws {
            let maxLength = lengths.max() ?? 0
            bits = max(maxLength, 1)
            entries = [UInt32](repeating: 0, count: 1 << bits)
            var count = [Int](repeating: 0, count: 16)
            for length in lengths where length > 0 { count[length] += 1 }
            var next = [Int](repeating: 0, count: 16)
            var code = 0
            for length in 1...15 {
                code = (code + count[length - 1]) << 1
                next[length] = code
                if count[length] > 0, next[length] + count[length] > 1 << length { throw Failure.bad("over-subscribed code") }
            }
            for (symbol, length) in lengths.enumerated() where length > 0 {
                let code = next[length]; next[length] += 1
                var reversed = 0
                for i in 0..<length where code & (1 << i) != 0 { reversed |= 1 << (length - 1 - i) }
                var r = reversed
                while r < 1 << bits {
                    entries[r] = UInt32(symbol) << 5 | UInt32(length)
                    r += 1 << length
                }
            }
        }
    }

    private enum Mode { case header, stored(Int), codes(Table, Table), done }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
                                       1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    private static let fixed: (Table, Table) = {
        var lit = [Int](repeating: 8, count: 288)
        for i in 144..<256 { lit[i] = 9 }
        for i in 256..<280 { lit[i] = 7 }
        return (try! Table(lengths: lit), try! Table(lengths: [Int](repeating: 5, count: 32)))
    }()

    private var mode = Mode.header
    private var lastBlock = false
    private var input: [UInt8] = []
    private var bit = 0
    private var window = [UInt8](repeating: 0, count: 1 << 15)
    private var position = 0
    private var total = 0
    /// The final block has ended.
    var finished: Bool { if case .done = mode { return true }; return false }

    private var available: Int { input.count * 8 - bit }

    /// The next `n` bits (n <= 24), zero beyond the input.
    private func peek(_ n: Int) -> Int {
        var value = 0, got = 0, p = bit
        while got < n {
            let index = p >> 3
            guard index < input.count else { break }
            let offset = p & 7
            let take = min(8 - offset, n - got)
            value |= ((Int(input[index]) >> offset) & ((1 << take) - 1)) << got
            got += take; p += take
        }
        return value
    }

    private mutating func take(_ n: Int) -> Int? {
        guard available >= n else { return nil }
        let value = peek(n); bit += n
        return value
    }

    private mutating func symbol(_ table: Table) throws -> Int? {
        let entry = table.entries[peek(table.bits)]
        let length = Int(entry & 31)
        guard length > 0 else {
            // Not a code, unless the input simply ran out before its last bits.
            if available >= table.bits { throw Failure.bad("invalid code") }
            return nil
        }
        guard available >= length else { return nil }
        bit += length
        return Int(entry >> 5)
    }

    private mutating func emit(_ byte: UInt8, _ out: inout [UInt8]) {
        window[position] = byte
        position = (position + 1) & 0x7FFF
        total += 1
        out.append(byte)
    }

    /// The code tables of a dynamic block, or nil when the input ends inside them.
    private mutating func dynamicTables() throws -> (Table, Table)? {
        guard let hlit = take(5), let hdist = take(5), let hclen = take(4) else { return nil }
        let literals = hlit + 257, distances = hdist + 1
        guard literals <= 286, distances <= 30 else { throw Failure.bad("too many codes") }
        var codeLengths = [Int](repeating: 0, count: 19)
        for i in 0..<(hclen + 4) {
            guard let length = take(3) else { return nil }
            codeLengths[Self.codeLengthOrder[i]] = length
        }
        let codeTable = try Table(lengths: codeLengths)
        var lengths: [Int] = []
        lengths.reserveCapacity(literals + distances)
        while lengths.count < literals + distances {
            guard let code = try symbol(codeTable) else { return nil }
            switch code {
            case 0...15: lengths.append(code)
            case 16:
                guard let previous = lengths.last else { throw Failure.bad("repeat with no length") }
                guard let extra = take(2) else { return nil }
                lengths.append(contentsOf: repeatElement(previous, count: 3 + extra))
            case 17:
                guard let extra = take(3) else { return nil }
                lengths.append(contentsOf: repeatElement(0, count: 3 + extra))
            default:
                guard let extra = take(7) else { return nil }
                lengths.append(contentsOf: repeatElement(0, count: 11 + extra))
            }
        }
        guard lengths.count == literals + distances else { throw Failure.bad("lengths overrun") }
        guard lengths[256] > 0 else { throw Failure.bad("no end-of-block code") }
        return (try Table(lengths: Array(lengths[0..<literals])), try Table(lengths: Array(lengths[literals...])))
    }

    /// Decodes what `data` completes; the bytes it produced.
    mutating func feed<Bytes: Sequence>(_ data: Bytes) throws -> [UInt8] where Bytes.Element == UInt8 {
        input.append(contentsOf: data)
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 4)
        run: while true {
            switch mode {
            case .done:
                break run
            case .header:
                let start = bit
                guard let last = take(1), let type = take(2) else { bit = start; break run }
                lastBlock = last == 1
                switch type {
                case 0:
                    let aligned = (bit + 7) & ~7
                    guard input.count * 8 - aligned >= 32 else { bit = start; break run }
                    bit = aligned
                    let length = take(16)!, inverse = take(16)!
                    guard length == ~inverse & 0xFFFF else { throw Failure.bad("stored length") }
                    mode = length == 0 ? (lastBlock ? .done : .header) : .stored(length)
                case 1:
                    mode = .codes(Self.fixed.0, Self.fixed.1)
                case 2:
                    guard let tables = try dynamicTables() else { bit = start; break run }
                    mode = .codes(tables.0, tables.1)
                default:
                    throw Failure.bad("block type 3")
                }
            case .stored(let remaining):
                let index = bit >> 3
                let count = min(remaining, input.count - index)
                guard count > 0 else { break run }
                for byte in input[index..<index + count] { emit(byte, &out) }
                bit += count * 8
                mode = remaining == count ? (lastBlock ? .done : .header) : .stored(remaining - count)
            case .codes(let literals, let distances):
                while true {
                    let start = bit
                    guard let code = try symbol(literals) else { break run }
                    if code < 256 { emit(UInt8(code), &out); continue }
                    if code == 256 { mode = lastBlock ? .done : .header; continue run }
                    let index = code - 257
                    guard index < 29 else { throw Failure.bad("length code") }
                    guard let lengthExtra = take(Self.lengthExtra[index]) else { bit = start; break run }
                    let length = Self.lengthBase[index] + lengthExtra
                    guard let distanceCode = try symbol(distances) else { bit = start; break run }
                    guard distanceCode < 30 else { throw Failure.bad("distance code") }
                    guard let distanceExtra = take(Self.distanceExtra[distanceCode]) else { bit = start; break run }
                    let distance = Self.distanceBase[distanceCode] + distanceExtra
                    guard distance <= min(total, 1 << 15) else { throw Failure.bad("distance too far") }
                    for _ in 0..<length { emit(window[(position - distance) & 0x7FFF], &out) }
                }
            }
        }
        // Keep only what is not decoded yet.
        let used = bit >> 3
        if used > 0 { input.removeFirst(used); bit -= used * 8 }
        return out
    }
}

// MARK: - installerdata.xml

/// What a build's `__Installer/installerdata.xml` says about starting the game.
struct EAInstallerData: Equatable {
    struct Launcher: Equatable {
        /// The program, often behind a registry key: `[HKEY_LOCAL_MACHINE\SOFTWARE\…\Install Dir]Game\x.exe`.
        var filePath: String
        var parameters: String
        var trial: Bool
        var requires64Bit: Bool
    }
    var launchers: [Launcher] = []
    var gameVersion: String?
    var contentIDs: [String] = []
    var title: String?
    var touchupPath: String?
    var touchupParameters: String?

    /// The full game's launcher (not a trial), else the first.
    var launcher: Launcher? { launchers.first { !$0.trial } ?? launchers.first }

    static func parse(_ data: Data) -> EAInstallerData? {
        guard let root = EAXMLNode.parse(text: data) else { return nil }
        var out = EAInstallerData()
        if let runtime = root.child("runtime") {
            for node in runtime.children("launcher") {
                guard let path = node.value("filePath") else { continue }
                out.launchers.append(Launcher(filePath: path, parameters: node.value("parameters") ?? "",
                                              trial: flag(node.value("trial")), requires64Bit: flag(node.value("requires64BitOS"))))
            }
        }
        // Builds from before the current manifest ("pre-DiP"): one executable element.
        if out.launchers.isEmpty, let executable = root.child("executable"), let path = executable.value("filePath") {
            out.launchers.append(Launcher(filePath: path, parameters: executable.value("parameters") ?? "", trial: false, requires64Bit: false))
        }
        out.gameVersion = root.child("buildMetaData")?.child("gameVersion")?.attribute("version") ?? root.attribute("gameVersion")
        if let ids = root.child("contentIDs") { out.contentIDs = ids.children("contentID").compactMap { node in
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines); return text.isEmpty ? nil : text } }
        if let titles = root.child("gameTitles") {
            let all = titles.children("gameTitle")
            out.title = (all.first { $0.attribute("locale")?.lowercased().hasPrefix("en") == true } ?? all.first)?
                .text.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.title?.isEmpty == true { out.title = nil }
        }
        if let touchup = root.child("touchup") {
            out.touchupPath = touchup.value("filePath")
            out.touchupParameters = touchup.value("parameters")
        }
        return out.launchers.isEmpty && out.contentIDs.isEmpty ? nil : out
    }

    private static func flag(_ text: String?) -> Bool {
        guard let text = text?.lowercased() else { return false }
        return text == "1" || text == "true"
    }
}

/// A path that may start with a registry key, as EA's manifests spell programs:
/// `[HKEY_LOCAL_MACHINE\SOFTWARE\BioWare\Mass Effect\Install Dir]Game\Bin\x.exe`.
struct EARegistryPath: Equatable {
    /// The key under HKEY_LOCAL_MACHINE (backslashes), without the value's name.
    var key: String?
    /// The value holding the install folder.
    var valueName: String?
    /// The rest, relative to that folder, with backslashes and no leading one.
    var relative: String

    init(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let inside = String(text[text.index(after: text.startIndex)..<close]).replacingOccurrences(of: "/", with: "\\")
            text = String(text[text.index(after: close)...])
            var parts = inside.split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 2 {
                valueName = parts.removeLast()
                if let first = parts.first, first.uppercased() == "HKEY_LOCAL_MACHINE" || first.uppercased() == "HKLM" { parts.removeFirst() }
                key = parts.joined(separator: "\\")
            }
        }
        var relative = text.replacingOccurrences(of: "/", with: "\\")
        while relative.hasPrefix("\\") { relative.removeFirst() }
        self.relative = relative
    }
}

// MARK: - Licence files

/// A game's licence from EA's activation service, as the game reads it from
/// `C:\ProgramData\Electronic Arts\EA Services\License\<content id>.dlf`: a
/// 65-byte signature slot, then the licence XML under AES-128-CBC with a fixed
/// key and a zero IV.
enum EALicenseFile {
    static let key: [UInt8] = [65, 50, 114, 45, 208, 130, 239, 176, 220, 100, 87, 197, 118, 104, 202, 9]
    static let signatureSlot = 65

    static func decrypt(_ encrypted: Data) -> String? {
        guard let plain = EAAES128(key: key).cbcDecrypt(encrypted) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    static func encrypt(_ xml: String) -> Data { EAAES128(key: key).cbcEncrypt(Data(xml.utf8)) }

    /// The file's bytes. Games whose `Core` folder has activation.exe expect the
    /// signature as the service sent it (base64 text); the others its decoded bytes.
    static func pack(xml: String, signature: String, decodeSignature: Bool) -> Data? {
        var bytes: Data
        if decodeSignature {
            guard let decoded = Data(base64Encoded: signature) else { return nil }
            bytes = decoded
        } else {
            bytes = Data(signature.utf8)
        }
        guard bytes.count <= signatureSlot else { return nil }
        bytes.append(Data(count: signatureSlot - bytes.count))
        return bytes + encrypt(xml)
    }

    /// The licence XML inside a file.
    static func unpack(_ file: Data) -> String? {
        guard file.count > signatureSlot else { return nil }
        return decrypt(file.subdata(in: signatureSlot..<file.count))
    }
}

/// The fields of a licence's XML that Madeira reads back.
struct EALicenseInfo: Equatable {
    var contentID: String
    var userID: String
    var machineHash: String
    var gameToken: String?
    var startTime: Date?

    init?(xml: String) {
        guard let root = EAXMLNode.parse(Data(xml.utf8)) else { return nil }
        contentID = root.value("ContentId") ?? ""
        userID = root.value("UserId") ?? ""
        machineHash = root.value("MachineHash") ?? ""
        gameToken = root.value("GameToken")
        startTime = root.value("StartTime").flatMap(Self.date)
    }

    static func date(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - The machine hash

/// What an EA game reads about the machine when it checks its licence (it asks
/// Windows Management Instrumentation and the processor), and the same values
/// as Madeira's Wine and FEX report them to the game. The hash versions follow
/// the game's activation library (`Core/activation.dll` or `awc.dll`); the
/// values are the ones Madeira's own Wine answers with, and a file in Documents
/// (`madeira-ea-hardware.json`) can replace any of them after a device test.
struct EAHardwareProfile: Codable, Equatable {
    var boardManufacturer = "Apple Inc."
    var boardSerial = "None"
    var biosManufacturer = "Apple Inc."
    /// Wine's Win32_BIOS answers "Serial number" whatever the machine.
    var biosSerial = "Serial number"
    /// Win32_OperatingSystem.InstallDate: the creation time of C:\ in WMI's form.
    var osInstallDate = "20260101000000.000000+000"
    /// Win32_OperatingSystem.SerialNumber: the prefix's ProductId.
    var osSerial = "12345-oem-0000001-54321"
    /// GetVolumeInformation's serial for C:, 8 hex digits; without mountmgr it is 0.
    var volumeSerial = "00000000"
    /// Win32_VideoController.PNPDeviceID; the hash takes it up to its last backslash.
    var gpuPNPDeviceID = "PCI\\VEN_106B&DEV_0001&SUBSYS_00000000&REV_00\\00000000"
    var cpuManufacturer = "GenuineIntel"
    var cpuBrand = "Unknown ARM CPU"
    var cpuEAX: UInt32 = 0x000A_0661
    var cpuECX: UInt32 = 0x82D8_230F
    var cpuEDX: UInt32 = 0x2F8B_FBF3
    var hostname = "iPad"
    var diskSerial = "None"
    var macAddress: String?

    /// The hash the game compares its licence with. Versions 0 and 1 are the oldest
    /// activation libraries; 2 and 3 add the volume, graphics card and processor; 4 is
    /// the current one. Returned with the text that was hashed, for the log.
    func machineHash(version: Int) -> (hash: String, input: String) {
        let gpu = gpuPNPDeviceID.isEmpty ? "None" : String(gpuPNPDeviceID[..<(gpuPNPDeviceID.lastIndex(of: "\\") ?? gpuPNPDeviceID.endIndex)])
        let edx = String(format: "%08x", cpuEDX), ecx = String(format: "%08x", cpuECX)
        let edxEAX = String(format: "%08X%08X", cpuEDX, cpuEAX)
        var parts = [boardManufacturer, boardSerial]
        switch version {
        case 0, 1: parts += [hostname, biosManufacturer, biosSerial, osInstallDate, osSerial]
        case 2: parts += [biosManufacturer, biosSerial, osInstallDate, osSerial, volumeSerial, gpu, cpuManufacturer, edx, ecx]
        case 3: parts += [biosManufacturer, biosSerial, volumeSerial, gpu, cpuManufacturer, edx, ecx]
        default: parts += [biosManufacturer, biosSerial, volumeSerial, gpu, cpuManufacturer, edxEAX]
        }
        var input = parts.joined(separator: ";") + ";"
        var data = Data(input.utf8)
        if version >= 2 {
            // The processor's brand string as the 47-byte buffer it is read into, zero-padded.
            var brand = Array(cpuBrand.utf8.prefix(47))
            brand += [UInt8](repeating: 0, count: 47 - brand.count)
            data.append(contentsOf: brand)
            data.append(UInt8(ascii: ";"))
            input += cpuBrand + ";"
        }
        let digest = EADigest.sha1(data)
        // Before version 4 the bytes were written with %x, so a byte under 16 has one digit.
        let hash = version < 4 ? digest.map { String(format: "%x", $0) }.joined() : EAHex.encode(digest)
        return (hash, input)
    }

    /// The machine identity in the sign-in's `pc_sign` (FNV-1a of the board, BIOS and OS fields).
    var machineID: String {
        var text = boardManufacturer + boardSerial + biosManufacturer + biosSerial + osInstallDate + osSerial
        if let macAddress { text += macAddress }
        return String(EAFNV.hash64(Data(text.utf8)))
    }

    /// The graphics device id in `pc_sign`.
    var gpuDeviceID: UInt32 {
        guard let range = gpuPNPDeviceID.range(of: "DEV_") else { return 0 }
        let hex = gpuPNPDeviceID[range.upperBound...].prefix { $0.isHexDigit }
        return UInt32(hex, radix: 16) ?? 0
    }

    /// Win32_OperatingSystem.InstallDate as Wine forms it from C:\'s creation time:
    /// `yyyyMMddHHmmss.ffffff+000` in UTC, with millisecond precision.
    static func wmiDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let milliseconds = (c.nanosecond ?? 0) / 1_000_000
        return String(format: "%04d%02d%02d%02d%02d%02d.%06d+000", c.year ?? 1970, c.month ?? 1, c.day ?? 1,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, milliseconds * 1000)
    }

    /// The processor's CPUID(1) ECX as FEX reports it on this host: AVX and what comes
    /// with it only when the game runs with AVX on (env.MADEIRA_FEX_AVX = 1).
    static func cpuECX(avx: Bool) -> UInt32 {
        let base: UInt32 = 0x82D8_230F
        return avx ? base | 1 << 12 | 1 << 26 | 1 << 27 | 1 << 28 | 1 << 29 : base
    }
}

/// The `pc_sign` value EA's sign-in page asks the EA app for: a base64url JSON
/// description of the machine and its HMAC-SHA-256 under one of two keys the EA
/// app carries, joined by a dot.
enum EAPCSign {
    static let keys: [String: Data] = ["v1": Data("ISa3dpGOc8wW7Adn4auACSQmaccrOyR2".utf8), "v2": Data("nt5FfJbdPzNcl2pkC3zgjO43Knvscxft".utf8)]

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The signed description; `keyVersion` is "v1" or "v2" (the EA app picks one at random).
    static func value(profile: EAHardwareProfile, keyVersion: String, date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let timestamp = String(format: "%04d-%02d-%02d %02d:%02d:%02d:%03d", c.year ?? 1970, c.month ?? 1, c.day ?? 1,
                               c.hour ?? 0, c.minute ?? 0, c.second ?? 0, (c.nanosecond ?? 0) / 1_000_000)
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var fields = [("av", quoted("v1")), ("bsn", quoted(profile.biosSerial)), ("gid", String(profile.gpuDeviceID)),
                      ("hsn", quoted(profile.diskSerial))]
        if let mac = profile.macAddress { fields.append(("mac", quoted(mac))) }
        fields += [("mid", quoted(profile.machineID)), ("msn", quoted(profile.boardSerial)), ("sv", quoted(keyVersion)), ("ts", quoted(timestamp))]
        let json = "{" + fields.map { "\(quoted($0.0)):\($0.1)" }.joined(separator: ",") + "}"
        let payload = base64url(Data(json.utf8))
        let signature = EADigest.hmacSHA256(key: keys[keyVersion] ?? keys["v1"]!, data: Data(payload.utf8))
        return payload + "." + base64url(signature)
    }
}

// MARK: - PE version resource

/// The product version of a Windows program or library, from its version
/// resource (VS_FIXEDFILEINFO). EA's activation library's version picks the
/// machine hash the game computes.
enum EAPEVersion {
    struct Version: Equatable { var major: Int; var minor: Int; var patch: Int; var build: Int }

    static func productVersion(_ data: Data) -> Version? {
        // VS_FIXEDFILEINFO starts with 0xFEEF04BD and a structure version of 1.0.
        let signature: [UInt8] = [0xBD, 0x04, 0xEF, 0xFE]
        let bytes = Data(data)
        var position = 0
        while let range = bytes.range(of: Data(signature), in: position..<bytes.count) {
            let at = range.lowerBound
            if at + 52 <= bytes.count {
                func u32(_ offset: Int) -> UInt32 {
                    UInt32(bytes[at + offset]) | UInt32(bytes[at + offset + 1]) << 8 | UInt32(bytes[at + offset + 2]) << 16 | UInt32(bytes[at + offset + 3]) << 24
                }
                if u32(4) == 0x0001_0000 {
                    let ms = u32(16), ls = u32(20)
                    return Version(major: Int(ms >> 16), minor: Int(ms & 0xFFFF), patch: Int(ls >> 16), build: Int(ls & 0xFFFF))
                }
            }
            position = at + 1
        }
        return nil
    }

    /// The machine-hash version an activation library of this product version computes.
    static func hashVersion(_ version: Version?) -> Int {
        guard let v = version else { return 1 }
        if v.major >= 5 { return 4 }
        if v.major == 4, v.minor > 7 || (v.minor == 7 && v.patch >= 6) { return 3 }
        if v.major == 4, v.minor == 7 { return 2 }
        if v.major == 4 { return 1 }
        return 0
    }
}
