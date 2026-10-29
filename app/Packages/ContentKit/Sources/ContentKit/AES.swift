// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// AES-256 decryption (FIPS-197), the one symmetric primitive Steam content
/// needs: depot chunks and encrypted manifest filenames are
/// `AES-ECB(key, iv-block) || AES-CBC-PKCS7(key, iv, body)` (DepotChunk.kt).
/// Portable Swift so the same code runs on the Linux host and iOS; checked
/// against FIPS-197 C.3 and OpenSSL-generated vectors in CryptoTests.
public struct AES256Decryptor: Sendable {
    /// The equivalent inverse cipher's schedule (FIPS-197 5.3.5): 15 round
    /// keys in decryption order, the middle 13 passed through InvMixColumns.
    private let roundKeys: [UInt32] // 60 words

    public init(key: [UInt8]) throws {
        guard key.count == 32 else { throw ClientError.protocolChanged("depot key is \(key.count) bytes, expected 32") }
        var w = [UInt32](repeating: 0, count: 60)
        for i in 0..<8 {
            w[i] = UInt32(key[4 * i]) << 24 | UInt32(key[4 * i + 1]) << 16 | UInt32(key[4 * i + 2]) << 8 | UInt32(key[4 * i + 3])
        }
        var rcon: UInt32 = 0x01
        for i in 8..<60 {
            var t = w[i - 1]
            if i % 8 == 0 {
                t = Self.subWord(t.rotl(8)) ^ (rcon << 24)
                rcon = Self.xtime(UInt8(rcon)).asU32
            } else if i % 8 == 4 {
                t = Self.subWord(t)
            }
            w[i] = w[i - 8] ^ t
        }
        var d = [UInt32](repeating: 0, count: 60)
        for round in 0...14 {
            for c in 0..<4 {
                let k = w[(14 - round) * 4 + c]
                d[round * 4 + c] = round == 0 || round == 14 ? k : Self.invMixColumn(k)
            }
        }
        roundKeys = d
    }

    /// Decrypts one 16-byte block in place.
    public func decryptBlock(_ block: inout [UInt8], at offset: Int = 0) {
        precondition(offset >= 0 && offset + 16 <= block.count)
        block.withUnsafeMutableBytes { b in
            roundKeys.withUnsafeBufferPointer { rk in
                Self.tables.withUnsafeBufferPointer { td in
                    Self.decrypt(b.baseAddress! + offset, rk.baseAddress!, td.baseAddress!, chain: nil)
                }
            }
        }
    }

    /// CBC decryption with PKCS#7 padding removal.
    public func decryptCBC(_ data: ArraySlice<UInt8>, iv: [UInt8]) throws -> [UInt8] {
        guard data.count % 16 == 0, !data.isEmpty else {
            throw ClientError.verificationFailed("ciphertext length \(data.count) is not a positive multiple of 16")
        }
        precondition(iv.count == 16)
        var out = Array(data)
        out.withUnsafeMutableBytes { b in
            roundKeys.withUnsafeBufferPointer { rk in
                Self.tables.withUnsafeBufferPointer { td in
                    // Back to front, so each block's chaining value is still the
                    // ciphertext of the block before it.
                    var off = b.count - 16
                    while off > 0 {
                        Self.decrypt(b.baseAddress! + off, rk.baseAddress!, td.baseAddress!, chain: UnsafeRawPointer(b.baseAddress! + off - 16))
                        off -= 16
                    }
                    iv.withUnsafeBytes { Self.decrypt(b.baseAddress!, rk.baseAddress!, td.baseAddress!, chain: $0.baseAddress!) }
                }
            }
        }
        let pad = Int(out.last!)
        guard pad >= 1, pad <= 16, out.suffix(pad).allSatisfy({ Int($0) == pad }) else {
            throw ClientError.verificationFailed("bad PKCS#7 padding (wrong depot key?)")
        }
        out.removeLast(pad)
        return out
    }

    /// Steam's symmetric scheme: the first block is the ECB-encrypted IV.
    public func decryptSteam(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count >= 32 else { throw ClientError.verificationFailed("encrypted blob of \(data.count) bytes is too short") }
        var iv = Array(data[0..<16])
        decryptBlock(&iv)
        return try decryptCBC(data[16...], iv: iv)
    }

    /// One block in place, table-driven (Td0..Td3 then the inverse S-box, as
    /// OpenSSL's aes_core.c), XORed with `chain` when given. Every CBC block is
    /// in place and `chain` points at the ciphertext before it, which a later
    /// call has not overwritten yet: the caller walks the buffer back to front.
    @inline(__always)
    private static func decrypt(_ p: UnsafeMutableRawPointer, _ rk: UnsafePointer<UInt32>, _ td: UnsafePointer<UInt32>,
                                chain: UnsafeRawPointer?) {
        @inline(__always) func load(_ q: UnsafeRawPointer, _ i: Int) -> UInt32 {
            UInt32(bigEndian: q.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))
        }
        @inline(__always) func t(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
            td[Int(a >> 24)] ^ td[256 + Int((b >> 16) & 0xFF)] ^ td[512 + Int((c >> 8) & 0xFF)] ^ td[768 + Int(d & 0xFF)]
        }
        @inline(__always) func last(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
            td[1024 + Int(a >> 24)] << 24 | td[1024 + Int((b >> 16) & 0xFF)] << 16
                | td[1024 + Int((c >> 8) & 0xFF)] << 8 | td[1024 + Int(d & 0xFF)]
        }
        var s0 = load(p, 0) ^ rk[0], s1 = load(p, 1) ^ rk[1], s2 = load(p, 2) ^ rk[2], s3 = load(p, 3) ^ rk[3]
        for round in 1..<14 {
            let k = rk + 4 * round
            let t0 = t(s0, s3, s2, s1) ^ k[0]
            let t1 = t(s1, s0, s3, s2) ^ k[1]
            let t2 = t(s2, s1, s0, s3) ^ k[2]
            let t3 = t(s3, s2, s1, s0) ^ k[3]
            s0 = t0; s1 = t1; s2 = t2; s3 = t3
        }
        var o0 = last(s0, s3, s2, s1) ^ rk[56], o1 = last(s1, s0, s3, s2) ^ rk[57]
        var o2 = last(s2, s1, s0, s3) ^ rk[58], o3 = last(s3, s2, s1, s0) ^ rk[59]
        if let chain {
            o0 ^= load(chain, 0); o1 ^= load(chain, 1); o2 ^= load(chain, 2); o3 ^= load(chain, 3)
        }
        p.storeBytes(of: o0.bigEndian, toByteOffset: 0, as: UInt32.self)
        p.storeBytes(of: o1.bigEndian, toByteOffset: 4, as: UInt32.self)
        p.storeBytes(of: o2.bigEndian, toByteOffset: 8, as: UInt32.self)
        p.storeBytes(of: o3.bigEndian, toByteOffset: 12, as: UInt32.self)
    }

    /// Td0..Td3 (1024 words: InvSubBytes then InvMixColumns of one byte in each
    /// row position) followed by the inverse S-box widened to words.
    private static let tables: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 1280)
        for x in 0..<256 {
            let s = invSBox[x]
            let w = UInt32(gmul(s, 14)) << 24 | UInt32(gmul(s, 9)) << 16 | UInt32(gmul(s, 13)) << 8 | UInt32(gmul(s, 11))
            for r in 0..<4 { t[256 * r + x] = w.rotr(UInt32(8 * r)) }
            t[1024 + x] = UInt32(s)
        }
        return t
    }()

    /// InvMixColumns of one column word, for the decryption key schedule.
    private static func invMixColumn(_ w: UInt32) -> UInt32 {
        let a = [UInt8(w >> 24), UInt8(truncatingIfNeeded: w >> 16), UInt8(truncatingIfNeeded: w >> 8), UInt8(truncatingIfNeeded: w)]
        func row(_ m: [UInt8]) -> UInt32 { UInt32(gmul(a[0], m[0]) ^ gmul(a[1], m[1]) ^ gmul(a[2], m[2]) ^ gmul(a[3], m[3])) }
        return row([14, 11, 13, 9]) << 24 | row([9, 14, 11, 13]) << 16 | row([13, 9, 14, 11]) << 8 | row([11, 13, 9, 14])
    }

    private static func gmul(_ x: UInt8, _ m: UInt8) -> UInt8 {
        var a = x, b = m, p: UInt8 = 0
        while b != 0 {
            if b & 1 != 0 { p ^= a }
            a = xtime(a); b >>= 1
        }
        return p
    }

    private static func xtime(_ b: UInt8) -> UInt8 { (b << 1) ^ (b & 0x80 != 0 ? 0x1B : 0) }

    private static func subWord(_ w: UInt32) -> UInt32 {
        UInt32(sBox[Int(w >> 24)]) << 24 | UInt32(sBox[Int((w >> 16) & 0xFF)]) << 16
            | UInt32(sBox[Int((w >> 8) & 0xFF)]) << 8 | UInt32(sBox[Int(w & 0xFF)])
    }

    static let sBox: [UInt8] = {
        // Generated from the multiplicative inverse in GF(2^8) plus the affine map.
        var box = [UInt8](repeating: 0, count: 256)
        var p: UInt8 = 1, q: UInt8 = 1
        repeat {
            p = p ^ (p << 1) ^ (p & 0x80 != 0 ? 0x1B : 0)
            q ^= q << 1; q ^= q << 2; q ^= q << 4
            if q & 0x80 != 0 { q ^= 0x09 }
            let x = q ^ q.rotl(1) ^ q.rotl(2) ^ q.rotl(3) ^ q.rotl(4)
            box[Int(p)] = x ^ 0x63
        } while p != 1
        box[0] = 0x63
        return box
    }()

    static let invSBox: [UInt8] = {
        var inv = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { inv[Int(sBox[i])] = UInt8(i) }
        return inv
    }()
}

extension UInt8 {
    fileprivate func rotl(_ n: UInt8) -> UInt8 { (self << n) | (self >> (8 - n)) }
    fileprivate var asU32: UInt32 { UInt32(self) }
}
