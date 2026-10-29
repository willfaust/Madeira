// SPDX-License-Identifier: GPL-3.0-or-later
// The host's side of a GOG game's Galaxy SDK (decision 0063): the local Galaxy
// service a game's SDK talks to on 127.0.0.1:9977 (GalaxyListener), as GOG's own
// client is. The game's AUTH_INFO request, bound to the installed build's client ID
// and secret (GOG's desktop client's own ID always refused), gets a refresh token
// minted for that game's client from the host's GOG session; that token is the one
// thing that crosses into the game, in the reply's bytes only. Achievements, stats,
// leaderboards and play time are served from gameplay.gog.com with the game-scoped
// access token, which stays here. One service per play: the token is minted at the
// play's first AUTH_INFO and kept in memory until the play ends. The log names each
// request and the reply's status, never a payload, a token or the client secret.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContentKit

/// A game-scoped GOG token: for the game's own client ID, the host session's user.
public struct GOGGameToken: Sendable {
    public var accessToken: Secret<String>
    public var refreshToken: Secret<String>
    public var expiresAt: Date
    public var userID: String

    public init(accessToken: Secret<String>, refreshToken: Secret<String>, expiresAt: Date, userID: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
    }
}

/// Where the service gets the game's token (GOGSession on the phone; a fake in tests).
public protocol GalaxyTokenSource: Sendable {
    /// A refresh token for `client`, minted from the host session (without a new session).
    func gameToken(for client: GOGGalaxyClient) async throws -> GOGGameToken
    /// The game token refreshed at the game's own client.
    func refreshGameToken(_ refreshToken: Secret<String>, for client: GOGGalaxyClient) async throws -> GOGGameToken
}

/// The service's HTTP: a status and a body, any status (the service maps it).
public protocol GalaxyHTTP: Sendable {
    func send(_ method: String, _ url: URL, bearer: Secret<String>?, json: [UInt8]?, language: String?) async throws -> (status: Int, body: [UInt8])
}

/// GalaxyHTTP over URLSession: ephemeral, no cookies or cache, a 20 s limit, 1 MiB at most.
public struct URLSessionGalaxyHTTP: GalaxyHTTP {
    let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": GOGAPI.userAgent]
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    public func send(_ method: String, _ url: URL, bearer: Secret<String>?, json: [UInt8]?, language: String?) async throws -> (status: Int, body: [UInt8]) {
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let bearer { r.setValue("Bearer " + bearer.value, forHTTPHeaderField: "Authorization") }
        if let json {
            r.httpBody = Data(json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let language { r.setValue(language, forHTTPHeaderField: "X-Gog-Lc") }
        let (data, response) = try await session.data(for: r)
        guard data.count <= 1 << 20 else { throw ClientError.unsafeContent("Galaxy reply of \(data.count) bytes") }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, [UInt8](data))
    }
}

extension GOGSession: GalaxyTokenSource {
    public func gameToken(for client: GOGGalaxyClient) async throws -> GOGGameToken {
        guard let host = try hostRefreshToken() else { throw ClientError.notLoggedOn }
        return try await gameGrant(host, client, label: "GOG game token")
    }

    public func refreshGameToken(_ refreshToken: Secret<String>, for client: GOGGalaxyClient) async throws -> GOGGameToken {
        try await gameGrant(refreshToken, client, label: "GOG game token refresh")
    }

    /// The refresh-token grant at the game's client, `without_new_session=1`: the host's
    /// kept tokens are neither used up nor replaced (the plan's B0 measurement).
    private func gameGrant(_ refreshToken: Secret<String>, _ client: GOGGalaxyClient, label: String) async throws -> GOGGameToken {
        var c = URLComponents(string: "https://auth.gog.com/token")!
        c.queryItems = [.init(name: "client_id", value: client.clientID), .init(name: "client_secret", value: client.clientSecret.value),
                        .init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: refreshToken.value),
                        .init(name: "without_new_session", value: "1")]
        let body = try await http.get(c.url!, maxBytes: 1 << 16, label: label)
        struct Reply: Decodable {
            var access_token: String
            var refresh_token: String
            var expires_in: Double?
            var user_id: String?
        }
        guard let r = try? JSONDecoder().decode(Reply.self, from: Data(body)), let user = r.user_id, UInt64(user) != nil else {
            throw ClientError.protocolChanged("\(label): unexpected reply")
        }
        return GOGGameToken(accessToken: Secret(r.access_token), refreshToken: Secret(r.refresh_token),
                            expiresAt: now().addingTimeInterval(r.expires_in ?? 3600), userID: user)
    }
}

public actor GalaxyService {
    let client: GOGGalaxyClient
    let tokens: any GalaxyTokenSource
    let http: any GalaxyHTTP
    let log: Logger
    let language: String
    private var token: GOGGameToken?
    private var userName: String?
    private var counts: [String: Int] = [:]
    /// The clock; tests move it.
    var now: @Sendable () -> Date = { Date() }

    public init(client: GOGGalaxyClient, tokens: any GalaxyTokenSource, http: any GalaxyHTTP = URLSessionGalaxyHTTP(),
                log: Logger, language: String = "en-US") {
        self.client = client
        self.tokens = tokens
        self.http = http
        self.log = log
        self.language = language
    }

    /// What the play asked of the service, for the line at its end.
    public var summary: String {
        counts.isEmpty ? "no requests" : counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    /// Whether a game token was minted in this play.
    public var minted: Bool { token != nil }

    /// The frames to send back for one frame from the game: none for a notification,
    /// else the reply (AUTH_INFO's is preceded by the overlay state).
    public func handle(_ f: GalaxyFrame) async -> [GalaxyFrame] {
        if f.sort == GalaxyFrame.Sort.webBroker { return webBroker(f) }
        guard f.sort == GalaxyFrame.Sort.communicationService else {
            log.info("galaxy", "sort \(f.sort) type \(f.type): not served")
            return f.oseq == nil ? [] : [f.reply(type: f.type + 1, status: .notImplemented)]
        }
        guard let m = GalaxyMessage(rawValue: f.type) else {
            log.info("galaxy", "type \(f.type) (\(f.payload.count) bytes): not served")
            return f.oseq == nil ? [] : [f.reply(type: f.type + 1, status: .notImplemented)]
        }
        counts[m.name, default: 0] += 1
        let replies: [GalaxyFrame]
        do {
            replies = try await serve(m, f)
        } catch is GalaxyProto.Malformed {
            replies = [f.reply(type: f.type + 1, status: .badRequest)]
        } catch {
            log.warn("galaxy", "\(m.name): \(error)")
            replies = [f.reply(type: f.type + 1, status: .unavailable)]
        }
        if let last = replies.last {
            log.info("galaxy", "\(m.name) (\(f.payload.count) bytes) -> \(last.status.map(String.init) ?? "200") (\(last.payload.count) bytes)")
        }
        return replies
    }

    private func webBroker(_ f: GalaxyFrame) -> [GalaxyFrame] {
        // SUBSCRIBE_TOPIC_REQUEST (3): acknowledged; the host pushes no topics.
        if f.type == 3, let topic = (try? GalaxyFields(f.payload))?.string(1) {
            log.info("galaxy", "web broker: topic subscription acknowledged, nothing will be pushed")
            return [f.reply(type: 4, payload: GalaxyMessages.subscribeTopicResponse(topic))]
        }
        log.info("galaxy", "web broker type \(f.type): not served")
        return f.oseq == nil ? [] : [f.reply(type: f.type + 1, status: .notImplemented)]
    }

    private func serve(_ m: GalaxyMessage, _ f: GalaxyFrame) async throws -> [GalaxyFrame] {
        let reply = m.rawValue + 1
        switch m {
        case .authInfoRequest:
            return try await authInfo(f)
        case .libraryInfoRequest:
            log.info("galaxy", "LIBRARY_INFO: the SDK asks for GOG's separate peer library, which Playport does not provide")
            return [f.reply(type: reply, payload: GalaxyMessages.libraryInfoUnavailable())]
        case .startGameSessionRequest:
            return [f.reply(type: reply)]
        default:
            break
        }
        guard token != nil else {
            log.info("galaxy", "\(m.name) before the game signed in: refused")
            return [f.reply(type: reply, status: .unauthorized)]
        }
        let fields = try GalaxyFields(f.payload)
        let base = "https://gameplay.gog.com/clients/\(client.clientID)"
        switch m {
        case .getUserStatsRequest:
            let (status, json) = try await call("GET", "\(base)/users/\(user(fields.fixed64(1)))/stats")
            guard status == .ok else { return [f.reply(type: reply, status: status)] }
            return [f.reply(type: reply, payload: GalaxyMessages.userStatsResponse(Self.stats(json)))]
        case .updateUserStatRequest:
            let r = try GalaxyMessages.UpdateUserStatRequest(f.payload)
            let value: Any
            switch r.value {
            case let .int(v)?: value = Int(v)
            case let .float(v)?, let .avgRate(v)?: value = Double(v)
            case nil: return [f.reply(type: reply, status: .badRequest)]
            }
            let (status, _) = try await call("POST", "\(base)/users/\(user(nil))/stats/\(r.statID)", json: ["value": value])
            return [f.reply(type: reply, status: status)]
        case .deleteUserStatsRequest:
            let (status, _) = try await call("DELETE", "\(base)/users/\(user(nil))/stats")
            return [f.reply(type: reply, status: status)]
        case .getUserAchievementsRequest:
            let (status, json) = try await call("GET", "\(base)/users/\(user(fields.fixed64(1)))/achievements")
            guard status == .ok else { return [f.reply(type: reply, status: status)] }
            let (items, mode) = Self.achievements(json)
            return [f.reply(type: reply, payload: GalaxyMessages.userAchievementsResponse(items, language: language, mode: mode))]
        case .unlockUserAchievementRequest:
            let r = try GalaxyMessages.AchievementRequest(f.payload)
            let at = r.time.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? now()
            log.info("galaxy", "UNLOCK_USER_ACHIEVEMENT \(r.id): sent to GOG")
            let (status, _) = try await call("POST", "\(base)/users/\(user(nil))/achievements/\(r.id)",
                                             json: ["date_unlocked": Self.rfc3339(at)])
            return [f.reply(type: reply, status: status)]
        case .clearUserAchievementRequest:
            let r = try GalaxyMessages.AchievementRequest(f.payload)
            let (status, _) = try await call("POST", "\(base)/users/\(user(nil))/achievements/\(r.id)", json: ["date_unlocked": NSNull()])
            return [f.reply(type: reply, status: status)]
        case .deleteUserAchievementsRequest:
            let (status, _) = try await call("DELETE", "\(base)/users/\(user(nil))/achievements")
            return [f.reply(type: reply, status: status)]
        case .getLeaderboardsRequest, .getLeaderboardsByKeyRequest:
            let keys = fields.strings(1)
            var url = "\(base)/leaderboards"
            if m == .getLeaderboardsByKeyRequest { url += "?keys=" + Self.query(keys.joined(separator: ",")) }
            let (status, json) = try await call("GET", url)
            guard status == .ok else { return [f.reply(type: 32, status: status)] }
            return [f.reply(type: 32, payload: GalaxyMessages.leaderboardsResponse(Self.leaderboards(json)))]
        case .getLeaderboardEntriesGlobalRequest, .getLeaderboardEntriesAroundUserRequest, .getLeaderboardEntriesForUsersRequest:
            guard let id = fields.fixed64(1) else { throw GalaxyProto.Malformed() }
            let query: String
            switch m {
            case .getLeaderboardEntriesGlobalRequest:
                query = "range_start=\(fields.uint(2) ?? 0)&range_end=\(fields.uint(3) ?? 0)"
            case .getLeaderboardEntriesAroundUserRequest:
                query = "count_before=\(fields.uint(3) ?? 0)&count_after=\(fields.uint(4) ?? 0)&user=\(user(fields.fixed64(2)))"
            default:
                query = "users=" + fields.fixed64s(2).map { String(GalaxyMessages.plainID($0)) }.joined(separator: ",")
            }
            let (status, json) = try await call("GET", "\(base)/leaderboards/\(id)/entries?\(query)")
            guard status == .ok else { return [f.reply(type: 36, status: status)] }
            let (entries, total) = Self.entries(json)
            return [f.reply(type: 36, payload: GalaxyMessages.leaderboardEntriesResponse(entries, total: total))]
        case .setLeaderboardScoreRequest:
            let r = try GalaxyMessages.SetLeaderboardScoreRequest(f.payload)
            var body: [String: Any] = ["score": Int(r.score), "force": r.force]
            if let d = r.details, !d.isEmpty { body["details"] = Self.base64URL(d) }
            let (status, json) = try await call("POST", "\(base)/users/\(user(nil))/leaderboards/\(r.leaderboardID)", json: body)
            guard status == .ok else { return [f.reply(type: reply, status: status)] }
            let o = json as? [String: Any] ?? [:]
            return [f.reply(type: reply, payload: GalaxyMessages.setLeaderboardScoreResponse(
                score: r.score, oldRank: UInt32(clamping: Self.u64(o["old_rank"]) ?? 0), newRank: UInt32(clamping: Self.u64(o["new_rank"]) ?? 0),
                total: UInt32(clamping: Self.u64(o["leaderboard_entry_total_count"]) ?? 0)))]
        case .createLeaderboardRequest:
            let sort = ["", "asc", "desc"], display = ["", "numeric", "seconds", "milliseconds"]
            guard let key = fields.string(1), let s = fields.uint(3), let d = fields.uint(4), (1...2).contains(s), (1...3).contains(d) else {
                throw GalaxyProto.Malformed()
            }
            let (status, json) = try await call("POST", "\(base)/leaderboards",
                                                json: ["key": key, "name": fields.string(2) ?? key, "sort_method": sort[Int(s)], "display_type": display[Int(d)]])
            guard status == .ok, let id = Self.u64((json as? [String: Any])?["id"]) else { return [f.reply(type: reply, status: status == .ok ? .unavailable : status)] }
            return [f.reply(type: reply, payload: GalaxyMessages.createLeaderboardResponse(id: id))]
        case .getUserTimePlayedRequest:
            let (status, json) = try await call("GET", "\(base)/users/\(user(fields.uint(1)))/sessions")
            guard status == .ok else { return [f.reply(type: reply, status: status)] }
            let seconds = Self.u64((json as? [String: Any])?["time_sum"]) ?? 0
            return [f.reply(type: reply, payload: GalaxyMessages.timePlayedResponse(UInt32(clamping: seconds)))]
        default:
            log.info("galaxy", "\(m.name): not served")
            return f.oseq == nil ? [] : [f.reply(type: reply, status: .notImplemented)]
        }
    }

    private func authInfo(_ f: GalaxyFrame) async throws -> [GalaxyFrame] {
        let r = try GalaxyMessages.AuthInfoRequest(f.payload)
        let reply = GalaxyMessage.authInfoResponse.rawValue
        guard let id = r.clientID, id != GOGAPI.clientID, id == client.clientID, r.clientSecret == client.clientSecret.value else {
            log.warn("galaxy", "AUTH_INFO refused: the client is not this build's" + (r.clientID == GOGAPI.clientID ? " (GOG's desktop client)" : ""))
            return [f.reply(type: reply, status: .forbidden)]
        }
        if token == nil {
            let started = now()
            do {
                token = try await tokens.gameToken(for: client)
            } catch let ClientError.eresult(_, context) {
                log.warn("galaxy", "AUTH_INFO: GOG refused the game's token (\(context)); the game stays signed out")
                return [f.reply(type: reply, status: .forbidden)]
            } catch ClientError.notLoggedOn {
                log.warn("galaxy", "AUTH_INFO: not signed in to GOG; the game stays signed out")
                return [f.reply(type: reply, status: .unauthorized)]
            }
            log.info("galaxy", String(format: "AUTH_INFO: a game token minted for the build's client in %.2f s", now().timeIntervalSince(started)))
            userName = await fetchUserName()
        }
        guard let t = token, let user = UInt64(t.userID) else { return [f.reply(type: reply, status: .unavailable)] }
        return [GalaxyFrame(sort: GalaxyFrame.Sort.communicationService, type: GalaxyMessage.overlayStateChangeNotification.rawValue,
                            payload: GalaxyMessages.overlayNotSupported()),
                f.reply(type: reply, payload: GalaxyMessages.authInfoResponse(refreshToken: t.refreshToken.value, userID: user, userName: userName))]
    }

    /// The account's public name (users.gog.com, no token), for the SDK's persona name.
    private func fetchUserName() async -> String? {
        guard let id = token?.userID, let url = URL(string: "https://users.gog.com/users/\(id)"),
              let (status, body) = try? await http.send("GET", url, bearer: nil, json: nil, language: nil), status == 200,
              let o = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] else { return nil }
        return o["username"] as? String
    }

    /// The signed-in user's ID, or the one a request names (a GOG entity ID).
    private func user(_ entity: UInt64?) -> String {
        if let e = entity, GalaxyMessages.plainID(e) != 0 { return String(GalaxyMessages.plainID(e)) }
        return token?.userID ?? "0"
    }

    /// One gameplay.gog.com call with the game's access token, refreshed first when it has
    /// under five minutes left, and once more after a 401.
    private func call(_ method: String, _ url: String, json: [String: Any]? = nil) async throws -> (GalaxyFrame.Status, Any?) {
        guard let u = URL(string: url) else { throw GalaxyProto.Malformed() }
        let body = try json.map { [UInt8](try JSONSerialization.data(withJSONObject: $0)) }
        if let t = token, t.expiresAt.timeIntervalSince(now()) < 300 { try await refresh() }
        var (status, data) = try await http.send(method, u, bearer: token?.accessToken, json: body, language: language)
        if status == 401 {
            try await refresh()
            (status, data) = try await http.send(method, u, bearer: token?.accessToken, json: body, language: language)
        }
        let mapped: GalaxyFrame.Status
        switch status {
        case 200, 201, 202, 204: mapped = .ok
        case 400: mapped = .badRequest
        case 401: mapped = .unauthorized
        case 403: mapped = .forbidden
        case 404: mapped = .notFound
        case 409: mapped = .conflict
        default: mapped = .unavailable
        }
        if mapped != .ok { log.info("galaxy", "\(method) \(u.path): HTTP \(status)") }
        return (mapped, data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: Data(data)))
    }

    private func refresh() async throws {
        guard let t = token else { return }
        token = try await tokens.refreshGameToken(t.refreshToken, for: client)
        log.info("galaxy", "the game's access token refreshed at its client")
    }

    // MARK: GOG's replies

    static func u64(_ v: Any?) -> UInt64? {
        if let s = v as? String { return UInt64(s) }
        if let n = v as? NSNumber { return n.uint64Value }
        return nil
    }

    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func items(_ json: Any?) -> [[String: Any]] { ((json as? [String: Any])?["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] } }

    static func stats(_ json: Any?) -> [GalaxyMessages.UserStat] {
        items(json).compactMap { o in
            guard let id = u64(o["stat_id"]), let key = o["stat_key"] as? String else { return nil }
            let v = double(o["value"]) ?? 0
            let value: GalaxyMessages.StatValue
            switch o["type"] as? String {
            case "int": value = .int(Int32(clamping: Int64(v)))
            case "avgrate": value = .avgRate(Float(v))
            default: value = .float(Float(v))
            }
            return .init(id: id, key: key, value: value, window: double(o["window"]), incrementOnly: o["increment_only"] as? Bool ?? false,
                         minValue: double(o["min_value"]), maxValue: double(o["max_value"]), maxChange: double(o["max_change"]),
                         defaultValue: double(o["default_value"]))
        }
    }

    static func achievements(_ json: Any?) -> ([GalaxyMessages.UserAchievement], String?) {
        let list: [GalaxyMessages.UserAchievement] = items(json).compactMap { o in
            guard let id = u64(o["achievement_id"]), let key = o["achievement_key"] as? String else { return nil }
            return .init(id: id, key: key, name: o["name"] as? String ?? key, description: o["description"] as? String ?? "",
                         imageLocked: o["image_url_locked"] as? String ?? "", imageUnlocked: o["image_url_unlocked"] as? String ?? "",
                         visible: o["visible"] as? Bool ?? true,
                         unlockTime: (o["date_unlocked"] as? String).flatMap(parseDate).map { UInt32(clamping: Int64($0.timeIntervalSince1970)) },
                         rarity: double(o["rarity"]).map(Float.init), rarityDescription: o["rarity_level_description"] as? String,
                         raritySlug: o["rarity_level_slug"] as? String)
        }
        return (list, (json as? [String: Any])?["achievements_mode"] as? String)
    }

    static func leaderboards(_ json: Any?) -> [GalaxyMessages.Leaderboard] {
        items(json).compactMap { o in
            guard let id = u64(o["id"]), let key = o["key"] as? String else { return nil }
            let sort: UInt64 = (o["sort_method"] as? String) == "asc" ? 1 : (o["sort_method"] as? String) == "desc" ? 2 : 0
            let display: UInt64 = ["numeric": 1, "seconds": 2, "milliseconds": 3][o["display_type"] as? String ?? ""] ?? 0
            return .init(id: id, key: key, name: o["name"] as? String ?? key, sortMethod: sort, displayType: display)
        }
    }

    static func entries(_ json: Any?) -> ([GalaxyMessages.LeaderboardEntry], UInt32) {
        let list: [GalaxyMessages.LeaderboardEntry] = items(json).compactMap { o in
            guard let user = u64(o["user_id"]) else { return nil }
            return .init(rank: UInt32(clamping: u64(o["rank"]) ?? 0), score: UInt32(clamping: u64(o["score"]) ?? 0), userID: user,
                         details: (o["details"] as? String).flatMap(base64URLDecode))
        }
        return (list, UInt32(clamping: u64((json as? [String: Any])?["leaderboard_entry_total_count"]) ?? UInt64(list.count)))
    }

    /// GOG's dates: `2026-10-07T12:00:00+0000` or with `+00:00`/`Z`.
    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func rfc3339(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'+00:00'"
        return f.string(from: d)
    }

    static func query(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~,"))) ?? ""
    }

    static func base64URL(_ b: [UInt8]) -> String {
        Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ s: String) -> [UInt8]? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).map { [UInt8]($0) }
    }
}
