// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Portable hashes and checksums for content verification. They check integrity
// of public depot content against the signed manifest; nothing here protects a
// secret. Known-answer tests live in Tests/SteamClientKitTests/CryptoTests.swift.

public enum SHA1 {
    public static func hash(_ data: [UInt8]) -> [UInt8] {
        var s = SHA1Stream()
        s.update(data)
        return s.finalize()
    }
}

/// Incremental SHA-1: 64-byte blocks are compressed as they arrive, so a
/// multi-GB file is hashed in bounded memory (the installer feeds it `pread`
/// blocks).
public struct SHA1Stream: Sendable {
    private var h: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0)
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    public init() { pending.reserveCapacity(64) }

    public mutating func update(_ data: [UInt8]) {
        data.withUnsafeBufferPointer { update(UnsafeRawBufferPointer($0)) }
    }

    public mutating func update(_ data: UnsafeRawBufferPointer) {
        length &+= UInt64(data.count)
        var i = 0
        if !pending.isEmpty {
            let take = Swift.min(64 - pending.count, data.count)
            pending += data[0..<take]
            i = take
            guard pending.count == 64 else { return }
            pending.withUnsafeBytes { compress($0.baseAddress!) }
            pending.removeAll(keepingCapacity: true)
        }
        while data.count - i >= 64 {
            compress(data.baseAddress! + i)
            i += 64
        }
        if i < data.count { pending += data[i...] }
    }

    public func finalize() -> [UInt8] {
        var copy = self
        var tail = pending
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = length &* 8
        for i in (0..<8).reversed() { tail.append(UInt8(truncatingIfNeeded: bits >> (UInt64(i) * 8))) }
        tail.withUnsafeBytes { p in
            for block in stride(from: 0, to: p.count, by: 64) { copy.compress(p.baseAddress! + block) }
        }
        var out = [UInt8]()
        out.reserveCapacity(20)
        for v in [copy.h.0, copy.h.1, copy.h.2, copy.h.3, copy.h.4] {
            out += [UInt8(v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
        }
        return out
    }

    private mutating func compress(_ p: UnsafeRawPointer) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 80) { w in
            for t in 0..<16 {
                let j = t * 4
                w[t] = UInt32(p.load(fromByteOffset: j, as: UInt8.self)) << 24
                    | UInt32(p.load(fromByteOffset: j + 1, as: UInt8.self)) << 16
                    | UInt32(p.load(fromByteOffset: j + 2, as: UInt8.self)) << 8
                    | UInt32(p.load(fromByteOffset: j + 3, as: UInt8.self))
            }
            for t in 16..<80 { w[t] = (w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16]).rotl(1) }
            var (a, b, c, d, e) = h
            for t in 0..<80 {
                let f: UInt32, k: UInt32
                switch t {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                default: f = b ^ c ^ d; k = 0xCA62_C1D6
                }
                let temp = a.rotl(5) &+ f &+ e &+ k &+ w[t]
                e = d; d = c; c = b.rotl(30); b = a; a = temp
            }
            h = (h.0 &+ a, h.1 &+ b, h.2 &+ c, h.3 &+ d, h.4 &+ e)
        }
    }
}

/// Incremental SHA-256 (FIPS 180-4), for checking an adopted title against
/// the committed `sha256sum` list with no Steam session.
public struct SHA256Stream: Sendable {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    public init() { pending.reserveCapacity(64) }

    public static func hash(_ data: [UInt8]) -> [UInt8] {
        var s = SHA256Stream()
        s.update(data)
        return s.finalize()
    }

    public mutating func update(_ data: [UInt8]) {
        data.withUnsafeBufferPointer { update(UnsafeRawBufferPointer($0)) }
    }

    public mutating func update(_ data: UnsafeRawBufferPointer) {
        length &+= UInt64(data.count)
        var i = 0
        if !pending.isEmpty {
            let take = Swift.min(64 - pending.count, data.count)
            pending += data[0..<take]
            i = take
            guard pending.count == 64 else { return }
            pending.withUnsafeBytes { compress($0.baseAddress!) }
            pending.removeAll(keepingCapacity: true)
        }
        while data.count - i >= 64 {
            compress(data.baseAddress! + i)
            i += 64
        }
        if i < data.count { pending += data[i...] }
    }

    public func finalize() -> [UInt8] {
        var copy = self
        var tail = pending
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = length &* 8
        for i in (0..<8).reversed() { tail.append(UInt8(truncatingIfNeeded: bits >> (UInt64(i) * 8))) }
        tail.withUnsafeBytes { p in
            for block in stride(from: 0, to: p.count, by: 64) { copy.compress(p.baseAddress! + block) }
        }
        var out = [UInt8]()
        out.reserveCapacity(32)
        for v in copy.h {
            out += [UInt8(v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
        }
        return out
    }

    private mutating func compress(_ p: UnsafeRawPointer) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
            for t in 0..<16 {
                let j = t * 4
                w[t] = UInt32(p.load(fromByteOffset: j, as: UInt8.self)) << 24
                    | UInt32(p.load(fromByteOffset: j + 1, as: UInt8.self)) << 16
                    | UInt32(p.load(fromByteOffset: j + 2, as: UInt8.self)) << 8
                    | UInt32(p.load(fromByteOffset: j + 3, as: UInt8.self))
            }
            for t in 16..<64 {
                let s0 = w[t - 15].rotr(7) ^ w[t - 15].rotr(18) ^ (w[t - 15] >> 3)
                let s1 = w[t - 2].rotr(17) ^ w[t - 2].rotr(19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for t in 0..<64 {
                let s1 = e.rotr(6) ^ e.rotr(11) ^ e.rotr(25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ Self.k[t] &+ w[t]
                let s0 = a.rotr(2) ^ a.rotr(13) ^ a.rotr(22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
    }
}

extension UInt32 {
    @inline(__always) func rotl(_ n: UInt32) -> UInt32 { (self << n) | (self >> (32 - n)) }
    @inline(__always) func rotr(_ n: UInt32) -> UInt32 { (self >> n) | (self << (32 - n)) }
}

public enum CRC32 {
    /// Slicing-by-8: table k holds the CRC of a byte followed by k zero bytes.
    private static let tables: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 8 * 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            t[i] = c
        }
        for k in 1..<8 {
            for i in 0..<256 { t[256 * k + i] = t[256 * (k - 1) + i] >> 8 ^ t[Int(t[256 * (k - 1) + i] & 0xFF)] }
        }
        return t
    }()

    public static func checksum(_ data: [UInt8]) -> UInt32 { update(0, data) }

    public static func update(_ crc: UInt32, _ data: [UInt8]) -> UInt32 {
        data.withUnsafeBytes { update(crc, $0) }
    }

    public static func update(_ crc: UInt32, _ p: UnsafeRawBufferPointer) -> UInt32 {
        var c = ~crc
        do {
            tables.withUnsafeBufferPointer { t in
                var i = 0
                while p.count - i >= 8 {
                    let lo = c ^ UInt32(littleEndian: p.loadUnaligned(fromByteOffset: i, as: UInt32.self))
                    let hi = UInt32(littleEndian: p.loadUnaligned(fromByteOffset: i + 4, as: UInt32.self))
                    c = t[7 * 256 + Int(lo & 0xFF)] ^ t[6 * 256 + Int((lo >> 8) & 0xFF)]
                        ^ t[5 * 256 + Int((lo >> 16) & 0xFF)] ^ t[4 * 256 + Int(lo >> 24)]
                        ^ t[3 * 256 + Int(hi & 0xFF)] ^ t[2 * 256 + Int((hi >> 8) & 0xFF)]
                        ^ t[256 + Int((hi >> 16) & 0xFF)] ^ t[Int(hi >> 24)]
                    i += 8
                }
                while i < p.count {
                    c = t[Int((c ^ UInt32(p[i])) & 0xFF)] ^ (c >> 8)
                    i += 1
                }
            }
        }
        return ~c
    }
}

/// Adler-32 as Steam uses it for chunk checksums: seeded with 0, not 1
/// (JavaSteam util/Adler32.kt `calculate(buffer) = calculate(0, buffer)`).
public enum SteamAdler32 {
    public static func checksum(_ data: [UInt8], seed: UInt32 = 0) -> UInt32 {
        var s1 = seed & 0xFFFF, s2 = (seed >> 16) & 0xFFFF
        var i = 0
        while i < data.count {
            let n = Swift.min(5552, data.count - i)
            for j in i..<(i + n) { s1 &+= UInt32(data[j]); s2 &+= s1 }
            s1 %= 65521; s2 %= 65521
            i += n
        }
        return s2 << 16 | s1
    }
}
