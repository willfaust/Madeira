# Epic Games integration

Native Epic Games support in Madeira, modeled on Legendary's protocol work
(https://github.com/derrod/legendary). Milestones 1 and 2 are implemented: sign in, list owned games, install Windows
builds and launch them directly through Wine + FEX, without the Epic launcher.

## Milestone 1 — sign in + library (done)

**Files** (`app/Madeira/Epic/`):

- `EpicAuth.swift` — OAuth through Epic's site. The user logs in in an embedded
  `WKWebView`; Madeira captures the `authorizationCode` from Epic's redirect
  page (`/id/api/redirect`, JSON body) and exchanges it at
  `account-public-service-prod03.ol.epicgames.com/account/api/oauth/token`
  (grant `authorization_code`, HTTP Basic with Epic's public launcher client
  credentials — the same ones Legendary uses). A manual paste fallback takes
  the raw code or the whole JSON, like Legendary's CLI. Tokens are refreshed
  with `grant_type=refresh_token` and kept in the Keychain
  (`madeira.epic.tokens`); the password never touches the app.
- `EpicAPI.swift` — owned games via
  `library-service.live.use1a.on.epicgames.com/library/api/public/items`
  (the endpoint Legendary's `get_library_items` uses), with cursor pagination.
  Titles and artwork missing from the records come from Epic's catalog
  (bulk item lookups). DLC (records with `mainGameItem`), add-ons and the `ue`
  namespace are filtered out, and only games in the account's Windows asset list
  (`launcher/api/public/assets/Windows`) are kept, so mobile-store copies with no
  Windows build stay out. Artwork prefers `DieselGameBoxTall` → `DieselGameBox` →
  `Thumbnail`; the library is cached in Application Support and refreshed when stale.
- `EpicSignInView.swift` — the sign-in sheet (`SettingsSheet.epicSignIn`) and
  Settings › Epic Games, after Steam's section: the account and Sign out, or Sign in.
- `EpicLibraryViews.swift` — the library's Epic Games section after Steam's and the
  games you added: installed and downloading games under the title, the rest under
  Not installed, with cards in the Steam cards' style. An installed game opens its
  Game details page; any other its install page, which shows the download and
  installed sizes beside the free space before installing.

## Milestone 2 — native installs and launch (done)

- `EpicManifest.swift` requests the Windows Live build from
  `launcher-public-service-prod06.ol.epicgames.com/launcher/api/public/assets/v2/platform/Windows/namespace/{namespace}/catalogItem/{catalogItemId}/app/{appName}/label/Live`.
  Epic lists the manifest on several CDNs; like Legendary it tries each URI with its
  query parameters until one answers and matches the hash, and reads binary or JSON
  manifests. When the library's app name has no Windows asset (HTTP 404), the app
  name from the Windows asset list is used instead. This includes metadata, prerequisites,
  chunk GUIDs/hashes/groups/sizes, file chunk parts and custom fields. Binary
  sections use their declared lengths; strings support ASCII and UTF-16LE.
  JSON numbers use Legendary's three-decimal-digits-per-byte encoding.
- `EpicChunk.swift` reads chunk headers, inflates zlib payloads and verifies
  GUID, sizes, manifest SHA-1 and the header SHA-1 when present. Paths follow
  the manifest feature level (`ChunksV3`, `ChunksV4`, and unencrypted `ChunksV5`).
  Encrypted content and legacy file-data manifests fail explicitly; content
  secrets and encrypted preloads are not implemented.
- `EpicInstaller.swift` queues installs, downloads at most four chunks at once,
  and writes each file's parts in manifest order. Its GUID-keyed LRU retains
  at most 8 MiB between writes, plus up to four chunks being fetched/consumed;
  a chunk is released immediately after its last use. Evicted chunks can be
  downloaded again. Responses spool to temporary files rather than building a
  whole game in RAM. Decompressed chunks are capped at 16 MiB each.
- File SHA-1 is incremental. Only verified files are renamed into place.
  Resume checks existing size **and** SHA-1 and skips matching files. Pause
  keeps complete files; an unfinished file restarts. App termination leaves
  pending installs paused for Resume, and abandoned staging data is removed
  at the next attempt. Cancel deletes the partial install. Free space is checked
  for remaining files plus 128 MiB working space before assembly begins.
- Installs live under `drive_c/Program Files/Epic Games/<sanitized title>-<app hash>`.
  The suffix keeps titles that sanitize to the same name separate. Paths that
  escape the install directory, existing symlinks, and duplicate file names are
  rejected. Installed build/launch/prerequisite metadata and pending jobs are
  stored atomically in Application Support's `epic-installs.json`.
- Epic uses the existing `SteamDownloadStatus` visuals and the same
  `SteamDownloadBackground` implementation with its own `.download.epic`
  identifier. iOS 26 uses continued processing when available; iOS 17–25 uses
  the normal background grace period, then pauses and resumes on foreground.
  Background execution remains subject to iOS scheduling and permission.
- Finished installs get a normal `LibraryEntry` with optional `epicAppName`,
  manifest launch command and public artwork URLs. Cards and sheets show real
  status, Pause/Resume/Cancel, Play and confirmed Uninstall. Play opens the normal
  details page; installed games remain visible after sign-out. Prerequisite
  installers listed by the manifest can be opened separately from the Epic sheet.
  Uninstall deletes the game directory (including saves stored there) and entry.
- Immediately after JIT setup and before launch, `EpicAuth.gameArguments` calls
  `/account/api/oauth/exchange`. The temporary launch profile appends Legendary's
  `-AUTH_LOGIN=unused`, exchange-code password/type, `-epicapp`, `-epicenv=Prod`,
  `-EpicPortal`, display name, account ID and `-epiclocale=en`, together with the
  manifest launch command. The saved library profile never receives credentials.
  Wine's argument logger redacts Epic authentication and identity values.
  `[epic-install]` logs contain counts and sizes, never tokens or account IDs.

### Validation and limits

`python3 tests/host/check-epic-manifest.py` compiles the production Swift readers
on macOS. Synthetic fixtures cover compressed and raw binary manifests, JSON,
UTF-16 metadata, prerequisites, columnar lists, optional file metadata, chunk
headers v1–v4, CDN paths, multi-chunk file assembly, incremental SHA-1, corruption,
truncation and encrypted-content rejection. The same test compiles the production
file worker with host stubs and fixture downloads to check assembly, hash-based
resume, corrupted-file repair, persistence, path/symlink rejection, cancellation
cleanup and uninstall. No iOS app build is needed.

Live account/CDN downloads, on-device pause/background behavior, prerequisite
execution and Wine/FEX gameplay still require device testing. Launch arguments
do not supply EOS overlays, ownership-ticket files, third-party launchers or
anti-cheat support; games requiring those may not run. Updates, delta manifests,
DLC selection and cloud saves are outside this milestone.

### Credits

Protocol and binary/JSON layout work is ported from
[Legendary](https://github.com/derrod/legendary), by derrod and contributors,
licensed GPL-3.0-or-later: `legendary/api/egs.py`, `models/manifest.py`,
`models/json_manifest.py`, `models/chunk.py`, `downloader/mp/manager.py`,
`downloader/mp/workers.py`, and `core.py` (`get_launch_parameters`). Madeira's
Swift port uses Apple's Foundation/URLSession and zlib, with no Python runtime
or new package dependencies.
