// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import Triptych

final class CuratorFallbackModelTests: XCTestCase {
    func testBackendPriority() {
        func checkFallback() -> Bool {
            XCTFail("Available Apple Intelligence should skip the fallback check")
            return true
        }
        XCTAssertEqual(CuratorModel.selectBackend(appleAvailable: true, fallbackAvailable: checkFallback()), .foundationModels)
        XCTAssertEqual(CuratorModel.selectBackend(appleAvailable: false, fallbackAvailable: true), .fallback)
        XCTAssertEqual(CuratorModel.selectBackend(appleAvailable: false, fallbackAvailable: false), .rules)
    }

    func testRequiresInstalledModelIdleProcessAndEnoughHeadroom() {
        let limit = CuratorFallbackModel.minimumHeadroom
        XCTAssertFalse(CuratorFallbackModel.canLoad(installed: true, engineStarted: false, availableMemory: limit - 1))
        XCTAssertTrue(CuratorFallbackModel.canLoad(installed: true, engineStarted: false, availableMemory: limit))
        XCTAssertFalse(CuratorFallbackModel.canLoad(installed: false, engineStarted: false, availableMemory: limit))
        XCTAssertFalse(CuratorFallbackModel.canLoad(installed: true, engineStarted: true, availableMemory: limit))
    }

    func testDownloadVerificationChecksSizeAndDigest() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try CuratorFallbackModel.verifyModel(at: file, expectedSize: 3, sha256: digest)
        XCTAssertThrowsError(try CuratorFallbackModel.verifyModel(at: file, expectedSize: 4, sha256: digest))
        try Data("abd".utf8).write(to: file)
        XCTAssertThrowsError(try CuratorFallbackModel.verifyModel(at: file, expectedSize: 3, sha256: digest))
    }

    func testParsesSummaryAndMapsFixToRemedy() throws {
        let parsed = try XCTUnwrap(CuratorFallbackModel.parse("Summary: The disk image could not be opened.\nFix: 5"))
        XCTAssertEqual(parsed.summary, "The disk image could not be opened.")
        XCTAssertEqual(parsed.suggestedFix, CuratorModel.remedies[4])
        let loose = try XCTUnwrap(CuratorFallbackModel.parse("Memory ran out.\nFix: free some storage on this device"))
        XCTAssertEqual(loose.summary, "Memory ran out.")
        XCTAssertEqual(loose.suggestedFix, CuratorModel.remedies[3])
        XCTAssertNil(CuratorFallbackModel.parse("Fix: 2"))
    }

    func testUnknownRemedyBecomesReport() {
        XCTAssertEqual(CuratorModel.matchRemedy("Reinstall macOS from the recovery partition"), CuratorModel.remedies.last)
        XCTAssertEqual(CuratorModel.matchRemedy("9"), CuratorModel.remedies.last)
        XCTAssertEqual(CuratorModel.matchRemedy(CuratorModel.remedies[1]), CuratorModel.remedies[1])
    }
}
