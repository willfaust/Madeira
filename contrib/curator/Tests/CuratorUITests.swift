// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

final class CuratorUITests: XCTestCase {
    func testSignsInSendsWithAccountAndSignsOut() {
        let app = openReport(mode: "account")
        XCTAssertFalse(app.buttons["curator-send-anonymous"].exists)
        XCTAssertFalse(app.buttons["curator-send-account"].exists)
        tapReportAction(app.buttons["curator-sign-in"], in: app)
        let code = app.staticTexts["curator-device-code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertEqual(code.label, "TEST-CODE")
        XCTAssertTrue(app.descendants(matching: .any)["Open github.com/login/device"].exists)
        let send = app.buttons["curator-send-account"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["curator-send-mode"].label.hasPrefix("Sending as your signed-in"),
                      "the send mode follows sign-in on the review sheet")
        tapReportAction(send, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["Open GitHub issue"].waitForExistence(timeout: 10))
        app.navigationBars["Review report"].buttons["Done"].tap()
        app.navigationBars["Curator"].buttons["Done"].tap()

        app.buttons["home-toolbar-settings"].tap()
        let status = app.staticTexts["curator-account-status"]
        let signedIn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "@fixture-user"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [signedIn], timeout: 8), .completed)
        app.buttons["curator-sign-out"].tap()
        XCTAssertEqual(status.label, "Signed out")
    }

    func testSendsAnonymouslyWithRelay() {
        let app = openReport(mode: "anonymous")
        XCTAssertFalse(app.buttons["curator-sign-in"].exists)
        XCTAssertFalse(app.buttons["curator-send-account"].exists)
        tapReportAction(app.buttons["curator-send-anonymous"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["Open GitHub issue"].waitForExistence(timeout: 10))
    }

    func testShowsWhenReportingIsUnavailable() {
        let app = openReport(mode: "unconfigured")
        XCTAssertTrue(app.staticTexts["curator-report-unavailable"].exists)
        XCTAssertFalse(app.buttons["curator-sign-in"].exists)
        XCTAssertFalse(app.buttons["curator-send-anonymous"].exists)
        XCTAssertFalse(app.buttons["curator-send-account"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Curator"].waitForExistence(timeout: 5))
    }

    private func openReport(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRIPTYCH_CURATOR_UI_TEST"] = mode
        app.launch()

        let open = app.buttons["open-curator"]
        for _ in 0..<5 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.isHittable)
        open.tap()
        XCTAssertTrue(app.navigationBars["Curator"].waitForExistence(timeout: 5))
        app.buttons["curator-check"].tap()

        let finding = app.staticTexts["curator-finding-jit-required"]
        XCTAssertTrue(finding.waitForExistence(timeout: 15))
        XCTAssertEqual(finding.label, "JIT is off")
        XCTAssertTrue(app.buttons["curator-apply-jit-required"].exists)
        tapReportAction(app.buttons["curator-report-jit-required"], in: app)
        XCTAssertTrue(app.navigationBars["Review report"].waitForExistence(timeout: 15))
        return app
    }

    private func tapReportAction(_ action: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 where !action.isHittable { app.swipeUp() }
        XCTAssertTrue(action.isHittable)
        action.tap()
    }

    private func openReview(stub: String?, localRelay: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TRIPTYCH_CURATOR_UI_TEST"] = "1"
        if let stub { app.launchEnvironment["TRIPTYCH_CURATOR_REPORT_STUB"] = stub }
        if let localRelay { app.launchEnvironment["TRIPTYCH_CURATOR_LOCAL_RELAY"] = localRelay }
        app.launch()
        let open = app.buttons["open-curator"]
        for _ in 0..<5 where !open.isHittable { app.swipeUp() }
        open.tap()
        XCTAssertTrue(app.navigationBars["Curator"].waitForExistence(timeout: 5))
        app.buttons["curator-check"].tap()
        let report = app.buttons["curator-report-jit-required"]
        XCTAssertTrue(report.waitForExistence(timeout: 15))
        for _ in 0..<5 where !report.isHittable { app.swipeUp() }
        report.tap()
        XCTAssertTrue(app.navigationBars["Review report"].waitForExistence(timeout: 15))
        return app
    }

    func testAnonymousReportShowsModeAndSubmits() {
        let app = openReview(stub: "anonymous")
        XCTAssertTrue(app.staticTexts["curator-send-mode"].label.hasPrefix("Sending anonymously"))
        XCTAssertFalse(app.staticTexts["curator-preview-body"].label.contains("/Users/"))
        sendButton(app).tap()
        XCTAssertTrue(app.links["curator-issue-link"].waitForExistence(timeout: 10))
    }

    /// End to end through the real relay Worker under `wrangler dev` (tools/curator-relay/e2e-local.sh).
    /// Skipped unless the script passes the relay URL; the app solves the real Hashcash challenge.
    func testAnonymousReportThroughLocalRelay() throws {
        let relay = ProcessInfo.processInfo.environment["CURATOR_LOCAL_RELAY"] ?? ""
        try XCTSkipIf(relay.isEmpty, "set TEST_RUNNER_CURATOR_LOCAL_RELAY to run against wrangler dev")
        let app = openReview(stub: nil, localRelay: relay)
        XCTAssertTrue(app.staticTexts["curator-send-mode"].label.hasPrefix("Sending anonymously"))
        sendButton(app).tap()
        let link = app.links["curator-issue-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 90))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "curator-local-relay-filed"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSignedInReportShowsModeAndSubmits() {
        let app = openReview(stub: "signedin")
        XCTAssertTrue(app.staticTexts["curator-send-mode"].label.hasPrefix("Sending as your signed-in"))
        sendButton(app).tap()
        XCTAssertTrue(app.links["curator-issue-link"].waitForExistence(timeout: 10))
    }

    func testFailedReportOffersRetry() {
        let app = openReview(stub: "fail-once")
        sendButton(app).tap()
        XCTAssertTrue(app.staticTexts["curator-failure"].waitForExistence(timeout: 10))
        let retry = sendButton(app) // the send buttons stay offered after a failure
        XCTAssertTrue(retry.isEnabled)
        retry.tap()
        XCTAssertTrue(app.links["curator-issue-link"].waitForExistence(timeout: 10))
    }

    /// The report sheet offers "Send with my account" when signed in, else "Send anonymously" when the relay is set.
    private func sendButton(_ app: XCUIApplication) -> XCUIElement {
        let account = app.buttons["curator-send-account"]
        if account.waitForExistence(timeout: 5) { return account }
        let anonymous = app.buttons["curator-send-anonymous"]
        XCTAssertTrue(anonymous.waitForExistence(timeout: 5), "a send button")
        return anonymous
    }
}
