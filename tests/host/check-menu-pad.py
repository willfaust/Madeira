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


# Wave 12, Settings: the ring inside the row; the keyboard only from a tap or View.
settings = (app / 'SettingsPages.swift').read_text()
require('RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(LibrarySidebar.blue, lineWidth: 3)' in settings
        and 'Rectangle().strokeBorder(LibrarySidebar.blue, lineWidth: 3)\n' not in settings, 'Settings: the ring inside the row')
require('if focused, MenuPad.enabled, pad.ring, !searchAsked {' in settings and 'if command == "search" { searchAsked = true; searchFocused = true; return }' in settings,
        'Settings: no keyboard from the controller, View opens search')
require('[settings-split] search kept closed' in settings, 'logged (marker)')

print('check-menu-pad: ' + ('FAIL' if failures else 'PASS'))
sys.exit(1 if failures else 0)
