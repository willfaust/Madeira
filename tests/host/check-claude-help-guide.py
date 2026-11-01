#!/usr/bin/env python3
"""Get Help from Claude (app/Madeira/ClaudeHelp.swift) and its guide
(app/Madeira/Give-to-Claude-with-log-and-cfg.txt).

Checks:
  * the guide is small enough to paste into a chat (32 KB), plain text, short lines;
  * every setting the guide names (env.NAME lines, MADEIRA_* switches, plain cfg keys
    such as pool-split) is still read somewhere in the code or listed in the config
    catalog, so the guide never tells someone to set a key that does nothing;
  * the guide holds no project-internal paths or ids;
  * the guide and ClaudeHelp.swift are in the Xcode project (resource and source);
  * the guide is copied to Documents at start, and Game details and Settings ›
    Diagnostics both offer the button; the game's file carries its config.
"""
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


name = 'Give-to-Claude-with-log-and-cfg.txt'
guide_path = app / name
guide = guide_path.read_text(encoding='utf-8')
helper = (app / 'ClaudeHelp.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
main = (app / 'MadeiraApp.swift').read_text(encoding='utf-8')
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
catalog = (app / 'ConfigCatalog.generated.swift').read_text(encoding='utf-8')

size = len(guide.encode('utf-8'))
check(size <= 32 * 1024, f'the guide is small enough to paste ({size} bytes, at most 32768)')
long_lines = [i + 1 for i, line in enumerate(guide.splitlines()) if len(line) > 76]
check(not long_lines, f'guide lines are at most 76 characters (long: {long_lines[:5]})')
check(guide.isascii(), 'the guide is plain ASCII (pastes cleanly everywhere)')
check(not re.search(r'cmsg_|/mnt/|chan_|claude/project-thread', guide), 'no project-internal paths, ids or branch names')
check('Give this file to Claude together with your log and your cfg.' in guide, 'the guide says what to hand over with it')

# Every setting the guide names must still exist.
sources = []
for folder in ('app/Madeira', 'build', 'wine-patches', 'madeira-dock', 'docs'):
    base = root / folder
    if not base.exists():
        continue
    for path in base.rglob('*'):
        if path.is_file() and path.suffix in {'.swift', '.m', '.mm', '.c', '.h', '.cpp', '.py', '.sh', '.patch', '.md', '.example'} \
                and path.name != name:
            try:
                sources.append(path.read_text(encoding='utf-8', errors='replace'))
            except OSError:
                pass
code = '\n'.join(sources)

names = set(re.findall(r'\b(?:MADEIRA|DXMT|DOTNET)_[A-Za-z0-9_]+', guide))
names.discard('MADEIRA_')
missing = sorted(n for n in names if n.rstrip('_*') not in code and not n.endswith('_'))
check(not missing, f'every MADEIRA_/DXMT_/DOTNET_ switch the guide names is in the code ({len(names)} names; missing: {missing})')

plain = set()
for line in guide.splitlines():
    m = re.match(r'\s*([a-z][a-z0-9-]+) = \S', line)
    if m:
        plain.add(m.group(1))
plain_missing = sorted(k for k in plain if f'key: "{k}"' not in catalog and f'"{k}"' not in code)
check(plain and not plain_missing, f'every plain cfg key in the guide is a real key ({sorted(plain)}; missing: {plain_missing})')

# The app side.
check(f'static let fileName = "{name}"' in helper, 'ClaudeHelp names the same file')
check('forResource: "Give-to-Claude-with-log-and-cfg", withExtension: "txt"' in helper, 'the guide is read from the app bundle')
check(project.count(f'/* {name} in Resources */') == 2 and project.count(f'/* {name} */') == 3,
      'the guide is an app resource in the Xcode project')
check(project.count('/* ClaudeHelp.swift in Sources */') == 2 and project.count('/* ClaudeHelp.swift */') == 3,
      'ClaudeHelp.swift is compiled into the app')
check('ClaudeHelp.install()' in main, 'the guide is copied into Documents when the app starts')
check(library.count('ClaudeHelpButton(entry: entry)') == 1 and library.count('ClaudeHelpButton(entry: nil)') == 1,
      'Game details (with the game) and Settings > Diagnostics (without one) offer Get Help from Claude')
check('GameProfile(windowsPath: entry.windowsPath).text' in helper and 'LibraryPrefs.sharedSwitches(entry.windowsPath)' in helper,
      "the game's file holds its own config and its Game details switches")
for log in ('LogSummary.fileName', '"madeira-log.txt"', '"madeira-log.prev.txt"', 'MadeiraConfig.fileName'):
    check(log in helper, f'the share includes {log}')
check('"controls", "zones"' in helper, 'touch layouts are left out of the game file (long, unrelated)')

print('PASS' if failures == 0 else f'FAIL ({failures})')
sys.exit(1 if failures else 0)
