// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A PKZip archive read from a file without loading it: the central directory
/// (zip64 too), then each entry streamed out, stored or deflated, and checked
/// against its CRC-32. A game picked as a `.zip` is imported through this.
/// Encrypted entries and other compression methods are refused by name.
public struct ZipArchive {
    public struct Entry: Sendable, Equatable {
        /// As stored, `/`-separated; a directory's ends with `/`.
        public var path: String
        public var method: UInt16
        public var crc: UInt32
        public var compressedSize: UInt64
        public var size: UInt64
        public var localHeader: UInt64
        public var isDirectory: Bool
        public var isSymlink: Bool
        public var encrypted: Bool
    }

    public let url: URL
    public let entries: [Entry]
    public let fileSize: UInt64

    /// The methods a game zip may use; any other is refused with its name.
    public static func methodName(_ m: UInt16) -> String {
        switch m {
        case 0: "stored"
        case 8: "deflate"
        case 9: "deflate64"
        case 12: "bzip2"
        case 14: "LZMA"
        case 93: "zstd"
        case 95: "xz"
        case 98: "PPMd"
        case 99: "AES-encrypted"
        default: "method \(m)"
        }
    }

    public init(url: URL) throws {
        self.url = url
        let fd = sysOpen(url.path, O_RDONLY | O_CLOEXEC, 0)
        guard fd >= 0 else { throw ClientError.notFound("cannot open \(url.lastPathComponent) (errno \(errno))") }
        defer { _ = sysClose(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw ClientError.transport("fstat errno \(errno)") }
        fileSize = UInt64(st.st_size)
        entries = try Self.directory(fd, size: fileSize)
    }

    static func pread(_ fd: Int32, _ count: Int, at offset: UInt64) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = buf.withUnsafeMutableBytes {
                #if canImport(Glibc)
                Glibc.pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                #else
                Darwin.pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                #endif
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw ClientError.protocolChanged("zip: truncated at \(offset + UInt64(done))") }
            done += n
        }
        return buf
    }

    static func directory(_ fd: Int32, size: UInt64) throws -> [Entry] {
        guard size >= 22 else { throw ClientError.protocolChanged("zip: too short to be an archive") }
        // The end record is in the last 64 KiB + 22 bytes (its comment is at most 65535).
        let tailSize = Int(Swift.min(size, 22 + 0xFFFF))
        let tail = try pread(fd, tailSize, at: size - UInt64(tailSize))
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail.readLE32(at: i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ClientError.protocolChanged("zip: no end of central directory (not a zip, or cut short)") }
        var count = UInt64(tail.readLE16(at: eocd + 10))
        var cdSize = UInt64(tail.readLE32(at: eocd + 12))
        var cdOffset = UInt64(tail.readLE32(at: eocd + 16))
        let eocdAt = size - UInt64(tailSize) + UInt64(eocd)
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            guard eocdAt >= 20 else { throw ClientError.protocolChanged("zip64: no locator") }
            let loc = try pread(fd, 20, at: eocdAt - 20)
            guard loc.readLE32(at: 0) == 0x0706_4B50 else { throw ClientError.protocolChanged("zip64: no locator") }
            let recAt = loc.readLE64(at: 8)
            guard recAt + 56 <= size else { throw ClientError.protocolChanged("zip64: end record out of range") }
            let rec = try pread(fd, 56, at: recAt)
            guard rec.readLE32(at: 0) == 0x0606_4B50 else { throw ClientError.protocolChanged("zip64: bad end record") }
            count = rec.readLE64(at: 32)
            cdSize = rec.readLE64(at: 40)
            cdOffset = rec.readLE64(at: 48)
        }
        guard cdOffset + cdSize <= size, cdSize <= 256 << 20, count <= 1_000_000 else {
            throw ClientError.unsafeContent("zip: central directory out of range or too large")
        }
        let cd = try pread(fd, Int(cdSize), at: cdOffset)
        var out: [Entry] = []
        out.reserveCapacity(Int(count))
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, cd.readLE32(at: p) == 0x0201_4B50 else {
                throw ClientError.protocolChanged("zip: bad central directory entry")
            }
            let madeBy = cd.readLE16(at: p + 4) >> 8
            let flags = cd.readLE16(at: p + 8)
            let method = cd.readLE16(at: p + 10)
            let crc = cd.readLE32(at: p + 16)
            var csize = UInt64(cd.readLE32(at: p + 20))
            var usize = UInt64(cd.readLE32(at: p + 24))
            let nameLen = Int(cd.readLE16(at: p + 28)), extraLen = Int(cd.readLE16(at: p + 30)), commentLen = Int(cd.readLE16(at: p + 32))
            let external = cd.readLE32(at: p + 38)
            var local = UInt64(cd.readLE32(at: p + 42))
            let end = p + 46 + nameLen + extraLen + commentLen
            guard end <= cd.count else { throw ClientError.protocolChanged("zip: central entry runs past the directory") }
            let rawName = Array(cd[(p + 46)..<(p + 46 + nameLen)])
            // Zip64 extra field: the 0xFFFFFFFF fields, in order.
            var e = p + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = cd.readLE16(at: e), len = Int(cd.readLE16(at: e + 2))
                var q = e + 4
                if id == 0x0001 {
                    if usize == 0xFFFF_FFFF, q + 8 <= e + 4 + len { usize = cd.readLE64(at: q); q += 8 }
                    if csize == 0xFFFF_FFFF, q + 8 <= e + 4 + len { csize = cd.readLE64(at: q); q += 8 }
                    if local == 0xFFFF_FFFF, q + 8 <= e + 4 + len { local = cd.readLE64(at: q) }
                }
                e += 4 + len
            }
            // UTF-8 when flagged (bit 11) or valid; otherwise each byte as Latin-1, close enough to CP437 for a refusal message.
            let name = flags & 0x800 != 0 || String(bytes: rawName, encoding: .utf8) != nil
                ? String(decoding: rawName, as: UTF8.self)
                : String(rawName.map { Character(Unicode.Scalar($0)) })
            let mode = (external >> 16) & 0o170000
            out.append(Entry(path: name, method: method, crc: crc, compressedSize: csize, size: usize, localHeader: local,
                             isDirectory: name.hasSuffix("/") || (madeBy == 0 && external & 0x10 != 0) || mode == 0o040000,
                             isSymlink: madeBy == 3 && mode == 0o120000, encrypted: flags & 1 != 0))
            p = end
        }
        return out
    }

    /// Streams `entry`'s bytes to `write`, checking its size and CRC-32.
    public func extract(_ entry: Entry, blockSize: Int = 1 << 20, write: @escaping (UnsafeRawBufferPointer) throws -> Void) throws {
        guard !entry.encrypted else { throw ClientError.unsupported("\(entry.path) is encrypted") }
        guard entry.method == 0 || entry.method == 8 else {
            throw ClientError.unsupported("\(entry.path) uses \(Self.methodName(entry.method)) compression; only stored and deflate are supported")
        }
        let fd = sysOpen(url.path, O_RDONLY | O_CLOEXEC, 0)
        guard fd >= 0 else { throw ClientError.notFound("cannot open \(url.lastPathComponent) (errno \(errno))") }
        defer { _ = sysClose(fd) }
        let header = try Self.pread(fd, 30, at: entry.localHeader)
        guard header.readLE32(at: 0) == 0x0403_4B50 else { throw ClientError.protocolChanged("zip: no local header for \(entry.path)") }
        let start = entry.localHeader + 30 + UInt64(header.readLE16(at: 26)) + UInt64(header.readLE16(at: 28))
        guard start + entry.compressedSize <= fileSize else { throw ClientError.protocolChanged("zip: \(entry.path) runs past the archive") }
        var crc: UInt32 = 0
        var produced: UInt64 = 0
        var at = start
        let end = start + entry.compressedSize
        let next: () throws -> [UInt8]? = {
            guard at < end else { return nil }
            let n = Int(Swift.min(UInt64(blockSize), end - at))
            let b = try Self.pread(fd, n, at: at)
            at += UInt64(n)
            return b
        }
        let sink: (UnsafeRawBufferPointer) throws -> Void = { buf in
            crc = CRC32.update(crc, buf)
            produced += UInt64(buf.count)
            try write(buf)
        }
        if entry.method == 0 {
            guard entry.compressedSize == entry.size else { throw ClientError.protocolChanged("zip: stored \(entry.path) sizes differ") }
            while let b = try next() { try b.withUnsafeBytes { try sink($0) } }
        } else {
            var s = InflateStream(limit: entry.size, flushAt: blockSize, read: next, write: sink)
            try s.run()
        }
        guard produced == entry.size else {
            throw ClientError.verificationFailed("\(entry.path): \(produced) bytes, the archive says \(entry.size)")
        }
        guard crc == entry.crc else { throw ClientError.verificationFailed("\(entry.path) fails its CRC-32") }
    }
}
