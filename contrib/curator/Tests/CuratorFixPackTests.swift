// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import XCTest
@testable import Triptych

final class CuratorFixPackTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    private func envelope(_ json: String, signedWith signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        let payload = Data(json.utf8)
        let signature = try (signer ?? key).signature(for: payload)
        return try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(), "signature": signature.base64EncodedString()])
    }

    private let cacheFix = #"{"version":1,"fixes":[{"id":"f1","signature":"jit-region","title":"t","summary":"s","changes":[{"key":"henge.perf.codeCacheMB","value":512},{"key":"henge.jit.autoEnable","value":true}]}]}"#

    private func suite() -> UserDefaults {
        let name = "curator-fixpack-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testBundledPackVerifiesWithAppKey() throws {
        let pack = try XCTUnwrap(CuratorFixPack.bundled())
        XCTAssertNotNil(CuratorFixPack.fix(for: "jit-region", in: pack))
        XCTAssertNotNil(CuratorFixPack.fix(for: "jit-required", in: pack))
    }

    func testRejectsWrongKeyAndTamperedPayload() throws {
        let signed = try envelope(cacheFix)
        XCTAssertNoThrow(try CuratorFixPack.verify(signed, publicKeyBase64: publicKey))
        XCTAssertThrowsError(try CuratorFixPack.verify(signed, publicKeyBase64: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())) {
            XCTAssertEqual($0 as? CuratorFixPack.PackError, .badSignature)
        }
        XCTAssertThrowsError(try CuratorFixPack.verify(try envelope(cacheFix, signedWith: Curve25519.Signing.PrivateKey()), publicKeyBase64: publicKey))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: signed) as? [String: String])
        object["payload"] = Data(cacheFix.replacingOccurrences(of: "512", with: "1536").utf8).base64EncodedString()
        XCTAssertThrowsError(try CuratorFixPack.verify(JSONSerialization.data(withJSONObject: object), publicKeyBase64: publicKey)) {
            XCTAssertEqual($0 as? CuratorFixPack.PackError, .badSignature)
        }
        XCTAssertThrowsError(try CuratorFixPack.verify(Data("nope".utf8), publicKeyBase64: publicKey))
    }

    func testRejectsSignedChangeOutsideAllowlist() throws {
        let bad = #"{"version":1,"fixes":[{"id":"x","signature":"s","title":"t","summary":"s","changes":[{"key":"DYLD_INSERT_LIBRARIES","value":1}]}]}"#
        XCTAssertThrowsError(try CuratorFixPack.verify(try envelope(bad), publicKeyBase64: publicKey)) {
            XCTAssertEqual($0 as? CuratorFixPack.PackError, .disallowedChange("DYLD_INSERT_LIBRARIES"))
        }
        let badValue = bad.replacingOccurrences(of: "DYLD_INSERT_LIBRARIES", with: "henge.perf.codeCacheMB").replacingOccurrences(of: ":1}", with: ":9999}")
        XCTAssertThrowsError(try CuratorFixPack.verify(try envelope(badValue), publicKeyBase64: publicKey))
    }

    func testApplyAndRevertRestoresPriorValues() throws {
        let pack = try CuratorFixPack.verify(try envelope(cacheFix), publicKeyBase64: publicKey)
        let fix = try XCTUnwrap(pack.fixes.first)
        let defaults = suite()
        defaults.set(1536, forKey: JITBootstrap.codeCacheKey)
        XCTAssertFalse(CuratorFixPack.isApplied(fix, defaults: defaults))

        CuratorFixPack.apply(fix, defaults: defaults)
        XCTAssertTrue(CuratorFixPack.isApplied(fix, defaults: defaults))
        XCTAssertEqual(defaults.integer(forKey: JITBootstrap.codeCacheKey), 512)
        XCTAssertTrue(defaults.bool(forKey: JITCoordinator.autoEnableKey))

        CuratorFixPack.apply(fix, defaults: defaults)   // a second tap must not overwrite the saved originals
        CuratorFixPack.revert(fix, defaults: defaults)
        XCTAssertFalse(CuratorFixPack.isApplied(fix, defaults: defaults))
        XCTAssertEqual(defaults.integer(forKey: JITBootstrap.codeCacheKey), 1536)
        XCTAssertNil(defaults.object(forKey: JITCoordinator.autoEnableKey))
    }
}
