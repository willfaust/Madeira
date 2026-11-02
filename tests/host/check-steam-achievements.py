#!/usr/bin/env python3
"""Steam achievements (app/Madeira/SteamAchievements.swift).

Game details > Achievements lists a Steam game's achievements, and a banner shows each
unlock while a game runs, both read from the Steam client's own appcache/stats files
(UserGameStatsSchema_<app>.bin, UserGameStats_<account>_<app>.bin; binary KeyValues).

Source checks (every host): the page is in Game details for Steam games, the watcher starts
with the app, the file is in the project.

Swift fixture (macOS CI with --require-swift; skipped without a compiler): the part of
SteamAchievements.swift above "MARK: Views" on schema and stats files written here in
Valve's binary KeyValues format.
"""
from pathlib import Path
import argparse, os, shutil, struct, subprocess, sys, tempfile

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


source = (app / 'SteamAchievements.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
madeira_app = (app / 'MadeiraApp.swift').read_text(encoding='utf-8')
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')

check('case .achievements: if let appID = entry.steamAppID { SteamAchievementsSection(appID: appID) }' in library and
      '[.steam, .cloud, .achievements] : [.steam, .achievements]' in library, 'Steam games have an Achievements page')
check('AchievementWatcher.shared.start()' in madeira_app, 'the unlock watcher starts with the app')
check(project.count('A1009C04 /* SteamAchievements.swift in Sources */') == 2 and
      project.count('A2009C04 /* SteamAchievements.swift */') == 3, 'SteamAchievements.swift is in the app target')
check('guard running || self.wasRunning' in source and 'applicationState == .active' in source,
      'the watcher only scans while a game runs and Madeira is on screen')
check('appcache/stats' in source and 'SteamRuntime.relativeRoot' in source, "it reads the Steam client's appcache in the prefix")
foundation = source[:source.index('// MARK: Views')]
code = '\n'.join(l for l in foundation.splitlines() if not l.strip().startswith('//'))
check('LibraryModel' not in code and 'LogStore' not in code and 'UIApplication' not in code, 'the model part is Foundation only')


# Valve's binary KeyValues.
def kv(name, value):
    key = name.encode() + b'\0'
    if isinstance(value, dict):
        return b'\x00' + key + b''.join(kv(k, v) for k, v in value.items()) + b'\x08'
    if isinstance(value, str):
        return b'\x01' + key + value.encode() + b'\0'
    if isinstance(value, float):
        return b'\x03' + key + struct.pack('<f', value)
    if isinstance(value, tuple):  # ('u64', n) / ('wide', s)
        if value[0] == 'u64':
            return b'\x07' + key + struct.pack('<Q', value[1])
        return b'\x05' + key + value[1].encode('utf-16-le') + b'\0\0'
    return b'\x02' + key + struct.pack('<i', value)


schema = kv('620', {
    'gamename': 'Portal 2', 'version': 3,
    'stats': {
        '1': {'type': '4', 'id': 1, 'bits': {
            '0': {'name': 'ACH_SURVIVE', 'bit': 0, 'display': {
                'name': {'english': 'Survival of the Fittest', 'german': 'Überleben des Stärkeren', 'token': 'NEW_ACHIEVEMENT_1_0_NAME'},
                'desc': {'english': 'Wake up.', 'token': 'x'}, 'hidden': '0', 'icon': 'abc123.jpg', 'icon_gray': 'def456.jpg'}},
            '1': {'name': 'ACH_SECRET', 'bit': 1, 'display': {'name': 'Secret', 'desc': 'Shh', 'hidden': 1, 'icon': 'aaa.jpg'}},
            '5': {'name': 'ACH_SIX', 'bit': 5, 'display': {'name': {'english': 'Six'}, 'desc': {'english': ''}}},
        }},
        '2': {'type': '1', 'id': 2, 'name': 'kills', 'ratio': 0.5, 'big': ('u64', 1 << 40), 'wide': ('wide', 'hé')},
    },
}) + b'\x08'
stats_before = kv('cache', {'crc': 123, 'PendingChanges': 0, '1': {'data': 0b000001, 'AchievementTimes': {'0': 1700000000}}}) + b'\x08'
stats_after = kv('cache', {'crc': 124, 'PendingChanges': 0, '1': {'data': 0b100011, 'AchievementTimes': {'0': 1700000000, '1': 1800000000}}}) + b'\x08'

main_swift = r'''
import Foundation
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let schema = try! SteamBinaryValue.read(Data(contentsOf: dir.appendingPathComponent("schema.bin")))
let before = SteamAchievements.unlocks(try! SteamBinaryValue.read(Data(contentsOf: dir.appendingPathComponent("before.bin"))))
let after = SteamAchievements.unlocks(try! SteamBinaryValue.read(Data(contentsOf: dir.appendingPathComponent("after.bin"))))
let en = SteamAchievements.schema(schema, language: "english")
let de = SteamAchievements.schema(schema, language: "german")
print("game=" + en.game)
print("list=" + en.achievements.map { "\($0.id):\($0.apiName):\($0.name):\($0.hidden)" }.joined(separator: ","))
print("german=" + de.achievements[0].name + "|" + de.achievements[0].detail)
print("before=" + before.keys.sorted().map { "\($0)@\(Int(before[$0]!.timeIntervalSince1970))" }.joined(separator: ","))
print("new=" + SteamAchievements.newlyUnlocked(before: before, now: after).joined(separator: ","))
let merged = SteamAchievements.merge(en.achievements, after)
print("merged=" + merged.map { $0.unlocked == nil ? "-" : String(Int($0.unlocked!.timeIntervalSince1970)) }.joined(separator: ","))
print("icon=" + (merged[0].iconURL(appID: 620)?.absoluteString ?? "nil") + "|" + (en.achievements[0].iconURL(appID: 620)?.absoluteString ?? "nil"))
let stat = schema.children[0].1["stats"]?["2"]
print("types=\(stat?["ratio"]?.string ?? "")|\(stat?["big"]?.int ?? 0)|\(stat?["wide"]?.string ?? "")")
print("file=" + [SteamAchievements.statsFile("UserGameStats_12345_620.bin").map { "\($0.account)/\($0.app)" } ?? "nil",
                 SteamAchievements.statsFile("UserGameStatsSchema_620.bin").map { "\($0.app)" } ?? "nil"].joined(separator: "|"))
let cut = Data(try! Data(contentsOf: dir.appendingPathComponent("after.bin")).prefix(20))
print("truncated=\((try? SteamBinaryValue.read(cut)) == nil ? "refused" : "read")")
'''

compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
if not compiler:
    print('SKIP: Swift compiler unavailable locally; macOS CI must run this check with --require-swift')
    if args.require_swift:
        failures += 1
else:
    with tempfile.TemporaryDirectory(prefix='madeira-achievements-', dir=os.environ.get('TMPDIR')) as directory:
        temporary = Path(directory)
        body = foundation
        for line in ('import SwiftUI\n', 'import UIKit\n'):
            body = body.replace(line, '')
        (temporary / 'SteamAchievements.swift').write_text(body)
        (temporary / 'main.swift').write_text(main_swift)
        (temporary / 'schema.bin').write_bytes(schema)
        (temporary / 'before.bin').write_bytes(stats_before)
        (temporary / 'after.bin').write_bytes(stats_after)
        binary = temporary / 'achievements'
        subprocess.run(compiler.split() + ['-swift-version', '5', str(temporary / 'SteamAchievements.swift'),
                                           str(temporary / 'main.swift'), '-o', str(binary)], check=True)
        out = dict(line.split('=', 1) for line in subprocess.run([str(binary), str(temporary)], capture_output=True,
                                                                 text=True, check=True).stdout.splitlines())
        check(out['game'] == 'Portal 2', "the schema names the game")
        check(out['list'] == '1/0:ACH_SURVIVE:Survival of the Fittest:false,1/1:ACH_SECRET:Secret:true,1/5:ACH_SIX:Six:false',
              'achievements are read from every stat with bits, language tables and plain names alike')
        check(out['german'] == 'Überleben des Stärkeren|Wake up.', "Steam's game language is used, English when it has none")
        check(out['before'] == '1/0@1700000000', 'unlock bits and times are read from the stats file')
        check(out['new'] == '1/1,1/5', 'a newly set bit is an unlock (the banner)')
        check(out['merged'] == '1700000000,1800000000,0', 'an unlock without a time is still unlocked')
        check(out['icon'] == 'https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/620/abc123.jpg|'
              'https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/620/def456.jpg',
              "unlocked achievements show their icon, locked ones the grey one, from Steam's CDN")
        check(out['types'] == '0.5|1099511627776|hé', 'float, uint64 and wide-string values read')
        check(out['file'] == '12345/620|nil', 'stats files are told apart from schema files')
        check(out['truncated'] == 'refused', 'a file read mid-write is refused, not half-read')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
