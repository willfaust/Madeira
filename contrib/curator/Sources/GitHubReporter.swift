// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// Files Curator reports on GitHub: as the user's own account (OAuth device flow or a pasted fine-grained token)
/// or anonymously through a relay. URLSession only. Callers pass text that is already scrubbed (see CuratorUploadBridge).
struct GitHubReporter {
    struct Config: Equatable {
        var clientID: String
        var issueRepo: String
        var relayURL: URL?

        static let defaultRepo = "OWNER/REPO" // set to your issue tracker

        init(clientID: String = "", issueRepo: String = Config.defaultRepo, relayURL: URL? = nil) {
            self.clientID = clientID
            self.issueRepo = issueRepo
            self.relayURL = relayURL
        }

        init(info: [String: Any]) {
            func str(_ k: String) -> String { ((info[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let repo = str("TriptychIssueRepo")
            let relay = str("TriptychReportRelayURL")
            self.init(clientID: str("TriptychGitHubClientID"),
                      issueRepo: repo.isEmpty ? Config.defaultRepo : repo,
                      relayURL: relay.isEmpty ? nil : URL(string: relay).flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil })
        }

        static func fromBundle(_ bundle: Bundle = .main) -> Config { Config(info: bundle.infoDictionary ?? [:]) }
    }

    enum ReporterError: LocalizedError, Equatable {
        case notSignedIn
        case oauthUnavailable
        case relayChallengeExpired
        case relayDisabled
        case invalidToken
        case deviceFlowDenied
        case deviceCodeExpired
        case rateLimited(retryAfter: Date?)
        case unauthorized
        case notFound(String)
        case rejected(String)
        case server(Int, String)
        case network(String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in with GitHub first, or send the report anonymously."
            case .oauthUnavailable: return "This build has no GitHub sign-in. Paste a fine-grained personal access token instead."
            case .relayChallengeExpired: return "The anonymous reporting challenge expired. Try sending again."
            case .relayDisabled: return "Anonymous reports are not available in this build. Sign in with GitHub to send a report."
            case .invalidToken: return "That token is empty or contains invalid characters."
            case .deviceFlowDenied: return "GitHub sign-in was cancelled. Nothing was sent."
            case .deviceCodeExpired: return "The sign-in code expired. Start again to get a new code."
            case .rateLimited(let when):
                if let when {
                    let f = RelativeDateTimeFormatter()
                    return "GitHub is limiting requests right now. Try again \(f.localizedString(for: when, relativeTo: Date()))."
                }
                return "GitHub is limiting requests right now. Wait a minute and try again."
            case .unauthorized: return "GitHub rejected the saved token, so it was removed. Sign in again."
            case .notFound(let repo): return "GitHub could not find \(repo), or your token has no access to it."
            case .rejected(let m): return "GitHub rejected the report: \(m)"
            case .server(let code, let m): return "GitHub is having trouble (HTTP \(code))\(m.isEmpty ? "" : ": \(m)"). Try again later."
            case .network(let m): return "Could not reach GitHub: \(m)"
            case .badResponse: return "GitHub sent an answer Triptych could not understand."
            }
        }
    }

    struct DeviceCode: Equatable {
        var deviceCode: String
        var userCode: String
        var verificationURI: URL
        var expiresIn: TimeInterval
        var interval: TimeInterval
    }

    static let issueBodyLimit = 65_536
    static let gistContentLimit = 900_000
    static let oauthScope = "public_repo gist"
    static let footer = "\n\n---\n*Submitted via Triptych Curator on iOS (automated diagnostic report confirmed by user).*"

    var config: Config
    var session: URLSession
    var store: TokenStore
    var sleep: (TimeInterval) async throws -> Void
    private let refreshState = RefreshState()

    // GitHub rotates refresh tokens on use, so concurrent calls share the exchange.
    private final class RefreshState {
        @MainActor var pending: (credentials: GitHubCredentials, task: Task<GitHubCredentials, Error>)?
    }

    init(config: Config = .fromBundle(), session: URLSession = .shared, store: TokenStore = KeychainTokenStore(),
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.config = config
        self.session = session
        self.store = store
        self.sleep = sleep
    }

    static let shared = GitHubReporter()

    var isSignedIn: Bool { store.credentials != nil }
    var canSignInWithOAuth: Bool { !config.clientID.isEmpty }
    var anonymousAvailable: Bool { config.relayURL != nil }

    // MARK: Sign in

    func startDeviceFlow() async throws -> DeviceCode {
        guard canSignInWithOAuth else { throw ReporterError.oauthUnavailable }
        var req = request("https://github.com/login/device/code", method: "POST")
        req.httpBody = form(["client_id": config.clientID, "scope": Self.oauthScope])
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, status, headers) = try await send(req)
        let json = try object(data)
        if let err = json["error"] as? String { throw ReporterError.rejected((json["error_description"] as? String) ?? err) }
        try check(status, headers, data)
        guard let dc = json["device_code"] as? String, let uc = json["user_code"] as? String,
              let uri = (json["verification_uri"] as? String).flatMap(URL.init(string:)),
              uri.absoluteString == "https://github.com/login/device" else { throw ReporterError.badResponse }
        return DeviceCode(deviceCode: dc, userCode: uc, verificationURI: uri,
                          expiresIn: (json["expires_in"] as? Double) ?? 900, interval: max((json["interval"] as? Double) ?? 5, 1))
    }

    /// Polls until the user approves in the browser, then stores the token. Honors `slow_down`.
    func pollForToken(_ code: DeviceCode) async throws {
        var interval = code.interval
        var waited: TimeInterval = 0
        while waited < code.expiresIn {
            try await sleep(interval)
            waited += interval
            var req = request("https://github.com/login/oauth/access_token", method: "POST")
            req.httpBody = form(["client_id": config.clientID, "device_code": code.deviceCode,
                                 "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let (data, status, headers) = try await send(req)
            try Task.checkCancellation()
            let json = try object(data)
            if (200..<300).contains(status), let credentials = GitHubCredentials(response: json) {
                try store.save(credentials)
                return
            }
            switch json["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval = max((json["interval"] as? Double) ?? interval + 5, interval + 5)
            case "expired_token": throw ReporterError.deviceCodeExpired
            case "access_denied": throw ReporterError.deviceFlowDenied
            case .some(let e): throw ReporterError.rejected((json["error_description"] as? String) ?? e)
            case .none:
                try check(status, headers, data)
                throw ReporterError.badResponse
            }
        }
        throw ReporterError.deviceCodeExpired
    }

    /// Used when the build has no OAuth client ID: the user pastes a fine-grained personal access token.
    func savePersonalAccessToken(_ raw: String) throws {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.range(of: #"^[A-Za-z0-9_\-]+$"#, options: .regularExpression) != nil else { throw ReporterError.invalidToken }
        try store.save(GitHubCredentials(accessToken: t))
    }

    func signOut() { store.delete() }

    func accountLogin() async throws -> String {
        let data = try await sendAuthenticated(request("https://api.github.com/user", method: "GET"))
        guard let login = try object(data)["login"] as? String, !login.isEmpty else { throw ReporterError.badResponse }
        return login
    }

    @MainActor private func refresh(_ previous: GitHubCredentials) async throws -> GitHubCredentials {
        if let pending = refreshState.pending, pending.credentials == previous {
            return try await pending.task.value
        }
        guard store.credentials == previous else { throw ReporterError.notSignedIn }
        let task = Task { try await exchangeRefreshToken(previous) }
        refreshState.pending = (previous, task)
        defer {
            if refreshState.pending?.credentials == previous { refreshState.pending = nil }
        }
        return try await task.value
    }

    @MainActor private func exchangeRefreshToken(_ previous: GitHubCredentials) async throws -> GitHubCredentials {
        guard let refreshToken = previous.refreshToken, canSignInWithOAuth,
              previous.refreshExpiresAt.map({ $0 > Date() }) ?? true else {
            invalidate(previous)
            throw ReporterError.unauthorized
        }
        var req = request("https://github.com/login/oauth/access_token", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["client_id": config.clientID, "grant_type": "refresh_token", "refresh_token": refreshToken])
        let (data, status, headers) = try await send(req)
        let json = try? object(data)
        if status == 401 || json?["error"] as? String == "bad_refresh_token" {
            invalidate(previous)
            throw ReporterError.unauthorized
        }
        try check(status, headers, data)
        guard let json, let updated = GitHubCredentials(response: json), updated.refreshToken != nil else {
            throw ReporterError.badResponse
        }
        guard store.credentials == previous else { throw ReporterError.notSignedIn }
        try store.save(updated)
        return updated
    }

    private func invalidate(_ credentials: GitHubCredentials) {
        if store.credentials == credentials { store.delete() }
    }

    @MainActor private func sendAuthenticated(_ request: URLRequest, repo: String = "GitHub") async throws -> Data {
        guard var credentials = store.credentials else { throw ReporterError.notSignedIn }
        if credentials.expiresAt.map({ $0.timeIntervalSinceNow <= 60 }) == true, credentials.refreshToken != nil {
            credentials = try await refresh(credentials)
        }
        try Task.checkCancellation()
        var req = request
        req.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        var (data, status, headers) = try await send(req)
        if status == 401 {
            credentials = try await refresh(credentials)
            try Task.checkCancellation()
            req.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            (data, status, headers) = try await send(req)
        }
        if status == 401 { invalidate(credentials) }
        try check(status, headers, data, repo: repo)
        return data
    }

    // MARK: Issues

    /// Creates the issue as the signed-in user. Scrubbed logs go to a secret gist linked from the body.
    func createIssue(title: String, body: String, labels: [String], logText: String?) async throws -> URL {
        var gistLine = ""
        if let log = logText, !log.isEmpty {
            let gist = try await createGist(log: log)
            gistLine = "\n\n**Logs:** \(gist.absoluteString) (secret gist)"
        }
        let full = Self.fit(body, reserving: gistLine + Self.footer) + gistLine + Self.footer
        var req = request("https://api.github.com/repos/\(config.issueRepo)/issues", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["title": title, "body": full, "labels": labels] as [String: Any])
        let data = try await sendAuthenticated(req, repo: config.issueRepo)
        guard let url = (try object(data)["html_url"] as? String).flatMap(URL.init(string:)) else { throw ReporterError.badResponse }
        return url
    }

    private func createGist(log: String) async throws -> URL {
        var req = request("https://api.github.com/gists", method: "POST")
        let content = log.count > Self.gistContentLimit ? "[earlier lines omitted]\n" + String(log.suffix(Self.gistContentLimit)) : log
        let payload: [String: Any] = ["description": "Triptych Curator logs", "public": false,
                                      "files": ["triptych-log.txt": ["content": content]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data = try await sendAuthenticated(req, repo: "gists")
        guard let url = (try object(data)["html_url"] as? String).flatMap(URL.init(string:)) else { throw ReporterError.badResponse }
        return url
    }

    func relayChallenge() async throws -> String {
        guard let relay = config.relayURL else { throw ReporterError.relayDisabled }
        let challengeURL = relay.deletingLastPathComponent().appendingPathComponent("challenge")
        var req = URLRequest(url: challengeURL)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status, headers) = try await send(req)
        try check(status, headers, data, repo: "the report relay")
        let json = try object(data)
        guard json["difficulty"] as? Int == 20, let challenge = json["challenge"] as? String,
              challenge.range(of: #"^[0-9]{10}\.[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil
        else { throw ReporterError.badResponse }
        return challenge
    }

    /// Anonymous mode sends scrubbed text and a single-use proof to the configured relay.
    func submitAnonymously(title: String, body: String, labels: [String], logText: String?,
                           signature: CrashSignature?, challenge: String, nonce: String) async throws -> URL {
        guard let relay = config.relayURL else { throw ReporterError.relayDisabled }
        var req = URLRequest(url: relay)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(challenge, forHTTPHeaderField: "X-Curator-Challenge")
        req.setValue(nonce, forHTTPHeaderField: "X-Curator-Nonce")
        struct Report: Encodable {
            let title: String
            var body: String
            let labels: [String]
            let signature: CrashSignature?
            var log: String? = nil
        }
        let encoder = JSONEncoder()
        var report = Report(title: title, body: body + Self.footer, labels: labels, signature: signature)
        var summary = try encoder.encode(report)
        while summary.count > 32 * 1024 {
            guard report.body.utf8.count > 128 else { throw ReporterError.rejected("The report exceeds the relay size limit.") }
            let end = report.body.utf8.index(report.body.utf8.startIndex,
                                             offsetBy: report.body.utf8.count / 2)
            report.body = String(decoding: report.body.utf8[..<end], as: UTF8.self) + "\n\n[Report truncated]"
            summary = try encoder.encode(report)
        }
        if let logText, !logText.isEmpty {
            report.log = String(decoding: logText.utf8.suffix(768 * 1024), as: UTF8.self)
        }
        req.httpBody = try encoder.encode(report)
        let (data, status, headers) = try await send(req)
        try check(status, headers, data, repo: "the report relay")
        let json = try object(data)
        guard let s = (json["url"] ?? json["html_url"]) as? String, let url = URL(string: s) else { throw ReporterError.badResponse }
        return url
    }

    // MARK: Plumbing

    static func fit(_ body: String, reserving extra: String) -> String {
        let room = issueBodyLimit - extra.count - 1_000
        guard body.count > room else { return body }
        return String(body.prefix(room)) + "\n\n*[report truncated to fit GitHub's size limit]*"
    }

    private func request(_ url: String, method: String) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("Triptych-Curator", forHTTPHeaderField: "User-Agent")
        return r
    }

    private func form(_ f: [String: String]) -> Data {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return f.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: cs) ?? "")" }
            .joined(separator: "&").data(using: .utf8)!
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReporterError.badResponse }
        return o
    }

    private func send(_ req: URLRequest) async throws -> (Data, Int, [AnyHashable: Any]) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw ReporterError.badResponse }
            return (data, http.statusCode, http.allHeaderFields)
        } catch let e as ReporterError {
            throw e
        } catch {
            throw ReporterError.network((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
    }

    private func header(_ h: [AnyHashable: Any], _ name: String) -> String? {
        h.first { ($0.key as? String)?.lowercased() == name.lowercased() }?.value as? String
    }

    private func check(_ status: Int, _ headers: [AnyHashable: Any], _ data: Data, repo: String = "GitHub") throws {
        guard !(200..<300).contains(status) else { return }
        let message = ((try? object(data))?["message"] as? String) ?? ""
        let remaining = header(headers, "x-ratelimit-remaining")
        let limited = status == 429 || (status == 403 && (remaining == "0" || message.localizedCaseInsensitiveContains("rate limit")))
        if limited {
            var when: Date?
            if let ra = header(headers, "retry-after").flatMap(Double.init) { when = Date().addingTimeInterval(ra) }
            else if let reset = header(headers, "x-ratelimit-reset").flatMap(Double.init) { when = Date(timeIntervalSince1970: reset) }
            throw ReporterError.rateLimited(retryAfter: when)
        }
        switch status {
        case 401: throw ReporterError.unauthorized
        case 404: throw ReporterError.notFound(repo)
        case 400, 403, 410, 422: throw ReporterError.rejected(message.isEmpty ? "HTTP \(status)" : message)
        default: throw ReporterError.server(status, message)
        }
    }
}

// MARK: Token storage

struct GitHubCredentials: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var refreshExpiresAt: Date?

    init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, refreshExpiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshExpiresAt = refreshExpiresAt
    }

    init?(response: [String: Any]) {
        guard let token = response["access_token"] as? String, !token.isEmpty else { return nil }
        let now = Date()
        self.init(accessToken: token, refreshToken: response["refresh_token"] as? String,
                  expiresAt: (response["expires_in"] as? Double).map { now.addingTimeInterval($0) },
                  refreshExpiresAt: (response["refresh_token_expires_in"] as? Double).map { now.addingTimeInterval($0) })
    }
}

protocol TokenStore {
    var credentials: GitHubCredentials? { get }
    func save(_ credentials: GitHubCredentials) throws
    func delete()
}

struct KeychainTokenStore: TokenStore {
    var service = "app.triptych.curator.github"
    var account = "token"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    var credentials: GitHubCredentials? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        if let credentials = try? JSONDecoder().decode(GitHubCredentials.self, from: d) { return credentials }
        // Older installs stored a plain access token in this Keychain entry.
        guard let token = String(data: d, encoding: .utf8),
              token.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        return GitHubCredentials(accessToken: token)
    }

    func save(_ credentials: GitHubCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw GitHubReporter.ReporterError.rejected("The Keychain refused to store the token (error \(status)).")
        }
    }

    func delete() { SecItemDelete(query as CFDictionary) }
}
