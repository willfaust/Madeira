// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import GameBrowserKit

final class UrlOpenRequestTests: XCTestCase {
    func testEpicActivationNeedsTheMeasuredForm() {
        let r = UrlOpenRequest.classify("https://www.epicgames.com/activate?userCode=ABCD1234")
        XCTAssertEqual(r?.kind, .epicActivation)
        XCTAssertEqual(r?.host, "www.epicgames.com")
        XCTAssertEqual(r?.logLabel, "www.epicgames.com/activate")
        XCTAssertEqual(UrlOpenRequest.classify("HTTPS://WWW.EPICGAMES.COM/activate?userCode=X")?.kind, .epicActivation)
        // Without the code, over http, another path or another host: an ordinary page.
        XCTAssertEqual(UrlOpenRequest.classify("https://www.epicgames.com/activate")?.kind, .web)
        XCTAssertEqual(UrlOpenRequest.classify("https://www.epicgames.com/activate?userCode=")?.kind, .web)
        XCTAssertEqual(UrlOpenRequest.classify("http://www.epicgames.com/activate?userCode=X")?.kind, .web)
        XCTAssertEqual(UrlOpenRequest.classify("https://www.epicgames.com/id/login?userCode=X")?.kind, .web)
        XCTAssertEqual(UrlOpenRequest.classify("https://epicgames.com/activate?userCode=X")?.kind, .web)
        XCTAssertEqual(UrlOpenRequest.classify("https://www.epicgames.com.evil.example/activate?userCode=X")?.kind, .web)
        XCTAssertEqual(UrlOpenRequest.classify("https://www.epicgames.com:8443/activate?userCode=X")?.kind, .web)
    }

    func testOtherPagesAndRefusals() {
        let r = UrlOpenRequest.classify("http://example.com/news?x=1#top")
        XCTAssertEqual(r?.kind, .web)
        XCTAssertEqual(r?.logLabel, "example.com/news", "the query and fragment stay out of the log")
        XCTAssertEqual(UrlOpenRequest.classify("https://example.com")?.logLabel, "example.com/")
        XCTAssertNil(UrlOpenRequest.classify(""))
        XCTAssertNil(UrlOpenRequest.classify("file:///C:/windows/system32/cmd.exe"))
        XCTAssertNil(UrlOpenRequest.classify("javascript:alert(1)"))
        XCTAssertNil(UrlOpenRequest.classify("https:///nohost"))
        XCTAssertNil(UrlOpenRequest.classify("https://user:pass@example.com/"))
        XCTAssertNil(UrlOpenRequest.classify("https://user@www.epicgames.com/activate?userCode=X"))
        XCTAssertNil(UrlOpenRequest.classify("https://example.com/" + String(repeating: "a", count: 2048)))
        XCTAssertNotNil(UrlOpenRequest.classify("https://example.com/" + String(repeating: "a", count: 2047 - 20)))
    }

    func testEpicSignInURLCarriesThePageWhole() throws {
        let r = try XCTUnwrap(UrlOpenRequest.classify("https://www.epicgames.com/activate?userCode=AB+CD&x=1"))
        let u = try XCTUnwrap(r.epicSignInURL(exchangeCode: "0123abcd"))
        XCTAssertEqual(u.absoluteString, "https://www.epicgames.com/id/exchange?exchangeCode=0123abcd"
                       + "&redirectUrl=https%3A%2F%2Fwww.epicgames.com%2Factivate%3FuserCode%3DAB%2BCD%26x%3D1")
        let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["exchangeCode", "redirectUrl"])
        XCTAssertEqual(items.last?.value, "https://www.epicgames.com/activate?userCode=AB+CD&x=1")
    }

    func testRate() {
        var rate = UrlOpenRate(spacing: 5, perPlay: 3)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(rate.take(at: t0, sheetUp: false))
        XCTAssertEqual(rate.take(at: t0.addingTimeInterval(10), sheetUp: true), .sheetUp)
        XCTAssertEqual(rate.take(at: t0.addingTimeInterval(4), sheetUp: false), .tooSoon)
        XCTAssertNil(rate.take(at: t0.addingTimeInterval(5), sheetUp: false))
        XCTAssertNil(rate.take(at: t0.addingTimeInterval(10), sheetUp: false))
        XCTAssertEqual(rate.take(at: t0.addingTimeInterval(100), sheetUp: false), .playLimit)
        XCTAssertEqual(rate.opened, 3)
    }
}
