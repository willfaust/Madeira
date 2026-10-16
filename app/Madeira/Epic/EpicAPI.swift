// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Epic Games library: the owned-games list via the library-service API —
// the same endpoint Legendary's get_library_items uses — with cursor
// pagination. DLC and the Unreal Engine itself are filtered out.

import Foundation
import Combine

struct EpicGame: Identifiable, Codable {
    var appName: String
    var title: String
    var namespace: String
    var catalogItemId: String?
    var artworkURL: URL?
    /// Wide art for the library's hero and the game's page (optional: older caches lack it).
    var heroURL: URL?

    var id: String { appName }
}

private struct EpicLibraryResponse: Codable {
    var records: [EpicLibraryRecord]?
    var responseMetadata: EpicResponseMetadata?
}

private struct EpicResponseMetadata: Codable {
    var nextCursor: String?
}

private struct EpicLibraryRecord: Codable {
    var appName: String?
    var title: String?
    var namespace: String?
    var catalogItemId: String?
    var metadata: EpicRecordMetadata?
}

/// A catalog item: the title and art the library records usually lack.
private struct EpicCatalogItem: Codable {
    var title: String?
    var keyImages: [EpicKeyImage]?
    var mainGameItem: EpicMainGameItem?
    var categories: [EpicCategory]?
}

private struct EpicCategory: Codable {
    var path: String?
}

private struct EpicRecordMetadata: Codable {
    var keyImages: [EpicKeyImage]?
    var mainGameItem: EpicMainGameItem?
}

private struct EpicKeyImage: Codable {
    var type: String?
    var url: String?
}

private struct EpicMainGameItem: Codable {
    var id: String?
}

final class EpicLibrary: ObservableObject {
    static let shared = EpicLibrary()

    @Published private(set) var games: [EpicGame] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    private let host = "library-service.live.use1a.on.epicgames.com"
    private let userAgent = "UELauncher/11.0.1-14907503+++Portal+Release-Live Windows/10.0.19041.1.256.64bit"
    /// Preferred artwork, tallest box art first.
    private let artworkPreference = ["DieselGameBoxTall", "DieselGameBox", "Thumbnail",
                                     "DieselStoreFrontTall", "DieselStoreFrontWide"]

    /// Wide artwork, store front first.
    private let heroPreference = ["DieselStoreFrontWide", "OfferImageWide", "DieselGameBox",
                                  "Thumbnail", "DieselGameBoxTall"]

    /// The last fetched list, kept on disk so the library shows the account's games
    /// at once, before (or without) the network.
    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epic-library.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder().decode([EpicGame].self, from: data) {
            games = cached
        }
    }

    private static func store(_ games: [EpicGame]) {
        guard let data = try? JSONEncoder().encode(games) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private var lastRefresh: Date?

    /// The library's quiet refresh: when signed in, at most every 10 minutes.
    func refreshIfStale() {
        guard EpicAuth.shared.signedIn else { return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < 600 { return }
        refresh()
    }

    func clear() {
        games = []
        error = nil
        lastRefresh = nil
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        lastRefresh = Date()
        error = nil
        Task {
            do {
                let token = try await EpicAuth.shared.validAccessToken()
                let games = try await fetchAll(token: token)
                Self.store(games)
                await MainActor.run {
                    self.games = games
                    self.isLoading = false
                }
            } catch {
                LogStore.shared.log("[epic-library] refresh failed: \(error)", level: .error)
                await MainActor.run {
                    self.error = (error as? EpicAuthError)?.message ?? error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func fetchAll(token: String) async throws -> [EpicGame] {
        var records: [EpicLibraryRecord] = []
        var cursor: String? = nil
        repeat {
            let (page, next) = try await fetchPage(token: token, cursor: cursor)
            records.append(contentsOf: page)
            cursor = next
        } while cursor != nil

        // The library service mostly returns ids only (appName, namespace,
        // catalogItemId): the title, art and DLC flag live in Epic's catalog, which
        // is what Legendary's get_game_info reads. Look up every record missing them.
        var wanted: [String: Set<String>] = [:]
        for record in records where (record.title ?? "").isEmpty || record.metadata?.keyImages == nil {
            if let ns = record.namespace, let id = record.catalogItemId, ns != "ue" { wanted[ns, default: []].insert(id) }
        }
        let catalog = await fetchCatalog(token: token, wanted: wanted)
        // Mobile-store copies (Epic Games Store on iOS/Android) are library records too,
        // with no Windows build. Like Legendary, keep only games in the Windows asset
        // list; if that list fails to load, keep everything.
        let windows = await fetchWindowsAssets(token: token)

        var games: [EpicGame] = []
        for record in records {
            guard let appName = record.appName, !appName.isEmpty, record.namespace != "ue" else { continue }
            if let windows, !windows.contains("\(record.namespace ?? "")/\(record.catalogItemId ?? "")") { continue }
            let item = record.catalogItemId.flatMap { catalog[$0] }
            let title = (record.title?.isEmpty == false ? record.title : item?.title) ?? ""
            guard !title.isEmpty else { continue }
            // DLC rides on a main game item, and add-ons are filed under addons.
            if record.metadata?.mainGameItem != nil || item?.mainGameItem != nil { continue }
            if item?.categories?.contains(where: { ($0.path ?? "").hasPrefix("addons") }) == true { continue }
            let images = record.metadata?.keyImages ?? item?.keyImages
            games.append(EpicGame(
                appName: appName,
                title: title,
                namespace: record.namespace ?? "",
                catalogItemId: record.catalogItemId,
                artworkURL: Self.artwork(from: images, preferring: artworkPreference),
                heroURL: Self.artwork(from: images, preferring: heroPreference)
            ))
        }
        LogStore.shared.log("[epic-library] records=\(records.count) windows-assets=\(windows.map { String($0.count) } ?? "unavailable") catalog-lookups=\(wanted.values.reduce(0) { $0 + $1.count }) found=\(catalog.count) games=\(games.count)")
        // The library lists a game once per entitlement; keep one per title.
        return games.reduce(into: [EpicGame]()) { kept, game in
            if !kept.contains(where: { $0.title == game.title }) { kept.append(game) }
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Catalog items by id, eight namespaces at a time. A namespace that fails is
    /// skipped: its games just stay out until the next refresh.
    private func fetchCatalog(token: String, wanted: [String: Set<String>]) async -> [String: EpicCatalogItem] {
        var result: [String: EpicCatalogItem] = [:]
        let namespaces = Array(wanted.keys)
        var index = 0
        while index < namespaces.count {
            let batch = namespaces[index..<min(index + 8, namespaces.count)]
            index += 8
            await withTaskGroup(of: [String: EpicCatalogItem].self) { group in
                for ns in batch {
                    let ids = Array(wanted[ns] ?? [])
                    group.addTask { (try? await self.fetchCatalogItems(token: token, namespace: ns, ids: ids)) ?? [:] }
                }
                for await items in group { result.merge(items) { a, _ in a } }
            }
        }
        return result
    }

    private func fetchCatalogItems(token: String, namespace: String, ids: [String]) async throws -> [String: EpicCatalogItem] {
        var components = URLComponents(string: "https://catalog-public-service-prod06.ol.epicgames.com/catalog/api/shared/namespace/\(namespace)/bulk/items")!
        components.queryItems = [URLQueryItem(name: "id", value: ids.joined(separator: ",")),
                                 URLQueryItem(name: "includeDLCDetails", value: "true"),
                                 URLQueryItem(name: "includeMainGameDetails", value: "true"),
                                 URLQueryItem(name: "country", value: "US"),
                                 URLQueryItem(name: "locale", value: "en-US")]
        var request = URLRequest(url: components.url!)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EpicAuthError.network }
        return try JSONDecoder().decode([String: EpicCatalogItem].self, from: data)
    }

    private static func artwork(from images: [EpicKeyImage]?, preferring order: [String]) -> URL? {
        guard let images = images else { return nil }
        for type in order {
            if let urlString = images.first(where: { $0.type == type })?.url,
               !urlString.isEmpty, let url = URL(string: urlString) {
                return url
            }
        }
        return nil
    }

    /// "namespace/catalogItemId" for every game the account can install on Windows.
    private func fetchWindowsAssets(token: String) async -> Set<String>? {
        var components = URLComponents(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/public/assets/Windows")!
        components.queryItems = [URLQueryItem(name: "label", value: "Live")]
        var request = URLRequest(url: components.url!)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let assets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        let keys = Set(assets.compactMap { asset -> String? in
            guard let ns = asset["namespace"] as? String, let id = asset["catalogItemId"] as? String else { return nil }
            return "\(ns)/\(id)"
        })
        return keys.isEmpty ? nil : keys
    }

    private func fetchPage(token: String, cursor: String?) async throws -> ([EpicLibraryRecord], String?) {
        var components = URLComponents(string: "https://\(host)/library/api/public/items")!
        var items = [URLQueryItem(name: "includeMetadata", value: "true")]
        if let cursor = cursor {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EpicAuthError.network }
        let decoded = try JSONDecoder().decode(EpicLibraryResponse.self, from: data)
        return (decoded.records ?? [], decoded.responseMetadata?.nextCursor)
    }
}
