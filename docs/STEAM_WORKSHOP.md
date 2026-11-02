# Steam Workshop

Madeira lists, subscribes to and downloads a game's Steam Workshop items with
the signed-in Steam account, and puts them where Valve's client keeps them, so
a game started through Madeira Dock finds them installed.

The code is `app/Madeira/SteamWorkshop.swift` (the model, the game's Workshop
page and the library's Workshop area), `app/Madeira/SteamWorkshopFiles.swift`
(item decoding, the PublishedFile requests and Valve's Workshop record; no UI),
the Workshop part of `app/Madeira/SteamOwnedLibrary.swift` (the calls over the
app's own Steam connection) and `DepotDownloader.installWorkshopItem`.

## What you see

**Game details › Steam Workshop** (a Steam game's page; hidden only when Steam
says the game has no Workshop, `common.workshop_visible`):

- **Browse the Workshop**: the game's items, **Popular this week**, **Most
  subscribed** or **Most recent**, or a search; 30 at a time with **Load
  more**. **Subscribe** subscribes the account, as the Workshop's own button
  does, and downloads the item.
- **Download N items** when subscribed items are missing or Steam has a newer
  version of them; **Open the Workshop in Safari**.
- **Subscribed**: the account's subscribed items for the game, each with its
  preview, title and state (**Installed** with its size, **Update available**,
  **Not downloaded**, a download's progress, or why it failed). Swipe or hold
  an item for **Download**/**Update**, **Stop download**, **View on Steam**,
  **Unsubscribe and remove** and **Unsubscribe, keep files**.
- **Installed, not subscribed**: items on disk the account no longer
  subscribes to (for example ones a game fetched for a server), with
  **Subscribe** and **Remove files**.

**The library's Workshop area**: the **Workshop** button beside the Steam
section's title (signed in, with installed games) opens a list of the
installed Steam games, those with a Workshop first, each with how many items
are installed and how many wait to download; a game opens its Workshop page.

Nothing here runs while a game session holds the Steam account (Valve's client
in Madeira Dock has it then); a session that starts stops running Workshop
downloads, and Download continues them afterwards from the finished chunks.

## How it works

- **Lists and subscriptions** are Steam's PublishedFile service, called over
  the app's own logged-on connection (`SteamSession.callServiceMethodWithResult`,
  which also returns the response's EResult): `GetUserFiles` with type
  `mysubscriptions` (up to 1000 items, 100 a page), `QueryFiles` for Browse,
  `GetDetails` for installed items that are no longer subscribed, `Subscribe`
  and `Unsubscribe` on the subscription list with `notify_client`.
- **An item's files**: a current item is one manifest (`hcontent_file`) of the
  game's own Workshop depot, whose depot ID is the App ID. The depot key, the
  manifest request code, the content servers and the chunk download, check and
  resume are the game downloads' own (`docs/STEAM_LIBRARY.md`); the journal is
  `steamapps/workshop/downloads/madeira/<app>_<item>`. An older item is one
  file at a Steam URL (`file_url`): it is fetched over HTTPS from Steam's hosts
  only and saved under its own file name (`<item>_legacy.bin` when the name is
  unusable). A new version replaces the item's folder.
- **Where**: `steamapps/workshop/content/<app>/<item>` in the Steam library the
  game is installed in (Madeira's own or an external drive's).
- **The record**: `steamapps/workshop/appworkshop_<app>.acf`, in the format
  Valve's client writes: `WorkshopItemsInstalled` (size, time updated,
  manifest) and `WorkshopItemDetails` (manifest, time updated, time touched,
  the subscribing account, latest manifest). Entries Valve's client wrote are
  kept, as are its `TimeLastAppRan` and `LastBuildID`; it is written after the
  files. A game's ISteamUGC calls, answered by Valve's client in a Dock
  session, then report the items installed and current, so the game does not
  ask the client to download them again.

Log lines: `[steam-workshop]` (list, browse, subscribed, unsubscribed,
download begin/complete, installed, removed, failures with Steam's EResult).

## Switch

`env.MADEIRA_STEAM_WORKSHOP = 0` in madeira.cfg hides the page and the area.

## Limits

- Downloads during a game come from the game itself through Valve's client in
  Madeira Dock, not from here. A failure there ("Steam Error: Generic
  failure" in Garry's Mod) is Valve's client's; items subscribed and
  downloaded here beforehand avoid it for those items.
- Collections are listed but not subscribed to here; subscribe to their items.
- Dependencies an item names (required items) are not added automatically.
- Items Valve's client installed are shown and kept; their files are only
  changed by Download, Update or Remove.
