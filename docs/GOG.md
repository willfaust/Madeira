# GOG

Madeira can sign in to GOG, list the account's Windows games, download them with
the DLC the account owns, and start them through Wine and FEX. It does not
install GOG Galaxy. The protocol work follows Heroic's
[gogdl](https://github.com/Heroic-Games-Launcher/heroic-gogdl).

## Source

- `app/Madeira/SwiftGOG/GOGAPI.swift`: sign-in, the device-only Keychain token
  item, the library listing, owned ids, covers, builds, manifests and signed CDN
  addresses.
- `app/Madeira/SwiftGOG/GOGDownloader.swift`: the depot file list, chunk checks,
  install, update, repair, renewed CDN addresses, and the resume journal. It
  depends on no other store's code.
- `app/Madeira/GOGLibrary.swift`: the account, installed records, download
  queue, and the play task from `goggame-<id>.info`.
- `app/Madeira/GOGGames.swift`: sign-in, library, download, game-detail and
  settings views.

## Account and games

Sign in under Settings > GOG, or from the GOG section of the library. Madeira
shows GOG's own login page. When it finishes, GOG redirects to
`embed.gog.com/on_login_success` with a one-use code, which Madeira trades for an
access token and a refresh token. Tokens stay in the Keychain, for this device
only. If the web view cannot finish a login, sign in in Safari and paste the
final page's address.

The library lists the account's games that work on Windows. Covers come from
GOG's game database. GOG games are DRM-free: they play without a sign-in, and a
sign-in is only needed to download and update.

`env.MADEIRA_GOG = 0` hides everything GOG. Installed GOG games then stay in the
library entries but have no GOG section.

## A download

Madeira asks GOG's content system for the newest Windows build on the default
branch (generation 2). It installs the game's depots and those of DLC the account
owns, in English when the game has it, else the first language it lists, and
the 64-bit depots when a build has both. GOG's support files (installer scripts)
are left out, except the install script `goggame-<id>.script` (see "Install
script"), which goes to the folder's root.

Installs use `drive_c/GOG Games/<folder>`. Paths are checked against that
folder. Every chunk is checked by the MD5 of its compressed bytes and of its
contents, and a file with an MD5 is checked as a whole. Each file is written to
a temporary name and then renamed into place. Free space is checked before
any chunk is fetched. Pause keeps finished files, and a journal lets Resume skip
them. Signed CDN addresses are renewed when GOG stops accepting them. Update
keeps files whose checksum is unchanged and deletes files the new build no longer
has. Repair checks every chunk of every installed file. Cancel removes a partial
first install; it stops an update or repair without deleting the game.

In the background a download runs for the grace period iOS allows, then pauses
cleanly and continues when Madeira is active again. Downloads also pause for a
game session.

When a download finishes, Madeira reads the build's `goggame-<id>.info`. Its
primary file task names the program, its arguments and its working folder,
which become the game's library entry. A build without that file uses the
folder's only program. Otherwise the install stops with a message to add the
game by hand.

## Install script

GOG Galaxy runs a build's `goggame-<id>.script` after an install with its script
interpreter. Its `setRegistry` actions are values a game or its launcher reads to
find itself: The Witcher: Enhanced Edition's `launcher.exe` quits after half a
second, without a message, when `HKLM\Software\CD Projekt Red\The Witcher` has no
`InstallFolder`. Before each Play of a GOG game, or of a program added from a GOG
game's folder, Madeira writes those values into the prefix
(`SwiftGOG/GOGInstallScript.swift`, written with the Steam install-script writer,
so HKLM `Software` values land in both registry views). `{app}` and `{supportDir}`
become the game's folder. Actions for another language or for 32-bit Windows only
are skipped. A value the prefix already has is kept, except one made from the
game's folder, which follows the folder. `savePath`, `setIni`, `installSDB` and
`Execute` are left out and logged. Log tag `[gog-script]`.
Some scripts have no `setRegistry` at all: their one `Execute` runs a small setup
program from GOG's support folder that writes the keys, and Madeira does not
download or run it. For those, `GOGInstallScript.knownExecuteValues` lists the
values the program writes, by product. The Witcher: Enhanced Edition (1207658924,
`galaxy_the_witcher_enhanced_edition_*.exe`) gets `InstallFolder` = the folder,
`IsDjinniInstalled` = 1, `Language` = "3" and `RegionVersion` = "US". A game installed before
this change gets its script with Repair installed files.
`python3 tests/host/check-gog-install-script.py` checks it.

## Redistributables

A build names the redistributables it needs ("openAL", "MSVC2017_x64",
"DOSBOX"). Madeira reads GOG's dependency repository
(`content-system.gog.com/dependencies/repository?generation=2`, then its zlib
JSON manifest), downloads each needed one's files into the game's folder after
the game's own files (chunks from GOG's open link, no sign-in), and keeps the
list on the install record (`SwiftGOG/GOGSetup.swift`).

- Installers run at the game's first start, from the batch that starts the game
  (`LibraryEntry.servicesScript`): each once per prefix, from its own folder,
  with GOG's arguments. Its exit code goes to
  `C:\madeira-games\gog-setup\<id>.result`, so another game that needs the same
  one does not run it again, and a failing installer is not retried at every
  start. The game starts after them whatever they return.
- Left out, with the reason on the game's page: DirectX (Madeira's own Direct3D
  covers it), Visual C++ 2015 to 2022 (the build carries that runtime), the .NET
  Framework installers, and `.msi` packages while the build has no `msiexec.exe`.
  A redistributable without an installer (DOSBox, ScummVM files) is downloaded only.
- Repair installed files downloads them again if needed and runs the game's
  installers again at its next start. A game installed before this needs a Repair
  to get them.

## Galaxy game services

Games built with GOG's Galaxy SDK talk to GOG's client on `127.0.0.1:9977` for
their sign-in, achievements, stats, leaderboards and play time. While such a game
runs, Madeira answers there itself (`SwiftGOG/Galaxy`, ported from Playport): the
game's own client id and secret come from its build manifest, GOG mints a token
for that game from Madeira's GOG sign-in (`without_new_session=1`, so Madeira's own
tokens stay as they are), and only that token goes to the game. Achievements and
stats go to `gameplay.gog.com` as GOG Galaxy sends them. Without a GOG sign-in, or
when the port is taken, the game runs offline as it would without GOG's client.

Some SDK versions first ask Windows to start the `GalaxyCommunication` service, so
the prefix gets one: a do-nothing service (`build/gog-galaxy-service`, built into
`aarch64-windows/madeira-galaxy-service.exe`) copied to
`C:\ProgramData\GOG.com\Galaxy\redists\GalaxyCommunication.exe` and registered in
`system.reg` before the start, the same path GOG's client and Heroic's comet use.
`env.MADEIRA_GOG_GALAXY = 0` turns the services off. Log tag `[galaxy]`.

## Not supported yet

- Generation 1 builds, which some older games still have. Madeira says so
  instead of downloading.
- Galaxy cloud saves, and online multiplayer through Galaxy's peer library.
- Redistributables that need Windows Installer, while the build has none.
- Delta patches. An update downloads changed files whole.
- A language or branch picker.

## Checks

`python3 tests/host/check-gog-store.py` runs static checks: licence headers,
every GOG source in the Xcode project, the device-only Keychain item, no token or
code in a log line, GOG entries kept out of Other games, and the settings
catalog entry, the Game details page, and that the GOG code uses no Epic store
types. The Swift code has not been compiled on this branch. It needs
the app build and a device test of sign-in, listing, install, Play,
pause/resume, update, repair and uninstall.

## Credits

gogdl's protocol and format work is GPL-3.0, by the Heroic Games Launcher
contributors. Relevant sources include `gogdl/auth.py`, `gogdl/api.py`,
`gogdl/dl/dl_utils.py`, `gogdl/dl/objects/v2.py`, `gogdl/dl/managers/v2.py`,
`gogdl/dl/workers/task_executor.py` and `gogdl/launch.py`. No gogdl code is
included. The app uses Apple frameworks and adds no dependency.

The Galaxy service (`SwiftGOG/Galaxy/GalaxyWire.swift`, `GalaxyService.swift`,
`GalaxyListener.swift`, and `GOGGalaxyClient` in `GalaxySupport.swift`) is
Playport's (github.com/playportdev/playport at 412de5f, `app/Packages/GOGClient`),
as intraducine carried it to Madeira in willfaust/Madeira #479: copyright the
Playport authors, GPL-3.0-or-later with the Madeira Converter Exception, version 1.
Madeira's changes: type names prefixed `Galaxy`, no ContentKit package, the token
from Madeira's own GOG sign-in, and two compile fixes. Its 14 tests pass against
this copy. The install script reader follows Playport's
`GOGInstallScript` (GPL-3.0-or-later) for the script's shape and which actions matter. Which redistributables are skipped follows Playport's GOGDependencies.
