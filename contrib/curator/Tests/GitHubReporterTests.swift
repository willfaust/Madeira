// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import XCTest
@testable import Triptych

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    static var seen: [(url: String, headers: [String: String], body: Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 65_536)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
        }
        Self.seen.append((request.url!.absoluteString, request.allHTTPHeaderFields ?? [:], body))
        var (status, headers, data) = Self.handler?(request) ?? (500, [:], Data())
        // The relay hands out a proof-of-work challenge first; tests that don't care get a valid one.
        if request.url?.path == "/challenge", !String(decoding: data, as: UTF8.self).contains("\"challenge\"") {
            let c = "1700000000.00000000-0000-0000-0000-000000000000." + String(repeating: "A", count: 43)
            (status, headers, data) = (200, [:], try! JSONSerialization.data(withJSONObject: ["challenge": c, "difficulty": 20]))
            Self.seen.removeLast() // not part of what these tests check
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MemoryTokenStore: TokenStore {
    var credentials: GitHubCredentials?
    var token: String? {
        get { credentials?.accessToken }
        set { credentials = newValue.map { GitHubCredentials(accessToken: $0) } }
    }
    func save(_ credentials: GitHubCredentials) throws { self.credentials = credentials }
    func delete() { credentials = nil }
}

final class GitHubReporterTests: XCTestCase {
    typealias R = GitHubReporter.ReporterError
    var store = MemoryTokenStore()

    override func setUp() {
        StubURLProtocol.handler = nil
        StubURLProtocol.seen = []
        store = MemoryTokenStore()
    }

    private func reporter(clientID: String = "cid", relay: String? = "https://relay.example/report") -> GitHubReporter {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return GitHubReporter(config: .init(clientID: clientID, issueRepo: "RageMC/triptych", relayURL: relay.flatMap(URL.init(string:))),
                              session: URLSession(configuration: cfg), store: store, sleep: { _ in })
    }

    private func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }
    private func bodyJSON(_ i: Int) -> [String: Any] { try! JSONSerialization.jsonObject(with: StubURLProtocol.seen[i].body) as! [String: Any] }

    func testConfigFromInfoPlist() {
        XCTAssertEqual(GitHubReporter.Config(info: [:]), .init(clientID: "", issueRepo: "RageMC/triptych-issues", relayURL: nil))
        let c = GitHubReporter.Config(info: ["TriptychGitHubClientID": "abc", "TriptychIssueRepo": "o/r",
                                             "TriptychReportRelayURL": "https://x.example/r"])
        XCTAssertEqual(c.clientID, "abc"); XCTAssertEqual(c.issueRepo, "o/r"); XCTAssertEqual(c.relayURL?.host, "x.example")
        XCTAssertNil(GitHubReporter.Config(info: ["TriptychReportRelayURL": "http://insecure.example"]).relayURL)
    }

    func testDeviceFlowSlowDownThenToken() async throws {
        var polls = 0
        StubURLProtocol.handler = { req in
            if req.url!.path == "/login/device/code" {
                return (200, [:], self.json(["device_code": "dc", "user_code": "WDJB-MJHT",
                                              "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5]))
            }
            polls += 1
            switch polls {
            case 1: return (200, [:], self.json(["error": "authorization_pending"]))
            case 2: return (200, [:], self.json(["error": "slow_down", "interval": 10]))
            default: return (200, [:], self.json(["access_token": "gho_tok", "refresh_token": "refresh", "expires_in": 3600]))
            }
        }
        let r = reporter()
        let code = try await r.startDeviceFlow()
        XCTAssertEqual(code.userCode, "WDJB-MJHT")
        XCTAssertTrue(String(decoding: StubURLProtocol.seen[0].body, as: UTF8.self).contains("client_id=cid"))
        try await r.pollForToken(code)
        XCTAssertEqual(store.token, "gho_tok")
        XCTAssertEqual(store.credentials?.refreshToken, "refresh")
        XCTAssertNotNil(store.credentials?.expiresAt)
        XCTAssertTrue(r.isSignedIn)
        r.signOut()
        XCTAssertFalse(r.isSignedIn)
    }

    func testDeviceFlowDeniedAndNoClientID() async {
        StubURLProtocol.handler = { _ in (200, [:], self.json(["error": "access_denied"])) }
        let code = GitHubReporter.DeviceCode(deviceCode: "d", userCode: "u", verificationURI: URL(string: "https://github.com/login/device")!, expiresIn: 900, interval: 5)
        do { try await reporter().pollForToken(code); XCTFail() } catch { XCTAssertEqual(error as? R, .deviceFlowDenied) }
        do { _ = try await reporter(clientID: "").startDeviceFlow(); XCTFail() } catch { XCTAssertEqual(error as? R, .oauthUnavailable) }
        XCTAssertThrowsError(try reporter().savePersonalAccessToken("  ")) { XCTAssertEqual($0 as? R, .invalidToken) }
        XCTAssertNoThrow(try reporter().savePersonalAccessToken(" github_pat_abc123 "))
        XCTAssertEqual(store.token, "github_pat_abc123")
    }

    func testCreateIssueWithSecretGist() async throws {
        store.token = "tok"
        StubURLProtocol.handler = { req in
            req.url!.path == "/gists"
                ? (201, [:], self.json(["html_url": "https://gist.github.com/u/1"]))
                : (201, [:], self.json(["html_url": "https://github.com/RageMC/triptych/issues/7"]))
        }
        let url = try await reporter().createIssue(title: "T", body: String(repeating: "x", count: 100_000), labels: ["bug"], logText: "log line")
        XCTAssertEqual(url.absoluteString, "https://github.com/RageMC/triptych/issues/7")
        XCTAssertEqual(StubURLProtocol.seen[0].url, "https://api.github.com/gists")
        XCTAssertEqual(bodyJSON(0)["public"] as? Bool, false)
        XCTAssertEqual(StubURLProtocol.seen[1].url, "https://api.github.com/repos/RageMC/triptych/issues")
        XCTAssertEqual(StubURLProtocol.seen[1].headers["Authorization"], "Bearer tok")
        let issue = bodyJSON(1)
        let body = issue["body"] as! String
        XCTAssertLessThanOrEqual(body.count, GitHubReporter.issueBodyLimit)
        XCTAssertTrue(body.contains("https://gist.github.com/u/1"))
        XCTAssertTrue(body.contains("truncated"))
        XCTAssertEqual(issue["labels"] as? [String], ["bug"])
    }

    func testRefreshesBeforeExpiry() async throws {
        store.credentials = .init(accessToken: "old", refreshToken: "old-refresh",
                                  expiresAt: Date().addingTimeInterval(20))
        stubRefreshAndIssue()
        _ = try await reporter().createIssue(title: "T", body: "B", labels: [], logText: nil)
        XCTAssertEqual(StubURLProtocol.seen.count, 2)
        assertRotation(refreshRequest: 0)
        XCTAssertEqual(StubURLProtocol.seen[1].headers["Authorization"], "Bearer new")
    }

    func testRefreshesOnUnauthorizedWithoutRecreatingGist() async throws {
        store.credentials = .init(accessToken: "old", refreshToken: "old-refresh")
        stubRefreshAndIssue()
        _ = try await reporter().createIssue(title: "T", body: "B", labels: [], logText: "L")
        let requests = StubURLProtocol.seen
        XCTAssertEqual(requests.map { URL(string: $0.url)?.path }, [
            "/gists", "/repos/RageMC/triptych/issues", "/login/oauth/access_token", "/repos/RageMC/triptych/issues"
        ])
        assertRotation(refreshRequest: 2)
        XCTAssertEqual(requests[3].headers["Authorization"], "Bearer new")
        XCTAssertEqual(requests[1].body, requests[3].body)
    }

    func testStopsAfterSecondUnauthorized() async {
        store.credentials = .init(accessToken: "old", refreshToken: "old-refresh")
        stubRefreshAndIssue(acceptNewToken: false)
        do { _ = try await reporter().accountLogin(); XCTFail("Expected invalid credentials") }
        catch { XCTAssertEqual(error as? R, .unauthorized) }
        XCTAssertEqual(StubURLProtocol.seen.count, 3)
        XCTAssertNil(store.credentials)
    }

    private func stubRefreshAndIssue(acceptNewToken: Bool = true) {
        StubURLProtocol.handler = { req in
            switch req.url!.path {
            case "/login/oauth/access_token":
                return (200, [:], self.json(["access_token": "new", "refresh_token": "new-refresh",
                                             "expires_in": 3600, "refresh_token_expires_in": 86400]))
            case "/gists":
                return (201, [:], self.json(["html_url": "https://gist.github.com/u/1"]))
            default:
                if acceptNewToken && req.value(forHTTPHeaderField: "Authorization") == "Bearer new" {
                    return (201, [:], self.json(["html_url": "https://github.com/RageMC/triptych/issues/7"]))
                }
                return (401, [:], self.json(["message": "Bad credentials"]))
            }
        }
    }

    private func assertRotation(refreshRequest index: Int) {
        XCTAssertEqual(String(decoding: StubURLProtocol.seen[index].body, as: UTF8.self),
                       "client_id=cid&grant_type=refresh_token&refresh_token=old-refresh")
        XCTAssertEqual(store.credentials?.accessToken, "new")
        XCTAssertEqual(store.credentials?.refreshToken, "new-refresh")
        XCTAssertNotNil(store.credentials?.refreshExpiresAt)
    }

    func testIssueRequiresSignIn() async {
        do { _ = try await reporter().createIssue(title: "t", body: "b", labels: [], logText: nil); XCTFail() }
        catch { XCTAssertEqual(error as? R, .notSignedIn) }
    }

    func testRateLimitAndErrorMessages() async {
        store.token = "tok"
        StubURLProtocol.handler = { _ in (403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "4102444800"], self.json(["message": "API rate limit exceeded"])) }
        do { _ = try await reporter().createIssue(title: "t", body: "b", labels: [], logText: nil); XCTFail() }
        catch {
            guard case .rateLimited(let when)? = error as? R else { return XCTFail("\(error)") }
            XCTAssertEqual(when, Date(timeIntervalSince1970: 4102444800))
            XCTAssertTrue(error.localizedDescription.contains("limiting"))
        }
        StubURLProtocol.handler = { _ in (404, [:], self.json(["message": "Not Found"])) }
        do { _ = try await reporter().createIssue(title: "t", body: "b", labels: [], logText: nil); XCTFail() }
        catch { XCTAssertEqual(error as? R, .notFound("RageMC/triptych")) }
        StubURLProtocol.handler = { _ in (401, [:], self.json(["message": "Bad credentials"])) }
        do { _ = try await reporter().createIssue(title: "t", body: "b", labels: [], logText: nil); XCTFail() }
        catch { XCTAssertEqual(error as? R, .unauthorized); XCTAssertNil(store.token) }
    }

    func testAnonymousRelay() async throws {
        let challenge = "1700000000.00000000-0000-0000-0000-000000000000." + String(repeating: "A", count: 43)
        StubURLProtocol.handler = { req in
            if req.url?.path == "/challenge" {
                return (200, [:], self.json(["challenge": challenge, "difficulty": 20]))
            }
            return (201, [:], self.json(["url": "https://github.com/RageMC/triptych-issues/issues/3"]))
        }
        let previous = CuratorUploadBridge.reporter
        defer { CuratorUploadBridge.reporter = previous }
        CuratorUploadBridge.reporter = reporter()
        let signature = CrashSignature(engine: "casement", targetExe: "unknown", canonicalCrashLine: "known-crash")
        let url = try await CuratorUploadBridge.submit(
            IssueDraft(title: "T", body: "B", labels: ["curator"], logZipURL: nil, crashSignature: signature),
            anonymous: true)
        XCTAssertEqual(url.lastPathComponent, "3")
        XCTAssertEqual(StubURLProtocol.seen.map(\.url), ["https://relay.example/challenge", "https://relay.example/report"])
        let headers = StubURLProtocol.seen[1].headers
        XCTAssertNil(headers["Authorization"])
        XCTAssertEqual(headers["X-Curator-Challenge"], challenge)
        let nonce = try XCTUnwrap(headers["X-Curator-Nonce"])
        let hash = Array(SHA256.hash(data: Data((challenge + ":" + nonce).utf8)))
        XCTAssertEqual(Array(hash.prefix(2)), [0, 0])
        XCTAssertLessThan(hash[2], 16)
        XCTAssertEqual((bodyJSON(1)["signature"] as? [String: String])?["canonicalCrashLine"], "known-crash")
        do { _ = try await reporter(relay: nil).relayChallenge(); XCTFail() }
        catch { XCTAssertEqual(error as? R, .relayDisabled) }
    }

    // MARK: Bridge

    private func storedZip(_ name: String, _ text: String) -> Data {
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        let n = Array(name.utf8), c = Array(text.utf8)
        var local: [UInt8] = le(0x0403_4B50, 4) + le(20, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(0, 4)
        local += le(c.count, 4) + le(c.count, 4) + le(n.count, 2) + le(0, 2) + n + c
        var central: [UInt8] = le(0x0201_4B50, 4) + le(20, 2) + le(20, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(0, 4)
        central += le(c.count, 4) + le(c.count, 4) + le(n.count, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(0, 4) + n
        let eocd: [UInt8] = le(0x0605_4B50, 4) + le(0, 2) + le(0, 2) + le(1, 2) + le(1, 2) + le(central.count, 4) + le(local.count, 4) + le(0, 2)
        return Data(local + central + eocd)
    }

    func testBridgeScrubsEverythingIncludingZippedLogs() async throws {
        store.token = "tok"
        StubURLProtocol.handler = { req in
            req.url!.path == "/gists"
                ? (201, [:], self.json(["html_url": "https://gist.github.com/u/9"]))
                : (201, [:], self.json(["html_url": "https://github.com/RageMC/triptych/issues/9"]))
        }
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).zip")
        try storedZip("Triptych-qemu.log", "opened /Users/jdoeuser/g.img from 203.0.113.9").write(to: zip)
        defer { try? FileManager.default.removeItem(at: zip) }
        let previous = CuratorUploadBridge.reporter
        defer { CuratorUploadBridge.reporter = previous }
        CuratorUploadBridge.reporter = reporter()
        let url = try await CuratorUploadBridge.submit(
            IssueDraft(title: "Crash for me@mail.com", body: "path /Users/jdoeuser/x", labels: ["bug"], logZipURL: zip), anonymous: false)
        XCTAssertEqual(url.lastPathComponent, "9")
        let sent = StubURLProtocol.seen.map { String(decoding: $0.body, as: UTF8.self) }.joined()
        for leak in ["jdoeuser", "203.0.113.9", "me@mail.com"] { XCTAssertFalse(sent.contains(leak), leak) }
        XCTAssertTrue(sent.contains("Triptych-qemu.log"))
        XCTAssertTrue(sent.contains("<user>"))
    }

    private func draft() -> IssueDraft {
        IssueDraft(title: "Crash for me@mail.com", body: "path /Users/jdoeuser/x ip 203.0.113.9", labels: ["curator"], logZipURL: nil)
    }

    func testReviewPreviewIsScrubbedAndMatchesWhatIsSent() async throws {
        let shown = CuratorUploadBridge.scrubbed(draft())
        for leak in ["jdoeuser", "203.0.113.9", "me@mail.com"] { XCTAssertFalse((shown.title + shown.body).contains(leak), leak) }
        StubURLProtocol.handler = { _ in (200, [:], self.json(["url": "https://github.com/RageMC/triptych/issues/4"])) }
        CuratorUploadBridge.reporter = reporter()
        _ = try await CuratorUploadBridge.submit(draft(), anonymous: true)
        XCTAssertEqual(bodyJSON(0)["title"] as? String, shown.title)
        XCTAssertTrue((bodyJSON(0)["body"] as? String ?? "").hasPrefix(shown.body))
    }

    func testAnonymousModeNeverSendsStoredToken() async throws {
        store.token = "gho_secret"
        StubURLProtocol.handler = { _ in (200, [:], self.json(["url": "https://github.com/RageMC/triptych/issues/5"])) }
        CuratorUploadBridge.reporter = reporter()
        _ = try await CuratorUploadBridge.submit(draft(), anonymous: true)
        XCTAssertEqual(StubURLProtocol.seen.map(\.url), ["https://relay.example/report"])
        for hit in StubURLProtocol.seen {
            XCTAssertNil(hit.headers["Authorization"])
            XCTAssertFalse(String(decoding: hit.body, as: UTF8.self).contains("gho_secret"))
        }
    }

    func testSignedInModeUsesStoredTokenAndNeverTheRelay() async throws {
        store.token = "gho_secret"
        CuratorUploadBridge.reporter = reporter()
        XCTAssertTrue(CuratorUploadBridge.signedIn)
        StubURLProtocol.handler = { _ in (201, [:], self.json(["html_url": "https://github.com/RageMC/triptych/issues/6"])) }
        let url = try await CuratorUploadBridge.submit(draft(), anonymous: false)
        XCTAssertEqual(url.lastPathComponent, "6")
        XCTAssertEqual(StubURLProtocol.seen.count, 1)
        XCTAssertEqual(StubURLProtocol.seen[0].url, "https://api.github.com/repos/RageMC/triptych/issues")
        XCTAssertEqual(StubURLProtocol.seen[0].headers["Authorization"], "Bearer gho_secret")
        store.token = nil
        XCTAssertFalse(CuratorUploadBridge.signedIn)
    }

    func testFailureThenRetrySucceeds() async throws {
        var calls = 0
        StubURLProtocol.handler = { req in
            if req.url?.path == "/challenge" { return (200, [:], Data()) } // answered by the stub
            calls += 1
            return calls == 1 ? (503, [:], self.json(["message": "down"])) : (200, [:], self.json(["url": "https://github.com/RageMC/triptych/issues/7"]))
        }
        CuratorUploadBridge.reporter = reporter()
        do { _ = try await CuratorUploadBridge.submit(draft(), anonymous: true); XCTFail() }
        catch { XCTAssertEqual(error as? R, .server(503, "down")) }
        let url = try await CuratorUploadBridge.submit(draft(), anonymous: true)
        XCTAssertEqual(url.lastPathComponent, "7")
    }

    func testNetworkErrorSurfacesAsNetworkFailure() async {
        StubURLProtocol.handler = nil
        CuratorUploadBridge.reporter = reporter(relay: nil)
        do { _ = try await CuratorUploadBridge.submit(draft(), anonymous: true); XCTFail() }
        catch { XCTAssertEqual(error as? R, .relayDisabled) }
    }
}
