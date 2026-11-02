#!/usr/bin/env python3
"""Madeira's built-in recommended settings per game (owner's decision 2026-10-09).

Source checks (every host): the lists in app/Madeira/GameRecommendations.swift
match the working lists they were taken from (Red Dead Redemption 2's line for
line), every key that is not env.NAME is one Madeira reads (the generated
settings catalog), no list overrides Social Club's DLLs, and the app applies them where the owner asked: a game's first sight (library
start-up, saving an entry, Game details, a start) and Reset to Recommended at
the bottom of Game details. Every game's own list ends with madeira-bcd's
defaults where upstream's differ, because madeira-bcd's games ran with them: MADEIRA_FREE_DELAY_MS = 2000, MADEIRA_CTX_CPU_AREA = 2 (madeira-bcd's
fuller GetThreadContext; 1 is the control-only form) and MADEIRA_WAIT_CHILDREN = 1
(opt-in here) and MADEIRA_JIT_DUMP = 0 (here the JIT-pool dump is on by
default; madeira-bcd's is opt-in). The standard list, which every other game and
the Desktop get, has none of them (version 3): MADEIRA_FREE_DELAY_MS keeps a
released block's addresses taken, so an allocator that reserves, releases and
reserves again inside that range spins (Madeira Dock before Thumper). No list names madeira-bcd's dxgi-src.dll / d3d11-src.dll
switches (env.MADEIRA_DXGI_SRC, env.MADEIRA_D3D11_SRC): here DXMT's own dxgi.dll
and d3d11.dll carry those changes.

The Swift fixture (macOS CI) compiles the real GameRecommendations.swift and
GameRecommendationsApply.swift against small stand-ins for the app types and
checks how games are recognised (Steam games by App ID or by their folder
under steamapps\\common, every other game by its program's name, GTA V
Enhanced inside or outside a Steam library) and the first-sight, update and
reset rules, the Desktop's too. Linux hosts without Swift run the source checks; --require-swift
turns a missing compiler into a failure.
"""
from pathlib import Path
import argparse
import os
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
lists_src = (app / 'GameRecommendations.swift').read_text()
apply_src = (app / 'GameRecommendationsApply.swift').read_text()
library = (app / 'Library.swift').read_text()
prefs = (app / 'LibraryPrefs.swift').read_text()
content = (app / 'ContentView.swift').read_text()
profiles = (app / 'GameProfiles.swift').read_text()
catalog = (app / 'ConfigCatalog.generated.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()


def block(source, start, end):
    i = source.index(start)
    return source[i:source.index(end, i) + len(end)]


# The lists, as Swift sees them: the multi-line literal loses its closing
# delimiter's indentation.
presets = {}
for m in re.finditer(r'static let (\w+) = GameRecommendation\(\n\s*id: "([^"]+)", title: "([^"]+)", version: (\d+),\n'
                     r'\s*config: """\n(.*?)\n( *)"""(?:,\n(.*?))?\)\n', lists_src, re.S):
    name, ident, title, version, body, indent, switches = m.groups()
    # Swift's escape for a backslash is the only one the lists use (.be\\vc_redist).
    assert '\\' not in body.replace('\\\\', ''), (ident, 'a Swift escape other than \\\\')
    body = body.replace('\\\\', '\\')
    lines = [line[len(indent):] if line.startswith(indent) else line for line in body.split('\n')]
    presets[ident] = dict(name=name, title=title, version=int(version), lines=lines, switches=' '.join((switches or '').split()))
# The Steam titles merged on 2026-10-26 from community tested lists (GameRecommendations.steamTitles); Dark Souls III
# has its own tested list (darkSoulsIII), which replaced the community one.
MERGED = {'msfs-2024', 'counter-strike-2', 'breakneck', 'spelunky-2', 'albion-online', 'hogwarts-legacy',
          'metal-gear-solid-v', 'stellar-blade-demo', 'star-wars-galactic-racer', 'minecraft-dungeons-2', 'denshattack', 'final-fantasy-resonance-demo',
          'no-rest-for-the-wicked', 'quaver', 'dying-light', 'beamng-drive', 'monster-hunter-stories-3-trial', 'pwaat',
          'american-truck-simulator', 'marvels-spider-man-miles-morales', 'diablo-ii-resurrected', 'clair-obscur-expedition-33', 'gtasa-de-steam', 'unrailed-2-back-on-track',
          'blazblue-entropy-effect', 'marvels-spider-man-remastered', 'marvels-spider-man-2', 'raidou-remastered', 'yakuza-like-a-dragon',
          'batman-arkham-city-goty', 'trails-in-the-sky-1st-chapter', 'subnautica-2', 'rdr1-steam', 'resident-evil-requiem', 'resident-evil-requiem-demo',
          'life-is-strange-remastered', 'life-is-strange-2', 'project-zomboid', 'spiderheck', 'rounds', 'plateup',
          'final-fantasy-tactics-ivalice-chronicles', 'jetboard-joust', 'dead-as-disco', 'tung', 'sekiro-shadows-die-twice', 'stardew-valley',
          'glyphica-typing-survival', 'the-adventures-of-elliot'}
assert set(presets) == {'rdr2-steam', 'rdr2-other', 'gta5e-steam', 'gta5e-other', 'gta5l-steam', 'gta5l-other', 'gta4-steam',
                        'ghost-of-tsushima', 'god-of-war', 'horizon-zero-dawn', 'horizon-forbidden-west', 'ratchet-clank-rift-apart',
                        'crysis-remastered', 'crysis-2-remastered', 'crysis-3-remastered', 'rockstar-launcher', 'rockstar-launcher-setup',
                        'steam-big-picture', 'dark-souls-remastered', 'dark-souls-iii', 'fallout-new-vegas', 'fallout-3', 'black-ops-2',
                        'standard'} | MERGED, \
    sorted(presets)
assert ('static let all = [rdr2Steam, rdr2Other, gta5EnhancedSteam, gta5EnhancedOther, gta5LegacySteam, gta5LegacyOther, gta4Steam,\n'
        '                      ghostOfTsushima, godOfWar, horizonZeroDawn, horizonForbiddenWest, ratchetClankRiftApart, crysisRemastered,\n'
        '                      crysis2Remastered, crysis3Remastered, rockstarLauncher, rockstarLauncherSetup, steamBigPicture,\n'
        '                      darkSoulsRemastered, darkSoulsIII, falloutNewVegas, fallout3, blackOps2, standard]\n'
        '        + steamTitles.map(\\.list)') in lists_src
# The Rockstar Games Launcher outside Steam (logs 91-93, 2026-10-28): Launcher.exe in its own folder gets the
# launcher chain's lines, its installer the standard line; both start in the Wine desktop with Windows services.
assert ('        case "launcher.exe" where Array(parts.dropLast().suffix(2)) == ["rockstar games", "launcher"]:\n'
        '            // The Rockstar Games Launcher outside Steam; another publisher\'s Launcher.exe gets nothing here.\n'
        '            return rockstarLauncher\n'
        '        case "rockstar-games-launcher.exe":\n'
        '            return rockstarLauncherSetup\n') in lists_src
for ident in ('rockstar-launcher', 'rockstar-launcher-setup'):
    assert presets[ident]['switches'].endswith('launchMode: "desktop", startServices: true'), (ident, presets[ident]['switches'])
launcher_lines = set(presets['rockstar-launcher']['lines'])
for line in ('env.MADEIRA_SC_PA_POOLS = 2', 'env.MADEIRA_X64_IMAGE_NOCOPY = 1', 'pool-low = 1', 'pool-split = 1',
             'env.MADEIRA_POOL_LOW_IMAGES = 1', 'env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist',
             'env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe'):
    assert line in launcher_lines, ('rockstar-launcher', line)
assert not any(l.startswith('env.MADEIRA_SPAWN_BLOCK') for l in presets['rockstar-launcher-setup']['lines']), \
    'the installer runs its embedded vc_redist'
assert 'if let mode = rec.launchMode { entry.launchMode = mode == "desktop" ? mode : nil }' in apply_src
assert 'if let on = rec.startServices { entry.startServices = on ? true : nil }' in apply_src
# Every merged list is in the recognition table, once.
titles_src = block(lists_src, '    static let steamTitles: [SteamTitle] = [', '\n    ]\n')
for ident in MERGED:
    assert titles_src.count('list: %s)' % presets[ident]['name']) == 1, ident
assert titles_src.count('SteamTitle(') == len(MERGED)
# ml2021: the Big Picture entry (C:\big-picture.bat) is recognised by its batch name and gets the Steam Big Picture list
assert 'if last == "big-picture.bat" { return steamBigPicture }' in lists_src
assert 'static var bigPictureEntry: LibraryEntry' in library and 'relativePath: "big-picture.bat"' in library \
    and 'entry.bigPicture = true' in library and 'entry.launchMode = "desktop"' in library, 'the library offers the Big Picture entry (desktop-mode batch)'
assert 'if bigPicture == true { Self.writeBigPictureBatch() }' in library \
    and '-bigpicture -no-cef-sandbox" + (gpu ? "" : " -cef-disable-gpu") + " -console -nocrashmonitor"' in library \
    and 'MadeiraConfig.flag("MADEIRA_BIG_PICTURE_GPU", fallback: false)' in library, \
    'the batch (services.exe, then steam.exe -bigpicture) is written at every launch; software drawing unless env.MADEIRA_BIG_PICTURE_GPU = 1'
# ml2210 (version 3): the 32-bit web helper's crash reporter may start, no Social Club pool layout, and an
# installed 32-bit client is kept (no bootstrap update) unless env.MADEIRA_BIG_PICTURE_PIN = 0.
# ml2230 (version 4, logs 111-112): CEF's verbose log is off. Version 5 (logs 113-114): V8 is interpreted again
# (version 4's MADEIRA_JITLESS = 0 froze the UI: every store to its pool-aliased code space was emulated).
bp = presets['steam-big-picture']
assert bp['version'] == 6 and 'env.MADEIRA_STEAM_ALLOW_CRASHPAD = 1' in bp['lines'] and 'env.MADEIRA_SRW_HANG_KILL_S = 40' in bp['lines'] \
    and not any(l.startswith('env.MADEIRA_JITLESS') for l in bp['lines']) and 'env.MADEIRA_CEF_VERBOSE = 0' in bp['lines'] \
    and not any(l.startswith('env.MADEIRA_SC_PA_POOLS') for l in bp['lines']), bp
# ml2230: Big Picture's libraryfolders.vdf (config/ and steamapps/) gets Madeira's Steam library and the drives'
# libraries beside its own entries, before each start (env.MADEIRA_BIG_PICTURE_LIBRARIES = 0 leaves them alone).
assert 'listMadeiraLibraries(in: folder)' in library \
    and 'MadeiraConfig.flag("MADEIRA_BIG_PICTURE_LIBRARIES", fallback: true)' in library \
    and 'var libraries = [own]' in library \
    and 'for sub in ["config", "steamapps"]' in library \
    and 'try ExternalSteamLibraries.add(paths: libraries, to: existing)' in library, \
    'Big Picture lists the games Madeira installed'
# ml2240: every library Madeira's Steam list reads, including the other C: libraries the Dock client's
# libraryfolders.vdf names (env.MADEIRA_BIG_PICTURE_DOCK_LIBRARIES = 0: its own folder and the drives only).
dock = (app / 'MadeiraDock.swift').read_text()
assert 'MadeiraConfig.flag("MADEIRA_BIG_PICTURE_DOCK_LIBRARIES", fallback: true)' in library \
    and '? MadeiraDock.steamLibraries(drive: MadeiraDock.drive)' in library \
    and 'static func steamLibraries(drive: URL) -> [String] {' in dock \
    and 'let libraries = steamLibraries(drive: drive)' in dock, 'Big Picture reads the Dock\'s library list'
assert 'MadeiraConfig.flag("MADEIRA_BIG_PICTURE_PIN", fallback: true)' in library \
    and 'fm.fileExists(atPath: "\\(folder.unix)/bin/cef/cef.win7/steamwebhelper.exe")' in library \
    and '(pinned ? " -nobootstrapperupdate -skipinitialbootstrap" : "")' in library
# Big Picture is compiled out of every build without the MADEIRA_BIG_PICTURE_UI condition (no IPA build sets it).
bp_button = library[library.index('#if MADEIRA_BIG_PICTURE_UI\n            if LibraryEntry.steamClientInstalled {'):]
bp_button = bp_button[:bp_button.index('#endif')]
assert 'Label("Big Picture", systemImage: "gamecontroller")' in bp_button and '.id(LibraryEntry.bigPictureID)' in bp_button, \
    'the Big Picture button exists only under MADEIRA_BIG_PICTURE_UI'
assert library.count('Label("Big Picture", systemImage: "gamecontroller")') == bp_button.count('Label("Big Picture", systemImage: "gamecontroller")'), \
    'no Big Picture button outside that block'
assert '#if MADEIRA_BIG_PICTURE_UI\n    static let bigPictureShown = true\n#else\n    static let bigPictureShown = false\n#endif' in library \
    and 'MADEIRA_BIG_PICTURE"' not in library \
    and library.count('$0.desktop != true && $0.listedInLibrary') == 2 and 'entry.desktop != true && entry.listedInLibrary' in library, \
    'without MADEIRA_BIG_PICTURE_UI no Big Picture card is listed, and no runtime switch brings it back'

# madeira-bcd's defaults where upstream's differ: every game madeira-bcd ran had them,
# so every game's own list ends with them. The standard list reaches every other game
# and the Desktop, and has none of them. A list that sets one of them itself
# (Horizon Forbidden West and Rift Apart: MADEIRA_FREE_DELAY_MS = 0) leaves it out of the block.
FORK_DEFAULTS = ["# The defaults this list was tested with (upstream's differ).",
                 'env.MADEIRA_FREE_DELAY_MS = 2000', 'env.MADEIRA_CTX_CPU_AREA = 2', 'env.MADEIRA_WAIT_CHILDREN = 1',
                 'env.MADEIRA_JIT_DUMP = 0']
for ident, p in presets.items():
    if ident in ('dark-souls-remastered', 'dark-souls-iii'):
        p['tested'], p['fork'] = [line for line in p['lines'][2:] if not line.startswith('#')], []
        continue
    # The Fallout lists are the standard one plus a switch: the games ran with it.
    if ident in ('standard', 'fallout-new-vegas', 'fallout-3', 'black-ops-2'):
        assert not set(FORK_DEFAULTS) & set(p['lines']), (ident, "the standard list has none of madeira-bcd's defaults")
        p['tested'], p['fork'] = p['lines'][2:], []
        continue
    assert FORK_DEFAULTS[0] in p['lines'], (ident, "the list ends with the tested defaults")
    c = p['lines'].index(FORK_DEFAULTS[0])
    own = {line.partition(' = ')[0] for line in p['lines'][2:c]}
    tail = [FORK_DEFAULTS[0]] + [line for line in FORK_DEFAULTS[1:] if line.partition(' = ')[0] not in own]
    assert p['lines'][c:] == tail, (ident, "the list ends with the community build's defaults it does not set itself")
    p['tested'], p['fork'] = p['lines'][2:c], tail[1:]

catalog_keys = set(re.findall(r'ConfigOption\(key: "([^"]+)"', catalog))
for ident, p in presets.items():
    assert p['version'] >= 1, ident
    assert p['lines'][0].startswith('# Madeira') and p['lines'][1].startswith('# Reset to Recommended'), ident
    seen = set()
    for line in p['tested'] + p['fork']:
        assert line == line.strip() and not line.startswith('#'), (ident, line)
        key, sep, value = line.partition(' = ')
        assert sep and key and value, (ident, line)
        assert key not in seen, (ident, 'twice', key)
        seen.add(key)
        assert key not in ('env.MADEIRA_DXGI_SRC', 'env.MADEIRA_D3D11_SRC'), (ident, 'a madeira-bcd variant DLL switch', key)
        if key.startswith('env.'):
            assert re.fullmatch(r'env\.[A-Za-z_][A-Za-z0-9_]*', key), (ident, key)
        else:
            assert key in catalog_keys, (ident, 'not a key Madeira reads', key)
        # Madeira's own settings only: no list overrides Social Club's DLLs. SocialClubHelper.exe
        # may be named as a program in a list (env.DXMT_SMALL_RINGS), never in a DLL override.
        named = line.lower()
        if key != 'env.WINEDLLOVERRIDES':
            named = named.replace('socialclubhelper.exe', '')
        assert 'socialclub' not in named and 'MADEIRA_DLL_LOCAL' not in line, (ident, line)
for ident in ('fallout-new-vegas', 'fallout-3'):
    assert presets[ident]['tested'] == presets['standard']['tested'] and presets[ident]['switches'] == 'olderNvidia: true', presets[ident]
print('PASS: seventy-three lists (twenty-four plus 49 merged Steam titles), two comment lines each, every game list but Dark Souls ends with the four fork defaults and the standard, Fallout and Black Ops II ones have none, no key twice, '
      'every non-env key in the settings catalog, no Social Club DLL lines, no variant DLL switches')

# Red Dead Redemption 2 from Steam: the owner's list of 2026-10-09 (build 463), line for line,
# plus the lines of build 466's test (version 2), build 467's (version 3), build 470's (version 4) and
# build 472's (version 5: pool-mid), build 475's (version 6: ring-share), build 476's (version 7:
# swap-images, small DXMT rings for the launcher and Social Club, the ExecuteIndirect probe off)
# and build 480's (version 9: xinput1_4.dll loaded with the D3D12 device, the pool back to 128 MB of
# image headroom after 479's 192 starved the game's code buffer, the orphan-lock reaper stamped-only)
# and build 514's (version 10: the VC++ setup's elevated engine is not started; it crashed with a lock
# held and the first install waited forever). Without madeira-bcd's env.MADEIRA_D3D11_SRC and
# env.MADEIRA_DXGI_SRC lines: here DXMT's own d3d11.dll and dxgi.dll carry those changes.
rdr2 = '''d3d12-caps-log = 2
d3d12-shader-pack = 1
replay-split = 1
ring-share = 1
pool-low = 1
pool-mid = 1
pool-page-fit = 1
pool-split = 1
vram-mb = 2304
swap-mb = 8192
swap-mode = 2
swap-min-mb = 1
swap-images = 1
pso-warm = 2
fence-chain = 6
avail-phys = 1
indirect-fast = 1
ind-probe = 0
fullscreen-window = 1
env.WINE_D3D_CONFIG = renderer=no3d
env.FEX_VECTORTSOENABLED = 0
env.MADEIRA_BAND_CENSUS = 1
env.MADEIRA_RDR2_VA_HOLD = 1
env.MADEIRA_SWAP_RESERVE_MAX_MB = 9216
env.MADEIRA_THREAD_STACK_SPILL = 1
env.MADEIRA_SMALL_STACK_EXES = RDR2.exe
env.MADEIRA_DOCK_GAME_SCM = 1
env.MADEIRA_DOCK_KEEP_ALIVE = Launcher.exe;RDR2.exe
env.MADEIRA_DXGI_BUDGET_EVENTS = 1
env.DXMT_WSI_MONITOR_IDENTITY = 1
env.DXMT_WSI_MODE_TABLE = 1
env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe
env.MADEIRA_EXECREQ_LEAVE = 1
env.MADEIRA_LOCK_ORPHAN = stamped
env.MADEIRA_PIN_GRAPHICS_DLLS = 1
env.MADEIRA_PRELOAD_DLLS = xinput1_4.dll
env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
env.MADEIRA_POOL_LOW_IMAGES = 1
env.MADEIRA_POOL_RECYCLE_IMAGES = 1
env.MADEIRA_SC_PA_POOLS = 2
env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist
env.MADEIRA_TOUCH_MOUSE = 1
env.MADEIRA_WOW_MIN_FREE_GB = 2
env.MADEIRA_X64_GRAPHICS_ENTRY = 1
env.MADEIRA_X64_IMAGE_NOCOPY = 1
env.WINEDLLOVERRIDES = video64=
env.MADEIRA_DEVICE_STATS = 1
env.MADEIRA_METAL_HUD_MAIN = 1'''.split('\n')
assert presets['rdr2-steam']['tested'] == rdr2, 'the RDR2 list differs from the owner\'s'
assert presets['rdr2-steam']['version'] == 10, presets['rdr2-steam']['version']
assert presets['rdr2-steam']['switches'] == ('avx: false, nvidia: false, wineVCRT: false, fastSync: true, '
                                             'semaphoreFastPath: false, resolution: GameRecommendation.screen720, display: "fit"'), presets['rdr2-steam']['switches']
assert 'static let screen720 = "screen@720"' in lists_src and 'resolution == Self.screen720 ? "this screen\'s shape at 720 lines" : resolution' in lists_src
# Red Dead Redemption 2 outside Steam (Rockstar Games Launcher or another store; owner's request, 2026-10-12):
# derived from the Steam copy's lines without the two only Madeira Dock reads, plus the ec-hook reporter off,
# which GTA V Enhanced's list outside Steam has; the same switches. Not device-tested on its own.
rdr2_other = presets['rdr2-other']
dock_only = ['env.MADEIRA_DOCK_GAME_SCM = 1', 'env.MADEIRA_DOCK_KEEP_ALIVE = Launcher.exe;RDR2.exe']
assert all(line in rdr2 for line in dock_only), 'the Dock lines are the Steam copy\'s'
assert rdr2_other['tested'] == [line for line in rdr2 if line not in dock_only] + ['env.MADEIRA_EC_HOOK_TRACE = 0'], \
    rdr2_other['lines']
assert rdr2_other['version'] == 1 and rdr2_other['switches'] == presets['rdr2-steam']['switches'], rdr2_other
assert 'env.MADEIRA_EC_HOOK_TRACE = 0' in presets['gta5e-other']['lines']
# Every other game and the Desktop (owner's decisions, 2026-10-12): the ec-hook reporter off and,
# since version 3, nothing else (version 2 had the fork defaults); no switches.
standard = presets['standard']
assert standard['tested'] == ['env.MADEIRA_EC_HOOK_TRACE = 0'] and standard['switches'] == '' and standard['version'] == 3, standard
# Black Ops II (owner's test, 2026-10-27): the standard list it ran with, plus a 150 ms audio
# lead, which cleared Zombies' crackle. No switches.
bo2 = presets['black-ops-2']
assert bo2['tested'] == ['env.MADEIRA_AUDIO_LEAD_MS = 150', 'env.MADEIRA_EC_HOOK_TRACE = 0'] and bo2['switches'] == '' \
    and bo2['version'] == 1, bo2
assert not any(line.startswith('env.MADEIRA_AUDIO_LEAD_MS')
               for p in presets.values() if p is not bo2 for line in p['lines']), 'the 150 ms audio lead is Black Ops II\'s only'
assert 'if size != GameRecommendation.screen720 { entry.resolution = size }\n            else if let lines720 = ResolutionChoices.screen720Value { entry.resolution = lines720 }' in apply_src
gta = presets['gta5e-steam']
assert 'env.MADEIRA_CHILD_ARGS = PlayGTAV.exe -nobattleye' in gta['lines']
assert 'env.MADEIRA_DOCK_KEEP_ALIVE = Launcher.exe;GTA5_Enhanced.exe' in gta['lines']
# Version 10 (log 107): 30 FPS, the menus at 40 spent the power budget before iOS clamped the cores.
assert 'semaphoreFastPath: true, fpsMode: 3' in gta['switches'] and 'nvidia: true' in gta['switches']
# Outside Steam version 9 (an Epic copy): the Steam list's lines without its Dock lines, plus SteamDeck and the
# [ec-hook] reporter off, and its switches with the copy's 1280x720; no fastsync semaphore cells.
gta_other = presets['gta5e-other']
dock_lines = {'env.MADEIRA_DOCK_GAME_SCM = 1', 'env.MADEIRA_DOCK_KEEP_ALIVE = Launcher.exe;GTA5_Enhanced.exe'}
def settings(lines):
    return {l for l in lines if not l.startswith('#')}
assert settings(gta_other['lines']) == (settings(gta['lines']) - dock_lines) | {'env.SteamDeck = 1', 'env.MADEIRA_EC_HOOK_TRACE = 0'}, \
    sorted(settings(gta_other['lines']) ^ settings(gta['lines']))
assert 'env.MADEIRA_FASTSYNC_SEM = 1' not in gta_other['lines']
# Version 10 (ml2280): it starts in the Wine desktop, an aarch64 session, so the launcher installer's
# services.exe can run (in the game's own ARM64EC session that aarch64 program is refused).
assert gta_other['switches'] == gta['switches'].replace(
    'display: "fit"', 'resolution: "1280x720", display: "fit", launchMode: "desktop"'), gta_other['switches']
# Version 2 of both GTA lists (2026-10-12): the orphan-lock reaper's stamped mode, as RDR2 and
# Horizon Zero Dawn have. The default mode released a busy SocialClubHelper.exe lock at Story Mode.
for ident in ('gta5e-steam', 'gta5e-other', 'rdr2-steam', 'rdr2-other', 'horizon-zero-dawn'):
    assert 'env.MADEIRA_LOCK_ORPHAN = stamped' in presets[ident]['lines'], ident
# Version 3 of the Steam list (build 514): the VC++ setup's elevated engine is not started, as for RDR2.
# Version 4 / 3 (2026-10-26): new pipelines are built off the render thread (pso-async).
# Version 5 / 4: compiled pipelines kept in archives of our own (pso-archive).
# Version 6 / 5 (log 97, an 8 GB phone killed at its limit with Metal at 2.1 GB): shared argument-ring
# chunks, and under 12 GB of RAM the video budget's trim starts 3584 MB below the limit.
# Versions 9 / 8 (logs 103-106): the small-device memory guard; version 8 / 7's semaphore cells and lean
# diagnostics are gone again (the game's loading stalled with them).
assert presets['gta5e-steam']['version'] == 10 and presets['gta5e-other']['version'] == 10, \
    (presets['gta5e-steam']['version'], presets['gta5e-other']['version'])
for ident in ('gta5e-steam', 'gta5e-other'):
    assert 'pso-async = 1' in presets[ident]['lines'], ident
    assert 'pso-archive = 1' in presets[ident]['lines'], ident
    assert 'ring-share = 1' in presets[ident]['lines'], ident
    assert 'smallRAMConfig: gta5EnhancedSmallRAMLines' in presets[ident]['switches'], ident
    assert not any(l.startswith('vram-trim-mb') or l.startswith('donor-pool-guard')
                   for l in presets[ident]['lines']), ident   # small devices only
    assert 'env.MADEIRA_LEAN_DIAG = 1' not in presets[ident]['lines'], ident
assert 'env.MADEIRA_FASTSYNC_SEM = 1' not in gta['lines']
# Versions 7/6 (log 98): from 3584 the budget fell below the Metal usage the game could not shed and it
# stopped streaming; the trim starts 2560 MB below the limit.
# Versions 9/8 (log 103, the phone out of RAM): critical pressure sends the 64-bit title's new memory to
# the swap file, not more donated RAM.
assert 'static let gta5EnhancedSmallRAMLines = "vram-trim-mb = 2560\\ndonor-pool-guard = 1"' in lists_src
for ident in ('rdr2-steam', 'rdr2-other', 'gta5e-steam'):
    assert 'env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist' in presets[ident]['lines'], ident
assert 'resolution: "1280x720"' in presets['ghost-of-tsushima']['switches'] and 'avx: true' in presets['ghost-of-tsushima']['switches']
assert 'resolution: "1920x1080"' in presets['god-of-war']['switches']
# Horizon Zero Dawn, still being brought up: build 477's test list (register spaces other than 0,
# DXGI lists the virtual monitor's own modes so the game can pick this screen's resolution, its
# window is made foreground while none is, XInput pads reach Windows.Gaming.Input, and the
# shaders the converter refuses are retried with sized ranges, remembered and replaced by
# placeholder pipelines; pipelines are warmed in the background). Version 5 (build 480): the
# orphan-lock reaper releases only locks a live thread has stamped. Version 6 (build 481): shader
# libraries only for pipelines in use, rectangle clears, the game's memory in the swap file
# (broad, from 1 MB), and no pso-warm (its queue held 24,570 pipelines when iOS closed the game).
# Version 7 (build 483): the skin-check and view-census diagnostics for its compute-skinned
# characters (missing faces, missing hair, spikes every few frames on 481, gpu-sync or not).
# Version 8 (build 484): every candidate fix at once, one line each, to be halved if it helps:
# no wave operations, raw views readable as typed, ShaderAtomic on R32 typed UAVs, and FEX's
# x86 ordering for vector, memcpy and split-lock accesses and for images with volatile metadata.
# Version 9 (build 485): none of those helped (owner, 484 test), so they are gone again;
# typed buffer views start at Apple's 16-byte boundary, and skin-check traces whole frames and
# dumps the compute skinning's data, comparing what the GPU read with what the CPU wrote.
# Version 10 (build 486): the characters came out whole on 485; typed views start exactly at
# their first element where the probe allows (plants and lighting still flickered), and the
# skinning diagnostics are gone again (view-census stays, it counts views left with an offset).
# Version 11 (build 487): nothing changed on 486 (the GPU rounds a texture buffer's start down
# to 16 bytes; walls, trees and plants vanished for single frames); typed views of upload
# memory off a 16-byte boundary read an aligned copy, a queue's wait holds until the awaited
# work is committed, and vis-trace logs every frame's draws and the culling pyramid.
# Version 12 (build 489): desc-guard logs descriptors rewritten while a batch on the GPU uses them.
# Version 13 (build 490): the readback buffers (the culling pyramid) on Metal's own memory, not the swap tier.
# Version 14 (build 491): single constant buffers of descriptor tables read when the draw is recorded.
# Version 15 (build 492): the game rendered right on 491; the list without fence-strict, static-cbv,
# readback-swap and the trace diagnostics stayed clean, and without typed-view-shadow it broke again.
# Version 16 (build 494): + quiet-log and MADEIRA_SRV_FGETPATH, for frame rate (493, 2026-10-11).
hzd = presets['horizon-zero-dawn']
assert hzd['tested'] == ['dxbc-register-spaces = 1', 'msc-unbounded-retry = 1', 'msc-fail-memo = 1',
                            'pso-placeholder = 1', 'pso-lazy-libs = 1', 'clear-rects = 1',
                            'typed-view-align = 16', 'typed-view-shadow = 1', 'view-census = 1',
                            'quiet-log = 1',
                            'swap-mb = 6144', 'swap-mode = 2', 'swap-min-mb = 1',
                            'env.DXMT_WSI_MONITOR_IDENTITY = 1', 'env.DXMT_WSI_MODE_TABLE = 1',
                            'env.MADEIRA_INPUT_FOREGROUND = 1', 'env.MADEIRA_WGI_HOST_PADS = 1',
                            'env.MADEIRA_LOCK_ORPHAN = stamped', 'env.MADEIRA_SRV_FGETPATH = 1',
                            'env.WINEDEBUG = fixme-input'], hzd['lines']
hfw = presets['horizon-forbidden-west']
rca = presets['ratchet-clank-rift-apart']
assert not any(line.startswith('env.MADEIRA_SRV_FGETPATH')
               for p in presets.values() if p not in (hzd, hfw, rca) for line in p['lines']), \
    'the build 494 file-path switch is the two Horizon games\' and Rift Apart\'s only'
assert not any(line.startswith('quiet-log')
               for ident, p in presets.items() if p not in (hzd, hfw, rca) and ident not in MERGED for line in p['lines']), \
    'quiet-log is the two Horizon games\', Rift Apart\'s and some merged titles\' only'
assert hzd['version'] == 16 and hzd['switches'] == 'avx: false, nvidia: false, wineVCRT: false, fastSync: true, display: "fit"', hzd
assert not any(line.startswith(('d3d12-wave-ops', 'd3d12-raw-typed-views', 'typed-uav-atomic', 'ignore-volatile-metadata',
                                 'env.FEX_MEMCPYSETTSOENABLED', 'env.FEX_STRICTINPROCESSSPLITLOCKS'))
               for p in presets.values() for line in p['lines']), 'the build 484 experiment is in no list'
assert not any(line.startswith('clear-rects')
               for p in presets.values() if p is not hzd for line in p['lines']), 'clear-rects is Horizon Zero Dawn\'s only'
assert not any(line.startswith('pso-lazy-libs')
               for p in presets.values() if p not in (hzd, hfw, rca) for line in p['lines']), \
    'pso-lazy-libs is the two Horizon games\' and Rift Apart\'s only'
assert not any(line.startswith(('skin-check', 'skin-dump', 'fence-strict', 'vis-trace', 'readback-far', 'desc-guard', 'readback-swap',
                                 'static-cbv', 'env.FEX_VECTORTSOENABLED = 1'))
               for p in presets.values() for line in p['lines']), 'the build 482-491 experiments are in no list'
# Ghost of Tsushima, version 2 (build 492): Horizon Zero Dawn's proven typed-view fix, with the census.
# Version 3 (build 515, the owner's working list): the ec-hook reporter off, a 4 GB swap file, and
# thread stacks that may take the kernel's pick (a thread the game could not create froze it, 15:39).
got = presets['ghost-of-tsushima']
assert got['tested'] == ['dxil-tess = 0', 'sampler-reduction = 3', 'ind-count = 6000', 'typed-view-align = 16',
                            'typed-view-shadow = 1', 'view-census = 1', 'env.MADEIRA_PAD_MODE = hid', 'swap-mb = 4096',
                            'env.MADEIRA_EC_HOOK_TRACE = 0', 'env.MADEIRA_THREAD_STACK_SPILL = 1'], got['lines']
assert got['version'] == 3, got['version']
assert got['switches'] == ('avx: true, nvidia: true, wineVCRT: false, fastSync: true, semaphoreFastPath: false, '
                           'resolution: "1280x720", display: "fit"'), got['switches']
assert not any(line.startswith(('view-census', 'typed-view-align', 'typed-view-shadow'))
               for p in presets.values() if p not in (hzd, got, hfw) for line in p['lines']), \
    'the typed-view fix is HZD\'s, GoT\'s and HFW\'s only'
# Horizon Forbidden West, version 5 (community builds 517-534): AVX and NVIDIA on, frees released at once,
# programs from their own image, the swap file and a 3 GB budget with events, the typed-view fix with the
# large table, float3 copies (typed-view-rgb32) and MipLevels 0 as the full chain (mip0-full).
HFW_GENERAL = ['vram-mb = 3072', 'swap-mb = 8192', 'swap-mode = 2', 'swap-min-mb = 1', 'swap-images = 1']
HFW_ENV = ['env.MADEIRA_DXGI_BUDGET_EVENTS = 1', 'env.MADEIRA_SWAP_MIN_KB = 64',
           'env.MADEIRA_SWAP_RESERVE_MAX_MB = 9216', 'env.MADEIRA_INPUT_FOREGROUND = 1',
           'env.MADEIRA_WGI_HOST_PADS = 1', 'env.MADEIRA_LOCK_ORPHAN = stamped', 'env.MADEIRA_SRV_FGETPATH = 1',
           'env.MADEIRA_EC_HOOK_TRACE = 0', 'env.MADEIRA_FREE_DELAY_MS = 0', 'env.MADEIRA_X64_IMAGE_NOCOPY = 1',
           'env.MADEIRA_PAD_MODE = hid', 'env.MADEIRA_LEAN_DIAG = 1', 'env.WINEDEBUG = err+all,err-virtual,fixme-all']
assert hfw['tested'] == HFW_GENERAL + ['typed-view-align = 16', 'typed-view-shadow = 1', 'typed-view-rgb32 = 1',
                                       'mip0-full = 1', 'rp-carry = 1', 'quiet-log = 1', 'pso-lazy-libs = 1',
                                       'eco = 1'] + HFW_ENV, hfw['lines']
assert hfw['fork'] == ['env.MADEIRA_CTX_CPU_AREA = 2', 'env.MADEIRA_WAIT_CHILDREN = 1', 'env.MADEIRA_JIT_DUMP = 0'], hfw['fork']
assert hfw['version'] == 5 and hfw['switches'] == ('avx: true, nvidia: true, wineVCRT: false, fastSync: true, fpsMode: 3, '
                                                   'display: "fit"'), hfw
# Ratchet & Clank: Rift Apart, version 1: HFW's general lines without Decima's typed-view alignment and copies,
# rp-carry and eco. Version 2 (2026-10-26, a community last known working list, its version 6): a 2 GB budget and
# a 1 GB swap file, fence-early, the arena switches (jumbo-half, cage, alias release, VA pressure gap) and LC_ALL.
# rp-carry and eco; AVX and NVIDIA on. Seen up to its intro video on an 8 GB phone (community build 531).
RCA_ENV = HFW_ENV[:-1] + ['env.MADEIRA_JUMBO_HALF = 1', 'env.MADEIRA_CAGE_RELEASE = 1', 'env.MADEIRA_ALIAS_RELEASE = 1',
                         'env.LC_ALL = en_US.UTF-8', HFW_ENV[-1], 'env.MADEIRA_VA_PRESSURE_GAP_OK = 1']
assert rca['tested'] == ['vram-mb = 2048', 'swap-mb = 1024'] + HFW_GENERAL[2:] + [
    'typed-view-rgb32 = 1', 'mip0-full = 1', 'quiet-log = 1', 'pso-lazy-libs = 1', 'fence-early = 1'] + RCA_ENV, rca['lines']
assert rca['fork'] == hfw['fork'] and rca['version'] == 2 and rca['switches'] == hfw['switches'], rca
assert not any(line.startswith('typed-view-rgb32') for p in presets.values() if p not in (hfw, rca)
               for line in p['lines']), 'typed-view-rgb32 is HFW\'s and Rift Apart\'s only'
assert not any(line.startswith('mip0-full') for ident, p in presets.items() if p not in (hfw, rca) and ident not in MERGED
               for line in p['lines']), 'mip0-full is HFW\'s, Rift Apart\'s and some merged titles\' only'
# GTA IV, version 3: AVX pinned off (a community list for the same launcher chain).
assert presets['gta4-steam']['version'] == 3 and presets['gta4-steam']['switches'] == \
    'avx: false, fastSync: true, semaphoreFastPath: true, display: "fit"', presets['gta4-steam']
# The merged lists: version 1, none of the community variant or app-side switches, and no MADEIRA_SPAWN_SWAP
# (its engine code is not in this tree).
for ident in MERGED:
    p = presets[ident]
    assert p['version'] == 1, ident
    assert not any(line.startswith(('env.MADEIRA_WINTYPES', 'env.MADEIRA_OPTIN_DLLS', 'env.MADEIRA_D3D8 ',
                                    'env.MADEIRA_STEAM_IDENTITY', 'env.MADEIRA_MFC_DOCK', 'pool-split-retry'))
                   for line in p['lines']), (ident, p['lines'])
assert [ident for ident, p in presets.items() if any(line.startswith('env.MADEIRA_SPAWN_SWAP') for line in p['lines'])] == []
print('PASS: RDR2 (Steam) is the owner\'s 463 list plus the 466, 467, 470, 472, 475, 476, 480 and 514 test lines (v10), line for line with its switches (720 lines of this screen), and outside Steam the same without the Dock lines, with the ec-hook reporter off (v1); GTA V Enhanced keeps its tested lines plus the stamped orphan-lock mode (v2) and, from Steam, the VC++ engine block (v3), GoW its tested lines; Horizon Zero Dawn has build 491\'s proven list plus build 494\'s frame-rate switches (v16), GoT the owner\'s build 515 list (v3); every other game and the Desktop the standard list (v3)')

# Crysis Remastered, version 1 (community build 528, 2026-10-13 22:08, it ran perfectly): the
# standard list's line and the fork defaults it ran with, every switch off, at Fit.
crysis = presets['crysis-remastered']
assert crysis['tested'] == ['env.MADEIRA_EC_HOOK_TRACE = 0'], crysis['lines']
assert crysis['version'] == 1 and crysis['switches'] == 'avx: false, nvidia: false, wineVCRT: false, display: "fit"', crysis
# Crysis 2 and 3 Remastered, version 1 (not yet run with them): community build 540's tries stopped with AVX off
# (Crysis 2) and in Microsoft's msvcp140 (Crysis 3), so AVX on, and Wine's C++ runtime for Crysis 3.
c = presets['crysis-2-remastered']
assert c['tested'] == ['env.MADEIRA_EC_HOOK_TRACE = 0'], c['lines']
assert c['version'] == 1 and c['switches'] == 'avx: true, nvidia: false, wineVCRT: false, display: "fit"', c
# Crysis 3 Remastered, version 2 (community builds 547/549): the game's own x64 vcruntime140.dll next to Wine's ARM64EC
# msvcp140 stopped it; env.MADEIRA_APP_DLL_SHADOW refuses that copy, and Wine's C++ runtime switch is off again.
c = presets['crysis-3-remastered']
assert c['tested'] == ['env.MADEIRA_EC_HOOK_TRACE = 0', 'env.MADEIRA_APP_DLL_SHADOW = vcruntime140.dll'], c['lines']
assert c['version'] == 2 and c['switches'] == 'avx: true, nvidia: false, wineVCRT: false, display: "fit"', c
assert not any(line.startswith('env.MADEIRA_APP_DLL_SHADOW') for p in presets.values() if p is not c for line in p['lines']), \
    'the app-local DLL shadow is Crysis 3 Remastered\'s only'
print('PASS: Crysis Remastered is the standard line with the fork defaults and every switch off (v1); Crysis 2 '
      'Remastered the same with AVX on (v1); Crysis 3 Remastered with AVX on and its own vcruntime140.dll refused (v2)')

# Recognition: Steam by App ID or steamapps\common folder; everything else by the program's name.
match = block(lists_src, 'static func match(', '\n    }\n')
assert ('rdr2AppID = 1174180, gta5EnhancedAppID = 3240220, ghostAppID = 2215430, godOfWarAppID = 1593500,\n'
        '               horizonZeroDawnAppID = 1151640, darkSoulsRemasteredAppID = 570940, darkSoulsIIIAppID = 374320,\n'
        '               crysisRemasteredAppID = 1715130, crysis2RemasteredAppID = 2096600,\n'
        '               crysis3RemasteredAppID = 2096610, horizonForbiddenWestAppID = 2420110, ratchetClankRiftApartAppID = 1895880') in lists_src
assert ('if steamAppID == horizonForbiddenWestAppID || installFolder == "horizon forbidden west complete edition" {\n'
        '                return horizonForbiddenWest\n            }') in match
assert 'case "horizonforbiddenwest.exe":\n            return horizonForbiddenWest' in match
assert ('if steamAppID == ratchetClankRiftApartAppID || installFolder == "ratchet & clank - rift apart" {\n'
        '                return ratchetClankRiftApart\n            }') in match
assert 'case "riftapart.exe":\n            return ratchetClankRiftApart' in match
assert 'if steamAppID == crysisRemasteredAppID || installFolder == "crysis remastered" { return crysisRemastered }' in match
assert 'case "crysisremastered.exe":\n            return crysisRemastered' in match
assert 'if steamAppID == crysis2RemasteredAppID || installFolder == "crysis 2 remastered" { return crysis2Remastered }' in match
assert 'if steamAppID == crysis3RemasteredAppID || installFolder == "crysis 3 remastered" { return crysis3Remastered }' in match
assert 'case "crysis2remastered.exe":\n            return crysis2Remastered' in match
assert 'case "crysis3remastered.exe":\n            return crysis3Remastered' in match
assert 'let installFolder = last == steamFolder ? steamFolder : nil' in match
assert 'installFolder == "red dead redemption 2"' in match and 'installFolder == "grand theft auto v enhanced"' in match
assert 'case "ghostoftsushima.exe":' in match and 'case "gow.exe":' in match and 'case "rdr2.exe", "playrdr2.exe":' in match
assert 'case "horizonzerodawn.exe":\n            return horizonZeroDawn' in match
assert 'if steamAppID == horizonZeroDawnAppID || installFolder == "horizon zero dawn" { return horizonZeroDawn }' in match
assert 'static let falloutNewVegasAppID = 22380, fallout3AppIDs: Set<Int> = [22300, 22370]' in lists_src
assert 'case "falloutnv.exe":\n            return falloutNewVegas' in match and 'case "fallout3.exe":\n            return fallout3' in match
# Black Ops II: campaign, Zombies and multiplayer share one folder and list.
assert 'static let blackOps2AppIDs: Set<Int> = [202970, 212910, 202990]' in lists_src
assert 'if blackOps2AppIDs.contains(steamAppID ?? 0) || installFolder == "call of duty black ops ii" { return blackOps2 }' in match
assert 'case "t6sp.exe", "t6zm.exe", "t6mp.exe":\n            return blackOps2' in match
# GoT, GoW and Horizon Zero Dawn from Steam: their App IDs, and their folders as for RDR2 and GTA V Enhanced.
assert 'installFolder == "ghost of tsushima director\'s cut"' in match and 'installFolder == "godofwar"' in match
assert 'case "playgtav.exe", "gta5_enhanced.exe":' in match and 'return inSteam ? gta5EnhancedSteam : gta5EnhancedOther' in match
assert 'return inSteam ? rdr2Steam : rdr2Other' in match
assert 'guard fileExists(folder + "\\\\GTA5_Enhanced.exe") else {' in match
# GTA V Legacy: Steam only; Enhanced (GTA5_Enhanced.exe beside the program) is checked first.
assert 'static let gta5LegacyAppID = 271590' in lists_src
assert 'if steamAppID == gta5LegacyAppID || installFolder == "grand theft auto v" { return gta5LegacySteam }' in match
assert 'guard last == "playgtav.exe" && fileExists(folder + "\\\\GTA5.exe") else { return nil }\n' \
       '                return inSteam ? gta5LegacySteam : gta5LegacyOther' in match
assert 'case "gta5.exe":\n            // GTA V Legacy\'s game program, inside or outside a Steam library.\n' \
       '            return inSteam ? gta5LegacySteam : gta5LegacyOther' in match
# The merged Steam titles: by App ID or folder after the lists above, by program in the switch's default.
assert 'return steamTitles.first { title in\n' in match
assert 'default:\n            return steamTitles.first { $0.programs.contains(last) || (inSteam && $0.steamPrograms.contains(last)) }?.list' in match
# GTA V Legacy (Steam) v1 (community build 547): DirectX 11, so no D3D12 lines and no DualSense mode; no vram-mb or
# swap-mb in the list; a device under 12 GB of RAM gets the 3 GB RAM swap after it.
legacy = presets['gta5l-steam']
assert legacy['version'] == 1 and legacy['title'] == 'GTA V Legacy (Steam)', legacy
assert 'env.MADEIRA_DOCK_KEEP_ALIVE = Launcher.exe;GTA5.exe' in legacy['tested']
assert 'env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist' in legacy['tested']
assert not any(line.startswith(('d3d12-', 'pso-warm', 'vram-mb', 'swap-mb', 'env.MADEIRA_PAD_MODE')) for line in legacy['lines']), legacy['lines']
assert legacy['switches'] == ('avx: false, nvidia: true, wineVCRT: false, fastSync: true, semaphoreFastPath: true, fpsMode: 4, '
                              'display: "fit", smallRAMConfig: smallRAMSwapLines'), legacy['switches']
assert 'static let smallRAMSwapLines = "swap-mb = 3072"' in lists_src
assert 'static var smallRAMDevice: Bool { deviceRAMBytes < 10 << 30 }' in lists_src
assert lists_src.count('smallRAMConfig: smallRAMSwapLines') == 2   # GTA V Legacy inside and outside Steam
other_legacy = presets['gta5l-other']
assert other_legacy['tested'] == [line for line in legacy['tested'] if not line.startswith('env.MADEIRA_DOCK_')], other_legacy
assert other_legacy['switches'] == legacy['switches'] and other_legacy['version'] == 1, other_legacy

# Where the app applies them.
save = block(library, '    func save(_ entry: LibraryEntry, metadata: Bool = false) {', '\n    }\n')
assert save.index('let isNew = !next.contains { $0.id == entry.id || (entry.steamAppID != nil && $0.steamAppID == entry.steamAppID) }') \
    < save.index('GameRecommendations.prepare(&entry, new: isNew)') < save.index('persist(next, metadata:')
init = block(library, '    private init() {\n        refreshFlag()', '\n    }\n')
assert init.index('resetPhoneResolution()') < init.index('applyRecommendations()')
apply_all = block(library, '    private func applyRecommendations() {', '\n    }\n')
# The new grid writes Steam metadata results itself (applySteamMetadata); it asks for the same recommendations.
steam_apply = block(library, '    private func applySteamMetadata() {', '\n    }\n')
assert 'GameRecommendations.prepare(&fresh, new: true)' in steam_apply and 'GameRecommendations.prepare(&next[i])' in steam_apply
assert 'guard !readOnly' in apply_all and 'GameRecommendations.prepare(&next[i])' in apply_all and 'persist(next)' in apply_all
detail = block(library, 'struct LibraryDetail: View {', '\n/// madeira-bcd: a game\'s own options as the fork stores them')
assert '.onAppear {\n                migrateEntryOptions()\n                prepareRecommendation()\n                reloadBCD()\n            }' in detail
assert 'let isNew = !model.entries.contains { $0.id == entry.id }' in detail
assert 'if GameRecommendations.prepare(&entry, new: isNew) { model.save(entry) }' in detail
# Adding a game by hand opens its page with the entry the library stored.
assert 'model.save(entry); browser = false; selected = model.entries.first { $0.id == entry.id } ?? entry' in library
assert 'recommended = GameRecommendations.reset(&entry)' in detail
reset_section = detail[detail.index('Button("Reset to Recommended", systemImage: "arrow.counterclockwise")'):]
assert reset_section.index('Button("Reset", role: .destructive) { resetToRecommended() }') \
    < reset_section.index('Text(GameRecommendations.note(recommended, desktop: entry.desktop == true))')
assert 'GameRecommendations.question(recommended, desktop: entry.desktop == true)' in reset_section
# For every entry, the Desktop too: the section is not gated off.
assert ('// madeira-bcd: always last, for every entry, the Desktop too (GameRecommendationsApply.swift).\n'
        '                Section {\n') in detail
assert detail.index('// madeira-bcd: always last,') < detail.index('Button("Reset to Recommended"')
# Last in the form, after the Executable section and Remove from library (the error line is
# shown with the page's other sections since the Game details pages).
assert detail.index('Button("Remove from library"') < detail.index('Button("Reset to Recommended"')
assert 'if let error { Section' in detail
assert '!remove, !confirmReset else { return }' in detail
launch = block(content, '    private func launchLibraryEntry(_ entry: LibraryEntry) {', '\n    }\n')
assert launch.index('if GameRecommendations.prepare(&entry, new: isNew) { library.save(entry) }') < launch.index('BCDLaunch.applyLibrary(entry)')
for name in ('GameRecommendations.swift', 'GameRecommendationsApply.swift'):
    assert project.count(f'/* {name} in Sources */') == 2, name   # PBXBuildFile and the Sources phase
    assert project.count(f'/* {name} */') == 3, name              # fileRef, PBXFileReference and the group
# The rules: first sight only for a game with nothing of its own; switches only on first sight or a reset.
due = block(apply_src, '    private static func due(', '\n    }\n')
assert due.index('guard mark != "", let rec = found else { return nil }') < due.index('let text = GameProfile(windowsPath: windowsPath).text')
assert 'guard mark != stamp(rec), mark.hasSuffix("#" + fileHash(text)) else { return nil }' in due
assert '!(text + (ownLines ?? "")).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty' in due and 'setMark("", windowsPath)' in due
# The standard list for every other game and the Desktop, and later a game's own list over it as on first sight.
fallback = block(apply_src, '    static func recommendation(windowsPath: String, steamAppID: Int?) -> GameRecommendation? {', '\n    }\n')
assert 'if let rec = match(windowsPath: windowsPath, steamAppID: steamAppID, fileExists: driveFileExists) { return rec }' in fallback
assert 'return parts.count > 1 ? standard : nil' in fallback
assert 'let fromStandard = mark.hasPrefix(standard.id + "#") && rec.id != standard.id' in due
assert 'entry.desktop == true ? standard : recommendation(windowsPath: entry.windowsPath, steamAppID: entry.steamAppID)' in apply_src
assert 'if let found = due(entry.windowsPath, recommendation(for: entry), ownLines: entry.config, title: entry.title),' in apply_src
assert 'guard entry.desktop != true' not in apply_src, 'prepare takes the Desktop too'
put = block(apply_src, '    private static func put(', '\n    }\n')
assert 'guard file.text == rec.fileText' in put and 'if kind != .updated && switches {' in put
assert ('if let on = rec.avx { LibraryPrefs.setAVX(on, for: windowsPath) }' in put
        and 'if let on = rec.nvidia { LibraryPrefs.setNvidia(on, for: windowsPath) }' in put
        and 'if let on = rec.olderNvidia { LibraryPrefs.setOlderNvidia(on, for: windowsPath) }' in put
        and 'if let on = rec.wineVCRT { LibraryPrefs.setWineVCRT(on, for: windowsPath) }' in put)
print('PASS: first sight in the library (start-up, save, Game details, start); Reset to Recommended last in Game details')

# The Swift fixture: the real files with small stand-ins for the app types they use.
stable_hash = block(prefs, '    static func stableHash(_ s: String) -> UInt64 {', '\n    }\n')
profile_text = block(profiles, '    var text: String {', '\n    }\n')
profile_parse = block(profiles, '    static func parse(_ text: String) -> [String: String] {', '\n    }\n')
stubs = r'''import Foundation

enum DisplayMode: String { case fit, fill, stretch, aspect }

enum ResolutionChoices { static var screen720Value: String? { "1568x720" } }   // a 19.5:9 iPhone

final class LibraryModel {
    static let shared = LibraryModel()
    var entries: [LibraryEntry] = []
    func save(_ entry: LibraryEntry) {
        if let i = entries.firstIndex(where: { $0.windowsPath == entry.windowsPath }) { entries[i] = entry } else { entries.append(entry) }
    }
    static var drive: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["MADEIRA_TEST_DRIVE"]!, isDirectory: true) }
}

final class LogStore {
    static let shared = LogStore()
    enum Level { case info, error }
    var lines: [String] = []
    func log(_ message: String, level: Level = .info) { lines.append(message) }
}

struct LibraryEntry {
    var title: String
    var windowsPath: String
    var steamAppID: Int? = nil
    var desktop: Bool? = nil
    var config: String? = nil
    var resolution = "1408x648"
    var display: String? = nil
    var fpsMode = 1
    var fastSync: Bool? = nil
    var semaphoreFastPath: Bool? = nil
    var launchMode: String? = nil
    var startServices: Bool? = nil
}

final class PrefStore {
    static let shared = PrefStore()
    var flags: [String: Bool] = [:]
}

enum LibraryPrefs {
''' + stable_hash + r'''
    static func avx(_ path: String) -> Bool { PrefStore.shared.flags["avx|" + path] ?? false }
    static func setAVX(_ on: Bool, for path: String) { PrefStore.shared.flags["avx|" + path] = on ? true : nil }
    static func nvidia(_ path: String) -> Bool { PrefStore.shared.flags["nvidia|" + path] ?? false }
    static func setNvidia(_ on: Bool, for path: String) { PrefStore.shared.flags["nvidia|" + path] = on ? true : nil }
    static func olderNvidia(_ path: String) -> Bool { PrefStore.shared.flags["older|" + path] ?? false }
    static func setOlderNvidia(_ on: Bool, for path: String) { PrefStore.shared.flags["older|" + path] = on ? true : nil }
    static func wineVCRT(_ path: String) -> Bool { PrefStore.shared.flags["vcrt|" + path] ?? false }
    static func setWineVCRT(_ on: Bool, for path: String) { PrefStore.shared.flags["vcrt|" + path] = on ? true : nil }
}

struct GameProfile {
    let windowsPath: String
    var url: URL? {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MADEIRA_TEST_CONFIGS"]!, isDirectory: true)
            .appendingPathComponent(String(format: "%016llx.cfg", LibraryPrefs.stableHash(windowsPath.lowercased())))
    }
''' + profile_text + profile_parse + '}\n'

main = r'''import Foundation

func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { print("FAILED (main.swift line \(line)): \(what)"); exit(1) }
}

let R = GameRecommendations.self
let steam = #"C:\Program Files (x86)\Steam\steamapps\common"#

func id(_ path: String, _ app: Int? = nil, files: [String] = []) -> String {
    let have = Set(files.map { $0.lowercased() })
    return R.match(windowsPath: path, steamAppID: app, fileExists: { have.contains($0.lowercased()) })?.id ?? "none"
}

// How a game is recognised.
let rdr2 = steam + #"\Red Dead Redemption 2"#
check(id(#"C:\Program Files\Rockstar Games\Launcher\Launcher.exe"#) == "rockstar-launcher", "the publisher launcher in its folder")
check(id(#"C:\Games\Some Game\Launcher.exe"#) == "none", "another program called Launcher.exe")
check(id(#"C:\users\a\Downloads\Rockstar-Games-Launcher.exe"#) == "rockstar-launcher-setup", "the launcher's installer")
check(id(rdr2, 1174180) == "rdr2-steam", "RDR2 by its App ID")
check(id(rdr2) == "rdr2-steam", "RDR2 by its Steam folder")
check(id("D:\\SteamLibrary\\steamapps\\common\\Red Dead Redemption 2\\") == "rdr2-steam", "another Steam library, trailing backslash")
check(id(#"C:\Games\Red Dead Redemption 2\RDR2.exe"#) == "rdr2-other" && id(#"C:\Games\Red Dead Redemption 2\PlayRDR2.exe"#) == "rdr2-other",
      "RDR2 outside Steam: its own list")
check(id(rdr2 + #"\RDR2.exe"#) == "rdr2-steam" && id(rdr2 + #"\PlayRDR2.exe"#) == "rdr2-steam", "RDR2's programs inside Steam")
check(id(rdr2 + #"\Redistributables\vc_redist.x64.exe"#) == "none", "a redistributable in a game's Steam folder")
check(id(rdr2 + #"\start.bat"#) == "none" && id(steam + #"\Grand Theft Auto V Enhanced\launch.cmd"#) == "none",
      "a batch file inside a Steam game's folder")
let gta = steam + #"\Grand Theft Auto V Enhanced"#
check(id(gta, 3240220) == "gta5e-steam", "GTA V Enhanced by its App ID")
check(id(gta) == "gta5e-steam", "GTA V Enhanced by its Steam folder")
check(id(gta + #"\PlayGTAV.exe"#, files: [gta + #"\GTA5_Enhanced.exe"#]) == "gta5e-steam", "PlayGTAV.exe inside Steam is the Steam copy")
let renamed = steam + #"\GTAV Enhanced Copy"#
check(id(renamed + #"\PlayGTAV.exe"#, files: [renamed + #"\GTA5_Enhanced.exe"#]) == "gta5e-steam", "in any Steam library folder")
check(id(gta + #"\_CommonRedist\vc_redist.x64.exe"#, files: [gta + #"\GTA5_Enhanced.exe"#]) == "none", "not its redistributables")
let other = #"C:\Games\GTA V Enhanced"#
check(id(other + #"\PlayGTAV.exe"#, files: [other + #"\GTA5_Enhanced.exe"#]) == "gta5e-other", "PlayGTAV.exe elsewhere")
check(id(other + #"\GTA5_Enhanced.exe"#, files: [other + #"\GTA5_Enhanced.exe"#]) == "gta5e-other", "GTA5_Enhanced.exe elsewhere")
check(id(#"C:\GAMES\gta v enhanced\PLAYGTAV.EXE"#, files: [other + #"\gta5_enhanced.exe"#]) == "gta5e-other", "names in any case")
check(id("C:/Games/GTA V Enhanced/PlayGTAV.exe", files: [other + #"\GTA5_Enhanced.exe"#]) == "gta5e-other", "forward slashes")
check(id(#"C:\Games\GTA V\PlayGTAV.exe"#, files: [#"C:\Games\GTA V\GTA5.exe"#]) == "gta5l-other", "the legacy edition outside Steam")
check(id(#"C:\Games\GTA V\GTA5.exe"#) == "gta5l-other", "GTA5.exe outside Steam")
check(id(#"C:\Games\GTA V\PlayGTAV.exe"#) == "none", "PlayGTAV.exe outside Steam with neither game program beside it")
let legacy = steam + #"\Grand Theft Auto V"#
check(id(legacy, 271590) == "gta5l-steam", "GTA V Legacy by its App ID")
check(id(legacy) == "gta5l-steam", "GTA V Legacy by its Steam folder")
check(id(legacy + #"\PlayGTAV.exe"#, files: [legacy + #"\GTA5.exe"#]) == "gta5l-steam", "Legacy's PlayGTAV.exe inside Steam")
check(id(legacy + #"\GTA5.exe"#) == "gta5l-steam", "Legacy's GTA5.exe inside Steam")
check(id(legacy + #"\PlayGTAV.exe"#) == "none", "PlayGTAV.exe inside Steam with neither game program beside it")
check(id(gta + #"\PlayGTAV.exe"#, files: [gta + #"\GTA5_Enhanced.exe"#, gta + #"\GTA5.exe"#]) == "gta5e-steam",
      "GTA5_Enhanced.exe beside PlayGTAV.exe stays Enhanced, even with a GTA5.exe there")
check(id(legacy + #"\_CommonRedist\vc_redist.x64.exe"#, 271590) == "none", "not Legacy's redistributables")
let gta4 = steam + #"\Grand Theft Auto IV"#
check(id(gta4, 12210) == "gta4-steam", "GTA IV by its App ID")
check(id(gta4) == "gta4-steam", "GTA IV by its Steam folder")
check(id(gta4 + #"\GTAIV\PlayGTAIV.exe"#) == "gta4-steam" && id(gta4 + #"\GTAIV\GTAIV.exe"#) == "gta4-steam", "GTA IV's programs inside Steam")
check(id(#"C:\Games\GTA IV\GTAIV.exe"#) == "none", "GTA IV outside Steam has no list")
// The device's RAM: GTA V Legacy's 3 GB RAM swap only under 12 GB; every other list the same everywhere.
R.deviceRAMBytes = 11_695 << 20
let onTwelve = R.all.map { $0.fileText }
check(!R.gta5LegacySteam.fileText.contains("swap-mb") && !R.gta5LegacySteam.fileText.contains("vram-mb"),
      "a 12 GB phone: no RAM swap in GTA V Legacy's list")
R.deviceRAMBytes = 16 << 30
check(R.all.map { $0.fileText } == onTwelve, "a 16 GB iPad: the same lists as a 12 GB phone")
R.deviceRAMBytes = 7_500 << 20
check(R.gta5LegacySteam.fileText.hasSuffix("env.MADEIRA_JIT_DUMP = 0\nswap-mb = 3072\n"),
      "an 8 GB phone: the 3 GB RAM swap after GTA V Legacy's list")
check(R.gta5LegacyOther.fileText.hasSuffix("env.MADEIRA_JIT_DUMP = 0\nswap-mb = 3072\n"),
      "an 8 GB phone: the 3 GB RAM swap after GTA V Legacy's list outside Steam too")
check(zip(R.all, onTwelve).allSatisfy { $0.0.smallRAMConfig != nil || $0.0.fileText == $0.1 },
      "every list without small-device lines is the same on an 8 GB phone")
R.deviceRAMBytes = 11_695 << 20
check(id(other + #"\PlayGTAV.exe"#) == "none", "PlayGTAV.exe without GTA5_Enhanced.exe beside it")
check(id(#"C:\GhostOfTsushima\GhostOfTsushima.exe"#) == "ghost-of-tsushima", "GoT by its program")
check(id(#"E:\Some Other Folder\ghostoftsushima.EXE"#) == "ghost-of-tsushima", "GoT anywhere, in any case")
check(id(steam + #"\Ghost of Tsushima DIRECTOR'S CUT"#, 2215430) == "ghost-of-tsushima", "GoT from Steam")
check(id(steam + #"\Ghost of Tsushima DIRECTOR'S CUT"#) == "ghost-of-tsushima", "GoT by its Steam folder")
check(id(steam + #"\GodOfWar"#) == "god-of-war" && id("D:\\SteamLibrary\\steamapps\\common\\God of War") == "god-of-war",
      "GoW by its Steam folder")
check(id(steam + #"\Horizon Zero Dawn"#) == "horizon-zero-dawn", "Horizon Zero Dawn by its Steam folder")
check(id(steam + #"\Horizon Zero Dawn Remastered"#) == "none", "the remaster's Steam folder is another game")
check(id(steam + #"\Ghost"#, 1, files: [steam + #"\Ghost\GhostOfTsushima.exe"#]) == "none", "a library Steam game is its App ID or folder name")
check(id(#"C:\God of War\GoW.exe"#) == "god-of-war", "GoW by its program")
check(id(steam + #"\God of War"#, 1593500) == "god-of-war", "GoW from Steam")
check(id(#"C:\Games\God of War Ragnarok\GoWR.exe"#) == "none", "Ragnarok is another game")
check(id(#"C:\Horizon - Zero Down CE\HorizonZeroDawn.exe"#) == "horizon-zero-dawn", "Horizon Zero Dawn by its program (GOG)")
check(id(steam + #"\Horizon Zero Dawn\HorizonZeroDawn.exe"#) == "horizon-zero-dawn", "its program inside Steam")
check(id(steam + #"\Horizon Zero Dawn"#, 1151640) == "horizon-zero-dawn", "Horizon Zero Dawn from Steam")
check(id(#"C:\Games\Horizon Zero Dawn Remastered\HorizonZeroDawnRemastered.exe"#) == "none", "the remaster is another game")
let crysis = steam + #"\Crysis Remastered"#
check(id(crysis, 1715130) == "crysis-remastered", "Crysis Remastered by its App ID")
check(id(crysis) == "crysis-remastered", "Crysis Remastered by its Steam folder")
check(id(crysis + #"\Bin64\CrysisRemastered.exe"#) == "crysis-remastered", "its program inside Steam")
check(id(#"C:\Games\Crysis\Bin64\Crysis.exe"#) == "none", "the original Crysis is another game")
let hfw = steam + #"\Horizon Forbidden West Complete Edition"#
check(id(hfw, 2420110) == "horizon-forbidden-west", "Horizon Forbidden West by its App ID")
check(id(hfw) == "horizon-forbidden-west", "Horizon Forbidden West by its Steam folder")
check(id(hfw + #"\HorizonForbiddenWest.exe"#) == "horizon-forbidden-west", "its program inside Steam")
check(id(#"D:\Games\HFW\horizonforbiddenwest.EXE"#) == "horizon-forbidden-west", "its program anywhere, in any case")
check(id(hfw + #"\crs-handler.exe"#) == "none", "not its crash reporter")
let rca = steam + #"\Ratchet & Clank - Rift Apart"#
check(id(rca, 1895880) == "ratchet-clank-rift-apart", "Rift Apart by its App ID")
check(id(rca) == "ratchet-clank-rift-apart", "Rift Apart by its Steam folder")
check(id(rca + #"\RiftApart.exe"#) == "ratchet-clank-rift-apart", "its program inside Steam")
check(id(#"D:\Games\RC\RIFTAPART.exe"#) == "ratchet-clank-rift-apart", "its program anywhere, in any case")
let crysis2 = steam + #"\Crysis 2 Remastered"#, crysis3 = steam + #"\Crysis 3 Remastered"#
check(id(crysis2, 2096600) == "crysis-2-remastered" && id(crysis3, 2096610) == "crysis-3-remastered", "Crysis 2 and 3 Remastered by their App IDs")
check(id(crysis2) == "crysis-2-remastered" && id(crysis3) == "crysis-3-remastered", "by their Steam folders")
check(id(crysis2 + #"\Bin64\Crysis2Remastered.exe"#) == "crysis-2-remastered"
      && id(crysis3 + #"\Bin64\Crysis3Remastered.exe"#) == "crysis-3-remastered", "their programs inside Steam")
check(id(#"C:\Games\Crysis 2\Bin32\Crysis2.exe"#) == "none", "the original Crysis 2 is another game")
// The merged Steam titles: App ID, folder, a program anywhere, a Steam-only program only inside a library.
check(id(steam + #"\MSFS2024"#, 2537590) == "msfs-2024" && id(steam + #"\MSFS2024"#) == "msfs-2024", "a merged title by App ID and folder")
check(id(#"D:\Games\FS\FlightSimulator2024.exe"#) == "msfs-2024", "a merged title's program anywhere")
check(id(steam + #"\GTA San Andreas - The Definitive Edition\Gameface\Binaries\Win64\PlayGTASanAndreas.exe"#) == "gtasa-de-steam",
      "a Steam-only program inside Steam")
check(id(#"C:\Games\GTASA\PlayGTASanAndreas.exe"#) == "none", "a Steam-only program outside Steam")
check(id(steam + #"\Dead as Disco"#, 3404260) == "dead-as-disco" && id(steam + #"\TUNG"#) == "tung", "App ID only, folder only")
check(id(steam + #"\Red Dead Redemption"#) == "rdr1-steam" && id(steam + #"\Red Dead Redemption 2"#) == "rdr2-steam",
      "folders match whole names")
check(R.steamTitles.count == 49 && R.all.count == 73, "49 merged titles, 73 lists")
check(id(#"C:\Games\Foo\foo.exe"#) == "none" && id(steam + #"\Portal 2"#, 620) == "none", "other games")
check(id("") == "none" && id("C:\\") == "none", "no path")
print("PASS: Steam games by App ID or steamapps\\common folder, GTA V Enhanced and RDR2 inside and outside Steam, GoT, GoW, the Horizon games, Rift Apart and the three Crysis Remastered games by their programs, GTA V Legacy outside Steam, the 49 merged Steam titles, others none")

// The lists themselves.
check(Set(R.all.map(\.id)).count == R.all.count, "ids are unique")
for rec in R.all {
    check(rec.fileText.hasSuffix("\n") && !rec.fileText.hasSuffix("\n\n"), "\(rec.id): one trailing newline")
    let settingLines = rec.config.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    check(GameProfile.parse(rec.config).count == settingLines.count, "\(rec.id): every line but the comments parses")
}
check(R.gta5EnhancedSteam.switchSummary == "AVX off, NVIDIA on, Wine's C++ runtime off, fast semaphore waits on, FPS limit 40",
      R.gta5EnhancedSteam.switchSummary)
check(R.note(R.ghostOfTsushima).contains("1280x720") && R.note(R.ghostOfTsushima).contains("fast semaphore waits off"),
      R.note(R.ghostOfTsushima))
check(R.note(R.rdr2Steam).contains("@RDR2_CONFIG_LINES@ config lines") && R.note(R.rdr2Steam).contains("this screen's shape at 720 lines") && R.note(nil).contains("no recommended settings"), R.note(R.rdr2Steam))
check(id(steam + #"\Dark Souls Remastered"#, 570940) == "dark-souls-remastered", "Dark Souls Remastered by App ID")
check(id(steam + #"\DARK SOULS III"#) == "dark-souls-iii", "Dark Souls III by folder")
check(id(#"C:\Games\DarkSoulsRemastered.exe"#) == "dark-souls-remastered", "Dark Souls Remastered by executable")
check(id(#"C:\Games\DarkSoulsIII.exe"#) == "dark-souls-iii", "Dark Souls III by executable")
// Every other game: the standard list; a path that names nothing: none.
check(R.recommendation(windowsPath: #"C:\Games\Foo\foo.exe"#, steamAppID: nil)?.id == "standard"
      && R.recommendation(windowsPath: steam + #"\Portal 2"#, steamAppID: 620)?.id == "standard", "every other game: the standard list")
check(R.recommendation(windowsPath: "", steamAppID: nil) == nil && R.recommendation(windowsPath: "C:\\", steamAppID: nil) == nil,
      "a path that names nothing has none")
let standardLines = GameProfile.parse(R.standard.config).count
check(standardLines == 1 && R.note(R.standard).contains("standard settings: 1 config line (")
      && R.question(R.standard).contains("standard settings"), R.note(R.standard))
check(R.note(R.standard, desktop: true).hasPrefix("Madeira recommends its standard settings for the Desktop: 1 config line (")
      && R.question(R.standard, desktop: true).contains("the Desktop's config"), R.note(R.standard, desktop: true))

// First sight, the player's changes, newer lists and Reset to Recommended.
let key = "madeira.recommended.applied"
UserDefaults.standard.removeObject(forKey: key)
func mark(_ path: String) -> String? { (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[path.lowercased()] }
func file(_ path: String) -> String { GameProfile(windowsPath: path).text }

var red = LibraryEntry(title: "Red Dead Redemption 2", windowsPath: rdr2, steamAppID: 1174180)
red.display = "fill"
red.fpsMode = 2
LibraryPrefs.setNvidia(true, for: rdr2)
// A game already in the library: the config file only; its fields and switches are the player's.
check(!R.prepare(&red), "first sight of a library entry changes none of its fields")
check(file(rdr2) == R.rdr2Steam.fileText, "first sight writes the list")
check(red.display == "fill" && red.fpsMode == 2 && LibraryPrefs.nvidia(rdr2), "a library entry keeps its fields and switches")
check(mark(rdr2)?.hasPrefix("rdr2-steam#\(R.rdr2Steam.version)#") == true, "what was written is recorded")
// A game new to the library takes the whole list.
UserDefaults.standard.removeObject(forKey: key)
GameProfile(windowsPath: rdr2).text = ""
red = LibraryEntry(title: "Red Dead Redemption 2", windowsPath: rdr2, steamAppID: 1174180)
red.display = "fill"
check(R.prepare(&red, new: true), "first sight of a new entry takes the entry's fields")
check(file(rdr2) == R.rdr2Steam.fileText, "first sight writes the list")
check(red.fastSync == true && red.semaphoreFastPath == false && red.display == nil && red.fpsMode == 1, "first sight's entry fields")
check(red.resolution == "1568x720", "this screen's shape at 720 lines")
check(!LibraryPrefs.avx(rdr2) && !LibraryPrefs.nvidia(rdr2) && !LibraryPrefs.wineVCRT(rdr2), "first sight's switches")
check(mark(rdr2)?.hasPrefix("rdr2-steam#\(R.rdr2Steam.version)#") == true, "what was written is recorded")
check(!R.prepare(&red) && file(rdr2) == R.rdr2Steam.fileText, "once")
GameProfile(windowsPath: rdr2).text = R.rdr2Steam.fileText + "fence-chain = 1\n"
check(!R.prepare(&red) && file(rdr2).hasSuffix("fence-chain = 1\n"), "a changed config is the player's")
GameProfile(windowsPath: rdr2).text = ""
check(!R.prepare(&red) && file(rdr2).isEmpty, "an emptied config stays empty")
red.fpsMode = 2
LibraryPrefs.setNvidia(true, for: rdr2)
check(R.reset(&red)?.id == "rdr2-steam" && file(rdr2) == R.rdr2Steam.fileText, "Reset writes the list again")
check(!LibraryPrefs.nvidia(rdr2) && red.fpsMode == 2, "Reset writes the list's switches and leaves the rest")
// A list Madeira wrote that nobody changed follows a newer version: the config file only.
let older = "# an older list\nvram-mb = 2048\n"
GameProfile(windowsPath: rdr2).text = older
var marks = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
marks[rdr2.lowercased()] = "rdr2-steam#0#" + String(LibraryPrefs.stableHash(older), radix: 16)
UserDefaults.standard.set(marks, forKey: key)
LibraryPrefs.setAVX(true, for: rdr2)
check(!R.prepare(&red) && file(rdr2) == R.rdr2Steam.fileText, "an untouched older list is updated")
check(LibraryPrefs.avx(rdr2) && !R.prepare(&red), "an update leaves the switches, once")
print("PASS: first sight writes the list and its switches once; changed or emptied configs stay; Reset writes it again; untouched lists follow newer versions")

var gtaEntry = LibraryEntry(title: "GTA V Enhanced", windowsPath: gta, steamAppID: 3240220)
GameProfile(windowsPath: gta).text = "vram-mb = 4096\n"
check(!R.prepare(&gtaEntry) && file(gta) == "vram-mb = 4096\n" && mark(gta) == "" && gtaEntry.fpsMode == 1, "a config of its own stays")
GameProfile(windowsPath: gta).text = ""
check(!R.prepare(&gtaEntry) && file(gta).isEmpty, "and is not filled in later")
check(R.reset(&gtaEntry)?.id == "gta5e-steam" && file(gta) == R.gta5EnhancedSteam.fileText, "GTA V Enhanced Reset")
check(gtaEntry.fpsMode == 4 && gtaEntry.semaphoreFastPath == true && LibraryPrefs.nvidia(gta) && !LibraryPrefs.avx(gta), "its switches")
let gowExe = #"C:\Games\God of War\GoW.exe"#
var gow = LibraryEntry(title: "God of War", windowsPath: gowExe)
gow.config = "dxmt = d3d11.mipClampBC=1"
check(!R.prepare(&gow) && file(gowExe).isEmpty && mark(gowExe) == "", "lines in upstream's config field are the game's own")
check(R.reset(&gow)?.id == "god-of-war" && gow.resolution == "1920x1080" && gow.config == nil, "God of War Reset")
let deskExe = #"C:\windows\system32\explorer.exe"#
var desk = LibraryEntry(title: "Desktop", windowsPath: deskExe)
desk.desktop = true
check(R.recommendation(for: desk)?.id == "standard", "the Desktop: the standard list")
desk.resolution = "1280x720"
check(!R.prepare(&desk) && file(deskExe) == R.standard.fileText && mark(deskExe)?.hasPrefix("standard#\(R.standard.version)#") == true
      && desk.resolution == "1280x720" && !LibraryPrefs.avx(deskExe), "the Desktop's first sight: the standard list, its own fields")
check(!R.prepare(&desk), "once")
GameProfile(windowsPath: deskExe).text = "fence-chain = 6\n"
check(!R.prepare(&desk) && file(deskExe) == "fence-chain = 6\n", "a changed Desktop config is the player's")
check(R.reset(&desk)?.id == "standard" && file(deskExe) == R.standard.fileText, "the Desktop's Reset writes the standard list")
let fooExe = #"C:\Games\Foo\foo.exe"#
var foo = LibraryEntry(title: "Foo", windowsPath: fooExe)
GameProfile(windowsPath: fooExe).text = "fence-chain = 6\n"
check(!R.prepare(&foo) && file(fooExe) == "fence-chain = 6\n" && mark(fooExe) == "", "a game without a list keeps a config of its own")
check(R.reset(&foo)?.id == "standard" && file(fooExe) == R.standard.fileText, "its Reset writes the standard list")
let barExe = #"C:\Games\Bar\bar.exe"#
var bar = LibraryEntry(title: "Bar", windowsPath: barExe)
check(R.prepare(&bar, new: true) && file(barExe) == R.standard.fileText && bar.resolution == "1408x648" && bar.fpsMode == 1
      && !LibraryPrefs.avx(barExe) && mark(barExe)?.hasPrefix("standard#\(R.standard.version)#") == true,
      "first sight of a new game without a list: the standard list, no switches")
// An untouched standard list gives way to the game's own list later, as on first sight: the config
// file for a game already in the library, the switches and fields too for a new entry.
let laterExe = #"C:\Later\GoW.exe"#
GameProfile(windowsPath: laterExe).text = R.standard.fileText
marks = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
marks[laterExe.lowercased()] = "standard#\(R.standard.version)#" + String(LibraryPrefs.stableHash(R.standard.fileText), radix: 16)
UserDefaults.standard.set(marks, forKey: key)
var later = LibraryEntry(title: "God of War", windowsPath: laterExe)
later.resolution = "1280x720"
LibraryPrefs.setAVX(true, for: laterExe)
check(!R.prepare(&later) && file(laterExe) == R.godOfWar.fileText && later.resolution == "1280x720"
      && LibraryPrefs.avx(laterExe), "an untouched standard list gives way to the game's list; a library entry keeps its fields")
GameProfile(windowsPath: laterExe).text = R.standard.fileText
marks = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
marks[laterExe.lowercased()] = "standard#\(R.standard.version)#" + String(LibraryPrefs.stableHash(R.standard.fileText), radix: 16)
UserDefaults.standard.set(marks, forKey: key)
check(R.prepare(&later, new: true) && file(laterExe) == R.godOfWar.fileText && later.resolution == "1920x1080"
      && !LibraryPrefs.avx(laterExe), "for a new entry, switches and fields too")
print("PASS: own configs (the file or upstream's field) stay until Reset; Reset writes every switch of the list; no list of its own, and the Desktop: the standard list")

// A program outside Steam: drive_c looked up; a list written for an entry since removed.
let drive = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MADEIRA_TEST_DRIVE"]!, isDirectory: true)
let folder = drive.appendingPathComponent("Games/GTA V Enhanced", isDirectory: true)
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
check(FileManager.default.createFile(atPath: folder.appendingPathComponent("gta5_enhanced.EXE").path, contents: Data()), "fixture")
let play = #"C:\Games\GTA V Enhanced\PlayGTAV.exe"#
check(R.recommendation(windowsPath: play, steamAppID: nil)?.id == "gta5e-other", "drive_c is looked up in any case")
check(R.recommendation(windowsPath: #"C:\Games\GTA V\PlayGTAV.exe"#, steamAppID: nil)?.id == "standard", "a missing game file: the standard list")
var removed = LibraryEntry(title: "GTA V Enhanced", windowsPath: play)
check(R.prepare(&removed, new: true) && file(play) == R.gta5EnhancedOther.fileText && LibraryPrefs.nvidia(play)
      && removed.resolution == "1280x720", "first sight of a new program outside Steam")
var playEntry = LibraryEntry(title: "GTA V Enhanced", windowsPath: play)
check(!R.prepare(&playEntry), "another entry for the same program sees it was written")
check(R.prepare(&playEntry, new: true) && playEntry.resolution == "1280x720" && playEntry.fastSync == true,
      "an entry new to the library takes the fields of a list written before")
var page = LibraryEntry(title: "Red Dead Redemption 2", windowsPath: rdr2, steamAppID: 1174180)
page.display = "fill"
check(R.prepare(&page, new: true) && page.display == nil && page.fastSync == true && file(rdr2) == R.rdr2Steam.fileText,
      "a Steam game's first page made before the library stored its entry")
let gotSteam = steam + #"\Ghost of Tsushima DIRECTOR'S CUT"#
let olderGoT = "# an older list\nswap-mb = 2048\n"
GameProfile(windowsPath: gotSteam).text = olderGoT
marks = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
marks[gotSteam.lowercased()] = "ghost-of-tsushima#0#" + String(LibraryPrefs.stableHash(olderGoT), radix: 16)
UserDefaults.standard.set(marks, forKey: key)
var gotEntry = LibraryEntry(title: "Ghost of Tsushima", windowsPath: gotSteam, steamAppID: 2215430)
check(R.prepare(&gotEntry, new: true) && file(gotSteam) == R.ghostOfTsushima.fileText && gotEntry.resolution == "1280x720",
      "a new entry whose untouched older list is updated takes the list's fields too")
let ownExe = #"C:\Games\Ghost Own\GhostOfTsushima.exe"#
GameProfile(windowsPath: ownExe).text = "dxil-tess = 1\n"
var own = LibraryEntry(title: "Ghost of Tsushima", windowsPath: ownExe)
check(!R.prepare(&own, new: true) && mark(ownExe) == "" && own.resolution == "1408x648" && !LibraryPrefs.avx(ownExe),
      "a config of its own stays its own for a new entry too")
let got = #"C:\GoT\GhostOfTsushima.exe"#
var gotOwn = LibraryEntry(title: "Ghost of Tsushima", windowsPath: got)
check(R.prepare(&gotOwn, new: true) && LibraryPrefs.avx(got) && LibraryPrefs.nvidia(got) && gotOwn.resolution == "1280x720", "GoT by its program")
check(LogStore.shared.lines.contains { $0.hasPrefix("[recommended] Red Dead Redemption 2: rdr2-steam v\(R.rdr2Steam.version) written (first sight)") }, "log line")
UserDefaults.standard.removeObject(forKey: key)
print("PASS: drive_c is looked up for a program's list; a new entry takes the fields of a list written for its path before")
'''

with tempfile.TemporaryDirectory(prefix='madeira-recommended-') as directory:
    temporary = Path(directory)
    compiler = shutil.which('swiftc')
    if compiler:
        (temporary / 'Stubs.swift').write_text(stubs)
        # the RDR2 list's config lines (its two comment lines are not config)
        rdr2_config_lines = sum(1 for line in presets['rdr2-steam']['lines']
                                if line.strip() and not line.strip().startswith('#'))
        (temporary / 'main.swift').write_text(main.replace('@RDR2_CONFIG_LINES@', str(rdr2_config_lines)))
        (temporary / 'drive').mkdir()
        (temporary / 'configs').mkdir()
        binary = temporary / 'recommended'
        subprocess.run([compiler, str(app / 'GameRecommendations.swift'), str(app / 'GameRecommendationsApply.swift'),
                        str(temporary / 'Stubs.swift'), str(temporary / 'main.swift'), '-o', str(binary)], check=True)
        env = dict(os.environ, MADEIRA_TEST_DRIVE=str(temporary / 'drive'), MADEIRA_TEST_CONFIGS=str(temporary / 'configs'))
        subprocess.run([str(binary)], check=True, env=env)
    elif args.require_swift:
        raise SystemExit('Swift compiler required for the recommended-settings fixture')
    else:
        print('SKIP: Swift compiler unavailable locally; macOS CI must run this check with --require-swift')
