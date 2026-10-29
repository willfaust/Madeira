# GOGClient: GOG sign-in, library and content

`GOGClientKit` is GOG's side of the PC-store plan (docs/plans/finished.md#pc-import-gog-and-epic,
Phase 2), on [ContentKit](../ContentKit/README.md)'s install core. Foundation only; `pp test`
runs its offline tests on the Linux host.

- **Session** (`GOGSession`): GOG's desktop-client identity (decision 0058). The app's sign-in
  sheet opens `GOGAPI.loginURL`; the page GOG redirects to carries a code, which the session
  trades for tokens at `auth.gog.com/token` and keeps only in the credential store (the
  Keychain, service `dev.playport.app.gog`). Tokens refresh five minutes before they expire.
  Sign-out deletes the item; GOG has no revoke endpoint.
- **Library** (`GOGLibrary`): `embed.gog.com/account/getFilteredProducts`, the owned Windows games.
- **Content** (`GOGContent`, generation 2): the builds, newest first; a build's zlib JSON
  manifest (install folder, depots by language, bitness and product; its cloud credentials
  are not read); each depot manifest's files and chunks (path-checked by `SafePath`). The
  plan installs the base game's and owned DLCs' depots, 64-bit or neutral, in the player's
  language plus the neutral ones, including GOG's own depot with `goggame-ID.info`.
- **Chunks** (`GOGChunkSource`): a signed, expiring secure link per product, renewed when the
  CDN refuses it; each chunk's zlib bytes match its compressed md5 and its plain bytes its md5.
- **Installer** (`GOGInstaller`): a first install stages the whole build and commits it with
  one rename; an update stages only the files whose chunks changed, moves them in and removes
  the ones the build dropped; verify checks every file by size and md5 against the kept record
  (`manifests/gog-ID.json`), and repair fetches what fails. The app writes the store receipt
  from `goggame-ID.info`.

Measured from the workstation (2026-10-06, Shogun Showdown, 1104084973): build 0.9.1.3
(397 MB, 204 files) in 4.4 s; the update to 1.0.2.1a fetched 172 changed files; verify
clean; a corrupted executable found and repaired.
