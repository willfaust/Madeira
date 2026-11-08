#!/usr/bin/env python3
"""env.MADEIRA_AUDIO_MIX: a game's sound plays alongside other apps' (a Discord voice call,
music) unless the switch is 0. Read from the sources.

1. The bridge makes the session mix with others when it activates it, before Wine starts.
2. After madeira.cfg's and the game's env lines are exported, it applies the final choice
   (0: not mixing) and logs it as [audio-mix].
3. BackgroundRun puts the same choice back when it restores the session.
4. The catalog lists the switch, on by default.
"""
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[2]
bridge = (root / "app/Madeira/WineProcessBridge.m").read_text(encoding="utf-8")
bg = (root / "app/Madeira/BackgroundRun.swift").read_text(encoding="utf-8")
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text(encoding="utf-8")
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


first = bridge.index("withOptions:AVAudioSessionCategoryOptionMixWithOthers")
check("the session mixes from the start, before it is made active",
      first < bridge.index("[session setActive:YES error:&aerr];"))
final = bridge.index('const char *mix = getenv("MADEIRA_AUDIO_MIX");')
check("the final choice comes after the game's env lines are exported",
      bridge.index('const char *gameCfg = getenv("MADEIRA_CFG_GAME");') < final
      and 'BOOL mixes = !(mix && !strcmp(mix, "0"));' in bridge[final:final + 200]
      and "[audio-mix]" in bridge[final:final + 900])
check("restoring the session keeps the choice",
      'setCategory(.playback, options: MadeiraConfig.flag("MADEIRA_AUDIO_MIX") ? [.mixWithOthers] : [])' in bg
      and "setCategory(.playback, options: [])" not in bg)
check("the catalog lists it, on by default",
      re.search(r'key: "env\.MADEIRA_AUDIO_MIX", [^\n]*kind: \.bool, defaultValue: "1"', cat) is not None)

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
