#!/usr/bin/env python3
"""Wine Gecko without Wine's download window (app/Madeira/WineGecko.swift).

Madeira downloads Wine's own x86 Gecko MSI and every session links it into the
prefix's Wine download cache, where appwiz.cpl's install_from_cache finds it.
Checks that the pin (version, file name, SHA-256) is what Wine's appwiz.cpl
expects (against the wine submodule when it is checked out), that the link
lands where appwiz looks ($HOME/.cache/wine, HOME being the prefix), the
wiring (app start, Settings, Xcode project) and the Wi-Fi-only automatic
download.
"""
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
gecko = (app / 'WineGecko.swift').read_text(encoding='utf-8')
bridge = (app / 'WineProcessBridge.m').read_text(encoding='utf-8')
main = (app / 'MadeiraApp.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
pbx = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
failures = 0

# Wine's dlls/appwiz.cpl/addons.c: GECKO_VERSION, and GECKO_ARCH/GECKO_SHA for
# __i386__ and for __x86_64__ (which clang also defines for ARM64EC).
VERSION = '2.47.4'
SHA = {'x86': '26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6',
       'x86_64': 'e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f'}
MSIS = [f'wine-gecko-{VERSION}-{arch}.msi' for arch in SHA]


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


pins = dict(re.findall(r'WineGeckoPin\(arch: "([^"]+)", sha256: "([0-9a-f]{64})"\)', gecko))
check(f'static let version = "{VERSION}"' in gecko and pins == SHA, 'the pins are Wine 2.47.4\'s x86 and x86_64 MSIs and their SHA-256s')
check('var fileName: String { "wine-gecko-\\(Self.version)-\\(arch).msi" }' in gecko
      and 'URL(string: "https://dl.winehq.org/wine/wine-gecko/\\(Self.version)/\\(fileName)")!' in gecko,
      'downloaded from WineHQ over HTTPS, under Wine\'s file names')

addons = root / 'wine/dlls/appwiz.cpl/addons.c'
if addons.exists():
    text = addons.read_text(encoding='utf-8')
    block = text[text.index(f'#define GECKO_VERSION "{VERSION}"'):text.index('#define MONO_VERSION')]
    check(f'#ifdef __i386__\n#define GECKO_ARCH "x86"\n#define GECKO_SHA "{SHA["x86"]}"' in block
          and f'#elif defined(__x86_64__)\n#define GECKO_ARCH "x86_64"\n#define GECKO_SHA "{SHA["x86_64"]}"' in block,
          'the pinned wine\'s appwiz.cpl expects the same files and SHA-256s')
    check('install_from_cache() == INSTALL_NEXT' in text and 'L"\\\\wine"' in text and 'L"\\\\.cache"' in text,
          'appwiz.cpl installs from <WINEHOMEDIR>\\.cache\\wine before it downloads')
else:
    print('SKIP: wine submodule not checked out, appwiz.cpl not compared')

check('WineMonoInstaller.sha256(of: temp) == pin.sha256' in gecko, 'each download is checked before it is kept')
check('allowsExpensiveNetworkAccess = false' in gecko and 'allowsConstrainedNetworkAccess = false' in gecko
      and gecko.index('if automatic {') < gecko.index('allowsExpensiveNetworkAccess = false'),
      'the automatic download is Wi-Fi only (no cellular, no Low Data Mode)')
check('"wine-gecko-removed"' in gecko and '!UserDefaults.standard.bool(forKey: "wine-gecko-removed")' in gecko,
      'after Remove it is not downloaded again on its own')
check('isExcludedFromBackup = true' in gecko, 'kept out of backups')

fn = bridge[bridge.index('static void madeira_link_wine_gecko('):]
fn = fn[:fn.index('\n}\n')]
check(all(f'@"{m}"' in fn for m in MSIS) and '@"WineGecko"' in fn and '@".cache/wine"' in fn, 'sessions link both MSIs into <prefix>/.cache/wine')
check('!S_ISLNK(st.st_mode)' in fn and 'removeItemAtPath:dst' in fn, 'a real file there is kept; a stale link is removed')
check('setenv("HOME", g_prefix_path, 1);' in bridge, 'HOME (Wine\'s WINEHOMEDIR) is the prefix')
check('madeira_link_wine_mono(fm, prefix, bundlePath);\n            madeira_link_wine_gecko(fm, prefix);' in bridge,
      'linked every session, next to Wine Mono')
check('WineGeckoModel.shared.installAutomatically()' in main, 'the app starts the automatic download')
check('WineGeckoSettingsSection()' in library, 'Settings shows Web pages in programs')
check(pbx.count('/* WineGecko.swift in Sources */') == 2 and pbx.count('/* WineGecko.swift */ = {isa = PBXFileReference') == 1,
      'WineGecko.swift is in the Xcode project and its Sources phase')

if failures:
    print(f'{failures} check(s) failed')
    sys.exit(1)
print('PASS: Wine Gecko comes from Madeira, not from Wine\'s download window')
