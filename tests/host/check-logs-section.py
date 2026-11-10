#!/usr/bin/env python3
"""Settings › Logs and Share Logs (app/Madeira/LogsView.swift).

Checks:
  * the Logs page is in Settings (pages and the long page), Diagnostics links
    to it, and Game details offers Share Logs next to Get Help from Claude;
  * every log that is viewed or shared goes through PrivacyScrub first, and
    the work happens off the main thread (logs can be tens of MB);
  * the bug-report .zip holds the summary, the last game log, this run's log
    and madeira.cfg, deflated;
  * the new UI strings are in Localizable.xcstrings in all six languages;
  * LogsView.swift is compiled into the app.
Where a Swift compiler is installed, LogZip is compiled on its own and its
.zip is opened with Python's zipfile (SKIP without one; --require-swift makes
that a failure).
"""
from pathlib import Path
import json, os, re, shutil, subprocess, sys, tempfile, zipfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
view = (app / 'LogsView.swift').read_text(encoding='utf-8')
pages = (app / 'SettingsPages.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
strings = json.loads((app / 'Localizable.xcstrings').read_text(encoding='utf-8'))['strings']
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


check(project.count('/* LogsView.swift in Sources */') == 2 and project.count('/* LogsView.swift */') == 3,
      'LogsView.swift is compiled into the app')
check('case .logs: return "Logs"' in pages and '.advanced, .logs, .credits' in pages and 'case .logs: LogsSection()' in pages,
      'Settings lists a Logs page')
link = 'NavigationLink { Form { LogsSection() }.navigationTitle("Logs") }'
check(pages.count(link) == 1 and library.count(link) == 1, 'Diagnostics links to Logs, on the pages and on the long page')
check(library.count('ShareLogsButton(entry: entry)') == 1 and
      library.index('Button("Copy Settings"') < library.index('ShareLogsButton(entry: entry)'),
      'Game details offers Share Logs (Get Help from Claude is in the Get Help sheet now)')

check('PrivacyScrub.copy(from: url, to: out)' in view and 'try PrivacyScrub.copy(from: source, to: copy)' in view
      and 'ring.map(PrivacyScrub.line)' in view,
      'shared copies, the .zip and the viewer all go through PrivacyScrub')
check(view.count('DispatchQueue.global(') >= 4, 'listing, viewing, sharing and zipping run off the main thread')
bundle = view[view.index('static func bundle()'):view.index('/// A deflated zip')]
for name in ('LogSummary.fileName', 'LogSummary.gameLogName', '"madeira-log.txt"', 'MadeiraConfig.fileName'):
    check(name in bundle, f'the .zip holds {name}')
check('deflateInit2_(&stream, 6, Z_DEFLATED, -15' in view and 'h += Self.le16(8)' in view,
      'the .zip is raw-deflated (method 8), so a 20 MB log fits under chat upload limits')
for name in ('LogSummary.fileName', 'LogSummary.gameLogName', '"madeira-log.txt"', '"madeira-log.prev.txt"', '"logs"'):
    check(name in view, f'the Logs page lists {name}')

keys = set(re.findall(r'(?:Text|Label|Button|alert)\("((?:[^"\\]|\\.)+)"', view))
keys = {k.replace('\\(lines.count)', '%lld') for k in keys} | {'Logs', 'Share Logs'}
langs = {'de', 'es', 'ko', 'pt-BR', 'ru', 'zh-Hans'}
missing = sorted(k for k in keys if k not in strings or set(strings[k].get('localizations', {})) != langs)
check(not missing, f'every new UI string is translated into {sorted(langs)} (missing: {missing})')

SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
if not Path(SWIFTC).exists():
    if '--require-swift' in sys.argv:
        check(False, 'Swift compiler available')
    else:
        print('SKIP: Swift compiler unavailable locally')
else:
    writer = view[view.index('final class LogZip {'):view.index('private struct SharedLogs')]
    program = 'import Foundation\nimport zlib\n' + writer + r'''
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let zip = try! LogZip(url: out)
var big = ""
for i in 0..<200_000 { big += "[14:09:00.000] [xp] 14:09 +\(i) dt=325 cpu=137\n" }
try! zip.add(name: "madeira-last-game-log.txt", data: Data(big.utf8))
try! zip.add(name: "madeira-summary.txt", data: Data("Program: game.exe\n".utf8))
try! zip.add(name: "empty.txt", data: Data())
try! zip.finish()
'''
    with tempfile.TemporaryDirectory(prefix='madeira-logs-') as directory:
        main = Path(directory) / 'main.swift'
        main.write_text(program)
        binary = Path(directory) / 'check'
        args = [SWIFTC, str(main), '-o', str(binary)]
        if sys.platform.startswith('linux'):
            # Linux has no zlib module: a module map over the system zlib.h.
            shim = Path(directory) / 'zlib'
            shim.mkdir()
            (shim / 'module.modulemap').write_text('module zlib [system] {\n  header "/usr/include/zlib.h"\n  link "z"\n  export *\n}\n')
            args += ['-I', directory]
        built = subprocess.run(args)
        check(built.returncode == 0, 'LogZip compiles')
        if built.returncode == 0:
            zpath = Path(directory) / 'logs.zip'
            ran = subprocess.run([str(binary), str(zpath)])
            check(ran.returncode == 0, 'LogZip writes a .zip')
            with zipfile.ZipFile(zpath) as z:
                check(z.testzip() is None and z.namelist() == ['madeira-last-game-log.txt', 'madeira-summary.txt', 'empty.txt'],
                      f'Python opens it and every entry checks out ({z.namelist()})')
                info = z.getinfo('madeira-last-game-log.txt')
                check(info.compress_type == zipfile.ZIP_DEFLATED and info.compress_size * 5 < info.file_size,
                      f'the log is deflated ({info.file_size} -> {info.compress_size} bytes)')
                check(z.read('madeira-summary.txt') == b'Program: game.exe\n' and z.read('empty.txt') == b'',
                      'small and empty entries read back exactly')

print('PASS' if failures == 0 else f'FAIL ({failures})')
sys.exit(1 if failures else 0)
