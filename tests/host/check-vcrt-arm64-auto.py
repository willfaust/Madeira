#!/usr/bin/env python3
"""env.MADEIRA_VCRT_ARM64_AUTO: an Unreal Engine game starts with the ARM64 Visual C++
marker (env.MADEIRA_VCRT_ARM64_KEY = 1), so its bootstrap stops asking for the arm64
redistributable (Satisfactory 0x2329, Subnautica 2). Read from the sources; no Wine runs.

1. BCDLaunch.applyLibrary sets or unsets the variable first, for every start (also the
   Wine desktop), so one game's value never carries over.
2. Off for the desktop, with env.MADEIRA_VCRT_ARM64_AUTO = 0, or for a non-Unreal game.
3. Unreal: an Engine folder with Binaries or Extras in the game's folder, or in a folder
   between it and a program started below it.
4. The game's own line and madeira.cfg's are exported later (MADEIRA_CFG_GAME, read by the
   bridge), so they win; the catalog lists the switch and says so.
"""
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[2]
bcd = (root / "app/Madeira/LibraryBCD.swift").read_text(encoding="utf-8")
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text(encoding="utf-8")
gen = (root / "build/tools/gen-config-catalog.py").read_text(encoding="utf-8")
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


def body(src, sig):
    start = src.index(sig)
    return src[start:src.index("\n    }\n", start)]


lib = body(bcd, "    static func applyLibrary(_ entry: LibraryEntry) {")
check("applyLibrary sets the marker before anything returns early",
      lib.index("applyVCRTArm64(entry)") < lib.index("if entry.desktop == true {"))
auto = body(bcd, "    static func applyVCRTArm64(_ entry: LibraryEntry?) {")
check("off for the desktop, the switch, or a non-Unreal game (unset)",
      re.search(r'guard let entry, entry\.desktop != true, MadeiraConfig\.flag\("MADEIRA_VCRT_ARM64_AUTO"\), isUnreal\(entry\) else \{\s*unsetenv\("MADEIRA_VCRT_ARM64_KEY"\)', auto) is not None)
check("an Unreal game gets 1 and a log line",
      'setenv("MADEIRA_VCRT_ARM64_KEY", "1", 1)' in auto and "[vcrt-arm64]" in auto)
unreal = body(bcd, "    static func isUnreal(_ entry: LibraryEntry) -> Bool {")
check("Unreal = Engine with Binaries or Extras", '"Engine"' in unreal and '["Binaries", "Extras"]' in unreal)
check("a program below the game's folder: the folders in between are checked",
      "launchWindowsPath" in unreal and 'hasPrefix(folder.path + "/")' in unreal and "candidates.append(dir)" in unreal)
check("the catalog lists the switch, on by default, from LibraryBCD.swift",
      re.search(r'key: "env\.MADEIRA_VCRT_ARM64_AUTO", [^\n]*kind: \.bool, defaultValue: "1"[^\n]*sources: \["app/Madeira/LibraryBCD\.swift"\]', cat) is not None
      and '"env.MADEIRA_VCRT_ARM64_AUTO"' in gen)
check("the marker's own note mentions the automatic choice",
      re.search(r'key: "env\.MADEIRA_VCRT_ARM64_KEY"[^\n]*except for an Unreal Engine game', cat) is not None)

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
