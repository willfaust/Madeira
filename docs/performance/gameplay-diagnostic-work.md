# Active-gameplay diagnostic work

Base: `8b52c1810a0b77614238001ed86199978865afd1`.

## Changes and tradeoffs

### Native runtime profiling

The default `MADEIRA_PROBES` level started periodic thread-sample bursts, guest
RIP profiles and the D3D12 worker profiler. These suspend game threads to collect
diagnostic data. `MADEIRA_QUIET`, set by the app, does not gate these profilers.

Default/unset/empty now selects `light`: keep xprobe counters, governors and
sync-census, without the periodic profiles. `env.MADEIRA_PROBES = 1` restores
full profiling; `0` still disables both sampler loops. Unknown nonempty values
retain the prior full-profile behavior. Settings are read once per process. Earlier timing runs with explicit `light`
are not directly comparable: it previously started only xprobe, without the
stuck-store loop or its per-thread polling and possible suspension cost.

The thread-sampler loop also owns a correctness fix: it detects stores stuck
across a page boundary every 100 ms. Keep that check in default/light mode and
with lean diagnostics; it must not depend on whether diagnostic profiles run.
`MADEIRA_STUCK_CHECK=0` still disables it separately. For existing lean users,
this re-enables a repair that was previously suppressed, together with its
per-thread polling cost; it is not a claim of unchanged lean behavior. Explicit `MADEIRA_PROBES=0`
still disables the loop, including the repair, as before. The repair can itself
suspend a suspect thread; this change does not remove those correctness checks.

### D3D12 and desktop dumps

D3D12 `quiet-log` now defaults to 1. This uses the existing path that skips
OutputDebugStringA, automatic census frames and the fixed command-list draw
dump window. Normal Wine debug output and stderr remain. Manual frame capture
still forces a census. Conversion messages keep the existing first-64, then
every-1000th policy. `quiet-log = 0` restores verbose diagnostics. This switch
is read once when the D3D12 device is created.

Periodic desktop window-tree dumps (5 s) and all-thread stack dumps (20 s) now
require `env.MADEIRA_DESKTOP_DIAG = 1`. The flag is cached per process; restart
the app to change it. Failure-triggered dumps remain independent. Window
layout, event delivery, and hidden-window presentation rates are unchanged.

The tradeoff is less automatic diagnostic detail in ordinary game logs. The
explicit switches restore it when investigating a game. Existing source comments
report expensive logging and game stalls, but this work does not re-measure or
claim those historical device timings.

### App diagnostics

`ProMotionIntent.tick` read `MADEIRA_PROMOTE_KICK` through `MadeiraConfig.flag`
on every display tick, even when the diagnostic was off. `flag` calls
`presentCached` (which calls `all`), then calls `all` again when madeira.cfg
exists. Each `all` performs a file `stat`, URL lookup and cache stamp construction.
At 60/120 display ticks per second this meant 120/240 file-status calls per
second with an existing configuration file, by source inspection.

The link now refreshes only this diagnostic flag at most once per second.
The first tick still reads it. Later refreshes pick up the game's exported
environment and live edits. Edits can now take up to one second to apply while
ticks continue. Existing precedence is unchanged: a global
`env.MADEIRA_PROMOTE_KICK` value wins over the process environment. A newly armed
link resets the cache. The display-link range, display-sync setup, tick logging,
and enabled kick's one-transaction-per-tick cadence are unchanged.

`LibraryMetrics` now samples RAM and battery only when selected. Its monitoring
assignments also preserve an active `DeviceLoadDiagnostics` timer when the HUD
appears or fields change. The existing disappearance behavior remains: disable
monitoring, then let device diagnostics re-enable it before its next report.
Thermal transition logging and CPU/GPU meter behavior are preserved.

## Focused evidence

These are executable host-fixture operation counts, not CPU-time or device
performance measurements. Platform/configuration dependencies are stubbed.

| Actual production code exercised | Result |
| --- | --- |
| ProMotion tick, base source via `--revision`, 60 simulated seconds at 60 Hz | Negative control fails: 3,600 diagnostic config reads |
| Changed tick, 60 simulated seconds at 60 and 120 Hz | 60 reads at each rate, zero kicks while disabled |
| Changed tick, late enable/live disable/rearm | Pickup within one second; one kick per tick while enabled; reset takes effect immediately |
| 120 FPS-only HUD samples | Zero task_info calls and battery reads; selecting RAM/Battery makes one each |
| HUD monitoring expression | Preserves active device diagnostics; toggles with field selection otherwise |
| Sampler, five completed simulated 20-second cycles | Full: 20 passes, 5 guest profiles; default/light: 0 and 0; both retain 1,199 stuck-store check calls before harness termination |
| Sampler with lean diagnostics | No profiles; same stuck-store checks; explicit repair-disable switch still works |
| D3D12, 3,000 simulated presents | Default: zero automatic census frames; quiet-log=0: seven; manual capture still sets census |
| D3D12 logger and conversion gate | Default skips debug-string exceptions, keeps Wine output; 66/2,000 conversion messages versus 2,000/2,000 with quiet-log=0 |
| Desktop diagnostic helper | Off for unset/empty/0; on for 1; cached until process restart |

Checks:

- `tests/host/check-gameplay-diagnostic-work.py` (Swift compiler required).
- `tests/host/check-gameplay-native-diagnostics.py` (C compiler required).
- `tests/host/check-lean-diag.py`, `check-quiet-log.py`, and
  `check-overlay-frame-times.py`.
- Config catalog regeneration/check and `git diff --check`.
- Swift frontend syntax parsing of changed Swift files; full Winios.m syntax
  checking against the iOS SDK (existing deprecation warnings).
- The five gameplay checks are included in the build workflow's planning job.
- Council also ran `check-desktop-mode.py`: its fixture fails with an undeclared
  `madeira_japanese_on` on both the candidate and an exported base. This is a
  pre-existing check failure, separate from the passing diagnostic-gate checks.

The Swift check uses a Boolean config stub: it does not exercise real file
edits, precedence, environment publication or UIKit lifecycle. Arming reset
statements and HUD monitoring expressions are extracted from production source;
SwiftUI lifecycle attachment is checked textually. Native checks execute the
sampler/gates/logger against stand-ins; they do not call Mach thread APIs,
Wine, Metal, or a game. Desktop call-site gates and worker-profiler arming are
checked textually. A 3,600-entry library fixture is not relevant to these
constant-cost active-session paths.

## Shipping boundary and runtime limits

Swift and Winios compile directly into the app. `build/ntdll-unix/server_ios.c`
requires rebuilding `app/Madeira/libntdll_unix.a` through
`build/ntdll-unix/build.sh`. D3D12 requires rebuilding its ARM64EC PE DLL through
`build/madeira-d3d12/build-pe.sh`; the build also copies it as `d3d12.dll`.
The repository's shipping archives/DLLs have not been replaced. A separate
current-source simulator candidate stage now contains a rebuilt ntdll archive
and a successfully linked simulator app, as described below. The tracked
ARM64EC D3D12 DLLs still carry the old default. CI invalidates/rebuilds the
Windows runtime component for these source changes and rebuilds the ntdll
archive through the IPA build. A direct local Xcode build that skips those
runtime builds would still use stale native behavior. No FEX or DXMT submodule source or user game data was changed.

The direct app target initially failed on its missing x86_64-vcruntime resource.
A subsequently supplied current-source simulator setup resolves those prerequisites
without using old project native archives. In an owned --include-diff export,
all 41 ntdll compilations passed and the resulting archive contains the candidate
server.o and diagnostic markers. The separate real simulator app successfully
linked that exact archive, the matching freshly rebuilt FEX/Wine/DXMT prerequisites,
and a 722-file PE import closure with zero missing direct imports.

Both baseline and candidate apps subsequently built and ran on standard iOS 27.2
(24B8117), through the T3 Device panel. Their separate freshly rebuilt ntdll
archives match the respective source variants. Owned 90-second D3D11 clear/present
probes completed 5,403 baseline x64 and 5,404 candidate x64 presents, with zero
Present errors. The baseline logged two periodic profile burst completions and
two RIP profiles; the default candidate logged neither, while retaining xprobe
and sync-census. An explicit full-profile candidate x86 run completed 5,403
presents with zero errors and restored three bursts and three RIP profiles.
These simple capped probes do not establish a game FPS improvement.

Separate production-source fixture apps exercised real display callbacks,
configuration files, getenv, UIKit and Mach. For the same 267 callbacks, config
flag reads fell from 267 to 5 and instrumented stat sites from 536 to 12.
Both display timestamp intervals were 16.666667 ms. The simulator panel is 60 Hz;
a 120 Hz request does not validate 120 Hz delivery. Live file and environment
changes arrived within one second; precedence, kick cadence, stop and rearming
passed. In 120 FPS-only HUD samples, RAM and battery reads each fell from 120
to zero. Hardware battery monitoring is unsupported by UIKit Simulator.

The real desktop menu showed RAM disappearing and returning with field selection.
Lean mode logged repair-only sampler arming, and explicitly enabled periodic
window-tree dumps ran. Stack timer firing was not established from the Wine log
because stack output goes to stderr. No intentionally stuck-store game regression
was induced. Mouse/key counters stayed zero; input delivery is unverified.

No sustained physical-device thermal test, CPU-time comparison, full shipped-app
build or cross-game acceptance was performed. The simulator's D3D12 converter
boundary is unsupported, and copied D3D12 PE resources remain baseline; they do
not validate the candidate quiet-log default. This default remains covered by
host fixtures and requires a rebuilt PE DLL for device acceptance. No temperature,
power, battery-life or FPS benefit is claimed. The low-cost probes ran on a
shared host; simulator power counters are not iPad measurements.

Local artifacts under `artifacts/gameplay-overhead/simulator/ios272/` contain
`REPORT.md`, source/archive/app hashes, build logs, fixture JSON, native logs,
present TSVs and screenshots. Old-OS setup failures are historical, not the
current validation result. A 3,600-entry library fixture is not relevant to
these constant-cost active-session paths. Only owned isolated review apps and
fixtures were installed; no user library, save, or game was accessed.

The source investigation also checked these paths and retained their behavior:

- ProMotion display intent: removing it risks the documented panel-idle drawable
  stalls. Keep the link and frame-cap behavior.
- DXMT present submission uses Metal minimum-duration presentation and an opt-in
  absolute-deadline producer limiter. Changes require rebuilt DXMT artifacts
  and controlled game traces; tracked app/libdxmt_unix.a is not the linked input.
- Keep 4 ms input polling, controller assists, and output handling.
- Library interaction intent ends on launch; GlassSkin stops on disappearance.
  Library loading and poster caching are separate work.
- Keep each game's selected resolution, fidelity, and hidden-layer pacing.

Physical acceptance should compare the same game/scene, cap, resolution, overlay,
device state and duration before/after. Include D3D11/D3D12 and Dock launches,
manual capture, profile opt-ins, a stuck-store regression case, late per-game
configuration, menu field changes, background/foreground, and session relaunch.
