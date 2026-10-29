// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import ContentKit

final class ZipArchiveTests: XCTestCase {
    func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil))
    }

    func extract(_ zip: ZipArchive, _ path: String, blockSize: Int = 1 << 20) throws -> [UInt8] {
        let e = try XCTUnwrap(zip.entries.first { $0.path == path })
        var out: [UInt8] = []
        try zip.extract(e, blockSize: blockSize) { out += $0 }
        return out
    }

    func testTheCentralDirectoryNamesEveryEntry() throws {
        let zip = try ZipArchive(url: try fixture("game.zip"))
        XCTAssertEqual(zip.entries.map(\.path), ["Game/", "Game/game.exe", "Game/data/big.bin", "Game/readme.txt", "Game/link"])
        XCTAssertEqual(zip.entries.map(\.isDirectory), [true, false, false, false, false])
        XCTAssertEqual(zip.entries.map(\.isSymlink), [false, false, false, false, true])
        XCTAssertEqual(zip.entries.map(\.method), [0, 8, 8, 0, 0])
    }

    func testEntriesStreamOutWhateverTheBlockSize() throws {
        let zip = try ZipArchive(url: try fixture("game.zip"))
        for block in [1, 7, 4096, 1 << 20] {
            let big = try extract(zip, "Game/data/big.bin", blockSize: block)
            XCTAssertEqual(big.count, 139_447)
            XCTAssertEqual(SHA1.hash(big).hex, "1da63ba332c31bd5c9b132c4cf0eb7b16eb7c68e", "block \(block)")
        }
        XCTAssertEqual(try extract(zip, "Game/readme.txt"), Array("stored text\n".utf8))
        XCTAssertEqual(try extract(zip, "Game/game.exe").count, 206)
    }

    func testZip64() throws {
        let zip = try ZipArchive(url: try fixture("zip64.zip"))
        XCTAssertEqual(zip.entries.map(\.path), ["a/b.txt"])
        XCTAssertEqual(try extract(zip, "a/b.txt"), Array(String(repeating: "hello zip64\n", count: 100).utf8))
    }

    func testAnotherMethodIsRefusedByName() throws {
        let zip = try ZipArchive(url: try fixture("bzip2.zip"))
        XCTAssertThrowsError(try extract(zip, "x/y.dat")) { e in
            XCTAssertTrue("\(e)".contains("bzip2"), "\(e)")
        }
    }

    func testACorruptEntryFailsItsCheck() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var bytes = [UInt8](try Data(contentsOf: try fixture("game.zip")))
        let zip = try ZipArchive(url: try fixture("game.zip"))
        let readme = try XCTUnwrap(zip.entries.first { $0.path == "Game/readme.txt" })
        bytes[Int(readme.localHeader) + 30 + "Game/readme.txt".utf8.count] ^= 0x20
        let bad = dir.appendingPathComponent("bad.zip")
        try Data(bytes).write(to: bad)
        XCTAssertThrowsError(try extract(try ZipArchive(url: bad), "Game/readme.txt")) { e in
            XCTAssertTrue("\(e)".contains("CRC"), "\(e)")
        }
        try Data("not a zip at all, just some text".utf8).write(to: bad)
        XCTAssertThrowsError(try ZipArchive(url: bad))
    }

    func testStreamingInflateMatchesTheWholeBufferOne() throws {
        let zip = try ZipArchive(url: try fixture("game.zip"))
        let e = try XCTUnwrap(zip.entries.first { $0.path == "Game/data/big.bin" })
        let raw = [UInt8](try Data(contentsOf: try fixture("game.zip")))
        let start = Int(e.localHeader) + 30 + "Game/data/big.bin".utf8.count
        let body = raw[start..<(start + Int(e.compressedSize))]
        let whole = try Inflate.decompress(body, limit: Int(e.size))
        var fed = false
        var out: [UInt8] = []
        var s = InflateStream(limit: e.size, flushAt: 300, read: {
            defer { fed = true }
            return fed ? nil : Array(body)
        }, write: { out += $0 })
        try s.run()
        XCTAssertEqual(out, whole)
        var tooSmall = InflateStream(limit: e.size - 1, read: { Array(body) }, write: { _ in })
        XCTAssertThrowsError(try tooSmall.run(), "a stream past its declared size stops")
    }
}

final class WindowsNameTests: XCTestCase {
    func testWhatWindowsCannotName() {
        for bad in ["CON", "con.txt", "Lpt1", "nul.tar.gz", "a:b", "a?", "end.", "end ", "tab\there", "..", ""] {
            XCTAssertThrowsError(try WindowsName.check(bad), bad)
        }
        for good in ["Hollow Knight", "game.exe", "console.log", "COM10", "data.pak", "Ünïcode"] {
            XCTAssertNoThrow(try WindowsName.check(good), good)
        }
        var seen = Set<String>()
        XCTAssertNoThrow(try WindowsName.check(path: ["Data", "a.bin"], seen: &seen))
        XCTAssertThrowsError(try WindowsName.check(path: ["data", "A.bin"], seen: &seen))
    }
}
