#!/usr/bin/env python3
"""Game details > Advanced: Copy Compat Report (compat-report).

Players asked on Discord for one tap that copies the report format pinned in the
#game-compatibility forum:
    - Device:
    - iOS version:
    - Madeira version:
    - DRM (yes/no):
    - Results:
Source checks (no swiftc here):
1. CompatReport.format() writes the game's title, then those five lines in that order,
   with Results left empty for the player.
2. Device is the model identifier (uname machine), iOS version is systemName + systemVersion,
   Madeira version is BuildStamp.text (the same as the log's [build] line).
3. DRM: Steam, Epic and EA say Yes, GOG and itch.io say No, anything else is left blank.
4. The button is on the game's Advanced page, shows "Copied" after a tap, and env.MADEIRA_COMPAT_REPORT = 0
   hides it. Share Setup ... Reset to Recommended follow it there (game-actions-advanced); Game details ends
   with Uninstall.
5. The config catalog lists env.MADEIRA_COMPAT_REPORT, and the new texts have all six languages.
"""
from pathlib import Path
import json
import re
import sys

root = Path(__file__).resolve().parents[2]
lib = (root / 'app/Madeira/Library.swift').read_text()
catalog = (root / 'app/Madeira/ConfigCatalog.generated.swift').read_text()
strings = json.loads((root / 'app/Madeira/Localizable.xcstrings').read_text(encoding='utf-8'))['strings']
failures = []


def check(cond, what):
    print(('PASS: ' if cond else 'FAIL: ') + what)
    if not cond:
        failures.append(what)


def block(text, header):
    p = text.index(header)
    a = text.index('{', p)
    n, b = 1, a + 1
    while n:
        n += (text[b] == '{') - (text[b] == '}')
        b += 1
    return text[p:b]


report = block(lib, 'enum CompatReport {')
fmt = re.search(r'static func format\(.*?\) -> String \{\s*"""\n(.*?)\n\s*"""', report, re.S)
check(fmt is not None, 'CompatReport.format has a multi-line template')
if fmt:
    lines = [l.strip() for l in fmt.group(1).split('\n')]
    check(lines == ['\\(title)', '- Device: \\(device)', '- iOS version: \\(system)', '- Madeira version: \\(build)',
                    '- DRM (yes/no): \\(drm)', '- Results:'], f'the template is the pinned format: {lines}')
    # Render it the way Swift would, for a Steam game on an iPad.
    values = {'title': 'Stardew Valley', 'device': 'iPad16,9', 'system': 'iPadOS 27.2',
              'build': '0.2.0 · 11-03 21:04', 'drm': 'Yes (Steam)'}
    text = '\n'.join(re.sub(r'\\\((\w+)\)', lambda m: values[m.group(1)], l) for l in lines)
    print(text)
    check(text.endswith('- Results:') and '- DRM (yes/no): Yes (Steam)' in text, 'rendered report reads right')
check('uname(&info)' in report and 'info.machine' in report, 'Device is the model identifier')
check('UIDevice.current.systemName) \\(UIDevice.current.systemVersion)' in report, 'iOS version: system name and version')
check('build: BuildStamp.text' in report, 'Madeira version is BuildStamp.text, as in [build]')
drm = block(report, 'static func drm(')
order = [('steamAppID', 'Yes (Steam)'), ('epicAppName', 'Yes (Epic Games)'), ('eaOfferID', 'Yes (EA app)'),
         ('gogProductID', 'No (GOG)'), ('itchGameID', 'No (itch.io)')]
check(all(f'entry.{k} != nil {{ return "{v}" }}' in drm for k, v in order), 'DRM by store')
check(drm.rstrip('}').rstrip().endswith('return ""'), 'DRM left blank for other games')
check('static let enabled = MadeiraConfig.flag("MADEIRA_COMPAT_REPORT")' in report, 'off switch MADEIRA_COMPAT_REPORT')

adv = block(lib, '@ViewBuilder private var advancedPage: some View {')
check('if CompatReport.enabled {' in adv and 'UIPasteboard.general.string = CompatReport.text(for: entry)' in adv,
      'the button is on the Advanced page and copies the report')
check('Label("Copied", systemImage: "checkmark")' in adv and 'compatCopied = false' in adv, 'it shows Copied, then goes back')
check('(compat-report)' in adv, 'marker comment (compat-report)')
# (game-actions-advanced) Share Setup ... Reset to Recommended moved to the Advanced page too, after
# Copy Compat Report; Game details ends with Uninstall on its own.
check(adv.index('Copy Compat Report') < adv.index('(game-actions-advanced)') < adv.index('Button("Share Setup"')
      < adv.index('Button("Reset to Recommended"'), 'the setup, help and reset actions follow it on the Advanced page')
for row in ['Button("Share Setup"', 'Button("Apply Shared Setup"', 'Button("Copy Settings"',
            'Button("Reset to Recommended"', 'GameRecommendations.note(recommended']:
    check(row in adv, f'Advanced page has {row}')
body = lib[lib.index('struct LibraryDetail: View {'):]
body = body[body.index('    var body: some View {'):body.index('.navigationTitle(stack == nil ? L("Game details") : entry.title)')]
check(all(r not in body for r in ['Button("Share Setup"', 'ClaudeHelpButton(', 'ShareLogsButton()', 'Button("Reset to Recommended"']),
      'Game details no longer lists them')

check('key: "env.MADEIRA_COMPAT_REPORT"' in catalog, 'the config catalog lists env.MADEIRA_COMPAT_REPORT')
langs = ['de', 'es', 'ko', 'pt-BR', 'ru', 'zh-Hans']
for key in ['Copy Compat Report', 'Copied']:
    check(key in strings and all(l in strings[key]['localizations'] for l in langs), f'"{key}" has all six languages')
foot = [k for k in strings if k.startswith('Copies this device, iOS version, Madeira version')]
check(len(foot) == 1 and foot[0] in adv, 'the footer is translated and used')

if failures:
    print(f'{len(failures)} check(s) failed')
    sys.exit(1)
print('check-compat-report: OK')
