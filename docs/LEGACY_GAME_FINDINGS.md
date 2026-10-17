# Legacy game findings on an M1 iPad

These are observations from Madeira 0.1.3 on an M1 iPad Air running iPadOS
26.6, collected on 2026-10-17. They are not a compatibility guarantee for
current main. Tests used locally owned games; no game files are included.

## Age of Empires II: Forgotten Empires 2.2 (32-bit)

The actual game is `age2_x1/age2_x2.exe`, rather than the FE installer/launcher.
A separate, byte-identical executable copy in the game root, with arguments
`GAME=age2_x2 NOSTARTUP`, selected the FE mod while skipping intro playback.
The tested executable SHA-256 was
`55780472c174a56bc424816b9ba59d6a2cb40157f38b4c9ab3c42de73701f9bb`.

The failures were sequential, not a single configuration issue:

1. `DPLAYX` initialization failed with `c0000142`. Its fixed mapping request
   at `0x50000000` returned error 87. A game-local diagnostic DLL that
   requested any address passed initialization. **This is not proposed as a
   general DirectPlay fix:** cross-process absolute pointers and multiplayer
   behavior need investigation.
2. `wow64_NtUserCreateWindowEx` rebased class atom `0x8002` to `0x400008002`.
   The host faulted in `wine_dbgstr_wn`. Preserving the atom in an equivalent
   ARM64 binary edit removed this fault. The source change using the existing
   helper is [Wine fork PR #47](https://github.com/willfaust/wine/pull/47).
3. The GDI/EULA path needed the desktop compositor. Builtin DirectDraw then
   failed creating an OpenGL context. Game-local
   [cnc-ddraw 7.1](https://github.com/FunkyFr3sh/cnc-ddraw/releases/tag/v7.1.0.0),
   with the GDI renderer, rendered the game.
4. Intro MCI playback requested missing `ir50_32.dll`. `NOSTARTUP` skipped it.

The final test configuration used native-then-builtin `dplayx` and `ddraw`,
`MADEIRA_DESKTOP=1`, `renderer=gdi`, `windowed=true`, `fullscreen=true`,
`border=false`, and a 1024x768 fit display. Temporary window/version proxy
instrumentation was removed from the override list before gameplay testing.
A missing export in that temporary proxy caused an intermediate `80000100`
exception; that particular exception was an instrumentation error.

**Observed success:** started an Incas standard match, selected units,
trained a villager (population 4 to 5), saved, then cold-loaded the saved
match. A later saved state loaded at game time 26:27 with population 7/35.
Multiplayer, a complete campaign, and all resolutions were not tested.

Traditional Chinese menus and in-game text rendered using the
[official FE language pack](https://www.forgottenempires.net/age-of-empires-2-hd-the-forgotten/language-support),
its Traditional Chinese download, a CJK font (Noto Sans CJK TC), Big5 codepage
data, and Chinese font replacement names in Wine. Font/locale changes do not
upgrade the game's bitmap artwork. An integer-sized 800x600 menu produced
large margins on this iPad; restoring fullscreen scaling filled the display.

## STONKS-9800 (64-bit GOG build)

The original executable SHA-256 was
`3c28d65ae4ea6b0b9ff28771fc0d64b7549f60c92d98b2eca6c2d4bbde9470b4`.
It first failed loading `gdiplus` (`c0000135`). A trusted game-local copy from
the owner's working CrossOver bottle passed that dependency.

It then read `0x8` at guest RIP `0x1404a3896` (`c0000005`). Inspection found
an uninitialized C++ local-static hash table: its guard was zero, and the
failing thread's TLS epoch was zero, whereas the executable TLS template
and another thread held `INT_MIN`. The signed `JG` initialization guard
skipped initialization when both values were zero.

A separate, hash-guarded diagnostic executable changing this branch to `JGE`
passed the crash. Two additional instructions bypassed a window-centering
path that otherwise moved the game off-screen. These are **game-specific
workarounds**, not a Wine/FEX TLS fix. The component responsible for the TLS
value has not been established; tracing the epoch's initialization/writes
remains the useful engine investigation.

**Observed success with the diagnostic copy:** completed registration,
entered Free Mode gameplay, saved to an unused slot, terminated Madeira,
re-enabled JIT, and loaded the same slot. The expected balance remained
743105. The original executable and pre-existing saves were preserved.

A subsequent cold-launch regression after the FE test IPA/font/locale changes
loaded the same slot and reached the home screen in Traditional Chinese. The
built-in language selector used index 5 in this build. Disabling the CRT
effect (`crt=0`) visibly sharpened text while retaining 1280x720 fullscreen.
The desktop compositor left a narrow desktop strip below the D3D game.

Vector/memcpy TSO settings did not change the original crash. `FEX_O0=1`
failed earlier with an invalid-instruction exception at a different guest
RIP. None of those diagnostic environment switches was retained.

## Test discipline and remaining limits

- Installed the class-atom test IPA through SideStore with its JIT extension
  retained. The host regression test in the Wine PR exercises source-level
  argument conversion. A complete source rebuild of that PR was not run;
  device evidence used an equivalent edit to the bundled ARM64 DLL.
- Recreated prefix DLL symlinks can overwrite manual prefix substitutions on
  launch. Use a game-local override or an explicitly identified test build;
  verify the loaded image rather than assuming a copied file was used.
- Short touch taps worked in FE. Long presses during automation sometimes
  left a touch-down state without the expected release. A fresh process and
  short taps restored control. This observation needs a minimal input repro.
- A startup logo is insufficient validation. Reach gameplay, exercise input,
  save to a new slot, then cold-load it after a fresh JIT attachment.
- JIT dump files grew to hundreds of MB during debugging. Stop the producer
  before removing owned dumps; free space can otherwise disappear again.

This report and the linked source/test contribution were prepared with AI
assistance. No FEX-generated source changes are proposed.
