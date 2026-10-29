// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContentKit

extension Zlib {
    /// GOG's metadata: zlib JSON, or plain JSON for some older entries.
    static func json(_ data: [UInt8], limit: Int = 64 << 20) throws -> [UInt8] {
        if let first = data.first, first == 0x7B || first == 0x5B { return data }
        return try decompress(data, limit: limit)
    }
}

/// GOG's endpoints and its desktop client's public identity (decision 0058).
public enum GOGAPI {
    public static let clientID = "46899977096215655"
    static let clientSecret = Secret("9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9")
    public static let redirect = "https://embed.gog.com/on_login_success?origin=client"
    public static let userAgent = "GOGGalaxyClient/2.0 Playport"

    /// The page the sign-in sheet opens.
    public static var loginURL: URL {
        var c = URLComponents(string: "https://auth.gog.com/auth")!
        c.queryItems = [.init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
                        .init(name: "response_type", value: "code"), .init(name: "layout", value: "client2")]
        return c.url!
    }

    /// The login code in the page the sheet lands on, or nil when it is not the redirect.
    public static func code(fromRedirect url: URL) -> Secret<String>? {
        guard url.host == "embed.gog.com", url.path == "/on_login_success",
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { return nil }
        return Secret(code)
    }

    static func tokenURL(_ grant: [URLQueryItem]) -> URL {
        var c = URLComponents(string: "https://auth.gog.com/token")!
        c.queryItems = [.init(name: "client_id", value: clientID), .init(name: "client_secret", value: clientSecret.value)] + grant
        return c.url!
    }
}

/// What a session keeps in the Keychain (one item, JSON): never logged.
struct GOGTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// GOG's account ID: kept for the library, shown nowhere.
    var userID: String?

    enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresAt, userID = "user_id" }
}

/// The GOG sign-in: the code from the login page traded for tokens, refreshed
/// before they expire, kept only in the store (the Keychain on the phone, under
/// its own service name; decision 0058). Sign-out deletes the item: GOG has no
/// revoke endpoint, so the refresh token expires by itself.
public actor GOGSession {
    public static let keychainService = "dev.playport.app.gog"
    static let key = "session"

    public enum State: Sendable, Equatable { case signedOut, signedIn }

    let store: any SecretStore
    let http: HTTPClient
    let log: Logger
    private var tokens: GOGTokens?
    private var loaded = false
    /// The clock; tests move it.
    var now: @Sendable () -> Date = { Date() }

    public init(store: any SecretStore, log: Logger) {
        self.store = store
        self.log = log
        http = HTTPClient(log: log, userAgent: GOGAPI.userAgent)
    }

    public var state: State {
        loadIfNeeded()
        return tokens == nil ? .signedOut : .signedIn
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let raw = try? store.read(Self.key), let t = try? JSONDecoder.gog.decode(GOGTokens.self, from: Data(raw.value)) {
            tokens = t
        }
    }

    /// Trades the login page's code for tokens and keeps them.
    public func signIn(code: Secret<String>) async throws {
        let t = try await fetch([.init(name: "grant_type", value: "authorization_code"), .init(name: "code", value: code.value),
                                 .init(name: "redirect_uri", value: GOGAPI.redirect)], label: "GOG sign-in")
        try keep(t)
        log.info("gog", "signed in")
    }

    /// A valid access token, refreshed first when it has under five minutes left.
    public func accessToken() async throws -> Secret<String> {
        loadIfNeeded()
        guard var t = tokens else { throw ClientError.notLoggedOn }
        if t.expiresAt.timeIntervalSince(now()) < 300 {
            do {
                t = try await fetch([.init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: t.refreshToken)],
                                    label: "GOG token refresh")
            } catch let ClientError.eresult(.accessDenied, context) {
                log.warn("gog", "refresh refused (\(context)): signed out")
                signOut()
                throw ClientError.notLoggedOn
            }
            try keep(t)
            log.info("gog", "token refreshed")
        }
        return Secret(t.accessToken)
    }

    /// Deletes the kept tokens (GOG has no revoke endpoint; the refresh token lapses).
    public func signOut() {
        try? store.delete(Self.key)
        tokens = nil
        loaded = true
    }

    /// The kept refresh token, for minting a game's own token (GalaxyService, decision
    /// 0063): read only, never refreshed or replaced by that grant.
    func hostRefreshToken() throws -> Secret<String>? {
        loadIfNeeded()
        return tokens.map { Secret($0.refreshToken) }
    }

    private func fetch(_ grant: [URLQueryItem], label: String) async throws -> GOGTokens {
        let body = try await http.get(GOGAPI.tokenURL(grant), maxBytes: 1 << 16, label: label)
        struct Reply: Decodable {
            var access_token: String
            var refresh_token: String
            var expires_in: Double?
            var user_id: String?
        }
        guard let r = try? JSONDecoder().decode(Reply.self, from: Data(body)) else {
            throw ClientError.protocolChanged("\(label): unexpected reply")
        }
        return GOGTokens(accessToken: r.access_token, refreshToken: r.refresh_token,
                         expiresAt: now().addingTimeInterval(r.expires_in ?? 3600), userID: r.user_id)
    }

    private func keep(_ t: GOGTokens) throws {
        try store.write(Self.key, Secret([UInt8](try JSONEncoder.gog.encode(t))))
        tokens = t
        loaded = true
    }

    /// A GET with the session's token.
    func authorized(_ url: URL, maxBytes: Int, label: String) async throws -> [UInt8] {
        let token = try await accessToken()
        return try await http.get(url, headers: ["Authorization": Secret("Bearer " + token.value)], maxBytes: maxBytes, label: label)
    }

    /// A GET without the token (the CDN's metadata).
    func plain(_ url: URL, maxBytes: Int, label: String) async throws -> [UInt8] {
        try await http.get(url, maxBytes: maxBytes, label: label)
    }
}

extension JSONDecoder {
    static let gog: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let gog: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
