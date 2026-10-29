// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// MD5 (RFC 1321), for content integrity only: GOG names its chunks and files
/// by their md5. Nothing here protects a secret.
public enum MD5 {
    public static func hash(_ data: [UInt8]) -> [UInt8] {
        var s = MD5Stream()
        s.update(data)
        return s.finalize()
    }
}

/// Incremental MD5 over 64-byte blocks, in bounded memory.
public struct MD5Stream: Sendable {
    private var h: (UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476)
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
        for i in 0..<8 { tail.append(UInt8(truncatingIfNeeded: bits >> (UInt64(i) * 8))) }
        tail.withUnsafeBytes { p in
            for block in stride(from: 0, to: p.count, by: 64) { copy.compress(p.baseAddress! + block) }
        }
        var out = [UInt8]()
        out.reserveCapacity(16)
        for v in [copy.h.0, copy.h.1, copy.h.2, copy.h.3] {
            out += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
                    UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
        }
        return out
    }

    private static let s: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                      5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                      4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                      6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
    private static let k: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4_294_967_296)) }

    private mutating func compress(_ p: UnsafeRawPointer) {
        var m = [UInt32](repeating: 0, count: 16)
        for t in 0..<16 { m[t] = UInt32(littleEndian: p.loadUnaligned(fromByteOffset: t * 4, as: UInt32.self)) }
        var (a, b, c, d) = h
        for i in 0..<64 {
            var f: UInt32
            let g: Int
            switch i {
            case 0..<16: f = (b & c) | (~b & d); g = i
            case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
            case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
            default: f = c ^ (b | ~d); g = (7 * i) % 16
            }
            f = f &+ a &+ Self.k[i] &+ m[g]
            a = d; d = c; c = b
            b = b &+ f.rotl(Self.s[i])
        }
        h = (h.0 &+ a, h.1 &+ b, h.2 &+ c, h.3 &+ d)
    }
}
