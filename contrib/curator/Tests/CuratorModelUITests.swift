// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// Runs Curator's on-device model on a real (scrubbed) device log. Opt-in because it needs the model:
///   TEST_RUNNER_CURATOR_MODEL_BACKEND=apple|fallback  TEST_RUNNER_CURATOR_SAMPLE_LOG=<path to a log on this Mac>
/// With "fallback" the test downloads Qwen3-0.6B through the Setup screen first (397 MB from Hugging Face).
final class CuratorModelUITests: XCTestCase {
    func testOnDeviceModelSuggestsFixForRealLog() throws {
        let env = ProcessInfo.processInfo.environment
        let backend = env["CURATOR_MODEL_BACKEND"] ?? ""
        let sample = env["CURATOR_SAMPLE_LOG"] ?? ""
        try XCTSkipIf(backend.isEmpty || sample.isEmpty, "set TEST_RUNNER_CURATOR_MODEL_BACKEND and TEST_RUNNER_CURATOR_SAMPLE_LOG")

        let app = XCUIApplication()
        app.launchEnvironment["TRIPTYCH_CURATOR_BACKEND"] = backend
        app.launchEnvironment["TRIPTYCH_CURATOR_SAMPLE_LOG"] = sample
        app.launch()

        if backend == "fallback" {
            app.buttons["home-toolbar-settings"].tap()
            let setup = app.buttons["settings-open-setup"]
            for _ in 0..<6 where !setup.isHittable { app.swipeUp() }
            setup.tap()
            let download = app.buttons["Download Model"]
            let ready = app.staticTexts["Ready to use"]
            for _ in 0..<4 where !download.exists && !ready.exists { app.swipeUp() }
            if download.exists {
                download.tap()
                snap(app, "curator-model-downloading")
            }
            XCTAssertTrue(ready.waitForExistence(timeout: 900), "Qwen download did not finish")
            snap(app, "curator-model-ready")
            app.terminate()
            app.launch()
        }

        let open = app.buttons["open-curator"]
        for _ in 0..<5 where !open.isHittable { app.swipeUp() }
        open.tap()
        XCTAssertTrue(app.navigationBars["Curator"].waitForExistence(timeout: 10))
        app.buttons["curator-check"].tap()
        let fix = app.descendants(matching: .any)["curator-suggested-fix"]
        XCTAssertTrue(fix.waitForExistence(timeout: 300), "no on-device suggestion")
        for _ in 0..<5 where !fix.isHittable { app.swipeUp() }
        snap(app, "curator-\(backend)-suggested-fix")
        let summary = app.staticTexts["curator-model-summary"]
        XCTAssertFalse(summary.label.isEmpty)
        print("CURATOR_RESULT backend=\(backend) summary=\(summary.label) fix=\(fix.label)")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
