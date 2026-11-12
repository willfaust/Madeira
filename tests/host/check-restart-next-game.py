#!/usr/bin/env python3
"""The one-session-per-run rule (LibraryModel.sessionsThisRun), on the host: source checks.

A Play held because a session already ran in this app run names the game in the
Restart Madeira alert; the alert's Close Madeira keeps that game (NextLibraryGame), and
the next app run starts it once, within 30 minutes, without a Wine session having run.
Later forgets it. A Home Screen shortcut and a Steam game's steam://run request win over
it and drop it. Synthetic: reads the Swift sources only.
"""
from pathlib import Path
import json, sys

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
library = (app / 'Library.swift').read_text()
content = (app / 'ContentView.swift').read_text()
shortcuts = (app / 'SavesAndShortcuts.swift').read_text()
strings = json.loads((app / 'Localizable.xcstrings').read_text())['strings']
failed = 0

def check(ok, what):
    global failed
    print(('ok   ' if ok else 'FAIL ') + what)
    failed += not ok

key = 'Madeira starts one game each time it is opened. Tap Close Madeira, then open Madeira again: %@ starts by itself.'
check('func holdForRestart(_ entry: LibraryEntry?)' in library and f'L("{key}")' in library,
      'holdForRestart names the held game in the alert')
check(key in strings and all('%1$@' in v['stringUnit']['value'] for v in strings[key]['localizations'].values()),
      'the alert text is in the catalog, every translation keeps the game name')
check('restartEntry = entry.id' in library and library.count('restartEntry = ') == 1,
      'only holdForRestart sets the held game')
check(content.count('library.holdForRestart(') == 2 and 'library.restartNotice = LibraryModel.restartMessage' not in content,
      'both held launches (library Play and Dock) go through holdForRestart')
close = content[content.index('Button("Close Madeira") {\n                    LogStore.shared.log("[session-once] closed'):]
close = close[:close.index('exit(0)')]
check('NextLibraryGame.set(id)' in close, 'Close Madeira keeps the held game before exit')
check('library.restartNotice = nil; library.restartEntry = nil' in content, 'Later forgets the held game')
check('enum NextLibraryGame' in shortcuts and 'age < 30 * 60' in shortcuts[shortcuts.index('enum NextLibraryGame'):]
      and 'removeObject(forKey: key)' in shortcuts[shortcuts.index('enum NextLibraryGame'):],
      'NextLibraryGame is taken once and only within 30 minutes')
pending = content[content.index('private func launchPendingShortcut()'):]
pending = pending[:pending.index('\n    }\n')]
check('_ = NextSteamApp.take(); _ = NextLibraryGame.take()' in pending, 'a shortcut drops the held game')
check(pending.index('guard LibraryModel.sessionsThisRun == 0 else { return }') < pending.index('let heldGame = NextLibraryGame.take()')
      < pending.index('NextSteamApp.take() {'), 'held game read only before any session; steam://run wins')
check('$0.id == heldGame' in pending and pending.rstrip().endswith('launchLibraryEntry(entry)'),
      'the held game starts through Play (JIT, cloud and settings checks)')
sys.exit(1 if failed else 0)
