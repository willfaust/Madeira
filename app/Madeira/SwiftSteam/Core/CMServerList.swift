// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).
// Endpoint exclusion adapted from kuscholar/iDeck; see docs/STEAM_LIBRARY.md.

import Foundation

/// Discovers and manages Steam CM (Connection Manager) WebSocket endpoints.
actor CMServerList {
    /// A CM server endpoint (WebSocket)
    struct CMServer: Codable, Sendable {
        let host: String
        let port: UInt16
        var lastAttempt: Date?
        var failCount: Int = 0

        var isHealthy: Bool { failCount < 3 }

        var endpoint: String { "\(host):\(port)" }

        var url: URL { URL(string: "wss://\(host):\(port)/cmsocket/")! }
    }

    private var servers: [CMServer] = []
    private var lastFetched: Date?
    private let cacheKey = "swiftsteam_cm_servers_websocket"
    private let staleInterval: TimeInterval = 3600

    // MARK: - Public API

    /// Get the best available CM server to connect to
    func getServer(excluding: Set<String> = []) async throws -> CMServer {
        if servers.isEmpty || isListStale {
            try await refreshServerList()
        }

        let available = servers.filter { !excluding.contains($0.endpoint) }
        guard !available.isEmpty else { throw SteamError.noServersAvailable }
        guard let server = available
            .filter({ $0.isHealthy })
            .sorted(by: { ($0.lastAttempt ?? .distantPast) < ($1.lastAttempt ?? .distantPast) })
            .first
        else {
            for i in servers.indices where !excluding.contains(servers[i].endpoint) {
                servers[i].failCount = 0
            }
            guard let server = servers.first(where: { !excluding.contains($0.endpoint) }) else {
                throw SteamError.noServersAvailable
            }
            return server
        }

        return server
    }

    func markFailed(endpoint: String) {
        if let index = servers.firstIndex(where: { $0.endpoint == endpoint }) {
            servers[index].failCount += 1
            servers[index].lastAttempt = Date()
        }
    }

    func markSuccess(endpoint: String) {
        if let index = servers.firstIndex(where: { $0.endpoint == endpoint }) {
            servers[index].failCount = 0
            servers[index].lastAttempt = Date()
        }
    }

    func refreshServerList() async throws {
        let freshServers = try await fetchServerList()
        guard !freshServers.isEmpty else {
            throw SteamError.noServersAvailable
        }
        servers = freshServers
        lastFetched = Date()
        cacheServerList()
    }

    // MARK: - Private

    private var isListStale: Bool {
        guard let lastFetched else { return true }
        return Date().timeIntervalSince(lastFetched) > staleInterval
    }

    /// Fetch WebSocket CM server list from Steam Web API
    private func fetchServerList() async throws -> [CMServer] {
        let urlString = "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0&cmtype=websockets"
        guard let url = URL(string: urlString) else {
            throw SteamError.connectionFailed("Invalid CM directory URL")
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            if let cached = loadCachedServers(), !cached.isEmpty {
                SteamLog.trace("CM directory unavailable, using cached servers")
                return cached
            }
            throw SteamError.connectionFailed("CM directory returned non-200 status")
        }

        // Response format: { "response": { "serverlist": [ { "endpoint": "host:port", ... }, ... ] } }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serverResponse = json["response"] as? [String: Any],
              let serverList = serverResponse["serverlist"] as? [[String: Any]] else {
            throw SteamError.connectionFailed("Invalid CM directory response format")
        }

        // Each entry has an "endpoint" field: "hostname:port"
        let servers = serverList.compactMap { entry -> CMServer? in
            guard let endpoint = entry["endpoint"] as? String else { return nil }
            let parts = endpoint.split(separator: ":")
            guard parts.count == 2,
                  let port = UInt16(parts[1]) else { return nil }
            return CMServer(host: String(parts[0]), port: port)
        }

        SteamLog.trace("Fetched \(servers.count) WebSocket CM servers")
        return servers
    }

    // MARK: - Caching

    private func cacheServerList() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    private func loadCachedServers() -> [CMServer]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode([CMServer].self, from: data) else {
            return nil
        }
        return cached
    }
}
