#!/usr/bin/env python3
"""get-help-earlier-run: Get Help also sends this game's previous run (from Documents/logs) to compare."""
import pathlib, sys
app = pathlib.Path(__file__).resolve().parents[2] / 'app' / 'Madeira'
helper = (app / 'ClaudeHelp.swift').read_text(encoding='utf-8')
view = (app / 'GetHelpView.swift').read_text(encoding='utf-8')
ok = True
def check(cond, what):
    global ok
    print(('PASS: ' if cond else 'FAIL: ') + what); ok = ok and cond
check('static func sessionLogs(in docs: URL) -> [URL]' in helper and 'appendingPathComponent("logs", isDirectory: true)' in helper,
      'Documents/logs is listed, newest first')
check('.sorted { modified($0) > modified($1) }) + sessionLogs(in: docs)' in helper,
      "the game's last run is also looked for in Documents/logs")
check('static func earlierRunLog(title: String, current: URL?, in docs: URL) -> URL?' in helper and 'guard body != now else { continue }' in helper
      and 'where run.started' in helper, "the earlier run is another run of this game that reached Wine, never the current one")
check('("earlier-run.txt", earlier)' in view and 'ClaudeHelp.earlierRunLog(title: title, current: run, in: docs)' in view,
      'the upload zip carries earlier-run.txt (cut and scrubbed like the others)')
print('check-earlier-run: ok' if ok else 'check-earlier-run: FAIL'); sys.exit(0 if ok else 1)
