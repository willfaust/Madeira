// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Security

// itch.io's server API (docs/ITCH.md): the account's owned games and collections,
// game search, a game's uploads and an upload's download address, at api.itch.io
// with an API key the player makes on itch.io (Settings › API keys) and pastes into
// Madeira. The same calls the itch app makes through go-itchio (MIT): GET /profile,
// /profile/owned-keys, /profile/collections, /collections/<id>/collection-games,
// /search/games, /games/<id>, /games/<id>/uploads?download_key_id=, and
// /uploads/<id>/download; a game page's own <page>/data.json gives its id.
// itch.io decides ownership: a paid game's uploads are only listed and served for
// the download key the account owns. A free game has no key (downloading it from
// the website makes none): its uploads are served without one.

enum ItchAPIError: LocalizedError {
    case signedOut
    case badKey
    case http(Int)
    case invalid(String)
    case noWindowsUpload

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to itch.io in Settings › itch.io."
        case .badKey: return "itch.io did not accept this API key. Make a new one on itch.io (Settings › API keys) and paste it again."
        case .http(let code): return "itch.io answered with an error (HTTP \(code)). Try again later."
        case .invalid(let what): return "itch.io sent something Madeira could not read (\(what))."
        case .noWindowsUpload: return "This game has no Windows download on itch.io."
        }
    }

    /// A short code for the log.
    var reason: String {
        switch self {
        case .signedOut: return "signed-out"
        case .badKey: return "bad-key"
        case .http(let code): return "http-\(code)"
        case .invalid(let what): return "invalid-" + what
        case .noWindowsUpload: return "no-windows-upload"
        }
    }
}

/// A game in the player's itch.io library: one the account owns, with the download
/// key that proves it, or a free one from a collection or added in Madeira, with none.
struct ItchOwnedGame: Codable, Identifiable, Hashable, Sendable {
    /// itch.io's game id.
    var id: Int
    var title: String
    var cover: URL?
    /// 0: no key (a free game, or one only in a collection).
    var downloadKeyID: Int
    /// The store page.
    var url: URL?
    /// The lowest price in cents (0: free or name your own price); nil when not known.
    var minPrice: Int? = nil
    /// The author's name on itch.io.
    var author: String? = nil
    var owned: Bool { downloadKeyID != 0 }
}

/// One file of a game's page.
struct ItchUpload: Equatable, Sendable {
    var id: Int
    var filename: String
    var displayName: String
    var size: Int64
    /// "default" for the game itself; also "soundtrack", "book", "mod", ...
    var type: String
    var windows: Bool
    /// The Windows build's architectures as itch.io records them ("all", "386", "amd64"), "" when unknown.
    var windowsArch: String
    var demo: Bool
    var preorder: Bool
    /// The butler build's id, 0 for a plain upload.
    var buildID: Int
    /// The build's version as its author named it, or the upload's last change.
    var version: String
}

enum ItchFormat {
    /// JSON keys arrive in snake_case (and camelCase from some endpoints): both are read.
    static func value(_ object: [String: Any], _ snake: String) -> Any? {
        if let value = object[snake] { return value }
        var camel = ""
        var upper = false
        for c in snake {
            if c == "_" { upper = true; continue }
            camel += upper ? c.uppercased() : String(c)
            upper = false
        }
        return object[camel]
    }

    static func int(_ object: [String: Any], _ key: String) -> Int? {
        switch value(object, key) {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    static func string(_ object: [String: Any], _ key: String) -> String? { value(object, key) as? String }

    static func bool(_ object: [String: Any], _ key: String) -> Bool {
        switch value(object, key) {
        case let n as NSNumber: return n.boolValue
        default: return false
        }
    }

    /// Whether a game or upload has a Windows build, and for which architectures. API
    /// v2 records it as `platforms.windows`, older answers as a `p_windows` trait.
    static func windows(_ object: [String: Any]) -> (Bool, String) {
        if let platforms = value(object, "platforms") as? [String: Any], let arch = platforms["windows"] as? String {
            return (true, arch)
        }
        if (value(object, "traits") as? [String])?.contains("p_windows") == true { return (true, "all") }
        if bool(object, "p_windows") { return (true, "all") }
        return (false, "")
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard data.count < 64 << 20, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ItchAPIError.invalid("json")
        }
        if let errors = object["errors"] as? [String], !errors.isEmpty {
            if errors.contains(where: { $0.lowercased().contains("invalid key") || $0.lowercased().contains("api key") }) { throw ItchAPIError.badKey }
            throw ItchAPIError.invalid("error")
        }
        return object
    }

    /// A game object as a library game: Windows games and tools only. A game whose
    /// platforms are not listed is kept: its uploads decide.
    static func game(_ game: [String: Any], id fallback: Int? = nil, key: Int = 0) -> ItchOwnedGame? {
        guard let id = int(game, "id") ?? fallback else { return nil }
        let kind = string(game, "classification") ?? "game"
        guard kind == "game" || kind == "tool" else { return nil }
        let hasPlatforms = value(game, "platforms") != nil || value(game, "traits") != nil
        guard !hasPlatforms || windows(game).0 else { return nil }
        let title = (string(game, "title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let user = value(game, "user") as? [String: Any]
        let author = user.flatMap { string($0, "display_name").flatMap { $0.isEmpty ? nil : $0 } ?? string($0, "username") }
        return ItchOwnedGame(id: id, title: title.isEmpty ? "itch.io game \(id)" : title,
                             cover: (string(game, "still_cover_url") ?? string(game, "cover_url")).flatMap(httpsURL),
                             downloadKeyID: key, url: string(game, "url").flatMap(httpsURL),
                             minPrice: int(game, "min_price"), author: author)
    }

    /// One page of /profile/owned-keys: the account's Windows games ("game" or "tool"),
    /// and how many keys the page had (fewer than asked: the last page).
    static func ownedKeys(_ object: [String: Any]) -> (games: [ItchOwnedGame], keys: Int) {
        let keys = value(object, "owned_keys") as? [[String: Any]] ?? []
        var games: [ItchOwnedGame] = []
        for key in keys {
            guard let keyID = int(key, "id"), let object = value(key, "game") as? [String: Any],
                  let game = game(object, id: int(key, "game_id"), key: keyID) else { continue }
            games.append(game)
        }
        return (games, keys.count)
    }

    /// /profile/collections: the ids of the account's collections.
    static func collections(_ object: [String: Any]) -> [Int] {
        (value(object, "collections") as? [[String: Any]] ?? []).compactMap { int($0, "id") }
    }

    /// One page of /collections/<id>/collection-games: its Windows games, and how many
    /// entries the page had.
    static func collectionGames(_ object: [String: Any]) -> (games: [ItchOwnedGame], count: Int) {
        let entries = value(object, "collection_games") as? [[String: Any]] ?? []
        return (entries.compactMap { entry in (value(entry, "game") as? [String: Any]).flatMap { game($0, id: int(entry, "game_id")) } }, entries.count)
    }

    /// /search/games: its Windows games.
    static func searchGames(_ object: [String: Any]) -> [ItchOwnedGame] {
        (value(object, "games") as? [[String: Any]] ?? []).compactMap { game($0) }
    }

    /// A game page's id from its `itch:path` meta tag ("games/<id>").
    static func pageGameID(_ html: String) -> Int? {
        guard let tag = html.range(of: "name=\"itch:path\"") else { return nil }
        let rest = html[tag.upperBound...].prefix(200)
        guard let start = rest.range(of: "games/") else { return nil }
        let digits = rest[start.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// The itch.io game page a pasted link names (https://<author>.itch.io/<game>),
    /// as the address of its data.json, which gives the game's id; nil for any other link.
    static func dataURL(_ text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard var components = URLComponents(string: raw), let host = components.host?.lowercased(),
              host.hasSuffix(".itch.io"), host != "api.itch.io", host != "www.itch.io", host.split(separator: ".").count == 3 else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let slug = parts.first, !slug.isEmpty, slug.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        components.scheme = "https"; components.host = host; components.port = nil
        components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
        components.path = "/" + slug + "/data.json"
        return components.url
    }

    static func uploads(_ object: [String: Any]) -> [ItchUpload] {
        (value(object, "uploads") as? [[String: Any]] ?? []).compactMap { upload in
            guard let id = int(upload, "id") else { return nil }
            let (win, arch) = windows(upload)
            let traits = value(upload, "traits") as? [String] ?? []
            let build = value(upload, "build") as? [String: Any]
            return ItchUpload(id: id, filename: string(upload, "filename") ?? "",
                              displayName: string(upload, "display_name") ?? "",
                              size: Int64(int(upload, "size") ?? 0), type: string(upload, "type") ?? "default",
                              windows: win, windowsArch: arch,
                              demo: bool(upload, "demo") || traits.contains("demo"),
                              preorder: bool(upload, "preorder") || traits.contains("preorder"),
                              buildID: int(upload, "build_id") ?? build.flatMap { int($0, "id") } ?? 0,
                              version: build.flatMap { string($0, "user_version") } ?? string(upload, "updated_at") ?? "")
        }
    }

    /// The upload Madeira installs: the game's own Windows file (not a demo, soundtrack
    /// or preorder), a 64-bit or any-architecture one before a 32-bit one, a .zip
    /// before an installer or another archive, then the biggest.
    static func choose(_ uploads: [ItchUpload]) -> ItchUpload? {
        let games = uploads.filter { $0.windows && $0.type == "default" && !$0.preorder }
        let full = games.filter { !$0.demo }
        let pool = full.isEmpty ? games : full
        func score(_ u: ItchUpload) -> (Int, Int, Int64) {
            let name = u.filename.lowercased()
            let kind = name.hasSuffix(".zip") ? 3 : name.hasSuffix(".exe") ? 2 : u.buildID != 0 ? 2 : 0
            let arch = u.windowsArch == "386" ? 0 : 1
            return (arch, kind, u.size)
        }
        return pool.max { score($0) < score($1) }
    }

    static func httpsURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }
}

/// The Keychain item: service `madeira.itch.key`, this device only, while unlocked.
enum ItchKeyStore {
    private static let service = "madeira.itch.key"
    private static let account = "api-key"

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult static func save(_ key: String) -> Bool {
        delete()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: Data(key.utf8),
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

actor ItchAPI {
    static let shared = ItchAPI()
    static let server = URL(string: "https://api.itch.io")!
    /// Where a player makes an API key.
    static let keysPage = URL(string: "https://itch.io/user/settings/api-keys")!

    private var key: String? = ItchKeyStore.load()

    var signedIn: Bool { key != nil }

    /// A key is only kept once itch.io answers /profile with it. Returns the account's name.
    func signIn(key raw: String) async throws -> String {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count < 256, !candidate.contains(where: { $0.isWhitespace }) else { throw ItchAPIError.badKey }
        let name = try await profileName(key: candidate)
        guard ItchKeyStore.save(candidate) else { throw ItchAPIError.invalid("keychain") }
        key = candidate
        return name
    }

    func signOut() {
        ItchKeyStore.delete()
        key = nil
    }

    /// The account's display name, or nil when signed out or the key stopped working.
    func accountName() async -> String? {
        guard let key else { return nil }
        return try? await profileName(key: key)
    }

    private func profileName(key: String) async throws -> String {
        let object = try await get("profile", key: key)
        guard let user = ItchFormat.value(object, "user") as? [String: Any] else { throw ItchAPIError.invalid("profile") }
        return ItchFormat.string(user, "display_name").flatMap { $0.isEmpty ? nil : $0 } ?? ItchFormat.string(user, "username") ?? "itch.io account"
    }

    /// The Windows games in the account's collections, all of them (at most 20
    /// collections of 20 pages each); a collection that fails is skipped.
    func collectionGames() async throws -> [ItchOwnedGame] {
        guard let key else { throw ItchAPIError.signedOut }
        let ids = ItchFormat.collections(try await get("profile/collections", key: key))
        var all: [ItchOwnedGame] = []
        var seen = Set<Int>()
        for collection in ids.prefix(20) {
            for page in 1...20 {
                try Task.checkCancellation()
                guard let object = try? await get("collections/\(collection)/collection-games",
                                                  query: [URLQueryItem(name: "page", value: String(page))], key: key) else { break }
                let (games, count) = ItchFormat.collectionGames(object)
                for game in games where seen.insert(game.id).inserted { all.append(game) }
                if count == 0 || count < (ItchFormat.int(object, "per_page") ?? 0) { break }
            }
        }
        return all
    }

    /// itch.io's game search (Windows games only).
    func search(_ query: String) async throws -> [ItchOwnedGame] {
        guard let key else { throw ItchAPIError.signedOut }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return ItchFormat.searchGames(try await get("search/games", query: [URLQueryItem(name: "query", value: String(text.prefix(200)))], key: key))
    }

    /// The game a pasted itch.io link names: its page's data.json gives the id, the API the rest.
    func game(link: String) async throws -> ItchOwnedGame {
        guard let key else { throw ItchAPIError.signedOut }
        guard let address = ItchFormat.dataURL(link) else { throw ItchAPIError.invalid("link") }
        func fetch(_ url: URL) async throws -> Data {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("Madeira", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw ItchAPIError.http(status) }
            return data
        }
        // The page's data.json, else the page's own <meta name="itch:path" content="games/<id>">.
        var id = (try? await fetch(address)).flatMap { try? ItchFormat.json($0) }.flatMap { ItchFormat.int($0, "id") }
        if id == nil {
            let page = try await fetch(address.deletingLastPathComponent())
            id = ItchFormat.pageGameID(String(decoding: page.prefix(2 << 20), as: UTF8.self))
        }
        guard let id else { throw ItchAPIError.invalid("page") }
        guard let object = ItchFormat.value(try await get("games/\(id)", key: key), "game") as? [String: Any],
              let game = ItchFormat.game(object, id: id) else { throw ItchAPIError.noWindowsUpload }
        return game
    }

    /// Every owned Windows game, all pages (at most 100 pages of 50).
    func ownedGames() async throws -> [ItchOwnedGame] {
        guard let key else { throw ItchAPIError.signedOut }
        var all: [ItchOwnedGame] = []
        var seen = Set<Int>()
        for page in 1...100 {
            try Task.checkCancellation()
            let object = try await get("profile/owned-keys", query: [URLQueryItem(name: "page", value: String(page)),
                                                                     URLQueryItem(name: "per_page", value: "50")], key: key)
            let (games, count) = ItchFormat.ownedKeys(object)
            for game in games where seen.insert(game.id).inserted { all.append(game) }
            if count < 50 { break }
        }
        return all
    }

    func uploads(game: Int, downloadKey: Int) async throws -> [ItchUpload] {
        guard let key else { throw ItchAPIError.signedOut }
        return ItchFormat.uploads(try await get("games/\(game)/uploads", query: Self.keyQuery(downloadKey), key: key))
    }

    /// The upload's download address; itch.io answers it with a redirect to its CDN.
    func downloadRequest(upload: Int, downloadKey: Int) throws -> URLRequest {
        guard let key else { throw ItchAPIError.signedOut }
        var components = URLComponents(url: Self.server.appendingPathComponent("uploads/\(upload)/download"), resolvingAgainstBaseURL: false)!
        let query = Self.keyQuery(downloadKey)
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("Madeira", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// A free game (no key) is asked for without one.
    private static func keyQuery(_ downloadKey: Int) -> [URLQueryItem] {
        downloadKey == 0 ? [] : [URLQueryItem(name: "download_key_id", value: String(downloadKey))]
    }

    private func get(_ path: String, query: [URLQueryItem] = [], key: String) async throws -> [String: Any] {
        var components = URLComponents(url: Self.server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.itch.v2", forHTTPHeaderField: "Accept")
        request.setValue("Madeira", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw ItchAPIError.badKey }
        guard (200..<300).contains(status) else {
            // itch.io's errors come as {"errors": [...]} with a 4xx status; a refused key says so.
            do { _ = try ItchFormat.json(data) } catch ItchAPIError.badKey { throw ItchAPIError.badKey } catch {}
            throw ItchAPIError.http(status)
        }
        return try ItchFormat.json(data)
    }
}

enum ItchLog {
    static func event(_ message: String) { LogStore.shared.log(message) }
}
