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

Once the touch pad has connected, the Session menu (including opening the
software keyboard) and control editor keep that identity connected with neutral
input. Late touches are ignored while gameplay controls are suppressed; closing
the menu accepts fresh input without an XInput disconnect/reconnect. This does
not connect a pad early while the game is loading. Actually hiding or removing
all controller mappings still disconnects it, unless the session reservation
described below is enabled.

Touch and physical buttons combine; triggers use the larger value. A physical
stick outside its standard XInput dead zone takes priority over touch on that
stick. Otherwise a deflected touch stick takes priority; resting touch preserves
the physical value. Touch updates are event-driven and require no polling timer.
Keyboard/mouse mappings and the existing layout format are retained.

While such a layout shows at least one controller mapping, a touch on the game
view that misses every control is not sent to the program as a mouse. Some
games (Dark Souls Remastered) switch to keyboard and mouse prompts on any mouse
event and then ignore the controller. Touch used as a
trackpad and a hardware mouse are not affected. `env.MADEIRA_TOUCH_MOUSE = 1`
always sends such touches, as before; `0` never does.

## Layouts

While touch controls are shown, the landscape top bar has a layout button
(stacked squares) next to the show/hide controller glyph. In a library session
that top bar is replaced by the library's menu button, and the same menu is the
**Controller layout** row of the in-game **Session** menu, below **Touch
controls** (`docs/LIBRARY.md`). Either one lists:

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

A library game remembers the layout its controls were loaded from (an optional
`controlLayout` field of its library entry, so older files still load; a layout
deleted since is treated as none), and the session restores the shared layout
when it ends. A game with no saved controls of its own draws the shared working
copy, as before.

The two key sticks, WASD and Arrows, draw a small symbol on the knob in the
middle of the stick (a keyboard, and four arrows) so they can be told apart; the
controller sticks keep their LS/RS label.

Built-ins cannot be changed. Custom layouts live in
Documents/madeira-control-presets.json; madeira-controls.json stays the working
copy the overlay draws and records which layout it came from (an optional
`layout` field, so older files still load). When an edit ends, the controls are
written back to the active custom layout. Editing the built-in leaves it as
shipped: the edited controls become unsaved controls. Choosing another layout
while unsaved controls are on screen asks first and offers to keep them as the
next custom layout, so an existing hand-made layout is never lost.

The built-in is never applied automatically by default: it is only loaded
when chosen from the menu. A missing madeira-controls.json does not identify a
new user (the file is only written once the controls or their visibility
change, so an existing user who never touched them has none either), and
nothing else on disk tells the two apart reliably. With
`env.MADEIRA_CONTROLS_XBOX_DEFAULT = 1`, a user with no madeira-controls.json
at launch gets the built-in the first time the landscape overlay appears; it is
never applied over an existing controls file, even an empty one.

The editor shows **Done** in place of the checkmark and hides the show/hide
glyph while editing; **+** still adds a control. Menus and confirmation dialogs
raised from the overlay window take the touches they cover.

## Player 1 at session start

Some input layers enumerate XInput once when a game starts and only look again
on a device-arrival broadcast, which this port cannot deliver. Touch player 1
connects only once the landscape overlay shows its controller mappings, and a
paired controller may not have reported an extended profile yet, so such a game
would never see a pad.

This is **opt-in** (`env.MADEIRA_PAD_EARLY_SLOT = 1`), because the reserved
player 1 stays connected for the whole session. With the switch, when a Wine
session starts with visible touch controller mappings (or the built-in about
to be applied by `MADEIRA_CONTROLS_XBOX_DEFAULT = 1`) or with a paired
controller, slot 0 is published as connected with neutral input. Live touch or
physical input takes it over. Hiding the controls or disconnecting the pad then
leaves player 1 connected at rest until the app exits. Without the switch,
slot 0 connects only when a real source appears, as before.

## A controller as keyboard and mouse

For a game without controller support (or with it switched off), Game details
and the in-game Session menu offer **Controller: Keyboard and mouse**. Steam
Input does this for desktop players; Madeira Dock runs Valve's client headless,
so Madeira does it itself (`PadKeyboardMouse.swift`). The default, **Game's own
support**, is XInput as before.

In keyboard-and-mouse mode the physical pad is not published to XInput at all
(the game sees no controller; touch controller mappings still connect player 1),
and every pad input becomes what the touch controls already produce, through
the same posting paths:

| Pad input | Default |
| --- | --- |
| Left stick | WASD (the same eight sectors as a touch key stick) |
| Right stick | Mouse motion (the pointer settings' relative sensitivity) |
| RT / LT | Left / right mouse button (half press) |
| D-pad | Arrow keys |
| A, B, X, Y | Space, Ctrl, E, R |
| LB, RB, L3, R3 | Q, F, Shift, C |
| Start, Select | Escape, Tab |

The game's **Controller binds** page (the Session menu while the mode is on, and
Game details) lists every input with a menu of what it does: a mouse button, a
key, Show keyboard or Nothing; the sticks choose between WASD, the arrow keys
and (right stick) the mouse. Rows the player has not changed show the layout's
or the template's action and are not stored; "Default" in a row's menu and
the page's Reset clear them. The table is saved with the game
(`LibraryEntry.controllerBinds`) and the driver takes each change at once.
While the right stick is the mouse, the page also has its **Vertical speed**
(`LibraryEntry.padMouseVertical`, 25–150 % of the horizontal speed): games
scale the camera's pitch and yaw differently from a mouse, and a stick cannot
be compensated by hand the way a wrist does.

The Controller picker's second choice, **XInput and DirectInput**, is for games
older than XInput: it exports `MADEIRA_DINPUT_PAD=1` for that launch only (the
DirectInput device below), since a game reading both APIs may list two
controllers. The game's choice wins over `env.MADEIRA_DINPUT_PAD` in madeira.cfg
and is cleared when the session ends (ml1240); the cfg value still applies to
games left on the other choices. Chosen from the Session menu, it takes effect at
the next launch.

A layout can also bind an input: in the control editor, a touch control with
a key or mouse action has a **Controller button for this action** row, and a
key stick (WASD or Arrows) can name LS or RS. The named input then does what
that control does (`TouchControl.padBinding`, an optional field, so older
layouts load unchanged); a key stick bound to RS takes the right stick away from
the mouse. The bindings follow the layout on screen and are rebuilt when it
changes. The choice is saved with the game. While the Session menu is open, or
when the app resigns active, everything the mode holds is released.

`MADEIRA_PAD_KBM=0` removes the choice; `[pad-kbm]` logs the mode switching on
and off and its releases.

## Gyro aim and turbo

Game details › Controls › **Gyro aim & turbo**, and the same page in the
in-game Session menu, where a change applies at once (`PadAssist.swift`). Both
are per game, off until turned on, and apply to player 1 only.

**Gyro aim** adds the controller's rotation to the right stick, so the camera
follows the pad while the stick still works on top of it.

- *Gyro*: **Controller** (any pad GameController reports motion for:
  DualSense, DualShock 4, Switch Pro, Joy-Con), **This device** (the iPhone or
  iPad's own gyro, for touch play with the screen held upright), or
  **Automatic**, the controller's when it has one and the device's otherwise.
  Pads whose sensors are off until asked have them switched on only while a
  session uses gyro aim.
- *Active*: always, or only while holding LT, LB or RB.
- *Moves*: the **Right stick**, the **Mouse** (8 pixels a degree at 1×), or
  **Automatic**: the mouse while the game sees no controller from the pad (no
  controller and no touch controller, or keyboard-and-mouse mode) and the
  right stick otherwise. With no controller there is nothing to hold, so only
  *Always* moves the mouse.
- *Turn with*: twisting the pad flat (yaw) or tilting it like a wheel (roll).
- *Sensitivity* 0.25× to 4×; 1× is full deflection at 150 degrees a second.
- *Anti-dead zone* (default 25%, XInput's standard right-stick dead zone):
  the least deflection any gyro movement gives, so slow aim passes the game's
  own dead zone. Rotation under 2 degrees a second is ignored, so a still pad
  does not drift.
- *Invert* up and down, left and right.

**Turbo** repeats chosen buttons (A, B, X, Y, LB, RB, LT, RT) 5 to 30 times a
second while they are held, starting pressed. It applies to touch buttons too.

Player 1's sample passes through both after the touch merge, so XInput and the
HID controller see the result; in keyboard-and-mouse mode it passes through
before the key feed. Neither applies
while the library or the Session menu has the pad. Touch play with either on
keeps the 4 ms poll running without a physical pad. `[pad-assist]` log lines
record each session's choices and the sensors switching on and off.

## Player 1 as a HID controller (DualSense, DirectInput)

XInput stays the default and is unchanged. A game can instead see player 1 as
what it is, a HID game controller, the way CrossOver shows a DualSense on a
Mac: `env.MADEIRA_PAD_MODE = hid` in madeira.cfg (Settings > All settings >
Controllers > Controller API). `dualsense` or `generic` force the identity.

The mode is read once, when the Wine session starts (`GamepadInput.beginPadSession`
exports `MADEIRA_HIDPAD` before the wineserver starts): the device must exist
before the game enumerates, and a launch runs one Wine session, so a change
applies at the next start.

What the game gets, with `hid`:

- A PlayStation pad as player 1 (or no pad paired yet): a wired **DualSense**,
  Sony 054C:0CE6, USB interface 3 (`\\?\HID#VID_054C&PID_0CE6&MI_03#...`),
  "Sony Interactive Entertainment" / "DualSense Wireless Controller", with the
  controller's own 273-byte report descriptor (CFI-ZCT1W, byte-identical to
  the dump in github.com/nondebug/dualsense). Input report 0x01 (64 bytes) and
  output report 0x02 (48 bytes) follow Linux hid-playstation.c and SDL's
  SDL_hidapi_ps5.c; feature reports 0x05 (calibration: 16 units per deg/s,
  8192 per g), 0x09 (pairing address) and 0x20 (firmware 0x0224) answer, the
  others read as zeros. Sony's libScePad (God of War, other Sony PC ports)
  and SDL's HIDAPI driver see a PS5 pad; DirectInput shows it as Windows does
  (X/Y left stick, Z/Rz right stick, Rx/Ry the triggers, a hat, 15 buttons).
- Any other pad: stays on **XInput** (`[hid-pad] ... is not a PlayStation pad`),
  since an XInput game that does not also enumerate DirectInput never sees the
  generic HID gamepad. `generic` (or `env.MADEIRA_HIDPAD_AUTO_GENERIC = 1` with
  `hid`) makes it a **generic HID gamepad**, pid.codes 1209:4D47, with the
  object set of the opt-in DirectInput pad below: X/Y and Rx/Ry sticks, Z =
  LT - RT, an 8-way hat, buttons A B X Y LB RB Back Start L3 R3 Guide.

Readers: hid.dll and setupapi (HidD_*/HidP_*, ReadFile/WriteFile, feature
reports), DirectInput 8 through Wine's HID joystick, windows.gaming.input's
raw game controllers, and the raw input device list. Not yet: WM_INPUT for
the pad (no raw input reports are generated).

XInput in HID mode: player 1 leaves XInput, as a DualSense on Windows is not
an XInput pad (without Steam Input), so a game that reads both APIs -- God of
War reads XInput and libScePad -- sees one controller, not two; players 2-4
stay XInput. Wine's xinput only adopts WINEXINPUT devices, never this one.
`env.MADEIRA_HIDPAD_XINPUT = 1` keeps player 1 on XInput too (two views of
one pad). In XInput mode there is no HID device at all: no device object, no
registry entry.

With the per-game **Controller** choice (Game details and the Session menu,
above), HID mode is the madeira.cfg setting the picker builds on, for every
game:

- **Game's own support**: player 1 is the HID controller, as configured.
- **XInput and DirectInput**: nothing extra. DirectInput already lists the HID
  controller through Wine's HID joystick, and the opt-in "Madeira Gamepad"
  (`MADEIRA_DINPUT_PAD`, below) reads XInput slot 0, which player 1 has left,
  so it stays hidden and the game sees one controller. With
  `env.MADEIRA_HIDPAD_XINPUT = 1` it would list both.
- **Keyboard and mouse**: the physical pad presses keys and moves the mouse as
  above. The HID controller still exists (it is created at session start) but
  gets none of the pad's input: it reports a pad at rest, or the touch
  controller when that connects player 1, as XInput does in this mode.

Mapping (from the same sample as XInput, touch merge included): cross/circle/
square/triangle = A/B/X/Y, L1/R1, L2/R2 analogue plus their digital bits above
25/255, Create = buttonOptions, Options = buttonMenu, L3/R3, PS = buttonHome
(when iOS does not keep it for itself; the same as XInput's Guide), touchpad
click from GCDualSenseGamepad/GCDualShockGamepad. GameController exposes no
microphone (mute) button, so that bit never sets. Battery level and charging
come from GCDeviceBattery once a second. Sensors report the pad lying flat,
the touchpad reports no finger.

Output (ml2106/ml2107): the game's output reports (0x02 over WriteFile or
IOCTL_HID_SET_OUTPUT_REPORT) are decoded in the wineserver and applied to
player 1's pad by `app/Madeira/PadOutput.m`: the rumble pair through
CoreHaptics on the left and right handle, each trigger effect as the closest
`GCDualSenseAdaptiveTrigger` mode (`Winios/WiniosPadEffects.h`), the light bar
through `GCDeviceLight`, the player LEDs through `playerIndex`. All three
rumble flags count (Linux's compatible vibration and haptics select, and the
firmware-2.24 "improved rumble" flag libScePad and SDL use), as does the motor
power reduction byte. When the game closes its last handle the motors stop
and the triggers are released; while the app is inactive the motors stop and
the triggers go off. `env.MADEIRA_PAD_OUTPUT = 0` keeps the pad as it is.

What iOS allows at all: an app never sees the DualSense's HID reports, its
USB interfaces or its audio channels; it gets GameController's view only --
GCDualSenseGamepad state, GCDualSenseAdaptiveTrigger modes (off, feedback,
weapon, vibration, and the positional variants), GCDeviceLight (light bar
colour), GCController.playerIndex (four fixed player-LED patterns), GCMotion,
and CoreHaptics engines from GCDeviceHaptics. So the output side is mapped
best effort: the classic rumble pair to CoreHaptics intensities, a game's
trigger effect to the closest Apple trigger mode (bow becomes weapon,
galloping and machine become vibration), the light bar colour to
GCDeviceLight. Not reproducible on iOS: the DualSense's audio-driven
("advanced") haptics -- PC games send those as a sound stream to the pad's
USB audio interface, which this virtual device does not have, so such games
fall back to the rumble pair -- the speaker, headset and microphone, the
microphone LED, arbitrary player-LED patterns, light bar brightness/fade
settings. CoreHaptics on a game controller only takes plain pattern players
(the advanced player breaks the engine's connection to gamecontrollerd), so
each handle plays one continuous event (30 s long) whose intensity follows the
motor. The event is restarted on the first change of level after 25 s, so a
level held unchanged for over 30 s goes quiet until the game changes it; there
is no timer that re-arms it, which after a crash would keep the pad buzzing. A
failed engine set-up backs off and retries.

Why the wineserver serves it: on desktop Wine a pad reaches hid.dll through
plugplay/winedevice loading winebus.sys, winehid, hidclass and hidparse. A
Madeira session runs no winedevice (winebus, winehid and PlugPlay are disabled
in the prefix template) and ships no .sys file, so
`build/wineserver/hidpad_ios.c` creates `\Device\MadeiraHidPad0` and its
`\??\HID#...` link and answers reads, writes and ioctls with hidclass's
contract, as the server already does for ConDrv and named pipes. The preparsed
data comes from Wine's own hidparse.sys parser compiled into the wineserver
(`build/hidpad/hidparse_ios.c`), so it is exactly what the shipped hid.dll
expects. `build/ntdll-unix/server_ios.c` writes the volatile registry entries
setupapi lists (Enum\HID\..., DeviceClasses\{4d1e55b2-...}\##?#HID#...),
level by level and only for the link that exists. Reports are built on
demand from the newest sample: a read completes when the handle had no report
for 4 ms (a wired DualSense's rate) or a new sample is 1 ms old; a 4 ms timer
runs only while a read is pending. hid.dll, setupapi and dinput are the
shipped builtins, unchanged.

Logs: `[hid-pad] ml2100 session mode=... kind=...` (app), `[hid-pad] ml2101
device dualsense 054c:0ce6 ...` (wineserver), `[hid-pad] ml2102 ... registered
(4/4 keys)` (first Wine process), then `ml2101 open #n`, `first input report`,
`feature report 0x.. read`, `[hidpad-out] ml2106 #n via write|ioctl ...`
(the decoded output report; then a tally at 100, 1000, ... reports), `ml2104
... refused` and `unsupported ioctl` (each limited to a few lines); the app
logs what it applied as `[hidpad-out] ml2107 ...` (`haptics ready on ...`,
`slot n rumble`, `L2:`/`R2:` trigger modes, `lightbar`).

`tests/host/check-hidpad.py` (needs the wine submodule or `WINE_SRC`)
runs both descriptors through Wine's hidparse.sys and hid.dll and checks every
report field, the feature and output reports, the snapshot transport, and the
registry entries against a fake registry with Wine 11's rules.
`tests/host/check-pad-output.py` runs the output decoder (USB and Bluetooth
reports, CRC), the trigger-effect mapping against a transcription of Nielk1's
TriggerEffectGenerator, the rumble levels and player LEDs, and checks the
PadOutput/Xcode/GamepadInput/win32u wiring.

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

Each follow-up behaviour has its own switch (`env.NAME = value` in
madeira.cfg, or the process environment). The two that change what an existing
user sees are opt-in (only `1` enables); the others are on unless set to `0`:

| Switch | Default | Effect |
| --- | --- | --- |
| `MADEIRA_CONTROL_PRESETS` | on | `0`: no layout menu, no write-back |
| `MADEIRA_CONTROLS_EDITOR_DONE` | on | `0`: the checkmark and show/hide glyph while editing |
| `MADEIRA_CONTROLS_XBOX_DEFAULT` | **off** | `1`: a user with no controls file gets the built-in once |
| `MADEIRA_PAD_EARLY_SLOT` | **off** | `1`: player 1 is reserved at session start (see above) |
| `MADEIRA_PAD_MODE` | XInput | `hid` / `dualsense` / `generic`: player 1 as a HID controller (see above) |
| `MADEIRA_HIDPAD_XINPUT` | **off** | `1`: in HID mode, player 1 stays an XInput pad as well |
| `MADEIRA_PAD_OUTPUT` | on | `0`: no rumble/trigger/lightbar output to the pad; `hid` / `xinput`: only that half |
| `MADEIRA_XINPUT_BATTERY` | on | `0`: XInput reports an unknown battery and no wireless flag (ml2170) |
| `MADEIRA_WGI_HOST_PADS` | on | `0`: Windows.Gaming.Input lists no controllers (ml2171) |
| `MADEIRA_XINPUT_ENABLE_FOREGROUND` | on | `0`: a game's XInputEnable(FALSE) zeroes the pad even while its window is in front (ml2115) |
| `MADEIRA_XINPUT_SLOT0_RECONNECT` | on | `0`: a reconnected player 1 stays in the slot it landed in (ml2172) |
| `MADEIRA_CLICK_FOCUS` | on | `0`: a tap or click on an already active window leaves its keyboard focus as it is (ml2181, "Keyboard focus" below) |

`[controls-layout] ml1970` logs layout loads, saves, creation and deletion
(never layout names); `[xinput] ml1990` logs the session slot reservation.

DirectInput has a separate, opt-in device in the companion Wine change: one
joystick with the standard XInput controller object set (X/Y and Rx/Ry sticks,
Z as the combined triggers, an 8-way POV, ten buttons), read from the same host
query. It is hidden unless `env.MADEIRA_DINPUT_PAD = 1` is in madeira.cfg
(exported to the Wine environment), because a game that reads both APIs would
otherwise see two controllers. `MADEIRA_DINPUT_TRACE=1` adds a rate-limited
state trace.

XInput vibration (ml2106): XInputSetState's two motors play on the pad in
that slot through CoreHaptics, and XInputGetCapabilities reports motors, when
`MADEIRA_PAD_OUTPUT` allows it. XInputSetState, XInputEnable and process
detach forward the motors through `NtUserGamepadOp_SetVibration`; the shipped
arm64ec xinput1_1-1_4 and xinputuap carry it.

XInput battery (ml2170): XInputGetBatteryInformation reports each pad's
GameController battery (GCDeviceBattery, read once a second): on its battery,
`BATTERY_TYPE_NIMH` with EMPTY/LOW/MEDIUM/FULL at 5/20/70 %; charging or full,
`BATTERY_TYPE_WIRED`/FULL, as Windows shows a pad on a cable; no battery
information, `BATTERY_TYPE_UNKNOWN`/FULL; the touch controller alone,
WIRED/FULL. Headset queries answer `BATTERY_TYPE_DISCONNECTED`, and
XInputGetCapabilities sets `XINPUT_CAPS_WIRELESS` while the pad runs on its
battery. Before this every host pad read as an unknown battery at EMPTY, which
some games take for a low battery. `env.MADEIRA_XINPUT_BATTERY = 0` restores
that. Changes are logged as `[xinput] ml2170 slot=N battery type=T level=L`
(XInput's numbers: type 1 wired, 3 NiMH, 255 unknown; level 0-3).

Windows.Gaming.Input (ml2171): Wine's windows.gaming.input only lists devices
that winebus.sys creates, which a Madeira session never runs, so a game that
reads controllers only through that API (`Gamepad.Gamepads`,
`RawGameController.RawGameControllers`) saw none. Each connected XInput slot is
now also a Gamepad there (and a RawGameController: six axes, ten buttons, one
switch, 045E:028E like XInputGetCapabilitiesEx), read straight from the host
slot (so a game's XInputEnable does not affect it) and rescanned once a second
for pads that come and go. Gamepad.Vibration's two motors go to the slot's
rumble; the trigger motors have no path on iOS and are dropped. Logged as
`[wgi] ml2171 host pad N listed as a Gamepad` / `removed` (16 lines per
process, only in games that use the API). `env.MADEIRA_WGI_HOST_PADS = 0` turns it
off.

A stale XInputEnable(FALSE) (ml2115): many games call XInputEnable(FALSE) when
their window loses activation and XInputEnable(TRUE) when it comes back. The
activation messages a window gets while the port restores it and brings it to
the front at startup can arrive unbalanced, and the game then reads a
connected pad at rest for the whole session. While XInput is disabled, xinput
asks win32u (`NtUserGamepadOp_Foreground`, op 3) whether the calling process
owns the foreground window; if it does, the disable is taken as stale and the
live state is returned. `env.MADEIRA_XINPUT_ENABLE_FOREGROUND = 0` keeps the
pad at rest while disabled. Logged (ERR, capped): `[xinput] ml2114
XInputEnable(0|1) slot0=... foreground=...`, `[xinput] ml2114 first state query
index=N: connected (host slot)|not connected, XInput enabled|disabled`, and
once either `ml2115 ... live state` or `ml2114 ... host pad state zeroed
(reason)`. The op keeps the number and ABI of the pre-2026-10-01 fork's query,
whose 32-bit xinput builds are still in use; the battery op is 4.

Player 1 after a reconnect (ml2172): GameController can report a pad that
reconnects as a new controller before the old one leaves. The new one then
lands in slot 1 while slot 0 is still taken, slot 0 empties a moment later,
and a game that reads only player 1 sees nothing. When slot 0 has just
emptied and exactly one controller joined another slot within the last 5 s,
it is moved to slot 0 (`[xinput] ml2172 slot=N moved to slot 0`); a second
player's pad that has been connected longer keeps its slot.
`env.MADEIRA_XINPUT_SLOT0_RECONNECT = 0` leaves it where it landed.

Controller-driven navigation of the app itself,
shaped (non-round) controls, a layout-wide size slider and a movable top bar
remain outside this contribution. Binding physical buttons to keyboard/mouse
controls is the keyboard-and-mouse mode above.

## Foreground window

Nothing on iOS activates a window, so a game whose windows are shown with
`SWP_NOACTIVATE` is never the foreground window. A game that ignores input
unless `GetForegroundWindow()` is its own window (Dark Souls Remastered) then
reads the controller and drops it. While a process polls XInput and the
foreground window is not one of its own, win32u makes the process's largest
top-level window foreground and active, checking at most once a second; a
window of the same process already in front is left alone. `[fg]` logs the first
activations. `env.MADEIRA_FOREGROUND_FIX = 0` turns this off.

Keyboard focus (ml2181). In front is not always enough: some engines start
their per-frame input with `GetFocus() == their window` and drop polled input
(XInput, DirectInput) otherwise, while keyboard messages still reach the
window. Wine moves the keyboard focus into a top-level window only while it
activates it, so a window that is already its thread's active window keeps
whatever focus the thread has, possibly none: a click on it sends no
`WM_MOUSEACTIVATE`, and `SetForegroundWindow` on the window already in front
does nothing. On the window's own thread, after a mouse button press
(win32u `process_mouse_message`, also while the program holds the capture), a
born-minimized restore (`winios_drv_foreground_if_owner`)
and the once-a-second foreground check above, `winios_click_focus` focuses the
top-level window when it is the thread's active window and the focus is
nowhere inside it, which is what `DefWindowProc` does for `WM_ACTIVATE` on
Windows. Focus already inside the window (a child control), menu and move/size
modes, and minimized or disabled windows are left alone. Logged (stderr, 24
lines): `[winios] ml2181 focus → hwnd H (click|tap|activate) was F now N`.
`env.MADEIRA_CLICK_FOCUS = 0` turns it off.

The `[xinput] ml2180 state read …` line (win32u, the first 16 input/rest
transitions per slot) also carries the reading thread's GUI state since ml2181:
`fg=H(pid P) active=A focus=F capture=C focus-in-fg=0|1 fg-focus=G` (the
foreground window and its process, the reading thread's own active, focus and
capture windows, whether that focus lies inside the foreground window, and the
foreground thread's focus). `focus=0x0` with `active` equal to the game's
window is the state ml2181 repairs.

What reads a slot: XInputGetState and DirectInput's host joystick
(`MADEIRA_DINPUT_PAD`) both sample through the same win32u query, so an
`ml2180 state read index=0` line alone does not show that the game reads
XInput. xinput prints `[xinput] ml2114 first state query index=N` the first
time a game calls XInputGetState(Ex) for slot N; when that line exists for
slots 1-3 but not 0 while `[dinput] ml2116 enumeration: slot0=connected,
listed` is in the log, the game took the DirectInput joystick as its slot-0
controller and polls XInput only for the other slots. A game written for
both APIs tells an XInput pad apart from a DirectInput one by its PnP id
(the `IG_` marker it looks up through WMI's `Win32_PnPEntity`); the host
DirectInput joystick has no such entry, so such a game treats it as a generic
joystick. Choose **XInput** (not "XInput and DirectInput") for such a game.
A game that reads no XInput is not covered by that rule, and Windows sends raw
keyboard and mouse input only to the process in front. Horizon Zero Dawn
(madeira-bcd build 471) showed its window with `SWP_NOACTIVATE` only, reads its
pad through Windows.Gaming.Input, and nothing was in front at all
(`GetForegroundWindow()` NULL), so it ignored every key and tap. With
`env.MADEIRA_INPUT_FOREGROUND = 1` (opt-in), while no window at all is in
front, a process that polls its messages or receives an injected key or mouse
event makes its largest visible top-level window (at least 320x200) foreground,
at most every 250 ms; never while another window is in front. `[fg-none]` logs
the first activations.

## Windows.Gaming.Input

Wine's windows.gaming.input lists HID devices only, and counts one as a Gamepad
only when it is an XInput-compatible (winexinput) device, so on iOS a game
that reads its controller only through `Windows.Gaming.Input.Gamepad` sees
none: in XInput mode there is no HID device, in HID mode player 1 is a
DualSense, a raw game controller. With `env.MADEIRA_WGI_HOST_PADS = 1`
(opt-in), windows.gaming.input.dll (the matching willfaust/wine change;
`build/wine-pe/build-modules.sh windows.gaming.input` rebuilds it) also lists each connected XInput slot (through `XInputGetState`, i.e. the pads
described above) as a Gamepad, an Xbox 360 pad to the game; rumble goes back
through `XInputSetState`. The slots are polled twice a second for arrivals and
removals; the first poll runs before the game gets its first gamepad list.
A game reading both APIs could list a pad twice, so it is per game.
`[wgi-host]` lines log the switch and each slot change.

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
python3 tests/host/check-gamepad.py
python3 tests/host/check-touch-gamepad.py
python3 tests/host/check-control-presets.py
python3 tests/host/check-hidpad.py      # needs the wine submodule or WINE_SRC
python3 tests/host/check-pad-output.py
python3 tests/host/check-pad-assist.py
```

`wine/tools/tests/xinput-host.c` and `wine/tools/tests/wgi-host-pads.c` are
native Windows tests of the PE side (XInput, Windows.Gaming.Input) against a
synthetic host query; `wine/tools/tests/xinput-host.md` has the build lines.
`docs/CONTROLLERS_ANALYSIS.md` is the audit of the whole path and its
remaining gaps.

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
- Layouts: by default nothing is applied to a user with or without a controls
  file; the built-in loads from the menu (the overlay's button, and in a library
  session the Session menu's Controller layout row); switching away from unsaved controls
  asks first; create, edit with Done, relaunch and reload a custom layout;
  delete it; the layout menu and its dialogs respond anywhere on screen; each
  kill switch at `0`. With `MADEIRA_CONTROLS_XBOX_DEFAULT = 1`: a user without
  a controls file gets the built-in once and an existing file is kept.
- By default player 1 is not connected until a real source appears. With
  `MADEIRA_PAD_EARLY_SLOT = 1`, a game that enumerates XInput only at startup
  sees player 1 with touch controls shown or a controller paired before launch.

The fork's existing device history does not prove this isolated extraction.
