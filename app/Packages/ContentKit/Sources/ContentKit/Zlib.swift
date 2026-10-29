// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// zlib (RFC 1950): what GOG and Epic compress their manifests and chunks with.
public enum Zlib {
    public static func decompress(_ data: [UInt8], limit: Int) throws -> [UInt8] {
        guard data.count >= 6, data[0] & 0x0F == 8, (UInt16(data[0]) << 8 | UInt16(data[1])) % 31 == 0, data[1] & 0x20 == 0 else {
            throw ClientError.protocolChanged("zlib: bad header")
        }
        let out = try Inflate.decompress(data[2..<(data.count - 4)], limit: limit)
        let want = UInt32(data[data.count - 4]) << 24 | UInt32(data[data.count - 3]) << 16
            | UInt32(data[data.count - 2]) << 8 | UInt32(data[data.count - 1])
        guard SteamAdler32.checksum(out, seed: 1) == want else { throw ClientError.verificationFailed("zlib Adler-32 mismatch") }
        return out
    }
}
