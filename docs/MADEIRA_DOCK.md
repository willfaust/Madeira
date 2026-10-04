# Madeira Dock

Madeira Dock starts a Steam game that Steam's client has installed in the
prefix, through **Valve's genuine Windows Steam client**, without the Steam
desktop window, its Chromium web helper or its library UI.

It is a small headless Windows program (`dockhost.exe`). Inside Madeira's Wine
session it loads the client's own libraries, signs in with the user's own
Steam sign-in and asks the client to start the game with Valve's own
`LaunchApp`. Valve's client performs the online authentication and the licence
check. The game, its Steam API calls and any DRM run exactly as Valve ships
them.

## What it is not

- Not a Steam emulator, not a DRM bypass, no ticket forging, no game patches.
  Without Valve accepting the sign-in and confirming the licence, the game does
  not start, and there is no fallback that starts it anyway.
- Not a Valve SDK use. Dock drives **undocumented internal interfaces** of
  Valve's client DLL (`steamclient64.dll`). That is fragile by nature, so Dock
  only drives client builds it has been verified against: it hashes the DLL
  (SHA-256) and checks the exact method addresses it calls. Any other build
  **fails closed** before sign-in, with report code 30 and the client's
  fingerprint in the log. Two client builds are supported at the pinned
  commit; see `madeira-dock/docs/CLIENT_LAYOUTS.md`.
- No Valve binaries, game content, cached login or token is bundled or
  committed.

## Source and licence

- Source: the `madeira-dock` submodule
  (`https://github.com/125hz/madeira-dock`, pinned at `0c5bbd1`), about 1,850 lines of
  C. Copyright 2026 125hz, **GPL-3.0-or-later with the Madeira
  Converter Exception** (the owner open-sourced it on 2026-09-27; it used to
  be a closed executable).
- Research references: OpenSteamworks (MIT) and Valve's public Steamworks
  documentation and headers were consulted. According to the Dock repository's
  `THIRD-PARTY-NOTICES.md`, no code was copied from them.
- Build: `build/madeira-dock/build.sh` cross-compiles it with llvm-mingw
  (x86-64 PE, static runtime, stripped, reproducible: no PE timestamp) and
  stages two files in the bundle:
  - `app/Madeira/arm64ec-windows/dockhost.exe`
  - `app/Madeira/arm64ec-windows/dock-notices.txt` (Dock's licence, the
    exception, the GPL text and the LLVM/MinGW-w64 runtime notices).

  Both are build outputs and are gitignored. `--check` also runs Dock's own
  unit tests. Without a built `dockhost.exe`, Madeira shows no Dock button.

## Using it

The developer interface has a **Madeira Dock** button (when `dockhost.exe`
is built; `env.MADEIRA_DOCK = 0` hides it). In the library the same sheet is
**Settings › Steam › Madeira Dock**, and first-run setup offers step 2 below
(`docs/LIBRARY.md`, "Steam setup"). A start from the library runs as a
library session. The sheet has:

1. **Steam account.** Sign in with Madeira's Steam sign-in
   (`docs/STEAM_SIGNIN.md`).
2. **Steam client.** "Download Valve's client components" fetches three
   pinned packages (about 73 MB) from Valve's update CDN
   (`client-update.akamai.steamstatic.com`, HTTPS, redirects must stay on that
   host). Each package is checked against a pinned size and SHA-256 sum before
   it is read. The ZIP reader rejects traversal, symlinks, duplicates,
   encryption and ZIP64. The unpacked `steamclient64.dll` must be the pinned
   build the Dock host supports.

   The files go to `C:\Program Files (x86)\Steam`, and Steam's discovery
   registry keys (install path, client DLL paths; nothing account-related)
   are written. This happens without starting Wine. Existing Steam files are
   kept; conflicting ones stop the setup.
3. **Installed games.** Read from Steam's own
   `steamapps/appmanifest_<appid>.acf` files in the client's library and in
   the other C: libraries its `libraryfolders.vdf` lists. Only games Steam
   marks fully installed can be started.

   Dock does not install games. They must already be installed in the prefix
   by Steam's client, for example with the desktop client, or copied together
   with their app manifest. Valve's client may still update a game's content
   when Dock starts it, and Dock waits for that.
4. **Smaller JIT pool (512 MB) for this launch.** Opt-in. The toggle starts
   from `env.MADEIRA_DOCK_COMPACT_POOL` and is off unless that is `1`.
5. **One-time installs.** Listed for each installed game whose Steam install
   script has programs to run (see below): "Run at next start" or "Skip".
   A game starts at "Run at next start"; a start that runs its programs
   turns it to "Skip".

Tap a game. Dock is started with Steam's default launch option only; custom
arguments are not supported.

## How a launch works

1. Madeira checks: JIT is enabled, no session has run in this app run,
   `dockhost.exe` is bundled, the client DLL exists, the game is fully
   installed and its folder exists, and a sign-in is stored. Then the app's
   own Steam connection (the owned library, `docs/STEAM_LIBRARY.md`) logs off
   and closes its socket, and Madeira waits for that before going on: a second
   online sign-in of the same account would replace the client's session. It
   stays off until Dock's report or session is over. The checks run again.
2. **One-use sign-in transfer.** `SteamSignIn.credentialsForDock()` supplies
   the account name and refresh token from the Keychain. Madeira writes them,
   with the account's SteamID (taken from the token's subject claim to select
   the account, not trusted as identity) and the App ID, into a bounded file
   (`MDOCK001`: 8-byte magic, u64 SteamID, u32 App ID, u16 lengths, account,
   token). The file is:
   - in `Application Support/MadeiraDock/launch.auth`, with complete file
     protection, mode 0600, excluded from backups;
   - created exclusively (`O_EXCL | O_NOFOLLOW`);
   - reached by the guest only through its path, in `MADEIRA_DOCK_AUTH_FILE`
     via Wine's `\\?\unix` namespace (the prefix has no guaranteed Z:).

   Dock opens it exclusively with delete-on-close, clears its buffers and
   hands the token to the verified client's own sign-in method. Madeira
   removes any leftover when the result is reported, on sign-out and at the
   next app start. No token, account name or path is logged.
3. The host's inputs go in its environment: `MADEIRA_STEAM_HOST_*` gates,
   App ID, client folder, the expected install folder (Valve's client must
   resolve the game to exactly that folder) and the report path. The
   cached-account variables are always cleared. The launch also sets the
   engine's opt-in image-retire switch, `MADEIRA_JIT_IMAGE_RETIRE=1`, for
   this session only and logs `[dock-launch] image-retire=1` (see Known
   risks). Other sessions keep the engine default (off). It also sets
   Wine's opt-in image-map guard, `MADEIRA_IMAGE_MAP_GUARD=1`, and logs
   `[dock-launch] image-map-guard=1`: while the loader loads Valve's client
   and its imports, the emulator's image-map handler can commit a page of
   its own heap under its interval lock, and that commit's notification
   waits for the same lock. The host then parks for good with no report
   line after `load-client-begin`. With the guard, the emulator's own memory
   calls during that notification are not notified again, as on the syscall
   path; ntdll logs `[ldr-image] image-map guard on`. Other sessions keep
   Wine's default (off).
4. The session is the normal Wine session: `explorer.exe
   /desktop=madeira,<W>x<H> C:\windows\system32\dockhost.exe`. The size comes
   from `desktop-size` in madeira.cfg, else 1280x720. When the game has
   one-time installs to run, it is `... C:\windows\system32\cmd.exe /c call
   C:\madeira-dock-installers.cmd & C:\windows\system32\dockhost.exe`: the
   installers first, then the host, in the same session.

   The session publishes no fixed Steam game identity. Every other launch
   gives its guests one title's `SteamAppId`, `SteamGameId` and `SteamAppPath`
   (a known compromise in `WineProcessBridge.m`); in a Dock session they
   reached Valve's client, which runs inside the host, and the game it starts.
   A Dock launch sets `MADEIRA_DOCK_SESSION=1` and the bridge leaves the three
   unset (`[steam-env] Madeira Dock session: ...`); Valve's client gives the
   game its own. `env.MADEIRA_DOCK_CLEAR_STEAM_ID = 0` keeps the fixed identity.
5. **The report.** Dock writes numeric stages to `C:\madeira-dock.txt`.
   Madeira reads only whitelisted numeric fields and the 64-hex client
   fingerprint (never other guest text), logs changes as `[dock-report]`,
   and turns the final `probe-result` into a message. Covered: unsupported
   client build, no licence, a licence Valve's client did not confirm within
   the host's 90 s after sign-in (34), a bad transfer, Valve's own launch
   refusal codes, and per-user executable preparation errors. The first 16
   callback IDs Valve's client posts after sign-in are logged in order as
   `session-callback-ids` (numbers only), with `session-requested-app-entitled`
   and `session-subscription-count`, so a sign-in that never reaches the
   licence check can be told apart from one whose licences never arrive.
6. **Another session.** If Valve's client refuses the launch with 35 (Steam
   still counts the account as playing in another session, which also
   happens for a session that ended without telling Steam until its old
   connection times out), Dock asks again every 15 s for up to three minutes
   (`launch-session-wait`, `launch-session-gave-up`). The sheet shows the wait;
   only Valve's own later success starts the game, and a session that is
   really playing elsewhere still fails with its own message.

## Offline play

Valve's client can sign an account in without a connection, with an offline logon
ticket that Steam issues to it during an online sign-in and that the client stores
itself (desktop Steam's Offline Mode). The Dock uses that mechanism as it is
(`madeira-dock/docs/OFFLINE.md`); Madeira stores no ticket and decides nothing
about ownership.

- **Online starts are unchanged.** Once Valve's client has confirmed the game's
  license, the host asks it whether the account can log on offline and reports the
  answer (`session-offline-ready`). When it is 1, the app notes that the ACCOUNT can
  sign in offline (`DockOffline`: one date for the account and the games started
  online since, in the app's preferences; removed with the sign-in). Steam's offline
  sign-in is per account: with it, Valve's client answers the license question for
  any installed game from its cached list, started online before or not.
- **A start with no network path** (`NWPathMonitor`) sets `MADEIRA_DOCK_OFFLINE=1`
  for the host, which hands over the sign-in as usual, asks Valve's client whether
  it can log on offline, and only then asks it to. The client answers the license
  question from what it cached and starts the game through the same launch call.
  A network that fails after the start falls back the same way 20 s in.
- **Game details** shows a small line under the title for games the Dock starts:
  "Can be played offline" (green check) once the account is saved; "Start a game
  online to play offline" before that; and "Start once online to play offline" for
  a game with per-user executables that has not started online yet (Steam prepares
  those over the network on the first start). Tapping it explains. The mark is a
  note of the last online start; whether an offline start goes ahead is always
  Steam's decision at that moment, and Steam's offline sign-in expires on Steam's
  own schedule.
- A refusal ends the start with its own message: nothing saved to sign in offline
  (50), offline sign-in refused (51), game not in what Steam saved (52).

`[dock-offline]` logs the request and the save; `[dock-report] session-offline-*`
carries the host's numbers. Steam Cloud cannot be checked without a connection, so
the existing "could not be checked" question still appears before an offline start.
Device-run once (2026-10-04, iPhone 18,3 / iOS 27.0, no network path): the offline
request, Steam's offline sign-in, the license from its cache and the game's window
8 s after the host started; the refusals and the fallback have not been exercised.

## Starting screen

A Dock start from the library (Settings › Steam › Madeira Dock, or Play on a
Steam game's Game details page) is a desktop session, and the library's
starting screen used to end on the desktop's first GDI frame: explorer's
windows and the host's console window, seconds before the game. The user saw
the Wine desktop instead of the game. Now (`DockStartScreen.swift`) the
starting screen of a Dock start shows the game's Steam cover and background
art (public store artwork by App ID), its title, a spinner, a status line
with the seconds so far, and one row of round glyph buttons (their words are
VoiceOver labels): **Close session** once Dock has stopped, **Show live log**,
and **Show desktop** while the desktop is held back. It stays until the
game's own window is shown.

The status line follows the furthest stage in the host's report
(`DockStartStatus`, read once a second):

| Report | Status line |
|---|---|
| nothing yet | "Starting Madeira Dock…" ("Still starting Madeira Dock…" after 30 s) |
| one-time installs running | the program running now, and any that failed |
| one-time installs ended (`[dock-installers] end`) | "One-time installs finished: N of M succeeded." and the failed ones, then "Starting Madeira Dock…" (late 30 s after the installs' end) |
| `probe-start-bits` | "Loading Steam…" |
| `session-native-token-submitted` or `session-logon-start-result` | "Signing in to Steam…" |
| `session-authenticated-online=1` | "Signed in. Waiting for Steam to confirm this game's license…" |
| `session-requested-app-listed=1` | "License confirmed. Steam is starting the game…" |
| `ceg-scm`, `ceg-request-busy` or `ceg-request` without `ceg-result` | "Steam is preparing this game's executable…" |
| `launch-client-error=0` | "The game is starting. Waiting for its window…" |

Steam's own waits come first: content the game needs (`launch-update-wait`),
the game's configuration right after sign-in (`launch-config-wait` with 22 or
23), and Steam's other session still counted as playing (35). The host
reports only numbers; the words are the app's. When the host reports a
result while the starting screen is up, the screen says "Madeira Dock
stopped" with the report's words (the host waits for the game it started, so
a result before any game window means the game did not start).

**Which window is the game's.** Winios keeps a census of the desktop's
top-level windows while a Dock start's starting screen is up: per window,
whether it is shown, its size, whether it has put a frame on screen (a GDI
frame or a D3D swapchain of its own), and the owning process with its
executable path, read once per process from the Wine server by process id.
The app classes the owner by where the program lives on drive C, never by
its name:

| Owner's executable | Class | Effect |
|---|---|---|
| under `C:\windows\` | helper | never the game: Wine's shell, services and console hosts, msiexec, and the Dock host itself |
| under the Steam client's folder, outside its `steamapps` library | client | a shown, drawn dialog (240x120 or larger) may need the user |
| anywhere else | other | the game's (or its own launcher's) once shown, drawn and 160x120 or larger |
| unreadable | unknown | the game's only when D3D frames reached the screen |

A window first shown before the host started (its first report field,
`probe-start-bits`) belongs to the one-time installs, which run before the
host: it is never the game's, and a dialog of it may need the user (a failed
installer can wait for OK). A window that may need the user and stays up for
2 s reveals the desktop; 4 s after it is gone the starting screen returns, at
most six times. **Show desktop** reveals the desktop for good. The game's
window ends the starting screen in every case. `[steam-launch-view]` logs the
hold, scene changes (window size and owner class, never a path) and reveals.

**A game window born minimized.** Some games show their main window minimized
the first time (parked at -32000,-32000). On Windows the taskbar brings it
back; the desktop here has none, so the starting screen waited for a window
that never appeared. While the census runs, a top-level window whose first
show is minimized gets what a taskbar click sends, once: `WM_SYSCOMMAND` /
`SC_RESTORE`, posted, and its own thread then brings it to the front from its
event pump (a fullscreen game pauses without focus). A window that was shown
and minimized itself later is left alone. `[born-minimized]` logs both steps.

The census runs only for a Dock start's starting screen: with it off, each
hook costs one atomic load, and nothing else changes for any other session,
direct launch or desktop.

## One-time installs

A game's Steam install script (`installscript.vdf`) lists programs Steam's
desktop client runs before a first start, typically runtime setups, each
recorded in the registry once it has run ("Run Process", `HasRunKey`,
`MinimumHasRunValue`). Valve's client runs them as part of its own launch
tasks, before the step Dock asks it for, so on the Dock route nothing ran them.
`DockInstallers.swift` does, right before a Dock start, while no session runs:

1. **Find.** Scripts in the game's folder (one level down) and in
   `common/Steamworks Shared/_CommonRedist` (three levels down). Repeated
   "Run Process" sections all count. An entry without a `HasRunKey` is
   recorded where Valve's client records it, a DWORD named after the entry
   under `HKLM\Software\Valve\Steam\Apps\<appid>`. HKLM keys are read and
   written in both registry views.
2. **Plan.** Each program is `done` (recorded at least at its minimum),
   `missing` (not on disk; paths resolve case-insensitively inside drive_c),
   `unsupported` or `pending`; at most 8 run per start (`limit`: the next
   start). `unsupported` depends only on what the program is and what the
   bundle has: a Windows Installer package needs `msiexec.exe` in the bundle,
   a 32-bit executable (PE machine 0x14c) needs `i386-windows`. There is no
   list of program names; every runtime setup is treated alike.
3. **Choice.** With "Skip", nothing runs. Otherwise the pending programs go
   into `C:\madeira-dock-installers.cmd` and the choice turns to "Skip"
   (unless some programs wait for a later start).
4. **Batch.** It first runs `dockhost.exe --start-services`: installers
   expect a service manager, and a Dock session starts none before the host.
   That mode loads no Steam client, starts Wine's `services.exe` only if no
   manager answers, gives up after 20 s and writes no report file. Then each
   program runs once (`.msi` through `msiexec.exe /i`). Each start and exit
   status goes to `C:\madeira-dock-installers.result`; the batch writes
   nothing to the registry.
5. **Record.** At the next Dock start, when no session runs, Madeira reads
   the result file and records the programs that exited with 0, 3010 or 1641
   in `system.reg`/`user.reg` (a `.madeira-bak` copy is kept once). Failed
   programs are not recorded; with the choice at "Skip" they do not run
   again at every start.
6. **Sync engine for that session.** With madsync, Wine's `services.exe`
   never answered its RPC clients in the fork's device runs, so the service
   step and then every installer waited; msiexec's custom actions use the same
   RPC server. A start that runs installers therefore sets
   `MADEIRA_MADSYNC_SESSION=0` before its session starts, and
   `build/madsync/madsync.c` turns madsync off for that session (the app runs
   one session per run). Every other session keeps the configured engine.
7. **fusion.dll.** An installer with a managed step (DirectX setup's is one)
   loads `fusion.dll` from `C:\windows\Microsoft.NET\Framework\v2.0.50727`.
   Wine gets that file from its Mono package, which Madeira does not ship;
   in the fork's device runs such a setup ended with -9. Before a start that
   runs installers, Wine's own builtin 32-bit `fusion.dll`
   (`i386-windows/fusion.dll`) is copied there if the file is missing. A
   bundle without 32-bit Windows DLLs has nothing to copy (`no-source`).

The plan, each program's fate and the results are logged as
`[dock-installers]`; the Dock sheet's status and the starting screen show the
plan, the running program and, once the batch ended, how many succeeded.
`madeira-dock-installs.json` next to the registry files holds the
batch's program list and each game's choice.

If the install record lists per-user custom executables (`CheckGuid`), Dock
asks Valve's client to prepare them before launching. `env.MADEIRA_DOCK_CEG = 0`
never asks. The preparation is Valve's; Dock does not touch the files.

## Switches

`env.NAME = value` in `Documents/madeira.cfg`.

| Switch | Default | Effect |
|---|---|---|
| `MADEIRA_DOCK` | on | `0` hides the Dock button |
| `MADEIRA_DOCK_COMPACT_POOL` | **off** | `1` starts the sheet's "Smaller JIT pool" toggle on |
| `MADEIRA_DOCK_CLEAR_STEAM_ID` | on | `0`: a Dock session keeps the fixed Steam game identity every other launch publishes |
| `MADEIRA_DOCK_CEG` | on | `0`: never ask the client to prepare per-user executables |
| `MADEIRA_DOCK_IMAGE_RETIRE` | on | `0`: a Dock launch does not turn on the engine's `MADEIRA_JIT_IMAGE_RETIRE` (an explicit `env.MADEIRA_JIT_IMAGE_RETIRE` still wins) |
| `MADEIRA_DOCK_IMAGE_MAP_GUARD` | on | `0`: a Dock launch does not turn on Wine's `MADEIRA_IMAGE_MAP_GUARD` |
| `MADEIRA_DOCK_CLIENT_202601` | on | read by the host: `0` disables its January 2026 client adapter |
| `MADEIRA_DOCK_HANDOFF_DIAGNOSTICS` | on | read by the host: `0` drops its numeric transfer diagnostics |
| `MADEIRA_DOCK_SESSION_WAIT` | on | read by the host: `0` fails a launch refused with 35 (another session playing) at once instead of asking again for up to three minutes |
| `MADEIRA_DOCK_OFFLINE_LOGON` | on | `0`: no offline starts. The app never asks for one and hides the Game details mark; read by the host too, which then does not look up Valve's offline-logon methods |
| `MADEIRA_DOCK_INSTALLERS` | on | `0`: no one-time installs (nothing read, run or shown) |
| `MADEIRA_INSTALL_DEFAULT_KEY` | on | `0`: install-script entries without a `HasRunKey` are ignored |
| `MADEIRA_DOCK_INSTALL_CHOICE` | on | `0`: no per-game choice; every start runs whatever is pending |
| `MADEIRA_DOCK_INSTALL_SCM` | on | `0`: the batch records "services off" instead of starting the service manager (also read by the host's `--start-services`) |
| `MADEIRA_DOCK_INSTALL_SERVER_SYNC` | on | `0`: a start that runs installers keeps madsync and leaves the service step out |
| `MADEIRA_DOTNET_FUSION` | on | `0`: never place `fusion.dll` in the .NET 2.0 folder |
| `MADEIRA_DOCK_HIDE_DESKTOP` | on | `0`: a Dock start's starting screen ends on the desktop's first frame, as before (no census) |
| `MADEIRA_DOCK_AUTO_REVEAL` | on | `0`: a window that may need the user never reveals the desktop by itself (Show desktop still does) |
| `MADEIRA_DOCK_INSTALLER_REVEAL` | on | `0`: a one-time installer's dialog never reveals the desktop by itself |
| `MADEIRA_DOCK_STATUS` | on | `0`: the starting screen does not watch the host's result |
| `MADEIRA_RESTORE_BORN_MINIMIZED` | on | `0`: while the census runs, a window first shown minimized stays minimized |

## 64-bit and runtime impact

With no Dock launch, nothing changes. The JIT pool stays 896 MB (or
madeira.cfg `pool`); no engine, Wine, FEX or DXMT file is touched. The compact
pool applies only to a Dock launch whose toggle is on, only for that launch,
and an explicit madeira.cfg `pool` still wins. Dock's host is itself an x64
program. A Dock launch also sets `MADEIRA_JIT_IMAGE_RETIRE=1`, the engine's
opt-in image-retire switch (its own engine PR), for that session only; no
other session sets it, and an engine without the switch ignores it.

One-time installs change the engine for one session only: a Dock start that
runs a game's installers sets `MADEIRA_MADSYNC_SESSION=0`, and madsync is off
for that session, including the game Valve's client then starts in it. With
the variable unset, `madsync_enabled()` returns what `madeira.cfg` selects
(madsync only with `inproc-sync = 1`; fastsync is the default engine); no other
code sets the variable. The next start, with the choice at "Skip", uses the
configured engine again.

## Not included (compared with the fork)

- **Game installation and library integration.** Dock itself neither installs
  nor removes games. The owned library and downloads are a separate part
  (`docs/STEAM_LIBRARY.md`) that writes the install records Dock reads; a
  Steam game's Game details page starts it through Dock. The library also
  offers Dock's sheet from Settings › Steam (`docs/LIBRARY.md`).
- **One-time installs, fork extras.** The fork also marked runtimes it
  recognised by file name as done without running them, and recorded such a
  runtime as done after a failed run. Those name rules are gone here (every
  program is treated alike; the per-game choice keeps failures from running
  at every start). The fork's reset on uninstall exists only in Madeira's own uninstall
  (`docs/STEAM_LIBRARY.md`), which sets the game's choice back to "Run at next
  start"; Dock neither installs nor removes games. The fork's "skip" button on its starting screen
  needs a session stop this branch does not have; choose "Skip" in the sheet
  before the start instead.
- **Automatic session end and the exit-status hook.** These need the ntdll
  program start/exit hooks from the front-end PR. Here, the result comes from
  the report file, and the session ends as other developer-interface
  sessions do.
- Heap, D3D9-census and pool-pressure defaults for Dock sessions (fork engine
  policies).

## Status and known risks

- On the owner's devices (fork builds), Dock launches reached gameplay: the
  host reported an authenticated online session and the app in the account's
  licences. Clean-prefix component setup and broad title compatibility are
  less proven.
- **This extraction has not been run on a device.**
- The fork's device runs depended on an engine fix: retiring an unloaded
  image's translations before its address is reused (fork ml1850). Without
  it, one device run crashed while Valve's client loaded its DLLs, before any
  sign-in: a DLL mapped at the address of a DLL unloaded moments before ran
  the unloaded DLL's translated code. The fix is its own engine PR, off by
  default, behind `MADEIRA_JIT_IMAGE_RETIRE=1`. Dock launches set that switch
  for their session only. This app side builds and runs without the engine
  PR; the variable is then ignored and Dock may hit that crash.
- Valve can change the client at any time. A new client build needs a newly
  verified adapter in the Dock repository and new pins in `SteamRuntime.swift`.
  Until then, Dock refuses the new build.

## Tests

On a Linux host with `swiftc`, `cc` and `python3`; no Steam, Wine or
credentials:

- `check-dock-contract.py`:
  - static rules: no program-name lists, no credential in a log line, compact
    pool off by default and Dock-only, madeira.cfg `pool` wins, the
    image-retire switch set only in the Dock launch environment, no built
    binary tracked, submodule pin;
  - compiled production Swift: pool policy, manifest and library discovery,
    validation, the transfer envelope and subject, the host environment
    (image retire on, and off with `MADEIRA_DOCK_IMAGE_RETIRE=0`; the
    image-map guard on, and off with `MADEIRA_DOCK_IMAGE_MAP_GUARD=0`), and the
    one-launch request.
- `check-dock-report.py`: the report parser, its messages (including 34),
  the ordered callback IDs, rejection of private and malformed fields, and that every report round the pinned host
  writes is accepted.
- `check-dock-path.py`: the transfer path through Wine's own path resolver
  (`WINE_FILE_C` can point at `dlls/ntdll/unix/file.c` when the wine
  submodule is not checked out).
- `check-dock-components.py`: the component ZIP reader and registry writer on
  synthetic archives, and the pins (one HTTPS host, well-formed sums, a
  client hash the pinned host supports).
- `check-dock-installers.py`: install-script parsing, the plan and its note,
  the batch and result parser, the whole start in a synthetic prefix
  (choice, recording at the next start, madsync request, fusion.dll, every
  switch), `madsync_enabled()` with the production `madeira_cfg.h`, and,
  where Windows `cmd.exe` is reachable, the batch run for real with stand-in
  installers and the staged `dockhost.exe --start-services`.
- `build/madeira-dock/build.sh --check`: Dock's own ASan/UBSan unit tests
  (transfer parsing, 2,000 malformed inputs, client selection, launch-result
  and callback bounds).
- `check-dock-start-screen.py`: the starting screen's rules compiled from
  production Swift (owner classes by folder, which window is the game's, the
  one-time-install windows, reveal and cover timing, Show desktop, the status
  texts and the stop rule), Winios's census extracted from `Winios.m` under
  ASan/UBSan and ThreadSanitizer (top-level windows only, one path lookup per
  process, frames and swapchains, capacity, the born-minimized restore and its
  switch), the driver's path form, and the wiring and glyph row.
