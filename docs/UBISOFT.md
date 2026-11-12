# Ubisoft Connect

Ubisoft's PC games start through Ubisoft Connect, Ubisoft's launcher: a Steam
copy of Far Cry 3 or Far Cry 4 hands over to it, and its game starter starts
the game again. Madeira runs the launcher itself, in the game's Wine session,
as Windows would. Sign-in, ownership and licences are not changed or skipped:
the launcher signs in to Ubisoft's servers and starts the game as it does on
Windows. Madeira adds what the launcher and the games need from Windows that
Wine on iOS does not otherwise provide.

Tested with Ubisoft Connect 175.0.13393 and the Steam copies of Far Cry 3 and
Far Cry 4, started through Madeira Dock.

## Playing

1. Install the game in Madeira Dock and start it there. Its Steam install
   script runs Ubisoft Connect's installer once; for the next Ubisoft game the
   Dock sees the launcher in the prefix and records that step as done.
2. The game hands over to Ubisoft Connect. Sign in to your Ubisoft account the
   first time; the launcher then starts the game. The game's recommended
   settings apply on first sight (Game details › Reset to Recommended brings
   them back).
3. In Far Cry 3, set Overall Quality to Custom before changing the graphics
   options: the Optimal preset reads the detected GPU.

If a session runs out of code buffers ("JIT pool exhausted" in the log), start
it again.

Ubisoft Connect can also be added to the library on its own
(`C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\UbisoftConnect.exe`),
for example to sign in before a game. Its list starts it in the Wine desktop
with Windows services first, which it needs to open. The first sign-in can take
a while. Start games from their own entries: a game started from Ubisoft
Connect's window runs with Ubisoft Connect's settings, its code buffers held to
16 MB.

## Recommended settings

| Line | Lists | What it does |
| --- | --- | --- |
| `pool-split = 1` | all three | The game and Ubisoft Connect's processes together need more code buffers than one JIT pool region holds. |
| `env.MADEIRA_POOL_CODE_FOREGROUND = 1` | all three | Programs outside the launched program's folder (the launcher, its helpers, Steam's client) get code buffers of at most 16 MB, so they cannot fill the pool before the game starts. |
| `env.MADEIRA_POOL_CODE_FOREGROUND_PROGRAM = upc.exe` | Ubisoft Connect | Launched on its own, only the client keeps its code-buffer budget; its UplayService.exe and UplayWebCore.exe helpers, in the same folder, are held to 16 MB. |
| `env.MADEIRA_WOA_RECHECK = 1` | all three | Infinite waits on an address in 32-bit programs re-check every second, so a lost wake-up cannot stop Ubisoft Connect's browser on a free lock. |
| `env.MADEIRA_SLEEP_KERNEL_APC = 1` | Far Cry 3, Far Cry 4 | I/O completions run during a non-alertable sleep, as on Windows: Far Cry 3's read of the launcher's pipe completes while the game only sleeps. |
| `env.MADEIRA_KILL_REAP = 1` | Far Cry 3, Far Cry 4 | The game starter ends a suspended copy of the game with TerminateProcess; its code buffers, window and handles are released as its exit would release them. |
| `env.MADEIRA_X64_HOOK_ZONE = 1` | Far Cry 4 | 16 MB of free address space directly above each 64-bit program's ntdll, where FC64.dll puts its hook trampolines ("Error at hooking" without it). |
| `env.MADEIRA_X64_IMAGE_NOCOPY = 1` | Far Cry 4 | The game's pure-x64 DLLs and program run from their loaded images instead of JIT-pool copies, which leaves the pool for code buffers. |
| `env.MADEIRA_PAD_MODE = xbox360` | Far Cry 4 | Player 1 stays on XInput and is also the HID device Windows lists beside a wired Xbox 360 controller; the game reads XInput only once it finds one (see [CONTROLLERS.md](CONTROLLERS.md)). |
| `env.MADEIRA_WOW_HOLD_WINDOWS = 0` | Far Cry 4 | No 4 GB guest window is held for the 32-bit program in the game's folder, which never runs: the session's 64-bit processes need that room (with it held, the game's audio DLL can fail to load and the game crashes). |
| `dxmt = dxgi.customVendorId=1002;dxgi.customDeviceId=7340` | Far Cry 3 | The game's Direct3D 11 renderer sees an AMD adapter; with Apple's id it draws dark rectangles over the 3D scene (a vendor-dependent clear, DXVK issue 3758). |
| `env.MADEIRA_AUDIO_LEAD_MS = 0` | Far Cry 3, Far Cry 4 | No audio lead: the games' FAudio voices break up with it. |

Each list also turns the `[ec-hook]` reporter off (`env.MADEIRA_EC_HOOK_TRACE = 0`)
and ends with the defaults it was tested with.

These need no line, and are on by default:

- `env.MADEIRA_SELF_WRITE`: a program's `WriteProcessMemory` into its own
  memory is done in ntdll, page by page as on Windows. Ubisoft Connect's
  `upc.exe` and Far Cry 4's FC64.dll install their hooks this way. With `0`
  the write goes to the wineserver, which has no task port for the process
  and refuses it, and both programs end with 0xdeadc0de.
- `env.MADEIRA_UBI_CEF`: `upc.exe`, the browser process of Ubisoft Connect's
  32-bit Chromium (CEF 135), gets the switches that keep Chromium to few
  processes (`--in-process-gpu`, `--renderer-process-limit=1` and others, V8
  `--jitless`), and a two-byte in-memory change to its libcef.dll keeps them,
  since that build otherwise discards its command line. With Chromium's
  defaults the launcher needs more 32-bit windows than the session has. `0`
  turns both off.
- Madeira Dock, for a game whose install script runs Ubisoft Connect's
  installer:
  - the installer is recorded as done when `UbisoftConnect.exe` or `upc.exe` is
    already in the prefix (`env.MADEIRA_INSTALL_SKIP_LAUNCHER = 0` runs it for
    every game);
  - the launcher's `InstallDir` value, which its installer leaves out, is
    written where the prefix has none; without it the games report the launcher
    as not installed (`env.MADEIRA_INSTALL_LAUNCHER_REGISTRY = 0` writes none);
  - the session gets `MADEIRA_APC_BUSY_QUEUE=1`, without which the game starter
    never starts the play session.
- Wine's dxdiagn: a missing DirectShow device enumerator leaves its section
  empty instead of failing `IDxDiagProvider::Initialize` (Far Cry 4's hardware
  detection).

## Not supported

- Ubisoft Connect's in-game overlay: the game starter's injection does not take,
  and the game runs without it.
- Far Cry 4 offline: with the Dock's offline logon the game ends at its own
  "Logging in" step. Ubisoft Connect's offline mode is untested.
- A libcef.dll build the table in `ios_ubi_cef_patch` does not list: the log
  names it, and the launcher's browser runs with Chromium's defaults (more
  processes, which may not fit in the session's 32-bit windows). Adding a build
  is one table row once its site is checked.
- Other Ubisoft games are untested.

## Source

- `build/ntdll-unix/virtual_ios.c`: `ios_self_write`; the hook zone
  (`ios_hook_zone_*`, requested from `loader_ios.c`); `ios_ubi_cef_patch`; the
  code-buffer rules (`ios_pool_fg_class`, the tail-carve merge and cut);
  `mmap_add_reserved_area`, which keeps a FEX or thin reserved area whole when
  a generic range bridges it.
- `build/ntdll-unix/process_ios.c`: the browser's command line
  (`ubi_cef_kind`, `ubi_cef_cmdline`) and the teardown of a process another
  one ends (`env.MADEIRA_KILL_REAP`).
- `wine`: `dlls/ntdll/unix/sync.c` (`env.MADEIRA_SLEEP_KERNEL_APC`),
  `dlls/ntdll/sync.c` (`env.MADEIRA_WOA_RECHECK`) and `dlls/dxdiagn`.
- `build/hidpad/hidpad_ids.h`, `build/hidpad/hidpad_reports.h`: the Xbox 360
  controller identity and its report.
- `app/Madeira/DockInstallers.swift`: `sharedLauncherInstallers`.
- `app/Madeira/GameRecommendations.swift`: the three lists.

## Checks

    python3 tests/host/check-self-write.py
    python3 tests/host/check-x64-hook-zone.py
    python3 tests/host/check-reserved-area-merge.py
    python3 tests/host/check-ubi-cef.py
    python3 tests/host/check-kill-reap.py
    python3 tests/host/check-pool-carve-merge.py
    python3 tests/host/check-pool-code-policy.py
    python3 tests/host/check-sleep-kernel-apc.py
    python3 tests/host/check-woa-recheck.py
    python3 tests/host/check-hidpad.py
    python3 tests/host/check-dock-installers.py
    python3 tests/host/check-game-recommendations.py

They compile the production code on the host (ASan/UBSan) against models of
what it calls; the Swift parts need `swiftc`. None of them runs a game.
