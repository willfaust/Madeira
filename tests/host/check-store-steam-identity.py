#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml2310, from a tester's log of 2026-10-31: every launch outside Madeira Dock gets the bridge's fixed Steam
identity (SteamAppId, SteamGameId, SteamAppPath). A game from another store started a launcher that saw
SteamAppId, took its Steam path, failed in its Steam API start ("create pipe failed") and showed only an error.

- app/Madeira/Library.swift: configureLaunch clears MADEIRA_NO_STEAM_IDENTITY for every launch and sets it for an
  Epic library entry unless env.MADEIRA_STORE_STEAM_IDENTITY = 1;
- app/Madeira/WineProcessBridge.m: with it, the three Steam variables are removed instead of set; the flag is
  cleared after it is read.

Static anchors only.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(src, name, stop='\n    }\n'):
    i = src.index(name)
    return src[i:src.index(stop, i)]

lib = (ROOT / 'app/Madeira/Library.swift').read_text(encoding='utf-8')
cfg = body(lib, 'func configureLaunch() {')
check('unsetenv("MADEIRA_NO_STEAM_IDENTITY")' in cfg.split('if steamAppID != nil')[0],
      'every launch clears the flag before anything returns')
check('if epicAppName != nil, MadeiraConfig.get("env.MADEIRA_STORE_STEAM_IDENTITY") != "1" {\n            setenv("MADEIRA_NO_STEAM_IDENTITY", "1", 1)' in cfg,
      'an Epic entry sets it unless env.MADEIRA_STORE_STEAM_IDENTITY = 1')

bridge = (ROOT / 'app/Madeira/WineProcessBridge.m').read_text(encoding='utf-8')
i = bridge.index('const char *no_steam_id = getenv("MADEIRA_NO_STEAM_IDENTITY");')
block = bridge[i:bridge.index('/* iOS-Madeira 2026-07-02', i)]
branch = block[block.index("} else if (no_steam_id && no_steam_id[0] == '1') {"):]
branch = branch[:branch.index('} else if', 10)]
check(all(f'unsetenv("{v}");' in branch for v in ('SteamAppPath', 'SteamGameId', 'SteamAppId')),
      'with the flag, none of the three Steam variables is published')
check(block.index("dock_session[0] == '1'") < block.index("no_steam_id[0] == '1'") < block.index('direct_app && direct_app[0]'),
      'the Dock branch first, then the store branch, before a direct Steam start and the fixed identity')
check('unsetenv("MADEIRA_NO_STEAM_IDENTITY");' in block[block.index('setenv("SteamAppId",  "356400", 1);'):],
      'the flag is cleared after it is read, so no later launch inherits it')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    check('key: "env.MADEIRA_STORE_STEAM_IDENTITY"' in text, 'the config catalog documents env.MADEIRA_STORE_STEAM_IDENTITY')

print(f'check-store-steam-identity: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
