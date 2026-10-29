// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import ContentKit

final class MD5Tests: XCTestCase {
    func testKnownAnswers() {
        // RFC 1321, A.5.
        XCTAssertEqual(MD5.hash([]).hex, "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5.hash(Array("abc".utf8)).hex, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(MD5.hash(Array("message digest".utf8)).hex, "f96b697d7cb7938d525a2f31aaf161d0")
        XCTAssertEqual(MD5.hash(Array("12345678901234567890123456789012345678901234567890123456789012345678901234567890".utf8)).hex,
                       "57edf4a22be3c955ac49da2e2107b67a")
    }

    func testStreamingMatchesOneShot() {
        let data = (0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        var s = MD5Stream()
        for cut in stride(from: 0, to: data.count, by: 777) { s.update(Array(data[cut..<min(cut + 777, data.count)])) }
        XCTAssertEqual(s.finalize(), MD5.hash(data))
    }
}

/// Chunks by key from memory, checked as a store's source would.
final class MemoryChunks: ContentChunkSource, @unchecked Sendable {
    var data: [[UInt8]: [UInt8]] = [:]
    private let lock = NSLock()
    private var count = 0
    var fetches: Int { lock.withLock { count } }

    func chunk(_ c: ContentChunk) async throws -> [UInt8] {
        lock.withLock { count += 1 }
        guard let plain = data[c.key], c.matches(plain) else { throw ClientError.verificationFailed("chunk") }
        return plain
    }
}

final class SlicedPlanTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("contentkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Two chunks; `a.bin` is chunk 0 then the first half of chunk 1, `b.bin`
    /// is chunk 1's second half (Epic's slices), `c.bin` is chunk 0 whole (GOG's md5).
    func fixture() -> (ContentPlan, MemoryChunks, [String: [UInt8]]) {
        let c0 = Array("0123456789abcdef".utf8), c1 = Array("ABCDEFGHIJKLMNOP".utf8)
        let src = MemoryChunks()
        src.data = [Array("k0".utf8): c0, Array("k1".utf8): c1]
        let chunks = [ContentChunk(key: Array("k0".utf8), size: 16, compressedSize: 16, check: .md5(MD5.hash(c0))),
                      ContentChunk(key: Array("k1".utf8), size: 16, compressedSize: 16, check: .sha1(SHA1.hash(c1)))]
        let a = c0 + c1[0..<8], b = Array(c1[8..<16])
        let files = [
            ContentFile(path: "a.bin", size: 24, hash: .sha1(SHA1.hash(a)),
                        parts: [ContentPart(chunk: 0, length: 16, fileOffset: 0),
                                ContentPart(chunk: 1, offsetInChunk: 0, length: 8, fileOffset: 16)]),
            ContentFile(path: "sub/b.bin", size: 8, hash: .sha1(SHA1.hash(b)),
                        parts: [ContentPart(chunk: 1, offsetInChunk: 8, length: 8, fileOffset: 0)]),
            ContentFile(path: "c.bin", size: 16, hash: .md5(MD5.hash(c0)), parts: [ContentPart(chunk: 0, length: 16, fileOffset: 0)]),
        ]
        return (ContentPlan(files: files, directories: ["empty"], chunks: chunks, identity: SHA1.hash(Array("plan".utf8))),
                src, ["a.bin": a, "sub/b.bin": b, "c.bin": c0])
    }

    func engine(_ src: MemoryChunks, _ configure: (inout InstallEngine.Options) -> Void = { _ in }) -> InstallEngine {
        var o = InstallEngine.Options()
        o.concurrency = 1
        o.flushEveryChunks = 1
        configure(&o)
        var e = InstallEngine(tree: root.appendingPathComponent("tree"), journal: root.appendingPathComponent("j.journal"),
                              source: src, log: .silent, options: o)
        e.freeSpace = { _ in 1 << 40 }
        return e
    }

    func testPartsNumberInFileOrder() {
        let (plan, _, _) = fixture()
        XCTAssertEqual(plan.partCount, 4)
        XCTAssertEqual(plan.files.map(\.firstPart), [0, 2, 3])
        XCTAssertEqual(plan.fileIndex(forPart: 2), 1)
        XCTAssertNil(plan.fileIndex(forPart: 4))
        XCTAssertEqual(plan.totalBytes, 48)
    }

    func testSlicesAndWholeChunksStageOnceEach() async throws {
        let (plan, src, want) = fixture()
        let r = try await engine(src).run(plan)
        for (path, bytes) in want {
            XCTAssertEqual([UInt8](try Data(contentsOf: root.appendingPathComponent("tree/" + path))), bytes, path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("tree/empty").path))
        XCTAssertEqual(src.fetches, 2)
        XCTAssertEqual(r.chunksDownloaded, 2)
        XCTAssertEqual(r.chunksDeduped, 2)
        XCTAssertEqual(r.filesVerified, 3)
    }

    func testAResumeTrustsSlicesAndRehashesWholeChunks() async throws {
        let (plan, src, want) = fixture()
        do {
            _ = try await engine(src) { $0.cancelAfterChunks = 1 }.run(plan)
            XCTFail("expected a pause")
        } catch ClientError.cancelled {}
        let r = try await engine(src).run(plan)
        for (path, bytes) in want {
            XCTAssertEqual([UInt8](try Data(contentsOf: root.appendingPathComponent("tree/" + path))), bytes, path)
        }
        XCTAssertEqual(src.fetches, 2)
        XCTAssertEqual(r.chunksDownloaded, 1)
    }

    func testAPartPastItsChunkIsRefused() async throws {
        var (plan, src, _) = fixture()
        plan.files[1].parts[0].length = 9
        plan.files[1].size = 9
        do {
            _ = try await engine(src).run(plan)
            XCTFail("expected a refusal")
        } catch ClientError.verificationFailed {}
    }

    func testJournalKeysAreTwentyBytes() {
        XCTAssertEqual(ContentPlan.key20([1, 2]).count, 20)
        XCTAssertEqual(ContentPlan.key20([1, 2]).prefix(2), [1, 2])
        XCTAssertEqual(ContentPlan.key20([UInt8](repeating: 7, count: 32)), SHA1.hash([UInt8](repeating: 7, count: 32)))
    }
}

final class RedactorTests: XCTestCase {
    func testStoreTokensAndCodesAreScrubbed() {
        let lines = [
            #"{"access_token":"Abc123def456ghi","refresh_token":"Zyx987wvu","expires_in":3600}"#,
            "token eg1~eyJraWQiOiJ0RkMyVUloRnBUTV9FYTFLb0dReWJLcE9ISThnRF9YOW5KcHFCbFNWckhJIn0.abc-def",
            #"{"redirectUrl":"x","authorizationCode":"0123456789abcdef0123456789abcdef","exchangeCode":"fedcba"}"#,
            "GET https://embed.gog.com/on_login_success?origin=client&code=SECRETCODE123",
            "code=SECRETCODE456 client_secret=9d85c43b1482497dbbce61f6e4aa173a",
            #"{"user_code":"USRCODE1","verification_uri_complete":"x"} userCode=USRCODE2"#,
        ]
        let out = lines.map(Redactor.scrub).joined(separator: "\n")
        for secret in ["Abc123def456ghi", "Zyx987wvu", "eyJraWQi", "0123456789abcdef0123456789abcdef", "fedcba",
                       "SECRETCODE123", "SECRETCODE456", "9d85c43b1482497dbbce61f6e4aa173a", "USRCODE1", "USRCODE2"] {
            XCTAssertFalse(out.contains(secret), "\(secret) leaked: \(out)")
        }
        XCTAssertTrue(out.contains("expires_in"), "a non-secret field stays")
        XCTAssertTrue(out.contains("https://embed.gog.com/on_login_success?<query:redacted>"))
    }
}
