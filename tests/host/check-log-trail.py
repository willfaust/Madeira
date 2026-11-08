#!/usr/bin/env python3
"""The log's trail (app/Madeira/LogTrail.swift), on the host.

Source checks: the file is in the app target; it is installed at the app's first
appearance and fed every line of madeira-log.txt; Play, the session's begin, Quit,
Stop, a failed start and the return to the library reach it; LibraryController logs
each press with the ring; the game page and Settings sheets are named; every line
the trail reads as a step is still written somewhere in the sources; the launched
program's exit status is kept for any value; repeats collapse in LogStore.log; the
per-kind caps keep a run to a few hundred lines; the markers are binary-visible
(longer than Swift's 15-byte inline strings). The timestamp reader is mirrored in
Python and run.
"""
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


trail = (app / 'LogTrail.swift').read_text()
store = (app / 'LogStore.swift').read_text()
library = (app / 'Library.swift').read_text()
content = (app / 'ContentView.swift').read_text()
madeira_app = (app / 'MadeiraApp.swift').read_text()
pages = (app / 'SettingsPages.swift').read_text()
bridge_m = (app / 'WineProcessBridge.m').read_text()
bridge_h = (app / 'WineProcessBridge.h').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()

require(project.count('A1000E71 /* LogTrail.swift in Sources */') == 2 and project.count('A2000E71 /* LogTrail.swift */') == 3,
        'LogTrail.swift is in the app target')
require('static let enabled = MadeiraConfig.flag("MADEIRA_LOG_TRAIL")' in trail, 'the switch, on by default')
require('LogTrail.install()' in madeira_app, 'installed at the first appearance')
require('LogTrail.see(line)' in store, 'every line of the log file reaches the trail')

# The wiring into a game's life.
require('LogTrail.play(entry)' in content, 'Play starts the clock')
require('LogTrail.began(entry, dock: dock != nil)' in library, 'the session begin logs [game-start]')
require('LogTrail.ending("Quit game")' in library and 'LogTrail.ending("Stop on the starting screen")' in library
        and 'LogTrail.ending("the start failed"' in library, 'Quit, Stop and a failed start give the reason')
require('LogTrail.backInLibrary()' in library, 'finish() leads to the [game-end] line')
require('LogTrail.inGameMenu(menu)' in library, 'the in-game menu lets taps be logged')

controller = library[library.index('final class LibraryController'):library.index('enum FrontendChoice')]
require('LogTrail.pressed(command, ownsMenus: own, before: before)' in controller
        and 'let before = MainActor.assumeIsolated { LogTrail.ring }' in controller, 'each press is logged with the ring before and after')
require('LogTrail.pressedUnused(pressed)' in controller, 'a press with no menu command is logged too')
require('.logScreen("game page: \\(entry.title)")' in library and '.logScreen("add a game")' in library, 'the game page and the add-a-game browser are named')
require('.logScreen("Settings sheet:' in pages, 'Settings sheets are named')

# Focus, screens, taps, app state.
for needle, label in [
    ('UIFocusSystem.didUpdateNotification', 'iOS focus moves are logged'),
    ('UIFocusSystem.movementDidFailNotification', 'failed iOS focus moves are logged'),
    ('UIApplication.didReceiveMemoryWarningNotification', 'iOS memory warnings are logged'),
    ('UIApplication.didEnterBackgroundNotification', 'background and foreground are logged'),
    ('.GCControllerDidDisconnect', 'controller disconnects are logged'),
    ('as? UIAlertController', 'alerts are named with title and buttons'),
    ('LogTrailTapWatch(target: nil, action: nil)', 'taps are watched on the window'),
    ('override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }', 'the tap watch never prevents another gesture'),
    ('cancelsTouchesInView = false', 'the tap watch never takes a touch'),
    ('guard session.title == nil || session.inMenu else { return }', "a game's own touches are not logged"),
]:
    require(needle in trail, label)
require('accessibilityElements' not in trail, "SwiftUI's accessibility tree is never asked for (it would be built)")

# Each step pattern is still written by the code (else the step silently disappears).
sources = '\n'.join(p.read_text(errors='replace') for p in list(app.rglob('*.swift')) + list(app.rglob('*.m')) + list(app.rglob('*.mm'))
                    if p.name != 'LogTrail.swift')
steps = re.findall(r'\("([^"]+)", "([^"]+)"\),', trail[trail.index('static let steps:'):trail.index('/// "[00:10:48.331]')])
require(len(steps) >= 10, f'{len(steps)} step patterns')
for pattern, _ in steps:
    require(pattern in sources, f'step pattern still logged: {pattern}')

# Exit status of the launched program, any value.
require('int wine_launched_exit_code(uint32_t *status);' in bridge_h, 'wine_launched_exit_code is declared')
fn = bridge_m[bridge_m.index('void wine_launched_process_did_exit(int status) {'):bridge_m.index('int wine_crash_exit_status(uint32_t *status) {')]
require('__atomic_store_n(&g_launch_exit_any, (UINT64_C(1) << 32) | (uint32_t)status' in fn
        and fn.index('g_launch_exit_any, (UINT64') < fn.index('if ((uint32_t)status >= 0xC0000000u)'), 'every exit status is kept, before the crash filter')
require('__atomic_store_n(&g_launch_exit_any, 0, __ATOMIC_RELEASE);' in fn, 'reset with the others')
require('wine_launched_exit_code(&status)' in trail, '[game-end] reads it')

# Repeats and size.
log_fn = store[store.index('func log(_ message: String, level: LogEntry.Level = .info) {'):store.index('func flushRepeats()')]
require('message == lastWritten, now.timeIntervalSince(lastWrittenAt) < 60' in log_fn, 'the same line within a minute is counted, not written')
require('MadeiraConfig.flag("MADEIRA_LOG_COLLAPSE")' in store, 'env.MADEIRA_LOG_COLLAPSE = 0 writes repeats')
require('LogStore.shared.flushRepeats()' in store, 'the count is written when Madeira goes to the background')
require('LogTrail.during()' in log_fn and 'level == .error' in log_fn, 'an error line says what was going on')
caps = dict(re.findall(r'\.(\w+): (\d+)', trail[trail.index('private static let caps'):].split('\n')[0]))
total = sum(int(v) for v in caps.values())
require(set(caps) == {'pad', 'focus', 'screen', 'tap', 'app', 'step'} and total <= 900, f'caps per run: {caps} = {total} lines at most')

# Markers: literal segments longer than 15 bytes, so they are in the binary's string table.
for marker in ['[log-trail] on: [pad] [focus] [screen] [tap] [app] [step]', '[focus] system focus -> ',
               '[last-run] Madeira closed while ', '[log-repeat] repeated ']:
    require(len(marker.encode()) > 15 and marker in (trail + store), f'marker in the source: {marker}')


# madeira-log-summary: the block at the top, one run for Get Help.
require(store.count('try? LogRuns.initialHeader().write(to: logFileURL, atomically: true, encoding: .utf8)') == 2,
        'the log starts with the summary block (at start and after Clear)')
require('static let headerBytes = 4096' in trail and 'data.count == headerBytes' in trail, 'the block is a fixed size, rewritten in place')
require('String(decoding: head, as: UTF8.self) == firstLine' in trail, 'the block is rewritten only while the file still starts with it')
require('LogRuns.start(title: entry.title, store: store, windowsPath: entry.windowsPath)' in trail
        and 'LogRuns.began(title: entry.title)' in trail and 'LogRuns.stepped(name, seconds: seconds)' in trail
        and 'LogRuns.ended(why + ", " + code' in trail and 'LogRuns.previousRun(' in trail, 'runs start, step, end, and the previous run is noted')
require('static func lastRunText(game: String? = nil, maxBytes: Int = 200_000' in trail, 'one game\'s last run for Get Help: LogRuns.lastRunText(game:)')
block = trail[trail.index('static func headerText()'):trail.index('private static let fileLock')]
require(not re.search(r'"\s*\[[a-z-]+\] ', block), 'the block has no [tag] lines')
for marker in ['=== Madeira log summary: what happened, then the full log below ===', '--- One game run: Madeira']:
    require(marker in trail, f'marker in the source: {marker}')


def slice_run(lines, game, tail=3):
    """Mirror of LogRuns.slice (no size cut)."""
    start = number = None
    for i in range(len(lines) - 1, -1, -1):
        m = re.search(r'\[run-start\] #(\d+) (.*)$', lines[i])
        if m and (game is None or m.group(2).strip() == game):
            start, number = i, m.group(1); break
    if start is None:
        return None
    end = next((i for i in range(start, len(lines)) if f'[run-end] #{number}' in lines[i]), len(lines) - 1)
    out = []
    for i in range(start, end + 1):
        line = lines[i]
        madeira = line.startswith('[') and line[1:13].count(':') == 2
        if i >= end - tail + 1 or madeira or ':err:' in line:
            out.append(line)
    return out


log = ['[00:00:01.000] [INFO] [run-start] #1 Stardew Valley', '0108:fixme:x', '0108:err:y', '[00:00:09.000] [INFO] [run-end] #1',
       '[00:01:00.000] [INFO] [run-start] #2 Satisfactory', 'noise1', 'noise2', 'noise3', 'noise4', 'last1', 'last2']
s1 = slice_run(log, 'Stardew Valley')
require(s1 is not None and s1[0].endswith('#1 Stardew Valley') and '0108:err:y' in s1 and s1[-1].endswith('[run-end] #1'),
        'a named game\'s run is cut from its start to its end, with Wine errors')
s2 = slice_run(log, None)
require(s2 is not None and s2[0].endswith('#2 Satisfactory') and 'noise1' not in s2 and s2[-1] == 'last2', 'no name: the last run, to the end of the file, with its last lines')

# The timestamp reader, mirrored.
def time_of(line):
    if not line.startswith('[') or len(line) <= 13:
        return None
    parts = [int(x) for x in re.split(r'[:.]', line[1:13]) if x.isdigit()]
    return parts if len(parts) == 4 else None


require(time_of('[00:10:48.331] [INFO] [launch] wineserver ready after 25 ms') == [0, 10, 48, 331], 'a log time is read')
require(time_of('0108:err:process:foo') is None, "a Wine line has no time: the arrival time is used")

print('check-log-trail: ' + ('PASS' if failures == 0 else f'FAIL ({failures})'))
sys.exit(1 if failures else 0)
