#!/usr/bin/env python3
"""Settings' status line shows the installed Madeira and the free space (LibraryInfoLine), at its far right in
Ready to play's font (Cameron moved it there from the library page, Wave 7). Read from the sources.

1. LibraryStatus's line (JIT, Memory+, Ready to play) ends with it; the library page no longer has it.
2. It shows BuildStamp.text and the free space of LibraryModel.drive, read off the main
   thread when the library appears and every 30 s; env.MADEIRA_LIBRARY_INFO = 0 hides it.
3. "%@ free" is translated; the catalog lists the switch.
"""
from pathlib import Path
import json, sys

root = Path(__file__).resolve().parents[2]
lib = (root / "app/Madeira/Library.swift").read_text(encoding="utf-8")
grid = (root / "app/Madeira/LibraryGridPage.swift").read_text(encoding="utf-8")
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text(encoding="utf-8")
strings = json.loads((root / "app/Madeira/Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


start = lib.index("struct LibraryStatus: View {")
status = lib[start:lib.index("\n}\n", start)]
check("Settings' status line ends with it, at the far right (settings-info-right)",
      'Text("Ready to play")' in status and
      status.index('Text("Ready to play")') < status.index("Spacer(minLength: 8)\n                LibraryInfoLine()"))
check("no longer on the library page", lib.count("LibraryInfoLine()") == 1)
start = lib.index("struct LibraryInfoLine: View {")
view = lib[start:lib.index("\n}\n", start)]
check("the build and the free space", 'Text(verbatim: "Madeira \\(BuildStamp.text)")' in view and "freeText(free)" in view)
check("free space of the games' drive, off the main thread",
      "LibraryModel.drive" in view and "DispatchQueue.global(qos: .utility).async" in view and "drive.freeSpace" in view)
check("Ready to play's font", ".font(.footnote.weight(.semibold)).foregroundStyle(.secondary)" in view)
check("on appear and every 30 s", "onAppear { update() }" in view and "Timer.publish(every: 30" in view)
check("switch", 'MadeiraConfig.flag("MADEIRA_LIBRARY_INFO")' in view and "if Self.shown {" in view)
check('"%@ free" translated', "%@ free" in strings and len(strings["%@ free"]["localizations"]) >= 6)
check("catalog lists the switch", 'key: "env.MADEIRA_LIBRARY_INFO"' in cat)

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
