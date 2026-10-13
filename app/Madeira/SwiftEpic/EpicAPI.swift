// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Akshay CM
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CryptoKit
import Foundation
import Security

// Epic's public account, launcher and catalog services (docs/EPIC_GAMES.md):
// the same HTTPS endpoints Epic's own launcher uses, and that Legendary and
// Heroic use on Linux. Sign-in is Epic's web login: its redirect page returns a
// one-use authorization code, which is traded for an access and refresh token.
// The tokens live in one Keychain item; nothing else stores them. Log lines name
// methods and Epic error codes only, never a token, code, name or account id.

/// The signed-in account, as stored in the Keychain.
struct EpicSession: Codable, Sendable {
    var accountID: String
    var displayName: String
    var accessToken: String
    var accessExpires: Date
    var refreshToken: String
    var refreshExpires: Date
}

enum EpicAPIError: LocalizedError, Equatable {
    case signedOut
    case epic(code: String, message: String)
    case http(Int)
    case invalid(String)
    case manifestHash

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to Epic Games to continue."
        case .epic(let code, let message):
            if code.hasSuffix("invalid_grant") || code.hasSuffix("authorization_code_not_found") {
                return "Epic did not accept this sign-in code. Codes work once and expire after a few minutes: sign in again."
            }
            if code.hasSuffix("corrective_action_required") {
                return "Epic needs you to act on your account first (for example to accept new terms). Sign in at epicgames.com, then try again."
            }
            return message.isEmpty ? "Epic refused the request (\(code))." : message
        case .http(let status): return "Epic's server answered with HTTP \(status). Try again later."
        case .invalid(let what): return "Epic sent an unexpected answer (\(what))."
        case .manifestHash: return "The game's file list from Epic failed its checksum. Try again."
        }
    }

    /// Short and credential-free, for the log.
    var reason: String {
        switch self {
        case .signedOut: return "signed-out"
        case .epic(let code, _): return code.split(separator: ".").suffix(2).joined(separator: ".")
        case .http(let status): return "http-\(status)"
        case .invalid(let what): return "invalid-\(what)"
        case .manifestHash: return "manifest-hash"
        }
    }
}

/// One game the account owns on Windows (Epic's "asset" for the Live label).
struct EpicAsset: Codable, Sendable, Hashable {
    var appName: String
    var labelName: String?
    var buildVersion: String
    var catalogItemId: String
    var namespace: String
}

/// What the catalog says about a game.
struct EpicCatalogItem: Sendable {
    var title: String
    var images: [String: URL]
    var attributes: [String: String]
    var isDLC: Bool
    var categories: [String]
}

/// Where a build's manifest and chunks are.
struct EpicManifestLocation: Sendable {
    var manifestURLs: [URL]
    var baseURLs: [URL]
    var sha1: String
    var buildVersion: String
    var secrets: [String: String]
}

/// The Keychain item: service `madeira.epic.tokens`, this device only, while unlocked.
enum EpicTokenStore {
    private static let service = "madeira.epic.tokens"
    private static let account = "session"

    static func load() -> EpicSession? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(EpicSession.self, from: data)
    }

    @discardableResult static func save(_ session: EpicSession) -> Bool {
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

actor EpicAPI {
    static let shared = EpicAPI()

    // The Epic Games Launcher's public client, which the account and launcher
    // services expect for these calls (the same one Legendary uses).
    private static let clientID = "34a02cf8f4414e29b15921876da36f9a"
    private static let clientSecret = "daafbccc737745039dffe53d94fc76cf"
    static let userAgent = "UELauncher/11.0.1-14907503+++Portal+Release-Live Windows/10.0.19041.1.256.64bit"
    private static let oauthHost = "https://account-public-service-prod03.ol.epicgames.com"
    private static let launcherHost = "https://launcher-public-service-prod06.ol.epicgames.com"
    private static let catalogHost = "https://catalog-public-service-prod06.ol.epicgames.com"
    private static let ecommerceHost = "https://ecommerceintegration-public-service-ecomprod02.ol.epicgames.com"

    /// Epic's web login; after it, the redirect page shows the authorization code as JSON.
    static let loginURL: URL = {
        let redirect = "https://www.epicgames.com/id/api/redirect?clientId=\(clientID)&responseType=code"
        let encoded = redirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? redirect
        return URL(string: "https://www.epicgames.com/id/login?redirectUrl=\(encoded)")!
    }()
    static func isRedirectPage(_ url: URL?) -> Bool {
        guard let url, url.host?.lowercased() == "www.epicgames.com" else { return false }
        return url.path.lowercased().hasPrefix("/id/api/redirect")
    }

    /// The authorization code from what the user pasted or the redirect page showed:
    /// the page's JSON, or the code itself (32 hex characters).
    static func authorizationCode(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = object["authorizationCode"] as? String, !code.isEmpty {
            return code
        }
        if let pattern = try? NSRegularExpression(pattern: "\"authorizationCode\"\\s*:\\s*\"([0-9A-Za-z]+)\""),
           let match = pattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let range = Range(match.range(at: 1), in: trimmed) {
            return String(trimmed[range])
        }
        let allowed = CharacterSet.alphanumerics
        if (20...64).contains(trimmed.count), trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return trimmed }
        return nil
    }

    /// Epic's "corrective action" (EULA_ACCEPTANCE, PRIVACY_POLICY_ACCEPTANCE, ...) when the
    /// redirect page or a pasted text is that error instead of a code.
    static func correctiveAction(in text: String) -> String? {
        guard text.contains("corrective_action_required"),
              let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return text.contains("corrective_action_required") ? "" : nil
        }
        let metadata = object["metadata"] as? [String: Any]
        return (metadata?["correctiveAction"] as? String) ?? (object["correctiveAction"] as? String) ?? ""
    }

    static func correctiveMessage(_ action: String) -> String {
        let what = action.contains("EULA") ? "accept Epic's license agreement"
            : action.contains("PRIVACY") ? "accept Epic's privacy policy" : "complete a step on your account"
        return "Epic needs you to \(what) before it gives Madeira a sign-in code. Sign in at store.epicgames.com in Safari and accept it (or sign in once with the Epic Games Launcher on a computer), then reload this page."
    }

    private let http: URLSession
    private var session: EpicSession?
    private var loaded = false
    private var refreshing: Task<EpicSession, Error>?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        http = URLSession(configuration: config)
    }

    private func stored() -> EpicSession? {
        if !loaded { session = EpicTokenStore.load(); loaded = true }
        return session
    }

    /// The stored account, if any, without contacting Epic.
    func account() -> (id: String, name: String)? {
        stored().map { ($0.accountID, $0.displayName) }
    }

    // MARK: Sign-in

    func signIn(authorizationCode code: String) async throws -> EpicSession {
        let session = try await token(["grant_type": "authorization_code", "code": code, "token_type": "eg1"])
        EpicLog.event("[epic-signin] signed in")
        return session
    }

    func signOut() {
        refreshing?.cancel(); refreshing = nil
        session = nil; loaded = true
        EpicTokenStore.delete()
        EpicLog.event("[epic-signin] signed out")
    }

    /// A session whose access token is good for at least five more minutes.
    func validSession() async throws -> EpicSession {
        guard let current = stored() else { throw EpicAPIError.signedOut }
        if current.accessExpires.timeIntervalSinceNow > 300 { return current }
        if let refreshing { return try await refreshing.value }
        guard current.refreshExpires.timeIntervalSinceNow > 60 else { signOut(); throw EpicAPIError.signedOut }
        let task = Task { try await self.token(["grant_type": "refresh_token", "refresh_token": current.refreshToken, "token_type": "eg1"]) }
        refreshing = task
        defer { refreshing = nil }
        do {
            return try await task.value
        } catch let error as EpicAPIError {
            // A refresh token Epic no longer accepts: the account must sign in again.
            if case .epic(let code, _) = error, code.contains("invalid_refresh_token") || code.contains("invalid_grant") || code.contains(".auth_token.") {
                signOut(); throw EpicAPIError.signedOut
            }
            throw error
        }
    }

    private func token(_ form: [String: String]) async throws -> EpicSession {
        var request = URLRequest(url: URL(string: Self.oauthHost + "/account/api/oauth/token")!)
        request.httpMethod = "POST"
        let basic = Data("\(Self.clientID):\(Self.clientSecret)".utf8).base64EncodedString()
        request.setValue("basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { "\($0.key)=\(Self.formEncode($0.value))" }.sorted().joined(separator: "&").utf8)
        let json = try await object(request, method: "oauth-token")
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String,
              let account = json["account_id"] as? String else { throw EpicAPIError.invalid("token") }
        let now = Date()
        let session = EpicSession(accountID: account, displayName: json["displayName"] as? String ?? "",
                                  accessToken: access, accessExpires: now.addingTimeInterval(Self.seconds(json["expires_in"]) ?? 3600),
                                  refreshToken: refresh,
                                  refreshExpires: now.addingTimeInterval(Self.seconds(json["refresh_expires"]) ?? 8 * 3600))
        self.session = session; loaded = true
        EpicTokenStore.save(session)
        return session
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        (value as? NSNumber)?.doubleValue
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Requests

    private func authorized(_ url: URL, method: String = "GET") async throws -> URLRequest {
        let session = try await validSession()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Sends a request and returns its body; Epic's error JSON becomes EpicAPIError.epic.
    private func send(_ request: URLRequest, method: String) async throws -> Data {
        let (data, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 || status == 0 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let code = json["errorCode"] as? String {
                let error = EpicAPIError.epic(code: code, message: json["errorMessage"] as? String ?? "")
                EpicLog.event("[epic-api] \(method) failed reason=\(error.reason)")
                throw error
            }
            EpicLog.event("[epic-api] \(method) failed reason=http-\(status)")
            throw EpicAPIError.http(status)
        }
        return data
    }

    private func object(_ request: URLRequest, method: String) async throws -> [String: Any] {
        let data = try await send(request, method: method)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EpicAPIError.invalid(method) }
        return json
    }

    // MARK: Library

    /// The account's Windows games (Live label).
    func assets() async throws -> [EpicAsset] {
        var components = URLComponents(string: Self.launcherHost + "/launcher/api/public/assets/Windows")!
        components.queryItems = [URLQueryItem(name: "label", value: "Live")]
        let data = try await send(try await authorized(components.url!), method: "assets")
        do { return try JSONDecoder().decode([EpicAsset].self, from: data) } catch { throw EpicAPIError.invalid("assets") }
    }

    func catalogItem(namespace: String, id: String) async throws -> EpicCatalogItem? {
        var components = URLComponents(string: Self.catalogHost + "/catalog/api/shared/namespace/\(Self.pathSafe(namespace))/bulk/items")!
        components.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "includeDLCDetails", value: "true"),
                                 URLQueryItem(name: "includeMainGameDetails", value: "true"),
                                 URLQueryItem(name: "country", value: "US"), URLQueryItem(name: "locale", value: "en")]
        let json = try await object(try await authorized(components.url!), method: "catalog")
        guard let item = json[id] as? [String: Any] else { return nil }
        var images: [String: URL] = [:]
        for image in item["keyImages"] as? [[String: Any]] ?? [] {
            if let type = image["type"] as? String, let text = image["url"] as? String, let url = URL(string: text), url.scheme == "https" {
                images[type] = url
            }
        }
        var attributes: [String: String] = [:]
        for (key, value) in item["customAttributes"] as? [String: Any] ?? [:] {
            if let value = (value as? [String: Any])?["value"] as? String { attributes[key] = value }
        }
        let categories = (item["categories"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        return EpicCatalogItem(title: item["title"] as? String ?? "", images: images, attributes: attributes,
                               isDLC: item["mainGameItem"] != nil, categories: categories)
    }

    // MARK: Builds

    func manifestLocation(_ asset: EpicAsset) async throws -> EpicManifestLocation {
        let path = "/launcher/api/public/assets/v2/platform/Windows/namespace/\(Self.pathSafe(asset.namespace))/catalogItem/"
            + "\(Self.pathSafe(asset.catalogItemId))/app/\(Self.pathSafe(asset.appName))/label/Live"
        let json = try await object(try await authorized(URL(string: Self.launcherHost + path)!), method: "manifest-info")
        guard let element = (json["elements"] as? [[String: Any]])?.first, let hash = element["hash"] as? String else {
            throw EpicAPIError.invalid("manifest-info")
        }
        var manifests: [URL] = [], bases: [URL] = []
        for entry in element["manifests"] as? [[String: Any]] ?? [] {
            guard let uri = entry["uri"] as? String, var components = URLComponents(string: uri),
                  components.scheme == "https" || components.scheme == "http" else { continue }
            let base = String(uri[..<(uri.lastIndex(of: "/") ?? uri.endIndex)])
            if let url = URL(string: base), !bases.contains(url) { bases.append(url) }
            let params = (entry["queryParams"] as? [[String: Any]] ?? []).compactMap { param -> URLQueryItem? in
                guard let name = param["name"] as? String else { return nil }
                return URLQueryItem(name: name, value: param["value"] as? String)
            }
            if !params.isEmpty { components.queryItems = params }
            if let url = components.url { manifests.append(url) }
        }
        var secrets: [String: String] = [:]
        if let raw = element["secrets"] as? [String: Any] {
            for (key, value) in raw { if let value = value as? String { secrets[key.uppercased()] = value } }
        }
        guard !manifests.isEmpty else { throw EpicAPIError.invalid("no-manifest-url") }
        return EpicManifestLocation(manifestURLs: manifests, baseURLs: bases, sha1: hash.lowercased(),
                                    buildVersion: element["buildVersion"] as? String ?? "", secrets: secrets)
    }

    /// The manifest file, from the first CDN that serves it, checked against the API's SHA-1.
    func manifest(_ location: EpicManifestLocation) async throws -> Data {
        var lastError: Error = EpicAPIError.invalid("manifest")
        for url in location.manifestURLs {
            do {
                var request = URLRequest(url: url)
                request.setValue(EpicDownloader.userAgent, forHTTPHeaderField: "User-Agent")
                let data = try await send(request, method: "manifest")
                guard Data(Insecure.SHA1.hash(data: data)).epicHex == location.sha1 else { throw EpicAPIError.manifestHash }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: Launch

    /// A one-use code the game trades for its own Epic session (-AUTH_PASSWORD).
    func exchangeCode() async throws -> String {
        let json = try await object(try await authorized(URL(string: Self.oauthHost + "/account/api/oauth/exchange")!), method: "exchange")
        guard let code = json["code"] as? String, !code.isEmpty else { throw EpicAPIError.invalid("exchange") }
        return code
    }

    /// The ownership token some games require (-epicovt).
    func ownershipToken(namespace: String, catalogItemID: String) async throws -> Data {
        guard let account = stored()?.accountID else { throw EpicAPIError.signedOut }
        let url = URL(string: Self.ecommerceHost + "/ecommerceintegration/api/public/platforms/EPIC/identities/\(Self.pathSafe(account))/ownershipToken")!
        var request = try await authorized(url, method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("nsCatalogItemId=\(Self.formEncode(namespace + ":" + catalogItemID))".utf8)
        return try await send(request, method: "ownership-token")
    }

    private static func pathSafe(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

enum EpicLog {
    static func event(_ message: String) {
        LogStore.shared.log(message)
    }
}
