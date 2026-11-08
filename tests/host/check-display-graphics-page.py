#!/usr/bin/env python3
"""Settings: Display and Graphics are one page (display-graphics).

The Settings tab's "Running games" group had a Graphics row (Direct3D and Vulkan
pickers) and a Display row (one toggle). They are one row now, "Display and
Graphics": the Graphics section first, then Display in its own section. Each part
keeps its own switch, so the row shows when either part would. The long page that
search shows keeps both sections, so searching "display" or "graphics" still works.
"""
from pathlib import Path
import json, re, sys

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
pages = (app / 'SettingsPages.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
failures = 0


def check(ok, label):
    global failures
    print(('PASS: ' if ok else 'FAIL: ') + label)
    failures += 0 if ok else 1


cases = re.search(r'enum Page: Hashable, CaseIterable \{\s*case ([^\n]+\n[^\n]+)', pages).group(1)
check('displayGraphics' in cases and not re.search(r'\bgraphics\b|\bdisplay\b', cases),
      'one page case, no separate graphics or display page')
check('case .displayGraphics: return "Display and Graphics"' in pages, 'row title is "Display and Graphics"')
check('("Running games", [.displayGraphics, .memory, .pointer])' in pages, 'Running games: one row, then Memory and Pointer')
check('case .displayGraphics: return GraphicsSettings.shown || LibraryView.runtimeSettingsShown' in pages,
      'row shows when either part would')
body = pages[pages.index('case .displayGraphics:\n'):]
g, d = body.find('GraphicsSettings(refresh: refresh)'), body.find('DisplayRateSettings()')
check(0 <= g < d, 'page: Graphics pickers first, then Display')
check('if GraphicsSettings.shown { GraphicsSettings' in body and 'if LibraryView.runtimeSettingsShown { DisplayRateSettings() }' in body,
      'each part keeps its own switch')
check('(display-graphics)' in pages, 'tree marker (display-graphics)')
check('} header: { Text("Display") }' in library and '} header: { Text("Graphics") }' in library,
      'each part keeps its own section header')
check('settingsShow("display", "refresh"' in library and 'settingsShow("graphics", "Direct3D"' in library,
      'search still finds both sections')

catalog = json.loads((app / 'Localizable.xcstrings').read_text(encoding='utf-8'))['strings']
for key in ('Display', 'Graphics'):
    check(len(catalog.get(key, {}).get('localizations', {})) == 6, f'"{key}" header keeps its 6 translations')
footer = [k for k in catalog if k.startswith('Every other option Madeira reads from madeira.cfg.')]
check(len(footer) == 1 and 'Settings › Display and Graphics.' in footer[0]
      and len(catalog[footer[0]]['localizations']) == 6, 'All settings footer names the new page, 6 translations')
check(not any(re.search(r'Settings › (Graphics|Display(?! and Graphics))', k) for k in catalog), 'no catalog text names the old pages')

print('FAIL' if failures else 'OK')
sys.exit(1 if failures else 0)
