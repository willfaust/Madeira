// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Append-only install journal: a 32-byte header naming the plan, then one
/// fixed 32-byte record per verified part (a stretch of a chunk) or verified file. Records are
/// appended only after the data they vouch for is `fsync`ed, and the journal
/// is `fsync`ed per batch, so a kill loses at most the last batch. Replay
/// stops at the first torn or unchecked record and truncates it away.
///
///     header: "PPJ1" | u32 version | 20-byte plan identity | u32 0
///     record: u8 kind | 3 x 0 | u32 index | 20-byte SHA-1 | u32 CRC-32 of the first 28 bytes
public struct InstallJournal {
    enum Kind: UInt8 { case chunk = 1, file = 2 }

    struct Record: Equatable {
        var kind: Kind
        var index: Int
        var sha: [UInt8]
    }

    struct Replay {
        var chunks = Set<Int>()
        var files = Set<Int>()
        var records = 0
        var discardedBytes = 0
        /// No usable journal: absent, or written for another plan.
        var fresh = true
    }

    static let headerSize = 32
    static let recordSize = 32
    static let magic: [UInt8] = Array("PPJ1".utf8)
    static let version: UInt32 = 1

    let url: URL
    private let fd: Int32

    /// Opens the journal for `plan`, replaying what it holds. A journal for
    /// another plan (or none) starts empty; records that do not match the plan
    /// end the replay like a torn tail.
    static func open(_ url: URL, plan: ContentPlan) throws -> (InstallJournal, Replay) {
        var replay = Replay()
        var bytes: [UInt8] = []
        if let d = try? Data(contentsOf: url) { bytes = [UInt8](d) }
        var keep = 0
        if bytes.count >= headerSize, Array(bytes[0..<4]) == magic, bytes.readLE32(at: 4) == version,
           Array(bytes[8..<28]) == plan.identity {
            replay.fresh = false
            keep = headerSize
            var i = headerSize
            while bytes.count - i >= recordSize {
                guard let r = decode(Array(bytes[i..<(i + recordSize)])), matches(r, plan) else { break }
                switch r.kind {
                case .chunk: replay.chunks.insert(r.index)
                case .file: replay.files.insert(r.index)
                }
                replay.records += 1
                i += recordSize
            }
            keep = i
            replay.discardedBytes = bytes.count - keep
        }
        try InstallFS.makeDirectory(url.deletingLastPathComponent())
        let fd = sysOpen(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ClientError.unsafeContent("cannot open the install journal without following links (errno \(errno))") }
        let journal = InstallJournal(url: url, fd: fd)
        if replay.fresh {
            var header = magic
            header.appendLE(version)
            header += plan.identity
            header.appendLE(UInt32(0))
            guard ftruncate(fd, 0) == 0 else { throw ClientError.transport("journal truncate errno \(errno)") }
            try journal.write(header, at: 0)
            guard fsync(fd) == 0 else { throw ClientError.transport("journal fsync errno \(errno)") }
        } else if replay.discardedBytes > 0 {
            guard ftruncate(fd, off_t(keep)) == 0 else { throw ClientError.transport("journal truncate errno \(errno)") }
        }
        return (journal, replay)
    }

    func append(_ records: [Record]) throws {
        guard !records.isEmpty else { return }
        var buf: [UInt8] = []
        buf.reserveCapacity(records.count * Self.recordSize)
        for r in records { buf += Self.encode(r) }
        let end = lseek(fd, 0, SEEK_END)
        guard end >= 0 else { throw ClientError.transport("journal seek errno \(errno)") }
        try write(buf, at: end)
        guard fsync(fd) == 0 else { throw ClientError.transport("journal fsync errno \(errno)") }
    }

    func close() { _ = sysClose(fd) }

    private func write(_ buf: [UInt8], at offset: off_t) throws {
        var done = 0
        while done < buf.count {
            let n = buf.withUnsafeBytes { pwrite(fd, $0.baseAddress! + done, buf.count - done, offset + off_t(done)) }
            guard n > 0 else { throw ClientError.transport("journal write errno \(errno)") }
            done += n
        }
    }

    static func encode(_ r: Record) -> [UInt8] {
        var b: [UInt8] = [r.kind.rawValue, 0, 0, 0]
        b.appendLE(UInt32(r.index))
        b += r.sha.count == 20 ? r.sha : [UInt8](repeating: 0, count: 20)
        b.appendLE(CRC32.checksum(b))
        return b
    }

    static func decode(_ b: [UInt8]) -> Record? {
        guard b.count == recordSize, b[1] == 0, b[2] == 0, b[3] == 0,
              CRC32.checksum(Array(b[0..<28])) == b.readLE32(at: 28),
              let kind = Kind(rawValue: b[0]) else { return nil }
        return Record(kind: kind, index: Int(b.readLE32(at: 4)), sha: Array(b[8..<28]))
    }

    static func matches(_ r: Record, _ plan: ContentPlan) -> Bool {
        switch r.kind {
        case .chunk:
            guard let part = plan.part(r.index) else { return false }
            return plan.chunks[part.chunk].journalKey == r.sha
        case .file:
            guard r.index < plan.files.count else { return false }
            return fileKey(plan.files[r.index]) == r.sha
        }
    }

    /// The 20 bytes a file record holds: its hash, or zeros when it has none.
    static func fileKey(_ f: ContentFile) -> [UInt8] {
        f.hash.bytes.map(ContentPlan.key20) ?? [UInt8](repeating: 0, count: 20)
    }
}

// `open`/`close` without a module prefix would resolve to InstallJournal members.
@inline(__always) public func sysOpen(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
    #if canImport(Glibc)
    return Glibc.open(path, flags, mode)
    #else
    return Darwin.open(path, flags, mode)
    #endif
}

@inline(__always) public func sysClose(_ fd: Int32) -> Int32 {
    #if canImport(Glibc)
    return Glibc.close(fd)
    #else
    return Darwin.close(fd)
    #endif
}

/// Filesystem policy shared by the installers: no write follows a planted
/// symlink, and journal-style files are replaced atomically.
public enum InstallFS {
    public static func makeDirectory(_ url: URL) throws {
        var st = stat()
        if lstat(url.path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR else { throw ClientError.unsafeContent("\(url.lastPathComponent) exists and is not a directory") }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Resolves a validated relative path under `base`, refusing any existing
    /// component that is a symlink, so a planted link cannot redirect writes.
    public static func resolveInside(_ base: URL, _ relative: String, createParents: Bool) throws -> URL {
        let normalized = try SafePath.normalize(relative)
        var current = base
        let parts = normalized.split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            current = current.appendingPathComponent(part)
            var st = stat()
            if lstat(current.path, &st) == 0 {
                if (st.st_mode & S_IFMT) == S_IFLNK { throw ClientError.unsafeContent("symlink in staged path \(normalized)") }
            } else if i < parts.count - 1, createParents {
                guard mkdir(current.path, 0o755) == 0 || errno == EEXIST else {
                    throw ClientError.transport("mkdir errno \(errno)")
                }
            }
        }
        return current
    }

    public static func writeAtomically(_ url: URL, _ data: Data) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: tmp)
        guard rename(tmp.path, url.path) == 0 else { throw ClientError.transport("rename \(url.lastPathComponent) errno \(errno)") }
    }

    public static func fileSize(_ url: URL) -> UInt64? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return UInt64(st.st_size)
    }

    /// Streaming SHA-1 of a file through `pread` in 1 MiB blocks.
    public static func sha1(_ url: URL, expectedSize: UInt64? = nil) -> [UInt8]? {
        let fd = sysOpen(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
        guard fd >= 0 else { return nil }
        defer { _ = sysClose(fd) }
        var h = SHA1Stream()
        guard let n = stream(fd, { h.update($0) }), expectedSize == nil || n == expectedSize else { return nil }
        return h.finalize()
    }

    public static func sha256(_ url: URL) -> [UInt8]? {
        let fd = sysOpen(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
        guard fd >= 0 else { return nil }
        defer { _ = sysClose(fd) }
        var h = SHA256Stream()
        guard stream(fd, { h.update($0) }) != nil else { return nil }
        return h.finalize()
    }

    public static func md5(_ url: URL, expectedSize: UInt64? = nil) -> [UInt8]? {
        let fd = sysOpen(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
        guard fd >= 0 else { return nil }
        defer { _ = sysClose(fd) }
        var h = MD5Stream()
        guard let n = stream(fd, { h.update($0) }), expectedSize == nil || n == expectedSize else { return nil }
        return h.finalize()
    }

    public static let blockSize = 1 << 20

    private static func stream(_ fd: Int32, _ body: (UnsafeRawBufferPointer) -> Void) -> UInt64? {
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: blockSize, alignment: 16)
        defer { buf.deallocate() }
        var offset: off_t = 0
        while true {
            let n = pread(fd, buf.baseAddress, blockSize, offset)
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { return UInt64(offset) }
            body(UnsafeRawBufferPointer(rebasing: buf[0..<n]))
            offset += off_t(n)
        }
    }

    /// Space the system will let an important, user-started download use.
    public static func availableCapacity(_ url: URL) throws -> UInt64 {
        #if canImport(Darwin)
        let v = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = v.volumeAvailableCapacityForImportantUsage else { throw ClientError.transport("free space unavailable") }
        return UInt64(max(0, bytes))
        #else
        var s = statvfs()
        guard statvfs(url.path, &s) == 0 else { throw ClientError.transport("statvfs errno \(errno)") }
        return UInt64(s.f_bavail) * UInt64(s.f_frsize)
        #endif
    }
}
