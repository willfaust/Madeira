// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension Array where Element == UInt8 {
    public mutating func appendLE(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    public mutating func appendLE(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }

    public func readLE32(at i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
    public func readLE16(at i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    public func readLE64(at i: Int) -> UInt64 { UInt64(readLE32(at: i)) | UInt64(readLE32(at: i + 4)) << 32 }

    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension ArraySlice where Element == UInt8 {
    public func readLE32(at i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
