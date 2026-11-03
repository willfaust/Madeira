// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Security

// GOG's public account, library and content-system services (docs/GOG.md): the
// same HTTPS endpoints GOG Galaxy uses, and that Heroic's gogdl uses on Linux.
// Sign-in is GOG's own login page: it redirects to embed.gog.com/on_login_success
// with a one-use code, which is traded for an access and refresh token. The
// tokens live in one Keychain item; nothing else stores them. Log lines name
// methods and HTTP statuses only, never a token, code, name or account id.

/// The signed-in account, as stored in the Keychain.
struct GOGSession: Codable, Sendable {
    var userID: String
    var userName: String
    var accessToken: String
    var accessExpires: Date
    var refreshToken: String
}

enum GOGAPIError: LocalizedError, Equatable {
    case signedOut
    case http(Int)
    case invalid(String)
    case noWindowsBuild
    case legacyBuild
    case noPlayTask

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to GOG to continue."
        case .http(let status):
            if status == 401 || status == 403 { return "GOG refused the request (HTTP \(status)). Sign in again in Settings › GOG." }
            return "GOG's server answered with HTTP \(status). Try again later."
        case .invalid(let what): return "GOG sent an unexpected answer (\(what))."
        case .noWindowsBuild: return "GOG has no Windows build of this game for Madeira to download."
        case .legacyBuild: return "This game only has an older kind of GOG build (generation 1), which Madeira cannot download yet."
        case .noPlayTask: return "The game's files downloaded, but they do not say which program starts the game (goggame-<id>.info). Add the game with + and choose its .exe."
        }
    }

    /// Short and credential-free, for the log.
    var reason: String {
        switch self {
        case .signedOut: return "signed-out"
        case .http(let status): return "http-\(status)"
        case .invalid(let what): return "invalid-\(what)"
        case .noWindowsBuild: return "no-windows-build"
        case .legacyBuild: return "generation-1"
        case .noPlayTask: return "no-play-task"
        }
    }
}

/// One game in the account's library (getFilteredProducts).
struct GOGProduct: Sendable, Hashable {
    var id: String
    var title: String
    var image: URL?
    var windows: Bool
}

/// One build of a game (content-system builds list).
struct GOGBuild: Sendable {
    var buildID: String
    var versionName: String
    var branch: String?
    var generation: Int
    var link: URL
}

/// A build's manifest: its depots and where it installs.
struct GOGBuildManifest: Sendable {
    struct Depot: Sendable {
        var productID: String
        var languages: [String]
        var bitness: [String]
        var manifest: String
        var size: Int64
        var compressedSize: Int64
    }
    var baseProductID: String
    var buildID: String
    var installDirectory: String
    var depots: [Depot]
    /// GOG's redistributables the build needs ("MSVC2017_x64", "openAL"): GOGSetup.
    var dependencies: [String] = []
    /// The game's own Galaxy client (its SDK signs in with it): GOGGalaxy.
    var galaxy: GOGGalaxyClient?

    static func parse(_ json: [String: Any]) throws -> GOGBuildManifest {
        guard (json["version"] as? NSNumber)?.intValue == 2 else { throw GOGAPIError.legacyBuild }
        guard let base = GOGAPI.string(json["baseProductId"]), let folder = json["installDirectory"] as? String,
              let raw = json["depots"] as? [[String: Any]] else { throw GOGAPIError.invalid("build-manifest") }
        let depots = raw.compactMap { depot -> Depot? in
            guard let product = GOGAPI.string(depot["productId"]), let manifest = depot["manifest"] as? String,
                  GOGAPI.isHash(manifest) else { return nil }
            return Depot(productID: product, languages: depot["languages"] as? [String] ?? ["*"],
                         bitness: (depot["osBitness"] as? [Any] ?? []).compactMap { GOGAPI.string($0) },
                         manifest: manifest, size: (depot["size"] as? NSNumber)?.int64Value ?? 0,
                         compressedSize: (depot["compressedSize"] as? NSNumber)?.int64Value ?? 0)
        }
        let dependencies = (json["dependencies"] as? [Any] ?? []).compactMap { $0 as? String }
            .filter { (1...64).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) } }
        return GOGBuildManifest(baseProductID: base, buildID: GOGAPI.string(json["buildId"]) ?? "",
                                installDirectory: folder, depots: depots, dependencies: dependencies,
                                galaxy: GOGGalaxyClient(id: GOGAPI.string(json["clientId"]), secret: json["clientSecret"] as? String))
    }

    /// The depots to install: the game's and those of DLC the account owns, in one
    /// language (English when there is one, else the first the game lists), and the
    /// 64-bit files when the build has both.
    func selected(ownedDLC: Set<String>) -> (depots: [Depot], language: String) {
        let products = depots.filter { $0.productID == baseProductID || ownedDLC.contains($0.productID) }
        let languages = products.flatMap(\.languages).filter { $0 != "*" }
        let language = languages.first { $0.lowercased() == "en-us" } ?? languages.first { $0.lowercased().hasPrefix("en") }
            ?? languages.first ?? "*"
        let bits = products.contains { $0.bitness.contains("64") } ? "64" : "32"
        let chosen = products.filter { depot in
            (depot.languages.contains("*") || depot.languages.contains(language))
                && (depot.bitness.isEmpty || depot.bitness.contains(bits))
        }
        return (chosen, language)
    }
}

/// The Keychain item: service `madeira.gog.tokens`, this device only, while unlocked.
enum GOGTokenStore {
    private static let service = "madeira.gog.tokens"
    private static let account = "session"

    static func load() -> GOGSession? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(GOGSession.self, from: data)
    }

    @discardableResult static func save(_ session: GOGSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        delete()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                   kSecAttrSynchronizable as String: false]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

actor GOGAPI {
    static let shared = GOGAPI()

    // GOG Galaxy's public client, which the token service expects (the same one
    // gogdl, Heroic and lgogdownloader use).
    static let clientID = "46899977096215655"
    private static let clientSecret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
    private static let redirect = "https://embed.gog.com/on_login_success?origin=client"
    static let userAgent = "Madeira (GOG content system client)"
    private static let authHost = "https://auth.gog.com"
    private static let embedHost = "https://embed.gog.com"
    private static let contentHost = "https://content-system.gog.com"
    static let cdnHost = "https://gog-cdn-fastly.gog.com"

    /// GOG's login page in the layout Galaxy shows; it ends on the redirect page with `code`.
    static let loginURL: URL = {
        var components = URLComponents(string: authHost + "/auth")!
        components.queryItems = [URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "redirect_uri", value: redirect),
                                 URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "layout", value: "client2")]
        return components.url!
    }()

    /// The one-use code from the redirect page's address, or from what the user pasted
    /// (that address, or the code itself).
    static func authorizationCode(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), components.host?.lowercased() == "embed.gog.com",
           components.path.lowercased().hasPrefix("/on_login_success"),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return code
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if (20...512).contains(trimmed.count), !trimmed.contains("/"), trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return trimmed }
        return nil
    }

    static func isRedirectPage(_ url: URL?) -> Bool {
        guard let url, url.host?.lowercased() == "embed.gog.com" else { return false }
        return url.path.lowercased().hasPrefix("/on_login_success")
    }

    private let http: URLSession
    private var session: GOGSession?
    private var loaded = false
    private var refreshing: Task<GOGSession, Error>?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        // A stalled answer fails instead of leaving a download preparing forever.
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        http = URLSession(configuration: config)
    }

    private func stored() -> GOGSession? {
        if !loaded { session = GOGTokenStore.load(); loaded = true }
        return session
    }

    /// The stored account, if any, without contacting GOG.
    func account() -> (id: String, name: String)? {
        stored().map { ($0.userID, $0.userName) }
    }

    // MARK: Sign-in

    func signIn(authorizationCode code: String) async throws -> GOGSession {
        var session = try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect], userName: "")
        if let data = try? await send(try await authorized(URL(string: Self.embedHost + "/userData.json")!), method: "user-data"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = json["username"] as? String {
            session.userName = name
            self.session = session
            GOGTokenStore.save(session)
        }
        GOGLog.event("[gog-signin] signed in")
        return session
    }

    func signOut() {
        refreshing?.cancel(); refreshing = nil
        session = nil; loaded = true
        GOGTokenStore.delete()
        GOGLog.event("[gog-signin] signed out")
    }

    /// A session whose access token is good for at least five more minutes.
    func validSession() async throws -> GOGSession {
        guard let current = stored() else { throw GOGAPIError.signedOut }
        if current.accessExpires.timeIntervalSinceNow > 300 { return current }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.token(["grant_type": "refresh_token", "refresh_token": current.refreshToken], userName: current.userName) }
        refreshing = task
        defer { refreshing = nil }
        do {
            return try await task.value
        } catch GOGAPIError.http(let status) where status == 400 || status == 401 || status == 403 {
            // A refresh token GOG no longer accepts: the account must sign in again.
            signOut(); throw GOGAPIError.signedOut
        }
    }

    private func token(_ parameters: [String: String], userName: String) async throws -> GOGSession {
        var components = URLComponents(string: Self.authHost + "/token")!
        components.queryItems = [URLQueryItem(name: "client_id", value: Self.clientID),
                                 URLQueryItem(name: "client_secret", value: Self.clientSecret)]
            + parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let request = URLRequest(url: Self.encodingValues(components))
        let json = try await object(request, method: "oauth-token")
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String,
              let user = Self.string(json["user_id"]) else { throw GOGAPIError.invalid("token") }
        let session = GOGSession(userID: user, userName: userName, accessToken: access,
                                 accessExpires: Date().addingTimeInterval((json["expires_in"] as? NSNumber)?.doubleValue ?? 3600),
                                 refreshToken: refresh)
        self.session = session; loaded = true
        GOGTokenStore.save(session)
        return session
    }

    /// The URL with every query value fully percent-encoded: URLComponents leaves the
    /// "?", "=", ":" and "/" of the redirect URI as they are.
    private static func encodingValues(_ components: URLComponents) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        var copy = components
        copy.percentEncodedQuery = (components.queryItems ?? []).map {
            "\($0.name)=\(($0.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return copy.url!
    }

    // MARK: Requests

    private func authorized(_ url: URL) async throws -> URLRequest {
        let session = try await validSession()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest, method: String) async throws -> Data {
        let (data, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            GOGLog.event("[gog-api] \(method) failed reason=http-\(status)")
            throw GOGAPIError.http(status)
        }
        return data
    }

    private func object(_ request: URLRequest, method: String) async throws -> [String: Any] {
        let data = try await send(request, method: method)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GOGAPIError.invalid(method) }
        return json
    }

    // MARK: Library

    /// The account's games, every page of GOG's own library listing.
    func products() async throws -> [GOGProduct] {
        var products: [GOGProduct] = []
        var page = 1, pages = 1
        repeat {
            var components = URLComponents(string: Self.embedHost + "/account/getFilteredProducts")!
            components.queryItems = [URLQueryItem(name: "mediaType", value: "1"), URLQueryItem(name: "sortBy", value: "title"),
                                     URLQueryItem(name: "page", value: String(page))]
            let json = try await object(try await authorized(components.url!), method: "products")
            pages = min((json["totalPages"] as? NSNumber)?.intValue ?? 1, 200)
            for item in json["products"] as? [[String: Any]] ?? [] {
                guard let id = Self.string(item["id"]), let title = item["title"] as? String else { continue }
                if let isGame = item["isGame"] as? Bool, !isGame { continue }
                let worksOn = item["worksOn"] as? [String: Any] ?? [:]
                var image: URL?
                if let path = item["image"] as? String, !path.isEmpty {
                    image = URL(string: (path.hasPrefix("//") ? "https:" + path : path) + "_392.jpg")
                }
                products.append(GOGProduct(id: id, title: title, image: image?.scheme == "https" ? image : nil,
                                           windows: worksOn["Windows"] as? Bool ?? true))
            }
            page += 1
        } while page <= pages
        return products
    }

    /// Every product id the account owns (games and DLC).
    func ownedIDs() async throws -> Set<String> {
        let json = try await object(try await authorized(URL(string: Self.embedHost + "/user/data/games")!), method: "owned")
        return Set((json["owned"] as? [Any] ?? []).compactMap { Self.string($0) })
    }

    /// The game's tall cover from GOG's game database, or nil.
    func verticalCover(_ id: String) async -> URL? {
        guard let url = URL(string: "https://gamesdb.gog.com/platforms/gog/external_releases/\(Self.pathSafe(id))"),
              let json = try? await object(URLRequest(url: url), method: "gamesdb"),
              let format = ((json["game"] as? [String: Any])?["vertical_cover"] as? [String: Any])?["url_format"] as? String
        else { return nil }
        let text = format.replacingOccurrences(of: "{formatter}", with: "").replacingOccurrences(of: "{ext}", with: "jpg")
        guard let cover = URL(string: text), cover.scheme == "https" else { return nil }
        return cover
    }

    // MARK: Builds

    /// The build to install: the newest on the default branch.
    func latestBuild(_ id: String) async throws -> GOGBuild {
        var components = URLComponents(string: Self.contentHost + "/products/\(Self.pathSafe(id))/os/windows/builds")!
        components.queryItems = [URLQueryItem(name: "generation", value: "2")]
        let json: [String: Any]
        do {
            json = try await object(try await authorized(components.url!), method: "builds")
        } catch GOGAPIError.http(404) {
            throw GOGAPIError.noWindowsBuild
        }
        let builds = (json["items"] as? [[String: Any]] ?? []).compactMap { item -> GOGBuild? in
            guard let text = item["link"] as? String, let link = URL(string: text), link.scheme == "https" else { return nil }
            return GOGBuild(buildID: Self.string(item["build_id"]) ?? "", versionName: item["version_name"] as? String ?? "",
                            branch: item["branch"] as? String, generation: (item["generation"] as? NSNumber)?.intValue ?? 0, link: link)
        }
        guard let build = builds.first(where: { $0.branch == nil }) ?? builds.first else { throw GOGAPIError.noWindowsBuild }
        guard build.generation == 2 else { throw GOGAPIError.legacyBuild }
        return build
    }

    /// A build's manifest, kept as GOG sent it (zlib JSON) to read again for updates.
    func buildManifest(_ build: GOGBuild) async throws -> Data {
        try await send(URLRequest(url: build.link), method: "build-manifest")
    }

    /// One depot's file list (zlib JSON on GOG's CDN).
    func depotManifest(_ hash: String) async throws -> Data {
        guard GOGAPI.isHash(hash), let url = URL(string: Self.cdnHost + "/content-system/v2/meta/" + Self.galaxyPath(hash)) else {
            throw GOGAPIError.invalid("depot-hash")
        }
        return try await send(URLRequest(url: url), method: "depot-manifest")
    }

    /// Signed download addresses for a product's chunks, best first. Each is a URL
    /// format with parameters; the chunk's path goes on the end of its `path` parameter.
    func secureLinks(_ product: String) async throws -> [GOGEndpoint] {
        var components = URLComponents(string: Self.contentHost + "/products/\(Self.pathSafe(product))/secure_link")!
        components.queryItems = [URLQueryItem(name: "_version", value: "2"), URLQueryItem(name: "generation", value: "2"),
                                 URLQueryItem(name: "path", value: "/")]
        return try Self.endpoints(try await object(try await authorized(components.url!), method: "secure-link"), method: "secure-link")
    }

    private static func endpoints(_ json: [String: Any], method: String) throws -> [GOGEndpoint] {
        let endpoints = (json["urls"] as? [[String: Any]] ?? []).compactMap { entry -> GOGEndpoint? in
            guard let format = entry["url_format"] as? String else { return nil }
            var parameters: [String: String] = [:]
            for (key, value) in entry["parameters"] as? [String: Any] ?? [:] {
                if let text = Self.string(value) { parameters[key] = text }
            }
            return GOGEndpoint(format: format, parameters: parameters)
        }
        guard !endpoints.isEmpty else { throw GOGAPIError.invalid(method) }
        return endpoints
    }

    // MARK: Redistributables

    /// GOG's redistributables ("dependencies"): the repository's pointer, then its
    /// manifest (zlib JSON), as GOG Galaxy and Heroic read them. No sign-in needed.
    func dependencyRepository() async throws -> [GOGDependency] {
        let pointer = try await object(URLRequest(url: URL(string: Self.contentHost + "/dependencies/repository?generation=2")!),
                                       method: "dependency-repository")
        guard let text = pointer["repository_manifest"] as? String, let url = URL(string: text), url.scheme == "https" else {
            throw GOGAPIError.invalid("dependency-repository")
        }
        let json = try GOGCodec.json(try await send(URLRequest(url: url), method: "dependency-manifest"), what: "dependencies")
        return GOGDependency.parse(json)
    }

    /// One redistributable's file list (zlib JSON on GOG's CDN).
    func dependencyDepot(_ hash: String) async throws -> Data {
        guard GOGAPI.isHash(hash), let url = URL(string: "https://cdn.gog.com/content-system/v2/dependencies/meta/" + Self.galaxyPath(hash)) else {
            throw GOGAPIError.invalid("dependency-hash")
        }
        return try await send(URLRequest(url: url), method: "dependency-depot")
    }

    /// Download addresses for redistributables' chunks: GOG's open link (no sign-in).
    func dependencyLinks() async throws -> [GOGEndpoint] {
        let url = URL(string: Self.contentHost + "/open_link?generation=2&_version=2&path=/dependencies/store/")!
        return try Self.endpoints(try await object(URLRequest(url: url), method: "open-link"), method: "open-link")
    }

    // MARK: Helpers

    /// "abcdef..." -> "ab/cd/abcdef...", GOG's CDN layout.
    static func galaxyPath(_ hash: String) -> String {
        guard hash.count > 4, !hash.contains("/") else { return hash }
        return String(hash.prefix(2)) + "/" + String(hash.dropFirst(2).prefix(2)) + "/" + hash
    }

    /// A content hash: hexadecimal only, so it is safe in a path.
    static func isHash(_ text: String) -> Bool {
        (16...128).contains(text.count) && text.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }

    /// GOG sends ids as numbers in some answers and as strings in others.
    static func string(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func pathSafe(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// One signed CDN address for a product (secure_link).
struct GOGEndpoint: Sendable {
    var format: String
    var parameters: [String: String]

    /// The address of one chunk: its galaxy path on the end of the `path` parameter.
    /// The redistributables' open link has no `{path}` in its format: its format is the
    /// store's address and the chunk's path follows it (as Playport and heroic-gogdl
    /// build it; build 67 fetched the bare store address for every Witcher chunk).
    func url(for compressedMD5: String) -> URL? {
        var values = parameters
        values["path"] = (values["path"] ?? "") + "/" + GOGAPI.galaxyPath(compressedMD5)
        var text = format.contains("{path}") ? format : format + "{path}"
        for (key, value) in values { text = text.replacingOccurrences(of: "{\(key)}", with: value) }
        guard !text.contains("{"), let url = URL(string: text), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }
}

enum GOGLog {
    static func event(_ message: String) {
        LogStore.shared.log(message)
    }
}
