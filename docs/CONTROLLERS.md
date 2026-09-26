# Physical and touch controllers through XInput

Paired GameController devices and the existing landscape touch editor feed
Windows games through a shared XInput snapshot. Up to four physical extended
profiles have stable slots; disconnecting one does not renumber the others.
Touch input merges into player 1 (slot 0).

## Physical input and transport

The app captures live profiles and samples them on a serial queue at 250 Hz
(4 ms with 1 ms scheduling leeway), with change callbacks for prompt updates.
The timer stops while inactive or with no connected physical pads. Inactive
controllers remain connected but report neutral input. Disconnects clear slots
unless the touch layout still supplies slot 0. Buttons, triggers, and signed
stick axes reach XInput without mouse synthesis or an app-imposed dead zone.
iOS 18 event claims prevent focus navigation from consuming controller events.

`WiniosGamepad.c` publishes snapshots under a short mutex. Packet numbers change
only when the sample or connection changes. The win32u query copies state or
capabilities into the Windows caller's buffer. Wine's paired XInput change tries
this query before its existing HID path.

## Touch controls

In the existing landscape touch editor, assign a control using its Controller
tab. Saved `pad` names remain compatible: A/B/X/Y, D-pad directions, LB/RB,
L3/R3, Menu/View/Guide, LT/RT and LS/RS. LT/RT are full-press triggers; LS/RS are
analogue sticks with radial clamping and the full signed XInput range. Stick
motion is relative to the initial touch position. Guide follows Wine's existing
XInput filtering rules; not every API/game exposes it.

A visible, non-editing landscape layout with at least one supported controller
mapping connects a virtual player 1, even before a button is pressed. Hiding
controls, entering editing, switching to portrait, removing the overlay or
remapping releases input. Backgrounding releases holds while retaining the
connected identity. UIKit handles independent fingers and cancellation, so
releasing one of two controls mapped to the same button leaves the other held.
The pinch recognizer is enabled only during editing.

Touch and physical buttons combine; triggers use the larger value. A physical
stick outside its standard XInput dead zone takes priority over touch on that
stick. Otherwise a deflected touch stick takes priority; resting touch preserves
the physical value. Touch updates are event-driven and require no polling timer.
Keyboard/mouse mappings and the existing layout format are retained.

## Layouts

While touch controls are shown, the landscape top bar has a layout button
(stacked squares) next to the show/hide controller glyph. It lists:

- **Xbox controller**, a built-in full XInput layout: LT/LB and RB/RT rows in the
  top corners, a D-pad cross above the left stick, the A/B/X/Y diamond above the
  right stick, View/Menu at the bottom centre and L3/R3 beside the sticks. It is
  laid out in points from the safe-area edges each time it is loaded, so it fits
  phones and tablets, and it keeps clear of the top bar. It is offered only while
  touch XInput is enabled, since its buttons are controller mappings.
- The user's own layouts, **Custom Layout 1**, **Custom Layout 2**, ...
- **Create new layout**, which adds the next free "Custom Layout N" with no
  controls and opens the editor on it.
- **Delete** for the active custom layout (confirmed first). The deleted
  layout's controls are replaced by the built-in, when it is available.

Built-ins cannot be changed. Custom layouts live in
Documents/madeira-control-presets.json; madeira-controls.json stays the working
copy the overlay draws and records which layout it came from (an optional
`layout` field, so older files still load). When an edit ends, the controls are
written back to the active custom layout. Editing the built-in leaves it as
shipped: the edited controls become unsaved controls. Choosing another layout
while unsaved controls are on screen asks first and offers to keep them as the
next custom layout, so an existing hand-made layout is never lost.

A new user, meaning no madeira-controls.json at launch, gets the built-in the
first time the landscape overlay appears. It is never applied over an existing
controls file, even an empty one.

The editor shows **Done** in place of the checkmark and hides the show/hide
glyph while editing; **+** still adds a control. Menus and confirmation dialogs
raised from the overlay window take the touches they cover.

## Player 1 at session start

Some input layers enumerate XInput once when a game starts and only look again
on a device-arrival broadcast, which this port cannot deliver. Touch player 1
connects only once the landscape overlay shows its controller mappings, and a
paired controller may not have reported an extended profile yet, so such a game
would never see a pad. When a Wine session starts with visible touch controller
mappings (or a new user's built-in layout about to be applied) or with a paired
controller, slot 0 is published as connected with neutral input. Live touch or
physical input takes it over. Hiding the controls or disconnecting the pad then
leaves player 1 connected at rest until the app exits.

## Audio route with wired controllers

Some controllers enumerate as a USB audio output when wired. iOS then routes all
app audio to the controller and the device sounds silent while the audio engine
reports healthy signal levels. This is system routing, not a Madeira audio fault:
unplug the cable or pair the controller over Bluetooth.

## Rollback and scope

Set `env.MADEIRA_XINPUT = 0` in Documents/madeira.cfg and restart to disable the
whole producer and controller event claims. Set `env.MADEIRA_TOUCH_XINPUT = 0`
to disable only touch gamepad input. `[xinput] ml1920` logs physical enablement
and connections; `[touch-xinput] ml1930` logs touch enablement once.

Each follow-up behaviour has its own switch (`env.NAME = 0` in madeira.cfg, or
the process environment; only `0` disables):

| Switch | Default | `0` restores |
| --- | --- | --- |
| `MADEIRA_CONTROL_PRESETS` | on | no layout menu, no default layout, no write-back |
| `MADEIRA_CONTROLS_XBOX_DEFAULT` | on | new users start with no controls |
| `MADEIRA_CONTROLS_EDITOR_DONE` | on | the checkmark and show/hide glyph while editing |
| `MADEIRA_PAD_EARLY_SLOT` | on | slot 0 connects only when a source appears |

`[controls-layout] ml1970` logs layout loads, saves, creation and deletion
(never layout names); `[xinput] ml1990` logs the session slot reservation.

DirectInput has a separate, opt-in device in the companion Wine change: one
joystick with the standard XInput controller object set (X/Y and Rx/Ry sticks,
Z as the combined triggers, an 8-way POV, ten buttons), read from the same host
query. It is hidden unless `env.MADEIRA_DINPUT_PAD = 1` is in madeira.cfg
(exported to the Wine environment), because a game that reads both APIs would
otherwise see two controllers. `MADEIRA_DINPUT_TRACE=1` adds a rate-limited
state trace.

Vibration, battery telemetry, controller-driven navigation of the app itself,
binding physical buttons to keyboard/mouse controls, shaped (non-round) controls,
a layout-wide size slider and a movable top bar remain outside this contribution.

## Integration prerequisite

The XInput path needs [the Wine change](https://github.com/willfaust/wine/pull/1),
which is merged and pinned. The opt-in DirectInput device needs its companion
Wine change and rebuilt dinput.dll/dinput8.dll; the app side needs nothing more.
Source PRs keep upstream's submodule pins and prebuilt DLLs.

Rebuild the native win32u library and affected PE win32u/XInput modules using
the paired Wine source. Rebuild wow64win for a WOW64 configuration. XInput
1.1/1.2/1.3/1.4/UAP share the implementation; 9.1.0 forwards to 1.4. Copying just
the app changes over the existing prebuilt DLLs will not enable the feature.
No binaries from the larger fork are included here.

## Validation

Run on a POSIX host with a C compiler and Swift installed:

```sh
python3 build/host-tests/check-gamepad.py
python3 build/host-tests/check-touch-gamepad.py
python3 build/host-tests/check-control-presets.py
```

The first compiles production snapshot/query code and checks packets, ranges,
slots, invalid queries, disconnect/reconnect and concurrent readers/writers.
The second compiles production touch state and checks independent button holds,
layout/lifecycle clearing, analogue ranges, duplicate sticks and physical/touch
arbitration, and the session slot reservation. The third compiles the
production layout store with the controller actions: the built-in layout on
phone, tablet and portrait-reported screens (complete, supported mappings,
inside the safe area and clamps, no overlaps, top bar clear), built-ins
read-only, "Custom Layout N" naming, JSON round trips and what loading a layout
puts on screen; it also checks the switch and write-back wiring in the source.
Set `SWIFTC` if Swift is not on PATH. These are logic tests, not UIKit gesture
or device integration tests.

The Swift bridge, touch view and changed touch-editor section type-check against
the arm64 iOS 17 SDK with the production config reader and stubs for unrelated
app UI/logging/input sinks. The C transport compiles for arm64 iOS 17. Companion
Wine XInput source compiles for x86-64/i386; its standalone native Windows API
test passes using a synthetic host query.

The full combined upstream app has not been linked or device-tested. Before
merge, rebuild the paired components and test:

- Physical buttons, sticks, triggers, disconnect/reconnect and multiple pads.
- Touch-only player 1, both sticks plus buttons together, and duplicate mappings.
- Mixed physical/touch holds; releasing either source must preserve the other.
- Hold then hide, edit, remap, remove, rotate, background or interrupt the app;
  no input should remain stuck, and fresh touches should work afterward.
- Both rollback flags, saved layouts, and existing keyboard/mouse controls.
- Layouts: a fresh install gets the built-in once; an existing controls file is
  kept; switching away from unsaved controls asks first; create, edit with Done,
  relaunch and reload a custom layout; delete it; the layout menu and its dialogs
  respond anywhere on screen; each follow-up switch at `0`.
- A game that enumerates XInput only at startup sees player 1 with touch
  controls shown or a controller paired before launch.

The fork's existing device history does not prove this isolated extraction.
