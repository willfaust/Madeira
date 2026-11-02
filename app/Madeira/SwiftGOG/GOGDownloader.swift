// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Compression
import CryptoKit
import Foundation

// GOG's generation-2 content system (docs/GOG.md, "A download"): a depot's file
// list is zlib-compressed JSON, and each file is a list of zlib chunks named by
// the MD5 of their compressed bytes and checked by the MD5 of their contents.
// The format follows Heroic's gogdl (GPL-3.0), dl/objects/v2.py and
// dl/workers/task_executor.py. Self-contained: nothing here depends on another
// store's code.

/// Progress of one GOG download, published to the library model.
struct GOGDownloadProgress: Equatable, Sendable {
    enum Phase: String, Sendable { case preparing, verifying, downloading, finishing }
    var phase: Phase = .preparing
    /// Downloading: compressed chunk bytes to fetch and fetched. Verifying: file
    /// bytes to check and checked.
    var totalBytes: UInt64 = 0
    var doneBytes: UInt64 = 0
    var bytesPerSecond: Double = 0
    /// Preparing: what is being fetched from GOG ("Getting the file list (2 of 4)").
    var step: String?
    var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
}

enum GOGDownloadError: LocalizedError {
    case diskSpace(needed: Int64)
    case chunk(String)

    var errorDescription: String? {
        switch self {
        case .diskSpace(let needed):
            return "Not enough free space on this device: this download needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) more. Free some space, then try again."
        case .chunk(let reason): return "A game file could not be downloaded from GOG (\(reason)). Try again to continue."
        }
    }
}

enum GOGFormatError: LocalizedError, Equatable {
    case decompress(String)
    case parse(String)
    case checksum(String)
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .decompress(let what): return "A GOG download could not be unpacked (\(what))."
        case .parse(let what): return "GOG's file list could not be read (\(what))."
        case .checksum(let what): return "A file from GOG failed its checksum (\(what)). Try again."
        case .unsafePath: return "GOG's file list names a path outside the game's folder."
        }
    }
}

struct GOGChunk: Codable, Sendable, Hashable {
    var md5: String
    var size: Int
    var compressedMD5: String
    var compressedSize: Int
}

/// One file of a depot.
struct GOGFile: Codable, Sendable {
    var path: String
    var product: String
    var chunks: [GOGChunk]
    var md5: String?
    var sha256: String?
    var size: Int64 { chunks.reduce(0) { $0 + Int64($1.size) } }
    /// What identifies this file's contents across builds (gogdl's hash_map value).
    var checksum: String { md5 ?? sha256 ?? chunks.map(\.md5).joined(separator: ",") }
}

enum GOGCodec {
    /// A zlib stream (RFC 1950) of unknown size, as GOG's manifests are; a body that is
    /// already JSON is returned as it is (gogdl does the same).
    static func inflate(_ data: Data, what: String) throws -> Data {
        if let first = data.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "[") { return data }
        guard data.count >= 2, data[data.startIndex] & 0x0F == 8,
              (UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])) % 31 == 0 else {
            throw GOGFormatError.decompress(what)
        }
        // NSData's .zlib is raw DEFLATE: the two-byte header is skipped.
        guard let output = try? (Data(data.dropFirst(2)) as NSData).decompressed(using: .zlib) as Data,
              output.count <= 512 << 20 else { throw GOGFormatError.decompress(what) }
        return output
    }

    /// A zlib stream of known size (a chunk). Compression's ZLIB algorithm is raw
    /// DEFLATE, so the two-byte header is skipped here.
    static func inflate(_ data: Data, size: Int, what: String) throws -> Data {
        guard data.count >= 2, data[data.startIndex] & 0x0F == 8,
              (UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])) % 31 == 0,
              size >= 0, size <= 512 << 20 else {
            throw GOGFormatError.decompress(what)
        }
        if size == 0 { return Data() }
        let body = data.dropFirst(2)
        var output = Data(count: size + 1)
        let written = output.withUnsafeMutableBytes { out -> Int in
            body.withUnsafeBytes { input -> Int in
                guard let dst = out.bindMemory(to: UInt8.self).baseAddress,
                      let src = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, size + 1, src, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw GOGFormatError.decompress(what) }
        output.count = size
        return output
    }

    /// A path from a file list as folder components, or nil when it would leave the
    /// install folder (".." elements, a drive letter, control characters).
    static func components(_ name: String) -> [String]? {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        for part in parts {
            guard part != ".", part != "..", !part.contains(":"),
                  !part.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        }
        return parts
    }

    static func json(_ data: Data, what: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: try inflate(data, what: what)) as? [String: Any] else {
            throw GOGFormatError.parse(what)
        }
        return object
    }

    static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// One chunk as the CDN sends it: checked by its compressed MD5, unpacked to its
    /// size, then checked by its MD5.
    static func chunk(_ data: Data, expected: GOGChunk) throws -> Data {
        guard data.count == expected.compressedSize, md5(data) == expected.compressedMD5.lowercased() else {
            throw GOGFormatError.checksum("chunk")
        }
        let plain = try GOGCodec.inflate(data, size: expected.size, what: "chunk")
        guard md5(plain) == expected.md5.lowercased() else { throw GOGFormatError.checksum("chunk") }
        return plain
    }
}

/// A depot's file list.
enum GOGDepot {
    /// The files of one depot (support files, GOG's installer scripts, are left out,
    /// except the install script `goggame-<id>.script`, which goes to the folder's root
    /// for its registry values (GOGInstallScript); folders are made as files need them;
    /// links are not supported on drive_c).
    static func files(_ data: Data, product: String) throws -> [GOGFile] {
        let json = try GOGCodec.json(data, what: "depot")
        guard let items = (json["depot"] as? [String: Any])?["items"] as? [[String: Any]] else { throw GOGFormatError.parse("depot") }
        var files: [GOGFile] = []
        for item in items where item["type"] as? String == "DepotFile" {
            guard var path = item["path"] as? String, let raw = item["chunks"] as? [[String: Any]] else { throw GOGFormatError.parse("file") }
            if (item["flags"] as? [String] ?? []).contains("support") {
                let name = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
                guard GOGInstallScript.isScriptName(name) else { continue }
                path = name
            }
            let chunks = try raw.map { chunk -> GOGChunk in
                guard let md5 = chunk["md5"] as? String, let compressed = chunk["compressedMd5"] as? String,
                      GOGAPI.isHash(md5), GOGAPI.isHash(compressed),
                      let size = (chunk["size"] as? NSNumber)?.intValue, let compressedSize = (chunk["compressedSize"] as? NSNumber)?.intValue,
                      (0...(64 << 20)).contains(size), (0...(64 << 20)).contains(compressedSize) else { throw GOGFormatError.parse("chunk") }
                return GOGChunk(md5: md5.lowercased(), size: size, compressedMD5: compressed.lowercased(), compressedSize: compressedSize)
            }
            guard GOGCodec.components(path) != nil else { throw GOGFormatError.unsafePath }
            files.append(GOGFile(path: path.replacingOccurrences(of: "\\", with: "/"), product: product, chunks: chunks,
                                 md5: (item["md5"] as? String).map { $0.lowercased() }, sha256: (item["sha256"] as? String).map { $0.lowercased() }))
        }
        return files
    }

    /// The files of several depots, each path once (matched without case, as Windows
    /// does): the first depot that names a path keeps it.
    static func unique(_ files: [GOGFile]) -> [GOGFile] {
        var seen = Set<String>()
        return files.filter { seen.insert($0.path.lowercased()).inserted }
    }
}

/// The signed CDN addresses of each product, fetched again when GOG stops accepting them
/// (they expire during long downloads).
actor GOGLinks {
    private var links: [String: [GOGEndpoint]]
    private var refreshing: [String: Task<[GOGEndpoint], Error>] = [:]
    private let refresh: @Sendable (String) async throws -> [GOGEndpoint]

    init(links: [String: [GOGEndpoint]] = [:], refresh: @escaping @Sendable (String) async throws -> [GOGEndpoint]) {
        self.links = links
        self.refresh = refresh
    }

    func endpoints(_ product: String) async throws -> [GOGEndpoint] {
        if let known = links[product] { return known }
        return try await renew(product, stale: nil)
    }

    /// New addresses, unless another chunk already renewed the ones this chunk used.
    func renew(_ product: String, stale: [GOGEndpoint]?) async throws -> [GOGEndpoint] {
        if let stale, let known = links[product], known.map(\.format) != stale.map(\.format) || known.map(\.parameters) != stale.map(\.parameters) {
            return known
        }
        if let task = refreshing[product] { return try await task.value }
        let task = Task { try await refresh(product) }
        refreshing[product] = task
        defer { refreshing[product] = nil }
        let fresh = try await task.value
        links[product] = fresh
        return fresh
    }
}

/// Builds an install folder from a GOG build's files (docs/GOG.md, "A download").
///
/// - Files that are already right are kept: a file the journal recorded for this
///   build, a file an update leaves unchanged (same checksum in both builds) and,
///   otherwise, any file whose size and chunk MD5s match.
/// - Chunks are fetched by up to `window` tasks ahead of the writer, in file order,
///   and are checked (compressed MD5, size, MD5) before use.
/// - Each file is written to a temporary name and only then renamed into place, so
///   an interrupted update leaves the old file.
/// - Paths stay inside the install folder; directory names are matched without
///   case, as Windows does (GOGPathResolver).
final class GOGDownloader: @unchecked Sendable {
    var window = 12
    var attempts = 6
    /// Pause between retries of one chunk, doubled per attempt (tests set 0).
    var retryDelay: Double = 0.25

    private let http: URLSession

    init(session: URLSession? = nil) {
        if let session { http = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 16
        config.httpAdditionalHeaders = ["User-Agent": GOGAPI.userAgent]
        http = URLSession(configuration: config)
    }

    struct Result: Sendable {
        var filesWritten = 0
        var filesKept = 0
        var bytesFetched: UInt64 = 0
        var installBytes: Int64 = 0
    }

    /// Installs, updates (`previous`: the installed build's files) or repairs
    /// (`verifyAll`) `files` in `folder`. Throws CancellationError when cancelled.
    func install(files: [GOGFile], build: String, links: GOGLinks, folder: URL, previous: [GOGFile]?, verifyAll: Bool,
                 journal journalURL: URL, progress report: @escaping @Sendable (GOGDownloadProgress) -> Void) async throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = GOGPathResolver(root: folder)
        let journal = try GOGJournal(url: journalURL, build: build)
        var result = Result()

        struct Planned { var file: GOGFile; var parts: [String] }
        var all: [Planned] = []
        var seen = Set<String>()
        for file in files {
            guard let parts = GOGCodec.components(file.path) else { throw GOGFormatError.unsafePath }
            // A file in two depots (a DLC replacing a game file): the later depot wins.
            if !seen.insert(file.path.lowercased()).inserted { all.removeAll { $0.file.path.lowercased() == file.path.lowercased() } }
            all.append(Planned(file: file, parts: parts))
        }
        result.installBytes = all.reduce(0) { $0 + $1.file.size }
        var unchanged = [String: String]()
        for file in previous ?? [] { unchanged[file.path.lowercased()] = file.checksum }

        var needed: [Planned] = []
        var toVerify: [(Planned, URL)] = []
        for item in all {
            let url = paths.existing(item.parts)
            let size = url.flatMap { (try? fm.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value }
            guard let url, size == item.file.size else { needed.append(item); continue }
            if !verifyAll && (journal.contains(item.file) || unchanged[item.file.path.lowercased()] == item.file.checksum) {
                result.filesKept += 1
            } else {
                toVerify.append((item, url))
            }
        }
        if !toVerify.isEmpty {
            var state = GOGDownloadProgress(phase: .verifying)
            state.totalBytes = UInt64(toVerify.reduce(0) { $0 + $1.0.file.size })
            report(state)
            var reported: UInt64 = 0
            for (item, url) in toVerify {
                try Task.checkCancellation()
                // Progress at most every 32 MB: each report is a hop to the main actor.
                if try Self.matches(url, item.file, progress: { bytes in
                    state.doneBytes += UInt64(bytes)
                    if state.doneBytes - reported >= 32 << 20 { reported = state.doneBytes; report(state) }
                }) {
                    journal.record(item.file)
                    result.filesKept += 1
                } else {
                    needed.append(item)
                }
            }
            if state.doneBytes != reported { report(state) }   // the last, under-32 MB stretch
        }

        // Free space: what grows, plus room for the largest temporary file.
        var growth: Int64 = 0, largest: Int64 = 0
        for item in needed {
            let old = paths.existing(item.parts).flatMap { (try? fm.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value } ?? 0
            growth += max(0, item.file.size - old)
            largest = max(largest, item.file.size)
        }
        if let free = GOGDownloader.freeSpace(at: folder), free < growth + largest + (64 << 20) {
            throw GOGDownloadError.diskSpace(needed: growth + largest + (64 << 20) - free)
        }

        // Every chunk the needed files use, in the order the writer needs them.
        struct Job { var product: String; var chunk: GOGChunk }
        var order: [Job] = []
        for item in needed { for chunk in item.file.chunks { order.append(Job(product: item.file.product, chunk: chunk)) } }
        let wholeBuild = all.reduce(UInt64(0)) { total, item in total + item.file.chunks.reduce(0) { $0 + UInt64($1.compressedSize) } }
        let stillNeeded = order.reduce(UInt64(0)) { $0 + UInt64($1.chunk.compressedSize) }
        let total = max(wholeBuild, stillNeeded)
        let meter = GOGMeter(total: total, alreadyDone: total - stillNeeded, report: report)
        meter.publish(force: true)

        var inflight: [Int: Task<Data, Error>] = [:]
        var nextStart = 0
        defer { for task in inflight.values { task.cancel() } }
        func chunk(_ index: Int) async throws -> Data {
            let limit = min(order.count, index + window + 1)
            while nextStart < limit {
                let job = order[nextStart]
                inflight[nextStart] = Task.detached { [self] in try await self.fetch(job.chunk, product: job.product, links: links, meter: meter) }
                nextStart += 1
            }
            guard let task = inflight.removeValue(forKey: index) else { throw GOGDownloadError.chunk("order") }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }

        var position = 0
        for item in needed {
            try Task.checkCancellation()
            let target = try paths.create(item.parts)
            let temp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).madeira-part")
            try? fm.removeItem(at: temp)
            guard fm.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            do {
                let handle = try FileHandle(forWritingTo: temp)
                var md5 = Insecure.MD5()
                do {
                    for _ in item.file.chunks {
                        let data = try await chunk(position)
                        position += 1
                        try handle.write(contentsOf: data)
                        md5.update(data: data)
                    }
                    try handle.close()
                } catch { try? handle.close(); throw error }
                if let expected = item.file.md5, !item.file.chunks.isEmpty,
                   md5.finalize().map({ String(format: "%02x", $0) }).joined() != expected {
                    throw GOGFormatError.checksum("file")
                }
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: temp, to: target)
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
            journal.record(item.file)
            result.filesWritten += 1
        }

        // An update removes what the new build no longer has.
        var finishing = GOGDownloadProgress(phase: .finishing)
        finishing.totalBytes = meter.total; finishing.doneBytes = meter.total
        report(finishing)
        if let previous {
            let kept = Set(all.map { $0.file.path.lowercased() })
            for file in previous where !kept.contains(file.path.lowercased()) {
                if let parts = GOGCodec.components(file.path), let url = paths.existing(parts) { try? fm.removeItem(at: url) }
            }
        }
        journal.finish()
        result.bytesFetched = meter.fetchedThisRun
        return result
    }

    /// Free bytes on the volume of `url`, or nil when the volume does not say. Some
    /// volumes report zero for the important-usage estimate although they have free
    /// blocks, so the plain capacity is the fallback.
    static func freeSpace(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage, plain = values.volumeAvailableCapacity.map(Int64.init)
        if important == nil && plain == nil { return nil }
        return max(important ?? 0, plain ?? 0)
    }

    /// Whether the file on disk holds exactly these chunks.
    /// Each read is drained in its own autorelease pool: FileHandle's reads are autoreleased,
    /// and a repair reads the whole game without suspending, so without the pool every byte
    /// stayed in memory until the end (a 15 GB game ended Madeira; build 63, 2026-11-01).
    static func matches(_ url: URL, _ file: GOGFile, progress: (Int) -> Void = { _ in }) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        for chunk in file.chunks {
            let same: Bool = try autoreleasepool {
                let data = try handle.read(upToCount: chunk.size) ?? Data()
                progress(data.count)
                return data.count == chunk.size && GOGCodec.md5(data) == chunk.md5
            }
            guard same else { return false }
        }
        return try autoreleasepool { (try handle.read(upToCount: 1) ?? Data()).isEmpty }
    }

    /// One chunk from the CDN, trying the next address after a failure and asking for
    /// new addresses when GOG no longer accepts them.
    private func fetch(_ chunk: GOGChunk, product: String, links: GOGLinks, meter: GOGMeter) async throws -> Data {
        var lastReason = "no answer"
        var endpoints = try await links.endpoints(product)
        var renewed = false
        for attempt in 0..<max(1, attempts) {
            try Task.checkCancellation()
            guard let url = endpoints[attempt % endpoints.count].url(for: chunk.compressedMD5) else { throw GOGDownloadError.chunk("url") }
            do {
                let (data, response) = try await http.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (status == 401 || status == 403 || status == 410) && !renewed {
                    renewed = true
                    endpoints = try await links.renew(product, stale: endpoints)
                    lastReason = "http \(status)"
                    continue
                }
                guard status == 200 else { throw GOGDownloadError.chunk("http \(status)") }
                let plain = try GOGCodec.chunk(data, expected: chunk)
                meter.add(UInt64(chunk.compressedSize))
                return plain
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastReason = (error as? URLError).map { "url \($0.code.rawValue)" } ?? (error as? GOGFormatError).map { "\($0)" } ?? "\(error)"
                if retryDelay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * Double(1 << min(attempt, 4)) * 1e9))
                }
            }
        }
        throw GOGDownloadError.chunk(lastReason)
    }
}

/// Files already written for one build: one line per file, so a paused or failed
/// download resumes without writing them again. A journal for another build is
/// started over.
final class GOGJournal {
    private let url: URL
    private var done = Set<String>()
    private var handle: FileHandle?
    private static func key(_ file: GOGFile) -> String { file.checksum + "\t" + file.path }

    init(url: URL, build: String) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = "madeira-gog-journal 1 " + build.replacingOccurrences(of: "\n", with: " ")
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        if lines.first != header {
            lines = [header]
            try (header + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        done = Set(lines.dropFirst().filter { !$0.isEmpty })
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }
    deinit { try? handle?.close() }

    func contains(_ file: GOGFile) -> Bool { done.contains(Self.key(file)) }

    func record(_ file: GOGFile) {
        let key = Self.key(file)
        guard !key.contains("\n"), done.insert(key).inserted else { return }
        try? handle?.write(contentsOf: Data((key + "\n").utf8))
    }

    /// The install is complete: the journal is no longer needed.
    func finish() {
        try? handle?.close(); handle = nil
        try? FileManager.default.removeItem(at: url)
    }
}

/// Counts fetched bytes from the chunk tasks and reports at most four times a second.
final class GOGMeter: @unchecked Sendable {
    let total: UInt64
    private let lock = NSLock()
    private var fetched: UInt64 = 0
    private let alreadyDone: UInt64
    private var lastReport = Date.distantPast
    private var samples: [(Date, UInt64)] = []
    private let report: @Sendable (GOGDownloadProgress) -> Void

    init(total: UInt64, alreadyDone: UInt64 = 0, report: @escaping @Sendable (GOGDownloadProgress) -> Void) {
        self.total = total
        self.alreadyDone = alreadyDone
        self.report = report
    }
    /// Bytes fetched by this run (not counting what earlier runs left on disk).
    var fetchedThisRun: UInt64 { lock.lock(); defer { lock.unlock() }; return fetched }

    func add(_ bytes: UInt64) {
        lock.lock(); fetched += bytes; lock.unlock()
        publish(force: false)
    }

    func publish(force: Bool) {
        lock.lock()
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.25 else { lock.unlock(); return }
        lastReport = now
        samples.append((now, fetched))
        samples.removeAll { now.timeIntervalSince($0.0) > 8 }
        var state = GOGDownloadProgress(phase: .downloading, totalBytes: total, doneBytes: min(alreadyDone + fetched, total))
        if let first = samples.first, now.timeIntervalSince(first.0) > 0.5 {
            state.bytesPerSecond = Double(fetched - first.1) / now.timeIntervalSince(first.0)
        }
        lock.unlock()
        report(state)
    }
}

/// Install-folder paths with Windows' case-insensitive folder names: a folder that
/// exists in another spelling is reused instead of created a second time.
final class GOGPathResolver {
    let root: URL
    private var listings: [String: [String: String]] = [:]   // folder path -> lowercased name -> name

    init(root: URL) { self.root = root }
    /// Case and Unicode normalization do not make two names different (Windows, APFS).
    static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    private func names(in folder: URL) -> [String: String] {
        if let cached = listings[folder.path] { return cached }
        var map: [String: String] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] { map[Self.key(name)] = name }
        listings[folder.path] = map
        return map
    }

    /// The file's URL when it exists in any spelling of its path.
    func existing(_ parts: [String]) -> URL? {
        var url = root
        for part in parts {
            guard let name = names(in: url)[Self.key(part)] else { return nil }
            url.appendPathComponent(name)
        }
        return url
    }

    /// The file's URL, creating its folders; existing spellings are kept.
    func create(_ parts: [String]) throws -> URL {
        var url = root
        for (i, part) in parts.enumerated() {
            let folder = url
            let name = names(in: folder)[Self.key(part)] ?? part
            url.appendPathComponent(name)
            if i < parts.count - 1 {
                var isFolder: ObjCBool = false
                if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                    listings[folder.path, default: [:]][Self.key(part)] = part
                } else if !isFolder.boolValue {
                    throw GOGFormatError.unsafePath
                }
            } else {
                listings[folder.path, default: [:]][Self.key(part)] = name
            }
        }
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw GOGFormatError.unsafePath }
        return url
    }
}
