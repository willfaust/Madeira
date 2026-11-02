# EA app

Madeira can sign in to an EA account, list its PC games, download them, and
start them through Wine and FEX without the EA app. It does not install the EA
app (a Qt and Chromium program with a Windows service, which does not run well
in Wine) and instead talks to EA's services itself, the way the EA app does,
and stands in for the EA app's local service while a game runs. The protocol
work follows [Maxima](https://github.com/ArmchairDevelopers/Maxima), an
open-source EA app replacement for Linux.

## Source

- `app/Madeira/SwiftEA/EAAPI.swift`: sign-in with EA's own login page, the
  device-only Keychain token item, the account's games and catalog data, builds
  and download addresses, token exchanges for a game, and licence requests.
- `app/Madeira/SwiftEA/EAFormats.swift`: the pure parts: AES-128 (EA's local
  service and licence files use it with fixed keys), the service's challenge and
  session key, LSX messages, a zip build's table of contents, installerdata.xml,
  registry-prefixed paths, licence files, the machine hash, `pc_sign` and PE
  version resources. Host-tested on Linux.
- `app/Madeira/SwiftEA/EADownloader.swift`: installing a build from its zip on
  EA's CDN by range requests, with resume, update and repair.
- `app/Madeira/SwiftEA/EALicense.swift`: a game's licence: what its activation
  library expects, when to renew, where to write.
- `app/Madeira/SwiftEA/EAService.swift`: the local service on 127.0.0.1:3216.
- `app/Madeira/EALibrary.swift`: the account, installed records, download
  queue, and what a launch needs (licence, registry, environment, service).
- `app/Madeira/EAGames.swift`: library section, download sheet, Game details
  section, Settings section and sign-in views.

## Account and games

Sign in under Settings › EA app, or from the EA app section of the library.
Madeira shows EA's own login page, asked for as the EA app would ask for it
(the EA app's client, a PKCE challenge and a signed description of the
machine). When it finishes, EA sends the page to the EA app's private address
`qrc:///html/login_successful.html` with a one-use code; Madeira stops that
navigation and trades the code for an access token and a refresh token. Tokens
stay in the Keychain, for this device only.

The library lists the account's PC base games (not DLC, not trials), with
covers from EA's game database. For each, the catalog gives the content id a
licence names, the install folder and, for older games, the program to start.

`env.MADEIRA_EA = 0` hides everything EA. Installed EA games then stay in the
library entries but have no EA app section.

## A download

EA serves a build as one zip archive on its CDN, often tens of gigabytes.
Madeira reads the archive's table of contents from its tail with range requests
(Zip64 included), then fetches each file's bytes with its own range request and
inflates them (with Madeira's own DEFLATE decoder, `EAInflate`) straight into `drive_c/Program Files/EA Games/<folder>`, checking
the CRC-32 the archive records. Nothing of the archive is stored whole. Paths
are checked against the game's folder. Each file is written to a temporary name
and then renamed into place. Free space is checked before any file is fetched.
Pause keeps finished files, and a journal lets Resume skip them. Update keeps
files whose CRC and size are unchanged and deletes files the new build no
longer has. Repair checks every installed file's CRC. Cancel removes a partial
first install; it stops an update or repair without deleting the game.

In the background a download runs for the grace period iOS allows, then pauses
cleanly and continues when Madeira is active again. Downloads also pause for a
game session.

When a download finishes, Madeira reads the build's
`__Installer/installerdata.xml`. Its full-game launcher names the program (often
behind a registry key, `[HKEY_LOCAL_MACHINE\SOFTWARE\…\Install Dir]Game\x.exe`,
which Madeira takes relative to the game's folder), its arguments and the
build's content ids and version; these become the game's library entry and
record. Without a manifest the catalog's program is used; without either the
install stops with a message to add the game by hand. The build's "touchup"
(redistributable installers) is not run; Madeira's own Visual C++ runtime covers
the common case.

## Playing

An EA game checks, as it starts, that the EA app is present: it reads
environment variables the EA app sets, a licence file, registry keys, and
connects to the EA app's local service on 127.0.0.1:3216. Madeira provides all
four before the session starts (`EALibrary.prepareLaunch`):

1. **Licence.** A game with a `Core` folder (its activation library) needs a
   licence from EA's activation service, bound to the account and a hash of the
   machine. Madeira computes that hash from the values its own Wine and FEX
   report to the game (Win32_BaseBoard, Win32_BIOS, Win32_OperatingSystem, the
   C: volume serial, the graphics card's PNP id and CPUID), asks EA for the
   licence with the account's token, and writes it as
   `C:\ProgramData\Electronic Arts\EA Services\License\<content id>.dlf` (and
   `_cached.dlf`). The licence is renewed after two weeks, when the machine hash
   changes (a different graphics card choice or AVX switch changes it), or for
   another account. The hash version follows the activation library's product
   version, as the EA app does. A game whose licence check fails says so in its
   own words; `madeira-ea-hardware.json` in Documents can replace any of the
   hash's values (the keys of `EAHardwareProfile`) after a device test, and the
   log shows the exact text that was hashed.
2. **Registry.** `HKLM\Software\Electronic Arts\EA Desktop\InstallSuccessful`,
   the same for Origin, and the game's own install folder key when its manifest
   named one. Written into the prefix's `system.reg` while no session runs.
3. **Environment.** What the EA app gives a game: the account's token, the
   content id, the service port, the day's launch code, and the rest
   (`EALibrary.environmentNames`). Set for the EA game's launch only; every
   other launch starts with them cleared.
4. **Service.** Madeira listens on 127.0.0.1:3216 inside its own process (Wine's
   sockets are the app's). The game sends a challenge response; Madeira accepts
   it and, for encryption version 3, derives the session key the EA app would.
   It then answers the game's questions: the service list, the signed-in
   profile, settings, connectivity, game info, a sign-in code for another EA
   client (through EA's token exchange), the licence token (a licence request
   with the game's ticket), entitlements, presence (always "in game"), and
   empty friend, offer, image and overlay answers. The service stops when the
   session ends.

An EA game needs the sign-in to start. GOG and Epic games do not; EA's licence
and the EA app's environment come from the account.

## Not supported

- Games with EA's kernel anti-cheat (Battlefield 2042 and later, EA SPORTS FC,
  Madden): the anti-cheat cannot run in Wine on iOS.
- Cloud saves, friends, presence, the in-game overlay, achievements.
- DLC installs. Entitlements are reported to the game; DLC files are not fetched.
- EA games owned through Steam or Epic.
- Builds older than the current manifest ("pre-DiP") whose zip differs; they
  download but may not start.
- A language picker: builds install as EA serves them, and the game is told
  en_US.

## Checks

`python3 tests/host/check-ea-formats.py` compiles `EAFormats.swift` on the host
and checks it: AES against Python's `cryptography`, the service's session key
against the C runtime's `rand()`, the machine hash against `hashlib` for every
version, `pc_sign`'s signature, LSX documents, installerdata.xml, licence files
zip directories (plain and Zip64) written by Python, and the DEFLATE decoder
against zlib for every block type, fed whole and a few bytes at a time.

`python3 tests/host/check-ea-store.py` runs static checks: licence headers,
every EA source in the Xcode project, the device-only Keychain item, no token or
code in a log line, EA entries kept out of Other games, the settings catalog
entry, the Game details section, the launch preparation and environment
clearing, the environment list, the service's port and answers, and that the EA
code uses no other store's types. The Swift code has not been compiled on this
branch beyond `EAFormats.swift`. It needs the app build and a device test of
sign-in, listing, install, Play, pause/resume, update, repair and uninstall;
the first Play of a game with a `Core` folder is the test of the machine hash.

## Credits

Maxima's protocol and format work is GPL-3.0, by Sean Kahler, Nick Whelan,
Paweł Lidwin and the Maxima contributors. Relevant sources include
`maxima-lib/src/core/auth`, `core/service_layer.rs`, `core/library.rs`,
`core/launch.rs`, `ooa/mod.rs`, `lsx/`, `content/` and `util/simple_crypto.rs`.
No Maxima code is included. The app uses Apple frameworks and adds no
dependency.
