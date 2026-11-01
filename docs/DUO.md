# iPhone Duo

On the iPhone Duo, folding the screen like a laptop splits a library session in
two. The upright half above the fold shows the game, and the half lying flat
becomes a deck for the controls. Held open or closed, and on every other iPhone,
nothing changes. The fold is read in `app/Madeira/DeviceFold.swift`, and the
deck's controller view is in `app/Madeira/FoldDeck.swift`. The hooks are in
`ContentView.swift`: `sessionBody`, `TouchControlsOverlay` and
`ControlsWindow.hitTest`. Two parts at the end apply to every iPhone: moving the
game in portrait with a controller, and switching games.

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
the same rect. Touches there go to the game as before. The game's glow (below)
fills the bars beside it.

The system status bar would sit across the top of the game, so it is hidden while
folded, and its time, network and battery are drawn at the top of the deck
instead (`DeckStatusBar`, `FoldDeck.swift`). The controls window covers the
whole screen above the game's window, so iOS takes the status bar from it
(`ControlsHostingController`, `TouchControlsHost.hidesStatusBar`).
`[fold] status bar on the deck=…` is logged when that changes. Wi-Fi strength
has no public API, so the Wi-Fi mark is always full.

## The deck

The controls window (`ControlsWindow`) owns the whole deck while folded. The deck
has no game under it, so no touch there becomes a mouse event.

The deck is black, with the game glowing through it, the way Netflix lights the
lower screen of a folded Duo (`FoldDeckBackground`, `DeviceFold.swift`). A copy
of the game covers the deck, flipped at the fold like a reflection, with the
game's lower edge on the fold. It is blurred until only its colours are left
and dimmed evenly, a little more down the deck but never to black, so the keys
on it stay the brightest thing there. Its contents sit on top:

- **Touch controls.** The built-in controller layout, while it is untouched, is
  laid out again for the deck, and again for the whole screen when the Duo
  opens (`ControlPresetsModel.relay`), so it keeps its spacing on the smaller
  deck. A layout of the user's own is drawn at the same relative positions it
  has in landscape, shrunk until no two controls overlap (`[fold] deck controls
  fit=…`). Gesture zones scale to the deck too. At the top centre, the status
  bar sits beside a small key that turns the glow off and on.
- **The menu button and the in-game menu** (`LibraryHUD`) stay on the deck, so
  Done, Keyboard, Edit controls and Quit game are within reach without leaning
  over the fold. The starting screen still covers the whole window.
- **With a controller** (or with touch controls hidden), the deck shows
  `FoldDeck` instead of the controls, laid out as Netflix lays out its player on
  the Duo, in three rows:
  - Home; the game now playing (its artwork, its name and the controller), which
    opens the in-game menu; and the glow's key. Home quits the game and goes back
    to the library, the in-game menu's Quit game. It asks first, on the deck
    itself: the large keys become Keep playing and Quit game around the
    question. A system alert would sit across the fold, half out of reach.
  - Three large keys: Keyboard; Menu, the in-game menu, widest in the middle;
    and Touch controls, which brings the touch controls back. With a controller
    connected the controls would not show on the deck, so Aspect & scaling
    takes that place (the performance overlay where the in-game menu has no
    Aspect & scaling, `MADEIRA_SESSION_TOOLS = 0`).
  - Small keys for what changes most in play: Aspect & scaling (one tap to the
    next mode), the performance overlay and Eco mode, lit while on.

  The Menu key replaces the floating menu button, which would sit on Home, so
  `LibraryHUD` leaves it out while `FoldDeck` is shown (`FoldDeckState`). The
  glow's key is the same setting as the one above the touch controls
  (`madeiraFoldGlow` in the app's preferences).

Folded, the deck lies on the table like a keyboard, so its controls are drawn as
physical keys rather than glass. That covers the touch controls, `FoldDeck`'s
keys and the glow's key:
- Each key is a raised cap, lit from above, on a darker skirt.
- The cap sinks onto the skirt while held, and its shadow tightens.
- Coloured buttons such as A/B/X/Y keep their colour.

`glassFace` (`ContentView.swift`) draws the keycap (`FoldKeyFace`) wherever a view
is marked `.foldKeys()`. Outside the folded deck nothing changes.

The copy is a portal (`GameMirror`). UIKit's `_UIPortalView` draws the game's
Metal layer a second time, and SwiftUI's blur softens it. The layer itself cannot
move: it has one parent, and it must stay a window-level view for its presents
to reach the screen (`MetalHostView`). The glow costs one more composite and a
blur of the game per frame, and nothing in the game. If the class is missing on
some future system, the deck stays plain black, and the Mirror button is not
offered. `[fold] deck glow=… portal=…` is logged when the deck appears.

A Madeira Dock session draws the game in the desktop compositor's view
(`Winios.m`), beside `MetalHostView` rather than in it, so there the portal copies
that view, cropped to the desktop (`winios_compositor_mirror_source`). The mirror
checks once a second which of the two is drawing, and logs `[fold] mirror
source=…` when that changes. The compositor's letterbox is clear, so the glow
shows around the desktop too.

Held open or bent upright, with the fold across a portrait window, the library's
large title moves 12 points in from the screen's left edge
(`DeviceFold.portraitFold`, `LibraryTitleText`).

## Portrait with a controller

This part applies to every iPhone. Held upright, a library session fits the game
into a band across the middle of the tall window. With a controller connected, a
swipe up or down in the empty space above or below the game moves it to the top
or the bottom of the screen, inside the safe area, and a swipe the other way
brings it back to the middle. The game slides there at the same size. The choice
is kept (`madeiraPortraitPin` in the app's preferences).

The code is `app/Madeira/PortraitPin.swift`. `MetalBackedView` lays the game out
in the band at the pinned edge instead of its whole bounds, so the presented
layer, the desktop compositor and touch mapping all follow the same rect. A
touch that starts in the empty space while a pin can apply belongs to the swipe
and never reaches the game. Without a controller (but see touch controls below),
in landscape, folded, or when the game fills the height, nothing changes, and
touches in the empty space reach the game as before. Connecting or disconnecting
a controller lays the game out again.

Log tag: `[portrait-pin]`.

## Portrait with touch controls

This part applies to every iPhone. Held upright without a controller, touch
controls used to lie over the game in the middle band, their landscape layout
squeezed into the narrow window until the buttons ran into each other. Now, while
touch controls are on screen, the game moves to the top (as if pinned there), and
the space below it becomes a deck like the folded Duo's (`PortraitDeck`,
`PortraitPin.swift`):
- the controls, the menu button and the in-game menu are drawn there, and the
  controls window takes every touch in it;
- the built-in layout is laid out again for it, as on the fold;
- the game's reflection fills it, and its glow fills the space around the game.

Hiding touch controls, connecting a controller, or a game that fills the height
puts things back as before. A space of less than 160 points is not used. Log tag:
`[portrait-deck]`.

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
