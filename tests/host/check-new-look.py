#!/usr/bin/env python3
"""The new look (Settings › Appearance › New look, NewLook.swift + PadHighlight.swift), on the host.

Cameron, Nov 9: the approved mock-up (Apple + Build Monitor blend) built into the app behind one
switch. Stage 1: the tab bar, the Library (every installed game, last played first), the game
page (Play is the only filled button, Uninstall at the bottom), the starting screen with the
Madeira island and step tiles, and one controller highlight for all of it. Wave 8's store
sidebar is gone; its blue ring (MenuPad) only runs with New look off.
Stage 2: the Stores tab (every store, signed in or not, and its counts), a store's page (the
store's own section, so sign-in, downloads and its game sheets work as before) with the pencil
on its icon (Change icon from Photos or Files, Reset icon), and Pause, Resume, Try again and
Remove (asks first) on the Downloads tab.
Stage 3: Settings (the pages in their groups with coloured icons and the JIT pill; a page is the
same page as before, pushed, with the island behind it and B back) and Search over installed
games, the stores' games you have not installed (opens its store's own sheet), stores and Settings.

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

# 2. The switch.
check('static var allowed: Bool { MadeiraConfig.flag("MADEIRA_NEW_LOOK") }' in look, 'env.MADEIRA_NEW_LOOK = 0 takes it away')
check('UserDefaults.standard.object(forKey: key) as? Bool ?? true' in look, 'on by default')
toggle = re.compile(r'if NewLook\.allowed \{\s*Toggle\("New look", isOn: \$newLookOn\)\s*[\}\n]')
check(len(toggle.findall(library)) == 1 and len(toggle.findall(pages)) == 1,
      'Settings › Appearance › New look, on the long page and the Appearance page')
check('if newLook {\n            newLookBody\n        } else {' in library, 'off, the library is the earlier page with store tabs')
check('static var enabled: Bool { !NewLook.enabled && MadeiraConfig.flag("MADEIRA_MENU_CONTROLLER") }' in menupad,
      'the old blue ring only with New look off')
check('static var enabled: Bool { NewLook.enabled && MadeiraConfig.flag("MADEIRA_NEW_LOOK_PAD") }' in pad,
      'the new highlight only with New look on; env.MADEIRA_NEW_LOOK_PAD = 0 turns it off alone')

# 3. The controller (Cameron's map).
controller = library[library.index('final class LibraryController'):library.index('enum FrontendChoice')]
check('(0x4000, "play")' in controller, 'X is sent as play')
handle = pad[pad.index('    func handle(_ command: String) {'):pad.index('    // MARK: Touch')]
check('case "accept":' in handle and 'action.send((focus, .press))' in handle, 'A selects')
check('case "back":\n            if let back = top.back { back() } else if layers.count == 1 { rootBack?() }' in handle, 'B: back, cancel or stop, whatever the layer says')
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
check('struct NewLookTabBar' not in look and 'case library, stores, downloads, settings, search' in look,
      "tabs: Library, Stores, Downloads, Settings and Search, on Apple's tab bar only (the game page has no copy of it)")
check('cover: false))' in library and 'lookOpenGame(entry)' in library and 'case .game(let id, let tab, let depth):' in library
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
check('if NewLook.enabled { NewLookBackground(startScreen: true) }' in library, 'the island behind it')
check('if NewLook.enabled { newLookLaunch(entry, geometry: geo) } else { launchView(entry, geometry: geo) }' in library,
      'the old screen stays with New look off')
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
check("ownsInput: open || (NewLook.enabled && model.startingScreen)" in library, 'closing the Session menu on it keeps it')

# 6b. Stage 2: Stores, a store's page, its icon, and the Downloads tab's buttons.
steamgames = (app / 'SteamGames.swift').read_text(encoding='utf-8')
# 0045 (Cameron, Nov 9: "Switch to Apple's own tab bar"): a page stack per tab.
check('TabView(selection: lookSelection)' in library and library.count('NavigationStack(path: $') >= 5
      and library.count('.navigationDestination(for: NewLookRoute.self) { lookRoute($0) }') == 5,
      "Apple's tab bar: every tab has its own page stack")
check('Tab(value: NewLookTab.search, role: .search)' in library, "iOS 18: Search is the system's search tab")
check('ContentNavigation(stack: !(library.enabled && library.current == nil && NewLook.allowed && newLookOn))' in (app / 'ContentView.swift').read_text(encoding='utf-8'),
      'the new-look library is not inside a second NavigationStack (it breaks Back)')
check('NewLookStoresPage(open: { storesPath.append(NewLookRoute.store($0)) })' in library and 'case .store(let store):' in library,
      'the Stores tab: the list of stores; a store\'s page is pushed inside the tab')
check('// The store sections as before, until the Stores redesign (stage 2).' not in library, 'the old store sections are gone from the Stores tab')
check('if new == lookTab { lookReselect(new) } else { lookTab = new }' in library
      and 'if !path.wrappedValue.isEmpty { path.wrappedValue = NavigationPath(); return }' in library and 'lookTop[item, default: 0] += 1' in library,
      'tapping the open tab goes back to its first page, then to the top')
for store, section in [('steam', 'SteamGamesSection('), ('epic', 'EpicGamesSection('), ('gog', 'GOGGamesSection('),
                       ('itch', 'ItchGamesSection('), ('ea', 'EAGamesSection(')]:
    check(f'case .{store}: {section}' in look, f'the {store} page is the store\'s own section')
check('.padLayer("store", back: { dismiss() }, page: true)' in look and '"sp-back"' not in look,
      "B on a store's page goes back a page (the system Back button; no home-made one)")
check('static var collapsible: Bool { !NewLook.enabled && ' in steamgames, "a store's page never hides its games under a folded title")
check('else if let pad, PadHighlight.enabled { buttonStyle(PadCardStyle(id: pad, grid: grid)) }' in library
      and '.padItem(id, cornerRadius: grid ? 16 : 12, press: configuration.trigger)' in menupad,
      "the highlight reaches a store's game cards (A = a tap)")
check('else if PadHighlight.enabled { padItem(id, cornerRadius: cornerRadius, press: action) }' in menupad,
      'and the sign-in cards')
for f, store in [('SteamGames', 'steam'), ('EpicGames', 'epic'), ('GOGGames', 'gog'), ('ItchGames', 'itch'), ('EAGames', 'ea')]:
    check(f'.padItem("{store}-not-installed"' in (app / f'{f}.swift').read_text(encoding='utf-8'), f'and {store}\'s Not installed')
check('store-icon-\\(store.rawValue).png' in look and 'kCGImageSourceThumbnailMaxPixelSize: 1024' in look
      and 'width: 256, height: 256' in look, "a store's own icon: the middle square of any picture, 256 x 256, in madeira-art")
check('"ic-photos"' in look and '"ic-files"' in look and '"ic-reset"' in look and '.padLayer("icon", start: "ic-cancel"' in look
      and '.photosPicker(isPresented: $icons.photos' in look and '.fileImporter(isPresented: $icons.files' in look,
      'the pencil: Photos, Files, Reset icon; Cancel first')
check('if icons.has(store) {' in look, 'Reset icon only when the store has its own icon')
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
grid = (app / 'LibraryGridPage.swift').read_text(encoding='utf-8')
check('NewLookSettingsList(enableJIT: enableJIT, open: { settingsPath.append(NewLookRoute.settings($0)) })' in library,
      'the Settings tab is the new-look list of pages')
check('SettingsPagesList(startDock: startDock).scrollContentBackground(.hidden)' not in library, 'the old Settings list is gone from the new look')
check('case .settings(let page):\n            SettingsPageView(page: page, startDock: startDock)' in library,
      'a Settings page is the same page as before, pushed inside its tab (the tab bar stays)')
check('.modifier(NewLookSettingsChrome())' in pages_src and '.padLayer("settings-page", back: { dismiss() }, page: true)' in look,
      'a Settings page: the island behind it, B goes back')
check('NewLookBadge(symbol: page.symbol, color: page.color)' in look and '.padItem("set-" + page.key' in look,
      "Settings rows: the page's coloured icon, and the highlight")
check('NewLookStatusPill(enableJIT: enableJIT)' in look[look.index('struct NewLookSettingsList'):], 'Settings: the JIT pill')
srch = look[look.index('@MainActor enum NewLookSearch'):look.index('// MARK: - Settings')]
for rules in ['SteamGamesRules.items(', 'EpicGamesRules.items(', 'GOGGamesRules.items(', 'ItchGamesRules.items(', 'EAGamesRules.items(']:
    check(rules in srch, f'Search: {rules[:-7]} games you have not installed')
check('where item.installed == nil && item.owned != nil' in srch, 'Search: only owned games that are not installed')
check('L("Installed")' in srch and 'L("In your stores")' in srch and 'L("Stores")' in srch and 'L("Settings")' in srch,
      'Search: Installed, In your stores, Stores, Settings')
check('sheets.epicGame = .init(id: game.key)' in srch and 'sheets.steamGame = .init(id: id)' in srch
      and '@Published var steamGame: Game<Int>?' in grid and '.onReceive(LibraryStoreSheets.shared.$steamGame)' in steamgames,
      "Search: a store game opens its store's page and its own sheet")
check('setting: { searchPath.append(NewLookRoute.settings($0)) }' in library and 'store: { searchPath.append(NewLookRoute.store($0)) }' in library,
      'Search: a store or a Settings page opens inside the Search tab')
check('storeGame: { game in lookPendingGame = game; searchPath.append(NewLookRoute.store(game.store)) }' in library
      and '.task { shown() }' in look and 'asyncAfter' not in srch,
      "Search: a store game's sheet opens once its store's page is up (no timer)")

# 6d. Cameron's Test 2 findings (Nov 9).
check('if let back = top.back { back() } else if layers.count == 1 { rootBack?() }' in pad
      and 'if lookTab == .search { lookPick(lookBefore) }' in library and 'if new == .search { lookBefore = old }' in library,
      'B on Search goes back to the tab it came from')
check('.background(Color.clear.contentShape(Rectangle()).onTapGesture { field = false })' in look
      and '.scrollDismissesKeyboard(.immediately)' in look, 'Search: a tap or a drag puts the keyboard away')
check('.searchable(text: $lookSearch, placement: .navigationBarDrawer(displayMode: .always)' in library and 'content.searchFocused(field)' in look and '"search-field"' in look,
      "Search: Apple's own field; the controller puts the keyboard up from a button")
check('ContentUnavailableView.search(text: query)' in look and look.count('ContentUnavailableView {') == 2,
      "Apple's empty screens: no results, nothing downloading, nothing installed")
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
check('if NewLook.enabled { path.append(page); return }' in library and 'else { path.removeLast() }   // slides back' in library,
      'game pages slide in and out again in the new look')
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
words = ['New look', 'Library', 'Stores', 'Downloads', 'Settings', 'Search', 'Stop', 'Get ready', 'First-time setup',
         'Start Steam', 'Starting %@', 'Open %@', 'Waiting for its window…', 'While playing', 'Uninstall %@', 'Go to Stores',
         '%@ of %@ signed in', '%@ installed · %@ in your library', 'Sign in to see your games', 'Change icon', 'Reset icon',
         'Choose from Photos', 'Choose from Files', 'Remove %@ from Downloads?', 'Keep downloading', 'Pause', 'Resume', 'Try again',
         'Games, stores and settings', 'In your stores', 'Nothing downloading', 'Games you install from a store show up here.',
         'Type a name', "Steam's game list is taking a while.", 'Getting games', 'Steam and Dock',
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
check('let fold = NewLook.enabled && part == .all' in steam_src
      and 'let top = fold ? groups.downloading : groups.downloading + installed' in steam_src
      and steam_src.index('Text("Not installed").font(.headline)') < steam_src.index('NewLookInstalledHeader(id: "steam-installed"')
      and '@AppStorage("madeiraNewLookSteamShowInstalled") private var showInstalled = false' in steam_src,
      'Steam store page: downloading, then Not installed, then Installed (closed at first); the old look is unchanged')
for name, var, key in [('EpicGames', 'epic', 'Epic'), ('GOGGames', 'gog', 'GOG'), ('ItchGames', 'itch', 'Itch'), ('EAGames', 'ea', 'EA')]:
    src = (app / (name + '.swift')).read_text(encoding='utf-8')
    check(f'let top = NewLook.enabled ? mine.filter {{ {var}.downloads[$0.id] != nil }} : mine' in src
          and f'let folded = NewLook.enabled ? mine.filter {{ {var}.downloads[$0.id] == nil }} : []' in src
          and src.index('Text("Not installed").font(.headline)') < src.index(f'NewLookInstalledHeader(id: "{var}-installed"')
          and f'@AppStorage("madeiraNewLook{key}ShowInstalled") private var showInstalled = false' in src
          and 'others.isEmpty && folded.isEmpty && search.isEmpty' in src,
          f'{name}: games to install first, installed folded (closed at first); the old look is unchanged')
fold_view = look.split('struct NewLookInstalledHeader: View {')[1].split('\n}\n')[0]
check('.padItem(id, cornerRadius: 16) { toggle(open) }' in fold_view and 'if let open {' in fold_view
      and '.accessibilityAddTraits(.isHeader)' in fold_view and '[new-look] store page: Installed' in fold_view,
      'Installed title: a button with the highlight when it folds, plain text when it is the only group')

# 8. Markers.
check('[pad-highlight] on' in pad and '[pad-highlight] layer \\(name) opened' in pad, 'log lines (markers)')
check('[new-look] downloads: remove' in look and '[new-look] store icon: ' in look, 'log lines for Remove and a store icon (markers)')

print('check-new-look: ' + ('FAIL' if failures else 'PASS'))
sys.exit(1 if failures else 0)
