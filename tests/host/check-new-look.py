#!/usr/bin/env python3
"""The new look, the app's only look (NewLook.swift + PadHighlight.swift), on the host.

Cameron, Nov 9: the approved mock-up (Apple + Build Monitor blend). The old design is deleted:
no Settings > New look switch, no NewLook.enabled branches, no zoomable grid, no ambient glow.
Three tabs on Apple's tab bar (Library, Stores, Settings), each with its own page stack and its
own search field; Downloads sit under the stores on the Stores page (a % badge on the tab). The
Library (every installed game, last played first), the game page (Play is the only filled
button, Uninstall at the bottom), the starting screen with the Madeira island and step tiles,
a store's page (the store's own section, with its fixed logo), Settings (the pages in their
groups, one neutral icon tile, the JIT pill) and one controller highlight for all of it.

Source checks only (no Swift compiler here); the PC's typecheck and the build compile it.
"""
from pathlib import Path
import json, re, struct, sys

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


look = (app / 'NewLook.swift').read_text(encoding='utf-8')
pad = (app / 'PadHighlight.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
menupad = (app / 'MenuPad.swift').read_text(encoding='utf-8')
pages = (app / 'SettingsPages.swift').read_text(encoding='utf-8')
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
catalog_text = (app / 'ConfigCatalog.generated.swift').read_text(encoding='utf-8')
catalog = json.loads((app / 'Localizable.xcstrings').read_text(encoding='utf-8'))['strings']

# 1. In the app.
for ident, name in [('A1F00A01', 'NewLook.swift'), ('A1F00A02', 'PadHighlight.swift')]:
    check(project.count(f'{ident} /* {name} in Sources */') == 2 and project.count(f'A2{ident[2:]} /* {name} */') == 3,
          f'{name} is in the app target')
check(project.count('B1F00A03 /* MadeiraIsland.png in Resources */') == 2 and project.count('B2F00A03 /* MadeiraIsland.png */') == 3,
      'the island picture is copied into the app')
png = (app / 'MadeiraIsland.png').read_bytes()
check(png[:8] == b'\x89PNG\r\n\x1a\n' and struct.unpack('>II', png[16:24]) == (2000, 1000) and png[25] == 6,
      'the island is the 2000x1000 cut-out with transparency (Cameron: "that\'s perfect")')
check('Bundle.main.url(forResource: "MadeiraIsland", withExtension: "png")' in look, 'the background loads it by that name')
check('LibrarySidebar' not in project and not (app / 'LibrarySidebar.swift').exists(), "Wave 8's store sidebar is gone")
check('struct SettingsSplit' not in pages and 'SettingsSplit(' not in library, "and its iPad Settings split")

# 2. The new look is the only look: no switch, no old design.
swift = {f.name: f.read_text(encoding='utf-8') for f in app.glob('*.swift')}
every = '\n'.join(swift.values())
code = re.sub(r'(?m)^\s*//.*$', '', every)   # comments may still name the old design
check(not re.search(r'NewLook\.(enabled|allowed|key)\b|MADEIRA_NEW_LOOK"|"madeiraNewLook"|madeiraNewLook\b|newLookOn|L\("New look"\)', code),
      'no New look switch or NewLook.enabled/allowed/key branch is left in the app')
check(not any((app / n).exists() for n in ['LibraryGridPage.swift', 'InteractionFrameRate.swift']) and not re.search(r'LibraryGrid\w*|InteractionFrameRate|MenuPadRing|MenuPadCardStyle', code)
      and 'MADEIRA_MENU_CONTROLLER' not in code + catalog_text and 'LibraryGrid' not in project,
      'the zoomable grid, the interaction frame rate, the blue ring and MADEIRA_MENU_CONTROLLER are gone')
check('static var enabled: Bool { MadeiraConfig.flag("MADEIRA_NEW_LOOK_PAD") }' in pad,
      'the highlight is on by default; env.MADEIRA_NEW_LOOK_PAD = 0 turns it off')
check('static var enabled' not in menupad and 'if PadHighlight.enabled { padItem(id, cornerRadius: cornerRadius, press: action) } else { self }' in menupad,
      "menuPad() only forwards to the new highlight (MenuPad's own ring is gone)")
check('func step(_ by: Int) -> NewLookTab' in look and 'all[(index + by + all.count) % all.count]' in look,
      'LB/RB go round the three tabs')

# 3. The controller (Cameron's map).
controller = library[library.index('final class LibraryController'):library.index('enum FrontendChoice')]
check('(0x4000, "play")' in controller, 'X is sent as play')
handle = pad[pad.index('    func handle(_ command: String) {'):pad.index('    // MARK: Touch')]
check('case "accept":' in handle and 'action.send((focus, .press))' in handle, 'A selects')
check('case "back":\n            if let back = top.back { back() }' in handle, 'B: back, cancel or stop, whatever the layer says')
check('case "play":' in handle and 'item.play { action.send((focus, .play)) }' in handle and 'else { top.play?() }' in handle,
      'X: play or install the highlighted game, or the page\'s game')
check('case "add", "search":\n            if onTabPage { search?() }' in handle, 'Y: search (from a tab, or a page pushed in it)')
check('case "previous", "next":' in handle and 'if onTabPage { tabs?(command == "next" ? 1 : -1) }' in handle, 'LB/RB: tabs')
check('case "pageUp", "pageDown":' in handle and 'jump(down: command == "pageDown")' in handle, 'LT/RT: a page up or down')
check('case "menu":' in handle and 'item.menu { show(); action.send((focus, .menu)) }' in handle, 'Menu: the game\'s options')
check('if moves.contains(command), show() { return }' in handle, 'the first press only shows the highlight')
check('!model.menu else { return }' in handle and 'model.current == nil || model.startingScreen' in handle,
      'in a session only the starting screen is Madeira\'s, never under the Session menu')
check('window.addGestureRecognizer(PadTouchWatch { PadHighlight.shared.hide() })' in pad, 'touch hides the highlight')
check('GamepadEventClaim.install(on: window)' in pad, "iOS's own focus never gets the pad")
pop = pad[pad.index('    func pop(_ name: String'):pad.index('    /// A tab became the root page')]
check('layers.remove(at: i)' in pop and 'guard wasTop else {' in pop and 'returnTo' in pop
      and "if let back, items[back]?.layer == top.name { move(to: back, scroll: true) }" in pop,
      'Back restores the highlight; closing a layer under another leaves the top one alone (unless its row is on top again)')

# 4. Sheets trap focus and start on the safe choice.
check('.padLayer("options", start: "op-cancel"' in library or '.padLayer("options", start: "op-cancel"' in look,
      'the cover menu starts on Cancel')
check('.padLayer("sheet", back: { dismiss() }, accept: accept)' in menupad, 'store sheets: B closes, A installs or opens')
check('if command == "accept", let accept = top.accept, !items.values.contains(where: { $0.layer == top.name })' in handle,
      'A on a sheet with nothing to highlight runs its own action')
check('.padLayer("get-help", back: nil)' in (app / 'GetHelpView.swift').read_text(encoding='utf-8'), 'Get Help keeps its own A and B')
check(".filter { $0.value.layer == layer" in pad and "items[$0]?.layer == top.name" in pad, 'the highlight never leaves the top layer')

# 5. The Library and the game page.
check('LibraryReadyGame.all(search: "")' in look and 'static func all(search: String) -> [LibraryReadyGame]' in look,
      'the Library lists every installed game, last played first')
check('struct NewLookTabBar' not in look and 'case library, stores, settings\n' in look
      and not re.search(r'case (downloads|search)\b', look[look.index('enum NewLookTab'):look.index('struct NewLookHints')]),
      "three tabs only: Library, Stores and Settings, on Apple's tab bar (no Downloads or Search tab)")
check('lookOpenGame(entry)' in library and 'case .game(let id, let tab, let depth):' in library
      and 'LibraryDetailNavigation(own: stack == nil, path: $path)' in library,
      "the game page is pushed inside its tab like any iPhone page (system Back, swipe, tab bar stays)")
check("withTransaction(instant) { path.wrappedValue.append(route) }" in library and 'autoPlayIfAsked()' in library
      and 'DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { start() }' not in library,
      'X on a cover: the page opens without the slide and Play starts once it is laid out (no timer)')
detail = library[library.index('extension LibraryDetail {'):library.index('// MARK: - New look: the starting screen')]
play_style = library[library.index('struct LookPlayStyle'):library.index('struct NewLookPadHints')]
check(detail.count('LookPlayStyle(') == 1 and 'NewLookColor.button' not in detail and play_style.count('NewLookColor.button') == 2
      and 'filled: true' not in detail
      and '"gp-play"' in detail, 'Play is the only filled button on the game page')
helpers = detail[detail.index('@ViewBuilder private var lookHelp'):]
check(helpers.index('"gp-help"') < helpers.index('"gp-uninstall"'), 'Uninstall at the bottom')
check('.padLayer("game", start: lookReturn ?? "gp-play"' in library and 'lookReturn = "gp-page-\\(page)"' in library,
      'the game page starts on Play; back from one of its pages, on that page\'s row')

# 6. The starting screen.
start = library[library.index('// MARK: - New look: the starting screen'):]
check('NewLookBackground(startScreen: true)' in library and 'newLookLaunch(entry, geometry: geo)' in library
      and 'launchView(entry' not in library, 'the island behind it; the old starting screen is gone')
for step in ['L("Get ready")', 'L("First-time setup")', 'L("Start Steam")', 'L("Open %@")']:
    check(step in start, f'step tile {step}')
check('fields["launch-client-error"] == "0"' in start, "Steam's step is done once the Dock says the launch was accepted")
check('"ln-stop"' in start and '"ln-help"' in start and 'GetHelpCenter.shared.openOnStartScreen(entry, error: dockStart.failure)' in start,
      'Stop, and Get Help first once the Dock stopped')
check('model.closeForPoolRestart()' in start and 'JITPoolAuto.startHeadline' in start, '"Not enough memory" with Close Madeira (jit-pool-notice-now)')
check('pad.move(toAny:' in start and 'B never stops by itself' in start, 'B moves to Stop; only A on Stop stops')
check('.onChange(of: model.startingScreen) { _, starting in' in library
      and 'LibraryController.shared.configure(enabled: model.enabled, ownsInput: starting)' in library,
      'the starting screen takes the controller until the game shows')
check("ownsInput: open || model.startingScreen" in library, 'closing the Session menu on it keeps it')

# 6b. Stage 2: Stores, a store's page, its icon, and the Downloads tab's buttons.
steamgames = (app / 'SteamGames.swift').read_text(encoding='utf-8')
# 0045 (Cameron, Nov 9: "Switch to Apple's own tab bar"): a page stack per tab; no Search tab.
check('TabView(selection: lookSelection)' in library
      and len(re.findall(r'NavigationStack\(path: \$(library|stores|settings)Path\)', library)) == 3
      and library.count('.navigationDestination(for: NewLookRoute.self) { lookRoute($0) }') == 3,
      "Apple's tab bar: each of the three tabs has its own page stack")
check('role: .search' not in library and 'NewLookTab.search' not in library and 'searchPath' not in library,
      'no Search tab (each tab has its own search field)')
check('ContentNavigation(stack: !(library.enabled && library.current == nil))' in (app / 'ContentView.swift').read_text(encoding='utf-8'),
      'the library is not inside a second NavigationStack (it breaks Back)')
check('NewLookStoresPage(open: { storesPath.append(NewLookRoute.store($0)) }, software: { storesPath.append(NewLookRoute.software) })' in library and 'case .store(let store):' in library,
      'the Stores tab: the list of stores; a store\'s page is pushed inside the tab')
check('if new == lookTab { lookReselect(new) } else { lookTab = new }' in library
      and 'if !path.wrappedValue.isEmpty { path.wrappedValue = NavigationPath(); return }' in library and 'lookTop[item, default: 0] += 1' in library,
      'tapping the open tab goes back to its first page, then to the top')
# Each tab has its search field; results come from NewLookSearchPage in the tab's own scope.
for tab, prompt in [('library', 'Search installed games'), ('stores', 'Search games across stores'), ('settings', 'Search settings')]:
    check(f'.modifier(NewLookSearchField(text: lookText(.{tab}), prompt: L("{prompt}"), field: $lookField))' in library
          and f'lookResults(.{tab})' in library, f'the {tab} tab has its own search field and results')
check('NewLookSearchPage(scope: item == .library ? .library : item == .stores ? .stores : .settings,' in library
      and 'enum NewLookSearchScope { case library, stores, settings }' in look, 'search results: library, stores or settings scope')
check('NewLookDownloadsSection()' in look[look.index('struct NewLookStoresPage'):look.index('struct NewLookInstalledHeader')]
      and 'NewLookDownloadsSection()' not in library and look.count('NewLookDownloadsSection()') == 1,
      'Downloads are a section under the Stores page, not a tab')
check('.badge(lookDownloads.badge.map { Text(verbatim: $0) })' in library and '.badge(item == .stores ? lookDownloads.badge' in library,
      'a % badge on the Stores tab while something downloads')
for store, section in [('steam', 'SteamGamesSection('), ('epic', 'EpicGamesSection('), ('gog', 'GOGGamesSection('),
                       ('itch', 'ItchGamesSection('), ('ea', 'EAGamesSection(')]:
    check(f'case .{store}: {section}' in look, f'the {store} page is the store\'s own section')
check('.padLayer("store", back: { dismiss() }, page: true)' in look and '"sp-back"' not in look,
      "B on a store's page goes back a page (the system Back button; no home-made one)")
check('collapsible' not in steamgames and 'MADEIRA_LIBRARY_COLLAPSE' not in every, "a store's page never hides its games under a folded title")
check('if let pad, PadHighlight.enabled { buttonStyle(PadCardStyle(id: pad, grid: grid)) }' in library
      and '.padItem(id, cornerRadius: grid ? 16 : 12, press: configuration.trigger)' in menupad,
      "the highlight reaches a store's game cards (A = a tap)")
check('if PadHighlight.enabled { padItem(id, cornerRadius: cornerRadius, press: action) } else { self }' in menupad,
      'and the sign-in cards')
for f, store in [('SteamGames', 'steam'), ('EpicGames', 'epic'), ('GOGGames', 'gog'), ('ItchGames', 'itch'), ('EAGames', 'ea')]:
    check(f'.padItem("{store}-not-installed"' in (app / f'{f}.swift').read_text(encoding='utf-8'), f'and {store}\'s Not installed')
# Stores have fixed logos (no icon editor): one asset-catalog set per store, drawn by NewLookStoreIcon.
check(not re.search(r'NewLookStoreIcons|NewLookIconSheet|photosPicker|fileImporter|PhotosUI|store-icon-|"ic-photos"|"ic-files"|"ic-reset"|Reset icon|Change icon|pencil', re.sub(r'(?m)^\s*//.*$', '', look)),
      'no store icon editor (no pencil, Photos or Files picker, Reset icon)')
logos = {'steam': 'StoreSteam', 'epic': 'StoreEpic', 'gog': 'StoreGOG', 'itch': 'StoreItch', 'ea': 'StoreEA'}
for store, asset in logos.items():
    folder = app / 'Assets.xcassets' / f'{asset}.imageset'
    contents = json.loads((folder / 'Contents.json').read_text(encoding='utf-8')) if (folder / 'Contents.json').exists() else {}
    files = [i.get('filename') for i in contents.get('images', []) if i.get('filename')]
    check(files and all((folder / f).is_file() for f in files) and f'case .{store}: return "{asset}"' in look,
          f'{store}: the {asset} logo set exists and NewLookStore.logo names it')
check('case .other: return nil' in look and 'Image(asset).renderingMode(.template)' in look and 'if let asset = store.logo {' in look
      and look.count('NewLookStoreIcon(') >= 5, 'NewLookStoreIcon draws the logo (Other games its letter)')
dl = look[look.index('// MARK: - Downloads'):look.index('// MARK: - Stores')]
for store, pause, resume, remove in [
        ('steam', 'SteamOwnedLibrary.shared.pause(id)', 'SteamOwnedLibrary.shared.install(id)',
         'SteamOwnedLibrary.shared.cancelInstall(id, installed: SteamGamesModel.shared.games.contains { $0.id == id })'),
        ('epic', 'EpicLibrary.shared.pause(row.key)', 'EpicLibrary.shared.install(row.key)', 'EpicLibrary.shared.cancel(row.key)'),
        ('gog', 'GOGLibrary.shared.pause(row.key)', 'GOGLibrary.shared.install(row.key)', 'GOGLibrary.shared.cancel(row.key)'),
        ('itch', 'ItchLibrary.shared.pause(id)', 'ItchLibrary.shared.install(id)', 'ItchLibrary.shared.cancel(id)'),
        ('ea', 'EALibrary.shared.pause(row.key)', 'EALibrary.shared.install(row.key)', 'EALibrary.shared.cancel(row.key)')]:
    check(pause in dl and resume in dl and remove in dl, f'Downloads: Pause, Resume and Remove call {store}\'s own')
check('L("Try again")' in dl and 'L("Resume")' in dl and 'L("Pause")' in dl, 'Downloads: Try again after a failure, Resume when paused, else Pause')
check('.padLayer("remove", start: "rm-keep", back: close)' in dl and 'downloads.confirm = row' in dl,
      'Remove asks first and starts on Keep downloading')
check('NewLookOverlays()' in library, 'the questions sit over every tab')

# 6c. Stage 3: Settings and Search.
pages_src = pages
check('NewLookSettingsList(enableJIT: enableJIT, open: { settingsPath.append(NewLookRoute.settings($0)) })' in library,
      'the Settings tab is the new-look list of pages')
check('SettingsPagesList(startDock: startDock).scrollContentBackground(.hidden)' not in library, 'the old Settings list is gone from the new look')
check('case .settings(let page):\n            SettingsPageView(page: page, startDock: startDock)' in library,
      'a Settings page is the same page as before, pushed inside its tab (the tab bar stays)')
check('.modifier(NewLookSettingsChrome())' in pages_src and '.padLayer("settings-page", back: { dismiss() }, page: true)' in look,
      'a Settings page: the island behind it, B goes back')
check('NewLookPageIcon(symbol: page.symbol, store: page.store)' in look and '.padItem("set-" + page.key' in look,
      "Settings rows: the page's icon (a store's page its logo), and the highlight")
check('var color' not in pages and 'page.color' not in code and 'color:' not in look[look.index('struct NewLookBadge'):look.index('struct NewLookPageIcon')]
      and 'NewLookColor.tile' in look[look.index('struct NewLookBadge'):look.index('struct NewLookPageIcon')]
      and 'static let tile = Color(white: 0.39)' in look,
      'Settings rows use no per-page colour: every icon sits on the one neutral tile')
check('NewLookStatusPill(enableJIT: enableJIT)' in look[look.index('struct NewLookSettingsList'):], 'Settings: the JIT pill')
srch = look[look.index('@MainActor enum NewLookSearch'):look.index('// MARK: - Settings')]
for rules in ['SteamGamesRules.items(', 'EpicGamesRules.items(', 'GOGGamesRules.items(', 'ItchGamesRules.items(', 'EAGamesRules.items(']:
    check(rules in srch, f'Search: {rules[:-7]} games you have not installed')
check('where item.installed == nil && item.owned != nil' in srch, 'Search: only owned games that are not installed')
check('L("Installed")' in srch and 'L("In your stores")' in srch and 'L("Stores")' in srch and 'L("Settings")' in srch,
      'Search: Installed, In your stores, Stores, Settings')
check('sheets.epicGame = .init(id: game.key)' in srch and 'sheets.steamGame = .init(id: id)' in srch
      and '@Published var steamGame: Game<Int>?' in look and '.onReceive(LibraryStoreSheets.shared.$steamGame)' in steamgames,
      "Search: a store game opens its store's page and its own sheet")
check('setting: { settingsPath.append(NewLookRoute.settings($0)) }' in library and 'store: { storesPath.append(NewLookRoute.store($0)) }' in library,
      'Search: a store opens on the Stores stack, a Settings page on the Settings stack (inside the tab it was found in)')
check('storeGame: { game in lookPendingGame = game; storesPath.append(NewLookRoute.store(game.store)) }' in library
      and '.task { shown() }' in look and 'asyncAfter' not in srch,
      "Search: a store game's sheet opens once its store's page is up (no timer)")

# 6d. Cameron's Test 2 findings (Nov 9).
check('enum NewLookCatalog' in look and 'guard scope == .stores, query.count >= 2 else { catalog = .init(); return }' in look
      and 'SteamCatalog.search(query)' in look and 'NewLookCatalog.itch(query)' in look,
      "Search: Steam's and itch.io's catalogs are asked only from the Stores tab's field")
# (Search tab removed: its "B goes back to the tab it came from" and the tap-away keyboard background went with it.)
check('.scrollDismissesKeyboard(.immediately)' in look, 'Search: a drag puts the keyboard away')
check('.searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(prompt))' in library
      and 'content.searchFocused(field)' in look and 'pad.search = { lookField = true }' in library
      and 'lookField = false' in library,
      "Search: Apple's own field on every tab; Y puts the keyboard up in the open tab's field, changing tab puts it away")
check('ContentUnavailableView.search(text: query)' in look and look.count('ContentUnavailableView {') == 1
      and 'if !downloads.rows.isEmpty {' in dl,
      "Apple's empty screens: no results, nothing installed; the Downloads section shows nothing while nothing downloads")
check('.navigationBarTitleDisplayMode(.large)' in library[library.index('struct NewLookTabRoot'):],
      "every tab: Apple's large title")
check('guard pressed.0 == id, last.visible else { return }' in pad and 'if owner == nil || items[id]?.owner == owner' in pad
      and 'PadHighlight.shared.pop(name, token: token)' in pad,
      "a hidden tab's items and pages never take the controller from the open tab")
check('if command == "accept" || command == "menu", onGhost {' in pad and 'UIScreen.main' not in pad.replace('?? UIScreen.main.bounds.size', ''),
      'A on an item that is gone puts the highlight somewhere real first; the window, not the screen, is measured')
check('ForEach(games, id: \\.padID)' in look and 'var padID: String { "g-" + id }' in look
      and 'grids.first(where: { $0.value.ids.contains(focus) })?.key' in pad,
      'Library: the page scrolls with the highlight down the covers')
pill = look[look.index('struct NewLookStatusPill'):]
pill = pill[:pill.index('\n}\n')]
check('.padItem("status", when: !on, capsule: true) { start() }' in pill and pill.count('.padItem(') == 1
      and 'guard !jit.enabled, !starting else { return }' in pill and 'pill(L("Memory+")' in pill,
      'JIT on is not selectable; JIT off starts JIT once (busy while starting); Memory+ is shown, never selectable')
tiles = look[look.index('struct NewLookStatusTiles'):]
tiles = tiles[:tiles.index('private func tile(')]
check('tile(L("JIT")' not in tiles and 'tile(L("Memory+")' not in tiles, 'Settings shows JIT and Memory+ once (the pills), not again in tiles')
check('.padLayer("game-\\(page)", back: { lookBack() }, page: stack != nil)' in library and '.padScrollFollow(reader)\n        .padLayer("game-' in library,
      'game pages: their own layer, following the highlight')
for item in ['gd-resolution', 'gd-aspect', 'gd-metalfx', 'gd-framegen', 'gc-mode', 'gc-opacity', 'gc-size', 'gl-start', 'gl-services',
             'gx-x87', 'gx-large', 'gx-avx', 'gx-cpus', 'gx-gpu', 'gx-vcrt', 'gx-japanese', 'gx-suspend', 'gb-find', 'ga-live', 'ga-reset']:
    check(f'.padItem("{item}"' in library, f'game pages: {item} on the controller')
check('        path.append(page)\n    }' in library and 'else { path.removeLast() }   // slides back' in library,
      'game pages slide in and out again')
check('let loading = all.isEmpty && MadeiraDock.enabled && !ready.steamScanned' in look and '.onAppear { Self.load() }' in look
      and 'SteamGamesModel.shared.$scanned.removeDuplicates()' in look and 'let scanned = SteamGamesModel.shared.scanned' in look
      and 'SteamGamesModel.shared.refresh()' in look and 'if !self.scanned { self.scanned = true }' in steamgames,
      'first open: Loading your games, never "Nothing installed yet" before the stores are read')
# 0050: smoothness (ux-review-0044 #6, #7, #8).
games_cls = look[look.index('@MainActor final class NewLookGames'):look.index('// MARK: - Starting screen')]
check('.receive(on: DispatchQueue.main)' in games_cls and 'let games = LibraryReadyGame.all(search: "")' in games_cls
      and look.count('LibraryReadyGame.all(') == 1 and 'ready.matching(query)' in look,
      'the ready-game list is worked out once per change, not in each page body (review #7)')
check('try? await Task.sleep(for: .seconds(8))' in look and 'id: "lib-retry"' in look
      and '[new-look] library: loading again after a slow read' in look,
      'Loading your games has a time limit and Try again (review #8)')
check(look.count('guard let row = current(row, "') == 3 and 'Date().timeIntervalSince(last.at) < 0.6' in look
      and 'is no longer in the list' in look and 'Remove popup closed' in look,
      'Downloads buttons act on the row as it is now, once per press (review #6)')
check('NewLook.coverWidth(coverWidth * Double(pinch ?? 1), wide: wide)' in look and '.onChanged { value in pinch = value.magnification }' in look
      and '[new-look] cover size' in look and 'Picker("Cover size", selection: Binding(get: { NewLook.coverStep(coverWidth) }' in pages,
      'cover size: a live pinch, or Settings › Appearance › Cover size')
check('if pinch == nil, Date().timeIntervalSince(pinchEnded) > 0.4 { open(game.entry) }' in look, 'a pinch never opens the cover under it')
check('func detail(_ row: Row) -> String?' in look and 'L("about %@ left")' in look and 'downloads.detail(row)' in look,
      'Downloads: "1.2 GB of 13 GB · about 5 min left"')
check('Capsule().strokeBorder(NewLookColor.ring(scheme), lineWidth: 3)' in pad,
      'a capsule item\'s highlight is a capsule')
check('if let back, items[back] == nil { move(to: back, scroll: false); pending = back; return }' in pad
      and 'if id == pending { pending = nil;' in pad and 'register(id, .init(frame: last.frame,' in pad,
      'back from a game\'s page: the highlight returns to its row at once (no touch needed)')
check('.padScrollFollow(reader, toTop: ["gp-play"])' in library and '.id("pad-top")' in library,
      'the highlight on Play scrolls the game page all the way up')
check('!focus.hasPrefix("tab-") { remembered[page] = focus }' in pad and 'private func settle(layer: String, page: String?, at: Int)' in pad,
      'back from Search (or any tab change): the highlight starts on the page, never stuck on a tab button')

# 0041 (Cameron, Nov 9: "make sure things line up", "use all of Apple's stuff", follow the original mock-up).
check('RoundedRectangle(cornerRadius: max(0, cornerRadius - inset), style: .continuous)' in pad and '.padding(inset)' in pad
      and 'var inset: CGFloat = -4' in pad, 'the highlight is concentric with what it is on (around it, on it, or inside a card row)')
check(look.count('cornerRadius: NewLook.cardRadius, inset: 4') >= 3 and 'cornerRadius: NewLook.cardRadius, inset: 4' in library,
      'rows inside cards: the highlight follows the card\'s curve instead of poking out')
check('content.glassEffect(.regular.interactive(), in: Capsule())' in look and 'GlassEffectContainer(spacing: 12)' in look
      and 'accessibilityReduceTransparency' in look, 'iOS 26: the tab bar, Search, Back and hints are Apple\'s Liquid Glass (solid with Reduce Transparency)')
check('.buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(NewLookColor.button)' in library, 'iOS 26: Play is Apple\'s prominent glass button')
check('struct NewLookStatusTiles' in look and 'NewLookStatusTiles()' in look and 'static let newLookGroups' in pages,
      'Settings: the four status tiles and the mock-up\'s short groups')
check('NewLookSection(title: L("Now")) { nowCard(now) }' in look and 'static func steps(_ row: NewLookDownloads.Row) -> [NewLookStep]' in look
      and look.count('phase: d.progress.phase.rawValue') == 5, 'Downloads: the running one big under Now, with its store\'s real steps')
check('var blurb: String' in library and 'lookLabel(L(item.title), item.blurb)' in library, 'game page: a line under each row saying what it does')
check('struct NewLookBanner' in look and 'if picked.isEmpty, let last = all.first, last.entry.lastPlayed != nil' in look
      and '"banner-play"' in look and '"banner-open"' in look and 'LibraryArtwork(entry: game.entry, backdrop: true)' in look,
      'Library: the last-played game in a banner on top (Play, Game page), then the grid')
check('button.sfSymbolsName' in look and '.GCControllerDidBecomeCurrent' in look, 'button hints use the controller in hand\'s own symbols')
check('.system(size:' not in look[look.index('struct NewLookHints'):look.index('// MARK: - Downloads')],
      'hints: text styles, not fixed sizes')

# 7. Words in all six languages.
langs = ['de', 'es', 'ko', 'pt-BR', 'ru', 'zh-Hans']
words = ['Library', 'Stores', 'Downloads', 'Settings', 'Search', 'Stop', 'Get ready', 'First-time setup',
         'Start Steam', 'Starting %@', 'Open %@', 'Waiting for its window…', 'While playing', 'Uninstall %@', 'Go to Stores',
         '%@ installed · %@ in your library', 'Sign in to see your games', 'Search installed games', 'Search games across stores',
         'Search settings', 'Remove %@ from Downloads?', 'Keep downloading', 'Pause', 'Resume', 'Try again',
         'In your stores', 'On Steam', 'On itch.io', 'Steam · Store page', 'itch.io · Store page',
         "Steam's game list is taking a while.", 'Getting games', 'Steam and Dock',
         'Cover size', 'Small', 'Medium', 'Large', 'Loading your games…', '%@ of %@', 'about %@ left',
         'Now', 'Needs attention', 'Free space', 'Games ready', 'Step %@ of %@', 'Check files', 'Download files',
         'Finish installing', 'In progress · %@%%', 'How the game starts.', 'Buttons on the screen while you play.',
         'Download speed %@ %@', 'MB/s', 'KB/s']
missing = [w for w in words if not all(catalog.get(w, {}).get('localizations', {}).get(l, {}).get('stringUnit', {}).get('value') for l in langs)]
check(not missing, 'the new look\'s words are translated' + (f' (missing: {missing})' if missing else ''))

# 0052: Test 6 fixes (lag after many tab switches; Pause looked stuck).
item = pad[pad.index('struct PadItem'):pad.index('struct PadLayerModifier')]
check('@ObservedObject' not in item and '.map { [id] focus, shown in shown && focus == id }.removeDuplicates()) { on = $0 }' in item,
      'each highlight item redraws only when its own highlight changes (not on every move or tab switch)')
check('func isPaused(_ row: Row) -> Bool { flipped[row.id] ?? row.paused }' in look and 'downloads.isPaused(row)' in look
      and 'downloads.shownState(row)' in look and 'stateWatch = Publishers.MergeMany' in look,
      'Downloads: Pause and Resume show at once; store state changes show without waiting for the timer')

# 0053: Test 6 controller (LB/RB stuck over a pushed page; one stick push moved 2-3 rows).
check('private var onTabPage: Bool { layers.dropFirst().allSatisfy(\\.page) }' in pad
      and 'if onTabPage { tabs?(command == "next" ? 1 : -1) }' in pad and 'if onTabPage { search?() }' in pad
      and '.padLayer("store", back: { dismiss() }, page: true)' in look and '.padLayer("settings-page", back: { dismiss() }, page: true)' in look
      and 'page: stack != nil)' in library and '.padLayer("remove", start: "rm-keep", back: close)' in look,
      'LB/RB and Y change tabs over a page pushed in a tab, never under a popup')
check('Int32(value) * sign > (held & mask != 0 ? 10000 : 16000)' in library, 'the stick has an in/out gap (no flicker moving two rows)')

# 0055: Search's not-installed store games show the game's picture.
check('NewLookStoreGameArt(game: game).frame(width: 46, height: 69)' in look
      and 'LibraryCachedArtwork(source: LibraryCoverCache.Source.steam(appID), glyph: nil)' in look
      and 'LibraryCoverCache.Source.store(game.store.rawValue, game.key, game.cover)' in look,
      'Search: a not-installed store game shows its own cover, not the store icon')

# 0056: the Now card shows the download speed at the bottom right, in larger text.
now_card = look.split('private func nowCard(')[1].split('private func list(')[0]
rows_list = look.split('private func list(')[1].split('private func buttons(')[0]
speed_fn = look.split('func speed(_ row: Row)')[1].split('// MARK: Actions')[0]
check('buttons(row, speed: true)' in now_card and 'speed: true' not in rows_list
      and 'if speed, let now = downloads.speed(row) { NewLookDownloadSpeed(number: now.number, unit: now.unit) }' in look,
      'Downloads: the speed is on the Now card only, at the right end of the Pause and Remove row')
check('guard row.active, !row.failed, !isPaused(row), let rate = rates[row.id], rate > 1024 else { return nil }' in speed_fn
      and 'L("MB/s")' in speed_fn and 'L("KB/s")' in speed_fn,
      'Downloads: no speed while paused, failed or before it is known; MB/s, KB/s under 1 MB/s')
speed_view = look.split('struct NewLookDownloadSpeed: View {')[1].split('\n}\n')[0]
check('Text(number).font(.title2.bold()).monospacedDigit()' in speed_view and '.lineLimit(1).minimumScaleFactor(0.6)' in speed_view
      and '.accessibilityElement(children: .ignore)' in speed_view and 'padItem' not in speed_view and 'Button' not in speed_view,
      'Downloads: the speed is larger text, read out as one item, never a button or a highlight stop')

# 0057: store pages list the games to install first; the installed ones fold away under them.
steam_src = (app / 'SteamGames.swift').read_text(encoding='utf-8')
check('let fold = part == .all' in steam_src
      and 'let top = fold ? groups.downloading : groups.downloading + installed' in steam_src
      and steam_src.index('Text("Not installed").font(.headline)') < steam_src.index('NewLookInstalledHeader(id: "steam-installed"')
      and '@AppStorage("madeiraNewLookSteamShowInstalled") private var showInstalled = false' in steam_src,
      'Steam store page: downloading, then Not installed, then Installed (closed at first)')
for name, var, key in [('EpicGames', 'epic', 'Epic'), ('GOGGames', 'gog', 'GOG'), ('ItchGames', 'itch', 'Itch'), ('EAGames', 'ea', 'EA')]:
    src = (app / (name + '.swift')).read_text(encoding='utf-8')
    check(f'let top = mine.filter {{ {var}.downloads[$0.id] != nil }}' in src
          and f'let folded = mine.filter {{ {var}.downloads[$0.id] == nil }}' in src
          and src.index('Text("Not installed").font(.headline)') < src.index(f'NewLookInstalledHeader(id: "{var}-installed"')
          and f'@AppStorage("madeiraNewLook{key}ShowInstalled") private var showInstalled = false' in src
          and 'others.isEmpty && folded.isEmpty && search.isEmpty' in src,
          f'{name}: games to install first, installed folded (closed at first)')
fold_view = look.split('struct NewLookInstalledHeader: View {')[1].split('\n}\n')[0]
check('.padItem(id, cornerRadius: 16) { toggle(open) }' in fold_view and 'if let open {' in fold_view
      and '.accessibilityAddTraits(.isHeader)' in fold_view and '[new-look] store page: Installed' in fold_view,
      'Installed title: a button with the highlight when it folds, plain text when it is the only group')

# 8. Markers.
check('[pad-highlight] on' in pad and '[pad-highlight] layer \\(name) opened' in pad, 'log lines (markers)')
check('[new-look] downloads: remove' in look and '[new-look] store icon' not in look, 'log line for Remove (marker); the store icon editor logs nothing any more')

print('check-new-look: ' + ('FAIL' if failures else 'PASS'))
sys.exit(1 if failures else 0)
