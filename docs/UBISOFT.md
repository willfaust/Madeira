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
with Windows services first; without them it did not open. It is slow, and
the first sign-in can take a while.

The games and Ubisoft Connect's processes together need more code buffers than
one JIT pool region holds, so the three lists turn on the split pool
(`pool-split = 1`; about 860 to 880 MB in two regions in the tested sessions).
If a session still runs out ("JIT pool exhausted" in the log), start it
again.

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
