// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG && targetEnvironment(simulator)
import Foundation

/// UI tests only: answers GitHub and relay requests in-process so the report flow never touches the network.
/// Modes: "anonymous", "signedin", "fail-once" (anonymous; first send fails, the retry succeeds).
final class CuratorReportUITestStub: URLProtocol {
    nonisolated(unsafe) static var failuresLeft = 0

    private final class MemoryStore: TokenStore {
        var credentials: GitHubCredentials?
        init(_ t: String?) { credentials = t.map { GitHubCredentials(accessToken: $0) } }
        func save(_ credentials: GitHubCredentials) throws { self.credentials = credentials }
        func delete() { credentials = nil }
    }

    static func install(mode: String?) {
        guard let mode else { return }
        failuresLeft = mode == "fail-once" ? 1 : 0
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CuratorReportUITestStub.self]
        CuratorUploadBridge.reporter = GitHubReporter(
            config: .init(clientID: "", issueRepo: "RageMC/triptych", relayURL: URL(string: "https://relay.test/report")),
            session: URLSession(configuration: cfg), store: MemoryStore(mode == "signedin" ? "ui-test-token" : nil))
    }

    /// UI tests only: sends anonymous reports to a relay on this Mac (`wrangler dev`), with the real network stack.
    static func installLocalRelay(_ value: String?) {
        guard let value, let url = URL(string: value), url.scheme == "http",
              ["localhost", "127.0.0.1"].contains(url.host ?? "") else { return }
        CuratorUploadBridge.reporter = GitHubReporter(
            config: .init(clientID: "", issueRepo: "RageMC/triptych-issues", relayURL: url),
            session: URLSession(configuration: .ephemeral), store: MemoryStore(nil))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var status = 201
        var body = #"{"html_url":"https://github.com/RageMC/triptych/issues/1","url":"https://github.com/RageMC/triptych/issues/1"}"#
        if request.url?.path == "/challenge" {
            status = 200
            body = #"{"challenge":"1700000000.00000000-0000-0000-0000-000000000000.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","difficulty":20}"#
        } else if request.url?.host == "relay.test", Self.failuresLeft > 0 {
            Self.failuresLeft -= 1
            status = 503
            body = #"{"message":"relay down"}"#
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
