// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import GOGClientKit
@testable import ContentKit

final class GOGClientKitTests: XCTestCase {
    func fixture(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil))))
    }

    func testTheLoginRedirectGivesTheCodeAndNothingElseDoes() {
        XCTAssertEqual(GOGAPI.code(fromRedirect: URL(string: "https://embed.gog.com/on_login_success?origin=client&code=abc")!)?.value, "abc")
        XCTAssertNil(GOGAPI.code(fromRedirect: URL(string: "https://embed.gog.com/on_login_success?origin=client")!))
        XCTAssertNil(GOGAPI.code(fromRedirect: URL(string: "https://evil.example/on_login_success?code=abc")!))
        XCTAssertTrue(GOGAPI.loginURL.absoluteString.hasPrefix("https://auth.gog.com/auth?client_id=46899977096215655"))
        XCTAssertEqual("\(Secret("abc"))", "<redacted>")
    }

    func testASessionIsKeptInTheStoreAndSignOutDeletesIt() async throws {
        let store = MemorySecretStore()
        let s = GOGSession(store: store, log: .silent)
        let signedOut = await s.state
        XCTAssertEqual(signedOut, .signedOut)
        let t = GOGTokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), userID: "1")
        try store.write(GOGSession.key, Secret([UInt8](try JSONEncoder.gog.encode(t))))
        let again = GOGSession(store: store, log: .silent)
        let up = await again.state
        XCTAssertEqual(up, .signedIn)
        let token = try await again.accessToken()
        XCTAssertEqual(token.value, "a", "a token with an hour left is not refreshed")
        await again.signOut()
        XCTAssertNil(try store.read(GOGSession.key))
        let gone = await again.state
        XCTAssertEqual(gone, .signedOut)
    }

    func testBuildsNewestFirst() throws {
        let b = try GOGContent.parseBuilds(try fixture("builds.json"))
        XCTAssertEqual(b.count, 5)
        XCTAssertEqual(b.first?.version, "1.0.2.1a")
        XCTAssertEqual(b.last?.version, "0.9.1.3")
        XCTAssertEqual(b.first?.link.host, "gog-cdn-fastly.gog.com")
    }

    func testTheBuildManifestAndItsDepots() throws {
        let m = try GOGBuildManifest.parse(try Zlib.json(try fixture("build.zlib")))
        XCTAssertEqual(m.installDirectory, "Shogun Showdown")
        XCTAssertEqual(m.baseProductID, "1104084973")
        XCTAssertEqual(m.depots.count, 2)
        XCTAssertEqual(m.selected().map(\.manifest), ["969a45dc4a71fea54293a47748cafbda", "cd267b2e6511435d96da72e54a5eb8fe"])
        XCTAssertEqual(m.selected().last?.isGogDepot, true, "the depot with goggame-ID.info is installed too")
        XCTAssertEqual(m.selected(language: "pl-PL").count, 2, "no Polish depot: English")
    }

    func testTheBuildsGalaxyClientIsReadAndAPlaceholderIsNone() throws {
        XCTAssertNil(try GOGBuildManifest.parse(try Zlib.json(try fixture("build.zlib"))).galaxy,
                     "the fixture's fields are placeholders: no client")
        let secret = String(repeating: "0f", count: 32)
        let json = #"{"baseProductId":"7","installDirectory":"G","depots":[],"version":2,"clientId":"51234567890123456","clientSecret":""# + secret + #""}"#
        let m = try GOGBuildManifest.parse(Array(json.utf8))
        XCTAssertEqual(m.galaxy?.clientID, "51234567890123456")
        XCTAssertEqual(m.galaxy?.clientSecret.value, secret)
        XCTAssertEqual("\(m.galaxy!)".contains(secret), false, "the secret never prints")
        XCTAssertNil(GOGGalaxyClient(id: "123", secret: "not hex at all, not hex at all"))
        XCTAssertNil(GOGGalaxyClient(id: nil, secret: secret))
    }

    func testTheInstallRecordKeepsTheGalaxyClientAndAnOlderRecordStillReads() throws {
        let g = GOGGalaxyClient(clientID: "5", clientSecret: Secret("abcdef0123456789"))
        let rec = GOGInstalled(productID: "7", buildID: "1", version: nil, installDir: "G", files: [], galaxy: g, galaxyRead: true)
        let back = try JSONDecoder().decode(GOGInstalled.self, from: JSONEncoder().encode(rec))
        XCTAssertEqual(back, rec)
        let old = #"{"productID":"7","buildID":"1","installDir":"G","files":[]}"#
        let o = try JSONDecoder().decode(GOGInstalled.self, from: Data(old.utf8))
        XCTAssertNil(o.galaxy)
        XCTAssertNil(o.galaxyRead, "an older record: the client is read from its build at the next launch")
    }

    func testDepotSelectionKeepsNeutral64BitAndOwnedDLCs() {
        func d(_ m: String, _ l: [String], _ p: String = "1", _ b: [String]? = nil) -> GOGBuildManifest.Depot {
            .init(manifest: m, languages: l, productID: p, size: 1, bitness: b, isGogDepot: false)
        }
        let m = GOGBuildManifest(buildID: "1", baseProductID: "1", installDirectory: "G", depots: [
            d("en", ["en-US"]), d("pl", ["pl-PL"]), d("all", ["*"]), d("x86", ["*"], "1", ["32"]),
            d("dlc", ["*"], "2"), d("notowned", ["*"], "3")], dependencies: [])
        XCTAssertEqual(m.selected(language: "pl-PL", owned: ["2"]).map(\.manifest), ["pl", "all", "dlc"])
        XCTAssertEqual(m.selected().map(\.manifest), ["en", "all"])
    }

    func testALanguageWithoutARegionIsTheRegionedOnes() {
        // NWN Diamond's build names `en`, `fr`, …: `en-US` picked the first other one, French (PLA-187).
        func d(_ m: String, _ l: [String]) -> GOGBuildManifest.Depot {
            .init(manifest: m, languages: l, productID: "1", size: 1, bitness: nil, isGogDepot: false)
        }
        let m = GOGBuildManifest(buildID: "1", baseProductID: "1", installDirectory: "G", depots: [
            d("all", ["*"]), d("fr", ["fr"]), d("en", ["en"]), d("de", ["de"])], dependencies: [])
        XCTAssertEqual(m.selected().map(\.manifest), ["all", "en"])
        XCTAssertEqual(m.selected(language: "de-DE").map(\.manifest), ["all", "de"])
        XCTAssertEqual(m.selected(language: "pl-PL").map(\.manifest), ["all", "en"], "no Polish depot: English")
        XCTAssertFalse(GOGBuildManifest.language("en-GB", is: "en-US"), "another region is not the same language tag")
    }

    func testTheBuildsSupportSetupsAreRead() throws {
        // NWN Diamond's products: the base game's Inno Setup, which places app/binkw32.dll (PLA-187).
        let json = #"{"baseProductId":"7","installDirectory":"G","depots":[],"version":2,"products":["#
            + #"{"productId":"8","temp_executable":"dlc_setup.exe","temp_arguments":"None"},"#
            + #"{"productId":"7","temp_executable":"galaxy_game_2.1.0.21.exe","temp_arguments":"None","script":"goggame-7.script"},"#
            + #"{"productId":"9","temp_executable":"","temp_arguments":""}]}"#
        let m = try GOGBuildManifest.parse(Array(json.utf8))
        XCTAssertEqual(m.supportCommands, [GOGSupportCommand(productID: "7", executable: "galaxy_game_2.1.0.21.exe"),
                                           GOGSupportCommand(productID: "8", executable: "dlc_setup.exe")], "the base product first; none for 9")
        XCTAssertEqual(try GOGBuildManifest.parse(try Zlib.json(try fixture("build.zlib"))).supportCommands, [])
        XCTAssertThrowsError(try GOGBuildManifest.parse(Array(#"{"baseProductId":"7","installDirectory":"G","depots":[],"products":[{"productId":"7","temp_executable":"/x.exe"}]}"#.utf8)))
        XCTAssertEqual(GOGSupportCommand.prerequisiteID(productID: "7", buildID: "49"), "gog-support:7@49")
        let args = GOGSupportCommand.arguments(folder: "C:\\Games\\NWN Diamond", productID: "7", buildID: "49", version: "1.69 (A)")
        XCTAssertEqual(args.prefix(3), ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/DIR=C:\\Games\\NWN Diamond"])
        XCTAssertTrue(args.contains("/ProductId=7") && args.contains("/galaxyclient") && args.contains("/versionName=1.69 (A)"))
    }

    func testAnOlderRecordReadsItsSupportSetupsLater() throws {
        let old = #"{"productID":"7","buildID":"1","installDir":"G","files":[]}"#
        XCTAssertNil(try JSONDecoder().decode(GOGInstalled.self, from: Data(old.utf8)).supportCommands)
        var rec = GOGInstalled(productID: "7", buildID: "1", version: nil, installDir: "G", files: [])
        rec.supportCommands = [GOGSupportCommand(productID: "7", executable: "setup.exe")]
        XCTAssertEqual(try JSONDecoder().decode(GOGInstalled.self, from: JSONEncoder().encode(rec)), rec)
    }

    func testADepotManifestsFilesAreChecked() throws {
        let files = try GOGContent.parseDepot(try Zlib.json(try fixture("depot.zlib")))
        XCTAssertEqual(files.count, 8, "the directory entry writes nothing")
        XCTAssertEqual(files[0].path, "MonoBleedingEdge/EmbedRuntime/MonoPosixHelper.dll")
        XCTAssertEqual(files[0].size, 609_472)
        let bad = #"{"depot":{"items":[{"type":"DepotFile","path":"..\\evil.dll","chunks":[]}]}}"#
        XCTAssertThrowsError(try GOGContent.parseDepot(Array(bad.utf8)))
    }

    func testThePlanDedupsChunksAndALaterDepotWins() throws {
        let c = { (m: String, n: UInt32) in GOGDepotFile.Chunk(md5: m, size: n, compressedMd5: String(m.reversed()), compressedSize: n) }
        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32), e = String(repeating: "e", count: 32)
        let files = [GOGDepotFile(path: "Data/x.bin", chunks: [c(a, 10), c(b, 5)]),
                     GOGDepotFile(path: "game.exe", chunks: [c(a, 10)]),
                     GOGDepotFile(path: "DATA/X.BIN", chunks: [c(e, 3)], md5: e)]
        let p = try GOGContent.plan(productID: "7", buildID: "1", files: files)
        XCTAssertEqual(p.files.map(\.path), ["DATA/X.BIN", "game.exe"])
        XCTAssertEqual(p.chunks.count, 2)
        XCTAssertEqual(p.files[1].hash, .md5(GOGContent.hex(a)), "a one-chunk file's md5 is its chunk's")
        XCTAssertEqual(p.chunks[0].group, 7)
        XCTAssertEqual(p.directories, ["DATA"])
    }

    func testSecureLinksFillTheirFormat() throws {
        let body = #"""
        {"product_id":1,"type":"depot","urls":[
         {"endpoint_name":"gcore","fallback_only":true,"priority":1,"supports_generation":[2],
          "url_format":"{base_url}/{path}","parameters":{"base_url":"https://b.example","path":"/p"}},
         {"endpoint_name":"fastly","fallback_only":false,"priority":10,"supports_generation":[1,2],
          "url_format":"{base_url}/token=nva={expires_at}~dirs={dirs}~token={token}{path}",
          "parameters":{"base_url":"https://a.example/x","dirs":2,"expires_at":1790000000,"path":"/content-system/v2/store/1","token":"T"}}]}
        """#
        let eps = try GOGChunkSource.parseLink(Array(body.utf8))
        XCTAssertEqual(eps.map(\.priority), [10, 1])
        XCTAssertEqual(eps[0].expires, Date(timeIntervalSince1970: 1_790_000_000))
        let md5 = "c889eaa977f423a284e4a128f1794cad"
        XCTAssertEqual(try GOGChunkSource.url(eps[0], chunk: md5).absoluteString,
                       "https://a.example/x/token=nva=1790000000~dirs=2~token=T/content-system/v2/store/1/c8/89/" + md5)
    }

    func testZlibChecksItsAdler() throws {
        // zlib.compress(b"hello hello hello")
        let z: [UInt8] = [120, 156, 203, 72, 205, 201, 201, 87, 200, 64, 144, 0, 58, 46, 6, 125]
        XCTAssertEqual(String(decoding: try Zlib.decompress(z, limit: 64), as: UTF8.self), "hello hello hello")
        var bad = z
        bad[bad.count - 1] ^= 1
        XCTAssertThrowsError(try Zlib.decompress(bad, limit: 64))
    }

    func testAnInstalledFileVerifiesByChunks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let one = Array("0123456789".utf8), two = Array("abcde".utf8)
        try Data(one + two).write(to: dir.appendingPathComponent("f.bin"))
        let hex = { (b: [UInt8]) in MD5.hash(b).hex }
        var f = GOGDepotFile(path: "f.bin", chunks: [.init(md5: hex(one), size: 10, compressedMd5: hex(one), compressedSize: 1),
                                                    .init(md5: hex(two), size: 5, compressedMd5: hex(two), compressedSize: 1)])
        XCTAssertTrue(try GOGInstaller.matches(dir, f))
        f.chunks[1].md5 = hex(one)
        XCTAssertFalse(try GOGInstaller.matches(dir, f))
        f.md5 = hex(one + two)
        XCTAssertTrue(try GOGInstaller.matches(dir, f), "the file's md5 wins when GOG lists one")
    }

    func testLibraryPages() throws {
        let body = #"{"products":[{"id":2,"title":"Zeta","image":"//images-1.gog-statics.com/abc","worksOn":{"Windows":true},"dlcCount":1},{"id":3,"title":"Mac only","worksOn":{"Windows":false}}],"totalPages":3}"#
        let p = try GOGLibrary.parse(Array(body.utf8))
        XCTAssertEqual(p.pages, 3)
        XCTAssertEqual(p.games.map(\.id), ["2", "3"])
        XCTAssertEqual(p.games[0].art("_196")?.absoluteString, "https://images-1.gog-statics.com/abc_196.jpg")
    }

    func testUniqueFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gogu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Game"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(GOGInstaller.unique("Other", in: dir), "Other")
        XCTAssertEqual(GOGInstaller.unique("game", in: dir), "game (GOG)")
    }
}
