// SPDX-License-Identifier: GPL-3.0-or-later
// Portions copyright the Playport authors (GOGGalaxyClient, from Playport 412de5f
// app/Packages/GOGClient GOGContent.swift; GalaxySecret and GalaxyLogger after its
// ContentKit Secret and Logger); GPL-3.0-or-later with the Madeira Converter
// Exception, version 1. Copyright 2026 Madeira contributors for the rest.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The few helpers the Galaxy service files (GalaxyWire, GalaxyService,
// GalaxyListener) need, so they build inside the app without Playport's
// ContentKit package.

/// A value that must never reach a log: tokens and the game's client secret.
struct GalaxySecret<Value: Sendable>: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: Value
    init(_ value: Value) { self.value = value }
    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
}

extension GalaxySecret: Equatable where Value: Equatable {}

/// The service's log: "[galaxy] ..." lines in Madeira's log. Messages name requests
/// and statuses only.
struct GalaxyLogger: Sendable {
    private let sink: @Sendable (String) -> Void

    init(sink: @escaping @Sendable (String) -> Void) { self.sink = sink }

    static let silent = GalaxyLogger { _ in }

    func info(_ category: String, _ message: @autoclosure () -> String) { sink("[\(category)] " + message()) }
    func warn(_ category: String, _ message: @autoclosure () -> String) { sink("[\(category)] warning: " + message()) }
}

enum GalaxyError: Error, Equatable, Sendable, CustomStringConvertible {
    case protocolChanged(String)
    /// GOG refused a request: its HTTP status.
    case eresult(Int, context: String)
    case notLoggedOn
    case unsafeContent(String)

    var description: String {
        switch self {
        case let .protocolChanged(s): return "protocol changed: \(s)"
        case let .eresult(status, context): return "\(context): HTTP \(status)"
        case .notLoggedOn: return "not signed in"
        case let .unsafeContent(s): return "unsafe content: \(s)"
        }
    }
}

/// A game's own Galaxy client identity, from its build manifest: what the Galaxy SDK
/// in the game sends to the local Galaxy service, and what the service checks it
/// against before minting the game's token. The secret is never logged.
struct GOGGalaxyClient: Codable, Equatable, Sendable {
    var clientID: String
    var clientSecret: GalaxySecret<String>

    init(clientID: String, clientSecret: GalaxySecret<String>) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// GOG's client IDs are decimal and its secrets hex: anything else (a missing or
    /// placeholder field) is no client.
    init?(id: String?, secret: String?) {
        guard let id, let secret, (1...24).contains(id.count), id.allSatisfy({ $0.isASCII && $0.isNumber }),
              (16...128).contains(secret.count), secret.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        self.init(clientID: id, clientSecret: GalaxySecret(secret))
    }

    enum CodingKeys: String, CodingKey { case clientID = "clientId", clientSecret }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try c.decode(String.self, forKey: .clientID)
        clientSecret = GalaxySecret(try c.decode(String.self, forKey: .clientSecret))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientID, forKey: .clientID)
        try c.encode(clientSecret.value, forKey: .clientSecret)
    }
}

/// The game-token requests' connection: ephemeral, no cookies or cache, 20 s.
enum GalaxyHTTPSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": GOGAPI.userAgent]
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()
}
