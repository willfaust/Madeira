#!/usr/bin/env python3
# ini-editor-async (Cameron, Nov 8): tapping a settings file froze the screen. The file and the
# Unity registry are read in the background, with timing lines in the log.
import pathlib, sys
root = pathlib.Path(__file__).resolve().parents[2]
ini = (root / 'app/Madeira/GameIniFiles.swift').read_text()
unity = (root / 'app/Madeira/UnityPlayerPrefs.swift').read_text()
fails = 0
def check(ok, name):
    global fails
    print(('PASS: ' if ok else 'FAIL: ') + name)
    fails += 0 if ok else 1
check('.task { if document == nil { await load() } }' in ini and 'private func load() async' in ini, 'the editor reads the file in the background')
check('[ini] opened' in ini and '[ini] Add settings file:' in ini and '[ini] Unity check' in ini, 'the log says how long each step took')
check('UnityPlayerPrefs.isUnity(gameFolder: folder) }.value' in ini and 'UnityPlayerPrefs.isUnity(gameFolder: LibraryModel.drive' not in ini, 'the Unity folder check is off the main thread')
check('.task { if original == nil { await load() } }' in unity and '[ini] Unity options' in unity, 'Unity game options read the registry in the background')
check('static let maxRows = 300' in ini and 'private func visible(' in ini and 'more settings are not shown' in ini, 'a file with thousands of entries draws at most 300 rows; search reaches the rest')
sys.exit(1 if fails else 0)
