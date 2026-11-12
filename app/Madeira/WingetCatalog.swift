// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// The winget source on this device: the index in Caches/winget, refreshed from the CDN no more
/// often than the CDN allows (its max-age is 15 minutes), with the validators it gave. A package's
/// versions and manifest are fetched when its page opens and checked against the hashes that pin them.
@MainActor final class WingetCatalog: ObservableObject {
    static let shared = WingetCatalog()
    enum State: Equatable { case idle, loading, ready, failed(String) }
    @Published private(set) var state = State.idle
    @Published private(set) var count = 0
    private var index: WingetIndex?
    private var checked = Date.distantPast
    private var loading = false

    nonisolated static let base = URL(string: "https://cdn.winget.microsoft.com/cache/")!
    private nonisolated static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("winget", isDirectory: true)
    private nonisolated static var indexFile: URL { folder.appendingPathComponent("index.db") }
    private nonisolated static var validatorFile: URL { folder.appendingPathComponent("validators.txt") }

    /// Opens the index on disk at once, then asks the CDN whether it changed.
    func load(force: Bool = false) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        if index == nil, let opened = WingetIndex(path: Self.indexFile.path) { index = opened; count = opened.count; state = .ready }
        if index == nil { state = .loading }
        guard force || Date().timeIntervalSince(checked) > 900 else { return }
        do {
            if let fresh = try await Self.refresh() { index = fresh; count = fresh.count }
            checked = Date(); state = .ready
        } catch {
            LogStore.shared.log("[winget] index refresh failed: \(error.localizedDescription)")
            if index == nil { state = .failed(error.localizedDescription) }
        }
    }

    /// nil when the CDN's copy is the one on disk.
    private nonisolated static func refresh() async throws -> WingetIndex? {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var request = URLRequest(url: base.appendingPathComponent("source2.msix"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        if fm.fileExists(atPath: indexFile.path), let saved = try? String(contentsOf: validatorFile, encoding: .utf8) {
            let lines = saved.components(separatedBy: "\n")
            if let tag = lines.first, !tag.isEmpty { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
            if lines.count > 1, !lines[1].isEmpty { request.setValue(lines[1], forHTTPHeaderField: "If-Modified-Since") }
        }
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? fm.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else { throw WingetError.network("no response") }
        if http.statusCode == 304 { return nil }
        guard http.statusCode == 200 else { throw WingetError.network("HTTP \(http.statusCode)") }
        let staging = folder.appendingPathComponent("staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        guard try ItchArchive.unpackAny(file, to: staging) != nil else { throw WingetError.index }
        let db = staging.appendingPathComponent("Public/index.db")
        guard let fresh = WingetIndex(path: db.path) else { throw WingetError.index }
        _ = try? fm.replaceItemAt(indexFile, withItemAt: db)
        if !fm.fileExists(atPath: indexFile.path) { try fm.moveItem(at: db, to: indexFile) }
        let tag = http.value(forHTTPHeaderField: "ETag") ?? "", modified = http.value(forHTTPHeaderField: "Last-Modified") ?? ""
        try? (tag + "\n" + modified).write(to: validatorFile, atomically: true, encoding: .utf8)
        // `fresh` was opened on the staging copy, which is about to go: reopen the one in place.
        return WingetIndex(path: indexFile.path) ?? fresh
    }

    func search(_ text: String, limit: Int = 40) async -> [WingetPackage] {
        guard let index else { return [] }
        return await Task.detached(priority: .userInitiated) { index.search(text, limit: limit) }.value
    }

    func package(id: String) -> WingetPackage? { index?.package(id: id) }

    /// The newest version's manifest, each file checked against the hash that pins it.
    nonisolated static func manifest(for package: WingetPackage) async throws -> WingetManifest {
        let versionData = try await fetch(base.appendingPathComponent("packages/\(package.id)/\(package.hash.prefix(8))/versionData.mszyml"))
        guard wingetSHA256Hex(versionData) == package.hash else { throw WingetError.mismatch("version list") }
        guard let versions = WingetVersionData.decode(versionData), let newest = versions.first(where: { $0.version == package.latest }) ?? versions.first
        else { throw WingetError.index }
        let manifestData = try await fetch(base.appendingPathComponent(newest.path))
        guard wingetSHA256Hex(manifestData) == newest.sha256 else { throw WingetError.mismatch("manifest") }
        guard let text = String(data: manifestData, encoding: .utf8), let manifest = WingetManifest.parse(text) else { throw WingetError.index }
        return manifest
    }

    /// One retry: the CDN now and then closes a connection.
    private nonisolated static func fetch(_ url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw WingetError.network("not https") }
        var last: Error = WingetError.network("no response")
        for _ in 0..<2 {
            do {
                var request = URLRequest(url: url); request.timeoutInterval = 30
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 { return data }
                last = WingetError.network("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            } catch { last = error }
        }
        throw last
    }
}
