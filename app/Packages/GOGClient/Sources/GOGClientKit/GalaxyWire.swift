// SPDX-License-Identifier: GPL-3.0-or-later
// The Galaxy SDK's local protocol (decision 0063), as the SDK in a game speaks it to
// the local Galaxy service on 127.0.0.1:9977: a frame is a u16 big-endian header
// length, a protobuf header (`sort` the sub-protocol, `type` the message, `size` the
// payload's length, `oseq` the request's sequence; a reply carries `rseq` = the
// request's `oseq` in field 100 and a status code in field 101), then the payload, a
// protobuf message. The field numbers are the protocol's message descriptors; only the
// messages the service answers are here. Nothing in this file logs.

import Foundation

/// A protobuf encoder and decoder for the few field kinds Galaxy's messages use.
enum GalaxyProto {
    enum Field: Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes([UInt8])
        case fixed32(UInt32)
    }

    struct Malformed: Error {}

    /// Every field of a message by number, in order; repeated fields repeat.
    static func decode(_ b: [UInt8]) throws -> [(Int, Field)] {
        var out: [(Int, Field)] = []
        var i = 0
        func varint() throws -> UInt64 {
            var v: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                guard i < b.count else { throw Malformed() }
                let c = b[i]
                i += 1
                v |= UInt64(c & 0x7F) << UInt64(shift)
                if c & 0x80 == 0 { return v }
            }
            throw Malformed()
        }
        func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, n <= b.count - i else { throw Malformed() }
            defer { i += n }
            return Array(b[i..<i + n])
        }
        while i < b.count {
            let key = try varint()
            let number = Int(key >> 3)
            guard number > 0, number < 1 << 29 else { throw Malformed() }
            switch key & 7 {
            case 0: out.append((number, .varint(try varint())))
            case 1: out.append((number, .fixed64(try take(8).reversed().reduce(0) { $0 << 8 | UInt64($1) })))
            case 2:
                let n = try varint()
                guard n <= UInt64(b.count) else { throw Malformed() }
                out.append((number, .bytes(try take(Int(n)))))
            case 5: out.append((number, .fixed32(try take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) })))
            default: throw Malformed()
            }
        }
        return out
    }

    struct Writer {
        var bytes: [UInt8] = []

        mutating func varint(_ v: UInt64) {
            var v = v
            while v >= 0x80 {
                bytes.append(UInt8(v & 0x7F) | 0x80)
                v >>= 7
            }
            bytes.append(UInt8(v))
        }

        mutating func key(_ n: Int, _ wire: UInt64) { varint(UInt64(n) << 3 | wire) }
        mutating func uint(_ n: Int, _ v: UInt64) { key(n, 0); varint(v) }
        /// int32 as protobuf writes it: a negative value sign-extended to ten bytes.
        mutating func int(_ n: Int, _ v: Int32) { uint(n, UInt64(bitPattern: Int64(v))) }
        mutating func bool(_ n: Int, _ v: Bool) { uint(n, v ? 1 : 0) }
        mutating func fixed64(_ n: Int, _ v: UInt64) {
            key(n, 1)
            for s in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(s))) }
        }
        mutating func fixed32(_ n: Int, _ v: UInt32) {
            key(n, 5)
            for s in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(s))) }
        }
        mutating func float(_ n: Int, _ v: Float) { fixed32(n, v.bitPattern) }
        mutating func double(_ n: Int, _ v: Double) { fixed64(n, v.bitPattern) }
        mutating func data(_ n: Int, _ v: [UInt8]) { key(n, 2); varint(UInt64(v.count)); bytes += v }
        mutating func string(_ n: Int, _ v: String) { data(n, Array(v.utf8)) }
    }
}

/// A message's decoded fields, read by number (the last of a repeated scalar wins, as
/// protobuf reads it).
struct GalaxyFields {
    let fields: [(Int, GalaxyProto.Field)]

    init(_ payload: [UInt8]) throws { fields = try GalaxyProto.decode(payload) }

    func uint(_ n: Int) -> UInt64? {
        for (k, f) in fields.reversed() where k == n { if case let .varint(v) = f { return v } }
        return nil
    }
    func fixed64(_ n: Int) -> UInt64? {
        for (k, f) in fields.reversed() where k == n { if case let .fixed64(v) = f { return v } }
        return nil
    }
    func fixed32(_ n: Int) -> UInt32? {
        for (k, f) in fields.reversed() where k == n { if case let .fixed32(v) = f { return v } }
        return nil
    }
    func float(_ n: Int) -> Float? { fixed32(n).map(Float.init(bitPattern:)) }
    func int32(_ n: Int) -> Int32? { uint(n).map { Int32(truncatingIfNeeded: Int64(bitPattern: $0)) } }
    func bool(_ n: Int) -> Bool? { uint(n).map { $0 != 0 } }
    func data(_ n: Int) -> [UInt8]? {
        for (k, f) in fields.reversed() where k == n { if case let .bytes(v) = f { return v } }
        return nil
    }
    func string(_ n: Int) -> String? { data(n).map { String(decoding: $0, as: UTF8.self) } }
    func strings(_ n: Int) -> [String] {
        fields.compactMap { k, f in if k == n, case let .bytes(v) = f { return String(decoding: v, as: UTF8.self) } else { return nil } }
    }
    func fixed64s(_ n: Int) -> [UInt64] {
        fields.compactMap { k, f in if k == n, case let .fixed64(v) = f { return v } else { return nil } }
    }
}

/// One frame of the local protocol.
public struct GalaxyFrame: Equatable, Sendable {
    /// Sub-protocols (`sort`).
    public enum Sort {
        public static let communicationService: UInt32 = 1
        public static let webBroker: UInt32 = 2
    }

    /// Reply status codes (header field 101), as HTTP's.
    public enum Status: UInt32, Sendable {
        case ok = 200, badRequest = 400, unauthorized = 401, forbidden = 403, notFound = 404, conflict = 409
        case internalError = 500, notImplemented = 501, unavailable = 503
    }

    public var sort: UInt32
    public var type: UInt32
    public var oseq: UInt32?
    public var rseq: UInt32?
    /// A reply's status; nil in a request (and an OK reply, which leaves it out).
    public var status: UInt32?
    public var payload: [UInt8]

    public init(sort: UInt32, type: UInt32, oseq: UInt32? = nil, rseq: UInt32? = nil, status: UInt32? = nil, payload: [UInt8] = []) {
        self.sort = sort
        self.type = type
        self.oseq = oseq
        self.rseq = rseq
        self.status = status
        self.payload = payload
    }

    /// The largest payload the service takes; a frame claiming more ends the connection.
    public static let maxPayload = 1 << 20

    public enum ParseError: Error, Equatable {
        case malformedHeader
        case tooLarge(Int)
    }

    /// The first whole frame at the start of `buffer` and the bytes it took, or nil when
    /// more bytes are needed.
    public static func parse(_ buffer: [UInt8]) throws -> (GalaxyFrame, Int)? {
        guard buffer.count >= 2 else { return nil }
        let headerLength = Int(buffer[0]) << 8 | Int(buffer[1])
        guard headerLength > 0 else { throw ParseError.malformedHeader }
        guard buffer.count >= 2 + headerLength else { return nil }
        guard let h = try? GalaxyFields(Array(buffer[2..<2 + headerLength])),
              let sort = h.uint(1), let type = h.uint(2), sort <= UInt64(UInt32.max), type <= UInt64(UInt32.max) else {
            throw ParseError.malformedHeader
        }
        let size = Int(clamping: h.uint(3) ?? 0)
        guard size <= maxPayload else { throw ParseError.tooLarge(size) }
        let total = 2 + headerLength + size
        guard buffer.count >= total else { return nil }
        let frame = GalaxyFrame(sort: UInt32(sort), type: UInt32(type), oseq: h.uint(4).map { UInt32(truncatingIfNeeded: $0) },
                                rseq: h.uint(100).map { UInt32(truncatingIfNeeded: $0) },
                                status: h.uint(101).map { UInt32(truncatingIfNeeded: $0) },
                                payload: Array(buffer[2 + headerLength..<total]))
        return (frame, total)
    }

    public var encoded: [UInt8] {
        var h = GalaxyProto.Writer()
        h.uint(1, UInt64(sort))
        h.uint(2, UInt64(type))
        h.uint(3, UInt64(payload.count))
        if let oseq { h.uint(4, UInt64(oseq)) }
        if let rseq { h.uint(100, UInt64(rseq)) }
        if let status { h.uint(101, UInt64(status)) }
        return [UInt8(h.bytes.count >> 8), UInt8(h.bytes.count & 0xFF)] + h.bytes + payload
    }

    /// The reply to this request: its sort, `type`, `rseq` = its `oseq`, and the status
    /// when it is not OK.
    public func reply(type: UInt32, status: Status = .ok, payload: [UInt8] = []) -> GalaxyFrame {
        GalaxyFrame(sort: sort, type: type, rseq: oseq, status: status == .ok ? nil : status.rawValue, payload: payload)
    }
}

/// The communication service's message types (sort 1) the service knows.
public enum GalaxyMessage: UInt32, Sendable {
    case libraryInfoRequest = 1, libraryInfoResponse = 2
    case authInfoRequest = 3, authInfoResponse = 4
    case getUserStatsRequest = 15, getUserStatsResponse = 16
    case updateUserStatRequest = 17, updateUserStatResponse = 18
    case deleteUserStatsRequest = 19, deleteUserStatsResponse = 20
    case getGlobalStatsRequest = 21
    case getUserAchievementsRequest = 23, getUserAchievementsResponse = 24
    case unlockUserAchievementRequest = 25, unlockUserAchievementResponse = 26
    case clearUserAchievementRequest = 27, clearUserAchievementResponse = 28
    case deleteUserAchievementsRequest = 29, deleteUserAchievementsResponse = 30
    case getLeaderboardsRequest = 31, getLeaderboardsResponse = 32
    case getLeaderboardEntriesGlobalRequest = 33, getLeaderboardEntriesAroundUserRequest = 34
    case getLeaderboardEntriesForUsersRequest = 35, getLeaderboardEntriesResponse = 36
    case setLeaderboardScoreRequest = 37, setLeaderboardScoreResponse = 38
    case authStateChangeNotification = 39
    case getLeaderboardsByKeyRequest = 40
    case createLeaderboardRequest = 41, createLeaderboardResponse = 42
    case getUserTimePlayedRequest = 43, getUserTimePlayedResponse = 44
    case shareFileRequest = 47
    case startGameSessionRequest = 49, startGameSessionResponse = 50
    case startStorageSynchronizationRequest = 51
    case abortStorageSynchronizationRequest = 56
    case overlayStateChangeNotification = 58
    case configureEnvironmentRequest = 59

    /// The name the service's log uses.
    public var name: String {
        switch self {
        case .libraryInfoRequest: "LIBRARY_INFO"
        case .authInfoRequest: "AUTH_INFO"
        case .getUserStatsRequest: "GET_USER_STATS"
        case .updateUserStatRequest: "UPDATE_USER_STAT"
        case .deleteUserStatsRequest: "DELETE_USER_STATS"
        case .getGlobalStatsRequest: "GET_GLOBAL_STATS"
        case .getUserAchievementsRequest: "GET_USER_ACHIEVEMENTS"
        case .unlockUserAchievementRequest: "UNLOCK_USER_ACHIEVEMENT"
        case .clearUserAchievementRequest: "CLEAR_USER_ACHIEVEMENT"
        case .deleteUserAchievementsRequest: "DELETE_USER_ACHIEVEMENTS"
        case .getLeaderboardsRequest: "GET_LEADERBOARDS"
        case .getLeaderboardsByKeyRequest: "GET_LEADERBOARDS_BY_KEY"
        case .getLeaderboardEntriesGlobalRequest: "GET_LEADERBOARD_ENTRIES_GLOBAL"
        case .getLeaderboardEntriesAroundUserRequest: "GET_LEADERBOARD_ENTRIES_AROUND_USER"
        case .getLeaderboardEntriesForUsersRequest: "GET_LEADERBOARD_ENTRIES_FOR_USERS"
        case .setLeaderboardScoreRequest: "SET_LEADERBOARD_SCORE"
        case .createLeaderboardRequest: "CREATE_LEADERBOARD"
        case .getUserTimePlayedRequest: "GET_USER_TIME_PLAYED"
        case .shareFileRequest: "SHARE_FILE"
        case .startGameSessionRequest: "START_GAME_SESSION"
        case .startStorageSynchronizationRequest: "START_STORAGE_SYNCHRONIZATION"
        case .abortStorageSynchronizationRequest: "ABORT_STORAGE_SYNCHRONIZATION"
        case .configureEnvironmentRequest: "CONFIGURE_ENVIRONMENT"
        default: "type \(rawValue)"
        }
    }
}

/// The messages' fields (the protocol's descriptors), each as the service reads or writes it.
enum GalaxyMessages {
    /// GOG's entity IDs carry their kind in the top byte: 2 is a user.
    static func userEntity(_ id: UInt64) -> UInt64 { 2 << 56 | (id & 0x00FF_FFFF_FFFF_FFFF) }
    static func plainID(_ entity: UInt64) -> UInt64 { entity & 0x00FF_FFFF_FFFF_FFFF }

    struct AuthInfoRequest: Equatable {
        var clientID: String?
        var clientSecret: String?
        var gamePID: UInt32?
        var openID: Bool

        init(_ payload: [UInt8]) throws {
            let f = try GalaxyFields(payload)
            clientID = f.string(1)
            clientSecret = f.string(2)
            gamePID = f.uint(5).map { UInt32(truncatingIfNeeded: $0) }
            openID = f.bool(6) ?? false
        }
    }

    /// The refresh token is a parameter, never a stored field, so the reply's bytes are
    /// the only place it is put together.
    static func authInfoResponse(refreshToken: String, userID: UInt64, userName: String?) -> [UInt8] {
        var w = GalaxyProto.Writer()
        w.string(1, refreshToken)
        w.uint(2, 0)                         // ENVIRONMENT_PRODUCTION
        w.fixed64(3, userEntity(userID))
        if let userName { w.string(4, userName) }
        w.uint(5, 0)                         // REGION_WORLD_WIDE
        return w.bytes
    }

    /// OVERLAY_STATE_CHANGE_NOTIFICATION: Playport shows no Galaxy overlay.
    static func overlayNotSupported() -> [UInt8] {
        var w = GalaxyProto.Writer()
        w.uint(1, 0)                         // OVERLAY_STATE_NOT_SUPPORTED
        return w.bytes
    }

    /// LIBRARY_INFO_RESPONSE with UPDATE_FAILED: no separate peer library is provided.
    static func libraryInfoUnavailable() -> [UInt8] {
        var w = GalaxyProto.Writer()
        w.uint(2, 2)                         // UPDATE_FAILED
        return w.bytes
    }

    enum StatValue: Equatable {
        case int(Int32)
        case float(Float)
        case avgRate(Float)
    }

    struct UserStat: Equatable {
        var id: UInt64
        var key: String
        var value: StatValue
        var window: Double?
        var incrementOnly: Bool
        var minValue: Double?
        var maxValue: Double?
        var maxChange: Double?
        var defaultValue: Double?
    }

    static func userStatsResponse(_ stats: [UserStat]) -> [UInt8] {
        var w = GalaxyProto.Writer()
        for s in stats {
            var m = GalaxyProto.Writer()
            m.fixed64(1, s.id)
            m.string(2, s.key)
            switch s.value {
            case let .int(v):
                m.uint(3, 1)
                m.int(5, v)
                if let d = s.defaultValue { m.int(8, Int32(clamping: Int64(d))) }
                if let d = s.minValue { m.int(10, Int32(clamping: Int64(d))) }
                if let d = s.maxValue { m.int(12, Int32(clamping: Int64(d))) }
                if let d = s.maxChange { m.int(14, Int32(clamping: Int64(d))) }
            case let .float(v), let .avgRate(v):
                if case .float = s.value { m.uint(3, 2) } else { m.uint(3, 3) }
                m.float(4, v)
                if let d = s.defaultValue { m.float(7, Float(d)) }
                if let d = s.minValue { m.float(9, Float(d)) }
                if let d = s.maxValue { m.float(11, Float(d)) }
                if let d = s.maxChange { m.float(13, Float(d)) }
            }
            if let window = s.window { m.double(6, window) }
            m.bool(15, s.incrementOnly)
            w.data(1, m.bytes)
        }
        return w.bytes
    }

    struct UpdateUserStatRequest: Equatable {
        var statID: UInt64
        var value: StatValue?

        init(_ payload: [UInt8]) throws {
            let f = try GalaxyFields(payload)
            guard let id = f.fixed64(1) else { throw GalaxyProto.Malformed() }
            statID = id
            switch f.uint(2) {
            case 1: value = .int(f.int32(4) ?? 0)
            case 2: value = .float(f.float(3) ?? 0)
            case 3: value = .avgRate(f.float(3) ?? 0)
            default: value = nil
            }
        }
    }

    struct UserAchievement: Equatable {
        var id: UInt64
        var key: String
        var name: String
        var description: String
        var imageLocked: String
        var imageUnlocked: String
        var visible: Bool
        var unlockTime: UInt32?
        var rarity: Float?
        var rarityDescription: String?
        var raritySlug: String?
    }

    static func userAchievementsResponse(_ items: [UserAchievement], language: String, mode: String?) -> [UInt8] {
        var w = GalaxyProto.Writer()
        for a in items {
            var m = GalaxyProto.Writer()
            m.fixed64(1, a.id)
            m.string(2, a.key)
            m.string(3, a.name)
            m.string(4, a.description)
            m.string(5, a.imageLocked)
            m.string(6, a.imageUnlocked)
            m.bool(7, a.visible)
            if let t = a.unlockTime { m.fixed32(8, t) }
            if let r = a.rarity { m.float(9, r) }
            if let d = a.rarityDescription { m.string(10, d) }
            if let s = a.raritySlug { m.string(11, s) }
            w.data(1, m.bytes)
        }
        w.string(2, language)
        if let mode { w.string(3, mode) }
        return w.bytes
    }

    /// UNLOCK_USER_ACHIEVEMENT_REQUEST and CLEAR_USER_ACHIEVEMENT_REQUEST: the ID, and the
    /// unlock's time (seconds since 1970) when the game gives one.
    struct AchievementRequest: Equatable {
        var id: UInt64
        var time: UInt32?

        init(_ payload: [UInt8]) throws {
            let f = try GalaxyFields(payload)
            guard let id = f.fixed64(1) else { throw GalaxyProto.Malformed() }
            self.id = id
            time = f.fixed32(2)
        }
    }

    struct Leaderboard: Equatable {
        var id: UInt64
        var key: String
        var name: String
        /// 1 ascending, 2 descending.
        var sortMethod: UInt64
        /// 1 numeric, 2 seconds, 3 milliseconds.
        var displayType: UInt64
    }

    static func leaderboardsResponse(_ boards: [Leaderboard]) -> [UInt8] {
        var w = GalaxyProto.Writer()
        for b in boards {
            var m = GalaxyProto.Writer()
            m.fixed64(1, b.id)
            m.string(2, b.key)
            m.string(3, b.name)
            m.uint(4, b.sortMethod)
            m.uint(5, b.displayType)
            w.data(1, m.bytes)
        }
        return w.bytes
    }

    struct LeaderboardEntry: Equatable {
        var rank: UInt32
        var score: UInt32
        var userID: UInt64
        var details: [UInt8]?
    }

    static func leaderboardEntriesResponse(_ entries: [LeaderboardEntry], total: UInt32) -> [UInt8] {
        var w = GalaxyProto.Writer()
        for e in entries {
            var m = GalaxyProto.Writer()
            m.uint(1, UInt64(e.rank))
            m.uint(2, UInt64(e.score))
            m.fixed64(3, userEntity(e.userID))
            if let d = e.details { m.data(4, d) }
            w.data(1, m.bytes)
        }
        w.uint(2, UInt64(total))
        return w.bytes
    }

    struct SetLeaderboardScoreRequest: Equatable {
        var leaderboardID: UInt64
        var score: Int32
        var force: Bool
        var details: [UInt8]?

        init(_ payload: [UInt8]) throws {
            let f = try GalaxyFields(payload)
            guard let id = f.fixed64(1), let score = f.int32(2) else { throw GalaxyProto.Malformed() }
            leaderboardID = id
            self.score = score
            force = f.bool(3) ?? false
            details = f.data(4)
        }
    }

    static func setLeaderboardScoreResponse(score: Int32, oldRank: UInt32, newRank: UInt32, total: UInt32) -> [UInt8] {
        var w = GalaxyProto.Writer()
        w.int(1, score)
        w.uint(2, UInt64(oldRank))
        w.uint(3, UInt64(newRank))
        w.uint(4, UInt64(total))
        return w.bytes
    }

    static func createLeaderboardResponse(id: UInt64) -> [UInt8] {
        var w = GalaxyProto.Writer()
        w.fixed64(1, id)
        return w.bytes
    }

    static func timePlayedResponse(_ seconds: UInt32) -> [UInt8] {
        var w = GalaxyProto.Writer()
        w.uint(1, UInt64(seconds))
        return w.bytes
    }

    static func subscribeTopicResponse(_ topic: String) -> [UInt8] {
        var w = GalaxyProto.Writer()
        w.string(1, topic)
        return w.bytes
    }
}
