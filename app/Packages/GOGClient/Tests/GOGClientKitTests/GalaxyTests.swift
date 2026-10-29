// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import GOGClientKit
@testable import ContentKit

/// The local Galaxy service (decision 0063): the wire, the service against fakes, the socket.
final class GalaxyTests: XCTestCase {
    static let secret = String(repeating: "ab", count: 32)
    static let client = GOGGalaxyClient(clientID: "51234567890123456", clientSecret: Secret(secret))
    static let refreshToken = "game-refresh-" + String(repeating: "7", count: 40)
    static let accessToken = "game-access-" + String(repeating: "5", count: 40)
    static let userID: UInt64 = 48_123_456_789_012_345

    final class Tokens: GalaxyTokenSource, @unchecked Sendable {
        var minted = 0, refreshed = 0
        var fail: ClientError?
        var expiresIn: TimeInterval = 3600
        func gameToken(for client: GOGGalaxyClient) async throws -> GOGGameToken {
            if let fail { throw fail }
            minted += 1
            return GOGGameToken(accessToken: Secret(GalaxyTests.accessToken), refreshToken: Secret(GalaxyTests.refreshToken),
                                expiresAt: Date().addingTimeInterval(expiresIn), userID: String(GalaxyTests.userID))
        }
        func refreshGameToken(_ refreshToken: Secret<String>, for client: GOGGalaxyClient) async throws -> GOGGameToken {
            refreshed += 1
            return GOGGameToken(accessToken: Secret("refreshed-access"), refreshToken: refreshToken,
                                expiresAt: Date().addingTimeInterval(3600), userID: String(GalaxyTests.userID))
        }
    }

    final class HTTP: GalaxyHTTP, @unchecked Sendable {
        struct Call { var method: String; var url: URL; var bearer: String?; var json: [String: Any]? }
        var calls: [Call] = []
        var replies: [String: (Int, String)] = [:]
        func send(_ method: String, _ url: URL, bearer: Secret<String>?, json: [UInt8]?, language: String?) async throws -> (status: Int, body: [UInt8]) {
            calls.append(Call(method: method, url: url, bearer: bearer?.value,
                              json: json.flatMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }))
            let r = replies[method + " " + url.path] ?? (200, "{}")
            return (r.0, Array(r.1.utf8))
        }
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        var logger: Logger { Logger { line in self.lock.withLock { self.all.append(line) } } }
        var text: String { lock.withLock { all.joined(separator: "\n") } }
    }

    func authRequest(id: String = GalaxyTests.client.clientID, secret: String = GalaxyTests.secret, oseq: UInt32 = 1) -> GalaxyFrame {
        var w = GalaxyProto.Writer()
        w.string(1, id)
        w.string(2, secret)
        w.uint(5, 4242)
        return GalaxyFrame(sort: 1, type: 3, oseq: oseq, payload: w.bytes)
    }

    func service(_ tokens: Tokens = Tokens(), _ http: HTTP = HTTP(), _ lines: Lines = Lines()) -> GalaxyService {
        GalaxyService(client: Self.client, tokens: tokens, http: http, log: lines.logger)
    }

    // MARK: wire

    func testAFrameRoundTripsAndWaitsForItsWholeBytes() throws {
        let f = GalaxyFrame(sort: 1, type: 3, oseq: 77, payload: [1, 2, 3])
        let bytes = f.encoded
        XCTAssertNil(try GalaxyFrame.parse(Array(bytes.prefix(1))))
        XCTAssertNil(try GalaxyFrame.parse(Array(bytes.dropLast())), "a frame short of its payload waits")
        let (back, used) = try XCTUnwrap(try GalaxyFrame.parse(bytes + [9, 9]))
        XCTAssertEqual(back, f)
        XCTAssertEqual(used, bytes.count)
        let r = f.reply(type: 4, status: .forbidden)
        let (rb, _) = try XCTUnwrap(try GalaxyFrame.parse(r.encoded))
        XCTAssertEqual(rb.rseq, 77)
        XCTAssertEqual(rb.status, 403)
        XCTAssertNil(f.reply(type: 4).status, "an OK reply leaves the status out")
    }

    func testAMalformedOrOversizedFrameIsRefused() {
        XCTAssertThrowsError(try GalaxyFrame.parse([0, 0])) { XCTAssertEqual($0 as? GalaxyFrame.ParseError, .malformedHeader) }
        XCTAssertThrowsError(try GalaxyFrame.parse([0, 2, 0xFF, 0xFF]))
        var h = GalaxyProto.Writer()
        h.uint(1, 1)
        h.uint(2, 3)
        h.uint(3, UInt64(GalaxyFrame.maxPayload + 1))
        XCTAssertThrowsError(try GalaxyFrame.parse([0, UInt8(h.bytes.count)] + h.bytes)) {
            XCTAssertEqual($0 as? GalaxyFrame.ParseError, .tooLarge(GalaxyFrame.maxPayload + 1))
        }
        XCTAssertThrowsError(try GalaxyProto.decode([0x0A, 0x05, 1]), "a length past the end")
    }

    func testFieldsRoundTripIncludingNegativeInt32AndFixedWidths() throws {
        var w = GalaxyProto.Writer()
        w.int(1, -5)
        w.fixed64(2, 0x0102_0304_0506_0708)
        w.float(3, 1.5)
        w.string(4, "a")
        w.string(4, "b")
        let f = try GalaxyFields(w.bytes)
        XCTAssertEqual(f.int32(1), -5)
        XCTAssertEqual(f.fixed64(2), 0x0102_0304_0506_0708)
        XCTAssertEqual(f.float(3), 1.5)
        XCTAssertEqual(f.strings(4), ["a", "b"])
        XCTAssertEqual(f.string(4), "b")
    }

    // MARK: the service

    func testAuthInfoForTheBuildsClientMintsOnceAndRepliesWithTheToken() async throws {
        let tokens = Tokens(), http = HTTP(), lines = Lines()
        http.replies["GET /users/\(Self.userID)"] = (200, #"{"id":"\#(Self.userID)","username":"Player"}"#)
        let s = service(tokens, http, lines)
        let out = await s.handle(authRequest())
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].type, 58, "the overlay state first")
        XCTAssertEqual(try GalaxyFields(out[0].payload).uint(1), 0, "not supported")
        XCTAssertNil(out[0].rseq)
        XCTAssertEqual(out[1].type, 4)
        XCTAssertEqual(out[1].rseq, 1)
        XCTAssertNil(out[1].status)
        let reply = try GalaxyFields(out[1].payload)
        XCTAssertEqual(reply.string(1), Self.refreshToken)
        XCTAssertEqual(reply.fixed64(3), 2 << 56 | Self.userID)
        XCTAssertEqual(reply.string(4), "Player")
        XCTAssertNil(http.calls.first?.bearer, "the user name is public: no token sent")
        _ = await s.handle(authRequest(oseq: 2))
        XCTAssertEqual(tokens.minted, 1, "one token per play")
        let minted = await s.minted
        XCTAssertTrue(minted)
        XCTAssertFalse(lines.text.contains(Self.refreshToken))
        XCTAssertFalse(lines.text.contains(Self.secret))
        XCTAssertTrue(lines.text.contains("AUTH_INFO"))
    }

    func testAuthInfoForAnotherClientOrGOGsOwnIsRefusedWithoutMinting() async throws {
        let tokens = Tokens()
        let s = service(tokens)
        for f in [authRequest(id: "999"), authRequest(secret: String(repeating: "cd", count: 32)), authRequest(id: GOGAPI.clientID)] {
            let out = await s.handle(f)
            XCTAssertEqual(out.map(\.status), [403])
            XCTAssertFalse(out[0].payload.contains(Array(Self.refreshToken.utf8)[0]))
        }
        XCTAssertEqual(tokens.minted, 0)
    }

    func testAuthInfoWhenGOGRefusesOrIsSignedOut() async throws {
        let tokens = Tokens()
        tokens.fail = .eresult(.accessDenied, context: "GOG game token: HTTP 403")
        let out = await service(tokens).handle(authRequest())
        XCTAssertEqual(out.map(\.status), [403])
        tokens.fail = .notLoggedOn
        let out2 = await service(tokens).handle(authRequest())
        XCTAssertEqual(out2.map(\.status), [401])
        tokens.fail = .transport("offline")
        let out3 = await service(tokens).handle(authRequest())
        XCTAssertEqual(out3.map(\.status), [503])
    }

    func testRequestsBeforeTheSignInAreRefused() async {
        var w = GalaxyProto.Writer()
        w.fixed64(1, 2 << 56 | Self.userID)
        let out = await service().handle(GalaxyFrame(sort: 1, type: 23, oseq: 5, payload: w.bytes))
        XCTAssertEqual(out.map(\.status), [401])
        XCTAssertEqual(out.first?.type, 24)
    }

    func testAchievementsComeFromGameplayWithTheGameAccessToken() async throws {
        let http = HTTP()
        http.replies["GET /clients/\(Self.client.clientID)/users/\(Self.userID)/achievements"] = (200, #"""
        {"total_count":2,"limit":1000,"page_token":"","achievements_mode":"all_visible","items":[
         {"achievement_id":"58123","achievement_key":"FIRST","name":"First","description":"d","visible":true,
          "image_url_locked":"https://l","image_url_unlocked":"https://u","date_unlocked":null,"rarity":12.5,
          "rarity_level_description":"Rare","rarity_level_slug":"rare"},
         {"achievement_id":"58124","achievement_key":"SECOND","name":"Second","description":"","visible":false,
          "image_url_locked":"","image_url_unlocked":"","date_unlocked":"2026-10-07T12:00:00+0000","rarity":1}]}
        """#)
        let s = service(Tokens(), http)
        _ = await s.handle(authRequest())
        var w = GalaxyProto.Writer()
        w.fixed64(1, 2 << 56 | Self.userID)
        let out = await s.handle(GalaxyFrame(sort: 1, type: 23, oseq: 6, payload: w.bytes))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].type, 24)
        XCTAssertNil(out[0].status)
        let call = try XCTUnwrap(http.calls.last)
        XCTAssertEqual(call.method, "GET")
        XCTAssertEqual(call.bearer, Self.accessToken, "the game's access token, never the host's")
        let f = try GalaxyFields(out[0].payload)
        let items = try f.fields.filter { $0.0 == 1 }.map { (_, v) -> GalaxyFields in
            guard case let .bytes(b) = v else { throw GalaxyProto.Malformed() }
            return try GalaxyFields(b)
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].fixed64(1), 58123)
        XCTAssertEqual(items[0].string(2), "FIRST")
        XCTAssertNil(items[0].fixed32(8), "locked: no unlock time")
        XCTAssertEqual(items[1].fixed32(8), 1_791_374_400)
        XCTAssertEqual(items[1].bool(7), false)
        XCTAssertEqual(f.string(3), "all_visible")
    }

    func testStatsUnlocksAndTimePlayedCallGOGAsItsClientDoes() async throws {
        let http = HTTP()
        let base = "/clients/\(Self.client.clientID)/users/\(Self.userID)"
        http.replies["GET \(base)/stats"] = (200, #"{"total_count":1,"items":[{"stat_id":"7","stat_key":"KILLS","type":"int","value":3,"min_value":0,"max_value":100,"increment_only":true,"window":null}]}"#)
        http.replies["GET \(base)/sessions"] = (200, #"{"time_sum":3600}"#)
        let s = service(Tokens(), http)
        _ = await s.handle(authRequest())
        let stats = await s.handle(GalaxyFrame(sort: 1, type: 15, oseq: 7))
        let stat = try GalaxyFields(XCTUnwrap(try GalaxyFields(stats[0].payload).data(1)))
        XCTAssertEqual(stat.fixed64(1), 7)
        XCTAssertEqual(stat.uint(3), 1, "int")
        XCTAssertEqual(stat.int32(5), 3)
        XCTAssertEqual(stat.int32(12), 100)
        XCTAssertEqual(stat.bool(15), true)

        var u = GalaxyProto.Writer()
        u.fixed64(1, 7)
        u.uint(2, 1)
        u.int(4, 4)
        let upd = await s.handle(GalaxyFrame(sort: 1, type: 17, oseq: 8, payload: u.bytes))
        XCTAssertEqual(upd.map(\.type), [18])
        XCTAssertEqual(http.calls.last?.url.path, "\(base)/stats/7")
        XCTAssertEqual(http.calls.last?.json?["value"] as? Int, 4)

        var a = GalaxyProto.Writer()
        a.fixed64(1, 58123)
        a.fixed32(2, 1_791_374_400)
        let unlock = await s.handle(GalaxyFrame(sort: 1, type: 25, oseq: 9, payload: a.bytes))
        XCTAssertEqual(unlock.map(\.type), [26])
        XCTAssertNil(unlock[0].status)
        XCTAssertEqual(http.calls.last?.method, "POST")
        XCTAssertEqual(http.calls.last?.url.path, "\(base)/achievements/58123")
        XCTAssertEqual(http.calls.last?.json?["date_unlocked"] as? String, "2026-10-07T12:00:00+00:00")

        var t = GalaxyProto.Writer()
        t.uint(1, Self.userID)
        let time = await s.handle(GalaxyFrame(sort: 1, type: 43, oseq: 10, payload: t.bytes))
        XCTAssertEqual(try GalaxyFields(time[0].payload).uint(1), 3600)
        let summary = await s.summary
        XCTAssertTrue(summary.contains("UNLOCK_USER_ACHIEVEMENT 1"), summary)
    }

    func testLeaderboardsAndAScoreThatDoesNotImprove() async throws {
        let http = HTTP()
        let c = "/clients/\(Self.client.clientID)"
        http.replies["GET \(c)/leaderboards"] = (200, #"{"items":[{"id":"11","key":"TIME","name":"Best time","sort_method":"asc","display_type":"milliseconds"}]}"#)
        http.replies["GET \(c)/leaderboards/11/entries"] = (200, #"{"items":[{"user_id":"\#(Self.userID)","rank":1,"score":900,"details":"AQI"}],"leaderboard_entry_total_count":5}"#)
        http.replies["POST \(c)/users/\(Self.userID)/leaderboards/11"] = (409, "{}")
        let s = service(Tokens(), http)
        _ = await s.handle(authRequest())
        let boards = await s.handle(GalaxyFrame(sort: 1, type: 31, oseq: 2))
        let b = try GalaxyFields(XCTUnwrap(try GalaxyFields(boards[0].payload).data(1)))
        XCTAssertEqual(b.fixed64(1), 11)
        XCTAssertEqual(b.uint(4), 1)
        XCTAssertEqual(b.uint(5), 3)
        var g = GalaxyProto.Writer()
        g.fixed64(1, 11)
        g.uint(2, 0)
        g.uint(3, 10)
        let entries = await s.handle(GalaxyFrame(sort: 1, type: 33, oseq: 3, payload: g.bytes))
        XCTAssertEqual(entries[0].type, 36)
        XCTAssertEqual(http.calls.last?.url.query, "range_start=0&range_end=10")
        let ef = try GalaxyFields(entries[0].payload)
        let e = try GalaxyFields(XCTUnwrap(ef.data(1)))
        XCTAssertEqual(e.fixed64(3), 2 << 56 | Self.userID)
        XCTAssertEqual(e.data(4), [1, 2])
        XCTAssertEqual(ef.uint(2), 5)
        var sc = GalaxyProto.Writer()
        sc.fixed64(1, 11)
        sc.int(2, 800)
        sc.bool(3, false)
        let set = await s.handle(GalaxyFrame(sort: 1, type: 37, oseq: 4, payload: sc.bytes))
        XCTAssertEqual(set.map(\.status), [409])
    }

    func testAnExpiringAccessTokenIsRefreshedAtTheGamesClient() async throws {
        let tokens = Tokens(), http = HTTP()
        tokens.expiresIn = 60
        let s = service(tokens, http)
        _ = await s.handle(authRequest())
        _ = await s.handle(GalaxyFrame(sort: 1, type: 15, oseq: 2))
        XCTAssertEqual(tokens.refreshed, 1)
        XCTAssertEqual(http.calls.last?.bearer, "refreshed-access")
    }

    func testUnknownMessagesGetNotImplementedAndNotificationsNothing() async {
        let s = service()
        let out = await s.handle(GalaxyFrame(sort: 1, type: 21, oseq: 3))
        XCTAssertEqual(out.map(\.status), [401], "global stats need the sign-in first")
        let other = await s.handle(GalaxyFrame(sort: 1, type: 99, oseq: 4))
        XCTAssertEqual(other.map(\.status), [501])
        let note = await s.handle(GalaxyFrame(sort: 1, type: 99))
        XCTAssertTrue(note.isEmpty)
        let overlay = await s.handle(GalaxyFrame(sort: 3, type: 1, oseq: 5))
        XCTAssertEqual(overlay.map(\.status), [501])
        var t = GalaxyProto.Writer()
        t.string(1, "topic")
        let sub = await s.handle(GalaxyFrame(sort: 2, type: 3, oseq: 6, payload: t.bytes))
        XCTAssertEqual(sub.map(\.type), [4])
        XCTAssertEqual(try? GalaxyFields(sub[0].payload).string(1), "topic")
        let lib = await s.handle(GalaxyFrame(sort: 1, type: 1, oseq: 7))
        XCTAssertEqual(try? GalaxyFields(lib[0].payload).uint(2), 2, "no peer library: UPDATE_FAILED")
    }

    func testTheGameTokenGrantAndTheTokensStayOutOfLogs() {
        let lines = [
            "GET https://auth.gog.com/token?client_id=1&client_secret=\(Self.secret)&grant_type=refresh_token&refresh_token=\(Self.refreshToken)",
            #"{"access_token":"\#(Self.accessToken)","refresh_token":"\#(Self.refreshToken)"}"#,
            "client_secret=\(Self.secret) refresh_token=\(Self.refreshToken)",
        ]
        for l in lines {
            let s = Redactor.scrub(l)
            XCTAssertFalse(s.contains(Self.refreshToken), s)
            XCTAssertFalse(s.contains(Self.secret), s)
            XCTAssertFalse(s.contains(Self.accessToken), s)
        }
    }

    // MARK: the socket

    func dial(_ port: UInt16) throws -> Int32 {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { throw ClientError.transport("connect errno \(errno)") }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    func listener(_ s: GalaxyService) throws -> (GalaxyListener, UInt16) {
        for _ in 0..<20 {
            let port = UInt16.random(in: 40000...60000)
            let l = GalaxyListener(service: s, log: .silent, port: port)
            do {
                try l.start()
                return (l, port)
            } catch {}
        }
        throw ClientError.transport("no free port")
    }

    func testTheSocketAnswersAFrameSplitAcrossWritesAndAPortInUseIsReported() throws {
        let (l, port) = try listener(service())
        defer { l.stop() }
        XCTAssertThrowsError(try GalaxyListener(service: service(), log: .silent, port: port).start()) {
            XCTAssertEqual("\($0)", "127.0.0.1 port in use")
        }
        let fd = try dial(port)
        defer { close(fd) }
        let bytes = authRequest(oseq: 9).encoded
        _ = bytes.prefix(3).withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        usleep(50_000)
        _ = bytes.dropFirst(3).withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        var got: [UInt8] = []
        var frames: [GalaxyFrame] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while frames.count < 2 {
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { break }
            got += chunk[0..<n]
            while let (f, used) = try GalaxyFrame.parse(got) {
                frames.append(f)
                got.removeFirst(used)
            }
        }
        XCTAssertEqual(frames.map(\.type), [58, 4])
        XCTAssertEqual(frames.last?.rseq, 9)
    }

    func testAnOversizedFrameEndsTheConnection() throws {
        let (l, port) = try listener(service())
        defer { l.stop() }
        let fd = try dial(port)
        defer { close(fd) }
        var h = GalaxyProto.Writer()
        h.uint(1, 1)
        h.uint(2, 3)
        h.uint(3, UInt64(GalaxyFrame.maxPayload + 1))
        let bytes = [0, UInt8(h.bytes.count)] + h.bytes
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        var b = [UInt8](repeating: 0, count: 16)
        let n = b.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(n, 0, "closed by the service")
    }
}
