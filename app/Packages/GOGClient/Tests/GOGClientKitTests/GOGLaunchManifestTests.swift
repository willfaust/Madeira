import XCTest
@testable import GOGClientKit

final class GOGLaunchManifestTests: XCTestCase {
    func testNestedQuotesAndPercentSignsStayLiteral() throws {
        let arguments = "/q /c:\"setup.exe /q\" --name=100%"
        let data = try GOGLaunchManifest.make(executable: "bin/game.exe", arguments: arguments,
            dependencies: [], support: [], build: "1", workingDirectory: "bin")
        XCTAssertNotNil(data.range(of: "bin".data(using: .utf16LittleEndian)!))
        XCTAssertEqual(data.prefix(4), Data([1, 0, 0, 0]))
        XCTAssertNotNil(data.range(of: arguments.data(using: .utf16LittleEndian)!))
        XCTAssertNotNil(data.range(of: "bin\\game.exe".data(using: .utf16LittleEndian)!))
    }
    func testTraversalAndNulAreRefused() {
        XCTAssertThrowsError(try GOGLaunchManifest.make(executable: "../other.exe", arguments: "", dependencies: [], support: [], build: "1"))
        XCTAssertThrowsError(try GOGLaunchManifest.make(executable: "game.exe", arguments: "a\0b", dependencies: [], support: [], build: "1"))
        XCTAssertThrowsError(try GOGLaunchManifest.make(executable: "game.exe", arguments: "", dependencies: [], support: [], build: "1", workingDirectory: "../other"))
    }
}
