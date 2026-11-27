// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG && targetEnvironment(simulator)
import Foundation

enum CuratorReportingUITestFixture {
    static func install(mode: String) {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [StubURLProtocol.self]
        let config = GitHubReporter.Config(
            clientID: mode == "account" ? "fixture-client" : "",
            relayURL: mode == "anonymous" ? URL(string: "https://relay.example/report") : nil
        )
        CuratorUploadBridge.reporter = GitHubReporter(
            config: config, session: URLSession(configuration: session), store: MemoryStore()
        )
    }

    private final class MemoryStore: TokenStore {
        var credentials: GitHubCredentials?
        func save(_ credentials: GitHubCredentials) throws { self.credentials = credentials }
        func delete() { credentials = nil }
    }

    private final class StubURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            let issue = "https://github.com/RageMC/triptych-issues/issues/42"
            let authenticated = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access"
            let status: Int
            let body: [String: Any]
            switch (url.host, url.path, request.httpMethod) {
            case ("github.com", "/login/device/code", "POST"):
                status = 200
                body = ["device_code": "fixture-device", "user_code": "TEST-CODE",
                        "verification_uri": "https://github.com/login/device", "interval": 4]
            case ("github.com", "/login/oauth/access_token", "POST"):
                status = 200
                body = ["access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 3600]
            case ("api.github.com", "/user", "GET") where authenticated:
                status = 200
                body = ["login": "fixture-user"]
            case ("api.github.com", "/gists", "POST") where authenticated:
                status = 201
                body = ["html_url": "https://gist.github.com/fixture-user/1"]
            case ("api.github.com", "/repos/RageMC/triptych-issues/issues", "POST") where authenticated:
                status = 201
                body = ["html_url": issue]
            case ("relay.example", "/challenge", _):
                status = 200
                body = ["challenge": "1700000000.00000000-0000-0000-0000-000000000000." + String(repeating: "A", count: 43),
                        "difficulty": 20]
            case ("relay.example", "/report", "POST") where request.value(forHTTPHeaderField: "Authorization") == nil:
                status = 200
                body = ["url": issue]
            default:
                status = 500
                body = ["message": "Unexpected request in Curator UI test"]
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}
#endif
