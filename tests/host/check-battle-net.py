#!/usr/bin/env python3
"""[battle-net] Blizzard's Battle.net app in the library (Nov 2026).

Source checks: Add a Program shows the Battle.net row at the top of drive_c's list
(Get Battle.net downloads Blizzard's installer, Add Battle.net adds the installed
app), Game details › Launch arguments on Battle.net shows one button per Blizzard
game (--exec="launch <code>", one game at a time), env.MADEIRA_BATTLE_NET = 0
turns both off, the file is in the Xcode project, and every new UI string is in
Localizable.xcstrings. The one-game-at-a-time rule is checked on a Python copy of
the Swift tokenizer.
"""
from pathlib import Path
import json
import re

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
bn = (app / 'BattleNet.swift').read_text()
library = (app / 'Library.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
strings = json.loads((app / 'Localizable.xcstrings').read_text())['strings']
recs = (app / 'GameRecommendations.swift').read_text()

assert 'MadeiraConfig.flag("MADEIRA_BATTLE_NET", fallback: true)' in bn
assert 'https://www.battle.net/download/getInstallerForGame?os=win&version=LIVE&gameProgram=BATTLENET_APP' in bn
assert 'static let installerRelative = "users/Public/Downloads/Battle.net-Setup.exe"' in bn
assert '"Program Files (x86)/Battle.net/Battle.net Launcher.exe"' in bn
# The launcher names match the recommendation's (GameRecommendations.match).
assert 'static let launcherNames: Set<String> = ["battle.net launcher.exe", "battle.net.exe"]' in bn
assert 'case "battle.net launcher.exe", "battle.net.exe":' in recs and 'case "battle.net-setup.exe":' in recs
# Wired into Add a Program (top of drive_c only) and Launch arguments.
assert ('if BattleNet.enabled, folder.standardizedFileURL == LibraryModel.drive.standardizedFileURL {\n'
        '                BattleNetAddRow(select: select)\n') in library
assert ('LaunchFlagChips(arguments: $entry.arguments)\n'
        '                // [battle-net] Battle.net: one button per Blizzard game.\n'
        '                if BattleNet.enabled, BattleNet.isBattleNet(entry) { BattleNetGameChips(arguments: $entry.arguments) }\n') in library
# In the app target.
for line in ('A1BA7701 /* BattleNet.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2BA7701 /* BattleNet.swift */; };',
             'A2BA7701 /* BattleNet.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "BattleNet.swift"; sourceTree = "<group>"; };',
             'A2BA7701 /* BattleNet.swift */,', 'A1BA7701 /* BattleNet.swift in Sources */,'):
    assert project.count(line) == 1, line
# Blizzard's launch codes.
codes = dict(re.findall(r'Game\(title: "([^"]+)", code: "([^"]+)"\)', bn))
assert codes == {'StarCraft': 'S1', 'StarCraft II': 'S2', 'Warcraft III': 'W3', 'World of Warcraft': 'WoW', 'Diablo III': 'D3',
                 'Hearthstone': 'WTCG', 'Heroes of the Storm': 'Hero', 'Overwatch': 'Pro'}, codes
assert 'static func argument(_ code: String) -> String { "--exec=\\"launch \\(code)\\"" }' in bn
# Every new UI string has its translations.
for text in re.findall(r'L\("([^"]+)"\)', bn) + re.findall(r'Text\("([^"]+)"\)', bn):
    text = text.replace("\\'", "'")
    assert text in strings, text
    assert set(strings[text]['localizations']) == {'de', 'es', 'ko', 'pt-BR', 'ru', 'zh-Hans'}, text


# The Swift rule (BattleNet.toggled over LaunchFlagChips.tokens), in Python.
def tokens(text):
    out, cur, quoted = [], '', False
    for ch in text:
        if ch == '"':
            quoted = not quoted
        if not quoted and ch in ' \t':
            if cur:
                out.append(cur); cur = ''
        else:
            cur += ch
    if cur:
        out.append(cur)
    return out


def toggled(text, code):
    flag = '--exec="launch %s"' % code
    had = any(t.lower() == flag.lower() for t in tokens(text))
    parts = [t for t in tokens(text) if not t.lower().startswith('--exec="launch ')]
    if not had:
        parts.append(flag)
    return ' '.join(parts)


assert toggled('', 'S1') == '--exec="launch S1"'
assert toggled('--exec="launch S1"', 'S2') == '--exec="launch S2"', 'one game at a time'
assert toggled('-windowed --exec="launch S1"', 'S1') == '-windowed', 'a second tap takes it off'
assert toggled('-windowed', 'WoW') == '-windowed --exec="launch WoW"'
assert 'filter { !$0.lowercased().hasPrefix("--exec=\\"launch ") }' in bn
print('PASS: battle-net: Get/Add Battle.net row at the top of drive_c, one game button per Blizzard code (one at a time), '
      'off switch env.MADEIRA_BATTLE_NET, in the Xcode project, strings translated')
