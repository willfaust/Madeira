# Controller path: analysis and gaps (2026-10-12)

What Madeira does with a controller today, end to end, what a competing iOS
port (NutsEmu, Wine 11.18 build 1382) does differently, and which gaps were
closed on branch `vulkan-stack` (uncommitted working tree, ml2115/ml2170/ml2171/ml2172).
`docs/CONTROLLERS.md` is the user-facing reference; this file is the audit.
Line numbers are for the working tree at the time of writing; `HEAD:` marks
the state before this change.

## Is "controller support is broken on every Madeira fork" true?

Not for the shipped design. XInput, which almost every PC game with
controller support reads, works the way NutsEmu describes its own: the app
reads Apple's GameController framework and Madeira's XInput DLLs read that
snapshot directly, never looking for HID devices (the "host pad" path,
`wine/dlls/xinput1_3/main.c:848` `host_pad_state`, tried before Wine's HID
discovery thread is ever started, `main.c:1003-1009`). Up to four pads, stable
slots, rumble, keystrokes and capabilities were already there.

What was true, and is the likely source of such reports:

1. **Games that only ask Windows.Gaming.Input saw no controller at all.**
   Wine's `windows.gaming.input` only lists devices that `winebus.sys`
   creates (`HEAD:wine/dlls/windows.gaming.input/main.c:70-75` enumerates
   WINEXINPUT/HID interfaces; `HEAD:provider.c:771` drops anything that is not
   `\\?\HID#`). A Madeira session runs no `winebus.sys`, so `Gamepad.Gamepads`
   was always empty. This is exactly the hole NutsEmu's patch
   `0066-gaming-input-xinput-pads.patch` fills. **Fixed (ml2171).**
2. **A game that disables XInput when it loses focus could read a pad at rest
   for the whole session.** `XInputEnable(FALSE)` zeroes the host state
   (`HEAD:wine/dlls/xinput1_3/main.c:812`); the port's startup window
   activation can leave such a game disabled while its window is in front.
   The pre-2026-10-01 fork diagnosed and fixed this (ml2114/ml2115, archived
   commits `2cc8e517` and wine `45459ca2b52`); the fix was never carried over
   to the current tree. **Ported (ml2115).**
3. **DirectInput-only games see no controller unless the user opts in**
   (`wine/dlls/dinput/joystick_ios.c:169`, `MADEIRA_DINPUT_PAD=1`, or the
   per-game "XInput and DirectInput" choice). Deliberate (a game reading both
   APIs would see two pads), unchanged here. See "Remaining gaps".
4. **GameInput (`gameinput.dll`) is a stub** (`wine/dlls/gameinput/gameinput.c:31-35`,
   `GameInputCreate` returns `E_NOTIMPL`). Unchanged; see "Remaining gaps".

## End-to-end path

```
GCController (GameController.framework)
  -> app/Madeira/GamepadInput.swift          sample() at 250 Hz + change callbacks (queue "madeira.gamepad")
       refreshControllers() :260             4 slots, first free slot (:286), disconnect never renumbers;
                                             reconnect-as-new-object back to slot 0 (:308, ml2172)
       sample() :368                         buttons/triggers/sticks -> struct winios_gamepad, touch merge
       publishBattery() :465                 (new, ml2170) GCDeviceBattery -> XInput type/level, 1 Hz
  -> app/Madeira/Winios/WiniosGamepad.c      mutex-protected per-slot snapshot, packet numbers,
                                             vibration store, battery store (new)
  -> build/win32u-unix/driver_ios.c          ios_gamepad_query() :2670, the body of
                                             NtUserCallTwoParam_GetGamepadState (wine/include/ntuser.h:1233)
       op 0 State, op 1 Caps, op 2 SetVibration, op 3 Foreground (ml2115), op 4 Battery (ml2170)
  -> wine/dlls/win32u/sysparams.c:7635       dispatch (64-bit); wine/dlls/wow64win/user.c:1903 32-bit thunk
                                             (pointer translation only, every payload is pointer-free)
  -> PE readers in the game process:
       xinput1_1/1_2/1_3/1_4/xinputuap        (one source, wine/dlls/xinput1_3/main.c; xinput9_1_0 forwards to 1_4)
       dinput/dinput8                         joystick_ios.c, opt-in, slot 0 only
       windows.gaming.input                   (new, ml2171) host pads as Gamepads
Output: XInputSetState / WGI Vibration -> op 2 -> winios_gamepad_set_vibration
  -> app/Madeira/PadOutput.m:466             CoreHaptics on the slot's GCController (left/right handle)
```

The opt-in HID mode (`env.MADEIRA_PAD_MODE = hid`) is a separate path: player
1 becomes a DualSense or generic HID device served by the wineserver
(`build/wineserver/hidpad_ios.c`), read through hid.dll/setupapi, DirectInput's
HID joystick and Windows.Gaming.Input's raw controllers; player 1 then leaves
XInput (`GamepadInput.swift:452`), slots 1-3 stay XInput.

## XInput API by API

| API | Host-pad behaviour | Data source |
| --- | --- | --- |
| `XInputGetState` / `GetStateEx` | Live state; Guide only in Ex (`main.c:1024`, `:1039`) | GameController buttons/axes, full signed range, no app dead zone (`GamepadInput.swift:368-408`) |
| `XInputGetCapabilities(Ex)` | Gamepad/gamepad subtype, every button and axis bit (0xf3ff, 16-bit thumbs), motors 0xff while rumble is on, VID/PID 045e:028e (`driver_ios.c:2695-2727`, `main.c:1362`). **New:** `XINPUT_CAPS_WIRELESS` while the pad runs on its battery (`driver_ios.c:2725`) | win32u |
| `XInputSetState` | Motors to the slot's pad through CoreHaptics (`main.c:966`, `PadOutput.m:466`); remembered across `XInputEnable`, stopped at process detach (`main.c:909`) | app |
| `XInputEnable` | FALSE silences motors and zeroes the state; **new (ml2115):** while the caller owns the foreground window the disable is taken as stale and the live state is returned (`main.c:827`, `driver_ios.c:2637`) | win32u foreground window |
| `XInputGetKeystroke` | Full edge detector over the host state (buttons, triggers, stick directions), per-index edge memory (`main.c:1142`, `:1234`); `ERROR_EMPTY` when idle | host state |
| `XInputGetBatteryInformation` | **Before:** `BATTERY_TYPE_UNKNOWN` + `BATTERY_LEVEL_EMPTY` for every host pad (`HEAD:main.c:1245-1246`), which can trigger low-battery prompts. **Now (ml2170):** discharging pad = `NIMH` with EMPTY/LOW/MEDIUM/FULL at 5/20/70 %; charging or full = `WIRED`/`FULL` (what Windows shows for a pad on a cable); no battery info = `UNKNOWN`/`FULL`; touch-only player 1 = `WIRED`/`FULL`; headset queries = `DISCONNECTED` (`main.c:1301-1330`, `GamepadInput.swift:174`) | GCDeviceBattery |
| `XInputGetDSoundAudioDeviceGuids` | `ERROR_NOT_SUPPORTED` for a connected pad (no audio on iOS pads) | - |

Pads: four slots (`WINIOS_GAMEPAD_MAX`, `GamepadInput.swift:212-213`), each
GameController extended profile takes the first free slot and keeps it until
it disconnects; the touch layout merges into slot 0. `MADEIRA_PAD_EARLY_SLOT=1`
reserves slot 0 for games that enumerate once at startup. New (ml2172): a
player 1 that GameController reports as a new controller before the old one
leaves is moved back from slot 1-3 to slot 0.

32-bit games: the same XInput/WGI source is built for i386 and reaches win32u
through wow64win's pass-through thunk (`wow64win/user.c:1903`), so every op,
including the new ones, works without a wow64win rebuild. The i386 DLL farm
lives only in the WSL workspace (`app/Madeira/i386-windows` is gitignored).
Its xinput1_1-1_4 there were built from the archived fork (they carry the
ml2114/ml2115 strings and its op 3 foreground query; `xinputuap` is older and
lacks rumble). Op 3 keeps that number and ABI on purpose, and the battery op
is 4, so those older DLLs keep working against the new win32u.

## What NutsEmu does differently

From its developer's description and the patch drop
(`wine-11.18-nutsemu-1382/patches/wine/0066-gaming-input-xinput-pads.patch`;
the replacement XInput DLL itself is not in the drop):

- **Own XInput DLL instead of Wine's.** Functionally the same as Madeira's
  host-pad path (Wine's DLL with a host query in front of the HID code). Both
  skip HID; both do 4 pads, rumble and (now) battery.
- **windows.gaming.input reads XInput.** Patch 0066 makes each connected XInput
  slot a WGI provider by `LoadLibrary("xinput1_4.dll")` + `XInputGetState`,
  polled once a second from WGI's monitor thread, typed Gamepad, VID/PID
  045e:02ea, rumble through `XInputSetState`. Madeira's version (written
  independently, `provider.c:75-160`, `:988-1072`) reads the host slots
  directly through the same win32u query (no xinput1_4 load, so a game's
  `XInputEnable(FALSE)` does not silence WGI), uses the Xbox 360 identity
  (045e:028e) that XInputGetCapabilitiesEx already reports so a reader that
  skips XInput-capable WGI devices recognises the pad, reports a released pad
  for a slot that just disconnected, stops motors on the last release and at
  process exit, and has a kill switch.
- Nothing in the drop covers DirectInput or GameInput either.

## Changes in this round

| Tag | What | Files | Kill switch |
| --- | --- | --- | --- |
| ml2170 | XInput battery from GCDeviceBattery; wireless caps flag | `GamepadInput.swift`, `Winios/WiniosGamepad.{c,h}`, `build/win32u-unix/driver_ios.c`, `wine/include/ntuser.h`, `wine/dlls/xinput1_3/main.c` | `env.MADEIRA_XINPUT_BATTERY = 0` (app publishes nothing; xinput answers as before) |
| ml2171 | Host pads as Windows.Gaming.Input Gamepads/RawGameControllers with rumble | `wine/dlls/windows.gaming.input/{provider.c,main.c,private.h,Makefile.in}` | `env.MADEIRA_XINPUT_WGI = 0` |
| ml2115 | Stale `XInputEnable(FALSE)` ignored while the game owns the foreground window; capped `[xinput] ml2114` log lines (XInputEnable calls, first query per index) | `wine/dlls/xinput1_3/main.c`, `build/win32u-unix/driver_ios.c`, `wine/include/ntuser.h` | `env.MADEIRA_XINPUT_ENABLE_FOREGROUND = 0` |
| ml2172 | Player 1 back to slot 0 when GameController reports a reconnect as a new controller first | `GamepadInput.swift` (`refreshControllers`) | `env.MADEIRA_XINPUT_SLOT0_RECONNECT = 0` |

Everything is behind the XInput host path: with `env.MADEIRA_XINPUT = 0` the
app publishes no slots, every op answers 0, and all four features are inert.
On a stock (non-Madeira) win32u every new op also answers 0.

Tests: `tests/host/check-gamepad.py` (battery store, op 4, wireless flag,
op 3 and its switch), `wine/tools/tests/xinput-host.c` (published/unknown
battery, headset, stale disable), `wine/tools/tests/wgi-host-pads.c` (new:
listing, rescan, removal, type/counts/ids, XUSB reading, D-pad, vibration,
exit stop, kill switch). All pass on this PC; none of it is device-tested.

## Remaining gaps

1. **DirectInput is opt-in and single-pad** (`dinput/joystick_ios.c:169`,
   `:460`), with no force feedback (`:71`). A DirectInput-only game needs the
   per-game "XInput and DirectInput" choice. Auto-enabling it for processes
   that never load xinput would need a reliable "this game does not read
   XInput" signal; not attempted.
2. **GameInput is a stub** (`gameinput/gameinput.c:31-35`). Newer GDK-based
   games that read controllers only through GameInput see nothing. A host-pad
   `IGameInput` (devices, `GetCurrentReading`, gamepad state, rumble) is a
   multi-day job.
3. **Trigger rumble** (WGI `LeftTrigger`/`RightTrigger` motors, the Xbox One
   impulse triggers) is dropped: the transport carries two motors per slot.
   GameController exposes trigger haptic localities on some pads; it would need
   a 4-motor op and PadOutput support.
4. **No raw input (`WM_INPUT`) or `GetRawInputDeviceList` entry for XInput
   pads**, so readers that correlate XInput with raw-input devices (SDL's
   RAWINPUT backend) fall back to plain XInput; harmless in practice.
5. **Slot 0 at session start.** The reconnect case is handled (ml2172), but
   the archived fork's other slot-0 rules (move a lone pad from another slot
   into an empty slot 0 at session start; publish slot 0 at rest while a pad
   is paired but has not reported input) were not ported. The existing opt-in
   `MADEIRA_PAD_EARLY_SLOT` covers part of the second.
6. **i386 farm provenance.** The workspace i386 xinput DLLs predate the reset;
   the rebuilt ones (this round, `app/Madeira/i386-windows/` in the checkout,
   gitignored) should replace them in the workspace before the next IPA.
7. The aarch64-windows farm also ships a `windows.gaming.input.dll`; it was not
   rebuilt (only ARM64-native processes would load it).
