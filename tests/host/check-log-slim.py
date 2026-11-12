#!/usr/bin/env python3
"""Get Help's upload zip, slimmed (log-fixes: app/Madeira/LogSlim.swift, GetHelpView.swift).

A Python copy of LogSlim, with its limits and tag list read from the Swift source,
run on a made-up log:
  * a line repeated with other numbers is kept keepFirst times, then every `every`th,
    and the end lists what was left out with counts;
  * Madeira's own story lines ([run-start], [step], [game-end], [ERR] ...) are never dropped;
  * a run whose first line is in skipStarts becomes one note line, up to its [run-end].
Then source checks: the upload uses it (MADEIRA_UPLOAD_SLIM), waits for a running game,
names the Library game in the report, adds crash handlers to the helper list, writes
[time] lines (MADEIRA_LOG_TICK), and LogSlim.swift is in the Xcode project.

Optional: pass folders with game-run.txt / madeira-log.txt (unpacked Sentry zips) to print
the before/after deflated size of each.
"""
from pathlib import Path
import re, sys, zlib

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
slim_src = (app / 'LogSlim.swift').read_text(encoding='utf-8')
view = (app / 'GetHelpView.swift').read_text(encoding='utf-8')
report = (app / 'HelpReport.swift').read_text(encoding='utf-8')
summary = (app / 'LogSummary.swift').read_text(encoding='utf-8')
store = (app / 'LogStore.swift').read_text(encoding='utf-8')
trail = (app / 'LogTrail.swift').read_text(encoding='utf-8')
proj = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
failures = 0


def check(condition, label):
    global failures
    print(('PASS ' if condition else 'FAIL ') + label)
    if not condition:
        failures += 1


KEEP_FIRST = int(re.search(r'static let keepFirst = (\d+)', slim_src).group(1))
EVERY = int(re.search(r'static let every = (\d+)', slim_src).group(1))
TOP = int(re.search(r'static let topListed = (\d+)', slim_src).group(1))
TAGS = re.findall(r'"([^"]+)"', re.search(r'static let keptTags = \[(.*?)\]\n', slim_src, re.S).group(1))
NUM = re.compile(r'0x[0-9A-Fa-f]+|\b(?=[0-9A-Fa-f]*[0-9])[0-9A-Fa-f]{4,}\b|[0-9]+')
CLOCK = re.compile(r'^\[[0-9:.]+\] ')


def shape(line):
    return NUM.sub('N', CLOCK.sub('', line, count=1))


def slim(lines, skip_starts=()):
    seen, dropped, total, skip_end, skipped, out = {}, {}, 0, None, 0, []
    note = lambda n: f'[log-slim] {n} lines of this game\'s run left out here'
    for line in lines:
        if skip_end:
            skipped += 1
            if skip_end in line:
                skip_end = None
                out.append(note(skipped))
            continue
        if line in skip_starts and '[run-start] #' in line:
            n = re.match(r'\d+', line.split('[run-start] #', 1)[1])
            if n:
                skip_end, skipped = f'[run-end] #{n.group(0)}', 1
                continue
        if any(t in line for t in TAGS):
            out.append(line); continue
        s = shape(line)
        c = seen.get(s, 0) + 1
        seen[s] = c
        if c <= KEEP_FIRST or c % EVERY == 0:
            out.append(line); continue
        dropped[s] = dropped.get(s, 0) + 1
        total += 1
    if skip_end:
        out.append(note(skipped))
    if total:
        out.append(f'[log-slim] {total} repeated lines were left out')
        out += [f'  {c} x {s}' for s, c in sorted(dropped.items(), key=lambda kv: (-kv[1], kv[0]))[:TOP]]
    return out


# Made-up log: a game's run inside madeira-log, a flood of one FEX line, Madeira's story lines.
log = ['[10:00:00.000] [INFO] [app] Madeira is active']
log += ['[10:00:01.000] [INFO] [run-start] #1 Test Game', '[10:00:01.100] [INFO] [step] Test Game +0.1s Wine sequence']
log += [f'[mach_exc] UNALIGNED-LSE madeira #{i} SWP pc=0x{0x1000 + i:x} size=4' for i in range(5000)]
log += [f'[10:00:02.{i:03d}] [ERR] something {i}' for i in range(200)]
log += ['[10:00:03.000] [ERR] [game-end] Test Game: Quit game', '[10:00:03.000] [INFO] [run-end] #1',
        '[10:00:04.000] [INFO] [get-help] answer']
out = slim(log)
check(sum(l.startswith('[mach_exc]') for l in out) == KEEP_FIRST + (5000 // EVERY) - (KEEP_FIRST // EVERY),
      f'a repeated line is kept {KEEP_FIRST} times, then every {EVERY}th')
check(sum('[ERR] something' in l for l in out) == 200, 'Madeira [ERR] lines are all kept')
check(all(any(t in l for l in out) for t in ['[run-start] #1', '[step]', '[game-end]', '[run-end] #1', '[get-help]']),
      'the story lines (run start, step, game end, run end, get-help) are kept')
check(any('repeated lines were left out' in l for l in out) and any(' x [mach_exc] UNALIGNED-LSE' in l for l in out),
      'the end lists the left-out lines and their count')
skipped = slim(log, {'[10:00:01.000] [INFO] [run-start] #1 Test Game'})
check(not any('[step]' in l for l in skipped) and any('lines of this game\'s run left out' in l for l in skipped)
      and any('[get-help]' in l for l in skipped), 'a run sent as its own file becomes one line in madeira-log')

check('LogSlim(skipStarts: name == "madeira-log.txt" ? sentRuns : [])' in view, 'only madeira-log.txt leaves out the sent runs')
check('MadeiraConfig.flag("MADEIRA_UPLOAD_SLIM")' in view, 'env.MADEIRA_UPLOAD_SLIM = 0 turns the slimming off')
check('while LogTrail.isRunning(title), waited < waitForEnd' in view and 'static let waitForEnd = 120' in view,
      'the upload waits up to 120 s for a game that is still running')
check('The game was still running when these logs were taken' in view, 'a run with no end says so at the top of game-run.txt')
check('static func isRunning(_ title: String) -> Bool' in trail, 'LogTrail tells whether a game is still running')
check('title: String? = nil' in report and 'its program did not start in this log' in report
      and 'cfg: cfg, title: title)' in view, 'the report names the Library game, also when its program never started')
for helper in ['unitycrashhandler64.exe', 'pnkbstra.exe', 'pnkbstrb.exe']:
    check(f'"{helper}"' in summary, f'{helper} is a helper, never the game')
check('MadeiraConfig.flag("MADEIRA_LOG_TICK")' in store and 'appendToFile("[time]"' in store
      and 'self?.tick(after: line)' in store, 'untimed Wine/FEX lines get a [time] line each second')
check(proj.count('/* LogSlim.swift */') == 3 and proj.count('/* LogSlim.swift in Sources */') == 2, 'LogSlim.swift is in the Xcode project (file, build file, group, sources)')

# Optional: real unpacked zips.
for folder in map(Path, sys.argv[1:]):
    run, mlog = folder / 'game-run.txt', folder / 'madeira-log.txt'
    before = after = raw_before = raw_after = 0
    starts = set()
    for f in [run, folder / 'earlier-run.txt']:
        if f.exists():
            first = next((l for l in f.read_text(errors='replace').split('\n') if '[run-start] #' in l), None)
            if first: starts.add(first)
    for f, skip in [(run, set()), (folder / 'earlier-run.txt', set()), (mlog, starts)]:
        if not f.exists():
            continue
        lines = f.read_text(errors='replace').split('\n')
        kept = slim(lines, skip)
        raw_before += len('\n'.join(lines).encode()); raw_after += len('\n'.join(kept).encode())
        before += len(zlib.compress('\n'.join(lines).encode(), 6))
        after += len(zlib.compress('\n'.join(kept).encode(), 6))
    if before:
        print(f'SIZE {folder.parent.name}: logs {raw_before/1e6:.1f} MB -> {raw_after/1e6:.1f} MB, zipped {before/1e6:.2f} -> {after/1e6:.2f} MB')

print('FAILURES', failures)
sys.exit(1 if failures else 0)
