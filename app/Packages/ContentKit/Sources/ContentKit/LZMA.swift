// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// LZMA1 decoder for a stream of known uncompressed size, following Igor
/// Pavlov's public-domain reference decoder (LzmaSpec.cpp). Steam's VZip depot
/// chunks carry the 5-byte properties and the size separately, so this takes
/// both explicitly. Output never exceeds `outSize`; the dictionary is capped
/// at `maxDictionary` so a hostile header cannot demand gigabytes.
public enum LZMA {
    public static let maxDictionary = 64 << 20

    public static func decompress(_ input: ArraySlice<UInt8>, properties: UInt8, dictionarySize: UInt32, outSize: Int) throws -> [UInt8] {
        var d = properties
        guard d < 9 * 5 * 5 else { throw ClientError.protocolChanged("lzma: bad properties byte") }
        let lc = Int(d % 9); d /= 9
        let lp = Int(d % 5)
        let pb = Int(d / 5)
        guard Int(dictionarySize) <= maxDictionary else {
            throw ClientError.unsafeContent("lzma dictionary \(dictionarySize) exceeds \(maxDictionary)")
        }
        guard outSize > 0 else {
            _ = try input.withUnsafeBufferPointer { try rangeCoderInit($0) }
            return []
        }
        return try input.withUnsafeBufferPointer { inp in
            try [UInt8](unsafeUninitializedCapacity: outSize) { buf, count in
                count = try decode(inp, into: buf.baseAddress!, outSize: outSize, lc: lc, lp: lp, pb: pb)
            }
        }
    }

    private static let kNumStates = 12
    private static let kMatchMinLen = 2
    private static let kEndPosModelIndex = 14
    private static let kNumFullDistances = 1 << (kEndPosModelIndex >> 1)
    private static let kNumAlignBits = 4
    private static let kNumLenToPosStates = 4
    private static let kNumPosBitsMax = 4
    private static let probInit: UInt16 = 1 << 10

    /// Checks the range coder's 5-byte preamble; returns the initial code.
    static func rangeCoderInit(_ input: UnsafeBufferPointer<UInt8>) throws -> UInt32 {
        guard input.count >= 5, input[0] == 0 else { throw ClientError.protocolChanged("lzma: bad range coder init") }
        var code: UInt32 = 0
        for i in 1...4 { code = code << 8 | UInt32(input[i]) }
        guard code != 0xFFFF_FFFF else { throw ClientError.protocolChanged("lzma: corrupted range coder") }
        return code
    }

    /// Every probability lives in one allocation; these are the offsets.
    enum Layout {
        static let isMatch = 0
        static let isRep = isMatch + (kNumStates << kNumPosBitsMax)
        static let isRepG0 = isRep + kNumStates
        static let isRepG1 = isRepG0 + kNumStates
        static let isRepG2 = isRepG1 + kNumStates
        static let isRep0Long = isRepG2 + kNumStates
        static let posSlot = isRep0Long + (kNumStates << kNumPosBitsMax)
        static let posDecoders = posSlot + (kNumLenToPosStates << 6)
        static let align = posDecoders + 1 + kNumFullDistances - kEndPosModelIndex
        // A length decoder: choice, choice2, low and mid ((1 << kNumPosBitsMax)
        // trees of 3 bits, tree i at i*8), then high (one tree of 8 bits).
        static let lenChoice = 0, lenChoice2 = 1, lenLow = 2
        static let lenMid = lenLow + ((1 << kNumPosBitsMax) << 3)
        static let lenHigh = lenMid + ((1 << kNumPosBitsMax) << 3)
        static let lenSize = lenHigh + (1 << 8)
        static let lenDecoder = align + (1 << kNumAlignBits)
        static let repLenDecoder = lenDecoder + lenSize
        static let literal = repLenDecoder + lenSize
    }

    /// The range coder. `decode` keeps it in a local and every method is
    /// inlined, so its fields stay in registers. Input past the end reads as
    /// zeros; `decode` checks `ip` once per symbol, so a truncated stream
    /// still fails (and output stays bounded by `outSize` meanwhile) without
    /// a check per bit.
    struct RangeCoder {
        let inp: UnsafePointer<UInt8>
        let inEnd: Int
        var ip = 5
        var range: UInt32 = 0xFFFF_FFFF
        var code: UInt32

        @inline(__always) mutating func normalize() {
            if range < (1 << 24) {
                range <<= 8
                code = code << 8 | (ip < inEnd ? UInt32(inp[ip]) : 0)
                ip &+= 1
            }
        }

        @inline(__always) mutating func bit(_ p: UnsafeMutablePointer<UInt16>) -> Int {
            let v = UInt32(p.pointee)
            let bound = (range >> 11) &* v
            if code < bound {
                p.pointee = UInt16(truncatingIfNeeded: v &+ (((1 << 11) &- v) >> 5))
                range = bound
                normalize()
                return 0
            }
            p.pointee = UInt16(truncatingIfNeeded: v &- (v >> 5))
            code &-= bound
            range &-= bound
            normalize()
            return 1
        }

        @inline(__always) mutating func bitTree(_ p: UnsafeMutablePointer<UInt16>, _ numBits: Int) -> Int {
            var m = 1
            for _ in 0..<numBits { m = (m << 1) &+ bit(p + m) }
            return m &- (1 << numBits)
        }

        @inline(__always) mutating func bitTreeReverse(_ p: UnsafeMutablePointer<UInt16>, _ numBits: Int) -> Int {
            var m = 1, symbol = 0
            for i in 0..<numBits {
                let b = bit(p + m)
                m = (m << 1) &+ b
                symbol |= b << i
            }
            return symbol
        }

        @inline(__always) mutating func directBits(_ numBits: Int) throws -> UInt32 {
            var res: UInt32 = 0
            for _ in 0..<numBits {
                range >>= 1
                code &-= range
                let t = 0 &- (code >> 31)
                code &+= range & t
                guard code != range else { throw ClientError.protocolChanged("lzma: corrupted direct bits") }
                normalize()
                res = res << 1 &+ (t &+ 1)
            }
            return res
        }

        // Taken and returned by value (below), and never inlined: `decode` is too
        // large for the inliner to take them, and a call by reference would
        // pin its range coder to memory for the whole loop.
        @inline(never) static func len(_ rc: RangeCoder, _ p: UnsafeMutablePointer<UInt16>, _ posState: Int) -> (Int, RangeCoder) {
            var rc = rc
            return (rc.len(p, posState), rc)
        }

        @inline(never) static func distance(_ rc: RangeCoder, _ probs: UnsafeMutablePointer<UInt16>, _ len: Int) throws -> (Int, RangeCoder) {
            var rc = rc
            return (try rc.distance(probs, len), rc)
        }

        @inline(__always) mutating func len(_ p: UnsafeMutablePointer<UInt16>, _ posState: Int) -> Int {
            if bit(p + Layout.lenChoice) == 0 { return bitTree(p + Layout.lenLow + (posState << 3), 3) }
            if bit(p + Layout.lenChoice2) == 0 { return 8 &+ bitTree(p + Layout.lenMid + (posState << 3), 3) }
            return 16 &+ bitTree(p + Layout.lenHigh, 8)
        }

        @inline(__always) mutating func distance(_ probs: UnsafeMutablePointer<UInt16>, _ len: Int) throws -> Int {
            let lenState = Swift.min(len, kNumLenToPosStates - 1)
            let slot = bitTree(probs + Layout.posSlot + (lenState << 6), 6)
            if slot < 4 { return slot }
            let numDirectBits = (slot >> 1) - 1
            var dist = (2 | (slot & 1)) << numDirectBits
            if slot < kEndPosModelIndex {
                dist += bitTreeReverse(probs + Layout.posDecoders + dist - slot, numDirectBits)
            } else {
                dist += Int(try directBits(numDirectBits - kNumAlignBits)) << kNumAlignBits
                dist += bitTreeReverse(probs + Layout.align, kNumAlignBits)
            }
            return dist
        }
    }

    /// Decodes the whole stream into `out`; returns the bytes produced.
    static func decode(_ input: UnsafeBufferPointer<UInt8>, into out: UnsafeMutablePointer<UInt8>, outSize: Int,
                       lc: Int, lp: Int, pb: Int) throws -> Int {
        var rc = RangeCoder(inp: input.baseAddress!, inEnd: input.count, code: try rangeCoderInit(input))
        let probCount = Layout.literal + (0x300 << (lc + lp))
        let probs = UnsafeMutablePointer<UInt16>.allocate(capacity: probCount)
        probs.initialize(repeating: probInit, count: probCount)
        defer { probs.deallocate() }
        var pos = 0

        var rep0 = 0, rep1 = 0, rep2 = 0, rep3 = 0
        var state = 0
        let pbMask = (1 << pb) - 1, lpMask = (1 << lp) - 1, litShift = 8 - lc
        while pos < outSize {
            // Reading past the end is corruption, not a reason to spin on zeros.
            guard rc.ip <= rc.inEnd else { throw ClientError.protocolChanged("lzma: truncated input") }
            let posState = pos & pbMask
            if rc.bit(probs + Layout.isMatch + (state << kNumPosBitsMax) + posState) == 0 {
                let prevByte = pos == 0 ? 0 : Int(out[pos - 1])
                let p = probs + Layout.literal + 0x300 * (((pos & lpMask) << lc) + (prevByte >> litShift))
                var symbol = 1
                if state >= 7 {
                    guard rep0 < pos else { throw ClientError.protocolChanged("lzma: distance beyond output") }
                    var matchByte = Int(out[pos - rep0 - 1])
                    repeat {
                        let matchBit = (matchByte >> 7) & 1
                        matchByte <<= 1
                        let b = rc.bit(p + ((1 + matchBit) << 8) + symbol)
                        symbol = (symbol << 1) | b
                        if matchBit != b { break }
                    } while symbol < 0x100
                }
                while symbol < 0x100 { symbol = (symbol << 1) | rc.bit(p + symbol) }
                out[pos] = UInt8(truncatingIfNeeded: symbol)
                pos &+= 1
                state = state < 4 ? 0 : (state < 10 ? state - 3 : state - 6)
                continue
            }
            // One length decode for both kinds of match, so it inlines once.
            let isRep = rc.bit(probs + Layout.isRep + state) != 0
            if isRep {
                guard pos > 0 else { throw ClientError.protocolChanged("lzma: rep match at start") }
                if rc.bit(probs + Layout.isRepG0 + state) == 0 {
                    if rc.bit(probs + Layout.isRep0Long + (state << kNumPosBitsMax) + posState) == 0 {
                        guard rep0 < pos else { throw ClientError.protocolChanged("lzma: distance beyond output") }
                        state = state < 7 ? 9 : 11
                        out[pos] = out[pos - rep0 - 1]
                        pos &+= 1
                        continue
                    }
                } else {
                    let dist: Int
                    if rc.bit(probs + Layout.isRepG1 + state) == 0 {
                        dist = rep1
                    } else {
                        if rc.bit(probs + Layout.isRepG2 + state) == 0 {
                            dist = rep2
                        } else {
                            dist = rep3; rep3 = rep2
                        }
                        rep2 = rep1
                    }
                    rep1 = rep0; rep0 = dist
                }
                state = state < 7 ? 8 : 11
            } else {
                rep3 = rep2; rep2 = rep1; rep1 = rep0
                state = state < 7 ? 7 : 10
            }
            var len: Int
            (len, rc) = RangeCoder.len(rc, probs + (isRep ? Layout.repLenDecoder : Layout.lenDecoder), posState)
            if !isRep {
                (rep0, rc) = try RangeCoder.distance(rc, probs, len)
                if rep0 == 0xFFFF_FFFF { return pos } // end marker
            }
            guard rep0 < pos else { throw ClientError.protocolChanged("lzma: distance beyond output") }
            len += kMatchMinLen
            guard pos + len <= outSize else { throw ClientError.unsafeContent("lzma output exceeds declared size \(outSize)") }
            // Byte by byte: a match may overlap the bytes it produces.
            var src = out + (pos - rep0 - 1)
            var dst = out + pos
            for _ in 0..<len { dst.pointee = src.pointee; dst += 1; src += 1 }
            pos &+= len
        }
        guard rc.ip <= rc.inEnd else { throw ClientError.protocolChanged("lzma: truncated input") }
        return pos
    }
}
