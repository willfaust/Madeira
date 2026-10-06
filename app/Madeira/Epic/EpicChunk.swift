// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
// Ported from Legendary's models/chunk.py (GPL-3.0-or-later).

import Foundation
import zlib

enum EpicContentError: LocalizedError {
    case invalid(String)
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .httpStatus(let status): return "Epic download failed (HTTP \(status)). Try again."
        }
    }
}

struct EpicReader {
    let data: Data
    var position = 0

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, position <= data.count, count <= data.count - position else {
            throw EpicContentError.invalid("Truncated Epic content.")
        }
        defer { position += count }
        return data.subdata(in: position..<position + count)
    }
    mutating func number(_ count: Int) throws -> UInt64 {
        try bytes(count).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    mutating func u32() throws -> Int { Int(try number(4)) }
    mutating func guid() throws -> String {
        try (0..<4).map { _ in String(format: "%08X", try number(4)) }.joined()
    }
    mutating func string() throws -> String {
        let length = Int(Int32(bitPattern: UInt32(try number(4))))
        if length == 0 { return "" }
        let wide = length < 0
        let raw = try bytes(abs(length) * (wide ? 2 : 1))
        let terminator = wide ? 2 : 1
        guard raw.suffix(terminator).allSatisfy({ $0 == 0 }),
              let result = String(data: raw.dropLast(terminator), encoding: wide ? .utf16LittleEndian : .ascii) else {
            throw EpicContentError.invalid("Invalid Epic string.")
        }
        return result
    }
    mutating func strings() throws -> [String] {
        let count = try boundedCount()
        return try (0..<count).map { _ in try string() }
    }
    mutating func boundedCount() throws -> Int {
        let count = try u32()
        guard count <= data.count - position else { throw EpicContentError.invalid("Invalid Epic list length.") }
        return count
    }
    mutating func section() throws -> EpicReader {
        let size = try u32()
        guard size >= 5 else { throw EpicContentError.invalid("Invalid Epic section size.") }
        return EpicReader(data: try bytes(size - 4))
    }
}

/// Incremental SHA-1 keeps file verification independent of file size.
struct EpicSHA1 {
    private var state: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    private var tail = [UInt8]()
    private var length: UInt64 = 0

    mutating func update(_ data: Data) {
        length += UInt64(data.count)
        for byte in data {
            tail.append(byte)
            if tail.count == 64 { compress(tail); tail.removeAll(keepingCapacity: true) }
        }
    }
    private func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
    private mutating func compress(_ block: [UInt8]) {
        var words = [UInt32](repeating: 0, count: 80)
        for i in 0..<16 {
            let p = i * 4
            words[i] = UInt32(block[p]) << 24 | UInt32(block[p + 1]) << 16 | UInt32(block[p + 2]) << 8 | UInt32(block[p + 3])
        }
        for i in 16..<80 { words[i] = rotate(words[i - 3] ^ words[i - 8] ^ words[i - 14] ^ words[i - 16], 1) }
        var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4]
        for i in 0..<80 {
            let f: UInt32, k: UInt32
            switch i {
            case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
            case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
            case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
            default: f = b ^ c ^ d; k = 0xCA62C1D6
            }
            let t = rotate(a, 5) &+ f &+ e &+ k &+ words[i]
            e = d; d = c; c = rotate(b, 30); b = a; a = t
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d; state[4] &+= e
    }
    mutating func finish() -> Data {
        let bits = length * 8
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bits >> shift)) }
        for start in stride(from: 0, to: tail.count, by: 64) { compress(Array(tail[start..<start + 64])) }
        return Data(state.flatMap { word in [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: word >> $0) } })
    }
    static func hash(_ data: Data) -> Data { var hash = Self(); hash.update(data); return hash.finish() }
    static func file(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = Self()
        while let data = try file.read(upToCount: 256 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data)
        }
        return hash.finish()
    }
}

enum EpicChunk {
    static let maximumSize = 16 * 1024 * 1024

    static func inflate(_ input: Data, size: Int, limit: Int) throws -> Data {
        guard size > 0, size <= limit else { throw EpicContentError.invalid("Epic content exceeds the decompression limit.") }
        var output = Data(count: size)
        var length = uLongf(size)
        let status = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                uncompress(dst.bindMemory(to: Bytef.self).baseAddress, &length,
                           src.bindMemory(to: Bytef.self).baseAddress, uLong(input.count))
            }
        }
        guard status == Z_OK, length == size else { throw EpicContentError.invalid("Invalid Epic zlib stream.") }
        return output
    }

    static func parse(_ data: Data, expected: EpicManifest.Chunk? = nil) throws -> Data {
        var r = EpicReader(data: data)
        guard try r.u32() == 0xB1FE3AA2 else { throw EpicContentError.invalid("Invalid Epic chunk magic.") }
        let version = try r.u32(), headerSize = try r.u32(), compressedSize = try r.u32()
        let guid = try r.guid(), hash = try r.number(8), stored = try r.number(1)
        var sha = Data(), hashType: UInt64 = 0, size = 1024 * 1024
        guard (1...4).contains(version), stored & ~1 == 0 else {
            throw EpicContentError.invalid("Encrypted or unsupported Epic chunk.")
        }
        if version >= 2 { sha = try r.bytes(20); hashType = try r.number(1) }
        if version >= 3 { size = try r.u32() }
        if version >= 4 { _ = try r.bytes(32) }
        guard r.position == headerSize, compressedSize == data.count - headerSize, size <= maximumSize else {
            throw EpicContentError.invalid("Invalid Epic chunk size.")
        }
        let payload = try r.bytes(compressedSize)
        let result = stored & 1 != 0 ? try inflate(payload, size: size, limit: maximumSize) : payload
        let digest = EpicSHA1.hash(result)
        guard result.count == size, hashType & 2 == 0 || digest == sha else {
            throw EpicContentError.invalid("Epic chunk SHA-1 mismatch.")
        }
        if let expected {
            guard guid == expected.guid, hash == expected.hash, digest == expected.sha,
                  result.count == expected.windowSize, data.count == expected.fileSize else {
                throw EpicContentError.invalid("Epic chunk does not match its manifest.")
            }
        } else if hashType & 2 == 0 {
            throw EpicContentError.invalid("A manifest SHA-1 is required to verify this chunk.")
        }
        return result
    }
}
