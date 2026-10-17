# Zoomable library grid (pinch to zoom)

The card and compact layouts of the library are one `UICollectionView` page
that can be pinched between column counts, Photos style. The list layouts, and
the original SwiftUI grid, are untouched.

## Settings

Two rows in Settings > Appearance:

- **New library grid** (`madeiraLibraryNewGrid`, off by default). Off: the
  original SwiftUI grid, its original glow and its original library writes run
  as before. On: the UIKit grid with pinch zoom, the Metal glow and the
  new-grid-only work (background library writer, touch frame-rate request, the
  Steam install snapshot below). `env.MADEIRA_LIBRARY_AMBIENT=0` in madeira.cfg
  still turns the glow off.
- **Zoom haptics** (`madeiraLibraryZoomHaptics`, on by default; hidden when the
  grid is off). Gates only the zoom's own haptics: a light click per level step
  and one heavy click at the rubber band's limit.

Two stored values belong to the new grid. `madeiraLibraryGridPosition` is the
pinched size (a position on the levels, -1 for none). `madeiraSteamInstalledSnapshot.v1`
is the last scan of Steam's install records, written and read only while the new
grid is on, so the first page after a launch is complete; the next scan
confirms it. Turning the grid off leaves both values unused.

The layout menu has no card sizes while the grid is on (one Cards entry; the
pinched size is kept). The card size has a non-gesture control: the grid exposes
an adjustable "Card size" element (VoiceOver, Switch Control and Voice Control
step it one level, without animation).

### Changes that apply with the setting off

A few small changes are not gated, because they do not change the original
grid's behaviour: the Direct3D and DirectDraw pills read "DX12" ... "DX8" and
"DDraw" (`LibraryRendererBadge.display`); `LibraryModel.drive` keeps the resolved
drive_c once the folder exists; `MadeiraConfig.all()` is cached and read again
when madeira.cfg's modification time or size changes (or Madeira writes it); and
`InteractionFrameRateInstaller`, a zero-size background view, installs nothing
while the setting is off.

## Design

- **One page, one scroll view.** The Desktop button, section headers, notices,
  empty states and grids are items of one collection view whose layout is a pure
  function (`LibraryGridLayoutModel`) of the page model, the width and the level.
  The page model (`LibraryGridPageModel`) is built from the same rules the
  SwiftUI page uses (`SteamGamesRules.items/groups/sorted`,
  `LibraryGrouping.groups`, `SteamGamesSection.shown/hasInstalled`); its
  arrangement is restated in `LibraryGridPageModel.build`, because the original
  views are left as they were. `tests/host/check-library-zoom.py` checks that
  the new page keeps calling the same rules.
- **Levels** (`LibraryGridLevels`): the column counts whose card width lies in
  [72, 220] pt at the page's width, at most five, thinned evenly. The stored size
  is a position on that range (0 = biggest cards; `madeiraLibraryGridPosition`),
  so a rotation or an iPad window resize maps to the nearest level. With no
  stored position the level nearest 154 pt (Cards) or 110 pt (Compact cards) is
  used; choosing Cards or Compact cards in the original layout menu resets the
  stored position to none. A pinch that lands stores the position and moves the
  stored layout to the nearer of Cards and Compact.
- **Geometry.** The cards and fixed 20 pt column gaps fill the page less its 16 pt
  padding exactly at every level; rows stay 18 pt apart; the 1100 pt page cap
  stays.
- **Cells.** Card cells are drawn UIKit cells (`LibraryGridCardCell`): a cover
  (`LibraryGridZoomCover`, the same view the zoom's stage uses, so the two cannot
  differ), a label drawn by the function that measures it (`LibraryCardLabel`),
  the press and the controller focus ring. Headers, notices and the Desktop
  button are hosted SwiftUI. A tap opens from the collection view's selection:
  a library card opens the library's current entry; a Steam card opens its
  details or the download sheet.
- **Sheets and refreshes.** What `SteamGamesSection` and `LibraryGroupedGames` own
  on the SwiftUI page (the download sheet, the sign-in sheet, the Steam alert,
  the refresh when the library appears) is owned by `LibraryGridPage`; Game
  details and Add executable are one shared modifier (`LibrarySheets`).
- **Covers** (`LibraryCoverCache`): a synchronous, size-keyed cache. A lookup
  returns the best resident bitmap for that game at once, the exact size replaces
  it in place; misses fetch the same candidate URLs as the SwiftUI cards, are
  downsampled with ImageIO off the main thread and kept on disk
  (`Caches/madeira-covers/`, capped at 300 MB, least recently used removed first).
  A not-downloaded game's cover carries the blur spot (`LibraryCoverSpot`), baked
  once at the widest bucket and kept as its own disk copy beside the plain one;
  every bucket after that downsamples the baked copy, so a zoom or a re-decode
  does not bake again.
  A chosen cover file is keyed by name and modification time, and falls back to
  the store match's art when it cannot be read. The grid cards, the zoom's stage
  and the glow all read it. Covers a screen or two ahead of the scroll are
  requested at idle. A memory warning, or a game starting, gives back the glow's
  textures; a game starting also frees the decoded bitmaps.
- **Measured label bands.** Each card's label height (title 1-2 lines, pills on one
  or two rows, played line) is measured per level from the fonts the card uses;
  a row takes its tallest card. Bands are memoised by the label's shape (its
  played-line presence included) and width, and measured off the main thread
  ahead of a zoom.
- **The title's size follows the level.** A card's title is 12 pt on a card 77 pt wide
  or less, 15 pt on one 160 pt wide or more, a straight line between, in half points
  (a phone: about 15, 13 and 12 pt at 2, 3 and 4 across), then scaled by the text size.
  It is chosen from the level's own card width, so the level's layout, its bands and
  its drawn labels agree, and the zoom blends levels as it does any other band
  difference. The title is measured and drawn by the same TextKit layout, so the
  lines counted are the lines drawn.
- **The glow.** One Metal layer behind the cells (`LibraryGridGlow`,
  `AmbientGlow.metal`), drawn in the page's coordinates at 30 fps. The light is
  cut out of each card's rectangle (no shine-through behind a cover that is not
  opaque for a moment). Its blur is a floating-point gaussian on a buffer wider than
  the glow's frame, so the light dies away by itself; it idles at a steady 30 fps,
  follows its cards while a zoom fades it out, and is redrawn in the same layout
  pass as any update that moves cards.
- **Data.** The page is rebuilt when the library or Steam's models publish, never
  under a finger or a coast (the newest data is applied when the scroll ends) and
  never during a zoom (after the landing). The account's cached library and
  playtime are read at launch, and the last scan of Steam's install records is
  kept (`SteamGamesModel`), so the first page is complete: its pills, sizes and
  played lines are all there, and the fresh scan only confirms them.
- **Updates keep what you look at.** When data that really is new arrives (a first
  metadata scan, a finished download, a sign-in) and changes heights above the
  viewport, the update moves the offset by the same amount in the same pass
  without animation (`LibraryGridHostController.apply`, the anchor): the first
  card on screen stays where it is. At the top of the page the page stays at the
  top. A card's label reserves no empty rows for data that has not arrived, as
  in the original cards.

## The zoom

Pure model (Foundation/CoreGraphics only, `LibraryGridZoomModel.swift`,
`LibraryGridZoomScene.swift`): `GridZoomTransition` (level coordinate, rubber
band, spring), `GridZoomFades` + `GridZoomBlend` + `GridZoomLag` (one shared fade
rate that follows the pinch speed; one blend at a time; pictures the pinch has
moved past are gone within a bound), `GridZoomScene` (each level's real layout on
one lattice: leading, trailing or centre), `GridZoomGeometry` (landing offset),
`GridZoomFeel` (speed limit, catch-up, rubber-band spring, centre zone),
`GridZoomCentre` (the line a pinch starts on, the 2-step chain, the click decider).
Where the pinch starts decides its line for the whole gesture: left, right, or the
centre (the middle 26 percent of the width), which steps through same-parity
levels so columns arrive and leave in pairs.

Host side (`LibraryGridZoom.swift`):

1. The pinch pauses the scroll view's `panGestureRecognizer` (never
   `isScrollEnabled`), restored at the landing.
2. Per frame only the stage's own views move, inside a `CATransaction` with
   actions disabled; the collection view lays out only at begin and landing.
3. The real `contentOffset` follows the zoom every frame (large title, edge blur,
   refresh control and the scroll indicator read the real scroll view), clamped to
   the blended page's range; near an end the pinched card drifts.
4. One blend at a time: no snap, no opacity dip (outgoing covers stay opaque
   beneath the incoming).
5. Cells that exist only at an intermediate or new level take their row's
   in-flight position and fade like the rest.
6. Every block is placed by one cumulative rule at the same blend, so no two
   blocks overlap at any blend (checked in `check-library-zoom.py`). The stage is
   inserted below UIKit's scroll-edge view. Every page element is a stand-in for
   the zoom, and every real cell, including ones UIKit realises mid-zoom, stays
   hidden until the landing.
7. The page's vertical motion is driven by the same spring and fades as the cards;
   the landing waits for all of them.
8. Labels are drawn images at every level (`LibraryCardLabel.draw`, the function
   the real cell uses), drawn off the main thread ahead of the pinch; until
   another level's is drawn the nearest level's stands in.
9. The stage asks the cover cache synchronously and draws the card's own overlays
   (the not-downloaded dim and cloud glyph, a download's clock / ring / pause /
   warning); covers that land mid-zoom replace the stand-in.
10. **Instant start.** The session is made ahead of the pinch (at rest, and when two
    fingers touch down) in steps of under 2 ms, the plans on a background task, the
    cells adopted hidden; a begin finds it ready, or the live cards are placed by the
    session's own rule (the bridge: the scene made first, the pair's lattice at the
    fingers' coordinate, only the covers scaled, labels at their own size) until it
    lands, so taking over changes nothing visible. The critical path never waits for
    the background. Any data change discards what was prepared.
11. **Pre-warm.** Every scroll stop and every landing schedules the covers' warm
    and the next start on `DeferredMainWork`, which runs units only while no finger
    is down, nothing coasts, no zoom or page transition is under way, and never for
    longer than about 2 ms at a time.
12. No Core Haptics engine: the step click is a light impact and the limit click one
    heavy impact (an engine's first make blocks the main thread and needs an audio
    session a game may own).

## Real Steam data: checks on a device

A generated library has no account, no installs and no sign-in. Real Steam data
differs in ways only a device with a real account shows. For each: what the
design does, and what to check on device.

### Remote covers
- **CDN latency and failures.** The cover cache returns whatever it has at once
  (the best resident size, else the plain placeholder the card draws today) and
  upgrades in place; failed candidates fall through to the next URL like
  `SteamGameArtwork`; a game whose every candidate fails stays a placeholder and
  is asked again after 60 s (a transient failure heals; a permanent 404 costs one
  request a minute per visible card).
  *Check:* scroll and pinch on a cold cache over cellular; no blank flashes once
  a cover has shown; placeholders upgrade without the card jumping.
- **Missing / odd-aspect art.** Covers are drawn aspect-fill into the 2:3 frame
  (as today's `scaledToFill`). Header images (460x215) used as a last resort are
  cropped hard. *Check:* demos and old apps with only a header image.
- **First load with nothing cached.** At begin the zoom asks the cache for every
  level's visible covers; misses show placeholders on the stage and upgrade
  ~10x a second. *Check:* first launch, pinch immediately: placeholders, no
  stalls; memory steady.
- **Memory at thousands of games.** Bitmaps are downsampled to the pixel size
  asked for, held in an NSCache with a byte budget (48 MB) and on disk. The zoom
  builds views only for the cards on screen at some width of the pinch.
  *Check:* a 2-5k library, scroll top to bottom, pinch through every level;
  Xcode memory gauge stays bounded; no jetsam.

### Library size
- **1-5k games, installed vs not.** Every item's frame comes from one pure
  function (the bands memoised per card width and measured off the main thread
  at idle); the layout binary-searches frames per scroll query; the zoom's scene
  walks only rows near the screen. *Check on device, Release:* 5k owned games
  with Not installed expanded: scroll at 120 Hz; pinch begin latency
  Instruments Time Profiler over a few
  pinches.
- **First page.** The account's cached library and playtime are read at launch
  (`MadeiraApp.init`, when the new grid is on), so the first page already shows
  Steam cards with their played lines. *Check:* cold launch, scroll at once: no
  row grows afterwards.
- **Data changing mid-zoom** (sign-in, refresh, download progress, playtime
  arriving): the SwiftUI wrapper hands the host a builder; the host builds the
  page only when it applies an update, and an update during a zoom is applied
  after the landing. Note: the ORIGINAL page rebuilds its Steam groups in
  `SteamGamesSection.body` on every download-progress tick (O(n log n) at 5k);
  the new page does the same work per applied update. *Check:* pinch while a
  download runs and while pull-to-refresh loads; scroll smoothness with a
  download running at 5k games.

### Titles and localisation
- Long titles wrap to two lines and are truncated as today; CJK titles measure
  with the system font's fallback; heights are measured per level. *Check:*
  Japanese/Korean/Chinese account names, titles with emoji, Dynamic Type sizes
  (the label heights re-measure on a content-size change).

### Sections and groups
- The three Platform sections and the Group by groups can be very uneven (one
  installed game above 3,000 not installed). Blocks move by one cumulative
  rule, so a small block between big ones never overlaps them. Collapsed
  sections are simply absent from the zoom. *Check:* pinch on the boundary
  between Steam and Other games, with a section collapsed, and with Group by
  Last played.

### The ambient glow
- The light is one Metal layer behind the cells, drawn at 30 fps in the page's
  coordinates; it fades out while a zoom runs (following its cards) and comes
  back after it. Its blur ends inside its texture, so no clipped edge shows under
  the top scroll-edge blur.
  *Check:* the light under the top bar while scrolling; Instruments' GPU time on
  an iPad.

### iPad widths, rotation, Stage Manager
- Levels come from the width (at most five), the stored position maps to the
  nearest level; a width change during a zoom ends the zoom at its nearest
  level first. *Check:* rotate mid-scroll, resize a Stage Manager window,
  split view at 1/3 width (two columns minimum).

### Sign-in / refresh changing the data
- See "Data changing mid-zoom". A sign-out removes the Not installed section;
  the page model rebuild after the landing handles it. *Check:* sign out while
  the library shows 2k games.

## How to test

- **Host checks** (no Xcode): `python3 tests/host/check-library-zoom.py` (the pure
  model, geometry and wiring), `check-steam-games.py`, `check-library-sections.py`.
- **On a device**, Release, with a real account: the checks under "Real Steam
  data" above.

## Files

- `app/Madeira/LibraryGridZoomModel.swift`, `LibraryGridZoomScene.swift` (pure)
- `app/Madeira/LibraryGridZoomStart.swift` (instant start), `LibraryGridZoomIdle.swift` (pre-warm), `LibraryGridZoomHaptics.swift`, `DeferredMainWork.swift`, `InteractionFrameRate.swift`
- `app/Madeira/LibraryGridLevels.swift` (levels, geometry, label measuring)
- `app/Madeira/LibraryCoverCache.swift`
- `app/Madeira/LibraryGridPage.swift` (page model, SwiftUI wrapper), `LibraryGridHost.swift` (collection view, layout, cells), `LibraryGridCardCell.swift`
- `app/Madeira/LibraryGridZoom.swift` (the session, the pinch, the landing), `LibraryGridZoomStage.swift` (what a zoom draws), `LibraryGridZoomBlend.swift`
- `app/Madeira/LibraryGridGlow.swift`, `AmbientGlow.metal`
- `tests/host/check-library-zoom.py`
