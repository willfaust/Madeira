#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Host checks for the itch.io store (docs/ITCH.md). Never contacts itch.io.

Source checks: licence headers, every itch.io source in the Xcode project, the
device-only Keychain item for the API key, no key in a log line, itch.io games kept
out of Other games, the Game details page, the Settings section, downloads pausing
for a session, the settings catalog entry.

Swift (ItchAPI.swift without the Keychain, ItchArchive.swift, ItchProgram from
ItchLibrary.swift): itch.io's answers in snake_case, camelCase and the old traits
form; which upload installs; which program starts; and the zip unpacker on archives
made here with Python's zipfile: stored and deflated entries over several 1 MB
pieces, ZIP64, a damaged CRC, names that leave the folder, two names that differ
only in case, a symbolic link, a truncated archive, and the old install folder
kept when an unpack fails.
"""
from pathlib import Path
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


sources = [app / 'SwiftItch/ItchAPI.swift', app / 'SwiftItch/ItchArchive.swift', app / 'ItchLibrary.swift', app / 'ItchGames.swift']
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text()
for path in sources:
    text = path.read_text()
    require(text.startswith('// SPDX-License-Identifier: GPL-3.0-or-later'), f'{path.name}: licence header')
    require(re.search(r'/\* (SwiftItch/)?' + re.escape(path.name) + r' in Sources \*/,', project) is not None,
            f'{path.name}: in the Xcode project sources')
    for line in text.splitlines():
        if 'ItchLog.event' in line or 'LogStore' in line:
            compact = line.replace(' ', '')
            bad = [w for w in ('key', 'candidate', 'raw', 'name', 'accountName', 'request', 'url') if '\\(' + w in compact]
            require(not bad, f'{path.name}: no key or account data in a log line: {line.strip()[:80]}')

api = (app / 'SwiftItch/ItchAPI.swift').read_text()
require('kSecAttrAccessibleWhenUnlockedThisDeviceOnly' in api and 'kSecAttrSynchronizable as String: false' in api,
        'the API key: one device-only Keychain item, not synchronised')
require('https://api.itch.io' in api and 'api_key' not in api, 'the key goes in the Authorization header, never in an address')
library = (app / 'Library.swift').read_text()
require('var itchGameID: Int?' in library, 'library entries record their itch.io game')
require(library.count('$0.epicAppName == nil && $0.itchGameID == nil') >= 2, 'Other games: no itch.io game (it has its own section)')
require('ItchGamesSection(search: search' in library and 'ItchSettingsSection()' in library, 'the library and Settings show itch.io')
require('case .itch: ItchEntrySection(entry: $entry)' in library, 'Game details: the itch.io page')
require('func upsertItch(' in library and 'func removeItch(' in library, 'installs and uninstalls keep the library in step')
require('ItchLibrary.shared.installed[game] == nil' in library, 'an uninstalled itch.io game does not start')
content = (app / 'ContentView.swift').read_text()
require('ItchLibrary.shared.sessionChanged(active: true)' in content, 'downloads pause for a game session')
require('ItchLibrary.shared.refreshLibrary' in (app / 'SteamGames.swift').read_text(), 'pull to refresh reloads the itch.io library')
require('key: "env.MADEIRA_ITCH"' in (app / 'ConfigCatalog.generated.swift').read_text(), 'settings catalog: env.MADEIRA_ITCH')
require((root / 'docs/ITCH.md').exists(), 'docs/ITCH.md')
itch_lib = (app / 'ItchLibrary.swift').read_text()
require('func upsertItch(_ game: ItchInstalledGame, cover: URL?, setupFinished: Bool = false)' in library
        and 'entry.launchMode = "desktop"; entry.startServices = true' in library, 'an installer runs in the Wine desktop with services first')
require(itch_lib.count('finishSetups()') >= 3, 'installers are finished after a session and at start')
require('owned = Self.merge(bought, collected, added)' in itch_lib, 'the library: owned keys, collections, then games added in Madeira')
require('ItchFindView' in (app / 'ItchGames.swift').read_text(), 'Find a game')
require('downloadKey == 0 ? []' in api, 'a free game is asked for without a key')

# ------------------------------------------------------------------ compiled Swift
lib = (app / 'ItchLibrary.swift').read_text()
program = lib[lib.index('/// Installer downloads, the kinds'):lib.index('/// One file download with pause')]
api_core = api.replace('import Security\n', '#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n')
api_core = api_core[:api_core.index('/// The Keychain item')] + r'''
enum ItchKeyStore {
    static func load() -> String? { nil }
    static func save(_ key: String) -> Bool { true }
    static func delete() {}
}
''' + api_core[api_core.index('actor ItchAPI {'):]
stubs = r'''
import Foundation
final class LogStore {
    nonisolated(unsafe) static let shared = LogStore()
    func log(_ message: String) {}
}
'''

checks = r'''
import Foundation
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}
func json(_ text: String) -> [String: Any] { try! ItchFormat.json(Data(text.utf8)) }

@main
struct Checks {
    static func main() throws {
        let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

        // Owned keys: snake_case (the server), camelCase, the old traits; tools kept, other kinds and Mac-only games not.
        let page = json("""
        {"page":1,"per_page":50,"owned_keys":[
          {"id":11,"game_id":101,"game":{"id":101,"title":"Celeste ","classification":"game","cover_url":"https://img.itch.zone/c.png","url":"https://mattmakesgames.itch.io/celeste","platforms":{"windows":"all","osx":"all"}}},
          {"id":12,"gameId":102,"game":{"id":102,"title":"Tool","classification":"tool","traits":["p_windows"]}},
          {"id":13,"game_id":103,"game":{"id":103,"title":"Soundtrack","classification":"soundtrack","platforms":{"windows":"all"}}},
          {"id":14,"game_id":104,"game":{"id":104,"title":"Mac only","classification":"game","platforms":{"osx":"all"}}},
          {"id":15,"game_id":105,"game":{"id":105,"title":"No platforms listed","classification":"game","cover_url":"http://insecure/x.png"}}
        ]}
        """)
        let (games, keys) = ItchFormat.ownedKeys(page)
        require(keys == 5 && games.map(\.id) == [101, 102, 105], "owned keys: Windows games and tools, unlisted platforms kept (\(games.map(\.id)))")
        require(games[0].title == "Celeste" && games[0].downloadKeyID == 11 && games[0].cover?.host == "img.itch.zone"
                && games[0].url?.path == "/celeste", "a game's title, key, cover and page")
        require(games[2].cover == nil, "only https artwork")
        require((try? ItchFormat.json(Data(#"{"errors":["invalid key"]}"#.utf8))) == nil, "an error answer is an error")
        do { _ = try ItchFormat.json(Data(#"{"errors":["invalid key"]}"#.utf8)); require(false, "bad key") }
        catch ItchAPIError.badKey { require(true, "a refused key says so") } catch { require(false, "bad key: \(error)") }

        // Uploads and the choice.
        let uploads = ItchFormat.uploads(json("""
        {"uploads":[
          {"id":1,"filename":"celeste-linux.zip","type":"default","size":900,"platforms":{"linux":"all"}},
          {"id":2,"filename":"celeste-win32.zip","type":"default","size":500,"platforms":{"windows":"386"}},
          {"id":3,"filename":"celeste-win.zip","type":"default","size":400,"platforms":{"windows":"all"},"build_id":77,"build":{"id":77,"user_version":"1.4"}},
          {"id":4,"filename":"Celeste-setup.exe","type":"default","size":800,"platforms":{"windows":"all"}},
          {"id":5,"filename":"ost.zip","type":"soundtrack","size":9000,"platforms":{"windows":"all"}},
          {"id":6,"filename":"demo.zip","type":"default","size":9000,"traits":["p_windows","demo"]},
          {"id":7,"filename":"preorder.zip","type":"default","size":9000,"platforms":{"windows":"all"},"preorder":true}
        ]}
        """))
        require(uploads.count == 7 && uploads[2].buildID == 77 && uploads[2].version == "1.4" && uploads[5].demo && uploads[5].windows,
                "uploads: builds, versions, demo and Windows traits")
        require(ItchFormat.choose(uploads)?.id == 3, "the choice: the game's own Windows .zip, any architecture, before 32-bit, an installer, the soundtrack, a demo or a preorder")
        require(ItchFormat.choose(uploads.filter { $0.id != 3 })?.id == 4, "without it: the installer before the 32-bit build")
        require(ItchFormat.choose(uploads.filter { ![2, 3, 4].contains($0.id) })?.id == 6, "only a demo: the demo")
        require(ItchFormat.choose(uploads.filter { [1, 5, 7].contains($0.id) }) == nil, "no Windows game file: none")

        // Which program starts the game.
        require(ItchProgram.manifestAction("""
        [[prereqs]]
        name = "vcredist-2015-x64"
        [[actions]]
        name = "play"
        path = "bin\\\\Game.exe"
        """) == "bin/Game.exe", ".itch.toml: the first action's program")
        require(ItchProgram.manifestAction("[[actions]]\npath = \"../evil.exe\"\n") == nil, ".itch.toml: never outside the folder")
        require(ItchProgram.choose(["Game/Game.exe"], title: "x") == "Game/Game.exe", "the only program")
        require(ItchProgram.choose(["Celeste.exe", "Other.exe"], title: "Celeste") == "Celeste.exe", "the one named like the game")
        require(ItchProgram.choose(["a/b/Tool.exe", "Run.exe"], title: "Thing") == "Run.exe", "the one nearest the top")
        require(ItchProgram.choose(["A.exe", "B.exe"], title: "Thing") == nil, "two equally likely: none")
        require(ItchProgram.helper("unins000.exe") && ItchProgram.helper("UnityCrashHandler64.exe") && ItchProgram.helper("vc_redist.x64.exe")
                && !ItchProgram.helper("Game.exe"), "helpers are never the game")
        let folder = work.appendingPathComponent("prog", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Game"), withIntermediateDirectories: true)
        for name in ["Game/Game.exe", "Game/UnityCrashHandler64.exe", "unins000.exe"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("MZ".utf8))
        }
        require(ItchProgram.find(in: folder, title: "Whatever") == "Game/Game.exe", "find: the game's program, helpers aside")

        // Free games: collections, search and pasted links; no key.
        let free = ItchFormat.game(json(#"{"id":7,"title":"Free Thing","classification":"game","min_price":0,"platforms":{"windows":"all"},"user":{"username":"dev","display_name":"Dev"}}"#))
        require(free?.downloadKeyID == 0 && free?.owned == false && free?.minPrice == 0 && free?.author == "Dev", "a game object: no key, its price and author")
        require(ItchFormat.collections(json(#"{"collections":[{"id":5,"title":"A"},{"id":6}]}"#)) == [5, 6], "the account's collections")
        let collected = ItchFormat.collectionGames(json(#"{"page":1,"per_page":30,"collection_games":[{"game_id":8,"game":{"id":8,"title":"In a collection","platforms":{"windows":"all"}}},{"gameId":9,"game":{"id":9,"title":"Mac","platforms":{"osx":"all"}}}]}"#))
        require(collected.games.map(\.id) == [8] && collected.count == 2, "a collection's Windows games (snake_case and camelCase)")
        require(ItchFormat.searchGames(json(#"{"games":[{"id":10,"title":"Found","minPrice":500,"platforms":{"windows":"all"}},{"id":11,"title":"Book","classification":"book"}]}"#)).map(\.minPrice) == [500],
                "search: Windows games with their price")
        require(ItchFormat.dataURL("https://dev.itch.io/free-thing?x=1#y")?.absoluteString == "https://dev.itch.io/free-thing/data.json"
                && ItchFormat.dataURL("dev.itch.io/free-thing")?.absoluteString == "https://dev.itch.io/free-thing/data.json",
                "a pasted game link: its data.json")
        require(ItchFormat.dataURL("https://itch.io/games/free") == nil && ItchFormat.dataURL("https://api.itch.io/x") == nil
                && ItchFormat.dataURL("https://evil.com/dev.itch.io/x") == nil && ItchFormat.dataURL("https://dev.itch.io.evil.com/x") == nil
                && ItchFormat.dataURL("https://dev.itch.io/") == nil, "only an author's itch.io game page")
        require(ItchFormat.pageGameID(#"<meta name="itch:path" content="games/123456"/>"#) == 123456 && ItchFormat.pageGameID("<html>") == nil,
                "a game page's id from its itch:path tag")

        // Installers: sniffed like the itch app's, run unattended into the game's folder.
        func exe(_ marker: String) -> Data { Data("MZ".utf8) + Data(count: 4000) + Data(marker.utf8) + Data(count: 100) }
        require(ItchSetup.kind(fileName: "game_setup.exe", head: exe("Inno Setup Setup Data (6.2.0)")) == .inno, "Inno Setup")
        require(ItchSetup.kind(fileName: "x.exe", head: exe("NullsoftInst")) == .nsis, "NSIS")
        require(ItchSetup.kind(fileName: "Game.msi", head: Data()) == .msi
                && ItchSetup.kind(fileName: "x", head: Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])) == .msi, "MSI")
        require(ItchSetup.kind(fileName: "MyGame-Installer.exe", head: exe("nothing")) == .other, "another installer by its name")
        require(ItchSetup.kind(fileName: "MyGame.exe", head: exe("nothing")) == nil && ItchSetup.kind(fileName: "unins000.exe", head: exe("x")) == nil
                && ItchSetup.kind(fileName: "setup.txt", head: Data("hello".utf8)) == nil, "the game itself, an uninstaller and a text file are not installers")
        let inno = ItchSetup.script(kind: .inno, installer: "C:\\itch\\G\\.madeira-setup\\setup.exe", target: "C:\\itch\\G", title: "G")
        require(inno.contains("start \"\" /wait \"C:\\itch\\G\\.madeira-setup\\setup.exe\" /SP- /SILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL /DIR=\"C:\\itch\\G\"")
                && inno.hasPrefix("@echo off\r\n") && inno.hasSuffix("echo ran>\"%~dp0ran\"\r\n"), "Inno: silent into the game's folder, CRLF, a mark once it ended")
        let nsis = ItchSetup.script(kind: .nsis, installer: "C:\\itch\\A & B\\s.exe", target: "C:\\itch\\A & B 100%", title: "A & B")
        require(nsis.contains("/S /D=C:\\itch\\A ^& B 100%%") && nsis.contains("\"C:\\itch\\A & B\\s.exe\""), "NSIS: /D= last, unquoted, specials escaped")
        let msi = ItchSetup.script(kind: .msi, installer: "C:\\itch\\G\\g.msi", target: "C:\\itch\\G", title: "G")
        require(msi.contains("msiexec /i \"C:\\itch\\G\\g.msi\" /qb /norestart TARGETDIR=\"C:\\itch\\G\""), "MSI: msiexec with a progress bar")
        require(!ItchSetup.script(kind: .other, installer: "C:\\s.exe", target: "C:\\t", title: "x").contains("/S"), "another installer runs as it is")
        require(ItchSetup.windowsPath("itch/My Game") == "C:\\itch\\My Game", "drive_c paths as Windows paths")

        let setupGame = work.appendingPathComponent("setup-game", isDirectory: true)
        let hidden = setupGame.appendingPathComponent(ItchSetup.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try exe("Inno Setup Setup Data").write(to: hidden.appendingPathComponent("game-setup.exe"))
        require(ItchProgram.find(in: setupGame, title: "Game") == nil, "the hidden setup folder is never the game")
        require(ItchSetup.installer(in: setupGame).map { "\($0.0.rawValue) \($0.1)" } == "inno .madeira-setup/game-setup.exe", "the downloaded installer")
        let zipped = work.appendingPathComponent("zipped-setup", isDirectory: true)
        try FileManager.default.createDirectory(at: zipped.appendingPathComponent("redist"), withIntermediateDirectories: true)
        try exe("NullsoftInst").write(to: zipped.appendingPathComponent("Setup.exe"))
        try exe("x").write(to: zipped.appendingPathComponent("readme.txt"))
        require(ItchProgram.find(in: zipped, title: "Game") == nil && ItchSetup.installer(in: zipped)?.1 == "Setup.exe", "an archive with one installer")

        let drive = work.appendingPathComponent("drive_c", isDirectory: true)
        let before = Date()
        for dir in ["Program Files (x86)/Cool Game", "Program Files/Common Files/Thing", "users/mobile/AppData/Local/Programs"] {
            try FileManager.default.createDirectory(at: drive.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        require(ItchSetup.installedElsewhere(drive: drive, title: "Cool Game", since: before) == "Program Files (x86)/Cool Game",
                "the folder an installer chose, named like the game")
        require(ItchSetup.installedElsewhere(drive: drive, title: "Other", since: before) == "Program Files (x86)/Cool Game",
                "the only new folder")
        require(ItchSetup.installedElsewhere(drive: drive, title: "Other", since: Date().addingTimeInterval(3600)) == nil, "nothing new: none")

        // The unpacker.
        func unpack(_ name: String) -> (Result<UInt64, Error>, URL) {
            let target = work.appendingPathComponent("out-" + name, isDirectory: true)
            return (Result { try ItchArchive.unpack(work.appendingPathComponent(name + ".zip"), to: target) }, target)
        }
        var reported: (UInt64, UInt64) = (0, 0)
        let good = work.appendingPathComponent("out-good", isDirectory: true)
        let bytes = try ItchArchive.unpack(work.appendingPathComponent("good.zip"), to: good) { reported = ($0, $1) }
        let expected = try Data(contentsOf: work.appendingPathComponent("expected-big.bin"))
        require((try? Data(contentsOf: good.appendingPathComponent("Game/Data/big.bin"))) == expected, "deflated entry over several pieces")
        require((try? Data(contentsOf: good.appendingPathComponent("Game/raw.bin"))) == expected.prefix(3_000_000), "stored entry over several pieces")
        require((try? String(contentsOf: good.appendingPathComponent("Game/Game.exe"), encoding: .utf8)) == "MZ game", "a small file")
        require(FileManager.default.fileExists(atPath: good.appendingPathComponent("Game/empty").path), "a folder entry")
        require(bytes == reported.1 && reported.0 == reported.1 && bytes > 0, "progress ends at the total (\(reported))")
        require(!FileManager.default.fileExists(atPath: work.appendingPathComponent(".out-good.unpacking").path), "no staging folder left")
        require(ItchArchive.isZip(work.appendingPathComponent("good.zip")) && !ItchArchive.isZip(work.appendingPathComponent("expected-big.bin")), "isZip")

        let (zip64, zip64Out) = unpack("zip64")
        if case .success = zip64 { require((try? String(contentsOf: zip64Out.appendingPathComponent("a.txt"), encoding: .utf8)) == "zip64 entry", "ZIP64 archive") }
        else { require(false, "ZIP64 archive: \(zip64)") }
        let unicode = unpack("unicode")
        if case .success = unicode.0 { require(FileManager.default.fileExists(atPath: unicode.1.appendingPathComponent("Jeu/Données/é.txt").path), "UTF-8 names") }
        else { require(false, "UTF-8 names: \(unicode.0)") }

        for (name, label) in [("crc", "a damaged CRC"), ("traversal", "a name that leaves the folder"), ("absolute", "an absolute name"),
                              ("case", "two names that differ only in case"), ("symlink", "a symbolic link"), ("truncated", "a cut-off archive")] {
            // An install folder from before stays when the unpack fails.
            let target = work.appendingPathComponent("out-" + name, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: target.appendingPathComponent("old.txt").path, contents: Data("old".utf8))
            let result = Result { try ItchArchive.unpack(work.appendingPathComponent(name + ".zip"), to: target) }
            var failed = false
            if case .failure = result { failed = true }
            require(failed && FileManager.default.fileExists(atPath: target.appendingPathComponent("old.txt").path)
                    && !FileManager.default.fileExists(atPath: work.appendingPathComponent("evil.txt").path),
                    "\(label) stops the unpack and the old folder stays (\(result))")
        }
        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all itch.io Swift checks")
    }
}
'''


def make_archives(work):
    rng = random.Random(4)
    big = bytes(rng.getrandbits(8) for _ in range(1_500_000)) + b'madeira ' * 400_000   # ~4.7 MB, part compressible
    (work / 'expected-big.bin').write_bytes(big)
    with zipfile.ZipFile(work / 'good.zip', 'w') as z:
        z.writestr('Game/', '')
        z.writestr('Game/empty/', '')
        z.writestr(zipfile.ZipInfo('Game/Game.exe'), 'MZ game', compress_type=zipfile.ZIP_DEFLATED)
        z.writestr('Game/Data/big.bin', big, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr('Game/raw.bin', big[:3_000_000], compress_type=zipfile.ZIP_STORED)
    with zipfile.ZipFile(work / 'zip64.zip', 'w', allowZip64=True) as z:
        with z.open('a.txt', 'w', force_zip64=True) as f:
            f.write(b'zip64 entry')
    # Force a ZIP64 end record too: rewrite the archive with the end-of-directory fields at their ZIP64 markers.
    data = bytearray((work / 'zip64.zip').read_bytes())
    eocd = data.rfind(b'PK\x05\x06')
    if data.rfind(b'PK\x06\x06') < 0:
        cd_size = int.from_bytes(data[eocd + 12:eocd + 16], 'little')
        cd_off = int.from_bytes(data[eocd + 16:eocd + 20], 'little')
        count = int.from_bytes(data[eocd + 10:eocd + 12], 'little')
        z64 = (b'PK\x06\x06' + (44).to_bytes(8, 'little') + (45).to_bytes(2, 'little') + (45).to_bytes(2, 'little')
               + (0).to_bytes(4, 'little') + (0).to_bytes(4, 'little') + count.to_bytes(8, 'little') + count.to_bytes(8, 'little')
               + cd_size.to_bytes(8, 'little') + cd_off.to_bytes(8, 'little'))
        loc = b'PK\x06\x07' + (0).to_bytes(4, 'little') + eocd.to_bytes(8, 'little') + (1).to_bytes(4, 'little')
        end = bytearray(data[eocd:eocd + 22])
        end[10:12] = b'\xff\xff'; end[8:10] = b'\xff\xff'; end[12:16] = b'\xff\xff\xff\xff'; end[16:20] = b'\xff\xff\xff\xff'
        data = data[:eocd] + z64 + loc + end
        (work / 'zip64.zip').write_bytes(bytes(data))
    with zipfile.ZipFile(work / 'unicode.zip', 'w') as z:
        z.writestr('Jeu/Données/é.txt', 'ok')
    with zipfile.ZipFile(work / 'crc.zip', 'w') as z:
        z.writestr('a.txt', 'some content here', compress_type=zipfile.ZIP_STORED)
    data = bytearray((work / 'crc.zip').read_bytes())
    data[data.index(b'some content')] ^= 1
    (work / 'crc.zip').write_bytes(bytes(data))
    with zipfile.ZipFile(work / 'traversal.zip', 'w') as z:
        z.writestr('ok.txt', 'ok')
        z.writestr('../evil.txt', 'evil')
    # zipfile strips leading slashes: write a name of the same length, then put the slash in by hand.
    with zipfile.ZipFile(work / 'absolute.zip', 'w') as z:
        z.writestr('placeholder', 'x')
    (work / 'absolute.zip').write_bytes((work / 'absolute.zip').read_bytes().replace(b'placeholder', b'/abs/evil.t'))
    with zipfile.ZipFile(work / 'case.zip', 'w') as z:
        z.writestr('Game/Data.pak', 'a')
        z.writestr('game/data.PAK', 'b')
    with zipfile.ZipFile(work / 'symlink.zip', 'w') as z:
        info = zipfile.ZipInfo('link')
        info.create_system = 3
        info.external_attr = (0o120777 << 16)
        z.writestr(info, '/etc/passwd')
    good = (work / 'good.zip').read_bytes()
    (work / 'truncated.zip').write_bytes(good[:len(good) // 2] + good[-200:])


with tempfile.TemporaryDirectory(prefix='madeira-itch-') as tmp:
    tmp = Path(tmp)
    work = tmp / 'work'; work.mkdir()
    make_archives(work)
    (tmp / 'stubs.swift').write_text(stubs)
    (tmp / 'api.swift').write_text(api_core)
    (tmp / 'program.swift').write_text('import Foundation\n' + program)
    (tmp / 'checks.swift').write_text(checks)
    # zlib as a Swift module on Linux (Apple's SDKs have one).
    (tmp / 'zlib').mkdir()
    (tmp / 'zlib/module.modulemap').write_text('module zlib [system] {\n  header "shim.h"\n  link "z"\n  export *\n}\n')
    (tmp / 'zlib/shim.h').write_text('#include <zlib.h>\n')
    exe = tmp / 'check'
    if not Path(SWIFTC).exists() and not shutil.which(SWIFTC):
        if '--require-swift' in sys.argv:
            require(False, 'Swift compiler available (--require-swift)')
        else:
            print('SKIP: Swift compiler unavailable; the compiled itch.io checks did not run')
    else:
        extra = [] if sys.platform == 'darwin' else ['-I', str(tmp / 'zlib')]
        build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', *extra, '-o', str(exe),
                                str(tmp / 'stubs.swift'), str(tmp / 'api.swift'), str(app / 'SwiftItch/ItchArchive.swift'),
                                str(tmp / 'program.swift'), str(tmp / 'checks.swift')])
        require(build.returncode == 0, 'the itch.io sources compile on the host')
        if build.returncode == 0:
            run = subprocess.run([str(exe), str(work)])
            require(run.returncode == 0, 'itch.io checks pass')

if failures:
    print(f'FAILURES: {failures}')
    sys.exit(1)
print('PASS: itch.io store')
