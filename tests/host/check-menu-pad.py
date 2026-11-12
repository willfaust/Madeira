#!/usr/bin/env python3
"""A controller in Madeira's own menus (MenuPad.swift + PadHighlight.swift), on the host.

Source checks: the files are in the app target; LibraryController sends the commands (L1/R1 as
previous/next, L2/R2 as pageUp/pageDown, View as search), repeats a held direction, logs each
controller once, and GamepadInput hands it the triggers and the name; every store's cards,
sign-in card and game sheet are reachable by the new highlight; the docs and the log lines.
The highlight's movement rule (PadHighlight.nearest) is mirrored in Python.
Nov 9 (new look, Cameron): the new look is the only look. MenuPad.swift keeps only the plumbing
(no-focus lists, the sheet layer, the card style); its blue ring, MADEIRA_MENU_CONTROLLER and
the old Game details ring are gone. The highlight itself is checked by check-new-look.py.
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
highlight = (app / 'PadHighlight.swift').read_text()
look = (app / 'NewLook.swift').read_text()
library = (app / 'Library.swift').read_text()
pages = (app / 'SettingsPages.swift').read_text()
gamepad = (app / 'GamepadInput.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
docs = (root / 'docs/LIBRARY.md').read_text()

require(project.count('A1000D52 /* MenuPad.swift in Sources */') == 2 and project.count('A2000D52 /* MenuPad.swift */') == 3,
        'MenuPad.swift is in the app target')
require(project.count('A1F00A02 /* PadHighlight.swift in Sources */') == 2, 'PadHighlight.swift is in the app target')
require('MADEIRA_MENU_CONTROLLER' not in pad + library + (app / 'ConfigCatalog.generated.swift').read_text() + docs
        and 'static var enabled' not in pad, 'the ring and its MADEIRA_MENU_CONTROLLER switch are gone (the highlight has env.MADEIRA_NEW_LOOK_PAD)')

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
require('.padItem("og-" + game.id, cornerRadius: 16, grid: "other") { open(game.entry) }' in look, 'Other games covers take the ring')
require('if let pad, PadHighlight.enabled { buttonStyle(PadCardStyle(id: pad, grid: grid)) }' in library
        and 'struct PadCardStyle: PrimitiveButtonStyle' in pad, 'the card style wraps the library card style')

require('PadTouchWatch' in highlight and 'cancelsTouchesInView = false' in highlight and 'state = .failed' in highlight
        and 'window.addGestureRecognizer(PadTouchWatch { PadHighlight.shared.hide() })' in highlight,
        'touch hides the highlight without taking the touch')
require('GamepadEventClaim.install(on: window)' in highlight
        and '.modifier(ClaimGamepadEvents())' in pad[pad.index('struct MenuPadSheet'):]
        and library[library.index('struct LibrarySheets'):library.index('struct ExecutableBrowser')].count('.modifier(ClaimGamepadEvents())') >= 1
        and '.modifier(ClaimGamepadEvents())' in library[library.index('private func lookRoute'):],
        "Wave 9: the system's own focus never gets the pad (window, game page, browser and store sheets claim it)")
require('[menu-pad] connected <controller>' in docs, 'docs/LIBRARY.md: the controller log line')


# PadHighlight.nearest and the grid rule, mirrored (the Swift is the rule checked below).
def gap(a0, a1, b0, b1):
    return b0 - a1 if a1 < b0 else a0 - b1 if b1 < a0 else 0


def nearest(f, direction, frames, skip=(), focus=None):
    x0, y0, w0, h0 = f
    best = None
    for key, (fx, fy, fw, fh) in frames.items():
        if key in skip or key == focus:
            continue
        if direction == 'down':
            if not fy >= y0 + h0 - 4: continue
            ahead, side = fy - (y0 + h0), gap(fx, fx + fw, x0, x0 + w0)
        elif direction == 'up':
            if not fy + fh <= y0 + 4: continue
            ahead, side = y0 - (fy + fh), gap(fx, fx + fw, x0, x0 + w0)
        elif direction == 'right':
            if not fx >= x0 + w0 - 4: continue
            ahead, side = fx - (x0 + w0), gap(fy, fy + fh, y0, y0 + h0)
        else:
            if not fx + fw <= x0 + 4: continue
            ahead, side = x0 - (fx + fw), gap(fy, fy + fh, y0, y0 + h0)
        if direction in ('left', 'right') and side > 0: continue
        score = max(0, ahead) + side * 3
        if best is None or score < best[1]:
            best = (key, score)
    return best and best[0]


def grid_next(index, count, columns, direction):
    target = None
    if direction == 'left' and index % columns > 0: target = index - 1
    if direction == 'right' and index % columns < columns - 1 and index + 1 < count: target = index + 1
    if direction == 'up' and index >= columns: target = index - columns
    if direction == 'down':
        if index + columns < count: target = index + columns
        elif index // columns < (count - 1) // columns: target = count - 1
    return target


# Wave 10: iPadOS walked a Form with the controller through its own focus (a page opened by itself).
# The game's pages (Controller binds, Gyro aim & turbo, ...) are Forms: their lists take no system
# focus while a controller is connected, and the probe holds the system focus off the rows.
require('list.allowsFocus = false; list.selectionFollowsFocus = false' in pad, 'the lists take no system focus')
require('!GCController.controllers().isEmpty' in pad and 'func menuPadNoSystemFocus()' in pad, 'only while a controller is connected')
detail = library[library.index('struct LibraryDetail: View'):library.index("struct BCDGameValues")]
require(detail.count('.menuPadNoSystemFocus()') >= 1 and '.padLayer("game-\\(page)"' in detail,
        "the game's pages (Controller binds and Gyro aim & turbo among them) take no system focus and are their own layer")
require('if let list = view as? UICollectionView' in pad, "the list is found from inside a row (Wave 11's search missed it)")
require('if context.previouslyFocusedItem === self, holding { return false }' in pad and 'system.requestFocusUpdate(to: self)' in pad
        and 'UIFocusSystem.didUpdateNotification' in pad, 'the system focus is held off the rows while the highlight shows')
require('[menu-pad] system focus held off the rows while the highlight shows' in pad
        and '[menu-pad] game details list takes no system focus' in pad, 'logged (markers)')
require('PadHighlight.enabled && PadHighlight.shared.shown' in pad, 'the probe only holds the focus while the highlight shows')

grid = {f'{r}{c}': (c * 180, r * 280, 164, 260) for r in range(6) for c in range(4)}
grid['signin'] = (0, -120, 700, 80)
require(nearest(grid['00'], 'right', grid, focus='00') == '01' and nearest(grid['03'], 'right', grid, focus='03', skip=('signin',)) is None,
        'right: the next cover; none past the row')
require(nearest(grid['00'], 'left', grid, focus='00') is None, 'left from the first column: none')
require(nearest(grid['12'], 'down', grid, focus='12') == '22' and nearest(grid['12'], 'up', grid, focus='12') == '02', 'up and down keep the column')
require(nearest(grid['02'], 'up', grid, focus='02') == 'signin', 'up from the top row: the sign-in card above')
covers = [f'{r}{c}' for r in range(6) for c in range(4)]
require(nearest(grid['02'], 'up', grid, focus='02', skip=covers) == 'signin', 'out of a grid: the nearest item that is not one of its covers')
require(grid_next(5, 22, 4, 'left') == 4 and grid_next(4, 22, 4, 'left') is None and grid_next(3, 22, 4, 'right') is None
        and grid_next(21, 22, 4, 'right') is None, 'in a grid: left and right stay in the row')
require(grid_next(1, 22, 4, 'up') is None and grid_next(5, 22, 4, 'up') == 1 and grid_next(5, 22, 4, 'down') == 9,
        'in a grid: up and down keep the column; up from the top row leaves the grid')
require(grid_next(18, 22, 4, 'down') == 21 and grid_next(21, 22, 4, 'down') is None, 'a short last row: down goes to the last cover')
rule = highlight[highlight.index('func nearest(from: CGRect'):highlight.index('private func gap(')]
require('let score = max(0, ahead) + side * 3' in rule and 'if direction == "left" || direction == "right", side > 0 { continue }' in rule
        and 'guard f.minY >= from.maxY - 4 else { continue }; ahead = f.minY - from.maxY' in rule
        and 'case "left": if index % columns > 0 { target = index - 1 }' in highlight
        and 'else if index / columns < (grid.ids.count - 1) / columns { target = grid.ids.count - 1 }' in highlight,
        'the Swift rule is the one checked here')

# Cameron, Nov 7 ("Yes, instant"): a store's Show uninstalled changes at once.
for store in ['EAGames', 'EpicGames', 'GOGGames', 'ItchGames', 'SteamGames']:
    require('withTransaction(instant) { showUninstalled.toggle() }' in (app / f'{store}.swift').read_text(), f'{store}: Show uninstalled at once')

# The game page is Madeira's own page with the highlight (no system Form on the main page, no ring of its own).
body = detail[detail.index('    var body: some View {'):]
main = body[:body.index('.navigationDestination(for: Page.self)')]
require('Form {' not in main and 'newLookPage' in main and 'MenuPad.shared.ring' not in library and 'MenuPadColor' not in library,
        "the main page is Madeira's own, no system Form and no blue ring")
require('case epic, ea' in detail and 'case .epic:' in detail and 'entry.epicAppName != nil ? [.epic]' in detail, 'Epic and EA have pages')

print('check-menu-pad: ' + ('FAIL' if failures else 'PASS'))
sys.exit(1 if failures else 0)
