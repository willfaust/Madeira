// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
import Foundation
import Combine

@main struct Check {
    @MainActor static func wait(_ label: String, timeout: TimeInterval = 30, _ ready: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !ready(), Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        precondition(ready(), label)
    }
    static func source(_ id: Int, spot: Bool = false) -> LibraryCoverCache.Source {
        .init(key: "steam-\(id)", urls: [URL(string: "https://fixture.invalid/\(id)/first")!], spot: spot)
    }
    static func librarySource(_ id: Int) -> LibraryCoverCache.Source { source(id, spot: id % 10 != 0) }
    @MainActor static func main() async {
        print("Fixture: 300x450 textured JPEG, \(Fixture.bytes.count) bytes, 3,600 games / 90% blur variants")
        let cache = LibraryCoverCache()
        // Fast responses and a blocked spot baker used to drain all 40 responses into queued Data captures.
        Gate.close()
        let blockedOwners = (0..<40).map { id -> UUID in
            let token = UUID(); _ = cache.image(for: source(id, spot: true), pixelWidth: 96, demand: token); return token
        }
        await wait("network reaches cap") { Fixture.total >= LibraryCoverCache.netCap }
        try? await Task.sleep(nanoseconds: 200_000_000)
        FileHandle.standardError.write(Data("Measured responses while decode blocked: \(Fixture.total) of 40 requested\n".utf8))
        precondition(Fixture.total == LibraryCoverCache.netCap, "response bodies must stay bounded through decode")
        print("PASS: stalled decode retains at most 12 response slots (40 requested)")
        for token in blockedOwners { cache.releaseDemand(token) }
        let afterScroll = UUID()
        _ = cache.image(for: source(50), pixelWidth: 96, demand: afterScroll)
        try? await Task.sleep(nanoseconds: 100_000_000)
        precondition(Fixture.total == LibraryCoverCache.netCap, "canceling queued decodes must not release their retained response slots")
        Gate.open()
        await wait("current request lands after bounded obsolete decodes") { cache.image(for: source(50), pixelWidth: 96, demand: afterScroll)?.exact == true }
        cache.releaseDemand(afterScroll)
        print("PASS: cancellation keeps queued response bodies accounted for until decoding completes")

        await wait("initial operations finish") { Fixture.liveJobs == 0 }
        Gate.close()
        let beforeAhead = Fixture.total
        cache.prefetchAhead((8000..<8040).map { (source($0, spot: true), 96) })
        await wait("ahead responses fill their cap") { Fixture.total == beforeAhead + LibraryCoverCache.netCapAhead }
        try? await Task.sleep(nanoseconds: 100_000_000)
        cache.cancelAhead(keys: (8000..<8040).map { "steam-\($0)" })
        let afterAhead = (8100..<8140).map { id -> UUID in
            let token = UUID(); _ = cache.image(for: source(id, spot: true), pixelWidth: 96, demand: token); return token
        }
        await wait("demand fills slots not held by ahead decodes") { Fixture.total >= beforeAhead + LibraryCoverCache.netCap }
        try? await Task.sleep(nanoseconds: 100_000_000)
        precondition(Fixture.total == beforeAhead + LibraryCoverCache.netCap, "cancelAhead keeps queued decode response slots")
        for token in afterAhead { cache.releaseDemand(token) }
        Gate.open()
        await wait("ahead decodes finish") { Fixture.liveJobs == 0 }
        Gate.close()
        let beforeIdle = Fixture.total
        cache.prefetch((8200..<8240).map { (source($0, spot: true), 96) })
        await wait("idle responses fill their cap") { Fixture.total == beforeIdle + LibraryCoverCache.netCapAhead }
        try? await Task.sleep(nanoseconds: 100_000_000)
        cache.dropIdle()
        cache.prefetchAhead((8300..<8340).map { (source($0, spot: true), 96) })
        try? await Task.sleep(nanoseconds: 100_000_000)
        precondition(Fixture.total == beforeIdle + LibraryCoverCache.netCapAhead, "dropIdle keeps queued decode response slots")
        cache.cancelAhead(keys: (8300..<8340).map { "steam-\($0)" })
        Gate.open()
        await wait("idle decodes finish") { Fixture.liveJobs == 0 }
        print("PASS: cancelAhead and dropIdle keep downloaded decode slots accounted for")

        Fixture.configure(held: true)
        let beforeDuplicates = Fixture.total
        let duplicateSources = (8400..<8413).map { source($0) }
        let duplicateOwners = duplicateSources.map { item -> UUID in
            let token = UUID(); _ = cache.image(for: item, pixelWidth: 96, demand: token); return token
        }
        await wait("duplicate signal test fills network slots") { Fixture.total == beforeDuplicates + LibraryCoverCache.netCap }
        let activeDuplicate = (8400..<8413).first { Fixture.count("/\($0)/first") == 1 }!
        let queuedDuplicate = (8400..<8413).first { Fixture.count("/\($0)/first") == 0 }!
        cache.fixtureRepeatNetwork(for: "steam-\(activeDuplicate)")
        cache.fixtureRepeatNetwork(for: "steam-\(queuedDuplicate)")
        Fixture.release()
        await wait("duplicate network signals settle") { duplicateSources.allSatisfy { cache.image(for: $0, pixelWidth: 96)?.exact == true } }
        for token in duplicateOwners { cache.releaseDemand(token) }
        precondition((8400..<8413).allSatisfy { Fixture.count("/\($0)/first") == 1 }, "repeated network handoff must not fetch twice or leak slots")
        await wait("duplicate signal jobs release") { Fixture.liveJobs == 0 }
        print("PASS: repeated network handoffs are idempotent for queued and active jobs")

        // A 3,600-game library, scrolled in realistic 24-card windows with a separate 96-pixel glow consumer.
        for start in stride(from: 100, to: 3700, by: 24) {
            let ids = Array(start..<min(start + 24, 3700))
            let tokens = ids.map { _ in UUID() }
            for (id, token) in zip(ids, tokens) { _ = cache.image(for: librarySource(id), pixelWidth: 192, demand: token) }
            await wait("cold window") { ids.allSatisfy { cache.image(for: librarySource($0), pixelWidth: 192)?.exact == true } }
            for id in ids { _ = cache.image(for: source(id), pixelWidth: 96) }
            await wait("glow window") { ids.allSatisfy { cache.image(for: source($0), pixelWidth: 96)?.exact == true } }
            let count = Fixture.total
            for id in ids {
                let image = cache.image(for: librarySource(id), pixelWidth: 192)!.image
                precondition(image.size.width == 192 && image.size.height == 288, "ImageIO downsamples before residency")
            }
            precondition(Fixture.total == count, "warm memory must not download")
            for token in tokens { cache.releaseDemand(token) }
        }
        precondition((100..<3700).allSatisfy { Fixture.count("/\($0)/first") == 1 }, "card and glow share one download per game")
        print("PASS: 3,600 games, 24-card windows: one download per game, shared card/glow, 192x288 decoded cards, warm memory has zero requests")
        await wait("completed and canceled jobs release operation/response ownership", timeout: 1) { Fixture.liveJobs == 0 }
        print("PASS: all completed/canceled jobs deallocate after the 3,600-game pass")
        LibraryCoverCache.trimDisk(cap: LibraryCoverCache.diskCap)
        let coldFiles = try! FileManager.default.contentsOfDirectory(at: LibraryCoverCache.folder, includingPropertiesForKeys: [.fileSizeKey])
        let coldBytes = coldFiles.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        precondition(coldBytes <= LibraryCoverCache.diskCap, "realistic disk footprint respects cap")
        precondition((100..<3700).allSatisfy { FileManager.default.fileExists(atPath: LibraryCoverCache.diskURL("steam-\($0)").path) }, "evict derived copies before original posters")
        let stats = Fixture.diskStats
        precondition(stats.scans <= stats.written / (8 * 1024 * 1024) + 4, "trim scans follow bytes written, not cover count")
        print("PASS: cold disk \(coldBytes) bytes; \(stats.scans) trim scans for \(stats.written) bytes written; all 3,600 originals retained")
        let beforeDisk = Fixture.total
        cache.releaseMemory()
        let relaunched = LibraryCoverCache()
        Fixture.configure(offline: true)
        for end in stride(from: 3700, to: 100, by: -48) {
            let ids = Array(max(100, end - 48)..<end).reversed()
            for id in ids { _ = relaunched.image(for: librarySource(id), pixelWidth: 48) }
            await wait("offline disk window") { ids.allSatisfy { relaunched.image(for: librarySource($0), pixelWidth: 48)?.exact == true } }
        }
        precondition(Fixture.total == beforeDisk, "fresh cache instance must use disk offline")
        print("PASS: fresh cache instance, 3,600 reverse-order offline disk hits (90% blur variants), zero network requests")
        Fixture.configure(offline: false)

        // The last owner cancels, while dropping a card alone preserves its glow's shared request.
        Fixture.configure(held: true)
        let card = UUID(), glow = UUID()
        _ = cache.image(for: source(4000), pixelWidth: 192, demand: card)
        _ = cache.image(for: source(4000), pixelWidth: 96, demand: glow)
        await wait("shared request starts") { Fixture.count("/4000/first") == 1 }
        cache.releaseDemand(card)
        Fixture.release()
        await wait("remaining owner lands") { cache.image(for: source(4000), pixelWidth: 96, demand: glow)?.exact == true }
        precondition(Fixture.count("/4000/first") == 1, "releasing card must not cancel glow")
        cache.releaseDemand(glow)
        Fixture.configure(held: true)
        let leases = (4100..<4200).map { id -> UUID in
            let token = UUID(); _ = cache.image(for: source(id), pixelWidth: 96, demand: token); return token
        }
        await wait("scroll requests fill slots") { Fixture.total >= beforeDisk + 13 }
        for token in leases { cache.releaseDemand(token) }
        let current = UUID()
        _ = cache.image(for: source(4300), pixelWidth: 96, demand: current)
        await wait("newly visible request starts despite obsolete backlog", timeout: 1) { Fixture.count("/4300/first") == 1 }
        Fixture.release()
        await wait("current lands") { cache.image(for: source(4300), pixelWidth: 96, demand: current)?.exact == true }
        cache.releaseDemand(current)
        print("PASS: shared consumers survive reuse; releasing 100 obsolete demands frees slots for current demand")

        Fixture.configure(corruptFirst: true)
        let fallback = LibraryCoverCache.Source(key: "fallback", urls: [URL(string: "https://fixture.invalid/5000/first")!, URL(string: "https://fixture.invalid/5000/second")!])
        _ = cache.image(for: fallback, pixelWidth: 96)
        await wait("corrupt candidate falls back without leaking slot") { cache.image(for: fallback, pixelWidth: 96)?.exact == true }
        precondition(Fixture.count("/5000/second") == 1)
        Fixture.configure(corruptFirst: false)
        Fixture.configure(held: true)
        let cell = CellHarness()
        cell.content = .init(source: fallback)
        cell.refreshCover()
        await wait("disk fallback remains visible during preferred-candidate retry") { cell.refreshCover(); return cell.coverExact }
        let oldImage = cell.cover!.image!
        var refreshed = false
        let observation = LibraryCoverCache.shared.updates.sink { key in
            if key == fallback.key {
                cell.refreshCover(force: true)
                refreshed = cell.cover!.image !== oldImage
            }
        }
        Fixture.release()
        await wait("exact visible image refreshes after preferred candidate recovery") { refreshed }
        precondition((try? String(contentsOf: LibraryCoverCache.originURL(LibraryCoverCache.diskURL("fallback")), encoding: .utf8)) == fallback.urls[0].absoluteString)
        observation.cancel()
        LibraryCoverCache.shared.releaseDemand(cell.coverDemand)
        print("PASS: corrupt candidate fallback, preferred-candidate recovery, actual cell refresh replaces exact visible art")

        Fixture.configure(corruptFirst: true)
        Fixture.configure(holdSecond: true)
        let corruptOwners = (6000..<6012).map { id -> UUID in
            let token = UUID()
            let source = LibraryCoverCache.Source(key: "corrupt-\(id)", urls: [URL(string: "https://fixture.invalid/\(id)/first")!, URL(string: "https://fixture.invalid/\(id)/second")!])
            _ = cache.image(for: source, pixelWidth: 96, demand: token)
            return token
        }
        await wait("all corrupt candidates reach held fallback") { (6000..<6012).allSatisfy { Fixture.count("/\($0)/second") == 1 } }
        for token in corruptOwners { cache.releaseDemand(token) }
        Fixture.configure(corruptFirst: false)
        let visible = UUID()
        _ = cache.image(for: source(6200), pixelWidth: 96, demand: visible)
        await wait("releasing corrupt-response fallback frees all slots", timeout: 1) { Fixture.count("/6200/first") == 1 }
        Fixture.configure(holdSecond: false)
        Fixture.release()
        await wait("current poster after corrupt-response fallback") { cache.image(for: source(6200), pixelWidth: 96, demand: visible)?.exact == true }
        cache.releaseDemand(visible)
        print("PASS: corrupt-response fallback remains cancelable after its last consumer leaves")

        let shared = LibraryCoverCache.shared
        let glowSource = source(7000)
        _ = shared.image(for: source(7000, spot: true), pixelWidth: 192)
        await wait("glow stand-in prime") { shared.image(for: source(7000, spot: true), pixelWidth: 192)?.exact == true }
        try! FileManager.default.removeItem(at: LibraryCoverCache.diskURL(glowSource.key))
        Fixture.configure(held: true)
        let glowView = GlowHarness()
        let glowCard = LibraryGlowCard(key: "glow", frame: CGRect(x: 0, y: 0, width: 96, height: 144), seed: 0, dimmed: false,
                                      sourceKey: glowSource.key, card: glowSource)
        glowView.render(glowCard)
        await wait("glow initially builds stand-in") { glowView.hasTexture("glow") && Fixture.count("/7000/first") == 2 }
        precondition(!glowView.exact("glow"))
        glowView.leave()
        glowView.render(glowCard)
        await wait("glow re-entry restarts canceled exact request", timeout: 1) { Fixture.count("/7000/first") == 3 }
        Fixture.release()
        await wait("glow upgrades stand-in after re-entry") { glowView.render(glowCard); return glowView.exact("glow") }
        glowView.leave()
        print("PASS: actual glow prepare/release logic restarts an exact request after canceling a stand-in on departure")

        let artFolder = LibraryModel.documents.appendingPathComponent("madeira-art")
        try! FileManager.default.createDirectory(at: artFolder, withIntermediateDirectories: true)
        let localFile = artFolder.appendingPathComponent("chosen.jpg")
        try! Fixture.bytes.write(to: localFile)
        let localEntry = LibraryEntry(coverFile: "chosen.jpg")
        let local = LibraryCoverCache.Source.entry(localEntry)!
        let beforeLocal = Fixture.total
        precondition(cache.image(for: local, pixelWidth: 96) == nil, "a cold local file loads asynchronously")
        await wait("chosen file decodes") { cache.image(for: local, pixelWidth: 96)?.exact == true }
        let oldLocal = cache.image(for: local, pixelWidth: 96)!.image
        try! Fixture.bytes.write(to: localFile, options: .atomic)
        try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: localFile.path)
        LibraryCoverCache.Source.coverFileChanged(named: "chosen.jpg")
        let replaced = LibraryCoverCache.Source.entry(localEntry)!
        precondition(replaced.key != local.key, "replaced chosen file has a new cache key")
        await wait("replaced chosen file decodes") { cache.image(for: replaced, pixelWidth: 96)?.exact == true }
        precondition(cache.image(for: replaced, pixelWidth: 96)!.image !== oldLocal && Fixture.total == beforeLocal)
        print("PASS: cold chosen cover decodes asynchronously; replacement invalidation changes the key without network")

        LibraryCoverCache.trimDisk(cap: 1_000_000)
        let files = try! FileManager.default.contentsOfDirectory(at: LibraryCoverCache.folder, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        precondition(bytes <= 800_000, "disk trim must reach 80% of cap")
        precondition(files.filter { $0.pathExtension == "src" }.allSatisfy {
            FileManager.default.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("img").path)
        }, "trim removes image and candidate record together")
        print("PASS: disk LRU trim reaches target and removes candidate records with their images")
        // A larger/older library must not evict every recently used derived copy solely for being derived.
        // Sparse synthetic files test eviction order; no bitmap decoding or game data is involved here.
        let oldDate = Date().addingTimeInterval(-365 * 86_400)
        for id in 0..<3584 {
            let url = LibraryCoverCache.diskURL("old-\(id)")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let file = try! FileHandle(forWritingTo: url)
            try! file.truncate(atOffset: 80 * 1024)
            try! file.close()
            try! FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        }
        let recent = (0..<512).map { LibraryCoverCache.diskURL("recent-\($0)|spot") }
        for url in recent {
            try! Data(count: 80 * 1024).write(to: url)
        }
        LibraryCoverCache.trimDisk(cap: LibraryCoverCache.diskCap)
        precondition(recent.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "recent blur copies outlive year-old originals")
        print("PASS: 280 MiB of year-old originals do not evict recently used blur copies first")
        print("check-library-cover-cache: PASS (host cache behavior only; no device/FPS/thermal claims)")
    }
}
