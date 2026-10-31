# itch.io

Madeira lists the games you bought or claimed on itch.io and installs their
Windows downloads.

- `app/Madeira/SwiftItch/ItchAPI.swift`: itch.io's server API at
  `api.itch.io`, the calls the itch app makes through go-itchio (MIT):
  `GET /profile`, `/profile/owned-keys`, `/games/<id>/uploads?download_key_id=`
  and `/uploads/<id>/download`. The API key goes in the `Authorization` header.
- `app/Madeira/SwiftItch/ItchArchive.swift`: the zip unpacker.
- `app/Madeira/ItchLibrary.swift`: the account's games, downloads and installs.
- `app/Madeira/ItchGames.swift`: the library section, download sheet, Game
  details section, Settings › itch.io and the sign-in sheet.

## Signing in

itch.io has no sign-in Madeira can use without registering an app with it, so
Madeira signs in with an API key: Settings › itch.io › Sign in opens
<https://itch.io/user/settings/api-keys>, where **Generate new API key** makes
one; paste it into Madeira. Madeira keeps it only once itch.io accepts it, in
this device's Keychain (`madeira.itch.key`, this device only, not synchronised).
Sign out removes it; deleting the key on itch.io stops it everywhere. Installed
games keep playing: itch.io games need no sign-in to start.

## What installs

## The library

The itch.io section lists, once each:

1. the account's owned keys (games bought or claimed);
2. the games in the account's collections (`/profile/collections`, then each
   collection's `collection-games`; a collection that fails is skipped);
3. the free games added in Madeira with **Find a game** (kept on this device, per
   account, in `itch-added.json`).

Downloading a free game on the website makes no key, so it never reaches the
owned keys; adding it to a collection on itch.io, or **Find a game**, puts it in
the library. **Find a game** searches itch.io (`/search/games`) or opens a pasted
game link (`https://<author>.itch.io/<game>`: its page's `data.json`, else the
page's `itch:path` tag, gives the game id, then `/games/<id>`). A free or
name-your-own-price game gets **Add**; a paid one links to its store page.

itch.io decides ownership: a paid game's files are only listed and served for
its download key; a game with no key is asked for without one, which itch.io
answers for free games. Madeira lists games and tools with a Windows build (or no
platforms listed), and installs one upload:

1. the game's own Windows file (not a soundtrack, a preorder, or a demo when
   the full game is there);
2. a 64-bit or any-architecture file before a 32-bit one;
3. a `.zip` before an `.exe` (a butler build counts as a zip), then the biggest.

A `.zip` unpacks into `C:\itch\<title>`; a lone `.exe` goes there as it is.
Other archives (`.rar`, `.7z`) are not supported yet; the sheet says so. The unpacker reads the archive a piece at a
time (ZIP64 too), checks every CRC-32, and only replaces the install folder once
every file is in. Names that leave the folder, absolute names, encrypted entries,
symbolic links and two names that differ only in case stop it.

The program that starts the game is the first `[[actions]]` path of the game's
`.itch.toml`, else the folder's only program within three levels (uninstallers,
crash handlers and redistributables aside), else the one named like the game,
else the one nearest the top. When none is clear, the download fails with a note
to add the program by hand.

## Installers

A download that is an installer (`ItchSetup`, by the file's own markers, as the
itch app's installers find them) is not the game. Madeira keeps it in the game
folder's hidden `.madeira-setup` folder with a batch file, `install.bat`, and the
library entry runs that batch file, in the Wine desktop with Windows services
first, until the installer has run:

| Installer | Found by | Runs as |
|---|---|---|
| Inno Setup | `Inno Setup Setup Data`, `JR.Inno.Setup` or `InnoSetupLdrWindow` in its first 8 MB | `/SP- /SILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL /DIR="C:\itch\<title>"` (a progress window, no questions) |
| NSIS | `NullsoftInst` or `Nullsoft.NSIS` | `/S /D=C:\itch\<title>` (no window) |
| MSI | `.msi`, or the compound-file header | `msiexec /i … /qb /norestart TARGETDIR=… INSTALLDIR=… INSTALLFOLDER=…` |
| Other | `setup` or `install` in its name | as it is: the player answers its questions |

An archive whose only program within two levels is an installer is treated the
same way. The batch file writes `.madeira-setup\ran` when the installer ends.
After every session and when Madeira starts, an installer that ran gives way to
the game it installed: the game folder's program (the same rules as below), else
a new folder the installer made itself (in `Program Files`, `Program Files
(x86)`, `AppData\Local\Programs` or `C:\`), the one named like the game or the
only new one. The entry then starts the game directly, and `.madeira-setup` is
deleted. When an installer ran but nothing is found, Play runs it again. An update
that is an installer keeps the installed game and runs over it. Log tag
`[itch-setup]`.

Downloads pause for a game session and in the background (iOS's grace period),
and resume where they stopped. An update is offered when itch.io's chosen upload
or its build changes. `env.MADEIRA_ITCH = 0` turns the store off.

Tests: `tests/host/check-itch-store.py`.
