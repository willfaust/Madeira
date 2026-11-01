# Native Steam restart and Library follow-up

Target: Madeira 0.1.3, iPhone18,3, iOS 26.6.1. Evidence: user-provided
`madeira-log(20261101-225828).txt`, compared with the preceding `213058` run.
Logs and account data are not committed.

## Established from this run

- The previous `ios_io_status_control` fault is absent. Native-owned IOSB v2
  remains enabled; this is one successful run, not proof of all async paths.
- At about 104 seconds, Steam PID 0020 creates the same installed `steam.exe`
  as PID 02b4. The original exits with status 42. Madeira immediately ends the
  session after detecting the child. The replacement's further behavior is
  therefore unobserved.
- The user says the update message appears after launching CS2. Its exact
  wording has not been captured. It could describe a required client update
  or game content update; these must be distinguished.
- `library.js` returns 200, and localhost WebSockets negotiate 101. A read-only
  AppStore snapshot contains 155 apps including 730. `ready` means AppStore
  initialization, and `cs2` means membership; neither alone proves ownership
  or current installation readiness.
- Startup probes find CS2's manifest, library registration and executable.
  The subsequent installed count changes from two to one without app IDs.
  The old log cannot identify the removed record or prove deleted files.

## Source changes

Native Steam sessions automatically retain the existing Wine server, session
UI, input and JIT while a trusted same-path Steam successor lives. Records
carry Windows PID, parent PID, PEB ownership and generation. Explicit native
Steam launch wrappers (`explorer.exe` / `cmd.exe`) can establish the original
Steam image; unrelated service siblings cannot. CEF and crash reporters do
not hold the session open. The final Steam successor supplies the session
exit status. Non-Steam child waiting remains opt-in.

The embedded server reports actual Windows process death at `process_killed`,
including last-thread exits from worker threads. This fixes stale liveness
records that previously depended on the bootstrap pthread returning. Native
exit remains a checked fallback. Server source is staged from the pinned
Wine revision, and the build checks the resulting weak callback reference.

After handoff, focus can move to an already visible, eligible top-level window
owned by the new client or its associated browser process. This does not show
hidden windows or steal focus from an unrelated game. The lifetime wait uses
native metadata and never changes the bridge thread into the successor's TEB.

The passive CEF observer now samples targets independently, prioritizes Steam
UI targets, labels target/purpose/timeouts, and recognizes allowlisted Library
routes in normal URLTrack console events. Command replies remain serviceable
after event limits are reached; ignored high-volume events no longer consume
that budget. These are proven observer defects, not a demonstrated root cause
of Steam's Library error. DOM checks return only booleans for selected public
error/update strings; a text match explicitly does not establish visibility.
No Steam JavaScript is changed and no SteamClient API is invoked by the probe.

Bounded inventory diagnostics report added/removed app IDs and read-only CS2
manifest/executable/library metadata changes. They preserve the existing game
discovery rules and never recreate an absent record. Paths, account names,
console argument bodies, authentication headers and IPC payloads are excluded.

## Updater evidence and open question

The installed and fetched public `steam_client_win32` manifest both report
1769731672 (2026-01-30 UTC). A 304 response alone does not establish a stale
cache. The public SteamTracking mirror has a newer October `win64` manifest.
Valve's [32-bit Windows support announcement](https://help.steampowered.com/en/faqs/view/49A1-B944-48B8-FF00)
states that 32-bit Windows updates ended in January 2026. The mirror is
independent evidence, not a live CDN result or an exact installed asset match.

This makes incorrect OS architecture detection a hypothesis worth testing.
A 32-bit bootstrap executable alone does not prove that hypothesis. New
bounded diagnostics observe actual Steam calls to GetSystemInfo,
GetNativeSystemInfo, IsWow64Process and IsWow64Process2 without changing their
results, query count or last-error behavior. No version is forged and no
branch selection or mandatory update check is overridden.

## Validation and device acceptance

Host harnesses exercise the production handoff registry, bridge wait, staged
server death path and window focus code under ASan/UBSan. Cases include parent
42 to successor 0, repeated restarts, helper exclusion, wrapper lineage,
worker-thread process death, failed startup, slot/PID/PEB reuse, server stop,
CEF-owned windows and protected unrelated foreground windows. Architecture
trace fixtures exercise the staged Wine functions and unchanged API results.
Inventory and real Swift/CDP fixtures run on macOS in GitHub Actions. The
final IPA gate checks the native consumer and rebuilt WoW64/guest producers.

On the phone, verify `[steam-handoff-v1] ... action=keep-session`, continued
rendering/input after parent exit 42, and final successor exit. Capture which
canonical update/error condition matches, actual `[steam-arch-v1]` outputs,
the first Library failure with its target/route, and inventory app-ID deltas.
Verify CS2 files and authenticated launch through Steam. The Library root
cause, official update completion, and successful interactive CS2 launch
remain unverified until that run. No Steam/CS2 reinstall, authentication reset,
VAC bypass or installed-data modification is part of these changes.
