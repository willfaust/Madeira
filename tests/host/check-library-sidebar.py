#!/usr/bin/env python3
"""The library's store sidebar (app/Madeira/LibrarySidebar.swift and Library.swift), on the host.

Source checks: the file is in the app target; the switch MADEIRA_LIBRARY_SIDEBAR picks
the sidebar before the other layouts; the shelves are Ready to play, the stores, then
Other games last; names show only wide and sideways, otherwise the icon rail with ≡;
Windows desktop and Settings sit at the bottom; each store's page is that store's own
section, and the keys the sidebar unfolds are the keys those sections store their folds
under; Group by is hidden with the sidebar; the docs and the log line.
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


side = (app / 'LibrarySidebar.swift').read_text()
library = (app / 'Library.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
docs = (root / 'docs/LIBRARY.md').read_text()

require(project.count('A1000D51 /* LibrarySidebar.swift in Sources */') == 2 and
        project.count('A2000D51 /* LibrarySidebar.swift */') == 3, 'LibrarySidebar.swift is in the app target')
require('static var enabled: Bool { MadeiraConfig.flag("MADEIRA_LIBRARY_SIDEBAR") }' in side, 'the switch, on by default')
require(re.search(r'if sidebarShown \{ sidebarLibrary \}\s*else if LibraryGridArm\.zoomable', library) is not None
        and 'private var sidebarShown: Bool { LibrarySidebar.enabled && sidebarOn }' in library,
        'the sidebar (switch and Appearance setting) comes before the zoomable and original pages')
pages = (app / 'SettingsPages.swift').read_text()
for name, text in [('Appearance page', pages), ('long Settings page', library)]:
    require('@AppStorage(LibrarySidebar.settingKey) private var sidebarOn = true' in text
            and re.search(r'if LibrarySidebar\.enabled \{\s*Toggle\("Store sidebar", isOn: \$sidebarOn\)', text) is not None,
            f'{name}: the Store sidebar toggle, on by default, only while the switch allows it')
require('static let settingKey = "madeiraLibrarySidebar"' in side, 'the setting\'s key')

cases = re.search(r'enum LibraryShelf[^{]*\{\s*case ([^\n]+)', side)
require(cases is not None and [c.strip() for c in cases.group(1).split(',')] == ['ready', 'steam', 'epic', 'gog', 'itch', 'ea', 'other'],
        'shelves in order: Ready to play, Steam, Epic, GOG, itch.io, EA, Other games')
available = side[side.index('static var available'):side.index('static func current')]
require(available.index('[.ready]') < available.index('.steam') < available.index('.epic') < available.index('.gog')
        < available.index('.itch') < available.index('.ea') < available.index('shelves.append(.other)'),
        'Other games is always the last shelf')
require('size.width >= 900 && size.width > size.height' in side, 'names only wide and sideways; the icon rail otherwise')
require('accessibilityLabel("Show store names")' in side and 'drawer = true' in side, '≡ on the rail slides the full list out')
require('L("Windows desktop")' in side and 'L("Settings")' in side, 'Windows desktop and Settings at the bottom of the list')
require('settings: { switchTab(to: 1) }' in library, 'Settings in the sidebar opens the Settings tab')

page = library[library.index('private var sidebarLibrary'):library.index('/// The Desktop button at the top of the page')]
for section in ['SteamGamesSection(', 'EpicGamesSection(', 'GOGGamesSection(', 'ItchGamesSection(', 'EAGamesSection(', 'LibraryReadyGames(']:
    require(section in page, f'a page uses {section[:-1]}')
require('LibrarySheets(' in page, 'game pages and Add a game open from the sidebar page')

# The fold keys the sidebar resets are the ones the sections read.
unfold = side[side.index('func unfold()'):side.index('/// A shelf\'s square icon')]
keys = re.findall(r'forKey: "([^"]+)"', unfold)
sources = ''.join((app / f).read_text() for f in ['SteamGames.swift', 'GOGGames.swift', 'EpicGames.swift', 'ItchGames.swift', 'EAGames.swift', 'Library.swift'])
missing = [k for k in keys if f'@AppStorage("{k}")' not in sources]
require(len(keys) == 11 and not missing, 'the unfolded keys are the sections\' own' + (f' (missing: {missing})' if missing else ''))

require(re.search(r'if !sidebarShown \{\s*Picker\("Group by"', library) is not None, 'Group by is hidden with the sidebar')
require('[library-sidebar] shelf=' in side, 'the log line')
# Cameron, Nov 7 (Wave 8 on iPad): the rail must not start below the bar with a hard edge.
require('.toolbar(sidebarShown && (tab == 0 || (LibrarySidebar.padSettings && SettingsPages.enabled)) ? .hidden : .automatic, for: .navigationBar)' in library
        and 'LibrarySidebarHeader(search: $search, rail: rail, options: { libraryOptions }, add: { browser = true })' in library,
        'the sidebar page (and iPad Settings) hides the bar and draws its buttons beside the sidebar')
require(side.count('.ignoresSafeArea(edges: [.top, .bottom, .leading])') == 2,
        'the sidebar and its slide-out list run the full height of the screen')
require('ToolbarItem(placement: .topBarTrailing) { libraryOptions }' in library, 'one library menu, in the bar or beside the sidebar')
# Cameron, Nov 7 (approved mockups): search in the sidebar, no tab switch, the gear at the bottom left,
# JIT and Memory+ on the folded page, and iPad Settings laid out like the iPad's Settings app.
frame = side[side.index('struct LibrarySidebarFrame'):side.index('struct LibrarySidebarTitle')]
header = side[side.index('struct LibrarySidebarHeader'):side.index('struct LibraryStatusChips')]
require('TextField(L("Search your library"), text: $search)' in frame and '.focused($searchFocused)' in frame
        and 'Image(systemName: "magnifyingglass")' in frame and 'searchFocused = true' in frame,
        'search is at the top of the list, and the rail\'s magnifier opens it ready to type')
require('TextField' not in header and 'if rail { LibraryStatusChips() }' in header,
        'the page has no search bar of its own; JIT and Memory+ show there with the icon rail')
chips = side[side.index('struct LibraryStatusChips'):]
require('chip("JIT", jit' in chips and 'chip("Memory+", memory' in chips and 'on ? LibrarySidebar.green : Color.secondary' in chips
        and ' on"' not in chips, 'the tags read JIT and Memory+, green when on and grey when off')
require(library.count('.toolbar(sidebarShown ? .hidden : .automatic, for: .tabBar)') == 2,
        'the Library and Settings switch is hidden with the sidebar, on both tabs')
require('Button { switchTab(to: 0) } label: { Label(L("Library"), systemImage: "square.grid.2x2") }' in library,
        'iPhone Settings has a way back to the library')
require(re.search(r'if sidebarShown, SettingsPages\.enabled, LibrarySidebar\.padSettings \{\s*// [^\n]*\n\s*SettingsSplit\(', library) is not None
        and 'UIDevice.current.userInterfaceIdiom == .pad' in side,
        'iPad Settings uses the split layout; iPhone keeps its list')
split = pages[pages.index('struct SettingsSplit'):pages.index('/// The credits')]
require('Text(verbatim: "Madeira \\(BuildStamp.text)")' in split and 'LibraryInfoLine.freeText(free)' in split
        and 'TextField(L("Search settings"), text: $search)' in split and 'SettingsPageView(page: current, startDock: startDock, header: true)' in split
        and 'action: library' in split and 'action: enableJIT' in split,
        'iPad Settings: the build, search, JIT, Memory+ and free space, the page with its header, the way back')
blurbs = pages[pages.index('var blurb: String'):pages.index('// A page shows when')]
cases = re.search(r'case ([^\n]+)\n\s*appearance, advanced, logs, credits', pages).group(1).replace(',', ' ').split() + ['appearance', 'advanced', 'logs', 'credits']
require(all(f'case .{c}: return L("' in blurbs for c in cases), 'every Settings page has its line under the title')
require('[settings-split] page=' in split, 'the Settings log line')
require('MADEIRA_LIBRARY_SIDEBAR' in docs and 'Appearance › **Store sidebar**' in docs and '**Ready to play**' in docs, 'docs/LIBRARY.md: the sidebar and its switch')

print('check-library-sidebar: ' + ('FAIL' if failures else 'PASS'))
sys.exit(1 if failures else 0)
