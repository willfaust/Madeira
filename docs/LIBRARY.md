# Library front end

Madeira starts in a game library. The original diagnostic screen (the
"developer interface") is still there: **Settings › Interface › Use developer
interface** switches to it, and its **Use New Interface** button switches back.
Either change applies at the next start (close Madeira in the app switcher and
open it again).

The code is `app/Madeira/Library.swift` and `app/Madeira/GuestDisplay.swift`
(the virtual monitor and its layout), plus the wiring in `ContentView.swift`
(`launchLibraryEntry`, `runWineFullSequence(profile:)`, `sessionBody`, the
library HUD inside `TouchControlsOverlay`, and `MetalBackedView`'s layout and
touch mapping).

## Adding games

Copy a game's whole folder into **Madeira › wine › drive_c** with the Files app,
tap **+** and choose its `.exe`. Only x86 and x64 PE executables inside drive_c
can be added; the library stores the path relative to drive_c, so a changed
app container path does not break entries. Adding an entry installs nothing.

The library reads the executable's PE imports (and those of the DLLs next to
it, plus bounded scans for dynamically loaded renderer DLL names) to show a
graphics-API badge, and measures the install folder's size. The badge names an
API only when exactly one is found: it describes what the files import, not
which renderer a game picks at run time.

Library data is written atomically to `Documents/madeira-library.json`
(version 1); covers chosen from Files are stored as thumbnails in
`Documents/madeira-art/`. A library file that cannot be read, or that has a
newer version, is left untouched and cannot be overwritten from the UI.
Removing an entry never removes the game's files or saves.

## Library screen

- Layouts: cards, compact cards, list and compact list (one short row per
  game). Sort by last played, name, date added or folder size. Search by title.
- Sections, as in the fork's library: when Madeira Dock is available,
  **Steam** (the Steam games being downloaded and the games Steam has
  installed, with their count; a **Sign in to Steam** card when signed out),
  its **Not installed** group (the account's other games, with their count),
  then **Other games** (the games you added; **+** in the navigation bar adds one). Tapping
  **Steam** or **Other games** collapses it; **Not installed** folds on its
  own, open by default; each state is remembered. Search, the layout and, for
  installed games, Sort by apply to every section. Pull down to read the
  Steam install records and the account's library again. Without Madeira
  Dock the games you added are one grid.
- Grid cards: a game that is not installed shows its artwork darkened, with a
  download glyph on a soft circle of blur. Every grid card throws ambient
  light on the page around it, like an LED strip behind a TV: its artwork's own
  colours, with arcs of the ring brightening and falling into shadow and the
  colours travelling around it as if a film were playing (fainter and less vivid
  for a game that is not installed; held still with Reduce Motion). Pressing a
  card shrinks its artwork, and its light draws in with crisp rays and goes out
  behind it like a spotlight's aperture closing; on release the artwork springs
  back and the light opens again slowly. The width a row of cards leaves goes
  into the gaps between them, so each card's light keeps to its own space.
- **Desktop** opens the Wine desktop (explorer and services in a virtual
  desktop) with its own profile; its Resolution is the desktop's size.
- The build label (`MadeiraBuild` in Info.plist, else the bundle version) is
  shown in Settings (Ready to play) and in the developer interface's status row.
- **Settings**: JIT and memory status, Enable JIT, JIT method and setup
  (StikDebug or the built-in helper), extended logging, pointer
  mode (Absolute, Relative or Touch) and touch sensitivity, **Display** (hold
  the display at its maximum rate, off by default), **Memory & sync** (swap tier
  Off/1/2/4 GB, off by default; sync engine, Fastsync by default), the interface
  switch and **Credits** (the last section). Display applies from the next session or FPS limit change; Memory &
  sync after a restart. They write `env.MADEIRA_PROMOTE`, `swap-mb`,
  `inproc-sync` and `env.MADEIRA_FASTSYNC` in `Documents/madeira.cfg`, keeping
  every other line. With neither sync key set the engine is fastsync
  (`madeira_cfg_sync_engine` in `build/madeira_cfg.h`); `inproc-sync = 1` selects
  madsync.

## Game details

Tapping a game opens its details page; it stays up until the session's
starting screen takes over (or an error is shown). A profile holds:

- title and cover image;
- **Resolution**: the size of the Windows screen (the virtual monitor) the game
  renders for: 640×480 to 2560×1440, plus **Screen shape**, this device's own
  aspect ratio at 720 lines (for example 1560×720 on a 19.5:9 phone), so a game
  fills the screen without bars. It is exported as the session default
  (`MADEIRA_SCREEN_W/H`, `MADEIRA_SCREEN_SRC=knob`), which win32u reports for
  the session. New entries use 1024×768, the size main uses for every launch;
- **Aspect & scaling**: how that screen is shown. **Fit** letterboxes it,
  **Fill** covers the screen and crops, **Stretch** fills it exactly, **Aspect**
  letterboxes the shape the game actually draws (its back buffer) and **Fill
  height** keeps that shape at full height. Touches are mapped through the same
  rectangle, so input lines up in every mode;
- FPS limit: 60, the display maximum or uncapped (the same presentation
  pacing modes as the FPS pill in the developer interface), and 30 when DXMT
  has its 30 FPS cap (willfaust/dxmt#1; DXMT without it would present mode 3
  uncapped, so the choice is hidden and a saved 30 runs as 60);
- reduced-precision x87: off by default, as in FEX; only an explicit choice
  exports `FEX_X87REDUCEDPRECISION=1`;
- **CPU cores reported** (Automatic, 1, 2, 4 or 6) and **D3D9 anisotropic
  filtering** (Application default, up to 1×, 2×, 4× or 8×): only a choice
  other than the default exports `MADEIRA_CPU_COUNT` (wine) or
  `DXMT_D9_ANISO_LIMIT` (DXMT); the defaults export nothing. The library
  exports no other engine switch;
- launch arguments (double-quoted tokens, at most 64 and 4 KB in total; not
  for Steam games, which Madeira Dock starts with Steam's own launch option),
  in their own section with chips for common flags (`-dx11`, `-dx12`, `-dx10`,
  `-dx9`, `-windowed`, `-fullscreen`, `-nosplash`; the renderer flags exclude
  each other, as do the window flags) and the command line the next start runs;
- performance overlay, live logs and touch controls for the session, with the
  controls' **opacity** and overall **size**. The touch layout itself is saved
  per game from the in-game editor.

A game you added starts directly. A Steam game's page (`docs/STEAM_LIBRARY.md`)
adds a **Steam** section under the library details: **Start with** Madeira
Dock (the default) or **The game** (its own program without Steam, from Steam's
launch configuration or chosen under **Program**), Dock's per-launch pool
choice, **One-time installs**, updates, **Repair
installed files**, App ID, free space and **Uninstall**; its **Executable**
section shows the install folder, and it has no **Remove from library** (the
entry goes with **Uninstall**).

## Sessions

Play applies the profile and runs the same `runWineFullSequence` as the
developer interface's buttons. The game is shown full screen in either
orientation. A starting screen with the game's cover stays until the first
frames arrive (Metal presents or a desktop surface); after 30 seconds it offers
**Show game view**. A Madeira Dock start keeps it, with the Dock's status,
until the game's own window is shown, and adds **Show desktop**
(`docs/MADEIRA_DOCK.md`, "Starting screen"). A row of round glyph-only buttons (their words are
VoiceOver labels) holds **Show live log**, which shows the most recent log lines.

The small menu button (drag to move; it fades after three seconds) opens the
in-game menu:

1. touch controls on/off, their **Controller layout** (the built-in Xbox
   controller, the user's custom layouts, **Create new layout**; remembered per
   game), their **Opacity** and **Size**, **Edit controls**
   (the existing editor) and the **Keyboard** (its own key window, with an
   Esc/Ctrl/Shift/Alt/Tab/Enter/arrow row; modifiers latch);
2. the FPS limit, **Aspect & scaling**, and the mouse and pointer settings;
3. the performance overlay and its fields (FPS, average frame time, memory
   footprint, battery);
4. **Quit game** in red. Quit asks the program to close with Alt+F4 through
   the normal input queue, so it can save; the session ends when it exits.

Changes made in the menu (FPS limit, Aspect & scaling, controls, overlay) are
saved to the game's profile.

**Pointer modes.** Absolute drags the pointer like a trackpad, Relative sends
finger movement as mouse movement (mouse-look), and **Touch** clicks where the
finger is: tap to click, hold or move to drag, a two- or three-finger tap for a
right or middle click, a two-finger drag to scroll. Touch works in direct and
desktop sessions.

When the session ends Madeira returns to the library, restores the touch layout
it had before, and hides the ended session's surfaces. If the session ended by
itself and the program Madeira launched exited with a Windows error status
(for example `0xC0000005`, memory access violation), a message says so. The
status comes from one weak hook in ntdll's common exit wrapper
(`wine_launched_process_did_exit` in `build/ntdll-unix/server_ios.c`), called
only for the session's initial process, the one the app handed to
`__wine_main`; helpers and processes the program starts are never reported.
The hook takes one integer, does not allocate and does not log; the app keeps
only the last error status. No program names are involved.

One Wine session runs per app run: a second one cannot start in the same
process (the wineserver's permanent objects from the first session remain and
the registry initialisation aborts). The library asks to restart Madeira
instead.

## First-run setup

The code is `app/Madeira/Onboarding.swift`. It uses `JITCoordinator` for the
JIT method and validated pairing-file import, `OnDevicePairing` for on-device
pairing (iOS 27, `docs/JIT.md`), Steam sign-in
(`docs/STEAM_SIGNIN.md`) through `SteamSignInModel`/`SteamSignInView` (the
token stays in sign-in's Keychain store), and Madeira Dock
(`docs/MADEIRA_DOCK.md`) through
`MadeiraDockModel.prepareClient()`/`MadeiraDockView`.

**First-run setup.** On a new install the library opens a full-screen setup
once: welcome, **Set up JIT**, **Sign in to Steam**, **Prepare Madeira Dock**
(Valve's client components, about 73 MB, only when Dock is available), done.
The JIT page offers three ways in, **On-device** (iOS 27 and later),
**On-device with pairing file** and **StikDebug**, or **I'll do this later**.
Each way opens numbered steps that tick off as they are done, with **Back to
options**. A completed pairing or a valid pairing-file import selects Built-in
StikJIT; it does not enable JIT yet. Steam and Dock steps have **Set up later**, and the welcome
page has **Skip setup**. Finishing or skipping stores
`madeiraOnboardingDone` in the app's UserDefaults, which iOS removes with the
app. The JIT page is always available; Steam pages follow their feature
switches. Setup never opens over a running session.

Setup starts no Wine session and allocates no JIT pool. It stores the selected
JIT method and may store a validated pairing file (paired on the device or
imported) in the Keychain (docs/JIT.md); the component download runs Dock's own
verified download without Wine. It changes no engine switch or launch
configuration.

**Settings › JIT** and **Settings › Steam** both show **Run setup again**.
Settings › Steam also shows the signed-in account with **Sign out of Steam**
(or **Sign in to Steam**), **Madeira Dock** (Dock's sheet, with the last Dock
result under it). A game started from the Dock sheet here runs as a library
session: full-screen view, starting screen, in-game menu, and the
one-session-per-run rule. That session is not added to the library.

**Steam games in the library** (`app/Madeira/SteamGames.swift`). When Madeira
Dock is available, the library shows a **Steam** section above **Other
games**, the games you added. It lists the games Steam has installed in the
prefix, exactly as Dock's own discovery finds them (`appmanifest_<appid>.acf`
in `C:\Program Files (x86)\Steam\steamapps` and the other C: libraries its
`libraryfolders.vdf` lists), and, once you are signed in, under **Not
installed**, the account's owned games that are not installed yet, which are
installed from their download sheet (`docs/STEAM_LIBRARY.md`); a game being
downloaded moves up to the installed games. The section follows the library's
search and layout and collapses like Other games. Artwork comes from Steam's
public store CDN.
An installed game opens its **Game details** page (above): the game is a
library entry with its own settings, listed only in the Steam section, and its
**Play** goes through Dock's launch path with the entry as its launch profile,
as a library session. When a download finishes, the sheet's button reads
**Open** and opens that page. Play starts only a game Steam marks fully
installed (and not being downloaded), with Valve's client components present
and a Steam sign-in. Reading install records never
writes Steam files; only the downloads and **Uninstall** of `docs/STEAM_LIBRARY.md`
do, and only in Madeira Dock's own library folder. Controller focus does not
reach the section yet.

Log tags: `[onboarding]` (`shown reason=… steps=…`, `step=…`, `done`,
`skipped`), `[steam-games]` (counts and App IDs), `[library-sections]`
(`native-steam=… sections=… collapse=…`, flags only) and the library and download
tags of `docs/STEAM_LIBRARY.md`. No account name, token or path is logged.

## Controllers

Player 1's controller navigates the library through `GamepadInput`: D-pad or
left stick moves the focus, A opens and plays, B goes back, Y adds a game and
the shoulder buttons switch between Library and Settings. In a session,
Back+Start opens the in-game menu and B closes it. While the library or its
menu owns input, the game sees a connected pad at rest.

## Switches

`env.NAME = 0` in `Documents/madeira.cfg` (or `NAME=0` in `madeira-env.txt`):

| Switch | Default | `0` means |
| --- | --- | --- |
| `MADEIRA_FRONTEND_DEFAULT_NEW` | on | the developer interface is the default |
| `MADEIRA_FRONTEND` | unset | `env.MADEIRA_FRONTEND = 0/1` picks the interface when nothing was chosen in the app |
| `MADEIRA_FRONTEND_CONTROLLER` | on | no controller navigation |
| `MADEIRA_ONE_SESSION_PER_RUN` | on | a second session is attempted anyway |
| `MADEIRA_EXIT_REPORT` | on | no message when a session ends by itself |
| `MADEIRA_LIBRARY_HIDE_ENDED_DESKTOP` | on | the ended desktop's surface is left as it was |
| `MADEIRA_BUILD_LABEL` | on | no build label (the `[build]` log line stays) |
| `MADEIRA_UI_LOG_IDLE` | on | the log view keeps parsing while hidden |
| `MADEIRA_LOG_VIA_STDERR` | on | Swift log lines use their own file handle |
| `MADEIRA_RUNTIME_SETTINGS` | on | no Display and Memory & sync sections in Settings |
| `MADEIRA_SESSION_TOOLS` | on | no Aspect & scaling in the in-game menu, and a session does not save it |
| `MADEIRA_SCREEN_SHAPE_RESOLUTION` | on | no Screen shape resolution choice |
| `MADEIRA_FRONTEND_KEYBOARD` | on | Keyboard opens the game view's own keyboard instead of the key window |
| `MADEIRA_ONBOARDING` | on | first-run setup never opens, and Settings › JIT/Steam have no **Run setup again** |
| `MADEIRA_LIBRARY_COLLAPSE` | on | the **Steam** and **Other games** titles do not collapse (**Not installed** still folds) |
| `MADEIRA_LIBRARY_AMBIENT` | on | no ambient light around the library's grid cards |

Opt-in (`env.NAME = 1`), off by default:

| Switch | `1` means |
| --- | --- |
| `MADEIRA_PROMOTE` | the display link also holds the panel at its maximum rate in the 60 FPS cap (Settings › Display) |
| `MADEIRA_DEVICE_STATS` | a `[device-load]` line (thermal state, low power, screen capture) every 10 s while Wine runs |

Log tags: `[frontend]`, `[display]`, `[display-shape]`, `[frontend-pointer]`, `[launch-view]`, `[startup-log]`, `[exit-report]`,
`[session-once]`, `[library-surface]`, `[library-metadata]`, `[onboarding]`,
`[frontend-controller]`, `[frontend-keyboard]`, `[device-load]`, `[promote]`.

## Tests

`tests/host/check-frontend.py` (profiles incl. resolution and scaling,
the engine switches a profile exports, the 30 FPS fallback, the display layout
math, controller commands, the exit hook, and the presence of the details and
in-game menu options), `tests/host/check-runtime-settings.py`
(`MadeiraConfig.set` and the Settings defaults) and
`tests/host/check-library-api.py` (renderer detection and the badge).
`tests/host/check-onboarding.py` covers first-run setup: the JIT choices,
pairing import, pages with and without Dock, the done key, the
`MADEIRA_ONBOARDING` switch, and the wiring (no Wine session, no pool or
engine switch; JIT, sign-in and Dock through their public pieces).
`tests/host/check-steam-games.py` covers the library's Steam section: Dock's
discovery on a synthetic drive_c laid out as Steam writes it, the merge of
installed and owned games, the section, status, card pill, search, Play and
artwork rules, the program an installed game's pills describe, the groups of the
library's sections and their Sort by order, and that Play uses only Dock's launch
path. `tests/host/check-library-sections.py` covers the library page's
sections (order, texts, collapsing, search, layout, pull to refresh).
`tests/host/check-steam-library.py`
covers the owned library and downloads (`docs/STEAM_LIBRARY.md`).
