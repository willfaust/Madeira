// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import zlib

// Unpacking an itch.io download (docs/ITCH.md). Most itch.io games are a .zip of the
// game's folder, often several GB, so the archive is read from its file a piece at a
// time, never whole: the central directory (ZIP64 too), then each entry stored or
// deflated, its CRC-32 checked. Entries land in a staging folder that replaces the
// install folder only when every entry is in. Names that leave the folder, absolute
// names, encrypted entries, symbolic links and two names Windows would see as one
// (Wine's drive_c is case-insensitive) stop the unpack.

enum ItchArchiveError: LocalizedError {
    case notZip
    case damaged(String)
    case unsupported(String)
    case unsafeName(String)

    var errorDescription: String? {
        switch self {
        case .notZip: return "This download is not a .zip archive."
        case .damaged(let what): return "The downloaded archive is damaged (\(what)). Download it again."
        case .unsupported(let what): return "Madeira cannot unpack this archive yet (\(what))."
        case .unsafeName(let name): return "The archive has a file Madeira will not unpack (\(name))."
        }
    }

    var reason: String {
        switch self {
        case .notZip: return "not-zip"
        case .damaged(let what): return "damaged-" + what
        case .unsupported(let what): return "unsupported-" + what
        case .unsafeName: return "unsafe-name"
        }
    }
}

enum ItchArchive {
    struct Entry: Equatable {
        var name: String          // "/" separators, no trailing "/"
        var directory: Bool
        var method: Int
        var crc: UInt32
        var compressed: UInt64
        var size: UInt64
        var localOffset: UInt64
    }

    /// Whether a file starts like a zip archive.
    static func isZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4b, 0x03, 0x04])
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw ItchArchiveError.damaged("short-read") }
        return data
    }

    private static func u16(_ d: Data, _ p: Int) -> UInt64 { UInt64(d[d.startIndex + p]) | UInt64(d[d.startIndex + p + 1]) << 8 }
    private static func u32(_ d: Data, _ p: Int) -> UInt64 { u16(d, p) | u16(d, p + 2) << 16 }
    private static func u64(_ d: Data, _ p: Int) -> UInt64 { u32(d, p) | u32(d, p + 4) << 32 }

    /// A name made safe to join under the install folder, or nil.
    static func safeName(_ raw: String) -> String? {
        let name = raw.replacingOccurrences(of: "\\", with: "/")
        guard !name.hasPrefix("/"), !name.contains(":"), !name.contains("\u{0}") else { return nil }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let trimmed = parts.last == "" ? Array(parts.dropLast()) : parts
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return trimmed.joined(separator: "/")
    }

    /// The archive's entries, from its central directory.
    static func entries(_ url: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length >= 22 else { throw ItchArchiveError.notZip }
        let tailSize = Int(min(length, 65_557))
        let tail = try read(handle, at: length - UInt64(tailSize), count: tailSize)
        guard let eocd = stride(from: tailSize - 22, through: 0, by: -1).first(where: { u32(tail, $0) == 0x06054b50 }) else {
            throw ItchArchiveError.notZip
        }
        guard u16(tail, eocd + 4) == 0, u16(tail, eocd + 6) == 0 else { throw ItchArchiveError.unsupported("split archive") }
        var count = u16(tail, eocd + 10), directorySize = u32(tail, eocd + 12), directoryOffset = u32(tail, eocd + 16)
        // ZIP64: the locator sits right before the end record and points at the ZIP64 end record.
        let eocdOffset = length - UInt64(tailSize) + UInt64(eocd)
        if count == 0xffff || directorySize == 0xffff_ffff || directoryOffset == 0xffff_ffff, eocdOffset >= 20 {
            let locator = try read(handle, at: eocdOffset - 20, count: 20)
            guard u32(locator, 0) == 0x07064b50 else { throw ItchArchiveError.damaged("zip64-locator") }
            let record = try read(handle, at: u64(locator, 8), count: 56)
            guard u32(record, 0) == 0x06064b50 else { throw ItchArchiveError.damaged("zip64-end") }
            count = u64(record, 32); directorySize = u64(record, 40); directoryOffset = u64(record, 48)
        }
        guard count <= 1_000_000, directorySize <= 512 << 20, directoryOffset + directorySize <= length else {
            throw ItchArchiveError.damaged("directory")
        }
        let directory = try read(handle, at: directoryOffset, count: Int(directorySize))
        var cursor = 0
        var entries: [Entry] = []
        var seen = Set<String>()
        for _ in 0..<count {
            guard cursor + 46 <= directory.count, u32(directory, cursor) == 0x02014b50 else { throw ItchArchiveError.damaged("entry") }
            let flags = u16(directory, cursor + 8), method = Int(u16(directory, cursor + 10))
            let crc = UInt32(u32(directory, cursor + 16))
            var compressed = u32(directory, cursor + 20), size = u32(directory, cursor + 24)
            let nameLength = Int(u16(directory, cursor + 28)), extraLength = Int(u16(directory, cursor + 30))
            let commentLength = Int(u16(directory, cursor + 32))
            let madeBy = u16(directory, cursor + 4) >> 8, external = u32(directory, cursor + 38)
            var local = u32(directory, cursor + 42)
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= directory.count else { throw ItchArchiveError.damaged("entry") }
            let nameData = directory.subdata(in: directory.startIndex + cursor + 46 ..< directory.startIndex + cursor + 46 + nameLength)
            // Bit 11: UTF-8 names; older archivers wrote code page 437, read as Latin-1 here.
            let raw = (flags & 0x800 != 0 ? String(data: nameData, encoding: .utf8) : nil)
                ?? String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            // ZIP64 extra field: the 8-byte values, in order, for the 32-bit fields set to all ones.
            var extra = cursor + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = u16(directory, extra), length = Int(u16(directory, extra + 2))
                guard extra + 4 + length <= extraEnd else { break }
                if id == 0x0001 {
                    var p = extra + 4
                    if size == 0xffff_ffff, p + 8 <= extra + 4 + length { size = u64(directory, p); p += 8 }
                    if compressed == 0xffff_ffff, p + 8 <= extra + 4 + length { compressed = u64(directory, p); p += 8 }
                    if local == 0xffff_ffff, p + 8 <= extra + 4 + length { local = u64(directory, p); p += 8 }
                }
                extra += 4 + length
            }
            cursor = next
            guard flags & 1 == 0 else { throw ItchArchiveError.unsupported("encrypted files") }
            let directoryEntry = raw.hasSuffix("/") || raw.hasSuffix("\\")
            // Unix "made by" with a link mode: a symbolic link.
            if madeBy == 3, (external >> 16) & 0xf000 == 0xa000 { throw ItchArchiveError.unsafeName(raw) }
            guard let name = safeName(raw) else { throw ItchArchiveError.unsafeName(raw) }
            guard seen.insert(name.lowercased()).inserted else {
                if directoryEntry { continue }
                throw ItchArchiveError.unsafeName(name)
            }
            if !directoryEntry { guard method == 0 || method == 8 else { throw ItchArchiveError.unsupported("compression method \(method)") } }
            entries.append(Entry(name: name, directory: directoryEntry, method: method, crc: crc,
                                 compressed: compressed, size: size, localOffset: local))
        }
        return entries
    }

    /// Unpacks `archive` into `destination`, replacing what was there only once every
    /// entry is in. `progress` gets the bytes written so far and the total.
    @discardableResult
    static func unpack(_ archive: URL, to destination: URL,
                       progress: (UInt64, UInt64) -> Void = { _, _ in }) throws -> UInt64 {
        let list = try entries(archive)
        let total = list.reduce(UInt64(0)) { $0 + $1.size }
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + ".unpacking", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var done: UInt64 = 0
        do {
            for entry in list {
                try Task.checkCancellation()
                let target = staging.appendingPathComponent(entry.name, isDirectory: entry.directory)
                if entry.directory { try fm.createDirectory(at: target, withIntermediateDirectories: true); continue }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let header = try read(handle, at: entry.localOffset, count: 30)
                guard u32(header, 0) == 0x04034b50 else { throw ItchArchiveError.damaged("local-header") }
                let start = entry.localOffset + 30 + u16(header, 26) + u16(header, 28)
                guard fm.createFile(atPath: target.path, contents: nil) else { throw ItchArchiveError.damaged("write") }
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                try handle.seek(toOffset: start)
                let crc = try copy(entry, from: handle, to: output) { written in progress(done + written, total) }
                guard crc == entry.crc else { throw ItchArchiveError.damaged("crc") }
                done += entry.size
                progress(done, total)
            }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return total
    }

    /// One entry's data, stored or deflated, to `output`; returns its CRC-32.
    private static func copy(_ entry: Entry, from input: FileHandle, to output: FileHandle,
                             progress: (UInt64) -> Void) throws -> UInt32 {
        let chunk = 1 << 20
        var crc = crc32(0, nil, 0)
        var left = entry.compressed
        var written: UInt64 = 0
        if entry.method == 0 {
            guard entry.compressed == entry.size else { throw ItchArchiveError.damaged("stored-size") }
            while left > 0 {
                let data = try input.read(upToCount: Int(min(UInt64(chunk), left))) ?? Data()
                guard !data.isEmpty else { throw ItchArchiveError.damaged("short-read") }
                crc = data.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
                try output.write(contentsOf: data)
                left -= UInt64(data.count); written += UInt64(data.count)
                progress(written)
            }
            return UInt32(crc)
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ItchArchiveError.damaged("inflate-init")
        }
        defer { inflateEnd(&stream) }
        var out = [UInt8](repeating: 0, count: chunk)
        var finished = false
        while !finished {
            try Task.checkCancellation()
            let packed = left > 0 ? (try input.read(upToCount: Int(min(UInt64(chunk), left))) ?? Data()) : Data()
            if left > 0 && packed.isEmpty { throw ItchArchiveError.damaged("short-read") }
            left -= UInt64(packed.count)
            let before = written
            try packed.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(source.count)
                repeat {
                    let status: Int32 = out.withUnsafeMutableBytes { destination in
                        stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(chunk)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    guard status == Z_OK || status == Z_STREAM_END || (status == Z_BUF_ERROR && stream.avail_in == 0) else {
                        throw ItchArchiveError.damaged("inflate")
                    }
                    let produced = chunk - Int(stream.avail_out)
                    if produced > 0 {
                        let piece = Data(out[0..<produced])
                        crc = piece.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
                        try output.write(contentsOf: piece)
                        written += UInt64(produced)
                        guard written <= entry.size else { throw ItchArchiveError.damaged("size") }
                    }
                    if status == Z_STREAM_END { finished = true; break }
                    if status == Z_BUF_ERROR { break }
                } while stream.avail_out == 0 || stream.avail_in > 0
            }
            progress(written)
            // No input left and nothing more came out: the stream ends early.
            if !finished && packed.isEmpty && written == before { throw ItchArchiveError.damaged("truncated") }
        }
        guard written == entry.size else { throw ItchArchiveError.damaged("size") }
        return UInt32(crc)
    }
}
