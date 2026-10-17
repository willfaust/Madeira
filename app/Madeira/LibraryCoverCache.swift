// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Combine
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The library's covers for the zoomable grid (docs/zoomable-grid.md, "Covers"). A lookup is synchronous: it returns the best
// bitmap resident for that game at once (the exact size, else the nearest other size, which the GPU scales) and asks for the
// exact size, which replaces it in place when it lands (`updates`). Bitmaps are downsampled to the pixel width asked for
// (ImageIO, off the main thread), held in memory under a byte budget, and the fetched files are kept on disk
// (Caches/madeira-covers). The candidates are the ones the cards try (SteamGamesRules.artwork; a cover chosen from Files first).

@MainActor
final class LibraryCoverCache {
    static let shared = LibraryCoverCache()

    /// Where a game's cover comes from: a cover file (Documents/madeira-art), else Steam's candidate URLs in order. `key` names the game's art.
    struct Source: Hashable {
        let key: String
        var file: URL?
        var urls: [URL] = []
        /// The bitmap carries the not-downloaded blur spot (LibraryCoverSpot), baked in when prepared: a variant of the same art that shares the files and the candidate record, not the resident bitmaps.
        var spot = false
        var variant: String { spot ? key + "|spot" : key }
        var other: Source { var copy = self; copy.spot.toggle(); return copy }
    }

    let updates = PassthroughSubject<String, Never>()
    /// The keys that landed since the last frame, once per frame: the grid takes one pass over its visible cells however many covers landed.
    let batches = PassthroughSubject<Set<String>, Never>()

    static let budget = 48 * 1024 * 1024
    static let budgetCeiling = 128 * 1024 * 1024
    /// Pixel widths are rounded up to this step, so nearby sizes share a bitmap (4 bytes x 48 x n: every row a multiple of 64 bytes, the stride the compositor wants).
    nonisolated static let step = 48
    /// Steam downloads in flight at once: all of them, and the share that may be prefetch. The cap keeps decodes and memory in step; it is not there to protect the line.
    static let netCap = 12
    static let netCapAhead = 6

    private final class Box { let image: UIImage; init(_ image: UIImage) { self.image = image } }
    private let memory = NSCache<NSString, Box>()
    private var sizes: [String: Set<Int>] = [:]
    private var inFlight = Set<String>()
    private var failed: [String: Date] = [:]
    static let retryAfter: TimeInterval = 60
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let aheadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    var paused = false { didSet { if !paused { drainPrefetch() } } }
    private var prefetchQueue: [(Source, Int)] = []

    nonisolated static let folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("madeira-covers", isDirectory: true)

    nonisolated private static let folderMade: Void = { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }()

    private var releaseObserver: NSObjectProtocol?

    private init() {
        memory.totalCostLimit = Self.budget
        releaseObserver = NotificationCenter.default.addObserver(forName: LibraryGridArm.releaseMemory, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseMemory() }
        }
        Self.trimDiskInBackground()
    }

    // MARK: Disk

    nonisolated static let diskCap = 300 * 1024 * 1024
    private var landedSinceTrim = 0

    nonisolated private static func trimDiskInBackground() {
        DispatchQueue.global(qos: .utility).async { trimDisk(cap: diskCap) }
    }

    /// Deletes the least recently used covers (a cover is its `.img` and its `.src`; a disk hit refreshes the modification time) until the folder is within 80% of `cap`.
    nonisolated static func trimDisk(cap: Int) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        var covers: [(image: URL, used: Date, bytes: Int)] = []
        var total = 0
        for image in files where image.pathExtension == "img" {
            let values = try? image.resourceValues(forKeys: Set(keys))
            let record = originURL(image)
            let bytes = (values?.fileSize ?? 0) + ((try? record.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            covers.append((image, values?.contentModificationDate ?? .distantPast, bytes))
            total += bytes
        }
        guard total > cap else { return }
        for cover in covers.sorted(by: { $0.used < $1.used }) where total > cap / 5 * 4 {
            try? fm.removeItem(at: cover.image)
            try? fm.removeItem(at: originURL(cover.image))
            total -= cover.bytes
        }
    }

    nonisolated static func bucket(_ pixelWidth: Int) -> Int { max(step, (pixelWidth + step - 1) / step * step) }

    // MARK: Budget

    private(set) var budgetBytes = LibraryCoverCache.budget

    /// Room for `screens` screens of the current level (a screen is `cardsPerScreen` bitmaps of `pixelWidth` x 1.5 x 4 bytes), a
    /// quarter more for the neighbour level and the old size a zoom leaves behind, between 48 MB and 128 MB. NSCache gives bitmaps
    /// back under memory pressure on its own.
    func sizeBudget(cardsPerScreen: Int, pixelWidth: Int, screens: Int = 3) {
        let bucket = Self.bucket(pixelWidth)
        let bytes = bucket * bucket * 3 / 2 * 4 * cardsPerScreen * screens * 5 / 4
        setBudget(min(Self.budgetCeiling, max(Self.budget, bytes)))
    }

    func releaseMemory() {
        memory.removeAllObjects()
        sizes = [:]
    }

    private func setBudget(_ bytes: Int) {
        guard bytes != budgetBytes else { return }
        budgetBytes = bytes
        memory.totalCostLimit = bytes
    }

    // MARK: Lookups

    func image(for source: Source, pixelWidth: Int) -> (image: UIImage, exact: Bool)? {
        let want = Self.bucket(pixelWidth)
        if let hit = memory.object(forKey: name(source.variant, want)) {
            if source.file == nil { reconsider(source) }
            return (hit.image, true)
        }
        load(source, bucket: want)
        // Another variant of the art stands in until this one lands (an install or uninstall switches it): a card never goes blank.
        return (bestResident(source.variant, near: want) ?? bestResident(source.other.variant, near: want)).map { ($0, false) }
    }

    func bestResident(_ key: String, near bucket: Int) -> UIImage? {
        guard let known = sizes[key] else { return nil }
        let ordered = known.sorted { a, b in
            let da = a >= bucket ? a - bucket : (bucket - a) * 4   // a smaller one blurs: prefer bigger
            let db = b >= bucket ? b - bucket : (bucket - b) * 4
            return da < db
        }
        for size in ordered {
            if let box = memory.object(forKey: name(key, size)) { return box.image }
        }
        return nil
    }

    func prefetch(_ items: [(Source, Int)]) {
        prefetchQueue = items.filter { memory.object(forKey: name($0.0.variant, Self.bucket($0.1))) == nil }
        if !paused { drainPrefetch() }
    }

    private func drainPrefetch() {
        let items = prefetchQueue
        prefetchQueue = []
        for (index, (source, width)) in items.prefix(200).enumerated() {
            load(source, bucket: Self.bucket(width), priority: .veryLow, rank: 1_000_000 + index)
        }
    }

    // MARK: Covers ahead

    private var aheadGeneration = 0

    /// Covers the page will scroll to, nearest first, at the exact bucket the cards will ask for. Below what a view asked for, above
    /// the idle neighbour-level prefetch, and not held up by a scroll. The newest call goes first.
    func prefetchAhead(_ items: [(Source, Int)]) {
        guard !paused, !items.isEmpty else { return }
        aheadGeneration += 1
        for (index, (source, width)) in items.prefix(120).enumerated() {
            let bucket = Self.bucket(width)
            if memory.object(forKey: name(source.variant, bucket)) != nil { continue }
            load(source, bucket: bucket, priority: .low, rank: index - aheadGeneration * 100_000, lane: .ahead)
        }
    }

    func cancelAhead(keys: some Sequence<String>) {
        for key in keys { if let job = loading[key], job.lane == .ahead, job.cancelable { cancel(job) } }
    }

    func dropIdle() {
        prefetchQueue = []
        let idle = loading.values.filter { $0.lane == .demand && $0.priority == .veryLow && $0.cancelable }
        for job in idle { cancel(job) }
    }


    private func name(_ key: String, _ bucket: Int) -> NSString { "\(key)#\(bucket)" as NSString }

    // MARK: Loading

    private enum Lane { case demand, ahead }

    /// One game's load: a decode of the file or the disk copy, else the candidates fetched in turn. One at a time per game.
    @MainActor private final class Job {
        let source: Source
        let bucket: Int
        var priority: Operation.QueuePriority
        var lane: Lane
        var demanded: Bool
        var rank: Int
        var seq = 0
        var op: Operation?
        var task: URLSessionDataTask?
        var remaining: [URL]
        var holdsSlot = false
        var slotWasPrefetch = false
        var cancelled = false
        /// The op in `op` decodes a download (not the local copy): it is not re-made on another queue.
        var decodingDownload = false
        var reconsider = false
        init(source: Source, bucket: Int, priority: Operation.QueuePriority, lane: Lane, rank: Int) {
            self.source = source; self.bucket = bucket; self.priority = priority; self.lane = lane; self.rank = rank
            demanded = priority == .high
            remaining = source.urls
        }
        var cancelable: Bool { !demanded && !reconsider && !(op?.isExecuting ?? false) }
    }

    private var loading: [String: Job] = [:]
    private var waiting: [String: [(Source, Int, Operation.QueuePriority)]] = [:]
    /// The candidate each game's bitmaps came from (nil: a cover file, or a disk copy from before the record was kept).
    private var origin: [String: String] = [:]

    private func load(_ source: Source, bucket: Int, priority: Operation.QueuePriority = .high, rank: Int = 0, lane: Lane = .demand) {
        let key = source.key
        let id = "\(source.variant)#\(bucket)"
        guard !inFlight.contains(id) else {
            // Asked for already (by the prefetch): a view asking now makes it a view's request.
            if let job = loading[key] {
                if priority == .high { promote(job) } else if job.lane == .ahead, !job.demanded { job.rank = rank }
            }
            return
        }
        if let when = failed[key], Date().timeIntervalSince(when) < Self.retryAfter { return }
        guard source.file != nil || !source.urls.isEmpty else { return }
        inFlight.insert(id)
        // One load per game at a time: another size waits for it and then decodes the disk copy it wrote (a card and its glow never
        // fetch the same cover twice, nor end on two different candidates).
        if let running = loading[key] {
            if priority == .high { promote(running) }
            waiting[key, default: []].append((source, bucket, priority))
            return
        }
        let job = Job(source: source, bucket: bucket, priority: priority, lane: lane, rank: rank)
        loading[key] = job
        enqueue(job)
    }

    private func promote(_ job: Job) {
        guard !job.demanded else { return }
        job.demanded = true
        job.priority = .high
        job.task?.priority = 0.75
        guard let op = job.op, !op.isExecuting, !op.isFinished else { return }
        if job.lane == .ahead, !job.decodingDownload {
            // Waiting on the utility queue: move it to the one a view's request uses.
            op.cancel()
            job.lane = .demand
            job.op = nil
            enqueue(job)
        } else {
            op.queuePriority = .high
        }
    }

    private func enqueue(_ job: Job) {
        let source = job.source, bucket = job.bucket
        let disk = Self.diskURL(source.key)
        let operation = BlockOperation()
        // A file or a disk copy decodes at once; otherwise the candidates are fetched in turn.
        operation.addExecutionBlock {
            if let (local, from) = Self.decodeLocal(source: source, disk: disk, pixelWidth: bucket) {
                Task { @MainActor in self.landed(job, image: local, from: from) }
                return
            }
            Task { @MainActor in self.needsNetwork(job) }
        }
        operation.queuePriority = job.priority
        job.op = operation
        (job.lane == .ahead ? aheadQueue : queue).addOperation(operation)
    }

    // MARK: Network

    private var netPending: [Job] = []
    private var netSeq = 0
    private var activeTotal = 0
    private var activePrefetch = 0

    private func needsNetwork(_ job: Job) {
        guard loading[job.source.key] === job, !job.cancelled else { return }
        guard !job.remaining.isEmpty else { landed(job, image: nil, from: nil); return }
        netSeq += 1
        job.seq = netSeq
        netPending.append(job)
        pumpNet()
    }

    private func pumpNet() {
        guard !netPending.isEmpty else { return }
        while !netPending.isEmpty {
            var best = 0
            for i in 1..<netPending.count where Self.goesBefore(netPending[i], netPending[best]) { best = i }
            let job = netPending[best]
            if activeTotal >= Self.netCap { return }
            if !job.demanded, activePrefetch >= Self.netCapAhead { return }
            netPending.remove(at: best)
            job.holdsSlot = true
            job.slotWasPrefetch = !job.demanded
            activeTotal += 1
            if job.slotWasPrefetch { activePrefetch += 1 }
            download(job)
        }
    }

    private static func goesBefore(_ a: Job, _ b: Job) -> Bool {
        if a.demanded != b.demanded { return a.demanded }
        if a.rank != b.rank { return a.rank < b.rank }
        return a.seq < b.seq
    }

    private func releaseSlot(_ job: Job) {
        guard job.holdsSlot else { return }
        job.holdsSlot = false
        activeTotal -= 1
        if job.slotWasPrefetch { activePrefetch -= 1 }
        pumpNet()
    }

    private func download(_ job: Job) {
        guard !job.cancelled, loading[job.source.key] === job else { return }
        guard let url = job.remaining.first else { landed(job, image: nil, from: nil); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let good = (response as? HTTPURLResponse)?.statusCode == 200 && (data?.count ?? Int.max) < 20_000_000
            Task { @MainActor in self.downloaded(job, url: url, data: good ? data : nil) }
        }
        task.priority = job.demanded ? 0.75 : 0.25
        job.task = task
        task.resume()
    }

    private func downloaded(_ job: Job, url: URL, data: Data?) {
        guard !job.cancelled, loading[job.source.key] === job else { return }
        job.task = nil
        guard let data else {
            job.remaining.removeFirst()
            download(job)
            return
        }
        releaseSlot(job)
        landedSinceTrim += 1
        if landedSinceTrim >= 25 { landedSinceTrim = 0; Self.trimDiskInBackground() }
        let bucket = job.bucket, key = job.source.key, disk = Self.diskURL(key), spot = job.source.spot
        let operation = BlockOperation()
        operation.addExecutionBlock {
            guard var image = Self.downsample(data: data, pixelWidth: spot ? Self.spotWidth : bucket) else {
                Task { @MainActor in
                    guard !job.cancelled, self.loading[key] === job else { return }
                    job.remaining.removeFirst()
                    self.needsNetwork(job)
                }
                return
            }
            _ = Self.folderMade
            try? data.write(to: disk, options: .atomic)
            try? url.absoluteString.write(to: Self.originURL(disk), atomically: true, encoding: .utf8)
            if spot {
                image = Self.bakeSpotCopy(of: image, key: key, from: url.absoluteString, pixelWidth: bucket)
            } else {
                Self.dropSpotCopy(of: key, unlessFrom: url.absoluteString)
            }
            Task { @MainActor in self.landed(job, image: image, from: url.absoluteString) }
        }
        operation.queuePriority = job.priority
        job.decodingDownload = true
        job.op = operation
        (job.lane == .ahead ? aheadQueue : queue).addOperation(operation)
    }

    private func cancel(_ job: Job) {
        let key = job.source.key
        job.cancelled = true
        job.task?.cancel()
        job.task = nil
        job.op?.cancel()
        netPending.removeAll { $0 === job }
        releaseSlot(job)
        inFlight.remove("\(job.source.variant)#\(job.bucket)")
        for (waiter, size, _) in waiting.removeValue(forKey: key) ?? [] { inFlight.remove("\(waiter.variant)#\(size)") }
        if loading[key] === job { loading[key] = nil }
    }

    // MARK: Landing

    private func landed(_ job: Job, image: UIImage?, from: String?) {
        let source = job.source, key = source.key
        guard loading[key] === job, !job.cancelled else { return }   // dropped, and perhaps asked for again since
        releaseSlot(job)
        job.task = nil
        inFlight.remove("\(source.variant)#\(job.bucket)")
        loading[key] = nil
        let next = waiting.removeValue(forKey: key) ?? []
        for (waiter, size, _) in next { inFlight.remove("\(waiter.variant)#\(size)") }
        if job.reconsider {
            if let image, let from {
                dropResident(source)
                origin[key] = from
                store(image, source: source, bucket: job.bucket)
            }
            for (waiter, size, priority) in next { load(waiter, bucket: size, priority: priority) }
            return
        }
        guard let image else {
            failed[key] = Date()
            return
        }
        failed[key] = nil
        if let from, let known = origin[key], known != from {
            // Another candidate than the resident sizes': they are dropped, so every size shows the same art.
            dropResident(source)
        }
        if let from { origin[key] = from }
        store(image, source: source, bucket: job.bucket)
        for (waiter, size, priority) in next { load(waiter, bucket: size, priority: priority) }
        if source.file == nil { reconsider(source) }
    }

    private func store(_ image: UIImage, source: Source, bucket: Int) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memory.setObject(Box(image), forKey: name(source.variant, bucket), cost: cost)
        sizes[source.variant, default: []].insert(bucket)
        notify(source.key)
    }

    private func dropResident(_ source: Source) {
        for variant in [source.variant, source.other.variant] {
            for size in sizes[variant] ?? [] { memory.removeObject(forKey: name(variant, size)) }
            sizes[variant] = []
        }
    }

    // The landed covers are told to the views once per frame (a fling lands several a frame, each notification a pass over the visible cells).
    private var landedKeys = Set<String>()
    private var flushScheduled = false

    private func notify(_ key: String) {
        landedKeys.insert(key)
        guard !flushScheduled else { return }
        flushScheduled = true
        LibraryGridNextFrame.run { [weak self] in MainActor.assumeIsolated { self?.flush() } }
    }

    private func flush() {
        flushScheduled = false
        let keys = landedKeys
        landedKeys = []
        guard !keys.isEmpty else { return }
        batches.send(keys)
        for key in keys { updates.send(key) }
    }

    /// A cover that came from a later candidate (an earlier one failed for a moment, or was not known yet: the owned library's
    /// capsule arrives after the install records) is asked for again from the top, once per app run and candidate list, as the
    /// original grid does. The resident art stays until a better one answers.
    private var reconsidered = Set<String>()
    private func reconsider(_ source: Source) {
        guard let first = source.urls.first?.absoluteString, origin[source.key] != first,
              loading[source.key] == nil, reconsidered.insert(source.key + "|" + first).inserted else { return }
        let ranked = source.urls.map(\.absoluteString)
        let better = Array(source.urls.prefix(origin[source.key].flatMap { ranked.firstIndex(of: $0) } ?? ranked.count))
        guard !better.isEmpty, let bucket = sizes[source.variant]?.max() else { return }
        let job = Job(source: source, bucket: bucket, priority: .veryLow, lane: .demand, rank: 2_000_000)
        job.reconsider = true
        job.remaining = better
        loading[source.key] = job
        needsNetwork(job)
    }

    nonisolated static func diskURL(_ key: String) -> URL {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        return folder.appendingPathComponent(safe + ".img", isDirectory: false)
    }

    nonisolated static func originURL(_ disk: URL) -> URL { disk.deletingPathExtension().appendingPathExtension("src") }

    /// Off the main thread: the cover file or the disk copy, downsampled, and the candidate the disk copy came from (nil for a file, or a copy kept before the record was).
    nonisolated private static func decodeLocal(source: Source, disk: URL, pixelWidth: Int) -> (UIImage, String?)? {
        if source.spot { return decodeSpot(source: source, disk: disk, pixelWidth: pixelWidth) }
        if let file = source.file, let image = downsample(url: file, pixelWidth: pixelWidth) { return (image, nil) }
        if FileManager.default.fileExists(atPath: disk.path), let image = downsample(url: disk, pixelWidth: pixelWidth) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: disk.path)
            return (image, try? String(contentsOf: originURL(disk), encoding: .utf8))
        }
        return nil
    }

    // MARK: Spot copies

    /// The width the blur spot is baked at, and of the baked copy kept on disk: the widest bucket a card asks for. A narrower bucket
    /// downsamples that copy, which matches baking at the narrower width (the blur and fade radii are fractions of the art's short side).
    nonisolated static let spotWidth = bucket(Int(((LibraryGridGeometry.maxCard - 2 * LibraryGridGeometry.cardPadding) * 3).rounded(.up)))

    /// The not-downloaded variant of a cover: its baked copy on disk (beside the plain copy, under its own key, with the candidate
    /// record), else the cover file or the plain disk copy baked once and kept. Every later decode downsamples the baked copy.
    nonisolated private static func decodeSpot(source: Source, disk: URL, pixelWidth: Int) -> (UIImage, String?)? {
        let fm = FileManager.default
        let copy = diskURL(source.variant)
        if fm.fileExists(atPath: copy.path), let image = downsample(url: copy, pixelWidth: pixelWidth) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: copy.path)
            return (image, try? String(contentsOf: originURL(copy), encoding: .utf8))
        }
        var plain: UIImage?
        var from: String?
        if let file = source.file { plain = downsample(url: file, pixelWidth: spotWidth) }
        if plain == nil, fm.fileExists(atPath: disk.path), let image = downsample(url: disk, pixelWidth: spotWidth) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: disk.path)
            plain = image
            from = try? String(contentsOf: originURL(disk), encoding: .utf8)
        }
        guard let plain else { return nil }
        return (bakeSpotCopy(of: plain, key: source.key, from: from, pixelWidth: pixelWidth), from)
    }

    /// Bakes the spot into `plain` (at most `spotWidth` wide), keeps it on disk as the cover's spot copy, and returns it downsampled to `pixelWidth` (`plain` downsampled, nothing kept, when the bake fails).
    nonisolated private static func bakeSpotCopy(of plain: UIImage, key: String, from: String?, pixelWidth: Int) -> UIImage {
        let baked = LibraryCoverSpot.baked(plain)
        let copy = diskURL(key + "|spot")
        guard baked !== plain, let data = baked.jpegData(compressionQuality: 0.92) else { return plain }
        _ = folderMade
        try? data.write(to: copy, options: .atomic)
        if let from { try? from.write(to: originURL(copy), atomically: true, encoding: .utf8) }
        return downsample(data: data, pixelWidth: pixelWidth) ?? baked
    }

    nonisolated private static func dropSpotCopy(of key: String, unlessFrom candidate: String) {
        let copy = diskURL(key + "|spot")
        guard FileManager.default.fileExists(atPath: copy.path),
              (try? String(contentsOf: originURL(copy), encoding: .utf8)) != candidate else { return }
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.removeItem(at: originURL(copy))
    }

    nonisolated private static func downsample(url: URL, pixelWidth: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return downsample(source, pixelWidth: pixelWidth)
    }

    nonisolated private static func downsample(data: Data, pixelWidth: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return downsample(source, pixelWidth: pixelWidth)
    }

    nonisolated private static func downsample(_ source: CGImageSource, pixelWidth: Int) -> UIImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? CGFloat, let h = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              w > 0, h > 0 else { return nil }
        let target = CGFloat(pixelWidth)
        let scale = min(1, max(target / w, target * 1.5 / h))
        let maxPixel = max(1, Int((max(w, h) * scale).rounded(.up)))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

extension LibraryCoverCache.Source {
    /// The candidates per app id: built from the account's game records (a linear search each) for every card a lookup configures, so kept until the records change.
    @MainActor private static var artworkMemo: [Int: [URL]] = [:]
    @MainActor private static var artworkMemoRevision = -1

    @MainActor static func steam(_ appID: Int) -> Self {
        let account = SteamOwnedLibrary.shared
        if artworkMemoRevision != account.ownedRevision { artworkMemo.removeAll(); artworkMemoRevision = account.ownedRevision }
        if let known = artworkMemo[appID] { return Self(key: "steam-\(appID)", urls: known) }
        let urls = SteamGamesRules.artwork(appID: appID) { account.game($0) }
        artworkMemo[appID] = urls
        return Self(key: "steam-\(appID)", urls: urls)
    }

    /// A game you added: its chosen cover file, else its store match's. A cover file that cannot be read falls back to the store match's candidates.
    @MainActor static func entry(_ entry: LibraryEntry) -> Self? {
        let steamID = entry.steamID ?? entry.steamAppID
        if let name = entry.coverFile {
            let (file, key) = coverFile(named: name)
            return Self(key: key, file: file, urls: steamID.map { steam($0).urls } ?? [])
        }
        return steamID.map { steam($0) }
    }

    @MainActor private static var modificationTimes: [String: Double] = [:]

    @MainActor static func coverFileChanged(named name: String) {
        modificationTimes[URL(fileURLWithPath: name, isDirectory: false).lastPathComponent] = nil
    }

    /// A chosen cover's file and the key its art is cached under. The key carries the file's modification time, so a replaced file is a different cover (a missing file is time 0).
    @MainActor static func coverFile(named name: String) -> (url: URL, key: String) {
        let leaf = URL(fileURLWithPath: name, isDirectory: false).lastPathComponent
        let url = LibraryModel.documents.appendingPathComponent("madeira-art/" + leaf, isDirectory: false)
        let time: Double
        if let known = modificationTimes[leaf] {
            time = known
        } else {
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            time = modified?.timeIntervalSinceReferenceDate ?? 0
            modificationTimes[leaf] = time
        }
        return (url, "file-\(leaf)-\(Int(time * 1000))")
    }
}
