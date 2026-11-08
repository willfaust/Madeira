#!/usr/bin/env python3
"""A controller in Madeira's own menus (app/Madeira/MenuPad.swift), on the host.

Source checks: the file is in the app target; LibraryController sends the new commands
(L1/R1 as previous/next, L2/R2 as pageUp/pageDown, View as search), repeats a held
direction, logs each controller once, and GamepadInput hands it the triggers and the
name; every store's cards, sign-in card and game sheet are reachable; the sidebar draws
the ring on its rows and rail; the library's page reports frames and scrolls to the ring;
B on a game page does not also move the ring; the switch, the docs and the log lines.
The ring's movement rule (MenuPad.nearest) is mirrored in Python and run on a grid.
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


pad = (app / 'MenuPad.swift').read_text()
library = (app / 'Library.swift').read_text()
side = (app / 'LibrarySidebar.swift').read_text()
pages = (app / 'SettingsPages.swift').read_text()
gamepad = (app / 'GamepadInput.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
docs = (root / 'docs/LIBRARY.md').read_text()

require(project.count('A1000D52 /* MenuPad.swift in Sources */') == 2 and project.count('A2000D52 /* MenuPad.swift */') == 3,
        'MenuPad.swift is in the app target')
require('static var enabled: Bool { MadeiraConfig.flag("MADEIRA_MENU_CONTROLLER") }' in pad, 'the switch, on by default')

controller = library[library.index('final class LibraryController'):library.index('enum FrontendChoice')]
for mask, name in [('0x100', 'previous'), ('0x200', 'next'), ('0x10000', 'pageUp'), ('0x20000', 'pageDown'), ('0x20', 'search'),
                   ('0x1000', 'accept'), ('0x2000', 'back'), ('0x10', 'menu'), ('0x8000', 'add')]:
    require(f'({mask}, "{name}")' in controller, f'{name} is sent for {mask}')
require('if lt > 128 { buttons |= 0x10000 }; if rt > 128 { buttons |= 0x20000 }' in controller, 'the triggers count past half way')
require('repeatAt = now.addingTimeInterval(0.35)' in controller and 'pressed |= direction; repeatAt = now.addingTimeInterval(0.1)' in controller,
        'a held direction repeats after 0.35 s, then every 0.1 s')
require('fputs("[menu-pad] connected \\(newName)\\n", stderr)' in controller and '!named.contains(name)' in controller,
        'each controller is logged once by name')
require('lt: state.left_trigger, rt: state.right_trigger' in gamepad and 'name: pad.controller?.vendorName' in gamepad,
        'GamepadInput hands over the triggers and the controller\'s name')
require('if !own, buttons & 0x30 == 0x30, pressed & 0x30 != 0 { command = "menu" }' in controller,
        'in a game only Back+Start reaches Madeira; the game keeps the pad')

for store, key in [('Steam', 'steam'), ('Epic', 'epic'), ('GOG', 'gog'), ('Itch', 'itch'), ('EA', 'ea')]:
    text = (app / f'{store}Games.swift').read_text()
    require(f'.libraryCardButtonStyle(grid: !list, pad: "{key}:\\(item.id)")' in text, f'{store}: covers take the ring')
    require(f'.menuPad("signin:{key}"' in text, f'{store}: the sign-in card takes the ring')
    require('.menuPadSheet { primaryPress(item)?() }' in text and 'private func primaryPress(' in text,
            f'{store}: A and B on the game sheet')
require('.libraryCardButtonStyle(grid: true, pad: "ready:\\(game.id)")' in side, 'Ready to play covers take the ring')
require('.libraryCardButtonStyle(grid: !list, pad: "entry:" + entry.id.uuidString)' in library, 'Other games covers take the ring')
require('if let pad, MenuPad.enabled { buttonStyle(MenuPadCardStyle(id: pad, grid: grid)) }' in library, 'the card style wraps the old one')

require(side.count('.overlay { ring(MenuPad.side(shelf)') == 2 and side.count('ring(MenuPad.desktopRow') == 1
        and side.count('ring(MenuPad.settingsRow') == 1 and 'pad: MenuPad.desktopRow' in side and 'pad: MenuPad.settingsRow' in side
        and '.overlay { ring(id, radius: 10) }' in side, 'the ring on the list rows and the rail icons')
require('.onReceive(pad.search)' in side, 'View opens the search field')
page = library[library.index('private var sidebarLibrary'):library.index('/// The Desktop button at the top of the page')]
require('.coordinateSpace(name: MenuPadSpace.name)' in page and '.onPreferenceChange(MenuPadFrames.self)' in page
        and 'reader.scrollTo(id, anchor: .center)' in page, 'the page reports where items are and keeps the ring on screen')
require('if MenuPad.enabled { padCommand(command); return }' in page and 'MenuPad.shared.sheets == 0' in page
        and 'Date() >= MenuPad.shared.quietUntil' in page, 'presses go to the ring unless a sheet or a closing page has them')
require('.onChange(of: selected == nil)' in page, 'B closing a game page does not also move the ring')
for command in ['"up", "down"', '"pageUp", "pageDown"', '"left"', '"right"', '"accept"', '"back"', '"previous", "next"', '"add"', '"menu"', '"search"']:
    require(f'case {command}:' in page, f'padCommand handles {command}')
require('.toolbar(sidebarShown' in library and 'MenuPad.shared.show(); switchTab(to: 0)' in library, 'Menu in Settings goes back to the library')
require('pad.sheets == 0' in pages and 'if selected && pad.ring {' in pages and '.menuPadSheet()' in pages,
        'iPad Settings: up and down go through the pages; its sheets close with B')
require('MenuPadTouchWatch' in pad and 'cancelsTouchesInView = false' in pad and 'state = .failed' in pad,
        'touch hides the ring without taking the touch')
require('GamepadEventClaim.install(on: window)' in pad and 'MenuPad.shared.claimControllerEvents()' in page
        and '.modifier(ClaimGamepadEvents())' in pad[pad.index('struct MenuPadSheet'):]
        and library[library.index('struct LibrarySheets'):library.index('struct ExecutableBrowser')].count('.modifier(ClaimGamepadEvents())') == 2,
        'Wave 9: the system\'s own focus never gets the pad (window, game page, browser and store sheets claim it)')
require('[menu-pad] store=' in page and '[menu-pad] open ' in page, 'the log lines')
require('MADEIRA_MENU_CONTROLLER' in docs and '[menu-pad] connected <controller>' in docs, 'docs/LIBRARY.md')


# MenuPad.nearest, mirrored.
def nearest(f, direction, frames, jump=None):
    x, y = f[0] + f[2] / 2, f[1] + f[3] / 2
    best = None
    for key, (fx, fy, fw, fh) in frames.items():
        dx, dy = fx + fw / 2 - x, fy + fh / 2 - y
        if jump is not None:
            if not (dy > 1 if direction == 'down' else dy < -1):
                continue
            score = abs(abs(dy) - jump) + abs(dx) * 0.5
        elif direction == 'down':
            if not (dy > 1 and fy >= y): continue
            score = dy + abs(dx) * 2
        elif direction == 'up':
            if not (dy < -1 and fy + fh <= y): continue
            score = -dy + abs(dx) * 2
        elif direction == 'right':
            if not (dx > 1 and fx >= x and abs(dy) < max(f[3], fh)): continue
            score = dx + abs(dy) * 3
        else:
            if not (dx < -1 and fx + fw <= x and abs(dy) < max(f[3], fh)): continue
            score = -dx + abs(dy) * 3
        if best is None or score < best[1]:
            best = (key, score)
    return best and best[0]


# Wave 10: one A on a cover opened Game details, then the system's focus opened Controls and
# Gyro aim & turbo by itself. The details' lists take no system focus with a controller, and a
# page that opens while the ring shows is undone.
require('list.allowsFocus = false; list.selectionFollowsFocus = false' in pad, 'the lists take no system focus')
require('!GCController.controllers().isEmpty' in pad and 'func menuPadNoSystemFocus()' in pad, 'only while a controller is connected')
require('UIFocusSystem.didUpdateNotification' in pad and '[menu-pad] system focus moved to' in pad, 'the system focus is logged')
detail = library[library.index('struct LibraryDetail: View'):library.index("struct BCDGameValues")]
require(detail.count('.menuPadNoSystemFocus()') >= 2, 'Game details and its pages (Controller binds and Gyro aim & turbo among them)')
require('MenuPad.shared.ring, new.count > old.count' in detail and 'withTransaction(instant) { path = old }' in detail,
        'a page the controller did not open is undone')
require('[menu-pad] details: stopped a page the controller did not open' in detail, 'and logged (marker)')

grid = {f'{r}{c}': (c * 180, r * 280, 164, 260) for r in range(6) for c in range(4)}
grid['signin'] = (0, -120, 700, 80)
require(nearest(grid['00'], 'right', grid) == '01' and nearest(grid['03'], 'right', grid) is None, 'right: the next cover; none past the row')
require(nearest(grid['00'], 'left', grid) is None, 'left from the first column: none (the sidebar takes it)')
require(nearest(grid['12'], 'down', grid) == '22' and nearest(grid['12'], 'up', grid) == '02', 'up and down keep the column')
require(nearest(grid['02'], 'up', grid) == 'signin', 'up from the top row: the sign-in card above')
require(nearest(grid['01'], 'down', grid, jump=600) == '21', 'a page down jumps about a screen, same column')
src = pad[pad.index('static func nearest'):pad.index('/// The item to ring when the page is entered')]
require('score = dy + abs(dx) * 2' in src and 'score = dx + abs(dy) * 3' in src and 'score = abs(abs(dy) - jump) + abs(dx) * 0.5' in src,
        'the Swift rule is the one checked here')

# Cameron, Nov 7 ("Yes, instant"): the ≡ list, search, folding sections, Game details' pages and
# the old store tabs change at once.
side = (app / 'LibrarySidebar.swift').read_text()
require('private var animation: Animation? { nil }' in side and 'asyncAfter(deadline: .now() + 0.3) { searchFocused' not in side,
        'the ≡ list and search open at once')
require('withTransaction(instant) { path.append(page) }' in detail and 'NavigationLink(value:' not in detail
        and 'case binds, assist' in detail and 'NavigationLink("Gyro aim' not in detail, "Game details' pages open at once")
require('withTransaction(instant) { collapsed.wrappedValue.toggle() }' in library
        and 'withTransaction(instant) { selection = tab.rawValue }' in library, 'sections fold and store tabs switch at once')
for store in ['EAGames', 'EpicGames', 'GOGGames', 'ItchGames', 'SteamGames']:
    require('withTransaction(instant) { showUninstalled.toggle() }' in (app / f'{store}.swift').read_text(), f'{store}: Show uninstalled at once')

# Cameron, Wave 11: in Game details A played the game from any row and the iPad's focus could
# not get back to Play. The page has its own ring: Play, the switches, each page's row.
detail = library[library.index('struct LibraryDetail: View'):library.index("struct BCDGameValues")]
require('["play", "fps", "toggle:performance", "toggle:touch"] + pageGroups' in detail, 'the ring goes Play, FPS, switches, rows')
require('case "play": start()' in detail and 'padOpened = true' in detail and 'if padOpened { padOpened = false; return }' in detail,
        'A plays only on Play, and opens a row it is on')
require('padMove(command == "up" ? -1 : 1, reader: reader)' in detail and 'reader.scrollTo(next, anchor: .center)' in detail,
        'up and down move the ring and keep it on screen')
require('[menu-pad] details: A on' in detail, 'logged (marker)')
require('if let list = view as? UICollectionView' in pad, "the list is found from inside a row (Wave 11's search missed it)")

# Wave 12: the cells took the system focus anyway (blue Uninstall under the ring on Advanced),
# and the rings were cut off and of different shapes.
require('if context.previouslyFocusedItem === self, holding { return false }' in pad and 'system.requestFocusUpdate(to: self)' in pad,
        'the system focus is held off the rows while the ring shows')
require('[menu-pad] system focus held off the rows while the ring shows' in pad, 'logged (marker)')
require('RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LibrarySidebar.blue, lineWidth: 3)' in detail
        and '}.padding(4)' in detail, 'rows: a rounded ring inset in the row')
require('RoundedRectangle(cornerRadius: 18)' in library, "Play's ring follows Play's shape")

# Cameron, Nov 7 (mockups, "Go for it"): Game details is Madeira's own page like the library:
# no system Form on the main page, Uninstall and the share buttons on the ring, Epic and EA
# store sections on their own pages.
body = detail[detail.index('    var body: some View {'):]
main = body[:body.index('.navigationDestination(for: Page.self)')]
require('Form {' not in main and 'ScrollView {' in main, "the main page is Madeira's own, no system Form")
require('+ (steamUninstallable != nil ? ["uninstall"] : [])' in detail and '"share:' not in detail,
        'Uninstall is on the ring (the share actions are on the Advanced page, game-actions-advanced)')
require('case "fps": entry.fpsMode = FPSChoice.next(after: entry.fpsMode)' in detail and 'static func next(after current: Int)' in library,
        'A steps the FPS limit')
require('case epic, ea' in detail and 'case .epic:' in detail and 'entry.epicAppName != nil ? [.epic]' in detail, 'Epic and EA have pages')
require('Game details is Madeira\'s own page' in detail, 'marker comment')

# Wave 12, Settings: the ring inside the row; the keyboard only from a tap or View.
settings = (app / 'SettingsPages.swift').read_text()
require('RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(LibrarySidebar.blue, lineWidth: 3)' in settings
        and 'Rectangle().strokeBorder(LibrarySidebar.blue, lineWidth: 3)\n' not in settings, 'Settings: the ring inside the row')
require('if focused, MenuPad.enabled, pad.ring, !searchAsked {' in settings and 'if command == "search" { searchAsked = true; searchFocused = true; return }' in settings,
        'Settings: no keyboard from the controller, View opens search')
require('[settings-split] search kept closed' in settings, 'logged (marker)')

print('check-menu-pad: ' + ('FAIL' if failures else 'PASS'))
sys.exit(1 if failures else 0)
