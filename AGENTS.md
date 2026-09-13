# AGENTS.md

Repository memory for Madeira. Read this before touching the JIT path — most of
the traps below have already shipped a bug once.

## What this is

Madeira runs Windows PC games on a non-jailbroken iPhone. Wine (ARM64EC), FEX-Emu
(x86-64 → ARM64) and DXMT (D3D11 → Metal) run as a single Mach process, with
wineserver as a thread rather than a separate process. It is sideloaded — JIT
requires a debugger to attach, so it cannot go through the App Store.

## Layout

- `app/Madeira/` — the iOS app (Swift + the C/C++ JIT and Wine bridge code).
- `app/Madeira/AppLayout.swift` — the tooling-vs-fullscreen decision, pure and
  unit-tested. Read the header before touching `ContentView`'s body.
- `app/Madeira/GamepadMap.swift` — controller → key/mouse mapping, pure and
  unit-tested. `app/Madeira/GamepadBridge.swift` is the only GCController code.
- `app/Madeira/VirtualPad.swift` — the on-screen PlayStation-style pad, as pure
  layout and touch-state functions. `app/Madeira/VirtualPadView.swift` is the
  SwiftUI window that draws it and the gestures that drive it.
- `app/Madeira/SettingsModel.swift` — the settings struct, the resolution
  policy and the engine-switch catalogue; pure and unit-tested (`test-app-ui`).
  It renders override files, it does not write them.
- `app/Madeira/SettingsStore.swift` — persistence (`UserDefaults`, JSON) and
  the file writing. This is the ONLY place settings reach the engine.
- `app/Madeira/MadeiraUI.swift` — the theme and `HomeView`.
- `app/Madeira/SettingsView.swift` — the settings screen, a front-end for the
  engine's existing `madeira-*.txt` override channel.
- `app/Madeira/madeira-jit.js` — the debugger-side JIT protocol script.
- `app/Madeira/JITAllocator.c` / `.h` — pool allocation, dual-map, BRK protocol,
  no-footprint (Jetsam) handling, trap handler.
- `app/Madeira/FEXBridge.mm` — the separate 64 MB FEX JIT pool.
- `FEX/`, `wine/`, `research/dxmt` — submodules pointing at iOS forks. Upstream
  clones will not build.
- `build/*/` — native build scripts and prebuilt test binaries
  (`proc-tests`, `x64-tests`, `dxmt-tests`, `net-tests`); there is no
  single top-level build.
- `tools/` — pre-release gates (see below).
- `research/` — investigation notes keyed by `ml###` revision numbers.

## Conventions

- Comments and commit messages reference `ml###` revision ids (e.g. `ml345`).
  Keep the highest id monotonic when adding a substantive change note.
- Two JIT pools exist and are unrelated: the app's ~896 MB pool via
  `jit26_prepare_region` (JITAllocator.c) and FEX's 64 MB pool in
  `FEXBridge.mm`. A fix to one does not affect the other.
- Credit upstream correctly: FEX-Emu prohibits AI-generated contributions (see
  `README.md` and `CONTRIBUTING.md`). Only the Madeira tree is yours to change
  from the app side.

## The embedded JIT script trap (read this twice)

`StikJITHelper.swift` ships `madeira-jit.js` as a **base64 string literal**
(`scriptBase64`). `madeira-jit.js` is NOT a member of the Xcode target, so the
literal — not the file — is what StikDebug actually runs. Editing the `.js` and
rebuilding changes nothing until you regenerate the literal:

```sh
tools/jit-script-sync.py --write    # regenerate literal from madeira-jit.js
tools/jit-script-sync.py            # check (exit 1 if drifted)
```

This is enforced by `tools/check-all.sh`, which is the pre-release gate. Run it
before shipping. (Same idea as `tools/check-prefix-template.sh`, which exists
because the prefix template once shipped absolute host symlinks, and
`tools/check-xcodeproj.py`, which exists because a source file that is not
registered in the Sources phase is silently not part of the app — invisible on
any machine that cannot open Xcode. `tools/test-device-capabilities.sh` covers
the JIT pool and override-parser policy; see Build / test constraints.)

## JIT lifecycle (app JIT pool, sized to the address space)

1. `jit_check_debugged()` reads `CS_DEBUGGED` via `csops`.
2. `enableJIT` opens StikDebug with the script in the URL; `pollForJIT` waits
   for the flag (bounded — do not make it unbounded again).
3. `allocatePool` pre-pins low address space so the pool lands above
   ~0x119000000 (FEX dispatcher encoding is address-dependent), allocates via
   `brk #0xf00d` (`x16=1`), and applies the no-footprint ledger.
   **It also measures the hole before it asks for it (ml793).** Pinning only
   moves the address-space frontier; it does not guarantee that a hole the pool
   fits in exists there. A 7GB device derives a 1760MB pool from
   `recommendedPoolMB()`, the contiguous space below the guest window is about
   a gigabyte, and the kernel's first fit then lands in 0x7000000000 — the
   guest x86-64 window, where executing pool code hangs the first call. The
   retry loop that used to sit here re-rolled the same address three times
   (ml595) and then aborted, which is a hard crash on launch, not a slow start.
   The pool size is therefore whatever the measured hole allows, floored at
   256MB, and everything downstream (the RW alias, the ledger,
   `WINE_IOS_JIT_SIZE`) uses the size that was allocated rather than the size
   that was requested.
   **It never exits the process (ml794).** The old path scheduled an `exit(0)`
   when every placement failed, so a launch that could not place the pool
   closed the app — the user sees that as "the desktop auto-shuts down", with
   no way to tell it apart from a crash. Failure now returns `nil`, the run
   sequence reports it through `RunStatus`, and the home screen shows it with a
   retry hint. Placement depends on the memory layout at that instant, so a
   second attempt is genuinely worth making. The size ladder is
   `[requested, requested/2, requested/4, floor]`, largest first, with a pause
   between waves — the waves are separated in time because the layout is not
   static, and a run that cannot place a pool now can place one a moment later.
4. `detachDebugger()` emits `brk #0xf00d` with `x16=0`. It is **one-shot** on
   purpose: the early-detach and post-Wine paths both call it, and the second
   call would trap into our own task-level exception port. `enableJIT` re-arms
   it for a fresh attach. Do not replace this with a permanent C-level flag —
   `JITAllocator.c` cannot tell a re-attach from a duplicate call.

### JIT is two requirements, and only one of them is "is JIT on" (ml801)

`jit_check_debugged()` (CS_DEBUGGED) and `isDebuggerAttached()` (P_TRACED) are
different facts, and a launch needs both:

- The pool is allocated with `brk #0xf00d`, which is answered by a LIVE
  debugger. With CS_DEBUGGED set but nothing attached, our own SIGTRAP handler
  skips the instruction, the allocation comes back zero, and the failure
  surfaces deep inside `allocatePool` as a placement complaint that has nothing
  to do with the cause.
- `detachDebugger()` is deliberate, so the second launch starts detached. That
  is the normal state after any successful run, not a fault.

`runWineFullSequence` therefore pre-flights both: it refuses to launch with
CS_DEBUGGED clear (`RunStatus.fail`), and re-attaches silently when only
P_TRACED is missing (`StikJITHelper.enableJIT`, then retries once —
`reattachAttempted` bounds the loop). The home screen reports CS_DEBUGGED,
because that is the only part the user controls, so "JIT enabled" no longer
flips to "off" the moment they enter the desktop. `isDebuggerAttached()` lives
in `EntitlementChecker.swift` and reads `kinfo_proc.kp_proc.p_flag & P_TRACED`.
Note that `EntitlementChecker.swift` needs `import Combine` for `JITState`.

### Stop-loop invariants (`madeira-jit.js`)

The script is the ONLY thing servicing traps while StikDebug is attached. Its
comment header is authoritative; the short version:

- Only genuine `BRK` instructions are skipped (`pc+4`). Everything else that
  escalates to us is a real fault and is handed back to the process as a unix
  signal — never blindly `pc+4`, that silently corrupts threads (ml344/ml345).
- Soft-signal stops (`metatype 5`, `EXC_SOFT_SIGNAL`) forward the original
  signal from `metadata[1]` and are never guarded.
- Never detach on a fault. With the StikDebug window still open the task
  exception port stays registered but unserviced, parking threads forever
  (ml345). Kill the inferior instead — a visible death beats a parked thread.
- Every reply is parsed defensively (`parseHexBigInt`); a `_M` error string must
  never be turned into a pool base address. An uncaught throw ends the script,
  which StikDebug treats as session teardown — JIT vanishes with no crash
  report. Logs are budgeted (`ulog`) because each `log()` drives a SwiftUI
  update and scene-update stalls are what the StikDebug watchdog kills.

## Is performance pinned to A15? (asked; answer verified — do not re-investigate blindly)

No. The gameplay translator does not use the hardcoded A15 block. Evidence:

- `FEXBridge.mm` ~430-450 builds a `FEXCore::HostFeatures` with A15 values
  (`CPUMIDRs.resize(8, 0x611F0250)`, `DCacheLineSize = 64`, ...). That block is
  real but its scope is tiny: this FEXCore instance only runs the in-app self
  test (`fex_test_execute()` → an embedded x86-64 ELF that returns 42) and
  allocates the shared pool. It never translates the game. The only things it
  publishes to the guest are `MADEIRA_JIT_WRITE_OFFSET` and `MADEIRA_FEX_ARENA`.
- The game is translated by `app/Madeira/arm64ec-windows/xtajit64.dll`, a
  separate FEXCore. Its symbols include
  `FEX::Windows::CPUFeatures::FetchHostFeatures(bool, HostTypeEnum)`, which in
  upstream FEX reads the live CPU (`ReadRegU64(Key, "CP 4000")` per core into
  `CPUMIDRs`, plus `mrs ctr_el0` / `mrs midr_el1`). Verified the DLL contains no
  `0x611F0250` bytes and no fixed MIDR table — it detects the real chip.
- `CPUMIDRs` could not cap codegen even if pinned: upstream FEX says so outright
  (`// Skip CPUMIDRs as it doesn't affect codegen.` in
  `FEXCore/include/FEXCore/Core/HostFeatures.h`). Its only jobs are errata
  workarounds and the guest hybrid-CPUID flag, and no Apple part has errata
  there.
- Nothing sets `FEX_HOSTFEATURES` or `FEX_FORCESVEWIDTH`. Core count is not
  pinned either — Wine derives `peb->NumberOfProcessors` from the host.

What *does* make every device behave alike, and is the real lever to pull. As of
ml787 the first two have a device-aware default plus a no-rebuild override:

- Desktop resolution was hardcoded: `1024x768` (`ContentView.swift:1159`) and
  `960x540` for the services path (`:1431`). Pixel work was therefore identical
  on an A15 and an A18, so a faster GPU bought nothing. The defaults are still
  those two — they are load-bearing for window fitting and unvalidated
  elsewhere — and `Documents/madeira-resolution.txt` (`WIDTHxHEIGHT`) overrides
  them per run.
- The JIT pool was a fixed `896 MB` (`ContentView.swift:1862`), so the
  translation cache was the same size regardless of device RAM.
  `DeviceCapabilities.recommendedPoolMB()` now derives it from the measured
  jetsam budget: exactly 896 MB at or below the 4096 MB budget of the device
  this was developed against (so nothing already validated moves), scaling
  above it and capping at 1792 MB. `Documents/madeira-pool.txt` still overrides.
- FEX has no per-microarchitecture tuning; it targets an ARMv8 baseline plus
  detected features. A15→A18 ISA gains are minor, so the translator gains
  little from the newer part. What switches exist are compiled in, so
  `Documents/madeira-fex.txt` exports `KEY=VALUE` pairs as `FEX_<KEY>` — the
  same no-rebuild channel as `madeira-dxmt.txt` on the renderer side.

To confirm on-device, read the startup log line the fork emits:
`FEX: HostFeatures={} (ml538: ...)`. Identical content on two different chips
would be the smoking gun; it should differ.

## Performance work must start by removing instrumentation (ml803)

When asked to "actually and strongly improve performance", the first real win
was not a knob. The Steam launch path had three investigation probes still armed
after their questions were answered, and each one costs time in the run it
measures — worst of all at game startup:

- `MADEIRA_SURF_SEQ=10` (`ContentView.launchSteamTesting`). Sequential surface
  dumping, and **ml556 believed it had been turned off**: the `unsetenv("MADEIRA_DUMP_SURFACES")`
  only kills the throttled dump. The seq arm is a second dump path that
  PNG-encodes ten consecutive full window surfaces per burst, 14 bursts per
  window, on a background queue, for the first ~84s of every session. PNG
  encoding a 1024x768 BGRA surface is tens of milliseconds, so a "clean
  baseline" run was never clean. Do not re-enable it to measure anything.
- `MADEIRA_IRCAP_RVA`/`MADEIRA_IRCAP_MODULE`: FEX IR capture on the translator's
  compile path. Cheap per block, but it is armed for every block compiled and
  its question is answered.
- `MADEIRA_SRCWATCH_ROWS`: only meaningful while `MADEIRA_SRCWATCH` is armed,
  which production never does.

All three now hang off **`MADEIRA_DIAGNOSTICS=1`** in the app's environment (Xcode
scheme, not persisted). `launchSteamTesting` *unsets* them in the off arm, so a
previous diagnostic launch cannot leak into a normal one.

`MADEIRA_QUIET=1` (set by `WineProcessBridge`, was already the production
default) now actually does what its comment claimed — "per-present log lines
(100+/s at RAW rates), winios poll heartbeat". The compositor and input bridge
had never consulted it, so these were live on every run:

- `winios_surface_present` computed a 4096-probe surface census **and did an
  `fprintf`+`fflush`** on every present of every window ≥400x400 for its first
  2000 presents (~33s at 60fps, per window). `[surf-alpha]`, `[surf-sentinel]`
  and the dump paths are gated with it.
- `winios_pProcessEvents` drained **every** queued input event through
  `fprintf`+`fflush`. This is the input path: a mouse-look posts a relative move
  per tick, and the synchronous write sat between the sample and the game.
- `winios_post_touch_down/move/up` and `winios_post_key` logged per event.
- The desktop window-tree dump ran every 5s for the whole session.

The general lesson, and the reason this section exists: on this stack the
diagnostics are the workload. Before adding a knob, grep for probes still
writing to stderr on a hot path (`fprintf`/`dprintf` in `Winios.m`, `driver_ios.c`,
`message_ios.c`) and check whether the gate everyone assumes is on actually is.

The user-facing half of the same work lives in Settings → Performance:

- A **profile picker** (Balanced / Performance / Quality / Custom) that is
  *derived* from the four fields it owns (`MadeiraSettings.matchingProfile`)
  rather than stored beside them, so it can never claim a preset the fields do
  not spell. `Performance` = 960x540 (34% fewer pixels than the 1024x768
  default), `d3d11.mipClampBC=1`, `WINEDEBUG=-all`. Applying one writes only
  those four fields; pacing, pool, pad and advanced switches are untouched.
- **x87 fast math** (`FEX_X87REDUCEDPRECISION=1` via `madeira-fex.txt`) is an
  explicit switch and is off in every profile, because FEX's own description is
  "reduces emulation accuracy and may result in rendering bugs". The key name
  matters: `DeviceCapabilities.fexConfigEntries` uppercases and prefixes
  `FEX_`, and FEX matches the config key uppercased.
- **`madeira-winlog.txt`** is read directly by `WineProcessBridge` and becomes
  `WINEDEBUG` (its `-all` is the only way to switch Wine off entirely without a
  rebuild). `MADEIRA_DEBUG_VERBOSE=1` still outranks it.
- `MadeiraSettings` now decodes with `decodeIfPresent` for every field. The
  synthesized decoder requires all keys, and `SettingsStore` reads a throw as
  "no saved settings" — so adding a field used to silently reset the user's
  choices. Adding one is now a compatible change; keep it that way.

### The D3D11 (DXMT) lever surface

The renderer is a submodule (`research/dxmt` → `willfaust/dxmt`, `ios-port`), so
a change there needs a fork push, a rebuild of four PE DLLs and a device run.

**First, where the D3D11 code actually is, because it decides what can ship.**
The IPA workflow builds exactly one DXMT artifact, `libdxmt_combined.a`, and
`build/dxmt-ios/build.sh` shows its contents: the Metal unix layer
(`winemetal/unix/{winemetal_unix.c,cache.c}`), **airconv** (the DXBC→LLVM
translator, 15 files) and LLVM 15. The D3D11 API itself (`src/d3d11/`, ~19k
lines), the DXMT core (`src/dxmt/`), DXGI and NVAPI are Windows-side code
compiled into four PE DLLs — `d3d11.dll`, `dxgi.dll`, `winemetal.dll`,
`d3d10core.dll` — which are **committed binaries**, in two architecture sets
(`app/Madeira/aarch64-windows/` and `app/Madeira/arm64ec-windows/`; see "Two
architectures ship" below). The workflow only asserts they exist ("DXMT PE
module not shipped" in `.github/workflows/ipa.yml`), and `build-all.sh` rebuilds
them only if absent or if the patch stamp no longer matches, because rebuilding
"only replaces known-good binaries ... a needless way to break D3D". So:

- Editing `src/d3d11/*` or `src/dxmt/*` changes **nothing** in the IPA until the
  DLLs are cross-built by `build/dxmt-ios/build-pe.sh` and committed.
- `build-pe.sh` calls `xcrun` for exactly one thing: compiling `src/dxmt/*.metal`
  into `.air`/`.metallib` (`xcrun -sdk macosx metal`), which is embedded in the
  committed DLLs. That step is genuinely macOS-only. The rest of the PE build is
  portable, and this was verified rather than assumed: llvm-mingw publishes a
  Linux `aarch64-w64-mingw32` build of the pinned version, Wine 11.4 configures
  on Linux with `--enable-win64 --enable-archs=aarch64 --with-mingw=llvm-mingw`
  and yields `tools/winebuild/winebuild` plus the `aarch64-windows` import
  archives (`libwinecrt0.a`, `libntdll.a`, `libdbghelp.a`), and meson/ninja then
  cross-compile the DLLs. The Linux PE tree builds until `dxmt_command.air` and
  stops there -- the single macOS step.
- `build-llvm.sh` exits on non-Darwin by design, so airconv — the one
  D3D11-path component the workflow *does* compile — cannot be built here
  either, and it also needs `xcrun metal` for its three embedded `.metal`
  sources.
- Nothing in-tree validates a renderer change off-device: `tests/dx11/*.cpp` are
  rendering integration tests needing a real device, and the `wmt_api_census`
  counters are already `DXMT_API_CENSUS`-gated so they do not distort a run.
- `research/dxmt` stays pinned at its tested revision. Fixes go in
  `patches/dxmt-*.patch` and are applied by `build/dxmt-ios/build-all.sh`, so no
  fork and no `.gitmodules` repoint are needed.

What a Linux container can do, and what to use it for:

- **Compile-check a changed translation unit exactly as CI will.** `meson setup`
  writes `compile_commands.json` during configuration, before any compile, so
  the real command for a file is available even though the build later stops on
  the Metal step. Extract it, swap `-o` to a scratch path, and run it.
- **Check a patch applies, and that it still applies later.** `git apply
  --check` against the pinned revision, plus `--reverse --check` to tell
  "already applied" from "no longer applies".

A renderer change still cannot be run off-device: a wrong format or state
mapping does not fail a build, it produces a black screen that only a game
reveals. Compile-verification narrows the risk to semantics, not correctness, so
say which of the two a change has actually had.

### Two architectures ship, and games load the arm64ec one (ml805)

DXMT's four modules exist **twice**: `app/Madeira/aarch64-windows/` (PE machine
`0xAA64`, native ARM64) and `app/Madeira/arm64ec-windows/` (PE machine `0x8664`,
an x86_64-callable ARM64EC hybrid). Both are tracked, and `app/Madeira.xcodeproj`
copies both into the bundle as folder resources. A session picks between them in
`app/Madeira/WineProcessBridge.m`:

    BOOL use_arm64ec = (MADEIRA_USE_ARM64EC == 1) ||
                       (strstr(madeira_exe, "x64") != NULL) ||
                       (strchr(madeira_exe, '\\') != NULL);
    const char *bundle_subdir = use_arm64ec ? "arm64ec-windows" : "aarch64-windows";

A game is launched by full Win32 path, so **every real game takes
`arm64ec-windows/`**; only the in-bundle ARM64 tests (`cube.exe`) take
`aarch64-windows/`. Both directories are still symlinked into the prefix's
`system32` (non-colliding names from the other arch, plus the `sysx64`/`sysaa64`
per-arch farms), but a game's `d3d11.dll` resolves to the arm64ec copy.

That asymmetry was a silent shipping trap. `build-pe.sh` produced only
`aarch64-windows/`; `build-all.sh` only looked in that one directory for missing
files; and `.github/workflows/ipa.yml` only asserted `aarch64-windows/*.dll`
existed. A patch could therefore be applied, built, validated, committed and
reported green while `arm64ec-windows/` — the set games load — stayed at an older
revision. It did: that directory's DLLs were last built 2026-08-28 (`4c1e9f0`)
and carried none of the feature-level, no-abort or resource-residency fixes in
`patches/`. Anything verified by loading `aarch64-windows/` says nothing about
what a game runs.

Now:

- `build-pe.sh` writes two cross files (`aarch64-windows.ini`,
  `arm64ec-windows.ini`; llvm-mingw's `arm64ec-w64-mingw32-*` reports
  `cpu_family = 'aarch64'`, so only the tool prefix and install directory
  differ), builds each into its own Meson tree (`pe/`, `pe-arm64ec/`), asserts
  the machine word of every output, and installs into both app directories.
- `build-all.sh` treats a missing DLL in **either** directory as a rebuild
  reason.
- `tools/validate-ios-bundle.py` and the workflow gate check all four modules in
  both directories, each at its own expected machine word.
- `scripts/prepare-wine-ios.sh` configures **two** Wine trees, one per PE
  architecture (`wine/build-macos` for aarch64, `wine/build-macos-arm64ec` for
  arm64ec), so the `arm64ec-windows` import archives (`libwinecrt0.a`,
  `libntdll.a`, `libdbghelp.a`) exist. DXMT links the arm64ec DLLs against
  those; without them the failure is a link error that reads like a DXMT bug
  rather than a missing Wine target. They cannot share one tree: with
  `--enable-archs=aarch64,arm64ec` Wine enters an ARM64X setup, where makedep
  sets `native_archs[arm64ec]` and `hybrid_archs[aarch64]` and so emits
  `libwinecrt0.a` only under `aarch64-windows/` (holding both object sets) --
  `arm64ec-windows/libwinecrt0.a` is not a target at all and make dies with "No
  rule to make target". The merge drops the arm64ec `ntdll` and `dbghelp` import
  archives as well, so an ARM64X tree emits no `arm64ec-windows/` Wine artifact
  of any kind, and adding arm64ec to the aarch64 tree's `--enable-archs` cannot
  work. The separate arm64ec-only tree is also how the shipped `arm64ec-windows`
  DLLs were originally built, in `wine/build-arm64ec`.
- Check a tree's targets before trusting it, rather than reading them off a CI
  failure: `grep '^libs/winecrt0/arm64ec-windows/libwinecrt0.a:' build-macos/Makefile`
  is present for `--enable-archs=arm64ec`, and absent -- like the ntdll and
  dbghelp rules -- for `--enable-archs=aarch64,arm64ec`.
- That script also applies `patches/wine-arm64ec-inline-asm.patch` before
  configure. ARM64EC defines `__x86_64__` (it is an x86_64-callable ARM64
  hybrid) and does **not** define `__aarch64__`, so a header guard written as
  `#ifdef __x86_64__` selects x86 inline asm inside what is really ARM64 code:
  `int $0x29` fails to compile at all, and `lock; xchgl` assembles into
  something that is not the atomic it reads as. Wine writes these guards as
  `__x86_64__ && !__arm64ec__` and `__aarch64__ || __arm64ec__` in 32 places
  already; three in `winnt.h` (`InterlockedExchange`,
  `InterlockedExchangePointer`, `__fastfail`) did not, and they only bite when a
  PE is built for arm64ec. The fix belongs in the wine fork, which this tree
  cannot push to, so it is applied at build time the way the FEX patch is.
  Treat any such guard in a Windows header as suspect for arm64ec, and remember
  that the arm64ec compiler's *objects* are machine `0xA641` while the *linked
  DLL* carries `0x8664` in its PE header -- only the latter is what the bundle
  validator should check. That difference is real, not a mislink:
  `llvm-readobj --file-headers` on one of these DLLs reports `COFF-ARM64EC`,
  `IMAGE_FILE_MACHINE_ARM64EC (0xA641)`, a `CHPEMetadataPointer` and an
  `.a64xrm` section, because the `0x8664` field is what lets an x64 loader
  accept the file and llvm reads the CHPE metadata to identify it as ARM64EC.
  Use that command to tell an arm64ec DLL from a plain x86_64 one; the raw
  header word cannot distinguish them.

To check a built bundle, test the machine word rather than mere existence:

    python3 - <<'PY'
    import struct, zipfile
    z = zipfile.ZipFile('Madeira-unsigned.ipa')
    for arch, want in (('aarch64-windows', 0xAA64), ('arm64ec-windows', 0x8664)):
        for name in ('d3d11', 'dxgi', 'winemetal', 'd3d10core'):
            b = z.read(f'Payload/Madeira.app/{arch}/{name}.dll')
            off = struct.unpack_from('<I', b, 0x3c)[0]
            mach = struct.unpack_from('<H', b, off + 4)[0]
            print(arch, name, hex(mach), 'OK' if mach == want else 'WRONG')
    PY

### Shipping a DXMT change

`build-all.sh` hashes the patch set into
`app/Madeira/aarch64-windows/.dxmt-pe-stamp`, committed beside the DLLs. A run
whose patches match the stamp skips the PE build; a new or edited patch forces
one. The stamp exists because the previous rule -- rebuild only when the DLLs
are missing -- silently shipped unpatched binaries the moment a patch was added
to an already-populated tree.

A patch that neither applies nor is already applied is fatal, not a warning.
Skipping it would compile the unpatched source and still report success, which
is the one failure mode that reaches a device undetected.

CI does not commit, so after a new patch the runner rebuilds the DLLs and the
committed copies stay stale until they are refreshed from the produced IPA.
Until that refresh lands, the repo's DLLs and its source disagree; the stamp is
what makes that state visible rather than assumed.

### The shipped DLLs were unoptimized

The four committed DLLs were not built by the `build-pe.sh` in this tree. That
script passes `--buildtype release`, which meson turns into `-O3 -DNDEBUG`, but
the DLLs it had been shipping contain uncompiled-looking machine code: every
argument stored to the stack and immediately reloaded, no register allocation,
`b` to the next instruction, 22,528 unwind entries against the rebuilt DLL's
5,120, 21,306 stack-frame setups against 1,742, and 2.74MB of `.text` against
1.71MB. Rebuilding them from the same pinned revision with the repo's own script
is the first time they have been optimized.

This matters more than any of the small levers above, and it is also the part to
be careful about: `-O0` to `-O3` changes which latent undefined behaviour
happens to work, so a rebuild is not a pure speed-up even when the source is
identical. When a rebuilt DLL misbehaves, establish whether the same build with
`--buildtype debug` (no `-O3`) also misbehaves before blaming the source change.

The `arm64ec-windows/` set is in exactly the same state, and it is the one games
load: its `d3d11.dll` is 5,398,528 bytes against the 4,792,320 the repo's own
script produces for aarch64, with the same unoptimized instruction patterns. The
first build after ml805 optimizes both sets, so the caveat above applies to a
device run of either.

### Unimplemented features abort; they should decline (ml804)

`IMPLEMENT_ME` and `UNIMPLEMENTED` in this tree expand to `Logger::err` followed
by `abort()`. In an API implementation that is almost always the wrong move: the
D3D11 and DXGI contracts let a driver refuse a feature with an HRESULT, and
titles are written to cope with exactly that, because real hardware refuses
things all the time. `abort()` converts "this optional feature is unavailable"
into "the whole emulator is gone", with nothing the user can act on.

The clearest proof that these were oversights rather than decisions: the same
feature was already handled gracefully in one place and fatally in another.
Debug annotation through the D3D11.0 `ID3DUserDefinedAnnotation` object returns
-1 from `BeginEvent`/`EndEvent`, does nothing in `SetMarker`, and answers FALSE to
`GetStatus` -- while the D3D11.2 methods on the device context for the same thing,
`IsAnnotationEnabled`, `SetMarkerInt`, `BeginEventInt` and `EndEvent`, aborted.
Wine's own `dxgi` swapchain functions, which the app also ships, return
`E_NOTIMPL` for the very methods DXMT aborted on.

`patches/dxmt-no-abort-on-optional-features.patch` removes eleven of them:
the four annotation methods plus seven `IDXGISwapChain1/2` methods
(`GetRestrictToOutput`, `SetBackgroundColor`, `GetBackgroundColor`, `SetRotation`,
`GetRotation`, `SetSourceSize`, `GetSourceSize`). Two rules to keep when
extending it:

- **Prefer the truthful answer to a failure.** `GetRestrictToOutput` returns NULL
  because the swap chain genuinely is not restricted to an output; `GetRotation`
  returns the stored value; `GetSourceSize` returns the back buffer size, which is
  the true source size when no scaling stage exists. Answering correctly is better
  than answering "unsupported".
- **When the semantics cannot be honoured, fail rather than accept.** `SetSourceSize`
  succeeds only when the requested size equals the back buffer, and returns
  `E_NOTIMPL` otherwise. Accepting a smaller source would tell a title to render
  into the top-left corner of a backdrop it believes is being scaled up -- a
  visibly broken frame that no log explains. Refusing keeps the title at native
  resolution, where its output is correct. `SetRotation` refuses the real rotations
  for the same reason: DXMT has no rotation stage, so success would mean a
  sideways frame.

A second batch, `patches/dxmt-resource-residency-and-reclaim.patch`, fixes the
two places where the memory-management API either aborted or lied:

- `QueryResourceResidency` aborted. It is on the base `IDXGIDevice`, not an
  obscure D3D11.2 interface, so any title that manages memory can reach it. It
  now reports every resource `DXGI_RESIDENCY_FULLY_RESIDENT`, which is simply
  true under unified memory -- and the answer needs no dereference of the
  resource pointers, only the count. Note the return type is `HRESULT`, not
  `void`; the aborting stub had already guessed right, so keep it.
- `ReclaimResources` returned `S_OK` without writing `pDiscarded`, an output
  array the caller reads one entry at a time. It now writes FALSE in every slot.
  `OfferResources` is a no-op, so nothing was ever discarded and FALSE is the
  honest answer; the old code handed back whatever was in the caller's buffer.

Roughly two dozen aborts remain, concentrated in the D3D11.1/1.2 tiled-resource
and D3D11.2 tile-mapping methods, `ReadFromSubresource`/`WriteToSubresource`,
`CreateQuery1`, `SwapDeviceContextState`, and `Flush1`. `Flush1` is not a
mechanical fix: it is `void` and takes an event to signal after the GPU work
completes, so a no-op would leave a waiting title hung rather than crash it.

Two capability facts worth having before promising "full game support":

- **Feature level is not uniform, and reporting it was broken.** `d3d11.cpp`
  only considers 11_1 where the GPU is `supportsFamily(Apple7)` (A14/M1 and
  later); everything older caps at 11_0. But the default probe list started at
  `11_0` and never contained `11_1`, so an application that passed NULL feature
  levels -- the common case -- was handed 11_0 *even on Apple7*, while every
  11_1 interface (`ID3D11Device1`, `ID3D11DeviceContext1/2`, `ClearView`,
  `DiscardView1`) and every 11_1 option in `D3D11_FEATURE_D3D11_OPTIONS`
  (`MapNoOverwriteOnDynamicConstantBuffer`, `MapNoOverwriteOnDynamicBufferSRV`)
  was already implemented. Nothing inside DXMT branches on the feature level, so
  this is a pure reporting fix: it changes what a title is told, which is what
  decides whether it takes its faster buffer-update path. Patch:
  `patches/dxmt-11-1-default-feature-level.patch`.
- **BC decode is a gap only on older devices.** Hardware BC arrives with Apple9
  (A17 Pro and later); "some" Apple7/Apple8 iPads have it and Apple6-and-older
  do not. The fork's unfinished "tier-3 CPU decompression" — `remap_unsupported_bc`
  maps BC to RGBA8 but uploads the BC blob raw, so the texture reads as
  black/noise — therefore does not affect the Apple9+ devices this work targets.
  Check `[gpu-caps] ml709 BC=` in the startup log to know which side a device is
  on. The reachable config surface is exactly nine options
  (`d3d11.ignoreMapFlagNoWait`, `d3d11.metalSpatialUpscaleFactor`,
  `d3d11.mipClampBC`, `d3d11.noMeshShaders`, `d3d11.preferredMaxFrameRate`,
  `dxgi.customDeviceId`, `dxgi.customVendorId`, `dxgi.forceSDR`,
  `dxmt.shaderMetalVersion`) plus `DXMT_METALFX_SPATIAL_SWAPCHAIN` and
  `DXMT_LOG_LEVEL`; anything else is not read by the shipped DLLs.

The levers reachable from the app are these, and the traps in each:

- **`madeira-dxmt.txt` is NOT line-based, whatever the file looks like.** DXMT
  reads `DXMT_CONFIG` as inline `key=value` chunks split on `;`, and its parser
  takes one option per chunk with the value ending at the first whitespace.
  Handed a multi-line file verbatim it applies the *first* line and drops the
  rest in silence. `DeviceCapabilities.dxmtConfigInline` folds the file into the
  inline form before it becomes the environment; keep the file one-option-per-
  line (that is what a person reading it in the Files app needs) and let the
  normalizer do the translation. This was invisible while the file held exactly
  one option and would have broken the moment it held two.
- **MetalFX upscaling needs two channels.** `d3d11.metalSpatialUpscaleFactor`
  alone does nothing: DXMT gates the spatial scaler on
  `DXMT_METALFX_SPATIAL_SWAPCHAIN`. The launch sequence derives that variable
  from the same text via `DeviceCapabilities.dxmtConfigArmsMetalFX` (true only
  above 1.0, because DXMT clamps to `max(factor, 1.0)` and arming at 1 buys a
  1:1 blit), which also makes a hand-edited file work. It is a GPU-side *trade*,
  not free speed: the title keeps rendering at the desktop size and MetalFX
  scales the finished image up, so it pays off next to a desktop the panel would
  otherwise stretch badly (`960x540` at 2× presents `1920x1080`). It is
  deliberately outside every profile, like the pool and the pad — the picker
  compares only the fields a preset owns.
- **The compiled-shader cache is now in Application Support, not
  `Library/Caches`.** DXMT caches every DXBC→AIR→metallib it builds, keyed by
  SHA-1, under `_CS_DARWIN_USER_CACHE_DIR` by default — which iOS may empty at
  will, so a title could recompile thousands of shaders every launch and hitch
  for seconds on each first appearance. `DXMTShaderCache.preparedPath` exports
  `DXMT_SHADER_CACHE_PATH` (DXMT only honours an absolute path, and appends
  `shaders_<metalVersion>.db` itself), excludes the directory from backup
  (unconditionally — corelibs-foundation *does* have `URLResourceValues`, so
  the off-device gate compiles that call rather than skipping it), and
  `discardUnreadableDatabases` deletes a database whose SQLite header is not
  intact. That last part is not optional: a location iOS cannot purge is also
  one nothing else clears, so a database truncated by a jetsam kill mid-write
  would cost a full recompile on every launch from then on. The trade named in
  the comment is real — every title now shares one database, which is safe
  because the keys are content hashes, but it does grow with the library.
- **`WINEDEBUG` does not reach DXMT's logger.** DXMT resolves
  `__wine_dbg_output` in ntdll and writes warn/info lines through it, bypassing
  Wine's channel filtering — a `WINEDEBUG=-all` run still formatted a string and
  took a mutex per warning, and those warnings are per-occurrence so they land
  mid-frame. `WineProcessBridge` now sets `DXMT_LOG_LEVEL=error` when
  `madeira-winlog.txt` says `-all` (levels: trace/debug/info/warn/error/none;
  default info). Errors stay, because they are what explains a black screen.
- **`d3d11.mipClampBC` is not gated on the GPU's BC support.** DXMT's clamp
  site (`d3d11_texture_device.cpp`) does not check
  `supportsBCTextureCompression`, so on a device that *can* sample BC the clamp
  only throws away texture detail. It is still in the Performance preset for the
  A15-class case it was written for — the preset is applied explicitly, never
  automatically — and the Settings copy sends a BC-capable user to the startup
  log line `[gpu-caps] ml709 BC=1`. If that ever costs a real device, the fix
  belongs in DXMT (add the capability test to the eligibility), not in a preset.

The FPS overlay also reports **whole-task CPU%** now (a delta over the same
250ms tick as the footprint). Every Windows "process" here is a thread of one
Mach task, so this is the emulator's total, and red CPU with low FPS is the
signature of a CPU-bound frame — the case no renderer setting can fix.

## iPad fullscreen: one size class is not enough (fixed ml790)

There is exactly one tooling layout and one fullscreen layout, chosen by
`LayoutPolicy.resolve` in `AppLayout.swift`. Do not go back to branching on
`verticalSizeClass == .compact`:

- That is true ONLY for an iPhone in landscape. An iPad reports `.regular`
  vertically in **both** orientations, so every iPad was permanently stuck in the
  tooling layout with a 240pt game strip and no way to enlarge it. An iPad has no
  rotation to discover fullscreen with. This was reported as "the iPad can't make
  the game fullscreen".
- The idiom is therefore an explicit input to the policy, not inferred from the
  size class. A compact size class on an iPad means a multitasking pane, and the
  tooling rows still fit there. `Info.plist` also sets `UIRequiresFullScreen` so
  that pane case cannot arise in a shipped build.
- Immersion is forced on an iPhone in landscape and chosen everywhere else, via
  the expand button in the nav bar. `LayoutPolicy.needsExitAffordance` decides
  whether the immersive layout draws its own way out — it must be false where
  immersion was forced, because there is nowhere to return to.

Two things about the fullscreen layout are load-bearing:

- The exit control is a 44pt strip **above** the surface, never a button over
  it. `MetalHostView.shared` is added as a subview of the *window*, so anything
  SwiftUI draws over the game rect is invisible. A 4:3 iPad leaves no pillarbox
  to hide in, so an overlaid button would be dead on the one device it is for.
- The touch-controls overlay lives in its own window and cannot read
  `ContentView`'s state. It learns whether the game is up from `GameChromeState`
  (`immersive`, `topInset`) — not from `w > h`, which is wrong in portrait
  fullscreen — and starts below the strip so it does not swallow taps meant for
  the exit button. `TouchControlsModel.hitsInteractive` must keep that offset.

`tools/test-app-ui.sh` asserts the whole table. It is cheap; extend it rather
than reasoning about this again.

## Controllers: no XInput, and a keyboard/pointer bridge instead (checked ml790)

Do not claim gamepad support exists in the guest. It does not:

- There is no XInput, DInput or HID gamepad plumbing anywhere. The `wine/`
  submodule is not checked out in this environment, and nothing in `build/`
  (the Madeira-side glue that IS here: `win32u-unix/`, `wineserver/`,
  `ntdll-unix/`) presents a gamepad device. `build/wineios-drv/wineios.c` is
  only a PE stub for the audio driver.
- `ControlAction.pad(...)` and the mapping panel's "gamecontroller" tab are
  therefore deliberately inert (ml645), and the panel says so. Wiring them up
  needs work in the `wine/` submodule plus `build/`, not in this target.
- The touch-controls overlay is what "the controller" in the app actually means:
  on-screen buttons and a thumbstick that post through `winios_post_key`.

What DOES work for a physical controller is `GamepadBridge`, added ml790. It
maps a real controller onto virtual keys and relative pointer motion through
`winios_post_key` / `winios_pointer` — the same two calls the key buttons, the
on-screen stick and the S2 trackpad already use — so any game that accepts
keyboard and mouse accepts it, mouse-look included. A game that accepts ONLY
XInput still will not see it, and no change on this side fixes that.

- Defaults are on when a controller is connected (a plugged-in gamepad that is
  ignored is the more surprising behaviour) and rebindable in
  `Documents/madeira-gamepad.txt`: `ENABLED = 0`, `MOUSE_SPEED = 1.0`, and
  `<BUTTON> = 0xNN | VK0xNN | LMB | RMB | NONE`. Movement (left stick and d-pad →
  arrow keys) is deliberately not rebindable — it is the contract every Windows
  game already has, and the same eight-way snap `JoystickKeyView` uses.
- The look axis y is negated in exactly one place: `GamepadMap` is written in
  up-positive stick coordinates but posts mouse coordinates, which count upward
  as negative. Getting that wrong looks like a broken game, not a broken bridge.
- On disconnect the bridge releases everything it was holding. There is no other
  event that could lift a key the vanished controller was holding.

`tools/test-app-ui.sh` covers the mapping, including the sign. The
`GamepadBridge` glue itself cannot be compiled or run off-device; it still needs
one on-iPad confirmation.

## The on-screen pad goes through the same bridge, not around it (ml800)

`VirtualPadView` is a touch DualShock — d-pad, △○✕□, four shoulders,
Options/Share and two continuous sticks — that shows itself while a session is
running (`VirtualPadMode.automatic`, the default) because the system keyboard is
not a control scheme anyone can play with. It posts through `GamepadBridge`, the
same object the physical controller uses, and therefore through the same single
`post(from:to:)` differ. That is the whole design, and it is worth keeping:

- Two differs would each hold their own idea of what was down. Whichever ran
  last would win, so a key held on one source would flicker as the other
  released it. `GamepadInput.merged` combines the two frames first instead
  (buttons union; an axis takes whichever source is pushed further, so a thumb
  resting on the pad cannot cancel a controller stick).
- The bridge used to stop its tick when no controller was connected. It now also
  runs while the pad asks for input, and stops — releasing everything — when
  neither source does.
- `ENABLED = 0` in `madeira-gamepad.txt` turns off the *physical* controller
  only. The pad has its own switch in Settings; a user who turned off a gamepad
  they are not holding has not asked for the touch controls to go away. The
  bindings in that file still apply to the pad, so it is rebindable the same way.

Geometry lives in `VirtualPad.swift` and is deliberately pure, because the
failures here are invisible off-device and unrecoverable on it: a hit region
that disagrees with the drawn button, two controls claiming one point, or a
shoulder sitting on the immersive exit button all mean "unplayable".
`tools/test-app-ui.sh` asserts, for six real device sizes: every control fully on
screen, no two overlapping, nothing inside the top chrome inset, every control's
own centre resolving to itself, and the PlayStation positions of the four face
buttons. Extend that table rather than eyeballing a layout change.

Two rules that are easy to lose and expensive to relearn:

- The pad is drawn in its own `UIWindow` at `normal + 102` — above the touch
  controls (+101), which are above the joystick pad (+100) — because the game
  surface is a window-level `UIView` above the whole SwiftUI hierarchy. Unlike
  the other two, `VirtualPadWindow.hitTest` claims a point only when a control
  is there, so the gap between the buttons still belongs to the game.
- A stick's `y` is negated in exactly one place, `VirtualPadLayout.stickVector`:
  screen coordinates grow downward and `GamepadInput` is written up-positive.
  `ContentView`'s `ControlsWindow.hitTest` also stands down for any point the pad
  claims, or a tap on the pad would also fire whatever the user had placed on
  their own touch-controls layer.

`ls`/`rs` (stick clicks) are deliberately not on the pad: pressing a stick is a
different gesture from steering it, and a tap on the stick centre already means
"steer from here". The small ✕ in the middle of the deck — the one control
that is not a gamepad button — turns the pad off from inside the game.

### The pad's visibility is a session fact, and its touches are UIKit's (ml802)

Two things about the pad are load-bearing, and both were wrong:

- **When it shows.** `automatic` keys off `RunStatus.phase.isBusy` — the only
  honest "is a session running". It used to key off `GameChromeState.immersive`,
  which is a LAYOUT fact: an iPhone in landscape is immersive from launch, so
  the pad sat over the home screen before anything had started. `always` is
  still there for someone who wants it up over the tooling screens.
- **Where its touches go.** The input layer is `VirtualPadTouchView`, a plain
  `UIView` with `isMultipleTouchEnabled`, added as the pad window's topmost
  subview. The SwiftUI overlay draws only
  (`host.view.isUserInteractionEnabled = false`) and recognises no gesture at
  all. A per-control `DragGesture` looked equivalent and is not: the touch had
  to survive `UIWindow.hitTest` into a `UIHostingController`, then be recognised
  by a view whose `@State` flag was re-created whenever the overlay re-rendered
  — and the overlay re-renders on the first frame of every press, because the
  pad's held state is what it draws. That is a pad which lights up and posts
  nothing, which is how it was reported.
- Geometry therefore has ONE source. `VirtualPadState.bounds` is published by
  the touch view's `layoutSubviews`; the drawing reads it; `claims(_:in:)` uses
  it for both windows. Two sources can disagree by a safe-area inset, and that
  disagreement is invisible until a thumb is on the glass.
- What the pad draws is a readout of what the touch layer captured (`pad.held`,
  `pad.axes`), so a control cannot look pressed without having posted a press.
- `PadHit.canReassign` is the single rule for a finger that slides: buttons swap
  with buttons (a d-pad needs it), a stick is sticky within itself, and nothing
  crosses between the two classes. `tools/test-app-ui.sh` covers it.
- `VirtualPadState.push()` writes one `[pad] input ...` line to stderr per
  gesture, on the idle->held and held->idle edges only. `[pad] input` with no
  response in the game is a delivery problem, not a pad problem; silence is the
  pad. Check that line before suspecting `winios_post_key`.

## Build / test constraints in this environment

- The iOS app builds only with `xcodebuild` on macOS. There is no Linux build.
- Swift can be checked without a Mac in three grades, all wired into
  `tools/check-all.sh`:
  - `tools/test-device-capabilities.sh` type-checks `DeviceCapabilities.swift`
    (installs nothing, adapts the one Apple-only import, shims `sysctl`) and
    asserts its pool/override tables.
  - `tools/test-app-ui.sh` type-checks and asserts `AppLayout.swift`,
    `GamepadMap.swift`, `VirtualPad.swift` and `SettingsModel.swift`. All four
    are deliberately Foundation-only so this stays possible — keep framework
    imports out of them. `SettingsStore.swift` needs Combine and
    `SettingsView.swift` and `VirtualPadView.swift` need SwiftUI, so none of
    those three can be compiled off-device.
  - `tools/check-swift-syntax.sh` runs `swiftc -parse` over every app source.
    This catches syntax only, NOT types: a misspelled property still parses.
    `ContentView.swift` needs SwiftUI and cannot be type-checked off-device, so
    type errors there are still caught by nothing until a Mac or a build.
- Two failure modes have now reached the IPA runner from this blind spot, both
  found only on a Mac. Expect them and pre-empt them:
  - An API that does not exist on the type it is called on. `URL` has no
    `setResourceValue(_:forKey:)` (that is an `NSURL` selector; the Swift pair
    is `URLResourceValues` + `setResourceValues(_:)`), and it compiled nowhere
    because it sat behind `#if canImport(Darwin)` — the one branch the Linux
    gate is told to skip. That same guard was based on a wrong premise:
    corelibs-foundation *does* have URL resource values. Prefer an unconditional
    call; if a conditional is genuinely needed, it is unverifiable here, so read
    the Apple API surface twice.
  - "The compiler is unable to type-check this expression in reasonable time."
    A SwiftUI `Section` whose body has grown large, especially with `Text` built
    from a chain of `+` over interpolated literals and with optional `.tag`
    values, can exceed the solver's budget. Neither `swiftc -parse` nor any gate
    sees it. Keep each row a small `some View`, and keep long prose in `String`
    properties rather than inline concatenations — that also makes the text
    assertable from `tools/test-app-ui.sh`.
- All three Swift gates SKIP silently without a `swiftc` on PATH, which makes a
  green `check-all.sh` mean less than it looks. A Linux toolchain is enough to
  run them: the `swift-6.2-RELEASE-debian12` tarball from swift.org runs on
  Debian 13, needs the usual desktop deps (libcurl4, libedit, libicu,
  libncurses, libpython3, libsqlite3, libxml2, uuid), and installs outside the
  repository. Put its `usr/bin` on PATH and the gates run for real.
  - This container already has one at `/workspace/swift-6.2-RELEASE-debian12`,
    with the ncurses fix in `/workspace/swiftlibs` (Debian 13 ships only
    `libncursesw.so.6`; Swift links `libncurses.so.6`, so it holds a symlink).
    Do not download the 1 GB tarball again — run the gates with:
    `export LD_LIBRARY_PATH=/workspace/swiftlibs:/workspace/swift-6.2-RELEASE-debian12/usr/lib/swift/linux`
    `export PATH=/workspace/swift-6.2-RELEASE-debian12/usr/bin:$PATH`
  - Worth knowing when reading a green run: `-parse` only proves syntax, so the
    two `SettingsView`/`FPSOverlay` changes in ml803 are still unverified by a
    compiler until a Mac or a build touches them. Keep new logic in the
    Foundation-only files when a test can reach it instead.
- `.github/workflows/gates.yml` runs `tools/check-all.sh` on every push and PR,
  on `macos-15` because three gates need `swiftc`.
- `scripts/make-ipa.sh` builds and packages the unsigned `Madeira-unsigned.ipa`
  on a Mac. It runs `tools/check-build-inputs.sh` first, because a clean clone
  cannot be linked. `--output`, `--configuration`, `--keep-build`.
- `.github/workflows/ipa.yml` builds the IPA on a hosted `macos-15` runner with
  no Mac and no pre-published binaries: FEX (`scripts/build-fex-ios.sh`), the
  GnuTLS stack, the Wine unix libs, LLVM 15 for iOS
  (`build/dxmt-ios/build-llvm.sh`) and DXMT (`build/dxmt-ios/build-all.sh`) are
  compiled from the pinned submodules, checked with
  `tools/validate-ios-bundle.py`, and cached between runs. It needs the iOS 26
  SDK because `ContentView.swift` calls `glassEffect()`. Triggered by pushes
  touching `app/`, `scripts/`, `build/`, `tools/`, `patches/` or the workflow
  itself, and by `workflow_dispatch`.
- `build/dxmt-ios/build-all.sh` rebuilds DXMT's four PE DLLs (`d3d11`, `dxgi`,
  `winemetal`, `d3d10core`) **only when they are missing**: they are committed,
  they were built against the same Wine revision the submodule pins, and a
  from-scratch rebuild would swap shipped binaries for a second opinion. The
  caches must never carry them either — a restore would write over the
  checked-in copies.
- `scripts/prepare-wine-ios.sh` downloads llvm-mingw, configures Wine for macOS
  (`wine/build-macos`, including the generated headers) and builds FreeType.
  `build/wineserver/build.sh`, `build/ntdll-unix/build.sh` and
  `build/win32u-unix/build.sh` then compile the Wine unix libs for iOS from
  source — `libwineserver.a` included, so there is no patch-an-existing-archive
  step any more and no base archive to supply.
- `scripts/publish-build-libs.sh` (ml792) tars archives for a `build-libs`
  release. It predates the self-building workflow and is now optional; the
  workflow does not consume it.
- The CI recipes above and `tools/validate-ios-bundle.py` /
  `tools/ar-macho-symbols.py` came from the sibling fork
  `LT-NP/uncrashed-ipad` (branch `fix/ci-ios-build`), which proved them on a
  hosted runner. They are GPL-licensed like the rest of the project; the
  `uncrashed` name survives only in two LLVM marker filenames.
- `node` and `python3` are available and are the way to sanity-check
  `madeira-jit.js` (syntax + unit-test the pure helpers).
- `build/*-tests` ship prebuilt `.exe`/binaries; they are not runnable on the
  build host.

## Handing an unsigned IPA to the user

The build lives in CI, so "give me an IPA" is three steps, and the third is the
one that is easy to forget — the artifact is invisible until something serves
it:

1. Push the branch to the fork (`nwaf92641/Madeira`). `.github/workflows/*ipa*`
   builds it on a hosted macOS runner; gates run first, so a red gate means no
   IPA at all.
2. Download the run's `Madeira-unsigned-ipa` artifact through the API and unzip
   it (`curl -L .../actions/artifacts/<id>/zip`).
3. Put the `.ipa` in `/workspace/project/ipa-dist/` and serve that directory on
   port 12000 (`python3 -m http.server 12000 --bind 0.0.0.0`). The runtime maps
   that port to `https://work-1-rwoqahycgtqbslzr.prod-runtime.all-hands.dev/`,
   which is the link the user can actually open on the device. Restart the
   server after any conversation restart; it does not survive one.

`index.html` in that directory is the download page. Keep its build sha and
SHA-256 in step with the file, and verify the served copy with `sha256sum` and a
`Content-Length` check — a stale page over a new IPA is worse than no page.

Pushing needs a credential that can write. The environment's own
`GITHUB_TOKEN` is a GitHub App token that authenticates and can read
(including CI logs and artifacts) but is denied writes with "Resource not
accessible by integration", so a push with it fails. When the user supplies a
PAT, use it for the push only; do not record it in this file or anywhere else
in the repo.

The artifact is unsigned: sideload it (AltStore, Sideloadly, TrollStore) or
re-sign it. Nothing in the repo signs it.

## Release readiness

- Bundle id must stay `com.madeira.emulator` in the Xcode project, matching
  `app/source.json` and `scripts/deploy-thumper.sh`. A mismatch silently points
  sideload tooling at the wrong app.
- `Madeira.entitlements` deliberately carries `get-task-allow` (needed for the
  debugger to attach), `increased-memory-limit` and `allow-jit`.
  `source.json` also requests `extended-virtual-addressing`, which free Apple
  IDs cannot provision — it is injected post-install (see GetMoreRam notes in
  `ARCHITECTURE_ANALYSIS.md`), so do not add it to the entitlements file or a
  free-account signature will fail.
- `app/source.json` (`downloadURL`, `iconURL`, `size`) is still placeholder
  data and must be filled in before an official release.
