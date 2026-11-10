#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Game details > Settings files (app/Madeira/GameIniFiles.swift).

A game's own settings files (.ini, .cfg, boot.config, settings.xml), added per
game from its folder, AppData and Documents, edited section by section in the app.
A Unity game also gets Unity game options: its registry values in user.reg
(app/Madeira/UnityPlayerPrefs.swift). Saving rewrites only the
changed values: line endings, encoding, comments and order stay. A file the game
rewrote since it was saved here is noted when it opens.

Source checks (every host): the page is in Game details, the file is in the project,
saving refuses a file that changed while open.

Swift fixture (macOS CI with --require-swift; skipped without a compiler): the part
of GameIniFiles.swift and UnityPlayerPrefs.swift above "MARK: Views" on synthetic files.
"""
from pathlib import Path
import argparse, shutil, subprocess, sys, tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


source = (app / 'GameIniFiles.swift').read_text(encoding='utf-8')
helpers = (app / 'IniSettingHelp.swift').read_text(encoding='utf-8')
unity = (app / 'UnityPlayerPrefs.swift').read_text(encoding='utf-8')
folders = (app / 'game-config-folders.txt').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')

check('case .iniFiles: return "Settings files"' in library and
      'case .iniFiles: GameIniFilesSection(windowsPath: entry.windowsPath, gameFolder: iniGameFolder)' in library,
      'Game details has a Settings files page')
check('[.library, .iniFiles, .mods, .advanced]' in library, 'for every game but the Desktop (Mods sits between it and Advanced)')
check('Label("Add settings file", systemImage: "plus")' in source and '.sheet(' not in source,
      'the page offers "Add settings file", pushed rather than a sheet that closed by itself')
for name in ['GameIniFiles.swift', 'IniSettingHelp.swift', 'UnityPlayerPrefs.swift', 'game-config-folders.txt']:
    check(sum(name in line for line in project.splitlines()) == 4,
          f'{name} is in the Xcode project (file, build file, group, sources or resources)')
check('B1E1A002 /* game-config-folders.txt in Resources */,' in project, 'the folder list is copied into the app')
check(folders.startswith('# Where games keep their settings files') and 'ludusavi-manifest' in folders and 'pcgamingwiki' in folders.lower(),
      'the folder list says where it comes from')
rows = [line.split('\t') for line in folders.splitlines() if not line.startswith('#')]
check(len(rows) > 5000 and all(len(r) > 1 and all(p.startswith('<') for p in r[1:]) for r in rows),
      f'the folder list has {len(rows)} games, each with paths')
check(any(r[0].split('|')[0] == 'subnautica2' and '<winLocalAppData>/Subnautica2/Saved/Config/Windows' in r[1:] for r in rows),
      'Subnautica 2 (the game Cameron hit this with) is in it')
check('Import settings file' in source and '.fileImporter(' in source and 'GameConfigFolders.importFile(' in source,
      'Import settings file copies a file from Files into a settings folder')
check('IniDocument(text: decoded.text, cfgLines: GameIniFiles.isCfg(file), xml: GameIniFiles.isXML(file))' in source,
      '.cfg files open with name value lines, .xml files by element')
check('if !document.xml { Section {' in source, 'XML files have no Add setting')
check('UnityOptionsPage(gameFolder: gameFolder)' in source and 'UnityPlayerPrefs.isUnity(gameFolder:' in source,
      'a Unity game has Unity game options on its Settings files page')
unity_save = unity[unity.index('    private func save() {'):]
check(unity_save.index('EpicLibrary.shared.sessionRunning') < unity_save.index('try out.write(to: registry, options: .atomic)') and
      unity_save.index('now == original') < unity_save.index('try out.write(to: registry, options: .atomic)'),
      'Unity options are saved only while no game runs, and not over a registry that changed')
unity_model = unity[:unity.index('// MARK: Views')]
check('LibraryModel' not in unity_model and 'LogStore' not in unity_model, 'the Unity model part is Foundation only')
check('Label("Add setting", systemImage: "plus")' in source and 'self.document?.add(section: section, key: key, value: value)' in source,
      'an open file has Add setting')
check('No description for this setting yet.' not in source and 'IniSettingHelp.info(key: setting.key, section: setting.section, value: setting.value)' in source,
      'the info button always says something about the setting')
check('IniSettingHelp.breakable(setting.key)' in source and '.fixedSize(horizontal: false, vertical: true)' in source and
      '.frame(minWidth: 56, maxWidth: 150)' in source, 'setting names wrap instead of ending in "…"')
table = helpers[helpers.index('static let table = """'):]
entries = [l.strip() for l in table.splitlines()[1:] if ' | ' in l and not l.strip().startswith('#')]
check(len(entries) >= 280 and all(len(e.split(' | ')) == 3 for e in entries), f'{len(entries)} settings described, each key | title | text')
keys = [e.split(' | ')[0].lower() for e in entries]
check(len(keys) == len(set(keys)), 'no setting is described twice')
check('\\' not in table, 'no backslash in the list (it is a Swift string)')
check('SwiftUI' not in helpers and 'LibraryModel' not in helpers, 'the help is Foundation only')
save = source[source.index('    private func save() {'):]
check(save.index('now != original') < save.index('try out.write(to: url, options: .atomic)'),
      'a file that changed while open is not overwritten')
check('GameIniFiles.setSavedFingerprint(' in save and 'GameIniFiles.savedFingerprint(file), saved != GameIniFiles.fingerprint(data)' in source,
      'a game rewriting the file is noted when it opens')
foundation = source[:source.index('// MARK: Views')]
check('LibraryModel' not in foundation and 'LogStore' not in foundation, 'the model part is Foundation only')

check('.focused($focused, equals: setting.line)' in source and '.onTapGesture { focused = setting.line }' in source and
      '.simultaneousGesture(TapGesture().onEnded { focused = setting.line })' in source and
      '.focused($focused, equals: value.id)' in unity,
      'a tap anywhere on a setting row puts the cursor in its value (Wave 16: rows were hard to tap)')
check('.interactiveDismissDisabled(changed || focused != nil)' in source and '.interactiveDismissDisabled(!edits.isEmpty || focused != nil)' in unity,
      'the game page does not slide away while a value is being typed or not saved')
check('Image(systemName: "info.circle")' in source and 'info = setting' in source,
      'each setting has a blue info button with its description')

main_swift = r'''
import Foundation
func show(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: "<CR>").replacingOccurrences(of: "\n", with: "<LF>") }
let crlf = "; comment\r\n[Display]\r\niSize W=1280\r\nbFull Screen=0\r\nsD3DDevice=\"Apple M4 GPU\"\r\n\r\n[General]\r\n  sLanguage = ENGLISH  \r\nbUseThreadedAI=1\r\n"
var d = IniDocument(text: crlf)
print("sections=" + d.sections.map { "\($0.name):\($0.settings.count)" }.joined(separator: ","))
print("same=\(d.text == crlf)")
d.set(line: 2, to: "1600")
d.set(line: 7, to: "FRENCH")
print("edited=" + show(d.text))
print("value=" + (d.value(section: "display", key: "isize w") ?? "nil"))
let lf = "a=1\nb = 2"
var e = IniDocument(text: lf)
e.set(line: 1, to: "3")
print("lf=" + show(e.text))
print("switch=\(GameIniFiles.isSwitch(key: "bFull Screen", value: "1")),\(GameIniFiles.isSwitch(key: "iSize W", value: "1")),\(GameIniFiles.isSwitch(key: "bob", value: "0"))")
let latin = Data([0x61, 0x3D, 0xE9, 0x0A])
let t = IniFileText(data: latin)!
print("latin=\(t.utf8),\(t.text == "a=é\n"),\(t.data(t.text) == latin)")
let bom = Data([0xEF, 0xBB, 0xBF, 0x61, 0x3D, 0x31, 0x0A])
let u = IniFileText(data: bom)!
print("bom=\(u.bom),\(u.text == "a=1\n"),\(u.data(u.text) == bom)")
print("label=" + GameIniFiles.label("users/steamuser/Documents/My Games/FalloutNV/Fallout.ini", gameFolder: nil) + "|" +
      GameIniFiles.label("Program Files (x86)/Steam/steamapps/common/Fallout New Vegas/Fallout_default.ini",
                         gameFolder: "Program Files (x86)/Steam/steamapps/common/Fallout New Vegas"))
print("folder=" + GameIniFiles.gameFolder(relativePath: "Games/NV/FalloutNV.exe", isDirectory: false) + "|" +
      GameIniFiles.gameFolder(relativePath: "Games/NV", isDirectory: true))
let defaults = UserDefaults(suiteName: "check-ini-editor")!
defaults.removePersistentDomain(forName: "check-ini-editor")
GameIniFiles.add("x/A.ini", for: "C:\\Game", defaults: defaults)
GameIniFiles.add("x/a.ini", for: "c:\\game", defaults: defaults)
GameIniFiles.add("x/B.ini", for: "C:\\Game", defaults: defaults)
GameIniFiles.remove("x/A.ini", for: "C:\\Game", defaults: defaults)
print("list=" + GameIniFiles.files("C:\\GAME", defaults: defaults).joined(separator: ","))
let helpChecks: [Bool] = [IniSettingHelp.describe(key: "uGridsToLoad") != nil, IniSettingHelp.describe(key: "iSize W")?.hasPrefix("The game's width") == true,
                  IniSettingHelp.describe(key: "bSomethingNew") == nil, IniSettingHelp.info(key: "bSomethingNew").text.contains("switch"),
                  IniSettingHelp.describe(key: "whatever") == nil,
                  IniSettingHelp.info(key: "r.Streaming.PoolSize").title == "Texture memory (MB)",
                  IniSettingHelp.info(key: "R.STREAMING.POOLSIZE").title == "Texture memory (MB)",
                  IniSettingHelp.info(key: "+r.Streaming.PoolSize").title == "Texture memory (MB)",
                  IniSettingHelp.info(key: "r.Lumen.Something").text.hasPrefix("Part of Unreal 5's Lumen"),
                  IniSettingHelp.info(key: "r.Shadow.Virtual.Something").text.contains("virtual shadow"),
                  IniSettingHelp.info(key: "bMyVSyncOn").guessed, IniSettingHelp.info(key: "bMyVSyncOn").title == "V-sync",
                  IniSettingHelp.info(key: "Bandwidth").title != "Width (pixels)",
                  IniSettingHelp.info(key: "Title", section: "Game").title == "Game title",
                  IniSettingHelp.info(key: "Title", section: "Other").title == nil,
                  IniSettingHelp.readableName("r.Streaming.MaxTempMemoryAllowed") == "Streaming › Max Temp Memory Allowed",
                  IniSettingHelp.readableName("bUseThreadedAI") == "Use Threaded AI",
                  IniSettingHelp.breakable("r.A_B") == "r.\u{200B}A_\u{200B}B",
                  IniSettingHelp.suggestions("r.streaming.po").first?.name == "r.Streaming.PoolSize",
                  IniSettingHelp.suggestions("Title").contains(where: { $0.name == "Title" }),
                  IniSettingHelp.info(key: "mat_queue_mode").title == "Multicore drawing",
                  IniSettingHelp.info(key: "sys_spec_Shadows").text.hasPrefix("One of CryEngine's quality groups"),
                  IniSettingHelp.info(key: "window/size/mode", section: "display").title == "Window mode",
                  IniSettingHelp.info(key: "gfx-enable-gfx-jobs").title == "Graphics jobs",
                  IniSettingHelp.readableName("window/size/viewport_width") == "window › size › viewport width"]
print("help=" + helpChecks.map { "\($0)" }.joined(separator: ","))
var g = IniDocument(text: "[A]\r\nx = 1\r\n\r\n[B]\r\ny = 2\r\n")
g.add(section: "a", key: "z", value: "3")
g.add(section: "C", key: "w", value: "4")
g.add(section: "B", key: "Y", value: "9")
print("add=" + show(g.text) + "|" + g.sections.map { "\($0.name):\($0.settings.count)" }.joined(separator: ","))
var h = IniDocument(text: "")
h.add(section: "[SystemSettings]", key: "r.X", value: "1")
var top = IniDocument(text: "; c\na=1\n\n[S]\nb=2")
top.add(section: "", key: "n", value: "5")
top.add(section: "S", key: "c", value: "3")
print("addnew=" + show(h.text) + "|" + show(top.text))
let cfgText = "// autoexec\r\nfps_max 300\r\nsensitivity \"2.5\" // mouse\r\nbind \"w\" \"+forward\"\r\n+jump\r\nseta r_mode \"4\"\r\nr_Width = 1280 // CryEngine\r\nexec other.cfg\r\n-- cry comment\r\nname \"a=b\"\r\n"
var c = IniDocument(text: cfgText, cfgLines: true)
print("cfg=" + c.settings.map { "\($0.key):\($0.value)" }.joined(separator: ",") + "|\(c.text == cfgText)")
c.set(line: 1, to: "60")
c.set(line: 2, to: "3")
c.set(line: 5, to: "-1")
c.set(line: 6, to: "1600")
c.set(line: 9, to: "two words")
c.add(section: "", key: "mat_vsync", value: "0")
print("cfgset=" + show(c.text))
var q = IniDocument(text: "sD3DDevice=\"Apple M4 GPU\"\nnoequals line\n")
q.set(line: 0, to: "Other GPU")
print("quoted=\(q.settings.count)," + show(q.text))
print("files=\([GameIniFiles.isSettingsFile("a/Engine.ini"), GameIniFiles.isSettingsFile("cfg/autoexec.CFG"), GameIniFiles.isSettingsFile("X_Data/boot.config"), GameIniFiles.isSettingsFile("readme.txt"), GameIniFiles.isCfg("override.cfg"), GameIniFiles.isCfg("Engine.ini")])")
let table = GameConfigFolders.table("# note\nsubnautica2|subnautica 2\t<winLocalAppData>/Subnautica2/Saved/Config/Windows\nnewgame\t<winLocalAppData>/NewGame/Saved/Config/Windows\t<winDocuments>/My Games/NewGame/*.ini\n")
print("table=\(table.count),\(table["subnautica 2"]?.first ?? "nil")")
print("expand=" + GameConfigFolders.expand("<base>/cfg/<storeUserId>/a.ini", gameFolder: "/G/Sub/", name: "Sub") + "|" +
      GameConfigFolders.expand("<winDocuments>/My Games/<game>", gameFolder: "G/Sub", name: "Sub"))
print("fits=\([GameConfigFolders.fits("*.ini", "Engine.INI"), GameConfigFolders.fits("Win*", "WindowsNoEditor"), GameConfigFolders.fits("a?c", "abc"), GameConfigFolders.fits("*.ini", "x.ini.bak")])")
let drive2 = URL(fileURLWithPath: CommandLine.arguments[2])
print("own=" + GameConfigFolders.files(drive: drive2, gameFolder: "Steam/common/Subnautica2", table: table).joined(separator: ",") + "|" +
      GameConfigFolders.files(drive: drive2, gameFolder: "Games/Grounded", table: table).joined(separator: ",") + "|" +
      GameConfigFolders.files(drive: drive2, gameFolder: "Games/Grounded/Maine/Binaries/Win64", table: table).joined(separator: ","))
print("folders=" + GameConfigFolders.folders(drive: drive2, gameFolder: "Steam/common/Subnautica2", table: table).joined(separator: ",") + "|" +
      GameConfigFolders.folders(drive: drive2, gameFolder: "Games/NewGame", table: table).joined(separator: ","))
let imported = try! GameConfigFolders.importFile(drive2.appendingPathComponent("Downloads/Engine.ini"),
                                                 into: "users/steamuser/AppData/Local/Subnautica2/Saved/Config/Windows", drive: drive2)
let fresh = try! GameConfigFolders.importFile(drive2.appendingPathComponent("Downloads/Engine.ini"), into: "made/here", drive: drive2)
print("import=\(imported.file),\(imported.backup ?? "nil"),\(fresh.file),\(fresh.backup ?? "nil")")
let drive = URL(fileURLWithPath: CommandLine.arguments[1])
print("found=" + GameIniFiles.candidates(drive: drive, gameFolder: "Games/NV").sorted().joined(separator: ","))
let gta = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<Settings>\r\n  <version value=\"27\" />\r\n  <!-- a\r\n  <x value=\"9\" /> -->\r\n  <graphics>\r\n    <Tessellation value=\"1\" />\r\n    <LodScale value=\"1.000000\" />\r\n  </graphics>\r\n  <video>\r\n    <Windowed value=\"0\" />\r\n  </video>\r\n  <VideoCardDescription>NVIDIA &amp; Co</VideoCardDescription>\r\n</Settings>\r\n"
var x = IniDocument(text: gta, xml: true)
print("xml=" + x.sections.map { "\($0.name):" + $0.settings.map { "\($0.key)=\($0.value)" }.joined(separator: ";") }.joined(separator: ",") + "|\(x.text == gta)")
x.set(line: x.settings.first { $0.key == "Windowed" }!.line, to: "2")
x.set(line: x.settings.first { $0.key == "VideoCardDescription" }!.line, to: "A<B")
print("xmlset=" + show(x.text) + "|\(x.add(section: "graphics", key: "a", value: "1"))")
let rdr = "<rage__fwuiSystemSettingsCollection>\n  <version>37</version>\n  <graphics>\n    <textureQuality>kSettingLevel_Medium</textureQuality>\n    <msaa value=\"0\" />\n  </graphics>\n  <advancedGraphics>\n    <API>kSettingAPI_Vulkan</API>\n  </advancedGraphics>\n</rage__fwuiSystemSettingsCollection>\n"
var r = IniDocument(text: rdr, xml: true)
r.set(line: r.settings.first { $0.key == "textureQuality" }!.line, to: "kSettingLevel_Low")
print("rdr=" + r.settings.map { "\($0.section)/\($0.key)=\($0.value)" }.joined(separator: ",") + "|" + show(r.text))
print("xmlfiles=\([GameIniFiles.isSettingsFile("GTA V/settings.xml"), GameIniFiles.isSettingsFile("Settings/system.xml"), GameIniFiles.isSettingsFile("Data/items.xml"), GameIniFiles.isSettingsFile("Data/items.xml", anyXML: true)])")
let reg = "WINE REGISTRY Version 2\n\n[Software\\\\Team Cherry\\\\Hollow Knight] 1730000000\n#time=1db0\n\"Screenmanager Resolution Width_h182942802\"=dword:00000780\n\"UnityGraphicsQuality_h1669003810\"=dword:00000003\n\"MasterVolume_h2045912121\"=hex(4):00,00,00,00,00,00,f0,3f\n\"PlayerName_h1\"=hex:41,62,00\n\"Plain\"=\"a\\\\b\"\n\"Long_h2\"=hex:41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,\\\n  41,41,00\n\"Odd\"=hex(7):00,00\n\n[Software\\\\Other\\\\Game] 1\n\"Screenmanager Fullscreen mode_h3\"=dword:00000001\n"
let key = UnityPlayerPrefs.keyName(company: "Team Cherry", product: "Hollow Knight")
let vals = UnityPlayerPrefs.values(in: reg, key: key) ?? []
print("unity=" + key + "|" + vals.map { "\($0.title)=\($0.shown):\($0.editable)" }.joined(separator: ",") + "|\(UnityPlayerPrefs.values(in: reg, key: "Software\\\\Nope") == nil)")
var edits: [Int: String] = [:]
for v in vals {
    switch v.title {
    case "Screenmanager Resolution Width": edits[v.id] = "1280"
    case "MasterVolume": edits[v.id] = "0.5"
    case "PlayerName": edits[v.id] = "Zoë"
    case "Plain": edits[v.id] = "x\"y"
    case "Long": edits[v.id] = String(repeating: "B", count: 30)
    default: break
    }
}
let applied = UnityPlayerPrefs.apply(edits, to: reg, key: key) ?? "nil"
print("unityset=" + show(applied))
let again = UnityPlayerPrefs.values(in: applied, key: key) ?? []
print("unityback=" + again.map { "\($0.title)=\($0.shown)" }.joined(separator: ","))
print("unitybad=\(UnityPlayerPrefs.apply([vals[0].id: "wide"], to: reg, key: key) == nil)")
print("unitykeys=" + UnityPlayerPrefs.unityKeys(in: reg).joined(separator: ","))
'''

compiler = shutil.which('swiftc')
if not compiler:
    print('SKIP: Swift compiler unavailable locally; macOS CI must run this check with --require-swift')
    if args.require_swift:
        failures += 1
else:
    with tempfile.TemporaryDirectory(prefix='madeira-ini-') as directory:
        temporary = Path(directory)
        model = foundation.replace('import SwiftUI\n', '').replace('import UniformTypeIdentifiers\n', '')
        (temporary / 'UnityPlayerPrefs.swift').write_text(unity_model.replace('import SwiftUI\n', ''))
        (temporary / 'GameIniFiles.swift').write_text(model)
        (temporary / 'IniSettingHelp.swift').write_text(helpers)
        (temporary / 'main.swift').write_text(main_swift)
        binary = temporary / 'ini'
        subprocess.run([compiler, '-swift-version', '5', str(temporary / 'GameIniFiles.swift'), str(temporary / 'IniSettingHelp.swift'),
                        str(temporary / 'UnityPlayerPrefs.swift'), str(temporary / 'main.swift'),
                        '-o', str(binary)], check=True)
        drive = temporary / 'drive_c'
        (drive / 'users/steamuser/Documents/My Games/FalloutNV').mkdir(parents=True)
        (drive / 'users/steamuser/Documents/My Games/FalloutNV/Fallout.ini').write_text('a=1\n')
        (drive / 'Games/NV/Data').mkdir(parents=True)
        (drive / 'Games/NV/Fallout_default.ini').write_text('a=1\n')
        (drive / 'Games/NV/Data/readme.txt').write_text('x')
        (drive / 'Games/Other').mkdir(parents=True)
        (drive / 'Games/Other/other.ini').write_text('a=1\n')
        drive2 = temporary / 'drive2'
        sub = drive2 / 'users/steamuser/AppData/Local/Subnautica2/Saved/Config/Windows'
        sub.mkdir(parents=True)
        (sub / 'engine.ini').write_text('[SystemSettings]\n')
        (sub / 'Old').mkdir()
        (sub / 'Old/GameUserSettings.ini').write_text('a=1\n')
        (sub / 'notes.txt').write_text('x')
        (drive2 / 'users/Public').mkdir(parents=True)
        (drive2 / 'Steam/common/Subnautica2').mkdir(parents=True)
        (drive2 / 'Games/Grounded/Maine/Binaries/Win64').mkdir(parents=True)
        (drive2 / 'Games/Grounded/Engine/Binaries').mkdir(parents=True)
        maine = drive2 / 'users/steamuser/AppData/Local/Maine/Saved/Config/WindowsNoEditor'
        maine.mkdir(parents=True)
        (maine / 'GameUserSettings.ini').write_text('a=1\n')
        (drive2 / 'Games/NewGame').mkdir(parents=True)
        (drive2 / 'Downloads').mkdir()
        (drive2 / 'Downloads/Engine.ini').write_text('[SystemSettings]\nr.Streaming.PoolSize=600\n')
        out = dict(line.split('=', 1) for line in subprocess.run([str(binary), str(drive), str(drive2)], capture_output=True, text=True,
                                                                 check=True).stdout.splitlines())
        check(out['sections'] == 'Display:3,General:2', 'sections and settings in file order')
        check(out['same'] == 'true', 'an unchanged file comes back byte for byte')
        check(out['edited'] == '; comment<CR><LF>[Display]<CR><LF>iSize W=1600<CR><LF>bFull Screen=0<CR><LF>'
              'sD3DDevice="Apple M4 GPU"<CR><LF><CR><LF>[General]<CR><LF>  sLanguage = FRENCH  <CR><LF>bUseThreadedAI=1<CR><LF>',
              'only the changed values are rewritten; CRLF, spacing and comments stay')
        check(out['value'] == '1600', 'values are found by section and key in any case')
        check(out['lf'] == 'a=1<LF>b = 3', 'LF files without a last newline stay so')
        check(out['switch'] == 'true,false,false', 'Bethesda 0/1 switches (bName) show as switches')
        check(out['latin'] == 'false,true,true', 'a Windows Latin 1 file is saved in Latin 1')
        check(out['bom'] == 'true,true,true', 'a UTF-8 byte order mark is kept')
        check(out['label'] == 'My Games\\FalloutNV\\Fallout.ini|Fallout New Vegas\\Fallout_default.ini', 'short names')
        check(out['folder'] == 'Games/NV|Games/NV', "the game's folder: the program's, or a Steam install folder")
        check(out['list'] == 'x/B.ini', 'each game keeps its own list, once per file')
        check(out['help'] == ','.join(['true'] * 25), 'the info button: listed settings, groups, words in the name, section-only names, readable names, suggestions')
        check(out['add'] == '[A]<CR><LF>x = 1<CR><LF>z = 3<CR><LF><CR><LF>[B]<CR><LF>y = 9<CR><LF><CR><LF>[C]<CR><LF>w = 4<CR><LF>|A:2,B:1,C:1',
              'Add setting: at the end of its section, a new section at the end, an existing key gets the value; CRLF and " = " kept')
        check(out['addnew'] == '[SystemSettings]<LF>r.X=1<LF>|; c<LF>a=1<LF>n=5<LF><LF>[S]<LF>b=2<LF>c=3',
              'Add setting: an empty file gets its section; "" goes above the first section')
        check(out['cfg'] == 'fps_max:300,sensitivity:2.5,r_mode:4,r_Width:1280,name:a=b|true',
              '.cfg: name value, quoted values, // and -- comments, seta, name = value; bind, exec and +actions are not settings')
        check(out['cfgset'] == '// autoexec<CR><LF>fps_max 60<CR><LF>sensitivity "3" // mouse<CR><LF>bind "w" "+forward"<CR><LF>+jump<CR><LF>'
              'seta r_mode "-1"<CR><LF>r_Width = 1600 // CryEngine<CR><LF>exec other.cfg<CR><LF>-- cry comment<CR><LF>name "two words"<CR><LF>'
              'mat_vsync 0<CR><LF>', '.cfg: values change in place, quotes and comments stay, Add setting writes name value')
        check(out['quoted'] == '1,sD3DDevice="Other GPU"<LF>noequals line<LF>', '.ini: quotes around a value stay; lines without = are not settings')
        check(out['files'] == '[true, true, true, false, true, false]', 'the editor opens .ini, .cfg and boot.config')
        check(out['table'] == '3,<winLocalAppData>/Subnautica2/Saved/Config/Windows', 'the folder list is read by every name of a game')
        check(out['expand'] == 'G/Sub/cfg/*/a.ini|users/*/Documents/My Games/Sub', 'list paths become paths under drive_c')
        check(out['fits'] == '[true, true, true, false]', 'names match * and ? in any case')
        check(out['own'] == 'users/steamuser/AppData/Local/Subnautica2/Saved/Config/Windows/engine.ini,'
              'users/steamuser/AppData/Local/Subnautica2/Saved/Config/Windows/Old/GameUserSettings.ini|'
              'users/steamuser/AppData/Local/Maine/Saved/Config/WindowsNoEditor/GameUserSettings.ini|'
              'users/steamuser/AppData/Local/Maine/Saved/Config/WindowsNoEditor/GameUserSettings.ini',
              "the game's settings files: from the list (AppData), and an Unreal game's by its project folder")
        check(out['folders'] == 'users/steamuser/AppData/Local/Subnautica2/Saved/Config/Windows,Steam/common/Subnautica2|'
              'users/steamuser/AppData/Local/NewGame/Saved/Config/Windows,users/steamuser/Documents/My Games/NewGame,Games/NewGame',
              'import folders: the ones that exist, else each Wine user\'s (not Public), then the game\'s folder')
        check(out['import'] == 'users/steamuser/AppData/Local/Subnautica2/Saved/Config/Windows/engine.ini,'
              'users/steamuser/AppData/Local/Subnautica2/Saved/Config/Windows/engine.ini.before-import,made/here/Engine.ini,nil',
              'import keeps the file it replaces and the spelling the game uses')
        check(out['found'] == 'Games/NV/Fallout_default.ini,users/steamuser/Documents/My Games/FalloutNV/Fallout.ini',
              "candidates: the game's folder and My Games, not other games")
        check(out['xml'] == ':version=27;VideoCardDescription=NVIDIA & Co,graphics:Tessellation=1;LodScale=1.000000,video:Windowed=0|true',
              'XML: one setting per line, sections are the elements around them, comments skipped, unchanged text kept')
        check(out['xmlset'] == '<?xml version="1.0" encoding="UTF-8"?><CR><LF><Settings><CR><LF>  <version value="27" /><CR><LF>  <!-- a<CR><LF>'
              '  <x value="9" /> --><CR><LF>  <graphics><CR><LF>    <Tessellation value="1" /><CR><LF>    <LodScale value="1.000000" /><CR><LF>'
              '  </graphics><CR><LF>  <video><CR><LF>    <Windowed value="2" /><CR><LF>  </video><CR><LF>'
              '  <VideoCardDescription>A&lt;B</VideoCardDescription><CR><LF></Settings><CR><LF>|-1',
              'XML: a value attribute or element text is rewritten in place and escaped; nothing is added')
        check(out['rdr'] == '/version=37,graphics/textureQuality=kSettingLevel_Low,graphics/msaa=0,advancedGraphics/API=kSettingAPI_Vulkan|'
              '<rage__fwuiSystemSettingsCollection><LF>  <version>37</version><LF>  <graphics><LF>    <textureQuality>kSettingLevel_Low</textureQuality><LF>'
              '    <msaa value="0" /><LF>  </graphics><LF>  <advancedGraphics><LF>    <API>kSettingAPI_Vulkan</API><LF>  </advancedGraphics><LF>'
              '</rage__fwuiSystemSettingsCollection><LF>', "RDR2's system.xml: element text values")
        check(out['xmlfiles'] == '[true, true, false, true]', 'settings.xml and system.xml open; other .xml only from the list of where games keep settings')
        check(out['unity'] == 'Software\\\\Team Cherry\\\\Hollow Knight|Screenmanager Resolution Width=1920:true,UnityGraphicsQuality=3:true,'
              'MasterVolume=1:true,PlayerName=Ab:true,Plain=a\\b:true,Long=AAAAAAAAAAAAAAAAAAAAAA:true,Odd=hex(7):00,00:false|true',
              'Unity options: dword numbers, hex(4) doubles, hex text, plain text, long values; the _h number left out; other types read only')
        check(out['unityset'] == 'WINE REGISTRY Version 2<LF><LF>[Software\\\\Team Cherry\\\\Hollow Knight] 1730000000<LF>#time=1db0<LF>'
              '"Screenmanager Resolution Width_h182942802"=dword:00000500<LF>"UnityGraphicsQuality_h1669003810"=dword:00000003<LF>'
              '"MasterVolume_h2045912121"=hex(4):00,00,00,00,00,00,e0,3f<LF>"PlayerName_h1"=hex:5a,6f,c3,ab,00<LF>"Plain"="x\\"y"<LF>'
              '"Long_h2"=hex:42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,42,\\<LF>  42,42,42,42,42,42,42,42,42,00<LF>'
              '"Odd"=hex(7):00,00<LF><LF>[Software\\\\Other\\\\Game] 1<LF>"Screenmanager Fullscreen mode_h3"=dword:00000001<LF>',
              'Unity options are written in their own type, Wine style, only the changed lines')
        check(out['unityback'] == 'Screenmanager Resolution Width=1280,UnityGraphicsQuality=3,MasterVolume=0.5,PlayerName=Zoë,Plain=x"y,'
              'Long=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB,Odd=hex(7):00,00', 'written values read back the same')
        check(out['unitybad'] == 'true', 'a word in a number is refused')
        check(out['unitykeys'] == 'Software\\\\Team Cherry\\\\Hollow Knight,Software\\\\Other\\\\Game', 'a game without app.info is found by its Screenmanager values')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
