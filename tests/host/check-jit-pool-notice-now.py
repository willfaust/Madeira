#!/usr/bin/env python3
"""env.MADEIRA_JIT_POOL_NOTICE_NOW: when a library game's start runs out of JIT pool
while the starting screen is up, the starting screen says "Not enough memory" at once
and offers Close Madeira, which keeps the game for the next app run (NextLibraryGame).
Before, the screen waited ~10 s for Steam's code 45 and showed "Madeira Dock could not
complete the Steam launch (code 45). Export the log", and the plain alert came only
after the session ended (which a crash on the way out could skip). Read from the
sources; no Wine runs.
"""
from pathlib import Path
import json, re, sys

root = Path(__file__).resolve().parents[2]
lib = (root / "app/Madeira/Library.swift").read_text(encoding="utf-8")
bcd = (root / "app/Madeira/LibraryBCD.swift").read_text(encoding="utf-8")
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text(encoding="utf-8")
gen = (root / "build/tools/gen-config-catalog.py").read_text(encoding="utf-8")
strings = json.loads((root / "app/Madeira/Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


def body(src, sig, end="\n    }\n"):
    start = src.index(sig)
    return src[start:src.index(end, start)]


poll = body(lib, "    private func poll() {")
check("poll: apply first, then the notice only while the starting screen is up, behind the switch",
      re.search(r"let added = JITPoolAuto\.apply\(windowsPath: entry\.windowsPath, title: entry\.title\)\s*\n[^\n]*\n[^\n]*\n[^\n]*\n\s*if startingScreen, MadeiraConfig\.flag\(\"MADEIRA_JIT_POOL_NOTICE_NOW\"\) \{", poll) is not None)
check("poll: the notice keeps the game and logs",
      "poolRestartEntry = entry.id" in poll and "poolRestartNote = JITPoolAuto.startMessage(entry.title, added: added)" in poll
      and "the starting screen says so now" in poll)
check("poll: a game already on screen keeps the alert after the session",
      "} else if added { poolAutoTitle = entry.title }" in poll)
begin = body(lib, "    func begin(_ entry: LibraryEntry, remember: Bool = true, dock: DockGame? = nil) {")
check("begin resets the notice", "poolRestartNote = nil; poolRestartEntry = nil" in begin)
fin = body(lib, "    private func finish() {")
check("finish clears the notice", "poolRestartNote = nil; poolRestartEntry = nil" in fin)
close = body(lib, "    func closeForPoolRestart() {")
check("Close Madeira keeps the game for the next run, then exits",
      close.index("NextLibraryGame.set(id)") < close.index("exit(0)"))
fail = body(lib, "    fileprivate func lookFailure(_ entry: LibraryEntry) -> some View {", "\n    }\n")
check("the starting screen offers Close Madeira for it (the note's own button, after an installs restart)",
      re.search(r'\} else if model\.poolRestartNote != nil \{\n\s*NewLookSheetButton\(id: "ln-restart", title: L\("Close Madeira"\)[^\n]*\n[^\n]*\{ model\.closeForPoolRestart\(\) \}', fail) is not None)
check("the failure card shows the note (headline and message) before the Dock failure",
      re.search(r"if let note = model\.poolRestartNote \{\n\s*Text\(JITPoolAuto\.startHeadline\)[^\n]*\n\s*Text\(note\)[^\n]*\n\s*\} else if let failure = dockStart\.failure \{", fail) is not None)
check("the starting screen counts the note as a failure and marks the active step failed",
      "let failed = dockStart.failure != nil || model.poolRestartNote != nil" in lib
      and "if model.poolRestartNote != nil, let i = steps.lastIndex(where: { $0.state == .active }) { steps[i].state = .failed }" in lib)

auto = body(bcd, "enum JITPoolAuto {", "\n}\n")
A = "%@ ran out of JIT memory, so Madeira gave it bigger memory settings. Tap Close Madeira (the round arrow below), then open Madeira again: %@ starts by itself."
B = "%@ ran out of JIT memory. Tap Close Madeira (the round arrow below), then open Madeira again; that often gives more memory, and %@ starts by itself."
check("words: headline and both messages", 'L("Not enough memory")' in auto and f'L("{A}")' in auto and f'L("{B}")' in auto)
langs = {"de", "es", "ko", "pt-BR", "ru", "zh-Hans"}
for key in ["Not enough memory", A, B, "Close Madeira"]:
    loc = strings.get(key, {}).get("localizations", {})
    check(f"translated in all six languages: {key[:40]}", langs <= set(loc))
    if key.count("%@") == 2:
        check("  both titles kept", all("%1$@" in loc[l]["stringUnit"]["value"] and "%2$@" in loc[l]["stringUnit"]["value"] for l in langs))

check("the catalog lists the switch, on by default",
      re.search(r'key: "env\.MADEIRA_JIT_POOL_NOTICE_NOW", [^\n]*kind: \.bool, defaultValue: "1"', cat) is not None
      and '"env.MADEIRA_JIT_POOL_NOTICE_NOW"' in gen)

check("the 'JIT memory is small' banner is off unless MADEIRA_JIT_SMALL_NOTICE = 1",
      re.search(r"JITPoolMeter\.current\.shrunk,\s*\n\s*MadeiraConfig\.flag\(\"MADEIRA_JIT_SMALL_NOTICE\", fallback: false\) \{", poll) is not None
      and re.search(r'key: "env\.MADEIRA_JIT_SMALL_NOTICE", [^\n]*kind: \.bool, defaultValue: "0"', cat) is not None
      and '"env.MADEIRA_JIT_SMALL_NOTICE"' in gen)

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
