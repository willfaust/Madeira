// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import GOGClientKit
@testable import ContentKit

/// GOG's redistributables (decision 0090), from the repository as GOG served it on 2026-10-11.
final class GOGDependenciesTests: XCTestCase {
    func fixture(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil))))
    }

    func repository() throws -> [GOGDependency] {
        try GOGDependencies.parseRepository(try Zlib.json(try fixture("dependencies.zlib")))
    }

    func testTheRepositoryPointerAndManifest() throws {
        let body = #"{"repository_manifest":"https:\/\/gog-cdn-fastly.gog.com\/content-system\/v2\/dependencies\/meta\/e4\/be\/e4be9c2bae009cf9473447fb8e479fee","build_id":"59705672826648994","generation":2}"#
        XCTAssertEqual(try GOGDependencies.parsePointer(Array(body.utf8)).host, "gog-cdn-fastly.gog.com")
        XCTAssertThrowsError(try GOGDependencies.parsePointer(Array(#"{"repository_manifest":"http://x.example/m"}"#.utf8)))
        let r = try repository()
        let openAL = try XCTUnwrap(r.first { $0.id == "openAL" })
        XCTAssertEqual(openAL, GOGDependency(id: "openAL", name: "Open AL (2.0.7.0)", executable: "__redist/openAL/oalinst.exe",
                                             arguments: "/S", manifest: "e0b13c7ba5ef3712faf6dd2855857e45", size: 809_496))
        XCTAssertEqual(r.first { $0.id == "ISI" }?.executable, "__redist/ISI/scriptinterpreter.exe")
        XCTAssertEqual(r.first { $0.id == "DOSBox073" }?.executable, "", "a tool GOG places for the game has no installer")
        let bad = #"{"depots":[{"dependencyId":"x","manifest":"e0b13c7b","executable":{"path":"a.exe"}}]}"#
        XCTAssertThrowsError(try GOGDependencies.parseRepository(Array(bad.utf8)))
        let evil = #"{"depots":[{"dependencyId":"x","manifest":"e0b13c7ba5ef3712faf6dd2855857e45","executable":{"path":"..\\..\\a.exe"}}]}"#
        XCTAssertThrowsError(try GOGDependencies.parseRepository(Array(evil.utf8)))
    }

    func testTheOpenALDepotIsOneInstaller() throws {
        let files = try GOGContent.parseDepot(try Zlib.json(try fixture("dependency-openal.zlib")))
        XCTAssertEqual(files.map(\.path), ["__redist/openAL/oalinst.exe"])
        XCTAssertEqual(files[0].size, 809_496)
    }

    func testABuildNamesItsDependencies() throws {
        let json = #"{"baseProductId":"1207666353","installDirectory":"Baldur's Gate - Enhanced Edition","depots":[],"version":2,"dependencies":["openAL"],"scriptInterpreter":true}"#
        XCTAssertEqual(try GOGBuildManifest.parse(Array(json.utf8)).dependencies, ["openAL"])
    }

    func testSelectionRunsInstallersAndSkipsWhatPlayportCovers() throws {
        let s = GOGDependencies.select(["openAL", "MSVC2017_x64", "DirectX", "dotNet472", "dotNetCore318_x64", "DOSBox073",
                                        "XNA_40", "nonesuch", "openAL"], from: try repository())
        XCTAssertEqual(s.run.map(\.id), ["openAL", "MSVC2017_x64", "dotNetCore318_x64", "XNA_40"], "in the build's order, once each")
        XCTAssertEqual(s.run.map(\.isWindowsInstallerPackage), [false, false, false, true], "XNA's .msi runs through msiexec (decision 0103)")
        XCTAssertEqual(s.skipped.map(\.dependency.id), ["DirectX", "dotNet472"])
        XCTAssertEqual(s.skipped.map(\.reason), [GOGDependencies.directXReason, GOGDependencies.dotNetFrameworkReason])
        XCTAssertEqual(s.notes.count, 2, "DOSBox (no installer) and an unknown id are left out")
        let physX = GOGDependencies.select(["PHYSXLEGACY"], from: try repository()).run
        XCTAssertEqual(physX.map(\.executable), ["__redist/PHYSXLEGACY/PhysX-9.13.0604-SystemSoftware-Legacy.msi"])
        XCTAssertEqual(physX.map(\.arguments), ["/passive /norestart"])
        XCTAssertEqual(GOGDependencies.prerequisiteID("openAL"), "gog-redist:openAL")
    }

    func testTheOpenLinkGivesTheChunksURL() throws {
        let body = #"""
        {"urls":[{"endpoint_name":"fastly","url":"https:\/\/gog-cdn-fastly.gog.com\/content-system\/v2\/dependencies\/store",
         "url_format":"https:\/\/gog-cdn-fastly.gog.com\/content-system\/v2\/dependencies\/store","parameters":{},"priority":10,
         "max_fails":100,"supports_generation":[1,2],"fallback_only":false}]}
        """#
        let eps = try GOGChunkSource.parseLink(Array(body.utf8))
        XCTAssertEqual(try GOGChunkSource.url(eps[0], chunk: "1c2be02b2fc5e07355c68c7ef8116477").absoluteString,
                       "https://gog-cdn-fastly.gog.com/content-system/v2/dependencies/store/1c/2b/1c2be02b2fc5e07355c68c7ef8116477")
    }

    func testTheInstallRecordKeepsTheDependenciesAndAnOlderRecordReadsThemLater() throws {
        let rec = GOGInstalled(productID: "7", buildID: "1", version: nil, installDir: "G", files: [], galaxyRead: true, dependencies: ["openAL"])
        XCTAssertEqual(try JSONDecoder().decode(GOGInstalled.self, from: JSONEncoder().encode(rec)), rec)
        let old = #"{"productID":"7","buildID":"1","installDir":"G","files":[],"galaxyRead":true}"#
        XCTAssertNil(try JSONDecoder().decode(GOGInstalled.self, from: Data(old.utf8)).dependencies)
    }

    func testMissingDependenciesLookInTheGamesFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gogdep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallLayout(stagingRoot: root.appendingPathComponent("stage"), gamesRoot: root.appendingPathComponent("Games"),
                                   stateRoot: root.appendingPathComponent("state"))
        let exe = layout.gamesRoot.appendingPathComponent("G/__redist/openAL/oalinst.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = try repository()
        let installer = GOGInstaller(layout: layout, session: GOGSession(store: MemorySecretStore(), log: .silent), log: .silent)
        let deps = r.filter { ["openAL", "MSVC2017_x64"].contains($0.id) }
        XCTAssertEqual(Set(installer.missingDependencies(deps, installDir: "G").map(\.id)), ["MSVC2017_x64", "openAL"])
        FileManager.default.createFile(atPath: exe.path, contents: Data([1]))
        XCTAssertEqual(installer.missingDependencies(deps, installDir: "G").map(\.id), ["MSVC2017_x64"])
    }
}
