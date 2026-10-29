import XCTest
@testable import GameBrowserKit

final class BrowserRegistryTests: XCTestCase {
    func testIdempotenceAndPreservation() {
        let original = "WINE REGISTRY Version 2\n\n[Software\\\\Classes\\\\mailto\\\\shell\\\\open\\\\command] 0\n@=\"mail.exe\"\n"
        let changed = BrowserRegistry.install(in: original)
        XCTAssertTrue(changed.hasPrefix(original))
        XCTAssertEqual(BrowserRegistry.install(in: changed), changed)
    }
    func testCustomWebHandlerStays() {
        let original = "[Software\\\\Classes\\\\https\\\\shell\\\\open\\\\command] 0\n@=\"custom.exe\"\n"
        let changed = BrowserRegistry.install(in: original)
        XCTAssertTrue(changed.hasPrefix(original))
        XCTAssertEqual(changed.components(separatedBy: "Classes\\\\https").count, 2)
    }
}
