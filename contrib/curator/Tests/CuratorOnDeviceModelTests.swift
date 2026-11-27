// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import Triptych

/// Opt-in: runs the selected on-device backend on a log excerpt and checks it returns a summary and a listed remedy.
/// TEST_RUNNER_TRIPTYCH_CURATOR_BACKEND=apple|fallback  TEST_RUNNER_CURATOR_SAMPLE_LOG=<path>
final class CuratorOnDeviceModelTests: XCTestCase {
    func testBackendSummarizesAndSuggestsRemedy() async throws {
        let env = ProcessInfo.processInfo.environment
        let path = env["CURATOR_SAMPLE_LOG"] ?? ""
        try XCTSkipIf(CuratorModel.forcedBackend == nil || path.isEmpty, "opt-in model test")
        let result = Triage.check([(URL(fileURLWithPath: path), "Documents__henge.log")])
        XCTAssertFalse(result.unmatchedExcerpt.isEmpty)
        let summary = await CuratorModel.summarize(result.unmatchedExcerpt)
        let unwrapped = try XCTUnwrap(summary, "backend returned nothing; see the curator lines in triptych.log")
        print("CURATOR_RESULT summary=\(unwrapped.summary) fix=\(unwrapped.suggestedFix)")
        XCTAssertTrue(CuratorModel.remedies.contains(unwrapped.suggestedFix))
    }
}
