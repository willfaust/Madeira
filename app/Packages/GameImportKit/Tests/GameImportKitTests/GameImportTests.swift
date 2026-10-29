// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import GameImportKit
import ContentKit

final class GameImportTests: XCTestCase {
    var root: URL!
    var src: URL { root.appendingPathComponent("Files/Celeste") }
    var layout: InstallLayout { InstallLayout.root(root.appendingPathComponent("container")) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ rel: String, _ text: String = "x", in base: URL? = nil) throws {
        let url = (base ?? src).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func importer(free: UInt64 = 1 << 40) -> GameImporter {
        var i = GameImporter(layout: layout)
        i.freeSpace = { _ in free }
        i.reserveBytes = 0
        return i
    }

    func testAFolderIsCopiedWithItsTreeAndAReceipt() async throws {
        try file("Celeste.exe", "MZ game")
        try file("Content/Dialog/English.txt", "hello")
        try file("Content/.hidden", "kept")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Saves"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("link.exe").path, withDestinationPath: "Celeste.exe")
        let plan = try GameImporter.plan(.folder(src))
        XCTAssertEqual(plan.name, "Celeste")
        XCTAssertEqual(plan.files.map(\.path), ["Celeste.exe", "Content/.hidden", "Content/Dialog/English.txt"])
        XCTAssertEqual(plan.directories, ["Content", "Content/Dialog", "Saves"])
        XCTAssertEqual(plan.skippedSymlinks, 1)
        XCTAssertEqual(plan.totalBytes, 7 + 4 + 5)
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let receipt = try await importer().run(plan, folder: "Celeste", now: at)
        let game = layout.gamesRoot.appendingPathComponent("Celeste")
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("Content/Dialog/English.txt"), encoding: .utf8), "hello")
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.appendingPathComponent("Saves").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent("link.exe").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: importer().stage(folder: "Celeste").path))
        XCTAssertEqual(receipt.key, StoreGameKey(store: .local, id: "celeste"))
        XCTAssertEqual(receipt.importedFrom, "Celeste")
        XCTAssertEqual(receipt.files, 3)
        XCTAssertEqual(layout.storeReceipts(), [receipt])

    }

    func testAStoppedImportResumesWithoutCopyingWhatIsInPlace() async throws {
        try file("a.bin", String(repeating: "a", count: 100))
        try file("b.bin", String(repeating: "b", count: 100))
        let plan = try GameImporter.plan(.folder(src))
        let stage = importer().stage(folder: "Celeste")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data(String(repeating: "a", count: 100).utf8).write(to: stage.appendingPathComponent("a.bin"))
        try Data("torn".utf8).write(to: stage.appendingPathComponent(".b.bin.part"))
        let seen = Seen()
        _ = try await importer().run(plan, folder: "Celeste") { seen.add($0) }
        XCTAssertEqual(seen.first?.bytesDone, 100, "a.bin was in place")
        XCTAssertEqual(try Data(contentsOf: layout.gamesRoot.appendingPathComponent("Celeste/b.bin")).count, 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.gamesRoot.appendingPathComponent("Celeste/.b.bin.part").path))
    }

    func testNotEnoughSpaceStopsBeforeCopying() async throws {
        try file("big.bin", String(repeating: "z", count: 1000))
        let plan = try GameImporter.plan(.folder(src))
        do {
            var i = importer(free: 1000); i.clonesInto = { _, _ in false }
            _ = try await i.run(plan, folder: "Celeste")
            XCTFail("expected a refusal")
        } catch let ImportError.insufficientSpace(needed, available) {
            XCTAssertEqual(needed, 1050)
            XCTAssertEqual(available, 1000)
        }
    }

    /// A clone on the stage's volume takes no space: the check is the reserve alone (PLA-199).
    func testAFolderThatClonesNeedsOnlyTheReserve() async throws {
        try file("big.bin", String(repeating: "z", count: 1000))
        let plan = try GameImporter.plan(.folder(src))
        var i = importer(free: 100)
        i.reserveBytes = 100
        i.clonesInto = { _, _ in true }
        i.cloneFile = { from, to in (try? FileManager.default.copyItem(at: from, to: to)) != nil }
        XCTAssertEqual(i.spaceNeeded(toCopy: 0), 100)
        _ = try await i.run(plan, folder: "Celeste")
        XCTAssertEqual(try Data(contentsOf: layout.gamesRoot.appendingPathComponent("Celeste/big.bin")).count, 1000)
    }

    /// A clone that fails falls back to a copy only after that file's own check.
    func testAFailedCloneIsCheckedAgainBeforeItsCopy() async throws {
        try file("big.bin", String(repeating: "z", count: 1000))
        let plan = try GameImporter.plan(.folder(src))
        var i = importer(free: 1049)
        i.clonesInto = { _, _ in true }
        i.cloneFile = { _, _ in false }
        do {
            _ = try await i.run(plan, folder: "Celeste")
            XCTFail("expected a refusal")
        } catch let ImportError.insufficientSpace(needed, available) {
            XCTAssertEqual(needed, 1050)
            XCTAssertEqual(available, 1049)
        }
        let stage = i.stage(folder: "Celeste")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.appendingPathComponent(".big.bin.part").path), "nothing was copied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.gamesRoot.appendingPathComponent("Celeste").path))
        i.freeSpace = { _ in 1050 }
        _ = try await i.run(plan, folder: "Celeste")
        XCTAssertEqual(try Data(contentsOf: layout.gamesRoot.appendingPathComponent("Celeste/big.bin")).count, 1000)
    }

    func testAFolderOnAnotherVolumeOrAZipIsCheckedInFull() {
        XCTAssertFalse(GameImporter.sameVolume(src, root.appendingPathComponent("missing")), "an unreadable path is not one volume")
        var i = importer()
        i.reserveBytes = 256
        XCTAssertEqual(i.spaceNeeded(toCopy: 1000), 1000 + 50 + 256)
    }

    func testNamesWindowsCannotHoldAreRefused() throws {
        try file("game.exe")
        try file("Data/aux.dat")
        XCTAssertThrowsError(try GameImporter.plan(.folder(src))) { XCTAssertTrue("\($0)".contains("reserved"), "\($0)") }
        try FileManager.default.removeItem(at: src.appendingPathComponent("Data/aux.dat"))
        try file("Data/A.bin")
        try file("data/a.bin")
        // A case-insensitive host cannot create both files; check the same name boundary directly.
        var names = Set<String>()
        try WindowsName.check(path: ["Data", "A.bin"], seen: &names)
        XCTAssertThrowsError(try WindowsName.check(path: ["data", "a.bin"], seen: &names))
    }

    func testICloudPlaceholdersAskForADownload() throws {
        try file("game.exe")
        try file(".data.pak.icloud")
        XCTAssertThrowsError(try GameImporter.plan(.folder(src))) { XCTAssertEqual($0 as? ImportError, .notDownloaded(1)) }
    }

    func testAZipWithOneTopFolderImportsThatFolder() async throws {
        let zip = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/game", withExtension: "zip"))
        let plan = try GameImporter.plan(.zip(zip))
        XCTAssertEqual(plan.name, "Game")
        XCTAssertEqual(plan.files.map(\.path), ["data/big.bin", "game.exe", "readme.txt"])
        XCTAssertEqual(plan.skippedSymlinks, 1)
        let receipt = try await importer().run(plan, folder: "Game")
        XCTAssertEqual(receipt.importedFrom, "game.zip")
        let big = try Data(contentsOf: layout.gamesRoot.appendingPathComponent("Game/data/big.bin"))
        XCTAssertEqual(SHA1.hash([UInt8](big)).hex, "1da63ba332c31bd5c9b132c4cf0eb7b16eb7c68e")
    }

    func testUniqueFolderNames() {
        XCTAssertEqual(GameImporter.uniqueFolder("Celeste", existing: ["Hollow Knight"]), "Celeste")
        XCTAssertEqual(GameImporter.uniqueFolder("Celeste", existing: ["celeste"]), "Celeste 2")
        XCTAssertEqual(GameImporter.uniqueFolder("Celeste", existing: ["celeste"], taken: ["Celeste 2"]), "Celeste 3")
        XCTAssertEqual(GameImporter.uniqueFolder("con", existing: []), "Game")
        XCTAssertEqual(GameImporter.uniqueFolder(".hidden", existing: []), "Game")
    }

    func testChangedSourceCannotReuseAStage() async throws {
        try file("game.exe", "first version")
        let old = try GameImporter.plan(.folder(src))
        var blocked = importer(free: 0); blocked.clonesInto = { _, _ in false }
        do { _ = try await blocked.run(old, folder: "Game"); XCTFail("space refusal expected") } catch {}
        try file("game.exe", "a different version with another size")
        do {
            _ = try await importer().run(GameImporter.plan(.folder(src)), folder: "Game")
            XCTFail("changed source must be refused")
        } catch { XCTAssertTrue("\(error)".contains("source changed")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.gamesRoot.appendingPathComponent("Game").path))
    }

    func testRevokedDestinationNeverPublishesTheGame() async throws {
        try file("game.exe", String(repeating: "a", count: 100))
        let plan = try GameImporter.plan(.folder(src)), revoked = LockedFlag()
        var i = importer()
        i.validateDestination = { if revoked.value { throw ImportError.refused("drive removed") } }
        do {
            _ = try await i.run(plan, folder: "Game") { p in if p.bytesDone == p.bytesTotal { revoked.set() } }
            XCTFail("revoked drive must be refused")
        } catch { XCTAssertTrue("\(error)".contains("drive removed")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.gamesRoot.appendingPathComponent("Game").path))
    }

    func testDestinationFolderCannotEscapeTheRoot() async throws {
        try file("game.exe")
        let plan = try GameImporter.plan(.folder(src))
        for folder in ["../escape", "a/b", "CON", ".stage"] {
            do { _ = try await importer().run(plan, folder: folder); XCTFail("unsafe folder accepted: \(folder)") } catch {}
        }
    }

}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [GameImporter.Progress] = []
    func add(_ p: GameImporter.Progress) { lock.withLock { all.append(p) } }
    var first: GameImporter.Progress? { lock.withLock { all.first } }
}


private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}
