# Hardware keyboard, mouse and trackpad

A Bluetooth or USB keyboard and mouse (or an iPad trackpad) reach Windows
programs as real key and mouse events: held keys with their own up events,
modifiers as keys, mouse motion, five mouse buttons and the wheel. The mouse
has a visible cursor, the program's own, and input reaches the program only
while it has focus. Everything is in `app/Madeira/HardwareInput.swift`, with the
cursor report in `app/Madeira/Winios/WiniosCursor.c` and
`build/win32u-unix/driver_ios.c`; controllers stay with `GamepadInput.swift`
(see [CONTROLLERS.md](CONTROLLERS.md)).

## Keyboard

`GCKeyboard` delivers one callback per physical key transition. UIKit's press
pipeline is not used: it reports modifiers only as flags on the next key and
re-delivers held keys as repeated presses.

- The key's USB HID usage is mapped to a Windows virtual key. Modifiers keep
  their side (`VK_LSHIFT`, `VK_RCONTROL`, ...); the wineserver derives the
  generic `VK_SHIFT`/`VK_CONTROL`/`VK_MENU` state from them. Numpad keys are
  sent as `VK_NUMPAD0`-`VK_NUMPAD9`/`VK_DECIMAL` (Num Lock on).
- The driver (`winios_drv_post_key` in `build/win32u-unix/driver_ios.c`)
  derives the scan code from the virtual key with Wine's US layout, so
  DirectInput and raw-input readers see the key's PC scan code. The dedicated
  arrows, Insert/Delete, Home/End and Page Up/Down carry their E0 prefix
  (`MADEIRA_NAV_KEYS_E0`, from the navigation-key change this builds on).
- While a hardware keyboard is connected, the text bridge (the keyboard button,
  `UIKeyInput` on the game view) ignores typed text, because the same presses
  already arrived raw.
- Known differences from a PC keyboard, all pinned by the host test: numpad
  Enter is sent as Enter (no E0); Print Screen maps to the SysRq scan code;
  the Japanese yen key shares the backslash key; keypad `=`, keypad comma,
  Select and the Japanese/Korean IME keys have no scan code in the US layout.
  Execute, Stop, Again, Undo, Cut, Copy, Paste and Find have no Windows virtual
  key and are not sent (the unmapped usage is logged).

## Focus

GameController reports the keyboard and mouse to the app whatever the user is
doing in it. Input reaches the program only while it has focus:

- **Always required:** the app is active and in the foreground, the game view
  is on screen, and nothing is presented over the app (a sheet, an alert, a
  picker, a menu shown as a view controller).
- **Keyboard:** no other text input is first responder, for example a text
  field in the app. The game view's own text bridge counts as the program's.
- **Mouse:** the pointer is over the game view (iPad, where UIKit reports the
  pointer's position); or, where it does not (iPhone AssistiveTouch), the last
  click or tap in the app's window landed on the game view; or pointer lock is
  on; or a button that went down on the game view is still held (a drag that
  leaves the view keeps the mouse until the button is released).
- **Right stick controls mouse:** the "always required" part.

On iPhone, AssistiveTouch turns a click into a tap at its cursor that arrives
within milliseconds of the GCMouse button report, before or after it. A button
press waits up to 60 ms for that tap and goes to the program only if the tap
landed on the game view, so a click on the app's own buttons does not also
click in the program.

When the program loses focus, everything it was told is held is released: a
key-up for each held key and a button-up for each held button. A key or button
pressed while the program did not have focus stays away from it until it is
released, even if focus comes back first. Focus is re-evaluated on each key and
button, when the pointer enters or leaves the game view, on taps, when the app
changes state, when a text field or text view starts or ends editing, when a
window becomes or stops being key, and four times a second while a keyboard,
mouse or controller is attached. Everything held is also released on a memory
warning and when a device disconnects.

Not detected: a menu that is neither presented as a view controller nor takes
first responder. Upstream's developer layout has none.

## Mouse and trackpad

Two paths carry the mouse; whichever delivers a delta first wins and is logged:

- **GCMouse** (iPad; iPhone with AssistiveTouch): raw HID deltas on a dedicated
  high-priority queue.
- **UIKit indirect pointer** (a pointer that GameController enumerates but that
  never reports): hover, pointer drag and scroll recognisers on the game view,
  and indirect-pointer touches read as buttons from `UIEvent.buttonMask`. This
  needs `UIApplicationSupportsIndirectInputEvents` in `Info.plist`, which this
  change adds. It is best effort: iOS clamps the unlocked pointer at the screen
  edge and has no API to re-centre it.

How motion reaches the program depends on the program's cursor:

- **The program shows a cursor, and UIKit reports the pointer's position**
  (iPad, pointer not locked; desktop sessions also follow reported cursor
  visibility): the program's cursor is put where the pointer is on the game view
  (absolute moves), mapped exactly as a touch is. The drawn cursor therefore
  sits under the hidden iOS pointer and never drifts away from it, and it stops
  at the edge where the pointer leaves the game view.
- **Otherwise** (the program hides its cursor, as mouse-look does; the pointer
  is locked; iPhone): motion is sent **relative** (`MOUSEEVENTF_MOVE` without
  `ABSOLUTE`). The wineserver adds it to its own cursor and raw input receives
  the delta before any `ClipCursor` clamping, so mouse-look never stalls at a
  screen edge.

Buttons are left, right, middle and the two side buttons
(`XBUTTON1`/`XBUTTON2`); continuous scrolling is summed into wheel notches of
120, vertical and horizontal.

Button sources are chosen per button. A GCMouse movement report alone does
not disable indirect-pointer clicks: buttons without raw reports can use the
fallback, while raw-reported buttons retain their holds without duplicate edges.
Raw button value callbacks and a 4 ms state sample share one edge history.
Sampling recovers missing callbacks without expiring a held button; it stops
while the app is inactive or no mouse is connected. Buttons held on attachment
or return to the app must be released before a new press is routed. The first
80 button callback/edge records and routing decisions are logged; diagnostics
also report sampled values every 10 s.
While raw mouse motion owns the relative route, game-surface touch packets
carry only positionless button/wheel events. Surface motion is suppressed,
including compatibility clicks reported as direct touches: their absolute
position must not warp the camera or mix with raw deltas during a drag.
Visible-cursor menus and touch-only sessions retain their original packets.
Desktop cursor visibility/position metadata also permits relative mouse-look
and automatic pointer lock when a desktop-hosted game hides its cursor.

**Gain:** relative mouse motion has its own sensitivity (`sensMouse`, default
1.0 = the device's deltas unchanged).

**iPad:** native mouse support does not require AssistiveTouch. If primary
clicks arrive as finger gestures, try disabling it under Settings >
Accessibility > Touch > AssistiveTouch and restart Madeira. The touch engine
resolves a short tap on release, which can post both button edges together;
games polling held state can miss that pulse. AssistiveTouch can consume the
primary button while secondary buttons still reach GameController (also
documented for [Citrix's generic mouse input](https://docs.citrix.com/en-us/citrix-workspace-app-for-ios/configure/peripheral-devices.html)).

**iPhone:** pointer devices are routed only through AssistiveTouch (Settings >
Accessibility > Touch > AssistiveTouch > On, then Devices). If a mouse is
enumerated but reports nothing for 10 s, the app shows this path once. With
AssistiveTouch, a click also arrives as a synthesised finger touch at the
AssistiveTouch cursor, which would snap the program's cursor there. While the
mouse is in use (a GCMouse delta in the last 2 s), touches on the game view
with no contact patch, or within 50 ms of a GCMouse button change, are
dropped. The decision is retained through release/cancellation, so a touch
admitted on press cannot lose its release when the raw mouse becomes active.
The first 30 classifications are logged. Set
`"ignoreTouchesWithMouse": false` in `Documents/madeira-input.json` to turn the
filter off. The on-screen touch controls are not filtered. AssistiveTouch's own
cursor cannot be hidden by an app; the program's drawn cursor is the one that
shows where a click lands.

## Cursor

The iOS pointer is hidden over the game view; what shows is the program's own
cursor:

- **Desktop session** (`MADEIRA_DESKTOP=1`): the compositor draws it, as
  before. On iPad it follows the pointer; with relative motion it follows the
  motion, and the touch trackpad continues from the same position.
- **A program on the game view** (no virtual desktop): nothing drew a Windows
  cursor before, because the finger is the pointer there. Now, while the mouse
  is in use, the app draws the program's cursor over the game view:
  - the driver sends the program's cursor image and hotspot (the same
    extraction as for the desktop compositor), whether the program hides its
    cursor (`ShowCursor(FALSE)`, `SetCursor(NULL)`), and where Wine's cursor is
    after every posted move and after `SetCursorPos`. It changes nothing the
    program sees, and does nothing until the app has enabled it;
  - the cursor is hidden whenever the program hides its own (mouse-look, or a
    program that draws its own cursor), while the mouse does not have focus,
    and after a finger touches the game view, until the mouse moves again;
  - until a program has reported a cursor, none is drawn.

## Pointer lock (iPad)

Pointer lock hides and pins the iPadOS pointer, so GCMouse deltas keep
arriving at the screen edges and the pointer cannot wander onto the app's own
buttons. iPadOS honours it only while Madeira is full screen, and only on the
GCMouse path (on the UIKit path locking would stop pointer delivery, so it is
refused). iPhone has no lockable pointer and shows no lock control.
The game root and app-owned overlay roots request the same preference without
forwarding it to SwiftUI child controllers. New hosting classes are installed
as roots change. The `[hwinput] system pointer lock` line reports both
`requested` and the scene's resolved `actual` state; `actual=1` is confirmation
that iPadOS granted it. A request alone is not proof of containment; see
[Apple's pointer-lock contract](https://developer.apple.com/documentation/uikit/uiviewcontroller/preferspointerlocked).

- **Automatic:** while a program on the game view hides its cursor (for half a
  second, so a program about to show one does not lock), the pointer is over
  the game view and the mouse is moving, the pointer is locked, as a PC game
  captures the mouse. The lock is released as soon as the program shows a
  cursor, when the program loses focus, and when the program stops draining
  the mouse (no report for 2 s while the mouse moves, e.g. it exited).
  `MADEIRA_POINTER_AUTOLOCK=0` turns this off.
- **By hand:** the lock button in the pointer settings or **Ctrl+Alt+P** on the
  keyboard (P is not sent to the program). Touch keeps working while locked, so
  the button is always a way out. Releasing an automatic lock by hand keeps it
  off until the program's cursor next changes visibility.
- The lock is released when the mouse disconnects.

## Right stick controls mouse

Optional and off by default (`padRightStickMouse`). While on and a controller
is connected, its right stick moves the mouse at a velocity (360 counts per
second at full deflection, scaled by the Relative pointer sensitivity; 15%
dead zone), in every pointer mode. It is meant for programs with no controller
support: a program that reads the controller itself (XInput or DirectInput)
already gets the right stick, and moving the mouse too would turn the camera
twice. XInput keeps receiving the stick either way.

## Settings

In the developer layout, open the pointer panel (the cursor button). Below the
key row it then shows, for attached devices only:

- the mouse sensitivity slider and, on iPad, the pointer lock button;
- the **Right stick controls mouse** toggle when a controller is connected.

The values are stored in `Documents/madeira-input.json` with the other pointer
settings: `sensMouse`, `padRightStickMouse`, `ignoreTouchesWithMouse`.

## Switches

Set these with `env.NAME = value` in `Documents/madeira.cfg`, or in the process
environment.

| Switch | Default | Effect |
| --- | --- | --- |
| `MADEIRA_HWINPUT` | on | `0`: no keyboard/mouse bridging, pointer recognisers, touch filter, drawn cursor, lock or right-stick mouse; the app behaves as before this change (the Info.plist key stays). |
| `MADEIRA_INPUT_FOCUS` | on | `0`: keyboard and mouse reach the program whatever has focus in the app (still not while the app is inactive). |
| `MADEIRA_DIRECT_CURSOR` | on | `0`: no cursor is drawn on the game view, motion stays relative there and the pointer never locks by itself; the driver reports nothing. |
| `MADEIRA_POINTER_ABSOLUTE` | on | `0`: the program's cursor never follows the pointer's position; all motion is relative. |
| `MADEIRA_POINTER_LOCK` | on | `0`: never lock the pointer; no lock button, Ctrl+Alt+P is sent to the program. |
| `MADEIRA_POINTER_AUTOLOCK` | on | `0`: lock only by hand (Ctrl+Alt+P or the lock button). |
| `MADEIRA_NAV_KEYS_E0` | on | `0`: the driver's previous extended-key flags for the navigation keys. |

## Logs

`[hwinput]` lines: the switches at start; keyboard and mouse connects and
disconnects with the device inventory (repeated 10, 30 and 90 s after start,
because stderr becomes the session log only when Wine starts); the mouse path;
keyboard focus changes, and mouse focus changes caused by the app's state;
the program showing or hiding its cursor; pointer lock changes with their
reason; unmapped HID usages; touch classifications; the right-stick mouse
turning on and off. With diagnostics on (the ladybug), also every mouse focus
change, pointer route changes, the first raw deltas, a 10 s delivery-rate line
and a 1 Hz activity line while input is moving or held. The driver logs each
new cursor image (`[winios] cursor set`), as in the desktop session.

## Validation

```sh
python3 tests/host/check-hardware-input.py      # needs swiftc, cc and the wine submodule (or WINE_SRC)
python3 tests/host/check-nav-keys.py
```

`check-hardware-input.py` compiles the pure part of `HardwareInput.swift` (key
map, mouse button edges, held-key diffing, motion carry, wheel notches, the
AssistiveTouch classifier, the desktop cursor clamp, the right-stick velocity,
the view-to-screen mapping against `mapTouch`'s arithmetic, focus gating of
held keys, click focus, the pointer route and the automatic lock) and the
driver's extended-key function, takes every mapped HID usage through Wine's US
layout, and compares the result with the scan code and E0 prefix a PC keyboard
sends. It compiles `WiniosCursor.c` and exercises it, including from four
threads at once. It also checks the driver's reports, the focus gating on every
path to the program, the app wiring, the switches and this document.

Device checklist:

- typing and held keys (WASD with Shift) in a program, with and without a
  text field of the app focused;
- the cursor on the game view: visible in a program's menus with its own
  image, hidden in mouse-look, under the pointer on iPad;
- mouse-look with the automatic lock on iPad in full screen, and its release
  when the program shows a cursor;
- clicking the app's own buttons with the mouse (the program gets nothing), on
  iPad and on iPhone with AssistiveTouch;
- the app going to the background with a key and a button held (both released);
- the wheel and all five buttons; Ctrl+Alt+P and the lock button;
- the iPhone AssistiveTouch hint and click filter;
- the right-stick mouse on and off;
- each switch at its non-default value.
