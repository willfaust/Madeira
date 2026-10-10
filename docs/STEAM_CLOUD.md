# Steam Cloud saves

Madeira syncs the save files of installed Steam games with the signed-in
account's Steam Cloud. It uses the app's own Steam connection (the one the
library and downloads use, `docs/STEAM_LIBRARY.md`), which is closed
while a game session holds the account: saves sync before and after a
session, and during one only on the game menu's upload button.

It is on by default. The **Steam Cloud saves** switch in **Settings › Steam**
turns it off, which keeps `env.MADEIRA_STEAM_CLOUD = 0` in `madeira.cfg`.
Off, Madeira checks, downloads and uploads nothing: Play never waits or
asks, the game page's Steam Cloud section and the game menu's upload button
are hidden, a running transfer stops between files, and saves stay as they
are on the device and in the cloud. The log says `[steam-cloud] off (setting)`
once per app run. Turning it back on drops what earlier checks found and
syncs the installed games at once against the record of the last sync.
`env.MADEIRA_STEAM_CLOUD_AUTO = 0` keeps the comparison and the game page
but copies nothing in either direction unless the user asks there.

## When it runs

- Once when Madeira starts, for every installed Steam game.
- When a Steam game's details page opens, and on its **Sync now** button.

- On **Upload saves and close Madeira** in the game menu of a running Steam
  game.

Madeira cannot close a game: the user leaves one by quitting the app. So
there is no sync at exit. What was played is uploaded at the next start,
unless the menu button sent it first.

The button works while the game still runs. Madeira's own Steam connection
is closed for a session, because a second logon replaces the first; the
button logs Madeira on again, which ends the logon of Valve's client in the
session, and the app quits once the upload is confirmed. It only uploads:
files that changed on this device and not in the cloud. It waits until two
looks 2 s apart find the same device files, since the game may be writing.
A file that also changed in the cloud is not sent without the user choosing
to replace the cloud's copy. On any failure the app stays open and says so.
`env.MADEIRA_STEAM_CLOUD_QUIT = 0` hides the button.

## Before a game starts

Play checks the game's cloud state first (`env.MADEIRA_STEAM_CLOUD_PLAY_CHECK = 0`
turns this off):

- In sync, checked in the last 10 minutes: the game starts.
- Not checked yet in this app run (Play pressed before the start-up sync got
  to the game), or checked longer ago: the saves are synced first, then the
  game starts.
- A check or transfer is running: an alert offers **Wait and sync** (the game
  starts when it finishes) or **Launch anyway**.
- The check failed (no network, for example): **Try again** or **Launch
  anyway**.
- Saves wait for a choice: **Choose** opens the game's page, or **Launch
  anyway**.

A start interrupts a running download between files, never inside one: each
file is written whole.

## What it does

1. Asks Steam for the app's cloud file list (`Cloud.GetAppFileChangelist`).
2. Maps each cloud path to a file of Madeira Dock's Wine prefix, through
   the `%Root%` placeholder of the path and the app's `ufs` product info:
   `GameInstall` is the game's folder, `WinAppDataLocalLow` and its
   siblings are under the Windows user folder (the one Wine names after
   `$USER`), and a path with no placeholder is under Steam's
   `userdata/<account>/<app>/remote`. Names are matched without regard to
   case. A path that would leave its folder is refused.
3. Compares SHA-1 and size, and also lists files matching the app's save
   patterns that the cloud does not have.
4. Looks each file up in its record of what was last identical on both
   sides (`steam-cloud-sync.json` in Application Support):
   - changed on one side only, or new on one side: copied to the other;
   - changed on both, or different with no record: **left alone**. The
     start-up check names the games, and the game's page shows each such
     save with both dates and sizes and asks which side to keep;
   - synced before and now missing on this device while the cloud still has
     it (a reset prefix, or the game deleted it): **a choice**, like a save
     that changed on both sides, and Play waits for it. Keeping the cloud's
     copy downloads it; keeping this device's state leaves it missing, which
     is recorded and not asked again unless the cloud's copy changes. Until
     the choice, a save of that name that appears on the device is a choice
     too, never uploaded over the cloud's copy unasked;
   - synced before and now missing in the cloud (deleted elsewhere): left
     alone, not sent back.

## Safety

- A downloaded file is checked against the SHA-1 in Steam's list before
  anything is written.
- Backups are kept where the Files app shows them, in
  `Madeira/Steam Cloud Backups/<game> (<App ID>)/<time>/`:
  - `device/` holds each device file a download replaced;
  - `cloud/` holds each cloud file an upload replaced. Steam keeps no copy
    of those, so Madeira downloads the cloud's copy (checked against its
    SHA-1) before the upload starts; if it cannot, nothing is uploaded.
- An upload over a differing cloud file only happens on the user's choice or
  when the record shows the cloud copy is the one this device last synced.
- Nothing is ever deleted in the cloud.

## Limits

- No download while a game runs, no upload except by the menu button, and no sync between pressing Play and the game
  starting: a cloud save newer than the device's that had not come down yet
  becomes a choice at the next start.
- A game whose Windows saves are redirected by a `rootoverrides` entry for
  Windows is compared and downloaded, but new device files there are not
  uploaded.
- Encrypted cloud files are not supported.
- Log tag `[steam-cloud]`: App IDs, counts and results; no file names or paths.
