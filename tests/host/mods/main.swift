// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// tests/host/check-mods.py compiles this with app/Madeira/ModsCore.swift. Every
// check prints "PASS: ..." or "FAIL: ..."; the last line is the count.

import Foundation

var failures = 0
func check(_ ok: Bool, _ label: String) {
    print((ok ? "PASS: " : "FAIL: ") + label)
    if !ok { failures += 1 }
}

let fm = FileManager.default
let scratch = fm.temporaryDirectory.appendingPathComponent("madeira-mods-\(getpid())", isDirectory: true)
try? fm.removeItem(at: scratch)
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)

func write(_ text: String, _ url: URL) {
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
}
func write(_ data: Data, _ url: URL) {
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}
func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

/// Every file under `folder`, relative, with its bytes: a snapshot to compare byte for byte.
func snapshot(_ folder: URL) -> [String: Data] {
    var out: [String: Data] = [:]
    let base = folder.resolvingSymlinksInPath().path
    if let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) {
        for case let url as URL in walker {
            let path = url.resolvingSymlinksInPath().path
            let rel = String(path.dropFirst(base.count + 1))
            var dir: ObjCBool = false
            _ = fm.fileExists(atPath: url.path, isDirectory: &dir)
            out[rel + (dir.boolValue ? "/" : "")] = dir.boolValue ? Data() : (try? Data(contentsOf: url))
        }
    }
    return out
}

// MARK: 1. A FOMOD with two steps and a flag condition

let fomodXML = """
<?xml version="1.0" encoding="UTF-16"?>
<Config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://qconsulting.ca/fo3/ModConfig5.0.xsd">
  <moduleName>Rock Retexture</moduleName>
  <requiredInstallFiles>
    <file source="Core\\core.esp" destination="core.esp"/>
  </requiredInstallFiles>
  <installSteps order="Explicit">
    <installStep name="Colour">
      <optionalFileGroups order="Explicit">
        <group name="Pick a colour" type="SelectExactlyOne">
          <plugins order="Explicit">
            <plugin name="Red">
              <description>Red rocks.</description>
              <image path="images\\red.png"/>
              <files><folder source="RED" destination="textures" priority="0"/></files>
              <conditionFlags><flag name="colour">red</flag></conditionFlags>
              <typeDescriptor><type name="Optional"/></typeDescriptor>
            </plugin>
            <plugin name="Blue">
              <description>Blue rocks.</description>
              <files><folder source="blue" destination="textures" priority="0"/></files>
              <conditionFlags><flag name="colour">blue</flag></conditionFlags>
              <typeDescriptor><type name="Optional"/></typeDescriptor>
            </plugin>
            <plugin name="Broken">
              <description>Never usable.</description>
              <files/>
              <typeDescriptor><type name="NotUsable"/></typeDescriptor>
            </plugin>
          </plugins>
        </group>
      </optionalFileGroups>
    </installStep>
    <installStep name="Blue extras">
      <visible><flagDependency flag="colour" value="blue"/></visible>
      <optionalFileGroups order="Explicit">
        <group name="Extras" type="SelectAny">
          <plugins order="Explicit">
            <plugin name="Shiny">
              <description>Shiny blue.</description>
              <files><file source="extras/shiny.dds" destination="textures/rock.dds" priority="5"/></files>
              <typeDescriptor>
                <dependencyType>
                  <defaultType name="Optional"/>
                  <patterns><pattern><dependencies operator="And"><flagDependency flag="colour" value="blue"/></dependencies><type name="Recommended"/></pattern></patterns>
                </dependencyType>
              </typeDescriptor>
            </plugin>
            <plugin name="Moss">
              <description>Moss.</description>
              <files><file source="extras/moss.dds" destination="textures/"/></files>
              <typeDescriptor><type name="Optional"/></typeDescriptor>
            </plugin>
          </plugins>
        </group>
      </optionalFileGroups>
    </installStep>
  </installSteps>
  <conditionalFileInstalls>
    <patterns>
      <pattern>
        <dependencies operator="Or"><flagDependency flag="colour" value="red"/></dependencies>
        <files><file source="patches/red_patch.esp" destination=""/></files>
      </pattern>
    </patterns>
  </conditionalFileInstalls>
</Config>
"""

let fomodRoot = scratch.appendingPathComponent("fomod-mod/Rock Retexture 1.2", isDirectory: true)
var utf16 = Data([0xFF, 0xFE])
utf16.append(fomodXML.data(using: .utf16LittleEndian)!)
write(utf16, fomodRoot.appendingPathComponent("FOMOD/moduleconfig.xml"))
write("core", fomodRoot.appendingPathComponent("core/Core.esp"))
write("red", fomodRoot.appendingPathComponent("red/rock.dds"))
write("blue", fomodRoot.appendingPathComponent("Blue/rock.dds"))
write("shiny", fomodRoot.appendingPathComponent("Extras/Shiny.dds"))
write("moss", fomodRoot.appendingPathComponent("extras/moss.dds"))
write("patch", fomodRoot.appendingPathComponent("Patches/red_patch.esp"))

let found = ModLayout.find(in: scratch.appendingPathComponent("fomod-mod"))
check(found.kind == .fomod && found.root.lastPathComponent == "Rock Retexture 1.2" && found.fomod != nil,
      "the mod root is the folder with fomod/ModuleConfig.xml, in any case")
do {
    let config = try FomodConfig.parse(Data(contentsOf: found.fomod!))
    check(config.moduleName == "Rock Retexture" && config.steps.count == 2 && config.steps[0].groups[0].plugins.count == 3,
          "a UTF-16 ModuleConfig.xml with mixed-case elements parses (name, 2 steps, 3 plugins)")
    check(config.steps[0].groups[0].plugins[0].image == "images\\red.png" && config.steps[0].groups[0].plugins[0].description == "Red rocks.",
          "a plugin keeps its description and image")
    var choices = FomodChoices(config)
    choices.prepare(0)
    check(choices.selected[0][0] == [0], "SelectExactlyOne starts on the first usable plugin")
    check(choices.locked(0, 0, 2), "a NotUsable plugin can't be picked")
    check(choices.next(after: 0) == nil, "the Blue extras page is hidden while the flag is red")
    var plan = try choices.plan(root: found.root).map { $0.destination }
    check(plan == ["core.esp", "red_patch.esp", "textures/rock.dds"], "red: core, the red folder and the conditional patch (\(plan))")
    choices.toggle(0, 0, 1)
    check(choices.selected[0][0] == [1], "picking Blue replaces Red")
    check(choices.next(after: 0) == 1, "the Blue extras page shows once the flag is blue")
    choices.prepare(1)
    check(choices.selected[1][0] == [0], "a pattern makes Shiny recommended, so it starts picked")
    choices.toggle(1, 0, 1)
    check(choices.selected[1][0] == [0, 1], "SelectAny takes a second plugin")
    check(choices.previous(before: 1) == 0, "Back goes to the first page")
    let blue = try choices.plan(root: found.root)
    plan = blue.map { $0.destination }
    check(plan == ["core.esp", "textures/moss.dds", "textures/rock.dds"], "blue: no patch, moss added (\(plan))")
    let rock = blue.first { $0.destination == "textures/rock.dds" }!
    check(read(rock.source) == "shiny", "a higher priority file wins over the folder's (shiny over blue)")
    // A declaration that lies about the encoding still parses.
    let lying = try? FomodConfig.parse(Data(fomodXML.utf8))
    check(lying?.moduleName == "Rock Retexture", "a UTF-8 file that says UTF-16 is read anyway")
    check((try? FomodConfig.parse(Data("<config></config>".utf8))) == nil, "an installer that installs nothing is refused")
} catch {
    check(false, "FOMOD: \(error)")
}

// MARK: 2. Layouts and target folders

let wrapped = scratch.appendingPathComponent("wrapped", isDirectory: true)
write("x", wrapped.appendingPathComponent("Outer/Inner/readme.txt"))
write("x", wrapped.appendingPathComponent("Outer/Inner/thing.dll"))
let w = ModLayout.find(in: wrapped)
check(w.root.lastPathComponent == "Inner" && w.kind == .plain, "lone wrapper folders are skipped")
let dataMod = scratch.appendingPathComponent("datamod", isDirectory: true)
write("x", dataMod.appendingPathComponent("My Mod/data/meshes/a.nif"))
check(ModLayout.find(in: dataMod).kind == .gameFolder && ModLayout.find(in: dataMod).root.lastPathComponent == "My Mod", "a mod with a Data folder")
let espMod = scratch.appendingPathComponent("espmod", isDirectory: true)
write("x", espMod.appendingPathComponent("v1/Sub/MyMod.esp"))
write("x", espMod.appendingPathComponent("v1/Sub/textures/a.dds"))
check(ModLayout.find(in: espMod).kind == .data && ModLayout.find(in: espMod).root.lastPathComponent == "Sub", "a mod with plugins")
let bep = scratch.appendingPathComponent("bep", isDirectory: true)
write("x", bep.appendingPathComponent("pack/BepInEx/core/BepInEx.dll"))
write("x", bep.appendingPathComponent("pack/winhttp.dll"))
check(ModLayout.find(in: bep).kind == .bepinex, "a BepInEx mod")
let gameWithData = scratch.appendingPathComponent("game-data", isDirectory: true)
write("x", gameWithData.appendingPathComponent("Data/FalloutNV.esm"))
let gameWithout = scratch.appendingPathComponent("game-plain", isDirectory: true)
write("x", gameWithout.appendingPathComponent("game.exe"))
let espRoot = ModLayout.find(in: espMod).root
check(ModLayout.target(gameFolder: gameWithData, content: espRoot, kind: .data) == "Data", "plugins go into the game's Data folder")
check(ModLayout.target(gameFolder: gameWithout, content: espRoot, kind: .data) == "", "no Data folder: the game's folder")
check(ModLayout.target(gameFolder: gameWithData, content: ModLayout.find(in: dataMod).root, kind: .gameFolder) == "", "a mod's own Data folder goes into the game's folder")
check(ModLayout.target(gameFolder: gameWithData, content: w.root, kind: .plain) == "", "a plain mod goes into the game's folder")
check(ModPath.clean("../x") == nil && ModPath.clean("/etc/x") == nil && ModPath.clean("C:\\x") == nil && ModPath.clean("a\\b/c") == "a/b/c",
      "paths that leave the folder are refused")

// MARK: 3. Turning mods on and off

let drive = scratch.appendingPathComponent("drive_c", isDirectory: true)
let game = drive.appendingPathComponent("Games/Fallout New Vegas", isDirectory: true)
var original = Data()
for i in 0..<70_000 { original.append(UInt8((i * 7919) & 0xff)) }
write(original, game.appendingPathComponent("Data/Textures/Rock.dds"))
write("game", game.appendingPathComponent("FalloutNV.exe"))
write("steam", game.appendingPathComponent("steam_api.dll"))
write("bsa", game.appendingPathComponent("Data/Fallout - Textures.bsa"))
write("[General]\r\nsLanguage=ENGLISH\r\n\r\n[Archive]\r\nSInvalidationFile=ArchiveInvalidation.txt\r\nbInvalidateOlderFiles=0\r\nSArchiveList=Fallout - Textures.bsa\r\n",
      drive.appendingPathComponent("users/mobile/Documents/My Games/FalloutNV/Fallout.ini"))
try! fm.createDirectory(at: drive.appendingPathComponent("users/Public"), withIntermediateDirectories: true)
let before = snapshot(game)
let iniBefore = read(drive.appendingPathComponent("users/mobile/Documents/My Games/FalloutNV/Fallout.ini"))!
var config = "env.WINEDLLOVERRIDES = video64=\n"
let bethesda = BethesdaGame.detect(steamAppID: nil, program: nil, gameFolder: game)
check(bethesda == .falloutNV && BethesdaGame.detect(steamAppID: 489830, program: nil, gameFolder: nil) == .skyrimSE
      && BethesdaGame.detect(steamAppID: nil, program: "fallout3.EXE", gameFolder: nil) == .fallout3, "the game is found by app id, program or folder")
let info = ModGame(id: "fnv", gameFolder: game, drive: drive, program: "FalloutNV.exe", bethesda: bethesda,
                   readConfig: { config }, writeConfig: { config = $0 })
let storeURL = scratch.appendingPathComponent("Mods/fnv", isDirectory: true)
var store = ModStore(folder: storeURL, game: info)

func makeMod(_ id: String, _ files: [String: String]) -> ModRecord {
    let content = storeURL.appendingPathComponent(id + "/files", isDirectory: true)
    for (name, text) in files { write(text, content.appendingPathComponent(name)) }
    let layout = ModLayout.find(in: content)
    let relative = String(layout.root.resolvingSymlinksInPath().path.dropFirst(storeURL.resolvingSymlinksInPath().path.count + 1))
    let target = ModLayout.target(gameFolder: game, content: layout.root, kind: layout.kind)
    return try! store.add(id: id, name: id, content: relative, target: target, kind: layout.kind)
}

let a = makeMod("modA", ["textures/rock.dds": "A", "ModA.esp": "esp-a", "textures/new/leaf.dds": "leaf"])
let b = makeMod("modB", ["Textures/ROCK.dds": "B", "ModB.esm": "esm-b"])
check(a.target == "Data" && a.plugins == ["ModA.esp"] && b.plugins == ["ModB.esm"], "the mods go into Data with their plugins")
let rockURL = game.appendingPathComponent("Data/Textures/Rock.dds")
let plugins = drive.appendingPathComponent("users/mobile/AppData/Local/FalloutNV/plugins.txt")
do {
    try store.enable(a.id)
    check(read(rockURL) == "A", "on: mod A's file replaces the game's (same file, other case)")
    check(!fm.fileExists(atPath: game.appendingPathComponent("Data/textures").path) || game.appendingPathComponent("Data/textures").resolvingSymlinksInPath() == game.appendingPathComponent("Data/Textures").resolvingSymlinksInPath(),
          "no second textures folder in another case")
    check(read(game.appendingPathComponent("Data/Textures/new/leaf.dds")) == "leaf", "a new file and folder")
    check(read(plugins) == "FalloutNV.esm\r\nModA.esp\r\n", "plugins.txt is made with the game's master and the plugin")
    let ini = read(drive.appendingPathComponent("users/mobile/Documents/My Games/FalloutNV/Fallout.ini"))!
    check(ini.contains("\r\nbInvalidateOlderFiles=1\r\n") && ini.contains("\r\nSInvalidationFile=\r\n") && ini.contains("SArchiveList=Fallout - Textures.bsa"),
          "Fallout.ini: bInvalidateOlderFiles=1 and SInvalidationFile= under [Archive], the rest kept")
    let iniBackup = store.backups.appendingPathComponent("users_mobile_Documents_My Games_FalloutNV_Fallout.ini")
    check(read(iniBackup) == iniBefore, "the .ini was backed up first")
    try store.enable(b.id)
    check(read(rockURL) == "B", "clash: the later mod wins")
    check(read(plugins) == "FalloutNV.esm\r\nModB.esm\r\nModA.esp\r\n", "a master goes with the masters")
    try store.disable(b.id)
    check(read(rockURL) == "A", "turning the later mod off brings back the one before it")
    try store.disable(a.id)
    check(fm.contents(atPath: rockURL.path) == original, "turning both off brings back the game's own file, byte for byte")
    check(!fm.fileExists(atPath: plugins.path), "plugins.txt Mods made goes when its last plugin does")
    // Order is install order, not the order they were turned on.
    try store.enable(b.id)
    try store.enable(a.id)
    check(read(rockURL) == "B", "B was installed later, so it wins even when A is turned on after it")
    try store.disable(b.id)
    check(read(rockURL) == "A", "and A is back when B goes off")
    try store.disable(a.id)
    // on, off, on, Remove
    try store.enable(a.id)
    try store.disable(a.id)
    check(snapshot(game) == before, "on then off: the game's folder is as it was, byte for byte")
    try store.enable(a.id)
    try store.remove(a.id)
    try store.remove(b.id)
    check(snapshot(game) == before, "on, off, on, Remove: the game's folder is as it was, byte for byte")
    check(!fm.fileExists(atPath: storeURL.appendingPathComponent("modA").path) && store.mods.isEmpty, "Remove deletes the mod's unpacked files and its record")
    let reloaded = ModStore(folder: storeURL, game: info)
    check(reloaded.manifest == store.manifest && reloaded.manifest.files.isEmpty, "mods.json keeps the manifest")
} catch {
    check(false, "on/off: \(error)")
}

// MARK: 4. What a mod may not touch

func refused(_ id: String, _ files: [String: String], _ expected: ModError) {
    let mod = makeMod(id, files)
    let snap = snapshot(game)
    do {
        try store.enable(mod.id)
        check(false, "\(id) should have been refused")
    } catch {
        check((error as? ModError) == expected && snapshot(game) == snap, "\(expected.errorDescription!) (nothing changed)")
    }
    try? store.remove(mod.id)
}
refused("valve", ["steam_api.dll": "x", "other.dll": "y"], .valveFile("steam_api.dll"))
refused("valve64", ["bin/steamclient64.dll": "x"], .valveFile("steamclient64.dll"))
refused("exe", ["falloutnv.exe": "patched", "nvse_loader.exe": "ok"], .gameProgram("falloutnv.exe"))
let outside = scratch.appendingPathComponent("outside", isDirectory: true)
try! fm.createDirectory(at: outside, withIntermediateDirectories: true)
try! fm.createSymbolicLink(at: game.appendingPathComponent("escape"), withDestinationURL: outside)
refused("escape", ["escape/evil.txt": "x", "readme.txt": "y"], .outside("escape/evil.txt"))
check(((try? fm.contentsOfDirectory(atPath: outside.path)) ?? ["?"]).isEmpty, "nothing was written through the link")
try! fm.removeItem(at: game.appendingPathComponent("escape"))
let newExe = makeMod("loader", ["nvse_loader.exe": "loader"])
check((try? store.enable(newExe.id)) != nil && read(game.appendingPathComponent("nvse_loader.exe")) == "loader", "a new program the game does not have is fine")
try? store.remove(newExe.id)

// MARK: 5. BepInEx and the game's config

let bepGame = drive.appendingPathComponent("Games/Valley", isDirectory: true)
write("game", bepGame.appendingPathComponent("Valley.exe"))
write("x", bepGame.appendingPathComponent("Valley_Data/level0"))
var bepConfig = "env.WINEDLLOVERRIDES = video64=\nfps = 60\n"
let bepStore = ModStore(folder: scratch.appendingPathComponent("Mods/valley"),
                        game: ModGame(id: "valley", gameFolder: bepGame, drive: drive, program: "Valley.exe", bethesda: nil,
                                      readConfig: { bepConfig }, writeConfig: { bepConfig = $0 }))
let bepContent = bepStore.folder.appendingPathComponent("bep1/files/BepInEx_x64_5.4/", isDirectory: true)
write("loader", bepContent.appendingPathComponent("winhttp.dll"))
write("[General]\nenabled = true\n", bepContent.appendingPathComponent("doorstop_config.ini"))
write("core", bepContent.appendingPathComponent("BepInEx/core/BepInEx.dll"))
let bepLayout = ModLayout.find(in: bepStore.folder.appendingPathComponent("bep1/files"))
let bepMod = try! bepStore.add(id: "bep1", name: "BepInEx", content: "bep1/files/BepInEx_x64_5.4",
                               target: ModLayout.target(gameFolder: bepGame, content: bepLayout.root, kind: bepLayout.kind), kind: bepLayout.kind)
check(bepLayout.kind == .bepinex && bepMod.target == "" && bepMod.bepinex, "BepInEx goes into the game's folder")
try! bepStore.enable(bepMod.id)
check(bepConfig == "env.WINEDLLOVERRIDES = video64=;winhttp=n,b\nfps = 60\n" && read(bepGame.appendingPathComponent("winhttp.dll")) == "loader",
      "on: winhttp=n,b joins the game's own WINEDLLOVERRIDES line")
try! bepStore.disable(bepMod.id)
check(bepConfig == "env.WINEDLLOVERRIDES = video64=\nfps = 60\n" && !fm.fileExists(atPath: bepGame.appendingPathComponent("winhttp.dll").path),
      "off: the line is as it was and the loader is gone")
bepConfig = ""
try! bepStore.enable(bepMod.id)
check(bepConfig == ModConfigLines.note + "\nenv.WINEDLLOVERRIDES = winhttp=n,b\n", "an empty config gets the line with a note")
try! bepStore.disable(bepMod.id)
check(bepConfig == "", "and loses it again")

// MARK: 6. plugins.txt for the newer games, and .ini edits

let sse = PluginsTxt.adding(["MyMod.esp", "MyMaster.esm"], to: "# This file is used by Skyrim to keep track of your downloaded content.\r\n*Unofficial.esp\r\n", game: .skyrimSE)
check(sse == "# This file is used by Skyrim to keep track of your downloaded content.\r\n*MyMaster.esm\r\n*Unofficial.esp\r\n*MyMod.esp\r\n",
      "Skyrim SE: each plugin with a *, the comment kept (\(sse.debugDescription))")
check(PluginsTxt.removing(["MyMod.esp", "mymaster.ESM"], from: sse, game: .skyrimSE) == "# This file is used by Skyrim to keep track of your downloaded content.\r\n*Unofficial.esp\r\n",
      "off takes them out, in any case")
check(PluginsTxt.adding(["A.esp"], to: nil, game: .fallout4) == "*A.esp\r\n", "Fallout 4: a new file lists only the plugin")
check(PluginsTxt.adding(["A.esp"], to: "Oblivion.esm\nA.esp\n", game: .oblivion) == "Oblivion.esm\nA.esp\n", "a plugin already there is not listed twice")
check(IniEdit.setting("[Display]\nx=1\n", section: "Archive", key: "bInvalidateOlderFiles", value: "1") == "[Display]\nx=1\n\n[Archive]\nbInvalidateOlderFiles=1\n",
      "a missing [Archive] section is added")
check(IniEdit.setting("[archive]\nA=1\n\n[Next]\nB=2\n", section: "Archive", key: "C", value: "3") == "[archive]\nA=1\nC=3\n\n[Next]\nB=2\n",
      "a missing key goes at the end of its section")

try? fm.removeItem(at: scratch)
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
