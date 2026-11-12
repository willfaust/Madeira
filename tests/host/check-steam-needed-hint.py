#!/usr/bin/env python3
"""A Steam game started without Madeira Dock that hands itself to Steam and quits
(Slay the Spire 2 on "Start with: The game"): the bridge notes it (wine_handed_to_steam,
WineProcessBridge.m) and the library shows "This game needs Steam" with Use Madeira Dock.

Checks the pieces are wired, then compiles the bridge's name matcher on its own and runs
it on child-name lists."""
from pathlib import Path
import re, subprocess, sys, tempfile, os

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0
def check(ok, label):
    global failures
    print(('PASS: ' if ok else 'FAIL: ') + label)
    failures += 0 if ok else 1

bridge = (app / 'WineProcessBridge.m').read_text()
header = (app / 'WineProcessBridge.h').read_text()
library = (app / 'Library.swift').read_text()
content = (app / 'ContentView.swift').read_text()

check('int wine_handed_to_steam(void);' in header, 'header declares wine_handed_to_steam')
check(re.search(r'void wine_exit_status_reset\(void\) \{[^}]*g_handed_to_steam, 0', bridge, re.S) is not None,
      'a new session forgets the note')
check('if (n > 0) madeira_note_handed_to_steam(names);' in bridge, 'noted where the main process ends with live children')
check('else if sawProcess, let hint = steamNeededHint() { steamNeeded = hint }' in library, 'finish() asks for the hint before the exit report')
check('MadeiraConfig.flag("MADEIRA_STEAM_NEEDED_HINT")' in library, 'off switch env.MADEIRA_STEAM_NEEDED_HINT')
check('entry.steamAppID == nil || entry.startsSteamGameDirectly' in library, 'never for a Madeira Dock session')
check('library.useMadeiraDock(hint.id)' in content and '.alert("This game needs Steam"' in content, 'the alert offers Use Madeira Dock')
check(re.search(r'func useMadeiraDock\(_ id: UUID\) \{.{0,200}?entry\.steamStart = nil\s+save\(entry\)', library, re.S) is not None,
      'Use Madeira Dock saves Start with: Madeira Dock')

m = re.search(r'static int g_handed_to_steam = 0;.*?static void madeira_note_handed_to_steam\(const char \*names\) \{.*?\n\}\n', bridge, re.S)
check(m is not None, 'name matcher found')
if m:
    src = '#include <stdio.h>\n#include <string.h>\n#include <strings.h>\n#include <unistd.h>\n' + m.group(0) + r'''
int main(void) {
    const char *yes[] = {"steam.exe", "Steam.exe", "unitycrashhandler64.exe steam.exe", "steam.exe game.exe", "a.exe  STEAM.EXE"};
    const char *no[] = {"", "steamwebhelper.exe", "mysteam.exe", "steam.exe.bak", "steamservice.exe game.exe"};
    for (unsigned i = 0; i < sizeof yes / sizeof *yes; i++) { g_handed_to_steam = 0; madeira_note_handed_to_steam(yes[i]); if (!wine_handed_to_steam()) { printf("missed %s\n", yes[i]); return 1; } }
    for (unsigned i = 0; i < sizeof no / sizeof *no; i++) { g_handed_to_steam = 0; madeira_note_handed_to_steam(no[i]); if (wine_handed_to_steam()) { printf("wrong %s\n", no[i]); return 1; } }
    return 0;
}
'''
    with tempfile.TemporaryDirectory() as d:
        c = os.path.join(d, 't.c'); exe = os.path.join(d, 't')
        Path(c).write_text(src)
        built = subprocess.run(['cc', '-std=c11', '-D_DEFAULT_SOURCE', '-Wall', '-Werror', '-fsanitize=address,undefined', '-o', exe, c],
                               capture_output=True, text=True)
        check(built.returncode == 0, 'matcher compiles' + ('' if built.returncode == 0 else ': ' + built.stderr[:300]))
        if built.returncode == 0:
            run = subprocess.run([exe], capture_output=True, text=True)
            check(run.returncode == 0, 'matcher finds steam.exe only as a whole name' + ('' if run.returncode == 0 else ': ' + run.stdout))
sys.exit(1 if failures else 0)
