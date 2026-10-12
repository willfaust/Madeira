import Foundation

func check(_ condition: Bool, _ label: String) {
    if !condition { print("FAIL: \(label)"); exit(1) }
}

let lua = """
-- a comment
local game = {
  name = "Test Game",
  appid = 4242,
  exe = "bin\(slash)\(slash)game.exe",
  installdir = "TestGame",
  download = "https://example.com/game.zip",
}
"""
let plan = try GameImportRules.plan(data: Data(lua.utf8), fileName: "game.lua")
check(plan.title == "Test Game", "lua title")
check(plan.source == .lua, "lua source")
check(plan.appID == 4242, "lua appid")
check(plan.exe == "bin/game.exe", "lua exe")
check(plan.installDir == "TestGame", "lua installdir")
check(plan.download?.host == "example.com", "lua download")
check(plan.exeRelative == "TestGame/bin/game.exe", "lua exeRelative")

let derived = try GameImportRules.plan(data: Data("""
game = { name = "Half-Life: Source", download = "https://cdn.example.org/hls.zip" }
""".utf8), fileName: "hls.lua")
check(derived.installDir == "Half-Life Source", "derived installdir")
check(derived.exe == nil, "derived exe")

let manifest = """
"AppState"
{
  "appid"  "440"
  "name"   "Team Fortress 2"
  "installdir"  "Team Fortress 2"
}
"""
let steam = try GameImportRules.plan(data: Data(manifest.utf8), fileName: "appmanifest_440.acf")
check(steam.title == "Team Fortress 2", "manifest title")
check(steam.source == .manifest, "manifest source")
check(steam.appID == 440, "manifest appid")
check(steam.installDir == "Program Files (x86)/Steam/steamapps/common/Team Fortress 2", "manifest installdir")
check(steam.download == nil && steam.exe == nil, "manifest no exe/download")

check(GameImportRules.relativeExe("C:\\Games\\g.exe") == "Games/g.exe", "relativeExe drive")
check(GameImportRules.relativeExe("Games/g.exe") == "Games/g.exe", "relativeExe plain")
check(GameImportRules.relativeExe("..\\g.exe") == nil, "relativeExe parent")
check(GameImportRules.folderName(forTitle: "Half-Life: Source?") == "Half-Life Source", "folderName")
check(GameImportRules.downloadURL("http://example.com/g.zip") == nil, "download http rejected")
check(GameImportRules.downloadURL("https://example.com/g.7z") == nil, "download 7z rejected")
check(GameImportRules.downloadURL("https://user:pw@example.com/g.zip") == nil, "download credentials rejected")
check(GameImportRules.downloadURL("https://example.com/G.ZIP") != nil, "download zip case")

func fails(_ data: Data, _ name: String, containing text: String) {
    do { _ = try GameImportRules.plan(data: data, fileName: name); print("FAIL: \(name) accepted"); exit(1) }
    catch let error as GameImportError {
        check(error.localizedDescription.contains(text), "error \(name): \(error.localizedDescription)")
    } catch { print("FAIL: \(name) wrong error"); exit(1) }
}
fails(Data("game = { name = \"x\" }".utf8), "no-exe.lua", containing: "download")
fails(Data("game = { name = \"x\", exe = \"a/b.exe\", installdir = \"a/b\" }".utf8), "bad-dir.lua", containing: "installdir")
fails(Data("game = { name = \"x\", exe = \"a/b.exe\", installdir = \"a\", appid = 12.5 }".utf8), "appid.lua", containing: "whole")
fails(Data("game = { name = \"x\", exe = \"a/b.dll\", installdir = \"a\" }".utf8), "dll.lua", containing: ".exe")
fails(Data("game = { name = \"x\", exe = \"a/b.exe\", installdir = \"a\", download = \"https://e.com/g.7z\" }".utf8), "7z.lua", containing: "https")
fails(Data("game = { name = foo }".utf8), "ident.lua", containing: "does not read")
fails(Data("\"AppState\" { \"installdir\" \"x\" }".utf8), "noappid.acf", containing: "App ID")

// oversized script
var big = Data("game = { name = \"".utf8)
big.append(Data(count: (1 << 20) + 8))
big.append(Data("\", exe = \"a/b.exe\", installdir = \"a\" }".utf8))
fails(big, "big.lua", containing: "too large")

print("game-import rules OK")
