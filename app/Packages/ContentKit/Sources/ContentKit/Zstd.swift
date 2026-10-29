// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Zstandard (RFC 8878) frame decoder, portable Swift, following the
/// structure of the reference educational decoder
/// (facebook/zstd doc/educational_decoder/zstd_decompress.c). Steam's current
/// depot chunks are zstd frames inside a "VSZa" container. Output is bounded
/// by the caller's limit; dictionaries are refused (Steam does not use them).
public enum Zstd {
    static let magic: UInt32 = 0xFD2F_B528
    static let maxBlockSize = 128 << 10

    public static func decompress(_ src: ArraySlice<UInt8>, limit: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(min(limit, 1 << 24))
        var i = src.startIndex
        while i < src.endIndex {
            guard src.endIndex - i >= 4 else { throw err("truncated frame magic") }
            let m = src.readLE32(at: i)
            if m & 0xFFFF_FFF0 == 0x184D_2A50 { // skippable frame
                guard src.endIndex - i >= 8 else { throw err("truncated skippable frame") }
                let n = Int(src.readLE32(at: i + 4))
                guard n <= src.endIndex - i - 8 else { throw err("truncated skippable frame") }
                i += 8 + n
                continue
            }
            guard m == magic else { throw err(String(format: "bad frame magic 0x%08x", m)) }
            i += 4
            var frame = FrameDecoder(src: src, pos: i, limit: limit)
            try frame.decode(into: &out)
            i = frame.pos
        }
        return out
    }

    static func err(_ s: String) -> ClientError { .protocolChanged("zstd: \(s)") }

    // MARK: bit readers

    /// Forward, LSB-first (FSE table headers).
    struct ForwardBits {
        let src: ArraySlice<UInt8>
        var bitPos: Int // absolute bit offset from src.startIndex
        let end: Int    // bit limit

        init(_ src: ArraySlice<UInt8>) { self.src = src; bitPos = 0; end = src.count * 8 }

        mutating func read(_ n: Int) throws -> Int {
            guard n > 0 else { return 0 }
            guard bitPos + n <= end else { throw err("forward bitstream overrun") }
            var v = 0
            for k in 0..<n {
                let b = bitPos + k
                v |= Int((src[src.startIndex + (b >> 3)] >> UInt8(b & 7)) & 1) << k
            }
            bitPos += n
            return v
        }
        mutating func rewind(_ n: Int) { bitPos -= n }
        var bytesConsumed: Int { (bitPos + 7) / 8 }
    }

    /// Backward bitstream (Huffman streams, FSE-coded data), read from the
    /// end; `offset` may go below zero, in which case zeros are shifted in.
    struct BackwardBits {
        let src: ArraySlice<UInt8>
        var offset: Int

        init(_ src: ArraySlice<UInt8>) throws {
            guard let last = src.last, last != 0 else { throw err("backward bitstream without end marker") }
            self.src = src
            // Total bits minus the padding above the final 1-bit marker.
            let hsb = 7 - last.leadingZeroBitCount
            offset = src.count * 8 - (8 - hsb)
        }

        mutating func read(_ n: Int) -> Int {
            guard n > 0 else { return 0 }
            offset -= n
            var start = offset
            var count = n
            var shift = 0
            if start < 0 {
                shift = -start
                count += start
                start = 0
                if count <= 0 { return 0 }
            }
            var v = 0
            for k in 0..<count {
                let b = start + k
                v |= Int((src[src.startIndex + (b >> 3)] >> UInt8(b & 7)) & 1) << k
            }
            return v << shift
        }
    }

    // MARK: FSE

    struct FSETable {
        var symbols: [UInt8] = []
        var numBits: [UInt8] = []
        var newStateBase: [UInt16] = []
        var accuracyLog = 0

        static func rle(_ symbol: UInt8) -> FSETable {
            FSETable(symbols: [symbol], numBits: [0], newStateBase: [0], accuracyLog: 0)
        }

        init(symbols: [UInt8], numBits: [UInt8], newStateBase: [UInt16], accuracyLog: Int) {
            self.symbols = symbols; self.numBits = numBits; self.newStateBase = newStateBase; self.accuracyLog = accuracyLog
        }

        init(normalized freqs: [Int], accuracyLog: Int) throws {
            let size = 1 << accuracyLog
            self.accuracyLog = accuracyLog
            symbols = [UInt8](repeating: 0, count: size)
            numBits = [UInt8](repeating: 0, count: size)
            newStateBase = [UInt16](repeating: 0, count: size)
            var stateDesc = [Int](repeating: 0, count: freqs.count)
            var high = size
            for (s, f) in freqs.enumerated() where f == -1 {
                high -= 1
                guard high >= 0 else { throw err("FSE table overfull") }
                symbols[high] = UInt8(s)
                stateDesc[s] = 1
            }
            let step = (size >> 1) + (size >> 3) + 3
            let mask = size - 1
            var pos = 0
            for (s, f) in freqs.enumerated() where f > 0 {
                stateDesc[s] = f
                for _ in 0..<f {
                    symbols[pos] = UInt8(s)
                    repeat { pos = (pos + step) & mask } while pos >= high
                }
            }
            guard pos == 0 else { throw err("FSE distribution does not cover the table") }
            for i in 0..<size {
                let s = Int(symbols[i])
                let next = stateDesc[s]
                stateDesc[s] += 1
                guard next > 0 else { throw err("FSE state underflow") }
                let hsb = Int.bitWidth - 1 - next.leadingZeroBitCount
                let bits = accuracyLog - hsb
                numBits[i] = UInt8(bits)
                newStateBase[i] = UInt16((next << bits) - size)
            }
        }

        /// Table description (RFC 8878 4.1.1), read forward from `src`.
        static func read(_ src: ArraySlice<UInt8>, maxAccuracy: Int, maxSymbol: Int) throws -> (FSETable, consumed: Int) {
            var r = ForwardBits(src)
            let accuracy = try r.read(4) + 5
            guard accuracy <= maxAccuracy else { throw err("FSE accuracy \(accuracy) > \(maxAccuracy)") }
            var remaining = (1 << accuracy) + 1
            var freqs: [Int] = []
            while remaining > 1 && freqs.count <= maxSymbol {
                let bits = (Int.bitWidth - remaining.leadingZeroBitCount)
                var val = try r.read(bits)
                let lowerMask = (1 << (bits - 1)) - 1
                let threshold = (1 << bits) - 1 - remaining
                if (val & lowerMask) < threshold {
                    r.rewind(1)
                    val &= lowerMask
                } else if val > lowerMask {
                    val -= threshold
                }
                let proba = val - 1
                remaining -= abs(proba)
                freqs.append(proba)
                if proba == 0 {
                    var rep = try r.read(2)
                    while true {
                        for _ in 0..<rep where freqs.count <= maxSymbol { freqs.append(0) }
                        if rep == 3 { rep = try r.read(2) } else { break }
                    }
                }
            }
            guard remaining == 1, freqs.count <= maxSymbol + 1 else { throw err("FSE table description is inconsistent") }
            return (try FSETable(normalized: freqs, accuracyLog: accuracy), r.bytesConsumed)
        }

        func initState(_ bits: inout BackwardBits) -> Int { bits.read(accuracyLog) }
        func peek(_ state: Int) -> UInt8 { symbols[state] }
        func update(_ state: inout Int, _ bits: inout BackwardBits) {
            state = Int(newStateBase[state]) + bits.read(Int(numBits[state]))
        }
    }

    // MARK: Huffman

    struct HuffmanTable {
        var symbols: [UInt8]
        var numBits: [UInt8]
        var maxBits: Int

        init(bits: [Int]) throws {
            guard let mb = bits.max(), mb > 0, mb <= 11 else { throw err("Huffman max bits out of range") }
            maxBits = mb
            let size = 1 << mb
            symbols = [UInt8](repeating: 0, count: size)
            numBits = [UInt8](repeating: 0, count: size)
            var rankCount = [Int](repeating: 0, count: mb + 2)
            for b in bits where b > 0 { rankCount[b] += 1 }
            var rankIdx = [Int](repeating: 0, count: mb + 2)
            rankIdx[mb] = 0
            var i = mb
            while i >= 1 {
                rankIdx[i - 1] = rankIdx[i] + rankCount[i] * (1 << (mb - i))
                guard rankIdx[i - 1] <= size else { throw err("Huffman table overfull") }
                for k in rankIdx[i]..<rankIdx[i - 1] { numBits[k] = UInt8(i) }
                i -= 1
            }
            guard rankIdx[0] == size else { throw err("Huffman table incomplete") }
            for (s, b) in bits.enumerated() where b > 0 {
                let code = rankIdx[b]
                let len = 1 << (mb - b)
                for k in code..<(code + len) { symbols[k] = UInt8(s) }
                rankIdx[b] += len
            }
        }

        init(weights: [Int]) throws {
            guard weights.count + 1 <= 256 else { throw err("too many Huffman weights") }
            var sum = 0
            for w in weights {
                guard w <= 11 else { throw err("Huffman weight \(w)") }
                if w > 0 { sum += 1 << (w - 1) }
            }
            guard sum > 0 else { throw err("Huffman weights sum to zero") }
            let maxBits = Int.bitWidth - sum.leadingZeroBitCount // highest_set_bit + 1
            let leftOver = (1 << maxBits) - sum
            guard leftOver & (leftOver - 1) == 0 else { throw err("Huffman weights do not complete a tree") }
            let lastWeight = Int.bitWidth - leftOver.leadingZeroBitCount
            var bits = weights.map { $0 > 0 ? maxBits + 1 - $0 : 0 }
            bits.append(maxBits + 1 - lastWeight)
            try self.init(bits: bits)
        }

        /// Tree description (RFC 8878 4.2.1); returns bytes consumed.
        static func read(_ src: ArraySlice<UInt8>) throws -> (HuffmanTable, consumed: Int) {
            guard let header = src.first else { throw err("missing Huffman header") }
            var weights: [Int] = []
            let consumed: Int
            if header >= 128 {
                let n = Int(header) - 127
                let bytes = (n + 1) / 2
                guard src.count >= 1 + bytes else { throw err("truncated Huffman weights") }
                for k in 0..<n {
                    let b = src[src.startIndex + 1 + k / 2]
                    weights.append(Int(k % 2 == 0 ? b >> 4 : b & 0x0F))
                }
                consumed = 1 + bytes
            } else {
                let size = Int(header)
                guard src.count >= 1 + size else { throw err("truncated FSE Huffman weights") }
                let body = src[(src.startIndex + 1)..<(src.startIndex + 1 + size)]
                let (fse, used) = try FSETable.read(body, maxAccuracy: 6, maxSymbol: 11)
                var bits = try BackwardBits(body.dropFirst(used))
                var s1 = fse.initState(&bits), s2 = fse.initState(&bits)
                while weights.count < 255 {
                    weights.append(Int(fse.peek(s1)))
                    fse.update(&s1, &bits)
                    if bits.offset < 0 { weights.append(Int(fse.peek(s2))); break }
                    weights.append(Int(fse.peek(s2)))
                    fse.update(&s2, &bits)
                    if bits.offset < 0 { weights.append(Int(fse.peek(s1))); break }
                }
                consumed = 1 + size
            }
            return (try HuffmanTable(weights: weights), consumed)
        }

        func decodeStream(_ src: ArraySlice<UInt8>, count: Int, into out: inout [UInt8]) throws {
            var bits = try BackwardBits(src)
            var state = bits.read(maxBits)
            let mask = (1 << maxBits) - 1
            for _ in 0..<count {
                out.append(symbols[state])
                let n = Int(numBits[state])
                state = ((state << n) + bits.read(n)) & mask
            }
            guard bits.offset == -maxBits else { throw err("Huffman stream length mismatch") }
        }
    }

    // MARK: sequences tables

    static let llDefault = [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1]
    static let mlDefault = [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1]
    static let ofDefault = [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1]
    static let llBase: [Int] = Array(0...15) + [16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    static let llBits: [Int] = [Int](repeating: 0, count: 16) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    static let mlBase: [Int] = Array(3...34) + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539]
    static let mlBits: [Int] = [Int](repeating: 0, count: 32) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    static let llPredef = try! FSETable(normalized: llDefault, accuracyLog: 6)
    static let mlPredef = try! FSETable(normalized: mlDefault, accuracyLog: 6)
    static let ofPredef = try! FSETable(normalized: ofDefault, accuracyLog: 5)

    // MARK: frame

    struct FrameDecoder {
        let src: ArraySlice<UInt8>
        var pos: Int
        let limit: Int
        var huffman: HuffmanTable?
        var llTable: FSETable?, ofTable: FSETable?, mlTable: FSETable?
        var rep: [Int] = [1, 4, 8]
        var frameStart = 0
        var windowSize = 0

        init(src: ArraySlice<UInt8>, pos: Int, limit: Int) { self.src = src; self.pos = pos; self.limit = limit }

        mutating func byte() throws -> UInt8 {
            guard pos < src.endIndex else { throw err("truncated frame header") }
            defer { pos += 1 }
            return src[pos]
        }

        mutating func decode(into out: inout [UInt8]) throws {
            frameStart = out.count
            let fhd = try byte()
            let fcsFlag = Int(fhd >> 6)
            let singleSegment = fhd & 0x20 != 0
            guard fhd & 0x08 == 0 else { throw err("reserved frame header bit set") }
            let checksum = fhd & 0x04 != 0
            let dictFlag = Int(fhd & 3)
            if !singleSegment {
                let wd = try byte()
                let exponent = Int(wd >> 3), mantissa = Int(wd & 7)
                let base = 1 << (10 + exponent)
                windowSize = base + (base / 8) * mantissa
            }
            let dictBytes = [0, 1, 2, 4][dictFlag]
            var dictID = 0
            for k in 0..<dictBytes { dictID |= Int(try byte()) << (8 * k) }
            guard dictID == 0 else { throw ClientError.unsupported("zstd dictionary frames") }
            let fcsBytes = [singleSegment ? 1 : 0, 2, 4, 8][fcsFlag]
            var fcs: UInt64 = 0
            for k in 0..<fcsBytes { fcs |= UInt64(try byte()) << (8 * UInt64(k)) }
            if fcsBytes == 2 { fcs += 256 }
            if fcsBytes > 0 {
                guard fcs <= UInt64(limit - out.count) else { throw ClientError.unsafeContent("zstd frame declares \(fcs) bytes (limit \(limit))") }
                if singleSegment { windowSize = Int(fcs) }
            }
            guard windowSize <= 64 << 20 || fcsBytes > 0 else { throw ClientError.unsafeContent("zstd window \(windowSize)") }

            var last = false
            while !last {
                guard src.endIndex - pos >= 3 else { throw err("truncated block header") }
                let h = Int(src[pos]) | Int(src[pos + 1]) << 8 | Int(src[pos + 2]) << 16
                pos += 3
                last = h & 1 != 0
                let type = (h >> 1) & 3
                let size = h >> 3
                switch type {
                case 0:
                    guard size <= src.endIndex - pos else { throw err("truncated raw block") }
                    guard out.count + size <= limit else { throw ClientError.unsafeContent("zstd output exceeds \(limit)") }
                    out.append(contentsOf: src[pos..<(pos + size)])
                    pos += size
                case 1:
                    guard pos < src.endIndex else { throw err("truncated RLE block") }
                    guard out.count + size <= limit else { throw ClientError.unsafeContent("zstd output exceeds \(limit)") }
                    out.append(contentsOf: repeatElement(src[pos], count: size))
                    pos += 1
                case 2:
                    guard size <= maxBlockSize, size <= src.endIndex - pos else { throw err("bad compressed block size") }
                    try compressedBlock(src[pos..<(pos + size)], into: &out)
                    pos += size
                default:
                    throw err("reserved block type")
                }
            }
            if fcsBytes > 0, UInt64(out.count - frameStart) != fcs {
                throw ClientError.verificationFailed("zstd frame produced \(out.count - frameStart) of \(fcs) bytes")
            }
            if checksum {
                guard src.endIndex - pos >= 4 else { throw err("truncated content checksum") }
                pos += 4 // content is verified by SHA-1 against the manifest instead
            }
        }

        mutating func compressedBlock(_ block: ArraySlice<UInt8>, into out: inout [UInt8]) throws {
            var i = block.startIndex
            // Literals section.
            guard i < block.endIndex else { throw err("empty block") }
            let b0 = Int(block[i])
            let litType = b0 & 3
            let sizeFormat = (b0 >> 2) & 3
            var literals: [UInt8] = []
            func need(_ n: Int) throws { guard block.endIndex - i >= n else { throw err("truncated literals header") } }
            if litType == 0 || litType == 1 {
                var regen: Int
                switch sizeFormat {
                case 0, 2: regen = b0 >> 3; i += 1
                case 1: try need(2); regen = (b0 >> 4) + (Int(block[i + 1]) << 4); i += 2
                default: try need(3); regen = (b0 >> 4) + (Int(block[i + 1]) << 4) + (Int(block[i + 2]) << 12); i += 3
                }
                guard regen <= maxBlockSize else { throw err("literals too large") }
                if litType == 0 {
                    guard block.endIndex - i >= regen else { throw err("truncated raw literals") }
                    literals = Array(block[i..<(i + regen)]); i += regen
                } else {
                    guard i < block.endIndex else { throw err("truncated RLE literals") }
                    literals = [UInt8](repeating: block[i], count: regen); i += 1
                }
            } else {
                var regen = 0, comp = 0, streams = 4
                switch sizeFormat {
                case 0, 1:
                    try need(3)
                    let c = b0 | Int(block[i + 1]) << 8 | Int(block[i + 2]) << 16
                    regen = (c >> 4) & 0x3FF; comp = (c >> 14) & 0x3FF; i += 3
                    streams = sizeFormat == 0 ? 1 : 4
                case 2:
                    try need(4)
                    let c = b0 | Int(block[i + 1]) << 8 | Int(block[i + 2]) << 16 | Int(block[i + 3]) << 24
                    regen = (c >> 4) & 0x3FFF; comp = (c >> 18) & 0x3FFF; i += 4
                default:
                    try need(5)
                    let c = b0 | Int(block[i + 1]) << 8 | Int(block[i + 2]) << 16 | Int(block[i + 3]) << 24 | Int(block[i + 4]) << 32
                    regen = (c >> 4) & 0x3FFFF; comp = (c >> 22) & 0x3FFFF; i += 5
                }
                guard regen <= maxBlockSize, comp <= block.endIndex - i else { throw err("bad compressed literals sizes") }
                var data = block[i..<(i + comp)]
                i += comp
                if litType == 2 {
                    let (t, used) = try HuffmanTable.read(data)
                    huffman = t
                    data = data.dropFirst(used)
                }
                guard let table = huffman else { throw err("treeless literals without a previous table") }
                literals.reserveCapacity(regen)
                if streams == 1 {
                    try table.decodeStream(data, count: regen, into: &literals)
                } else {
                    guard data.count >= 6 else { throw err("truncated jump table") }
                    let s = data.startIndex
                    let l1 = Int(data[s]) | Int(data[s + 1]) << 8
                    let l2 = Int(data[s + 2]) | Int(data[s + 3]) << 8
                    let l3 = Int(data[s + 4]) | Int(data[s + 5]) << 8
                    let a = s + 6
                    guard a + l1 + l2 + l3 <= data.endIndex else { throw err("jump table overruns literals") }
                    let per = (regen + 3) / 4
                    let lastCount = regen - 3 * per
                    guard lastCount >= 0 else { throw err("literal stream sizes") }
                    try table.decodeStream(data[a..<(a + l1)], count: per, into: &literals)
                    try table.decodeStream(data[(a + l1)..<(a + l1 + l2)], count: per, into: &literals)
                    try table.decodeStream(data[(a + l1 + l2)..<(a + l1 + l2 + l3)], count: per, into: &literals)
                    try table.decodeStream(data[(a + l1 + l2 + l3)...], count: lastCount, into: &literals)
                }
            }

            // Sequences section.
            guard i < block.endIndex else { throw err("missing sequences header") }
            let s0 = Int(block[i])
            var nbSeq = 0
            if s0 == 0 {
                i += 1
            } else if s0 < 128 {
                nbSeq = s0; i += 1
            } else if s0 < 255 {
                guard block.endIndex - i >= 2 else { throw err("truncated sequence count") }
                nbSeq = ((s0 - 128) << 8) + Int(block[i + 1]); i += 2
            } else {
                guard block.endIndex - i >= 3 else { throw err("truncated sequence count") }
                nbSeq = Int(block[i + 1]) + (Int(block[i + 2]) << 8) + 0x7F00; i += 3
            }
            if nbSeq == 0 {
                guard out.count + literals.count <= limit else { throw ClientError.unsafeContent("zstd output exceeds \(limit)") }
                out.append(contentsOf: literals)
                return
            }
            guard i < block.endIndex else { throw err("missing compression modes") }
            let modes = Int(block[i]); i += 1
            guard modes & 3 == 0 else { throw err("reserved compression mode bits") }
            func table(_ mode: Int, _ predef: FSETable, _ previous: FSETable?, maxAcc: Int, maxSym: Int) throws -> FSETable {
                switch mode {
                case 0: return predef
                case 1:
                    guard i < block.endIndex else { throw err("truncated RLE table") }
                    let t = FSETable.rle(block[i]); i += 1
                    return t
                case 2:
                    let (t, used) = try FSETable.read(block[i...], maxAccuracy: maxAcc, maxSymbol: maxSym)
                    i += used
                    return t
                default:
                    guard let previous else { throw err("repeat mode without a previous table") }
                    return previous
                }
            }
            llTable = try table(modes >> 6, Zstd.llPredef, llTable, maxAcc: 9, maxSym: 35)
            ofTable = try table((modes >> 4) & 3, Zstd.ofPredef, ofTable, maxAcc: 8, maxSym: 31)
            mlTable = try table((modes >> 2) & 3, Zstd.mlPredef, mlTable, maxAcc: 9, maxSym: 52)
            let ll = llTable!, of = ofTable!, ml = mlTable!

            var bits = try BackwardBits(block[i...])
            var llState = ll.initState(&bits), ofState = of.initState(&bits), mlState = ml.initState(&bits)
            var litPos = 0
            for n in 0..<nbSeq {
                let ofCode = Int(of.peek(ofState)), llCode = Int(ll.peek(llState)), mlCode = Int(ml.peek(mlState))
                guard llCode < Zstd.llBase.count, mlCode < Zstd.mlBase.count, ofCode <= 31 else { throw err("sequence code out of range") }
                let offsetValue = (1 << ofCode) + bits.read(ofCode)
                let matchLength = Zstd.mlBase[mlCode] + bits.read(Zstd.mlBits[mlCode])
                let literalLength = Zstd.llBase[llCode] + bits.read(Zstd.llBits[llCode])
                if n != nbSeq - 1 {
                    ll.update(&llState, &bits)
                    ml.update(&mlState, &bits)
                    of.update(&ofState, &bits)
                }
                // Repeat offsets (RFC 8878 3.1.1.5).
                var offset: Int
                if offsetValue > 3 {
                    offset = offsetValue - 3
                    rep = [offset, rep[0], rep[1]]
                } else {
                    var idx = offsetValue - 1
                    if literalLength == 0 { idx += 1 }
                    if idx == 0 {
                        offset = rep[0]
                    } else {
                        offset = idx < 3 ? rep[idx] : rep[0] - 1
                        if idx > 1 { rep[2] = rep[1] }
                        rep[1] = rep[0]
                        rep[0] = offset
                    }
                }
                guard literalLength <= literals.count - litPos else { throw err("sequence overruns literals") }
                guard out.count + literalLength + matchLength <= limit else { throw ClientError.unsafeContent("zstd output exceeds \(limit)") }
                out.append(contentsOf: literals[litPos..<(litPos + literalLength)])
                litPos += literalLength
                guard offset > 0, offset <= out.count - frameStart else { throw err("match offset beyond frame output") }
                let start = out.count - offset
                for k in 0..<matchLength { out.append(out[start + k]) }
            }
            guard bits.offset == 0 else { throw err("sequence bitstream not fully consumed") }
            guard out.count + (literals.count - litPos) <= limit else { throw ClientError.unsafeContent("zstd output exceeds \(limit)") }
            out.append(contentsOf: literals[litPos...])
        }
    }
}
