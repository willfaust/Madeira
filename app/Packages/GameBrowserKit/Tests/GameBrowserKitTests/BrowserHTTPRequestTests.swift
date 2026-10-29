import XCTest
@testable import GameBrowserKit

final class BrowserHTTPRequestTests: XCTestCase {
    func request(_ url: String, token: String = "secret", extra: String = "") -> Data {
        Data("POST /\(token) HTTP/1.1\r\nContent-Length: \(url.utf8.count)\r\n\(extra)\r\n\(url)".utf8)
    }
    func testEveryPartialReadWaitsForTheBody() throws {
        let data = request("https://example.com/activate?code=private")
        for n in 0..<data.count { XCTAssertNil(try BrowserHTTPRequest.parse(Data(data.prefix(n)), token: "secret")) }
        XCTAssertEqual(try BrowserHTTPRequest.parse(data, token: "secret")?.host, "example.com")
    }
    func testWrongSessionBrowserOriginsAndUnsafeURLsAreRejected() {
        for data in [request("https://example.com", token: "other"),
                     request("https://example.com", extra: "Origin: https://evil.example\r\n"),
                     request("file:///etc/passwd"), request("https://user:password@example.com"),
                     request("https://example.com", extra: "Content-Length: 1\r\n")] {
            XCTAssertThrowsError(try BrowserHTTPRequest.parse(data, token: "secret"))
        }
    }
}
