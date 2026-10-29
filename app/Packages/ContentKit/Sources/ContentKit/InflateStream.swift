// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Streaming raw DEFLATE (RFC 1951) for entries too large to hold in memory:
/// a zip import's files, which can be gigabytes. The input comes from `read`
/// in blocks; the output goes to `write` in blocks, keeping only the 32 KiB
/// window deflate's back-references reach. `limit` is the declared size: the
/// stream stops with `unsafeContent` past it. Shares `Inflate`'s Huffman tables.
public struct InflateStream {
    /// Bytes produced so far.
    public private(set) var produced: UInt64 = 0

    private let read: () throws -> [UInt8]?
    private let write: (UnsafeRawBufferPointer) throws -> Void
    private let limit: UInt64
    private var input: [UInt8] = []
    private var pos = 0
    private var ended = false
    private var bitBuf: UInt64 = 0
    private var bitCount = 0
    private var out: [UInt8]
    private var count = 0
    private static let window = 32 * 1024

    /// `flushAt`: output bytes held before a write (beyond the window).
    public init(limit: UInt64, flushAt: Int = 1 << 20, read: @escaping () throws -> [UInt8]?,
                write: @escaping (UnsafeRawBufferPointer) throws -> Void) {
        self.limit = limit
        self.read = read
        self.write = write
        out = [UInt8](repeating: 0, count: Self.window + Swift.max(flushAt, 258))
    }

    /// Inflates the whole stream; returns the bytes produced.
    @discardableResult
    public mutating func run() throws -> UInt64 {
        var last = false
        repeat {
            last = try bits(1) == 1
            switch try bits(2) {
            case 0: try stored()
            case 1: try codes(Inflate.Tables.fixedLength, Inflate.Tables.fixedDistance)
            case 2: try dynamic()
            default: throw ClientError.protocolChanged("deflate: invalid block type")
            }
        } while !last
        try flush(keep: 0)
        return produced
    }

    // MARK: input

    private mutating func more() throws -> Bool {
        guard !ended else { return false }
        while true {
            guard let next = try read() else {
                ended = true
                return false
            }
            if next.isEmpty { continue }
            input = next
            pos = 0
            return true
        }
    }

    private mutating func refill() throws {
        while bitCount <= 56 {
            if pos == input.count, try !more() { return }
            bitBuf |= UInt64(input[pos]) << UInt64(bitCount)
            pos += 1
            bitCount += 8
        }
    }

    private mutating func bits(_ need: Int) throws -> Int {
        if bitCount < need {
            try refill()
            guard bitCount >= need else { throw ClientError.protocolChanged("deflate: truncated input") }
        }
        let val = Int(truncatingIfNeeded: bitBuf & ((1 << UInt64(need)) - 1))
        bitBuf >>= UInt64(need)
        bitCount -= need
        return val
    }

    // MARK: output

    /// Writes all but the last `keep` bytes of the buffer and slides those to its start.
    private mutating func flush(keep: Int) throws {
        let n = count - keep
        guard n > 0 else { return }
        try out.withUnsafeBytes { try write(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        out.withUnsafeMutableBufferPointer { b in
            b.baseAddress!.update(from: b.baseAddress! + n, count: keep)
        }
        count = keep
    }

    /// Room for `n` more bytes, flushing what the window no longer needs.
    @inline(__always) private mutating func reserve(_ n: Int) throws {
        guard produced + UInt64(n) <= limit else { throw ClientError.unsafeContent("inflate exceeds declared size \(limit)") }
        if count + n > out.count { try flush(keep: Swift.min(count, Self.window)) }
    }

    @inline(__always) private mutating func emit(_ byte: UInt8) {
        out[count] = byte
        count += 1
        produced += 1
    }

    // MARK: blocks

    private mutating func stored() throws {
        // Drop to a byte boundary; whole bytes still in the bit buffer come first.
        let drop = bitCount & 7
        bitBuf >>= UInt64(drop)
        bitCount -= drop
        let len = try bits(16), nlen = try bits(16)
        guard len == (~nlen & 0xFFFF) else { throw ClientError.protocolChanged("deflate: stored length mismatch") }
        var left = len
        while left > 0, bitCount >= 8 {
            try reserve(1)
            emit(UInt8(truncatingIfNeeded: bitBuf))
            bitBuf >>= 8
            bitCount -= 8
            left -= 1
        }
        while left > 0 {
            if pos == input.count, try !more() { throw ClientError.protocolChanged("deflate: truncated stored block") }
            let take = Swift.min(left, input.count - pos, out.count - Self.window)
            try reserve(take)
            for i in 0..<take { out[count + i] = input[pos + i] }
            count += take
            produced += UInt64(take)
            pos += take
            left -= take
        }
    }

    private mutating func decode(_ h: Inflate.Huffman) throws -> Int {
        if bitCount < 15 { try refill() }
        let e = Int(h.fast[Int(truncatingIfNeeded: bitBuf) & ((1 << Inflate.Huffman.fastBits) - 1)])
        if e != 0, e & 15 <= bitCount {
            bitBuf >>= UInt64(e & 15)
            bitCount -= e & 15
            return e >> 4
        }
        var code = 0, first = 0, index = 0
        for len in 1...15 {
            code |= try bits(1)
            let n = Int(h.count[len])
            if code - n < first {
                let at = index + (code - first)
                guard at < h.symbol.count else { throw ClientError.protocolChanged("deflate: over-subscribed code") }
                return Int(h.symbol[at])
            }
            index += n
            first += n
            first <<= 1
            code <<= 1
        }
        throw ClientError.protocolChanged("deflate: bad Huffman code")
    }

    private mutating func codes(_ lencode: Inflate.Huffman, _ distcode: Inflate.Huffman) throws {
        let lengthBase = Inflate.Tables.lengthBase, lengthExtra = Inflate.Tables.lengthExtra
        let distBase = Inflate.Tables.distBase, distExtra = Inflate.Tables.distExtra
        while true {
            var sym = try decode(lencode)
            if sym < 256 {
                try reserve(1)
                emit(UInt8(truncatingIfNeeded: sym))
                continue
            }
            if sym == 256 { return }
            sym -= 257
            guard sym < 29 else { throw ClientError.protocolChanged("deflate: bad length symbol") }
            let len = lengthBase[sym] + (try bits(lengthExtra[sym]))
            let dsym = try decode(distcode)
            guard dsym < 30 else { throw ClientError.protocolChanged("deflate: bad distance symbol") }
            let dist = distBase[dsym] + (try bits(distExtra[dsym]))
            try reserve(len)
            guard dist <= count else { throw ClientError.protocolChanged("deflate: distance too far back") }
            // Byte by byte: a match may overlap the bytes it produces.
            for _ in 0..<len { emit(out[count - dist]) }
        }
    }

    private mutating func dynamic() throws {
        let nlen = try bits(5) + 257, ndist = try bits(5) + 1, ncode = try bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw ClientError.protocolChanged("deflate: bad counts") }
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var lengths = [Int](repeating: 0, count: 320)
        for i in 0..<ncode { lengths[order[i]] = try bits(3) }
        let lencode = try Inflate.Huffman(lengths: Array(lengths[0..<19]))
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
        try codes(Inflate.Huffman(lengths: Array(lengths[0..<nlen])), Inflate.Huffman(lengths: Array(lengths[nlen..<(nlen + ndist)])))
    }
}
