// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Stages a whole `ContentPlan` into one directory: chunks fetched in
/// parallel (a bounded task group), each unique chunk downloaded once and
/// each part of it written by offset to every place it occurs, data `fsync`ed
/// in batches before the append-only journal vouches for it, and every
/// finished file checked against the manifest's SHA-1 or md5 by streaming
/// `pread`. A relaunch replays the journal and re-hashes the journalled parts
/// of unfinished files that are whole chunks before trusting them (a slice of
/// a chunk has no hash of its own: the file's hash checks it). Free space is checked before the first chunk and
/// while downloading; a shortfall stops the job with `insufficientSpace` and
/// keeps the stage for the next run. The caller commits the finished tree.
public struct InstallEngine: Sendable {
    public struct Options: Sendable {
        /// Chunk requests in flight. On the phone 8 left the link idle
        /// (FlatOut 2: ~60 MB/s); 16 and 32 both reach ~75 MB/s, and 32 costs
        /// ~50 MiB more (docs/evidence/2026-09-25-steam-download-aes.md).
        public var concurrency = 16
        /// Journal batching: flush after this many chunks or this much time.
        public var flushEveryChunks = 64
        public var flushInterval: TimeInterval = 1
        public var spaceCheckEveryChunks = 128
        /// Free space kept beyond the bytes still to write: this fraction of
        /// the plan, plus `reserveBytes`.
        public var marginFraction = 0.05
        public var reserveBytes: UInt64 = 0
        /// Test and evidence hook: stop (as a pause) after this many downloads.
        public var cancelAfterChunks: Int?
        public var progressInterval: TimeInterval = 2

        public init() {}
    }

    public struct Progress: Sendable {
        public var bytesDone: UInt64
        public var bytesTotal: UInt64
        public var downloadedBytes: UInt64
        public var chunksDownloaded: Int
        public var chunksToDownload: Int
        public var filesVerified: Int
        public var filesTotal: Int
        public var seconds: Double

        public init(bytesDone: UInt64, bytesTotal: UInt64, downloadedBytes: UInt64, chunksDownloaded: Int, chunksToDownload: Int,
                    filesVerified: Int, filesTotal: Int, seconds: Double) {
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
            self.downloadedBytes = downloadedBytes
            self.chunksDownloaded = chunksDownloaded
            self.chunksToDownload = chunksToDownload
            self.filesVerified = filesVerified
            self.filesTotal = filesTotal
            self.seconds = seconds
        }
    }

    public struct Result: Sendable {
        public var files: Int
        public var bytes: UInt64
        /// Unique chunks fetched from the CDN in this run.
        public var chunksDownloaded: Int
        /// Extra copies of a fetched chunk written locally (dedup).
        public var chunksDeduped: Int
        /// Journalled chunks whose bytes re-hashed correctly on resume.
        public var chunksResumed: Int
        /// Journalled chunks that failed the re-hash and were fetched again.
        public var chunksRejected: Int
        /// Files trusted from the journal (verified before the interruption).
        public var filesResumed: Int
        public var downloadedBytes: UInt64
        /// Files SHA-1-checked in this run.
        public var filesVerified: Int
        public var seconds: Double
        public var peakRSSBytes: UInt64
    }

    public let tree: URL
    public let journalURL: URL
    let source: any ContentChunkSource
    let log: Logger
    public var options: Options
    /// The volume query; tests substitute a fixed figure.
    public var freeSpace: @Sendable (URL) throws -> UInt64 = { try InstallFS.availableCapacity($0) }

    public init(tree: URL, journal: URL, source: any ContentChunkSource, log: Logger, options: Options = Options()) {
        self.tree = tree
        self.journalURL = journal
        self.source = source
        self.log = log
        self.options = options
    }

    private enum Outcome: Sendable {
        case fetched(Int, [UInt8])
        case rehashed(Int, Bool)
        case hashed(Int, Bool)
    }

    private struct Dest: Sendable {
        var file: Int
        /// The global part index (the journal's numbering).
        var part: Int
        var offset: UInt64
        var offsetInChunk: UInt32
        var length: UInt32
    }

    private struct Unit: Sendable {
        var chunk: ContentChunk
        var dests: [Dest]
    }

    public func run(_ plan: ContentPlan, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Result {
        do {
            return try await stage(plan, progress: progress)
        } catch is CancellationError {
            throw ClientError.cancelled
        }
    }

    private func stage(_ plan: ContentPlan, progress: @escaping @Sendable (Progress) -> Void) async throws -> Result {
        let started = Date()
        let fm = FileManager.default
        let spaceRoot = tree.deletingLastPathComponent()
        try InstallFS.makeDirectory(spaceRoot)
        let (journal, replay) = try InstallJournal.open(journalURL, plan: plan)
        defer { journal.close() }
        if replay.fresh {
            if fm.fileExists(atPath: tree.path) {
                log.warn("install", "staged files belong to another plan; starting the stage afresh")
                try fm.removeItem(at: tree)
            }
        } else {
            log.info("install", "resuming stage: \(replay.chunks.count) chunk and \(replay.files.count) file records in the journal"
                     + (replay.discardedBytes > 0 ? ", \(replay.discardedBytes) torn bytes dropped" : ""))
        }
        try InstallFS.makeDirectory(tree)

        for d in plan.directories {
            try InstallFS.makeDirectory(try InstallFS.resolveInside(tree, d, createParents: true))
        }
        let files = plan.files
        var urls: [URL] = []
        urls.reserveCapacity(files.count)
        var fileDone = [Bool](repeating: false, count: files.count)
        var partDone = [Bool](repeating: false, count: plan.partCount)
        var toRehash: [(file: Int, part: Int)] = []
        for (i, f) in files.enumerated() {
            let url = try InstallFS.resolveInside(tree, f.path, createParents: true)
            urls.append(url)
            let fd = sysOpen(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw ClientError.unsafeContent("cannot open staged \(f.path) without following links (errno \(errno))") }
            defer { _ = sysClose(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0 else { throw ClientError.transport("fstat \(f.path) errno \(errno)") }
            let size = UInt64(st.st_size)
            if replay.files.contains(i), size == f.size {
                fileDone[i] = true
                continue
            }
            if replay.files.contains(i) { log.warn("install", "\(f.path) was verified but is now \(size) bytes, not \(f.size); fetching it again") }
            if size != f.size {
                guard ftruncate(fd, off_t(f.size)) == 0 else { throw ClientError.transport("ftruncate \(f.path) errno \(errno)") }
            }
            for j in f.parts.indices where replay.chunks.contains(f.firstPart + j) {
                toRehash.append((i, f.firstPart + j))
            }
        }
        let filesResumed = fileDone.filter { $0 }.count
        for (i, f) in files.enumerated() where fileDone[i] {
            for j in f.parts.indices { partDone[f.firstPart + j] = true }
        }

        // Trust a journalled part of an unfinished file only after re-hashing it.
        var resumed = 0, rejected = 0
        if !toRehash.isEmpty {
            let jobs = toRehash.map { job -> (Int, URL, ContentPart, ContentChunk) in
                let part = files[job.file].parts[job.part - files[job.file].firstPart]
                return (job.part, urls[job.file], part, plan.chunks[part.chunk])
            }
            try await withThrowingTaskGroup(of: Outcome.self) { group in
                var next = 0, running = 0
                while next < jobs.count || running > 0 {
                    while running < max(2, options.concurrency), next < jobs.count {
                        let (k, url, part, c) = jobs[next]
                        next += 1
                        running += 1
                        group.addTask { .rehashed(k, Self.partOnDisk(url, part, c)) }
                    }
                    guard case let .rehashed(k, ok)? = try await group.next() else { continue }
                    running -= 1
                    if ok { partDone[k] = true; resumed += 1 } else { rejected += 1 }
                }
            }
            log.info("install", "resume: \(resumed) journalled parts re-hashed OK, \(rejected) failed and will be fetched again; \(filesResumed) files already verified")
        }

        // Unique chunks still needed, in file order, with every place they go.
        var units: [Unit] = []
        var unitOf: [Int: Int] = [:]
        var remaining = [Int](repeating: 0, count: files.count)
        var remainingBytes: UInt64 = 0
        for (i, f) in files.enumerated() where !fileDone[i] {
            for (j, p) in f.parts.enumerated() where !partDone[f.firstPart + j] {
                let dest = Dest(file: i, part: f.firstPart + j, offset: p.fileOffset, offsetInChunk: p.offsetInChunk, length: p.length)
                if let u = unitOf[p.chunk] {
                    units[u].dests.append(dest)
                } else {
                    unitOf[p.chunk] = units.count
                    units.append(Unit(chunk: plan.chunks[p.chunk], dests: [dest]))
                }
                remaining[i] += 1
                remainingBytes += UInt64(p.length)
            }
        }
        let margin = UInt64(Double(plan.totalBytes) * options.marginFraction) + options.reserveBytes
        let available = try freeSpace(spaceRoot)
        log.info("install", "free space: \(available) bytes available, \(remainingBytes + margin) needed (\(remainingBytes) to write + \(margin) margin)")
        guard available >= remainingBytes + margin else {
            throw ClientError.insufficientSpace(needed: remainingBytes + margin, available: available)
        }
        log.info("install", "stage: \(files.count) files, \(plan.totalBytes) bytes; \(units.count) unique chunks to fetch (\(remainingBytes) bytes to write) with \(options.concurrency) in flight")

        var hashQueue = files.indices.filter { !fileDone[$0] && remaining[$0] == 0 }
        var awaitingFlush: [Int] = []
        var dirty: [Int: Int32] = [:]
        var pending: [InstallJournal.Record] = []
        var downloaded = 0, deduped = 0, verified = 0, downloadedBytes: UInt64 = 0
        var lastFlush = Date(), lastProgress = Date(), sinceSpaceCheck = 0
        let bytesTotal = plan.totalBytes

        func flush() throws {
            for (_, fd) in dirty {
                guard fsync(fd) == 0 else { throw ClientError.transport("fsync staged file errno \(errno)") }
                _ = sysClose(fd)
            }
            dirty.removeAll()
            try journal.append(pending)
            pending.removeAll(keepingCapacity: true)
            hashQueue += awaitingFlush
            awaitingFlush.removeAll()
            lastFlush = Date()
        }

        func report(force: Bool = false) {
            guard force || Date().timeIntervalSince(lastProgress) >= options.progressInterval else { return }
            lastProgress = Date()
            progress(Progress(bytesDone: bytesTotal > remainingBytes ? bytesTotal - remainingBytes : 0, bytesTotal: bytesTotal,
                              downloadedBytes: downloadedBytes, chunksDownloaded: downloaded, chunksToDownload: units.count,
                              filesVerified: filesResumed + verified, filesTotal: files.count, seconds: Date().timeIntervalSince(started)))
        }

        let limit = options.cancelAfterChunks
        let maxHashing = max(2, options.concurrency / 4)
        do {
            try await withThrowingTaskGroup(of: Outcome.self) { group in
                var nextUnit = 0, fetching = 0, hashing = 0
                while true {
                    while hashing < maxHashing, !hashQueue.isEmpty {
                        let i = hashQueue.removeFirst()
                        let url = urls[i], size = files[i].size, want = files[i].hash
                        hashing += 1
                        group.addTask { .hashed(i, Self.fileMatches(url, size: size, hash: want)) }
                    }
                    while fetching < options.concurrency, nextUnit < units.count, limit.map({ downloaded + fetching < $0 }) ?? true {
                        let u = nextUnit, c = units[u].chunk
                        nextUnit += 1
                        fetching += 1
                        group.addTask { .fetched(u, try await source.chunk(c)) }
                    }
                    if fetching == 0, hashing == 0 {
                        if !pending.isEmpty || !awaitingFlush.isEmpty || !dirty.isEmpty {
                            try flush()
                            if !hashQueue.isEmpty { continue }
                        }
                        break
                    }
                    guard let outcome = try await group.next() else { break }
                    switch outcome {
                    case let .fetched(u, plain):
                        fetching -= 1
                        downloaded += 1
                        downloadedBytes += UInt64(plain.count)
                        for (n, d) in units[u].dests.enumerated() {
                            let fd: Int32
                            if let open = dirty[d.file] {
                                fd = open
                            } else {
                                fd = sysOpen(urls[d.file].path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0)
                                guard fd >= 0 else { throw ClientError.unsafeContent("cannot reopen staged \(files[d.file].path) (errno \(errno))") }
                                dirty[d.file] = fd
                            }
                            let end = Int(d.offsetInChunk) + Int(d.length)
                            guard end <= plain.count else {
                                throw ClientError.verificationFailed("a part of \(files[d.file].path) runs past its chunk's \(plain.count) bytes")
                            }
                            if d.offsetInChunk == 0, Int(d.length) == plain.count {
                                try Self.writeAll(fd, plain, at: d.offset, path: files[d.file].path)
                            } else {
                                try Self.writeAll(fd, Array(plain[Int(d.offsetInChunk)..<end]), at: d.offset, path: files[d.file].path)
                            }
                            pending.append(.init(kind: .chunk, index: d.part, sha: units[u].chunk.journalKey))
                            if n > 0 { deduped += 1 }
                            remainingBytes -= UInt64(d.length)
                            remaining[d.file] -= 1
                            if remaining[d.file] == 0 { awaitingFlush.append(d.file) }
                        }
                        if pending.count >= options.flushEveryChunks || Date().timeIntervalSince(lastFlush) >= options.flushInterval {
                            try flush()
                        }
                        sinceSpaceCheck += 1
                        if sinceSpaceCheck >= options.spaceCheckEveryChunks {
                            sinceSpaceCheck = 0
                            try checkSpace(spaceRoot, needed: remainingBytes + margin)
                        }
                    case let .hashed(i, ok):
                        hashing -= 1
                        guard ok else { throw ClientError.verificationFailed("\(files[i].path) does not match the manifest hash after assembly") }
                        fileDone[i] = true
                        verified += 1
                        pending.append(.init(kind: .file, index: i, sha: InstallJournal.fileKey(files[i])))
                    case .rehashed:
                        break
                    }
                    report()
                }
            }
        } catch {
            // Keep what is durable: data written so far is synced and journalled.
            try? flush()
            report(force: true)
            throw error
        }
        report(force: true)
        if let limit, downloaded >= limit, fileDone.contains(false) {
            log.info("install", "stopping after \(downloaded) downloaded chunks (cancel-after-chunks); the stage is kept for resume")
            throw ClientError.cancelled
        }
        guard !fileDone.contains(false) else { throw ClientError.verificationFailed("stage finished with unverified files") }
        return Result(files: files.count, bytes: plan.totalBytes, chunksDownloaded: downloaded, chunksDeduped: deduped,
                      chunksResumed: resumed, chunksRejected: rejected, filesResumed: filesResumed,
                      downloadedBytes: downloadedBytes, filesVerified: verified,
                      seconds: Date().timeIntervalSince(started), peakRSSBytes: ResourceUsage.peakRSSBytes())
    }

    private func checkSpace(_ root: URL, needed: UInt64) throws {
        let available = try freeSpace(root)
        guard available >= needed else { throw ClientError.insufficientSpace(needed: needed, available: available) }
    }

    static func writeAll(_ fd: Int32, _ data: [UInt8], at offset: UInt64, path: String) throws {
        var done = 0
        while done < data.count {
            let n = data.withUnsafeBytes { pwrite(fd, $0.baseAddress! + done, data.count - done, off_t(offset) + off_t(done)) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else {
                if errno == ENOSPC { throw ClientError.insufficientSpace(needed: UInt64(data.count - done), available: 0) }
                throw ClientError.transport("write \(path) errno \(errno)")
            }
            done += n
        }
    }

    /// A journalled part on disk: a whole chunk is re-hashed; a slice is
    /// trusted from the journal (its data was synced first) and the file's hash checks it.
    static func partOnDisk(_ url: URL, _ p: ContentPart, _ c: ContentChunk) -> Bool {
        guard p.offsetInChunk == 0, p.length == c.size else { return true }
        let fd = sysOpen(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
        guard fd >= 0 else { return false }
        defer { _ = sysClose(fd) }
        var buf = [UInt8](repeating: 0, count: Int(p.length))
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(p.length), off_t(p.fileOffset)) }
        return n == Int(p.length) && c.matches(buf)
    }

    /// Size, then content: an empty file carries no meaningful hash.
    public static func fileMatches(_ url: URL, size: UInt64, hash: FileHash) -> Bool {
        guard InstallFS.fileSize(url) == size else { return false }
        guard size > 0 else { return true }
        switch hash {
        case let .sha1(want): return InstallFS.sha1(url, expectedSize: size) == want
        case let .md5(want): return InstallFS.md5(url, expectedSize: size) == want
        case .none: return true
        }
    }
}

enum ResourceUsage {
    static func peakRSSBytes() -> UInt64 {
        var u = rusage()
        #if canImport(Darwin)
        guard getrusage(RUSAGE_SELF, &u) == 0 else { return 0 }
        return UInt64(u.ru_maxrss)          // bytes
        #else
        guard getrusage(RUSAGE_SELF.rawValue, &u) == 0 else { return 0 }
        return UInt64(u.ru_maxrss) * 1024   // kilobytes
        #endif
    }
}
