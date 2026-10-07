# Steam library and downloads

Madeira shows the games a Steam account owns, installs and updates them from
Steam's content servers, and removes them again. An installed game starts
through Madeira Dock like any other Steam game in the prefix.

The code is `app/Madeira/SteamOwnedLibrary.swift` (the model),
`app/Madeira/SteamGames.swift` (the library's Steam section, the download
sheet and the Steam section of a game's Game details page),
`app/Madeira/SteamInstall.swift` (where a download lives and how one is
removed), `app/Madeira/SteamDownloadBackground.swift` (downloads in the
background), the Steam parts of `app/Madeira/Library.swift` (a Steam game's
library entry and Game details page), and `app/Madeira/SwiftSteam/` (the
Steam connection, product info, depot downloader, content decoders and install
record writer).

## What you see

In the library, the **Steam** section (`docs/LIBRARY.md`, "Steam setup") lists
the games Steam has installed in the prefix under its title, with the games
being downloaded first, and the account's owned games that are not installed
yet under **Not installed**; the games you added follow under **Other games**.
Each card shows the game's artwork, its pills and, when Steam knows it, the
playtime. An installed game has the pills of any library game: **32-bit** or
**64-bit**, its graphics API (**OpenGL**, **D3D9**, **D3D11**, ...; named only
when exactly one is found) and its install size, plus **Update** when Steam has
a newer build. Any other game shows its state: **Not installed**, **Not fully
installed**, **Waiting**, **Downloading 42%**, **Paused** or **Download
failed**. Pull down on the library to read the install records again and fetch
the library again.

The bits and graphics API are those of the program **Start with: The game**
would start (below): the program picked there, else Steam's launch
configuration, else the install folder's only program. They are read off the
main thread once per install folder, build and picked program (again when
Steam's launch configuration is cached, and a day later while no program is
known, for example offline without a cached configuration, when the card shows
only the size) and kept on the game's library entry; the size is the install
record's `SizeOnDisk`.
`[steam-games] metadata` logs the App ID, bits and API.

**An installed game** opens its **Game details** page, the library's own page
(`docs/LIBRARY.md`, "Game details"), as in the fork. The game is a library
entry (`LibraryEntry.steamAppID`), made from Steam's install record when its
card first reads its pills, when it is first opened or when its download
finishes, so it keeps its own settings.
The page has, in this order:

- the header: artwork (Steam's, or a chosen cover), title, its bits, graphics
  API and install size, Steam's playtime, and **Play**;
- **Library details**: title, **Choose cover image**, **Use Steam artwork**;
- **Steam**: **Start with** Madeira Dock (the default) or **The game** (below);
  under Madeira Dock, **Smaller JIT pool (512 MB) for this launch** (Dock's
  per-launch choice) and **One-time installs**, **Run at next start** or
  **Skip** (Dock's choice for the game's Steam install scripts, when it has
  any); under The game, **Program**; an update's progress with **Pause update** / **Resume update**,
  or **Update available — download**; **Repair installed files**; App ID; free
  space; the last Dock result; **Uninstall** (with a confirmation);
- **Display**, **Compatibility & performance** (reduced-precision x87,
  **CPU cores reported**, **D3D9 anisotropic filtering**), **On screen** and
  **Executable** (the install folder), as for any game.

**Play** starts the game through Madeira Dock with the entry as its launch
profile: its **Resolution** sizes the Dock desktop, and its display, frame
limit, x87, CPU-count, anisotropy, overlay, live-log and touch-control
settings apply to the session (the in-game menu saves changes back to the
entry). The profile never replaces what Dock starts. Play is refused, with the
reason, while an update runs, before Steam marks the game fully installed,
without Valve's client components or without a sign-in. Launch arguments are
not offered: Dock starts Steam's own launch option. The session keeps Dock's
starting screen until the game's own window is shown (`docs/MADEIRA_DOCK.md`,
"Starting screen").

**Start with: The game** starts the game's own program in Wine, without Steam
or Madeira Dock, like a game added to the library. It suits games that run
without Steam (DRM-free ones); a game that needs Steam or its licence check
does not start this way, and Madeira Dock stays the default. Which program is
Steam's own launch configuration for the app (`config.launch` in its product
info, read with the owned library, or asked of Steam once when an older cache
lacks it): the Windows entries outside beta branches that are the game itself
(not a server, editor or VR entry), Steam's default first, a 64-bit entry
before a 32-bit one, and the first whose program exists in the install folder
(names are matched without case, as on Windows, and never leave the folder).
That entry's arguments and working folder apply. When Steam's configuration
names nothing that runs here, **Program** lists the install folder's `.exe`
files to choose from (the only one is taken by itself); a program picked there
is kept. No list of program names is involved. The launch publishes the game's
own Steam identity (`SteamAppId`, `SteamGameId`, and `SteamAppPath` = its
install folder) instead of the fixed one other launches get. Play needs the
game installed, no update running, and a program; no client components or
sign-in.

**Repair installed files** runs the download again for the current build: the
downloader checks every chunk already on disk against its SHA-1 and fetches
only what is missing or differs. **Update**, **Repair** and **Uninstall** are
offered for games in Madeira's own library folder; games Steam's client
installed in another library folder are shown and played, but Madeira does not
modify them. **Uninstall** also removes the game's library entry.

**A game that is not installed** opens its download sheet: artwork, playtime,
**Install** (or **Resume download**), **Pause**, **Resume**, **Try again**,
progress, speed and time left, **Cancel download** (a first-time install's
partial files are deleted; an update is only stopped), the free space on the
device and a link to the game's Steam Store page. When the download finishes,
the game becomes a library entry and the sheet's button reads **Open**, which
opens its Game details page.

Sign-in is not new: Settings › Steam and first-run setup (`docs/STEAM_SIGNIN.md`,
`docs/LIBRARY.md`) sign in and out. Signing in fetches the library; signing out
deletes the cached list and stops the downloads.

## How it works

**The library.** After sign-in, one Steam connection (a WebSocket over TLS to a
Steam connection-manager server from Valve's public server directory) logs on
with the stored refresh token and reads the license list Steam pushes. The
licenses name packages, the packages name apps, and Steam's product-info
service (PICS) describes each app. Only playable types (games, demos,
applications) with a Windows depot are kept. The list is cached in
Application Support (`steam-library.json`, with a hash of the account name it belongs
to; removed at sign-out) and refreshed when it is older than six hours. Steam's
own playtime record for the account comes from `Player.GetOwnedGames` over the
same connection (`steam-playtime.json`).

**The token.** The connection reads the sign-in from `SteamSignIn` and never
stores a token of its own: there is no second Keychain item and no token in
UserDefaults or a file. The connection is closed after 60 seconds of no use and
opens again when needed.

**A download.** Steam issues a depot key and a manifest request code only to an
account that owns the depot, so ownership is Steam's decision, not Madeira's.

1. Product info of the app (and of the apps whose depots it shares) selects the
   Windows, English, 64-bit (else 32-bit) depots, without DLC, redistributables
   or regional alternates.
2. For each depot: the depot key, the manifest request code, a per-server
   authorization token, then the manifest from a content server (a single-entry
   zip; older depots encrypt the manifest as a whole). File names in a manifest
   are encrypted with the depot key.
3. Files are created at their manifest size, and chunks are fetched by up to
   eight tasks. A chunk is decrypted (AES-256, the IV first), decompressed
   (zstd, LZMA or zip, whichever container Steam served), checked against its
   size and Steam's Adler-32, and written in place. A failed chunk is retried on
   another content server; servers that keep failing move to the back of the
   rotation. Content servers come from Valve's directory and must be Valve's
   own hosts, over HTTPS.
4. Finished chunks are journaled under `steamapps/downloading/<appid>`. An
   interrupted, paused or failed install resumes without fetching them again,
   and bytes already on disk that match a chunk's SHA-1 are kept (an update, or a
   resume after the journal's last lines were lost).
5. Manifest paths are validated to stay inside the install folder (no `..`,
   drive letters or control characters; symlink entries are skipped), and
   directory spellings are folded case-insensitively, as on Windows.
6. Last, `appmanifest_<appid>.acf` is written. Until then the game is not
   installed for Madeira Dock, so a partial download is never offered for Play.

Games with depots shared from another app also get the owner app's own record,
because Valve's client refuses to start a game before it. A file Valve's client
must customize per user before it runs is listed in the record (`CheckGuid`) and
its depot's manifest is kept in `steamapps/depotcache`, as the client expects.
Nothing here alters, unpacks or replaces a game's files, and there is no
emulation of Steam, tickets or DRM: the game starts through Valve's own client,
which signs in and checks the license (`docs/MADEIRA_DOCK.md`).

**Where.** Downloads go to Madeira Dock's own Steam library folder,
`C:\Program Files (x86)\Steam\steamapps` in the prefix, as
`common/<installdir>` and the install record beside it. That is exactly the
layout Madeira Dock's discovery reads (`MadeiraDock.games`) and Valve's client
understands; `tests/host/check-steam-library.py` writes an install with
the production downloader and has Dock's own scanner find it.

**Sessions and the account.** Only one sign-in of an account may be online:
a second logon with the same account replaces the first one's session. So the
app's own connection (library, playtime, downloads) and Valve's client in a
game session never overlap (`SteamConnectionGate`):

1. A Madeira Dock start (`ContentView.startDock`) first awaits
   `SteamOwnedLibrary.prepareDock()`: downloads pause, the running one is
   awaited, and the app's connection sends `ClientLogOff` and closes its
   socket.
2. Only then are the launch preconditions checked again, the sign-in read from
   `SteamSignIn`, the one-use sign-in transfer written and the session started.
3. The connection stays closed until Dock's report or session is over (or the
   start failed) and no session runs; then downloads continue. A logon that
   was already on its way when the session took the account logs straight off
   again.

Any other session also pauses downloads and closes the connection
(`runWineFullSequence`). Madeira does not start more than one session per app
run (`docs/LIBRARY.md`).

## Downloads in the background

On iOS 26 and later, a download submits a `BGContinuedProcessingTask` when it
starts: iOS keeps Madeira running in the background for the whole queue and
shows its own progress UI (title, game, percentage, a cancel control), fed from
the downloader's byte counts. When the queue is empty the task completes; when
iOS ends it early the downloads pause cleanly (every finished chunk is
journaled) and continue when Madeira is active again. On earlier iOS, or when
iOS refuses the request, a running download gets the usual short background
grace period, then pauses the same way. Local notifications report a download
that finished, failed or paused while Madeira was in the background; the
permission is asked for when the first download starts.

This needs one `Info.plist` entry: `BGTaskSchedulerPermittedIdentifiers` with
`$(PRODUCT_BUNDLE_IDENTIFIER).download.*`. The task identifier is
`<bundle id>.download.queue`, read back from that entry at run time, so a
re-signed bundle keeps working or falls back to the grace period. There is no
`UIBackgroundModes` entry. (`app/Madeira/SteamDownloadBackground.swift`,
ported from the fork, where it ran on the owner's devices.)

## Switches

In `Documents/madeira.cfg`, all on by default:

- `env.MADEIRA_STEAM_LIBRARY = 0` turns the owned library and downloads off
  (the Steam section then lists installed games only, as before). The library
  also stays off without Madeira Dock, because a downloaded game starts
  through it.
- `env.MADEIRA_BACKGROUND_DOWNLOADS = 0`: no continued-processing task; the
  grace period and the clean pause remain.
- `env.MADEIRA_DOWNLOAD_NOTIFICATIONS = 0`: no notifications and no
  permission request.

`env.MADEIRA_STEAM_TRACE = 1` adds protocol trace lines (message names and
result codes, never payloads or credentials).

## Logs

`[steam-library]`, `[steam-depot]`, `[steam-repair]`, `[steam-cdn]`,
`[steam-shared]`, `[steam-shared-record]`, `[steam-record]`, `[steam-playtime]`,
`[steam-account]`, `[steam-games]`, `[steam-start]` (Start with: the mode,
where the program came from, how many launch entries and programs) and
`[bg-download]`. They carry App IDs,
depot IDs, counts and short reason codes. No account name, Steam ID, token,
game name or path is logged (the host test checks this on a full install).

## 64-bit impact

**64-bit default behaviour unchanged.** This is app-side Swift and C. It
changes no JIT pool, engine switch, Wine, FEX or DXMT code, and no `madeira.cfg`
default. Existing code paths it touches: `ContentView.runWineFullSequence` (one
call that tells the library a session starts), `ContentView.startDock` (the
sign-in transfer is written after the app's own logoff; a Steam game's library
entry is its launch profile), `ContentView.launchLibraryEntry` (a Steam entry
starts through Dock, or with **The game** as a library game),
`LibraryEntry.configureLaunch` (returns before `MADEIRA_EXE` for a Steam game
started through Dock; clears the direct start's `MADEIRA_STEAM_APPID`,
`MADEIRA_STEAM_APPPATH` and `MADEIRA_WORKDIR` for every other launch),
`WineProcessBridge.m` (a launch carrying those publishes that game's Steam
identity and working folder instead of the fixed identity and the program's
own folder; every other launch is unchanged) and `LibraryEntry.applyEnvironment`, which
exports `MADEIRA_CPU_COUNT` and `DXMT_D9_ANISO_LIMIT` only when a game's
**CPU cores reported** or **D3D9 anisotropic filtering** is chosen (both
engine variables are already in the pinned wine and DXMT; unset keeps their
default). A Dock start from Settings › Steam › Madeira Dock runs as before,
except that its sign-in transfer is written after the app's own logoff.

## Provenance and licence audit

The Steam connection, library, product-info, depot-downloader, content-decoder
and install-record code is derived from **Jfishin's** Madeira Steam client (his
private fork; its Steam module is called SwiftSteam), used with his
permission (`docs/STEAM_SIGNIN.md`, "Provenance"). Jfishin also confirmed that he
wrote the depot downloader himself, in Swift, from how Steam's content system
works, and did not translate DepotDownloader's C#.

His permission covers this code as it covers sign-in, so the derived files are
GPL-3.0-or-later with the Madeira Converter Exception and say
`Copyright 2026 Jfishin, 125hz`. Files that are 125hz's own say
`Copyright 2026 125hz`. The zstd decoder keeps its own notice (Meta Platforms,
BSD-3-Clause selected from BSD / GPL-2.0).

**Why an audit.** The original says it follows "the DepotDownloader flow", and
DepotDownloader (SteamRE) is GPL-2.0 code that must not be translated into a
GPL-3.0-or-later work. SteamKit2 (LGPL-2.1) is the library it
sits on. Following the same protocol is fine; translated code is not.

**What was compared.** DepotDownloader `master` (ContentDownloader.cs,
Steam3Session.cs, CDNClientPool.cs, ProtoManifest.cs, Util.cs,
DepotConfigStore.cs) and SteamKit2 (`SteamKit2/Steam/CDN/DepotChunk.cs`,
`Client.cs`, `Server.cs`, `Types/DepotManifest.cs`, `Util/CryptoHelper.cs`,
`Util/Adler32.cs`), against every ported file. Two checks:

1. A shingle comparison of the code (comments removed, identifiers kept). A
   translation to another language changes the tokens, so this is weak evidence
   alone, but it found nothing: the longest run any file shares with any of
   those C# files is one 8-token sequence in the app-info parser
   (`branches = depots["branches"]`, a Steam key name) and a `for (i >= 0; i--)`
   loop in Meta's decoder; at 5 tokens the most any file shares is 14, Steam key
   names and loop idioms. The distinctive identifiers the two share are the
   protocol's words (`depotKey`, `manifestRequestCode`, `compressedSize`,
   `installDir`, `sizeOnDisk`).
2. A read of the flow side by side. The steps are the protocol's: ask for the
   depot key, the manifest request code and a CDN authorization, fetch and
   decrypt the manifest, fetch chunks, decrypt with the key (first block ECB, the
   rest CBC with PKCS7), decompress by container, check Adler-32 with seed 0, write
   at the chunk's offset. Where the two differ in structure:

| | DepotDownloader (C#) | this code |
|---|---|---|
| Steam access | SteamKit2 callback handlers on a `SteamClient` | raw protobuf messages on a WebSocket over TLS (`SteamConnection`, `SteamSession`) |
| Content servers | `CDNClientPool` weights servers by a persisted penalty list, `Server.NumEntries`, proxy server | Valve's directory over HTTPS, host filter by name and `https_support`, a per-install failure count, hosts rotate per chunk |
| Resume | per-file staging directory, old manifest kept in a config store, chunk diff by old/new manifest, file hash | append-only journal of finished chunk indices per depot manifest, SHA-1 of bytes already on disk |
| File writes | one `FileStream` per file with a lock, async writes | `pwrite` on the download task, files sized to the manifest first |
| Licensing check | `AccountHasAccess` reads package `appids`/`depotids` before every download | the license depot list is read only when Steam refuses a depot key, to leave out content the account does not own |
| Output | files only | files plus Steam's install record, shared-owner records and `depotcache` entries for Valve's client |

**Result.** No translated code was found, so nothing was rewritten for licence
reasons. What follows the protocol carries the protocol's names
(`depotKey`, `manifestRequestCode`, `compressedSize`, and Valve's field numbers),
which are interface facts. Comments that said the code was a port of
DepotDownloader, or named SteamKit2 or JavaSteam functions, now say the code
follows Steam's content protocol. The class is still called `DepotDownloader`,
as in Jfishin's tree; the name is generic.

| File | Non-blank lines | Lines identical to Jfishin's | Origin |
|---|---|---|---|
| `Core/CMServerList.swift` | 117 | 108 | Jfishin; header and comments |
| `Core/LicenseListBox.swift` | 49 | 42 | Jfishin; header |
| `Core/SteamConnection.swift` | 171 | 154 | Jfishin; header |
| `Core/SteamMessageCodec.swift` | 218 | 205 | Jfishin; header |
| `Core/SteamSession.swift` | 751 | 639 | Jfishin; logon with SteamSignIn's sign-in, `suspend()`/`resume()` (a logon completing after `suspend()` logs off again), no token clearing, no channel encryption |
| `Core/SteamError.swift` | 108 | 60 | Jfishin (reduced in the sign-in PR, extended again with his connection, library and content errors) |
| `Core/SteamProtocol.swift` | 55 | n/a | Jfishin's message-type, result-code and service-method constants, reduced to what is used |
| `Core/SteamCMSession.swift` | 25 | n/a | 125hz (the protocol that lets tests script the connection) |
| `Proto/SteamProtoMessages.swift` | 810 | 767 | Jfishin (protobuf helpers and messages); the sign-in PR's hardened decoder is kept |
| `Content/ContentDecryptor.swift` | 232 | 153 | Jfishin; comments rewritten, zip container added, corrupt-zstd guard fixed |
| `Content/DepotDownloader.swift` | 732 | 209 | Jfishin's original (334 non-blank lines), substantially rewritten by 125hz: journal, resume, host rotation, records |
| `Content/DepotManifest.swift` | 175 | 163 | Jfishin; unused diff code removed |
| `Library/SteamAppInfo.swift` | 333 | 157 | Jfishin, extended (shared depots, artwork names); his launch, Cloud and licence-agreement parts removed; `SteamLaunchOption` (the launch configuration for Start with: The game) is 125hz's |
| `Library/SteamLibraryFetcher.swift` | 351 | 251 | Jfishin, extended (licensed depots, shared metadata); the hidden-app report removed |
| `Install/AppManifestWriter.swift` | 184 | 101 | Jfishin's record writer (176 lines, in a folder named DRM in his tree; it writes Steam's own `appmanifest` format and nothing else), extended by 125hz: installed depots, shared depots, `CheckGuid` |
| `lzma_shim.c/.h` | 85 | n/a | Jfishin |
| `zstd_edu.c/.h` | 2056 | n/a | Meta Platforms (BSD-3-Clause selected), with Jfishin's error-safe wrapper; 1,986 lines identical to his copy |
| `chunk_zip.c/.h` | 73 | n/a | 125hz |
| `SteamOwnedLibrary.swift` | 559 | n/a | 125hz; the model is adapted from the fork's account model around Jfishin's flows; `SteamConnectionGate` |
| `SteamInstall.swift` | 101 | n/a | 125hz |
| `SteamDownloadBackground.swift` | 188 | n/a | 125hz (the fork's background downloads) |
| `SteamGames.swift` | 777 | n/a | 125hz (#53's section, extended; the download sheet and the Game details page's Steam section follow the fork's; `SteamDirectStart` is new) |

The limit of this audit: it cannot prove how a file was originally written. It
rests on Jfishin's statement, on his tree carrying no third-party notice for
these files, and on the comparison above.

**Left out of his client, on purpose:** the channel encryption (which cites the
SteamKit2/JavaSteam key dictionary; the connection is TLS), Steam Cloud, the
launch, ticket and stub code and everything in his DRM folder except the
install record writer (which writes Steam's own `appmanifest` format and does
nothing else), and the Windows desktop client's installer and launch code.

## Tests

`tests/host/check-steam-session-jobs.py` compiles the production session with
a test connection. It checks that disconnecting during a send resumes each
pending request once, even when the send then fails. It needs `swiftc` and
Python 3 and never contacts Steam.

`tests/host/check-steam-library.py` (needs `swiftc` on Linux, `cc`,
`python3` with `cryptography` or the `openssl` command, and libssl, liblzma and
zlib development files; it never contacts Steam):

- static: licence headers, the Xcode project, no program names, no engine or
  pool change, `Info.plist` permitting only the `.download.*` task family and no
  background mode, the background-download switches, no second token path, no
  account data in a log line; the order of a Dock start (the app's connection
  closes, then the sign-in is read and written, then the session starts), the
  release after Dock and the logon guard in `SteamSession`;
- one AddressSanitizer executable built from the production Swift and C, with
  stand-ins for CommonCrypto (on OpenSSL), Compression and zlib and a scripted
  `SteamCMSession`:
  - units: message headers and codec (round trips, truncated and hostile
    input), logon, license and product-info messages, playtime, depot selection
    (language, architecture, DLC, redistributables, shared depots), the library
    fetcher against scripted product-info replies, the AES and container decoders
    on known vectors with wrong keys, checksums, truncation and hostile sizes,
    manifest path and folder rules; `SteamConnectionGate` with a connection
    that takes a while to close (the sign-in transfer comes only after the
    logoff and the socket close; nothing reopens while Dock holds the account
    or a session runs; a Dock start during a session's close waits for it);
  - installs, against a local HTTP content server with three hosts (one dead, one
    that corrupts the first answer per chunk, one healthy) and content
    authorization: every chunk container and an encrypted manifest; a shared
    depot; a depot the account does not own; hostile manifest paths; an
    interrupted install that resumes without refetching journaled chunks and is
    not listed as installed before its record exists; then Madeira Dock's own
    scanner (`MadeiraDock.games`) finds the finished install; an update that
    fetches one changed chunk and shrinks a file; uninstall.

`check-steam-games.py` covers the merge of installed and owned games, the
status text, artwork candidates and the Play rules, the install size from the
record, and the Game details wiring: an installed game opens its library entry's
page with the Steam section and every section and control listed above, a
finished download's sheet offers **Open**, a finished download (and only that)
gets its entry and **Uninstall** removes it, Play on a Steam entry goes through
Dock with the entry's profile, the profile never sets what Dock starts, and the
CPU-count and anisotropy variables are exported only when chosen. For **Start
with: The game** it reads a product info's launch configuration (order, types,
platforms, beta branches, bounds, the owned-library cache and an older cache
without it) and, on a synthetic install folder, checks which entry is taken
(64-bit default first, names without case, missing programs and working folders
passed over, nothing outside the folder), the Program picker's list and the Play
rule; the launch wiring (no program, no start; the program checked inside
drive_c) and the bridge's one-launch identity and working folder are checked in
the sources. `check-frontend.py` runs `LibraryEntry.configureLaunch` for a Dock
start (nothing set) and a direct start (program, Steam's arguments, identity,
working folder) and checks that any other launch clears them.
`check-onboarding.py` and `check-dock-installers.py` cover the rest of Dock's
start from the library; `check-steam-signin-native.py` covers the module
boundary (sign-in files hold no library code).

Not covered: a live logon to Steam and a download from Valve's content servers
from this branch (the protocol code is the fork's, which ran on the owner's
devices; see the pull request for what was and was not device-tested), the SwiftUI
views, iOS background-task behaviour, and running a downloaded game (through
Madeira Dock or as The game).

## Not included, and limits

- No Steam Cloud, no achievements, no workshop content, no DLC installation,
  no branch (beta) selection, no language selection: English, the public
  branch.
- A file that a newer build no longer contains is not deleted by an update
  (the install keeps it); **Uninstall** removes the whole folder.
- Only the account's licenses are read; family sharing and free-on-demand
  licenses are whatever Steam's license list contains.
- Games installed by Valve's client in another library folder are listed and
  played but not updated or removed here.
