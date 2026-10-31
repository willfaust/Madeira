# Square Enix sign-in

How Madeira signs a Square Enix account in to the official FINAL FANTASY XIV
servers and starts the game client with the session, without Square Enix's
launcher. Every fact comes from a source in "Provenance". Anything those
sources don't show is marked **unknown**. Don't fill those in from other
launchers' code.

**Scope:** Square Enix accounts (password and optional one-time password),
Windows and Mac licenses. Not covered: Steam service accounts, patching, and
SqexArg-encrypted arguments.

## Flow

| # | Step | Request | Status |
|---|---|---|---|
| 1 | Sign-in and gate status | `GET https://frontier.ffxiv.com/worldStatus/{login,gate}_status.json` | confirmed |
| 2 | Boot version check | `GET http://patch-bootver.ffxiv.com/http/win32/ffxivneo_release_boot/{boot_version}` | confirmed |
| 3 | Login page | `GET https://ffxiv-login.square-enix.com/oauth/ffxivarr/login/top?…` | confirmed |
| 4 | Credentials | `POST https://ffxiv-login.square-enix.com/oauth/ffxivarr/login/login.send` | confirmed |
| 5 | Boot hash | local files | confirmed (accepted in step 6) |
| 6 | Session registration | `POST https://patch-gamever.ffxiv.com/http/win32/ffxivneo_release_game/{game_version}/{SID}` | confirmed |
| 7 | Launch | `ffxiv_dx11.exe` with session arguments | confirmed, both licenses |

Madeira runs them in this order: the login status, step 2, steps 3 and 4,
the gate status, then steps 5 to 7. The boot check comes before the password
is sent, so an outdated game is reported first.

## 1. Sign-in and gate status

- `GET …/worldStatus/login_status.json`: the launcher checks it before
  showing the sign-in form.
- `GET …/worldStatus/gate_status.json?lang=en-us`: the launcher checks it
  after step 4.

Each returns a JSON object. Madeira continues only if both have `"status": 1`.
`gate_status.json` also returns a `message` array of maintenance text, even
while the gate is open. Only `status` decides.

## 2. Boot version check

- **`{boot_version}`:** the contents of `boot/ffxivboot.ver`. The wiki says
  `boot.ver`, which doesn't exist.
- **Plain HTTP:** the host's HTTPS certificate doesn't match it.
  `Info.plist` allows plain HTTP for this host only.
- **User-Agent:** the server ignores it. Madeira sends `FFXIV PATCH CLIENT`.

| Reply | Meaning |
|---|---|
| `204 No Content` | boot files are current |
| `200`, `multipart/mixed` patch list | outdated; each line is tab-separated: size, three unknown fields, target version, download URL |
| `404` | unknown version |

Anything but `204` stops with "the game needs updating". `X-Latest-Version`
only echoes the version sent; don't use it.

## 3. Login page

Query: `lng=en&rgn=2&isft={0|1}&cssmode=2&isnew=1&launchver=3`.

- **`lng`, `rgn`:** the launcher sends its own settings. Changing `rgn` from
  2 to 3 made no difference, so Madeira always sends `rgn=2` and `lng=en`.
- **`isft`:** `1` for a free trial account.
- **`cssmode`:** only the page theme.

The reply is an HTML form (`action="login.send"`). Madeira reads the `value`
of the input named `_STORED_` by attribute, not by position.

## 4. Credentials

Send a form-encoded **body**, never the URL, in this order:
`token=&_STORED_=…&sqexid=…&password=…&otppw=…`.

- **`otppw`:** empty when no one-time password is used.
- **`saveid`:** omitted, as an unticked "remember ID" box would be.
- **Referer:** the `login.send` URL.

The reply is HTML containing `window.external.user("…")`:

- `login=auth,ok,` then comma-separated **name, value pairs**:
  - `sid`: 56 hex characters.
  - `region`: passed to the client.
  - `maxex`: the highest owned expansion, passed to the client.
  - `playable`: must be `1`.
  - `terms`: `1` on a normal account.
  - `etmadd`, `ps3pkg`, `product`: unknown.
- `login=auth,ng,err,` then Square Enix's message: show it as sent.

Every login page also carries a commented-out
`//window.external.user('login=auth,ng,err,…')` line, whatever the outcome.
The parser skips comment lines.

**Never retry a refused sign-in.** Repeated wrong passwords can lock the
account. A successful reply also sets a `_rsid` cookie, which only remembers
the ID for the form. Madeira's session is ephemeral and doesn't keep it.

## 5. Boot hash

For each of `ffxivboot.exe`, `ffxivboot64.exe`, `ffxivlauncher.exe`,
`ffxivlauncher64.exe`, `ffxivupdater.exe` and `ffxivupdater64.exe` in `boot/`,
in that order, skipping files that don't exist (today only the four 64-bit
and boot ones exist):
`{name}/{size in bytes}/{lowercase SHA-1}`, joined with commas.

## 6. Session registration

- **URL fields:** `{game_version}` is the contents of `game/ffxivgame.ver`;
  `{SID}` comes from step 4.
- **Headers:** `X-Hash-Check: enabled`, the license's patch User-Agent and
  `Content-Type: application/x-www-form-urlencoded`.
- **Body:** `\n`-separated lines, with no newline after the last:
  `{boot_version}={boot_hash}`, then `ex{N}\t{version}` for each installed
  expansion, with the version read from `game/sqpack/exN/exN.ver`.
- **Reply:** when the game is current, the reply is `204` and its
  `X-Patch-Unique-Id` header is the session ID. When it is outdated, the reply is `200` with a
  `multipart/mixed` patch list (the same tab-separated lines as step 2, with
  more fields) **and** an `X-Patch-Unique-Id`, so the header alone does not
  mean the game may start: a reply whose body lists patches means "update
  needed". With no header at all, the game needs an update or its files were
  changed. The list's format is in `docs/FFXIV_PATCHING.md`.

## 7. Launch

Start `game/ffxiv_dx11.exe`, whichever FFXIV program the entry names, with
six unencrypted `name=value` tokens:

- `DEV.DataPathType=1`
- `DEV.MaxEntitledExpansionID={maxex}`
- `DEV.TestSID={session ID}`
- `DEV.UseSqPack=1`
- `SYS.Region={region}`
- `ver={game version}`

`language` isn't needed.

## Windows and Mac licenses

| | Mac | Windows |
|---|---|---|
| Sign-in User-Agent | `macSQEXAuthor/2.0.0(MacOSX; ja-jp)` | `SQEXAuthor/2.0.0(Windows 6.2; ja-jp; {id})` |
| Patch User-Agent | `FFXIV-MAC PATCH CLIENT` | `FFXIV PATCH CLIENT` |
| `wine_get_host_version` | visible, reports `Darwin` | hidden from `GetProcAddress` |
| Start | as the entry's Launch › Start says | always in the Wine desktop |

**The Windows `{id}` has a check byte.** Read as hex, its five bytes must add
up to a multiple of 256 (for example `5fd2faa332`), or the login page returns
an error page. The wiki says any value works; it doesn't.
`SquareEnixSignInOptions.newInstallID()` makes valid IDs.

**The game picks its version itself.** The Mac and Windows versions name their
graphics presets differently, which shows which one is running. The game
looks up `wine_get_host_version` (a Wine-only `ntdll` export, and the only
Wine name in its executables). Under Madeira that export reports `Darwin`, so
the game runs as the Mac version, whatever User-Agents were sent.

**Under the Windows license, two changes are needed:**

1. **Hide the function.** `build/wine-pe/patches/ntdll-hide-wine-host-version.patch`
   is applied by `build-ntdll.sh` for its build only. While
   `MADEIRA_HIDE_WINE_HOST_VERSION=1` is set, `LdrGetProcedureAddress` doesn't
   find `wine_get_host_version`. Load-time imports still resolve (`shell32`
   imports it). Reporting another name instead (`Linux`) also selects the
   Windows version.
2. **Start in the Wine desktop.** The Windows version opens a process handle,
   then starts a copy of itself and exits. As Wine's first process (a direct
   start), the copy never got past its loader (`NtGetNextThread` never
   returned). With `explorer.exe` first, it starts normally.

The test account had both licenses, so a refusal for a single-license account
under the wrong setting hasn't been observed.

## In Madeira

- **Only recognized FFXIV entries.** An entry is FFXIV when its program is
  `boot/ffxivboot.exe`, `boot/ffxivboot64.exe`, `boot/ffxivlauncher64.exe` or
  `game/ffxiv_dx11.exe`, beside `boot/ffxivboot.ver` and
  `game/ffxivgame.ver`. Steam, Epic and the Desktop are never FFXIV. Madeira
  sign-in is the only way such an entry starts; Square Enix's launcher doesn't
  run in Madeira's Wine.
- **The Square Enix section on the details page:**
  - **License:** Windows or Mac, chosen before the first Play.
  - **Free trial account.**
  - **Remember sign-in:** keeps the ID and password in the Keychain (service
    `madeira.squareenix.signin`, one item per entry, this device only). It is
    off by default. A one-time password is never kept.
- **Play signs in each time,** in a sheet over the details page, before the
  launch. The sheet:
  - checks first that a session can start, so a password is never asked for
    a launch that can't happen
  - shows each step's progress and Square Enix's messages
  - never retries a refused password, and deletes a remembered one (the reply
    doesn't say which field was wrong)

  Canceling or failing leaves the app run's one Wine session unused.
- **The session is for one launch only.** On success the sheet sets that
  launch's transient program and arguments, which `applyEnvironment` clears.
  `build/madeira_redact.h` hides `DEV.TestSID` in logged command lines.
  Exception: with Wine's `trace+process` channel on (off by default),
  `kernelbase` prints it unredacted.
- **Files:**
  - `app/Madeira/SquareEnixSignIn.swift`: the protocol, Foundation and
    CryptoKit only.
  - `app/Madeira/SquareEnixSignInView.swift`: recognition, the Keychain, the
    section and the sheet.
  - Entry fields `squareEnixLicense`, `squareEnixFreeTrial` and
    `squareEnixRemember`.
  - The Windows ID, stored once per install in UserDefaults
    (`madeira.squareenix.install-id`).
  - `tests/host/check-square-enix-signin.py`: a scripted transport and
    hand-written pages.
  - `tools/sqex-signin-probe.py`: runs steps 1–6 live from a Mac without
    starting the game.

## Open questions

- Whether a direct start could survive the game's restart under the Windows
  license, and what the game checks before restarting.
- Whether a single-license account is refused under the wrong setting, and
  where.
- What `etmadd`, `ps3pkg` and `product` mean, and what a `terms` value other
  than `1` requires.

## Provenance

Written for Madeira on 2026-10-29 as an independent implementation, with AI
assistance (Claude). Protocol facts are restated in new wording. No source's
prose or code is copied.

- **The xiv.zone wiki** (`https://wiki.xiv.zone/`, CC BY-SA 4.0), read on
  2026-10-29: "Logging into Official Servers" rev. 204, Client rev. 191,
  Launcher rev. 267, SqexArg rev. 205, Frontier Server rev. 195, Patch Server
  rev. 200 and Login Server rev. 197.
- **First-hand observation:**
  - captures of Square Enix's official macOS app signing in (private, since
    they contain credentials), including the facts its launcher web code uses
    to build the login query
  - direct requests to the public endpoints
  - a string search of the game's executables
  - sign-ins with the probe and with Madeira on an iPhone
- **Not opened:** third-party launchers (XIVLauncher / FFXIVQuickLauncher,
  XIVLauncher.Core, XIV on Mac, Astra, microlaunch, L4-cpp, Kawari), the
  code the wiki links to, the wiki's code snippets, and earlier sign-in code
  written for Madeira forks. `check-square-enix-signin.py` fails if the
  sign-in core names a third-party launcher.

CC BY-SA 4.0 is one-way compatible with GPL-3.0, so even if this document
counts as an adaptation of the wiki, it can be distributed here with the
credit above. (This isn't legal advice.) The code implements this document
and carries the copyright and license headers in its files.

## Confirmation log (2026-10-29)

Never record credentials, SIDs, `_STORED_` values or session IDs here.

| Step | Method | Finding |
|---|---|---|
| 1, 3, 4 | captures of the macOS app | status endpoints, login query and form, form-encoded credentials, 8 reply pairs, `_rsid` |
| 2 | direct requests | `204` current, `200` patch list, `404` unknown; User-Agent ignored; HTTPS host mismatch |
| 3 | login page requests | the Windows ID check byte; the Windows version in the User-Agent is ignored |
| 1–6 | probe, both licenses | four-file boot hash, expansion lines and both patch User-Agents accepted; `rgn=3` same as `2` |
| 1–7 | Madeira on iPhone, Mac license | signed in, the six tokens accepted, played normally |
| licenses | Madeira on iPhone, Windows license, User-Agents only | the game showed the Mac presets |
| licenses | the same with `Linux` reported, or the function hidden | the Windows version, which stalled in a direct start |
| licenses | `WINEDEBUG` trace | the Windows version restarts itself; the copy stops in its loader in a direct start |
| licenses | Madeira on iPhone, Windows license, Wine desktop | launched; the desktop start is automatic and the Mac license still starts directly |
| 6 | probe with `--game-version 2012.01.01.0000.0000 --save-reply` (2026-10-31) | an outdated game gets `200`, a patch list and an `X-Patch-Unique-Id`; the sign-in now stops with "update needed" for such a reply |
| 1–7 | Madeira on iPhone with that change, both licenses (2026-10-31) | a current game gets `204` with the session ID; signed in and launched with the Mac and the Windows license |
