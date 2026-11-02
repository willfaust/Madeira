// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Security

// EA's account and game services (docs/EA.md): the same HTTPS endpoints the EA
// app uses, and that Maxima (GPL-3.0) documents for Linux. Sign-in is EA's own
// login page, asked for the EA app's client with a PKCE challenge and a signed
// machine description; it ends on the EA app's private page address
// (qrc:///html/login_successful.html) with a one-use code, which is traded for an
// access and refresh token. The tokens live in one Keychain item; nothing else
// stores them. Log lines name methods and HTTP statuses only, never a token, code,
// name or account id.

/// The signed-in account, as stored in the Keychain.
struct EASession: Codable, Sendable {
    var userID: String
    var personaID: String
    var displayName: String
    var accessToken: String
    var accessExpires: Date
    var refreshToken: String
}

enum EAAPIError: LocalizedError, Equatable {
    case signedOut
    case http(Int)
    case graphQL(String)
    case invalid(String)
    case noBuild
    case noLauncher
    case license(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to EA to continue."
        case .http(let status):
            if status == 401 || status == 403 { return "EA refused the request (HTTP \(status)). Sign in again in Settings › EA app." }
            return "EA's server answered with HTTP \(status). Try again later."
        case .graphQL(let message): return "EA's server declined the request: \(message)"
        case .invalid(let what): return "EA sent an unexpected answer (\(what))."
        case .noBuild: return "EA has no PC build of this game for Madeira to download."
        case .noLauncher: return "The game's files downloaded, but they do not say which program starts the game (__Installer/installerdata.xml). Add the game with + and choose its .exe."
        case .license(let reason): return "EA did not give this game a licence (\(reason)). Check that your account owns it and try again."
        }
    }

    /// Short and credential-free, for the log.
    var reason: String {
        switch self {
        case .signedOut: return "signed-out"
        case .http(let status): return "http-\(status)"
        case .graphQL: return "graphql"
        case .invalid(let what): return "invalid-\(what)"
        case .noBuild: return "no-build"
        case .noLauncher: return "no-launcher"
        case .license(let reason): return "license-\(reason)"
        }
    }
}

/// One game the account owns (its base game offer).
struct EAOwnedGame: Codable, Identifiable, Hashable, Sendable {
    /// The offer id, `Origin.OFR.50.0001234`.
    var id: String
    var title: String
    var slug: String
    var downloadable: Bool
    /// The content id a licence names; from the catalog, else the build's manifest.
    var contentID: String?
    /// Where the catalog installs it (`Mass Effect Legendary Edition`), when it says.
    var installFolder: String?
    /// The program the catalog names when the manifest has none.
    var executePath: String?
    var multiplayerID: String?
    var cover: URL?
    var wide: URL?
}

/// One downloadable build of a game.
struct EABuild: Sendable, Equatable {
    var buildID: String
    var version: String
    /// "Live" for the current build, "Staged" for one not released yet.
    var type: String
    var liveDate: String?
}

/// The Keychain item holding the account, for this device only.
enum EATokenStore {
    private static let service = "madeira.ea.tokens"
    private static let account = "session"

    static func load() -> EASession? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(EASession.self, from: data)
    }

    @discardableResult static func save(_ session: EASession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                         kSecAttrSynchronizable as String: false]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// The machine EA sees: the values Madeira's Wine reports to a game (EAFormats.swift),
/// with the ones that change from device to device filled in once and kept, and any of
/// them replaced by Documents/madeira-ea-hardware.json.
enum EAHardware {
    private static var overridesURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("madeira-ea-hardware.json")
    }

    /// The profile for a game: its graphics card choice and AVX switch, as Madeira's Wine
    /// and FEX will report them, then the overrides file.
    static func profile(drive: URL, gpuVendor: UInt16, gpuDevice: UInt16, avx: Bool) -> EAHardwareProfile {
        var profile = EAHardwareProfile()
        if let created = (try? drive.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
            profile.osInstallDate = EAHardwareProfile.wmiDate(created)
        }
        profile.gpuPNPDeviceID = String(format: "PCI\\VEN_%04X&DEV_%04X&SUBSYS_00000000&REV_00\\00000000", gpuVendor, gpuDevice)
        profile.cpuECX = EAHardwareProfile.cpuECX(avx: avx)
        if let url = overridesURL, let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var dictionary = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))) as? [String: Any] ?? [:]
            for (key, value) in json where dictionary[key] != nil { dictionary[key] = value }
            if let merged = try? JSONSerialization.data(withJSONObject: dictionary),
               let decoded = try? JSONDecoder().decode(EAHardwareProfile.self, from: merged) {
                profile = decoded
            }
        }
        return profile
    }
}

final class EAAPI: @unchecked Sendable {
    static let shared = EAAPI()

    // The EA app's own client. EA's sign-in only accepts its fixed redirect, the
    // EA app's private page qrc:///html/login_successful.html.
    static let clientID = "JUNO_PC_CLIENT"
    private static let clientSecret = "4mRLtYMb6vq9qglomWEaT4ChxsXWcyqbQpuBNfMPOYOiDmYYQmjuaBsF2Zp0RyVeWkfqhE9TuGgAw7te"
    static let redirect = "qrc:///html/login_successful.html"
    static let userAgent = "Madeira (EA client)"
    private static let accounts = "https://accounts.ea.com/connect"
    private static let serviceLayer = "https://service-aggregation-layer.juno.ea.com/graphql"
    static let licenses = "https://proxy.novafusion.ea.com/licenses"

    private let http: URLSession
    private var session: EASession?
    private var loaded = false
    private var refreshing: Task<EASession, Error>?
    /// The sign-in's PKCE verifier, from the login address until the code is traded.
    private var codeVerifier: String?
    private let lock = NSLock()

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        http = URLSession(configuration: config)
    }

    private func stored() -> EASession? {
        lock.lock(); defer { lock.unlock() }
        if !loaded { session = EATokenStore.load(); loaded = true }
        return session
    }

    private func store(_ session: EASession?) {
        lock.lock(); defer { lock.unlock() }
        self.session = session; loaded = true
        if let session { EATokenStore.save(session) } else { EATokenStore.delete() }
    }

    /// The stored account, if any, without contacting EA.
    func account() -> EASession? { stored() }

    // MARK: Sign-in

    /// EA's login page for the EA app's client: a fresh PKCE challenge and this device's
    /// signed description. The verifier is kept for `signIn(authorizationCode:)`.
    func loginURL(profile: EAHardwareProfile) -> URL {
        var verifierBytes = [UInt8](repeating: 0, count: 32)
        for index in verifierBytes.indices { verifierBytes[index] = UInt8.random(in: 0...255) }
        let verifier = EAPCSign.base64url(Data(verifierBytes))
        lock.lock(); codeVerifier = verifier; lock.unlock()
        let challenge = EAPCSign.base64url(EADigest.sha256(Data(verifier.utf8)))
        var components = URLComponents(string: Self.accounts + "/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "sbiod_enabled", value: "false"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "locale", value: "en_US"),
            URLQueryItem(name: "pc_sign", value: EAPCSign.value(profile: profile, keyVersion: Bool.random() ? "v1" : "v2")),
            URLQueryItem(name: "nonce", value: String(Int32.random(in: Int32.min...Int32.max))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        return Self.encodingValues(components)
    }

    /// The one-use code in the address EA's login ends on, or nil.
    static func authorizationCode(in text: String) -> String? {
        guard let query = text.range(of: "?").map({ text[$0.upperBound...] }) else { return nil }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == "code", !parts[1].isEmpty { return parts[1].removingPercentEncoding ?? parts[1] }
        }
        return nil
    }

    /// Whether an address is the EA app's end-of-login page (its private scheme, or the
    /// same page's name should EA ever serve it over HTTPS).
    static func isRedirectPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme?.lowercased() == "qrc" { return true }
        return url.path.hasSuffix("/login_successful.html")
    }

    func signIn(authorizationCode code: String) async throws -> EASession {
        lock.lock(); let verifier = codeVerifier; lock.unlock()
        guard let verifier else { throw EAAPIError.invalid("no-login-started") }
        let json = try await token(["grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                                    "redirect_uri": Self.redirect, "token_format": "JWS"], method: "oauth-code")
        var session = try Self.session(from: json, previous: nil)
        let info = try await tokenInfo(session.accessToken)
        session.userID = info.userID
        session.personaID = info.personaID ?? ""
        store(session)
        if let player = try? await player() {
            session.displayName = player.displayName
            if session.personaID.isEmpty { session.personaID = player.personaID }
            store(session)
        }
        EALog.event("[ea-signin] signed in")
        return session
    }

    func signOut() {
        lock.lock(); refreshing?.cancel(); refreshing = nil; lock.unlock()
        store(nil)
        EALog.event("[ea-signin] signed out")
    }

    /// A session whose access token is good for at least five more minutes.
    func validSession() async throws -> EASession {
        guard let current = stored() else { throw EAAPIError.signedOut }
        if current.accessExpires.timeIntervalSinceNow > 300 { return current }
        lock.lock()
        if let refreshing { lock.unlock(); return try await refreshing.value }
        let task = Task { () throws -> EASession in
            let json = try await self.token(["grant_type": "refresh_token", "refresh_token": current.refreshToken], method: "oauth-refresh")
            let session = try Self.session(from: json, previous: current)
            self.store(session)
            return session
        }
        refreshing = task
        lock.unlock()
        defer { lock.lock(); refreshing = nil; lock.unlock() }
        do {
            return try await task.value
        } catch EAAPIError.http(let status) where status == 400 || status == 401 || status == 403 {
            // A refresh token EA no longer accepts: the account must sign in again.
            signOut(); throw EAAPIError.signedOut
        }
    }

    private static func session(from json: [String: Any], previous: EASession?) throws -> EASession {
        guard let access = json["access_token"] as? String else { throw EAAPIError.invalid("token") }
        guard let refresh = (json["refresh_token"] as? String) ?? previous?.refreshToken else { throw EAAPIError.invalid("refresh-token") }
        let expires = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return EASession(userID: previous?.userID ?? "", personaID: previous?.personaID ?? "", displayName: previous?.displayName ?? "",
                         accessToken: access, accessExpires: Date().addingTimeInterval(expires), refreshToken: refresh)
    }

    private func token(_ parameters: [String: String], method: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: Self.accounts + "/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = parameters
        all["client_id"] = Self.clientID
        all["client_secret"] = Self.clientSecret
        request.httpBody = Data(Self.form(all).utf8)
        return try await object(request, method: method)
    }

    struct TokenInfo { var userID: String; var personaID: String? }

    private func tokenInfo(_ accessToken: String) async throws -> TokenInfo {
        var components = URLComponents(string: Self.accounts + "/tokeninfo")!
        components.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
        let json = try await object(URLRequest(url: Self.encodingValues(components)), method: "tokeninfo")
        guard let user = Self.string(json["user_id"]) else { throw EAAPIError.invalid("tokeninfo") }
        return TokenInfo(userID: user, personaID: Self.string(json["persona_id"]))
    }

    /// A short-lived token or code for another EA client, from the account's access token:
    /// what a game asks the local service for (GetAuthCode), and the opaque token the
    /// game's launch takes. EA answers with a redirect whose address carries it.
    func exchange(clientID: String, responseType: String, scopes: [String] = [], tokenFormat: String? = nil, expiresIn: Int? = nil,
                  profile: EAHardwareProfile) async throws -> String {
        let session = try await validSession()
        var components = URLComponents(string: Self.accounts + "/auth")!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "sbiod_enabled", value: "false"),
            URLQueryItem(name: "response_type", value: responseType),
            URLQueryItem(name: "locale", value: "en_US"),
            URLQueryItem(name: "pc_sign", value: EAPCSign.value(profile: profile, keyVersion: Bool.random() ? "v1" : "v2")),
            URLQueryItem(name: "nonce", value: String(Int32.random(in: Int32.min...Int32.max))),
        ]
        if !scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " "))) }
        items.append(URLQueryItem(name: "access_token", value: session.accessToken))
        if let tokenFormat { items.append(URLQueryItem(name: "token_format", value: tokenFormat)) }
        if let expiresIn { items.append(URLQueryItem(name: "expires_in", value: String(expiresIn))) }
        components.queryItems = items
        let location = try await redirectLocation(URLRequest(url: Self.encodingValues(components)), method: "auth-exchange")
        guard !location.hasPrefix("https://signin.ea.com") else { throw EAAPIError.invalid("exchange-signin") }
        // The EA app's private scheme: the values may sit in the fragment.
        let text = location.replacingOccurrences(of: "qrc:/html", with: "http://127.0.0.1").replacingOccurrences(of: "#", with: "?")
        let key = responseType == "token" ? "access_token" : responseType
        guard let url = URL(string: text), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == key })?.value, !value.isEmpty else {
            throw EAAPIError.invalid("exchange-\(responseType)")
        }
        return value
    }

    // MARK: Requests

    /// The URL with every query value fully percent-encoded (URLComponents leaves
    /// "?", "=", ":" and "/" as they are).
    private static func encodingValues(_ components: URLComponents) -> URL {
        var copy = components
        copy.percentEncodedQuery = form(Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }),
                                        ordered: (components.queryItems ?? []).map(\.name))
        return copy.url!
    }

    private static func form(_ values: [String: String], ordered: [String]? = nil) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let keys = ordered ?? values.keys.sorted()
        return keys.map { key in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\((values[key] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    private func authorized(_ request: URLRequest) async throws -> URLRequest {
        let session = try await validSession()
        var request = request
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest, method: String) async throws -> Data {
        let (data, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            EALog.event("[ea-api] \(method) failed reason=http-\(status)")
            throw EAAPIError.http(status)
        }
        return data
    }

    private func object(_ request: URLRequest, method: String) async throws -> [String: Any] {
        let data = try await send(request, method: method)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EAAPIError.invalid(method) }
        return json
    }

    /// The Location of a redirect answer, without following it.
    private func redirectLocation(_ request: URLRequest, method: String) async throws -> String {
        let (_, response) = try await http.data(for: request, delegate: NoRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw EAAPIError.invalid(method) }
        guard (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location") else {
            EALog.event("[ea-api] \(method) failed reason=http-\(http.statusCode)")
            throw http.statusCode >= 400 ? EAAPIError.http(http.statusCode) : EAAPIError.invalid(method)
        }
        return location
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        static let shared = NoRedirects()
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    // MARK: GraphQL

    /// One query to EA's service aggregation layer; the `data` object of its answer.
    func graphQL(_ operation: String, query: String, variables: [String: Any], method: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: Self.serviceLayer)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["operationName": operation, "query": query, "variables": variables])
        let json = try await object(try await authorized(request), method: method)
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
            let message = (first["message"] as? String) ?? "unknown error"
            EALog.event("[ea-api] \(method) failed reason=graphql")
            throw EAAPIError.graphQL(message)
        }
        guard let data = json["data"] as? [String: Any] else { throw EAAPIError.invalid(method) }
        return data
    }

    // MARK: Account

    struct Player { var displayName: String; var personaID: String }

    func player() async throws -> Player {
        let query = """
        query MadeiraUserPlayer { me { pd player { pd psd displayName uniqueName } } }
        """
        let data = try await graphQL("MadeiraUserPlayer", query: query, variables: [:], method: "user-player")
        guard let me = data["me"] as? [String: Any], let player = me["player"] as? [String: Any] else { throw EAAPIError.invalid("user-player") }
        let name = (player["displayName"] as? String) ?? (player["uniqueName"] as? String) ?? ""
        return Player(displayName: name, personaID: Self.string(player["psd"]) ?? "")
    }

    // MARK: Library

    /// The account's PC games (base games only, every page), with what the catalog says
    /// about installing and starting each.
    func ownedGames() async throws -> [EAOwnedGame] {
        let query = """
        query MadeiraOwnedGames($next: String, $limit: Int) {
          me {
            ownedGameProducts(storefronts: [EA], locale: "en", paging: {limit: $limit, next: $next}, productFound: true,
                              orderBy: {field: NAME, direction: ASC}, type: [DIGITAL_FULL_GAME, PACKAGED_FULL_GAME],
                              downloadableOnly: false, entitlementEnabled: true, platforms: [PC]) {
              next
              items {
                originOfferId
                product {
                  id name downloadable gameSlug
                  trialDetails { trialType }
                  baseItem(availabilities: [VISIBLE]) { title id baseGameSlug gameType }
                  gameProductUser(storefronts: [EA]) { status gameProductUserTrial { trialTimeRemainingSeconds } }
                }
              }
            }
          }
        }
        """
        var games: [EAOwnedGame] = []
        var next: String?
        var pages = 0
        repeat {
            var variables: [String: Any] = ["limit": 100]
            if let next { variables["next"] = next }
            let data = try await graphQL("MadeiraOwnedGames", query: query, variables: variables, method: "owned-games")
            guard let me = data["me"] as? [String: Any], let page = me["ownedGameProducts"] as? [String: Any],
                  let items = page["items"] as? [[String: Any]] else { throw EAAPIError.invalid("owned-games") }
            for item in items {
                guard let offer = item["originOfferId"] as? String, let product = item["product"] as? [String: Any] else { continue }
                let base = product["baseItem"] as? [String: Any]
                // Only full base games: not DLC, not a trial.
                guard (base?["gameType"] as? String) == "BASE_GAME" else { continue }
                if let trial = product["trialDetails"] as? [String: Any], trial["trialType"] != nil, !(trial["trialType"] is NSNull) { continue }
                let user = product["gameProductUser"] as? [String: Any]
                if let userTrial = user?["gameProductUserTrial"], !(userTrial is NSNull) { continue }
                let title = ((base?["title"] as? String) ?? (product["name"] as? String) ?? offer).replacingOccurrences(of: "\n", with: "")
                let slug = (base?["baseGameSlug"] as? String) ?? (product["gameSlug"] as? String) ?? ""
                games.append(EAOwnedGame(id: offer, title: title, slug: slug, downloadable: (product["downloadable"] as? Bool) ?? false))
            }
            next = page["next"] as? String
            pages += 1
        } while next != nil && !(next ?? "").isEmpty && pages < 50
        // One offer per game: the first (EA lists an offer per edition).
        var seen = Set<String>()
        games = games.filter { seen.insert($0.slug.isEmpty ? $0.id : $0.slug).inserted }
        try await fillCatalog(&games)
        return games
    }

    /// The legacy catalog's content id, install folder and program for each offer.
    private func fillCatalog(_ games: inout [EAOwnedGame]) async throws {
        let query = """
        query MadeiraCatalogDefs($offerIds: [String!]!) {
          legacyOffers(offerIds: $offerIds, locale: "en_US") {
            id contentId displayName displayType multiplayerId executePathOverride installationDirectory installCheckOverride
            isDownloadable dipManifestRelativePath
          }
        }
        """
        for start in stride(from: 0, to: games.count, by: 25) {
            let slice = games[start..<min(start + 25, games.count)]
            let data = try await graphQL("MadeiraCatalogDefs", query: query, variables: ["offerIds": slice.map(\.id)], method: "catalog-defs")
            guard let offers = data["legacyOffers"] as? [[String: Any]] else { continue }
            for offer in offers {
                guard let id = offer["id"] as? String, let index = games.firstIndex(where: { $0.id == id }) else { continue }
                games[index].contentID = Self.string(offer["contentId"])
                games[index].installFolder = (offer["installationDirectory"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                games[index].executePath = (offer["executePathOverride"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                games[index].multiplayerID = Self.string(offer["multiplayerId"])
                if let downloadable = offer["isDownloadable"] as? Bool { games[index].downloadable = downloadable }
            }
        }
    }

    /// A game's cover (tall) and key art (wide), from its slug; nil when EA has none.
    func images(slug: String) async -> (cover: URL?, wide: URL?) {
        guard !slug.isEmpty else { return (nil, nil) }
        let query = """
        query MadeiraGameImages($gameSlug: String!) {
          game(slug: $gameSlug, locale: "en") {
            packArt { aspect9x16Image { path } aspect2x1Image { path } }
            keyArt { aspect16x9Image { path } largestImage { path } }
          }
        }
        """
        guard let data = try? await graphQL("MadeiraGameImages", query: query, variables: ["gameSlug": slug], method: "game-images"),
              let game = data["game"] as? [String: Any] else { return (nil, nil) }
        func path(_ node: Any?, _ keys: String...) -> URL? {
            var current = node as? [String: Any]
            for key in keys.dropLast() { current = current?[key] as? [String: Any] }
            guard let text = (current?[keys.last!] as? [String: Any])?["path"] as? String ?? current?[keys.last!] as? String,
                  let url = URL(string: text), url.scheme == "https" else { return nil }
            return url
        }
        let cover = path(game["packArt"], "aspect9x16Image")
        let wide = path(game["keyArt"], "aspect16x9Image") ?? path(game["packArt"], "aspect2x1Image") ?? path(game["keyArt"], "largestImage")
        return (cover, wide)
    }

    // MARK: Builds

    func builds(offerID: String) async throws -> [EABuild] {
        let query = """
        query MadeiraBuilds($offerId: String!) {
          availableBuilds(offerId: $offerId) { buildId downloadType gameVersion buildLiveDate }
        }
        """
        let data = try await graphQL("MadeiraBuilds", query: query, variables: ["offerId": offerID], method: "builds")
        guard let list = data["availableBuilds"] as? [[String: Any]] else { throw EAAPIError.invalid("builds") }
        return list.compactMap { build in
            guard let id = Self.string(build["buildId"]) else { return nil }
            return EABuild(buildID: id, version: Self.string(build["gameVersion"]) ?? "", type: Self.string(build["downloadType"]) ?? "",
                           liveDate: Self.string(build["buildLiveDate"]))
        }
    }

    /// The live build, else the newest listed.
    func liveBuild(offerID: String) async throws -> EABuild {
        let all = try await builds(offerID: offerID)
        guard let build = all.first(where: { $0.type.uppercased() == "LIVE" }) ?? all.last else { throw EAAPIError.noBuild }
        return build
    }

    /// The address of a build's zip on EA's CDN.
    func downloadURL(offerID: String, buildID: String) async throws -> URL {
        let query = """
        query MadeiraDownloadUrl($offerId: String!, $buildId: String) {
          downloadUrl(offerId: $offerId, buildId: $buildId) { url }
        }
        """
        let data = try await graphQL("MadeiraDownloadUrl", query: query, variables: ["offerId": offerID, "buildId": buildID], method: "download-url")
        guard let metadata = data["downloadUrl"] as? [String: Any], let text = metadata["url"] as? String,
              let url = URL(string: text), url.scheme == "https" else { throw EAAPIError.invalid("download-url") }
        return url
    }

    // MARK: Entitlements (the local service's QueryEntitlements)

    struct Entitlement {
        var id: String; var tag: String; var type: String; var grantDate: String; var group: String
        var productID: String; var terminationDate: String?; var useCount: Int; var version: Int
    }

    func entitlements(group: String) async throws -> [Entitlement] {
        let query = """
        query MadeiraSdkEntitlements($groupNames: [String!]!) {
          me {
            sdkEntitlements(productIds: [], includeChildGroups: false, groupNames: $groupNames, entitlementTag: "",
                            paging: {pageSize: 100, pageNumber: 1}) {
              entitlements { entitlementTag entitlementType grantDate groupName id productId terminationDate useCount version }
            }
          }
        }
        """
        let data = try await graphQL("MadeiraSdkEntitlements", query: query, variables: ["groupNames": [group]], method: "sdk-entitlements")
        guard let me = data["me"] as? [String: Any], let sdk = me["sdkEntitlements"] as? [String: Any],
              let list = sdk["entitlements"] as? [[String: Any]] else { return [] }
        return list.compactMap { e in
            guard let id = Self.string(e["id"]) else { return nil }
            return Entitlement(id: id, tag: Self.string(e["entitlementTag"]) ?? "", type: Self.string(e["entitlementType"]) ?? "",
                               grantDate: Self.string(e["grantDate"]) ?? "", group: Self.string(e["groupName"]) ?? group,
                               productID: Self.string(e["productId"]) ?? "", terminationDate: Self.string(e["terminationDate"]),
                               useCount: (e["useCount"] as? NSNumber)?.intValue ?? 0, version: (e["version"] as? NSNumber)?.intValue ?? 0)
        }
    }

    // MARK: Licences

    /// A game's licence from EA's activation service, for this machine hash: the
    /// licence XML and the signature header. `ticket` and `engine` are what a game
    /// passes with a RequestLicense (a Denuvo ticket).
    func license(contentID: String, machineHash: String, ticket: String? = nil, engine: String? = nil) async throws -> (xml: String, signature: String) {
        let session = try await validSession()
        var nonce = ""
        for _ in 0..<4 { nonce += String(format: "%02x", UInt8.random(in: 0...255)) }
        var items = [URLQueryItem(name: "contentId", value: contentID), URLQueryItem(name: "machineHash", value: machineHash),
                     URLQueryItem(name: "nonce", value: nonce), URLQueryItem(name: "ea_eadmtoken", value: session.accessToken)]
        if let ticket { items.append(URLQueryItem(name: "requestToken", value: ticket)) }
        if let engine { items.append(URLQueryItem(name: "requestType", value: engine)) }
        var components = URLComponents(string: Self.licenses)!
        components.queryItems = items
        var request = URLRequest(url: Self.encodingValues(components))
        request.setValue("Origin Online Activation", forHTTPHeaderField: "X-Requester-Id")
        request.setValue("EACTransaction", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await http.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EAAPIError.invalid("license") }
        guard http.statusCode == 200 else {
            EALog.event("[ea-license] request failed reason=http-\(http.statusCode)")
            throw EAAPIError.license("HTTP \(http.statusCode)")
        }
        guard let signature = http.value(forHTTPHeaderField: "X-Signature") else { throw EAAPIError.license("no signature") }
        guard let xml = EALicenseFile.decrypt(data) else { throw EAAPIError.license("unreadable") }
        return (xml, signature)
    }

    // MARK: Helpers

    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

enum EALog {
    static func event(_ message: String) { LogStore.shared.log(message) }
}
