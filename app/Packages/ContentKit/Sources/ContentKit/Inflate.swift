// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Raw DEFLATE (RFC 1951) decoder with a hard output ceiling, modelled on
/// zlib's puff.c. Every caller passes the size the container declares, so a
/// decompression bomb stops at that size with `unsafeContent`.
public enum Inflate {
    public static func decompress(_ input: ArraySlice<UInt8>, limit: Int) throws -> [UInt8] {
        try input.withUnsafeBufferPointer { inp in
            var s = State(input: inp, limit: limit)
            defer { s.out.deallocate() }
            var last = false
            repeat {
                last = try s.bits(1) == 1
                switch try s.bits(2) {
                case 0: try s.stored()
                case 1: try s.codes(Tables.fixedLength, Tables.fixedDistance)
                case 2: try s.dynamic()
                default: throw ClientError.protocolChanged("deflate: invalid block type")
                }
            } while !last
            return Array(UnsafeBufferPointer(start: s.out, count: s.count))
        }
    }

    struct Huffman {
        var count: [Int16]  // codes per length, 0...15
        var symbol: [Int16]
        /// Codes of up to `fastBits` bits, indexed by the next `fastBits`
        /// input bits (deflate sends codes most significant bit first, so the
        /// index is the code reversed): `symbol << 4 | length`, 0 for a longer
        /// code, which `decode` reads a bit at a time.
        var fast: [UInt16]
        static let fastBits = 9

        init(lengths: [Int]) throws {
            count = [Int16](repeating: 0, count: 16)
            symbol = [Int16](repeating: 0, count: lengths.count)
            for l in lengths { count[l] += 1 }
            var offs = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offs[len + 1] = offs[len] + Int(count[len]) }
            for (sym, l) in lengths.enumerated() where l != 0 {
                symbol[offs[l]] = Int16(sym); offs[l] += 1
            }
            fast = [UInt16](repeating: 0, count: 1 << Self.fastBits)
            var next = [Int](repeating: 0, count: 16)
            var code = 0
            for len in 1...15 {
                code = (code + (len > 1 ? Int(count[len - 1]) : 0)) << 1
                next[len] = code
            }
            for (sym, l) in lengths.enumerated() where l != 0 {
                let c = next[l]
                next[l] += 1
                guard c < 1 << l else { throw ClientError.protocolChanged("deflate: over-subscribed code") }
                guard l <= Self.fastBits else { continue }
                var r = 0
                for i in 0..<l where c & (1 << i) != 0 { r |= 1 << (l - 1 - i) }
                for fill in stride(from: r, to: 1 << Self.fastBits, by: 1 << l) {
                    fast[fill] = UInt16(sym << 4 | l)
                }
            }
        }
    }

    enum Tables {
        static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
        static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
        static let fixedLength: Huffman = {
            var l = [Int](repeating: 8, count: 288)
            for i in 144..<256 { l[i] = 9 }
            for i in 256..<280 { l[i] = 7 }
            return try! Huffman(lengths: l)
        }()
        static let fixedDistance: Huffman = try! Huffman(lengths: [Int](repeating: 5, count: 30))
    }

    struct State {
        let input: UnsafeBufferPointer<UInt8>
        var pos = 0
        var bitBuf: UInt64 = 0
        var bitCount = 0
        /// The output grows by doubling up to `limit` (a declared size the
        /// sender controls, so it is not allocated up front).
        var out: UnsafeMutablePointer<UInt8>
        var count = 0
        var capacity: Int
        let limit: Int

        init(input: UnsafeBufferPointer<UInt8>, limit: Int) {
            self.input = input
            self.limit = limit
            capacity = Swift.max(1, Swift.min(limit, 1 << 22))
            out = .allocate(capacity: capacity)
        }

        /// Room for `n` more bytes, or `unsafeContent` past the declared size.
        @inline(__always) mutating func reserve(_ n: Int) throws {
            guard count + n <= limit else { throw ClientError.unsafeContent("inflate exceeds declared size \(limit)") }
            if count + n > capacity { grow(count + n) }
        }

        mutating func grow(_ need: Int) {
            let newCapacity = Swift.min(limit, Swift.max(need, capacity * 2))
            let bigger = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
            bigger.update(from: out, count: count)
            out.deallocate()
            out = bigger
            capacity = newCapacity
        }

        /// Tops the bit buffer up to at least 57 bits, or to the end of input.
        @inline(__always) mutating func refill() {
            while bitCount <= 56, pos < input.count {
                bitBuf |= UInt64(input[pos]) << UInt64(bitCount)
                pos += 1
                bitCount += 8
            }
        }

        @inline(__always) mutating func bits(_ need: Int) throws -> Int {
            if bitCount < need {
                refill()
                guard bitCount >= need else { throw ClientError.protocolChanged("deflate: truncated input") }
            }
            let val = Int(truncatingIfNeeded: bitBuf & ((1 << UInt64(need)) - 1))
            bitBuf >>= UInt64(need)
            bitCount -= need
            return val
        }

        mutating func stored() throws {
            // Drop to a byte boundary, then hand back any whole bytes still buffered.
            let drop = bitCount & 7
            bitBuf >>= UInt64(drop); bitCount -= drop
            pos -= bitCount / 8
            bitBuf = 0; bitCount = 0
            guard input.count - pos >= 4 else { throw ClientError.protocolChanged("deflate: truncated stored header") }
            let len = Int(input[pos]) | Int(input[pos + 1]) << 8
            let nlen = Int(input[pos + 2]) | Int(input[pos + 3]) << 8
            pos += 4
            guard len == (~nlen & 0xFFFF) else { throw ClientError.protocolChanged("deflate: stored length mismatch") }
            guard input.count - pos >= len else { throw ClientError.protocolChanged("deflate: truncated stored block") }
            try reserve(len)
            (out + count).update(from: input.baseAddress! + pos, count: len)
            count += len
            pos += len
        }

        @inline(__always) mutating func decode(_ h: Huffman) throws -> Int {
            if bitCount < 15 { refill() }
            let e = Int(h.fast[Int(truncatingIfNeeded: bitBuf) & ((1 << Huffman.fastBits) - 1)])
            if e != 0, e & 15 <= bitCount {
                bitBuf >>= UInt64(e & 15)
                bitCount -= e & 15
                return e >> 4
            }
            return try decodeSlow(h)
        }

        mutating func decodeSlow(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1...15 {
                code |= try bits(1)
                let count = Int(h.count[len])
                if code - count < first {
                    let at = index + (code - first)
                    guard at < h.symbol.count else { throw ClientError.protocolChanged("deflate: over-subscribed code") }
                    return Int(h.symbol[at])
                }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw ClientError.protocolChanged("deflate: bad Huffman code")
        }

        mutating func codes(_ lencode: Huffman, _ distcode: Huffman) throws {
            let lengthBase = Tables.lengthBase, lengthExtra = Tables.lengthExtra
            let distBase = Tables.distBase, distExtra = Tables.distExtra
            while true {
                var sym = try decode(lencode)
                if sym < 256 {
                    try reserve(1)
                    out[count] = UInt8(truncatingIfNeeded: sym)
                    count += 1
                    continue
                }
                if sym == 256 { return }
                sym -= 257
                guard sym < 29 else { throw ClientError.protocolChanged("deflate: bad length symbol") }
                let len = lengthBase[sym] + (try bits(lengthExtra[sym]))
                let dsym = try decode(distcode)
                guard dsym < 30 else { throw ClientError.protocolChanged("deflate: bad distance symbol") }
                let dist = distBase[dsym] + (try bits(distExtra[dsym]))
                guard dist <= count else { throw ClientError.protocolChanged("deflate: distance too far back") }
                try reserve(len)
                // Byte by byte: a match may overlap the bytes it produces.
                var src = out + (count - dist)
                var dst = out + count
                for _ in 0..<len { dst.pointee = src.pointee; dst += 1; src += 1 }
                count += len
            }
        }

        mutating func dynamic() throws {
            let nlen = try bits(5) + 257, ndist = try bits(5) + 1, ncode = try bits(4) + 4
            guard nlen <= 286, ndist <= 30 else { throw ClientError.protocolChanged("deflate: bad counts") }
            let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
            var lengths = [Int](repeating: 0, count: 320)
            for i in 0..<ncode { lengths[order[i]] = try bits(3) }
            let lencode = try Huffman(lengths: Array(lengths[0..<19]))
            var index = 0
            while index < nlen + ndist {
                var sym = try decode(lencode)
                if sym < 16 { lengths[index] = sym; index += 1; continue }
                var len = 0
                if sym == 16 {
                    guard index > 0 else { throw ClientError.protocolChanged("deflate: repeat with no length") }
                    len = lengths[index - 1]
                    sym = 3 + (try bits(2))
                } else if sym == 17 {
                    sym = 3 + (try bits(3))
                } else {
                    sym = 11 + (try bits(7))
                }
                guard index + sym <= nlen + ndist else { throw ClientError.protocolChanged("deflate: too many lengths") }
                for _ in 0..<sym { lengths[index] = len; index += 1 }
            }
            guard lengths[256] != 0 else { throw ClientError.protocolChanged("deflate: no end-of-block code") }
            try codes(Huffman(lengths: Array(lengths[0..<nlen])), Huffman(lengths: Array(lengths[nlen..<(nlen + ndist)])))
        }
    }
}

/// gzip (RFC 1952) wrapper around `Inflate`, used by CM Multi messages.
public enum Gzip {
    public static func decompress(_ data: [UInt8], limit: Int) throws -> [UInt8] {
        guard data.count >= 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 8 else {
            throw ClientError.protocolChanged("gzip: bad header")
        }
        let flags = data[3]
        var i = 10
        if flags & 0x04 != 0 {
            guard i + 2 <= data.count else { throw ClientError.protocolChanged("gzip: truncated extra") }
            i += 2 + Int(data.readLE16(at: i))
        }
        if flags & 0x08 != 0 { while i < data.count && data[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < data.count && data[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i <= data.count - 8 else { throw ClientError.protocolChanged("gzip: truncated") }
        let out = try Inflate.decompress(data[i..<(data.count - 8)], limit: limit)
        let crc = data.readLE32(at: data.count - 8)
        guard CRC32.checksum(out) == crc else { throw ClientError.verificationFailed("gzip CRC mismatch") }
        return out
    }
}

/// Reads the single entry of a PKZip archive: depot manifests from the CDN and
/// PKZip-compressed depot chunks. Only stored (0) and deflate (8) entries are
/// accepted; the declared uncompressed size is the ceiling, bounded by `maxSize`.
public enum ZipSingleEntry {
    public static func extract(_ data: [UInt8], maxSize: Int) throws -> [UInt8] {
        guard data.count >= 30, data.readLE32(at: 0) == 0x0403_4B50 else {
            throw ClientError.protocolChanged("zip: no local file header")
        }
        let flags = data.readLE16(at: 6)
        let method = data.readLE16(at: 8)
        var crc = data.readLE32(at: 14)
        var compressedSize = Int(data.readLE32(at: 18))
        var size = Int(data.readLE32(at: 22))
        let nameLength = Int(data.readLE16(at: 26))
        let extraLength = Int(data.readLE16(at: 28))
        let start = 30 + nameLength + extraLength
        guard start <= data.count else { throw ClientError.protocolChanged("zip: truncated header") }
        if flags & 0x08 != 0 || compressedSize == 0 {
            // Sizes live in the central directory; find it via the end record.
            guard let central = centralEntry(data) else { throw ClientError.protocolChanged("zip: no central directory") }
            (crc, compressedSize, size) = central
        }
        guard size <= maxSize else { throw ClientError.unsafeContent("zip entry declares \(size) bytes (limit \(maxSize))") }
        guard compressedSize <= data.count - start else { throw ClientError.protocolChanged("zip: truncated entry") }
        let body = data[start..<(start + compressedSize)]
        let out: [UInt8]
        switch method {
        case 0: out = Array(body)
        case 8: out = try Inflate.decompress(body, limit: size)
        default: throw ClientError.unsupported("zip compression method \(method)")
        }
        guard out.count == size else { throw ClientError.verificationFailed("zip entry size \(out.count) != declared \(size)") }
        guard CRC32.checksum(out) == crc else { throw ClientError.verificationFailed("zip entry CRC mismatch") }
        return out
    }

    private static func centralEntry(_ data: [UInt8]) -> (UInt32, Int, Int)? {
        guard data.count >= 22 else { return nil }
        var i = data.count - 22
        let floor = Swift.max(0, data.count - 22 - 0xFFFF)
        while i >= floor {
            if data.readLE32(at: i) == 0x0605_4B50 {
                let cd = Int(data.readLE32(at: i + 16))
                guard cd + 46 <= data.count, data.readLE32(at: cd) == 0x0201_4B50 else { return nil }
                return (data.readLE32(at: cd + 16), Int(data.readLE32(at: cd + 20)), Int(data.readLE32(at: cd + 24)))
            }
            i -= 1
        }
        return nil
    }
}
