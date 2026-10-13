// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Akshay CM
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CryptoKit
import Foundation

/// Progress of one Epic download, published to the library model.
struct EpicDownloadProgress: Equatable, Sendable {
    enum Phase: String, Sendable { case preparing, verifying, downloading, finishing }
    var phase: Phase = .preparing
    /// Downloading: compressed chunk bytes to fetch and fetched. Verifying: file
    /// bytes to check and checked.
    var totalBytes: UInt64 = 0
    var doneBytes: UInt64 = 0
    var bytesPerSecond: Double = 0
    var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
}

enum EpicDownloadError: LocalizedError {
    case diskSpace(needed: Int64)
    case chunk(String)
    case noServers

    var errorDescription: String? {
        switch self {
        case .diskSpace(let needed):
            return "Not enough free space on this device: this download needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) more. Free some space, then try again."
        case .chunk(let reason): return "A game file could not be downloaded from Epic (\(reason)). Try again to continue."
        case .noServers: return "Epic did not name a download server for this game."
        }
    }
}

/// Builds an install folder from an Epic manifest (docs/EPIC_GAMES.md, "A download").
///
/// - Files that are already right are kept: a file the journal recorded for this
///   build, a file an update leaves unchanged (same SHA-1 in both manifests) and,
///   otherwise, any file whose size and SHA-1 match.
/// - Chunks are fetched by up to `window` tasks ahead of the writer, in the order
///   the files need them, and are checked (GUID, size, SHA-1) before use. A chunk
///   that later files need again stays in memory up to `memoryBudget`, and on disk
///   beyond it, until its last use.
/// - Each file is written to a temporary name, checked against its SHA-1 and only
///   then renamed into place, so an interrupted update leaves the old file.
/// - Paths stay inside the install folder; directory names are matched without
///   case, as Windows does.
final class EpicDownloader: @unchecked Sendable {
    var window = 12
    var memoryBudget = 96 << 20
    var attempts = 6
    /// Pause between retries of one chunk, doubled per attempt (tests set 0).
    var retryDelay: Double = 0.25

    private let http: URLSession

    static let userAgent = "EpicGamesLauncher/11.0.1-14907503+++Portal+Release-Live Windows/10.0.19041.1.256.64bit"

    init(session: URLSession? = nil) {
        if let session { http = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 16
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        http = URLSession(configuration: config)
    }

    struct Result: Sendable {
        var filesWritten = 0
        var filesKept = 0
        var bytesFetched: UInt64 = 0
        var installBytes: Int64 = 0
    }

    /// Installs, updates (`previous` is the installed build) or repairs (`verifyAll`)
    /// the files of `manifest` in `folder`. Throws CancellationError when cancelled.
    func install(manifest: EpicManifest, baseURLs: [URL], secrets: [String: String], folder: URL,
                 previous: EpicManifest?, verifyAll: Bool, journal journalURL: URL,
                 progress report: @escaping @Sendable (EpicDownloadProgress) -> Void) async throws -> Result {
        guard !baseURLs.isEmpty else { throw EpicDownloadError.noServers }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = EpicPathResolver(root: folder)
        let journal = try EpicJournal(url: journalURL, build: manifest.appName + "#" + manifest.buildVersion)
        var result = Result()

        // Which files to write.
        struct Planned { var file: EpicFileEntry; var parts: [String] }
        var all: [Planned] = []
        for file in manifest.files where file.symlinkTarget.isEmpty {
            guard let parts = EpicManifest.components(file.name) else { throw EpicFormatError.unsafePath }
            all.append(Planned(file: file, parts: parts))
        }
        result.installBytes = all.reduce(0) { $0 + $1.file.size }
        var unchanged = [String: Data]()
        for file in previous?.files ?? [] { unchanged[file.name.lowercased()] = file.sha1 }

        var needed: [Planned] = []
        var toVerify: [(Planned, URL)] = []
        for item in all {
            let url = paths.existing(item.parts)
            let size = url.flatMap { (try? fm.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value }
            guard let url, size == item.file.size else { needed.append(item); continue }
            if !verifyAll && (journal.contains(item.file) || unchanged[item.file.name.lowercased()] == item.file.sha1) {
                result.filesKept += 1
            } else {
                toVerify.append((item, url))
            }
        }
        if !toVerify.isEmpty {
            var state = EpicDownloadProgress(phase: .verifying)
            state.totalBytes = UInt64(toVerify.reduce(0) { $0 + $1.0.file.size })
            report(state)
            for (item, url) in toVerify {
                try Task.checkCancellation()
                let digest = try Self.sha1(of: url, progress: { state.doneBytes += UInt64($0); report(state) })
                if digest == item.file.sha1 {
                    journal.record(item.file)
                    result.filesKept += 1
                } else {
                    needed.append(item)
                }
            }
        }

        // Chunks the needed files use: their first-use order and use counts.
        var order: [EpicGUID] = []
        var position: [EpicGUID: Int] = [:]
        var uses: [EpicGUID: Int] = [:]
        for item in needed {
            for part in item.file.parts {
                guard let info = manifest.chunks[part.guid], UInt64(part.offset) + UInt64(part.size) <= UInt64(info.windowSize) else {
                    throw EpicFormatError.unsupported("file part without its chunk")
                }
                if position[part.guid] == nil { position[part.guid] = order.count; order.append(part.guid) }
                uses[part.guid, default: 0] += 1
            }
        }

        // Free space: what grows, plus room for the largest temporary file.
        var growth: Int64 = 0, largest: Int64 = 0
        for item in needed {
            let old = paths.existing(item.parts).flatMap { (try? fm.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value } ?? 0
            growth += max(0, item.file.size - old)
            largest = max(largest, item.file.size)
        }
        // Checked before any chunk is fetched, on a resume too (only what is still needed
        // counts). Some volumes report zero for the important-usage estimate although they
        // have free blocks, so the plain capacity is the fallback (ported from
        // willfaust/Madeira#207, iediot).
        if let free = Self.freeSpace(at: folder), free < growth + largest + (64 << 20) {
            throw EpicDownloadError.diskSpace(needed: growth + largest + (64 << 20) - free)
        }

        // Progress covers the whole build, as the Steam downloader's does: what files already
        // on disk (kept, journaled or verified) need counts as done, so a resumed download
        // continues from where it stopped instead of showing 0% again.
        func downloadSize(_ guids: Set<EpicGUID>) -> UInt64 {
            guids.reduce(0) { $0 + UInt64(max(0, manifest.chunks[$1]?.fileSize ?? 0)) }
        }
        let wholeBuild = downloadSize(Set(all.flatMap { $0.file.parts.map(\.guid) }))
        let stillNeeded = downloadSize(Set(order))
        let meter = EpicMeter(total: max(wholeBuild, stillNeeded), alreadyDone: max(wholeBuild, stillNeeded) - stillNeeded, report: report)
        meter.publish(force: true)
        let spill = journalURL.deletingPathExtension().appendingPathExtension("chunks")
        try? fm.removeItem(at: spill)
        var cache: [EpicGUID: Data] = [:], cacheBytes = 0
        var spilled = Set<EpicGUID>()
        var inflight: [EpicGUID: Task<Data, Error>] = [:]
        var nextStart = 0
        defer {
            for task in inflight.values { task.cancel() }
            try? fm.removeItem(at: spill)
        }

        func start(_ guid: EpicGUID) {
            guard let info = manifest.chunks[guid] else { return }
            inflight[guid] = Task.detached { [self] in
                try await self.fetch(info, bases: baseURLs, secrets: secrets, meter: meter)
            }
        }
        func chunk(_ guid: EpicGUID) async throws -> Data {
            if let data = cache[guid] { return data }
            if spilled.contains(guid) { return try Data(contentsOf: spill.appendingPathComponent(guid.hex)) }
            let limit = min(order.count, (position[guid] ?? 0) + window + 1)
            while nextStart < limit { start(order[nextStart]); nextStart += 1 }
            guard let task = inflight.removeValue(forKey: guid) else { throw EpicDownloadError.chunk("order") }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        func release(_ guid: EpicGUID, _ data: Data) throws {
            let left = (uses[guid] ?? 1) - 1
            uses[guid] = left
            if left <= 0 {
                if let dropped = cache.removeValue(forKey: guid) { cacheBytes -= dropped.count }
                if spilled.remove(guid) != nil { try? fm.removeItem(at: spill.appendingPathComponent(guid.hex)) }
            } else if cache[guid] == nil && !spilled.contains(guid) {
                if cacheBytes + data.count <= memoryBudget {
                    cache[guid] = data; cacheBytes += data.count
                } else {
                    try fm.createDirectory(at: spill, withIntermediateDirectories: true)
                    try data.write(to: spill.appendingPathComponent(guid.hex))
                    spilled.insert(guid)
                }
            }
        }

        for item in needed {
            try Task.checkCancellation()
            let target = try paths.create(item.parts)
            let temp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).madeira-part")
            try? fm.removeItem(at: temp)
            guard fm.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            do {
                let handle = try FileHandle(forWritingTo: temp)
                var sha = Insecure.SHA1()
                do {
                    for part in item.file.parts {
                        let data = try await chunk(part.guid)
                        let slice = data.subdata(in: Int(part.offset)..<Int(part.offset + part.size))
                        try handle.write(contentsOf: slice)
                        sha.update(data: slice)
                        try release(part.guid, data)
                    }
                    try handle.close()
                } catch { try? handle.close(); throw error }
                if item.file.size > 0, Data(sha.finalize()) != item.file.sha1 { throw EpicFormatError.checksum("file") }
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
        var finishing = EpicDownloadProgress(phase: .finishing)
        finishing.totalBytes = meter.total; finishing.doneBytes = meter.total
        report(finishing)
        if let previous {
            let kept = Set(manifest.files.map { $0.name.lowercased() })
            for file in previous.files where !kept.contains(file.name.lowercased()) {
                if let parts = EpicManifest.components(file.name), let url = paths.existing(parts) { try? fm.removeItem(at: url) }
            }
        }
        journal.finish()
        result.bytesFetched = meter.fetchedThisRun
        return result
    }

    /// One chunk from the CDN, retried on the next base URL after a failure.
    private func fetch(_ info: EpicChunkInfo, bases: [URL], secrets: [String: String], meter: EpicMeter) async throws -> Data {
        var lastReason = "no answer"
        for attempt in 0..<max(1, attempts) {
            try Task.checkCancellation()
            let base = bases[attempt % bases.count].absoluteString
            guard let url = URL(string: (base.hasSuffix("/") ? base : base + "/") + info.path) else { throw EpicDownloadError.chunk("url") }
            do {
                let (data, response) = try await http.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw EpicDownloadError.chunk("http \(status)") }
                let window = try EpicChunk.decode(data, expected: info, secrets: secrets)
                meter.add(UInt64(max(0, info.fileSize)))
                return window
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastReason = (error as? URLError).map { "url \($0.code.rawValue)" } ?? (error as? EpicDownloadError)?.reason ?? "\(error)"
                if retryDelay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * Double(1 << min(attempt, 4)) * 1e9))
                }
            }
        }
        throw EpicDownloadError.chunk(lastReason)
    }

    /// Free bytes on the volume of `url`, or nil when the volume does not say.
    static func freeSpace(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage, plain = values.volumeAvailableCapacity.map(Int64.init)
        if important == nil && plain == nil { return nil }
        return max(important ?? 0, plain ?? 0)
    }

    static func sha1(of url: URL, progress: (Int) -> Void = { _ in }) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = Insecure.SHA1()
        while true {
            let block = try handle.read(upToCount: 4 << 20) ?? Data()
            if block.isEmpty { break }
            sha.update(data: block)
            progress(block.count)
        }
        return Data(sha.finalize())
    }
}

private extension EpicDownloadError {
    var reason: String? { if case .chunk(let reason) = self { return reason }; return nil }
}

/// Counts fetched bytes from the chunk tasks and reports at most four times a second.
final class EpicMeter: @unchecked Sendable {
    let total: UInt64
    private let lock = NSLock()
    private var fetched: UInt64 = 0
    private let alreadyDone: UInt64
    private var lastReport = Date.distantPast
    private var samples: [(Date, UInt64)] = []
    private let report: @Sendable (EpicDownloadProgress) -> Void

    init(total: UInt64, alreadyDone: UInt64 = 0, report: @escaping @Sendable (EpicDownloadProgress) -> Void) {
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
        var state = EpicDownloadProgress(phase: .downloading, totalBytes: total, doneBytes: min(alreadyDone + fetched, total))
        if let first = samples.first, now.timeIntervalSince(first.0) > 0.5 {
            state.bytesPerSecond = Double(fetched - first.1) / now.timeIntervalSince(first.0)
        }
        lock.unlock()
        report(state)
    }
}

/// Files already written for one build: one line per file, so a paused or failed
/// download resumes without writing them again. A journal for another build is
/// started over.
final class EpicJournal {
    private let url: URL
    private var done = Set<String>()
    private var handle: FileHandle?
    private static func key(_ file: EpicFileEntry) -> String { file.sha1.epicHex + "\t" + file.name }

    init(url: URL, build: String) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = "madeira-epic-journal 1 " + build.replacingOccurrences(of: "\n", with: " ")
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

    func contains(_ file: EpicFileEntry) -> Bool { done.contains(Self.key(file)) }

    func record(_ file: EpicFileEntry) {
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

/// Install-folder paths with Windows' case-insensitive folder names: a folder that
/// exists in another spelling is reused instead of created a second time.
final class EpicPathResolver {
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
                    throw EpicFormatError.unsafePath
                }
            } else {
                listings[folder.path, default: [:]][Self.key(part)] = name
            }
        }
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw EpicFormatError.unsafePath }
        return url
    }
}
