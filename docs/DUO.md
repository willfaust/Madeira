# iPhone Duo

On the iPhone Duo, folding the screen like a laptop splits a library session in
two. The upright half above the fold shows the game, and the half lying flat
becomes a deck for the controls. Held open or closed, and on every other iPhone,
nothing changes. The fold is read in `app/Madeira/DeviceFold.swift`, and the
deck's controller view is in `app/Madeira/FoldDeck.swift`. The hooks are in
`ContentView.swift`: `sessionBody`, `TouchControlsOverlay` and
`ControlsWindow.hitTest`.

## Reading the fold

iOS 27.1 reports the hinge (`onHingeChange`: status and angle) and the fold as a
division region (`GeometryProxy.reservedRegions(kind: .division)`). Both arrive
late. The status turns `partiallyOpen`, and the division active, only once the
hinge is bent well over. So the angle decides first:

- The flattest angle seen stands for open. It starts at 174°, so a launch
  while already bent still works.
- More than 10° of bend from it counts as folded, and less than 5° as open
  again. The gap keeps a Duo held in the hand from flickering between layouts.
- Closed and partially open are taken at their word.

While folded, the division's frame (asked for with `.includeInactive`) splits the
window into the upper half, the fold and the deck. The frame can move a moment
after the last hinge event without the window changing size, so the regions are
read again at 0, 0.3, 0.8 and 1.6 s after each change. A fold that leaves less
than 120 points on either side is not treated as a laptop.

The API exists only in the iOS 27.1 SDK. The reader is compiled behind
`#if canImport(SwiftUI, _version: 8.0.85)` and `#available(iOS 27.1, *)`, so
older SDKs and systems build and run without it.

The `-fold` launch argument stands a 24-point fold across the middle of the
window. That way the layout can be seen in the simulator, whose hinge cannot bend.

Log tag: `[fold]`. These are logged when they change:
- the layout (`[fold] laptop top=… deck=…` or `[fold] off`);
- each new hinge reading (`[fold] hinge open, 150° (24° from flat)`), which gives
  real numbers when a fold is caught too early or too late;
- the window and every division the reader sees (`[fold] window 669x951
  divisions=[0,455 669x40 active]`). This shows why a fold didn't become a layout:
  no division, or one running down a landscape window, with the Duo held on its
  side, where the laptop layout needs a portrait window with the fold across it.

## The upper half: the game

`sessionBody` frames the game view (`MadeiraMetalView`) to the upper half. The
surface layout (`GameSurfaceLayout`, see `GuestDisplay.swift`) then fits the
game into that half with the entry's display mode, and touch mapping follows
the same rect. Touches there go to the game as before.

## The deck

The controls window (`ControlsWindow`) owns the whole deck while folded. The deck
has no game under it, so no touch there becomes a mouse event. Its contents:

- **Touch controls.** The entry's layout is drawn in the deck at the same
  relative positions it has in landscape. A user with no layout yet gets the
  built-in one laid out for the deck. Gesture zones scale to the deck too.
  Under them the deck shows the game as well, dimmed so the controls stay
  readable, the way a video app does on a folded Duo. A small key at the top
  of the deck turns that copy off and on.
- **The menu button and the in-game menu** (`LibraryHUD`) stay on the deck, so
  Done, Keyboard, Edit controls and Quit game are within reach without leaning
  over the fold. The starting screen still covers the whole window.
- **With a controller** (or with touch controls hidden), the deck shows
  `FoldDeck` instead of the controls. It has a live copy of the game, scaled to
  fit, above four buttons:
  - Home quits the game and goes back to the library, the in-game menu's Quit
    game. It asks first, on the deck itself: the copy of the game dims under the
    question and the buttons become Keep playing and Quit game. A system alert
    would sit across the fold, half out of reach. The in-game menu is the menu
    button's, already on the deck;
  - Keyboard shows the keyboard;
  - Touch brings the touch controls back (offered while no controller is
    connected);
  - Mirror turns the copy off. It's the same setting as the key above the
    touch controls (`madeiraFoldMirror` in the app's preferences).

Folded, the deck lies on the table like a keyboard, so its controls are drawn as
physical keys rather than glass. That covers the touch controls, `FoldDeck`'s
buttons and the mirror key:
- Each key is a raised cap, lit from above, on a darker skirt.
- The cap sinks onto the skirt while held, and its shadow tightens.
- Coloured buttons such as A/B/X/Y keep their colour.

`glassFace` (`ContentView.swift`) draws the keycap (`FoldKeyFace`) wherever a view
is marked `.foldKeys()`. Outside the folded deck nothing changes.

The copy is a portal. UIKit's `_UIPortalView` draws the game's Metal layer a
second time. The layer itself cannot move: it has one parent, and it must stay a
window-level view for its presents to reach the screen (`MetalHostView`). The
copy costs one more composite of the game per frame and nothing in the game. If
the class is missing on some future system, the deck shows the controller's
name instead, and the Mirror button is not offered.

## Switching games

This part applies to every iPhone. A process runs one Wine session
(`LibraryModel.sessionsThisRun`, `MADEIRA_ONE_SESSION_PER_RUN`). Before, Play on
a second game could only ask for a restart. The Restart Madeira alert now also
offers **Close and Start *game***, from `SessionSwitch.swift`:

- The held entry is noted, and Madeira closes.
- A notification posted a second later reopens it. If notifications are not
  allowed, Madeira just closes.
- Once the library is up, the entry starts the way a Home Screen shortcut does,
  through `launchLibraryEntry`, so JIT and Steam Cloud checks run as for Play.
- Opening Madeira from the Home Screen within ten minutes also starts it. After
  that, the note is dropped.

Log tag: `[session-switch]`.
