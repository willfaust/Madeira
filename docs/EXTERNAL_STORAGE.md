# External SSD game libraries

Madeira supports one registered external library alongside the existing iPad
library. Select a dedicated folder on a locally attached SSD in Settings → Game
storage, then choose its name under Download to for a new install. Existing and
partial installations retain their destination for resume, update and repair.
Moving installations, duplicate installs of an App ID, network shares and cloud
providers are outside this version's scope.

## Storage and identity

Game payloads, app manifests, depot caches and download journals live in
`<selected folder>/steamapps`. The Wine prefix, registry, Steam client and normal
Windows user folders remain internal. Saves beside a game's executable remain
on the SSD. Uninstall removes those saves with the game files.

An internal catalog stores a library UUID, display name, directory bookmark and
per-game relative paths. Legacy library entries without a library ID remain
internal without moving files. A `.madeira-library-id` marker distinguishes the
registered folder from another volume at an old mount path. Reconnect never
recreates a missing marker or silently redirects work to internal storage.

The folder picker opens in place. Security-scoped access and file coordination
cover the operation lifetime, including downloader cleanup and the entire Wine
session. Bookmark refresh occurs only when stale. Paths reject traversal and
symlink components within the selected library; the selected root itself is
resolved while its scope is held. Catalog updates are transactional.

## Windows paths

The session creates two owned mappings to the same directory:

- E: is the canonical Wine drive for executable, installer and working paths.
- `C:\MadeiraExternalLibrary` is the Steam client library root and Dock's expected
  install path. Valve's tested client rejected E: as unmounted; using the existing
  C: mount succeeded. This alias does not copy the payload onto internal storage.

Mapping replacement checks the recorded owner and refuses unrelated existing
files or links. Steam library registration preserves other libraries and unknown
metadata. Internal discovery does not reclassify the external alias as an iPad
installation. The native bridge resolves E: only with the registered identity
and marker; no Z: fallback or unrestricted mount-path access is introduced.

## Disconnects, progress and saves

Disconnected games remain listed. Play, Resume, Update and Repair require a
writable library; the game shows a separate Check SSD connection action. Visible
game details check removal roughly every two seconds while foregrounded, subject
to provider latency. Reconnect the drive, check its connection, and retry. Select
library folder again is for restoring permission to the original folder.

Downloads write in place and publish the install record last. Resume validates
chunks against journals; completed chunks are reused. Pausing waits for file
verification to stop. An internal progress snapshot preserves displayed counts
across restarts, but journals and chunk checks remain authoritative. Capacity
checks use the destination volume and distinguish sparse file length from blocks
already allocated. Later filesystem failures remain resumable errors.

Uninstall removes catalog entries only after deletion succeeds. A failed delete
can leave some files removed; reconnect and retry or repair. Ordinary network
failures do not mark an accessible SSD disconnected.

Cloud GameInstall paths use the registered root, including local-only save
scanning. Missing storage aborts comparison/upload/download instead of treating
saves as deleted. Reconnect clears failed cloud checks for a fresh audit, without
clearing unresolved conflicts. Normal Windows user-folder saves remain internal.
Removing the SSD during gameplay can end the session and lose unsaved progress.

## Host validation

Run from the repository root:

```sh
python3 tests/host/typecheck-ios.py
python3 tests/host/check-steam-library.py
python3 tests/host/check-steam-games.py
python3 tests/host/check-steam-cloud.py
python3 tests/host/check-dock-contract.py
python3 tests/host/check-dock-installers.py
python3 tests/host/check-launch-routing.py
python3 tests/host/check-frontend.py
python3 tests/host/check-dock-start-screen.py
```

The library integration suite executes production downloader code with a local
content server. It covers internal and external installs, interrupted transfers,
chunk reuse, update/repair/uninstall, failed deletion, identity/path rejection,
progress persistence, cancellable verification and sparse offsets beyond 4 GiB.
Cloud checks execute production path resolution and sync planning. Native routing
checks exercise the E: resolver with address/undefined-behavior sanitizers.

On macOS, `python3 tests/host/check-steam-storage-volumes.py --with-downloads`
creates bounded disposable APFS and exFAT images, tests full and read-only volumes,
and runs the external downloader lifecycle on each. It removes only its own
scratch images and fixtures. These checks do not contact Steam or use credentials.
Initialize the pinned Madeira Dock submodule for the contract check. See each
harness for compiler/library requirements.

## Device evidence and remaining work

Development testing on an iPad used an isolated app with the current Swift
frontend and a preserved OpenGL-capable native runtime, not a full native rebuild.
The native input SHA-256 was
`d942617b44d57bb23b3e97dce87cf5272265e239dc5d6434dac11030341d6446`.
Native E: bridge changes were not included in that binary. A controlled x64
EXE/DLL fixture supplied its own working directory. The development harness and
private deployment history are intentionally not production dependencies.

Observed successes in that development build:

- Scoped create/read/write, seek, rename, reopen and memory mapping; bookmark
  recovery after unplug/reconnect without selecting the folder again.
- Controlled external x64 EXE, companion DLL, relative asset and beside-EXE save.
- Fresh Steam SSD installs and playable Brotato and Borderlands GOTY through Dock
  using the C: alias. Borderlands resumed after a mid-download disconnect.
- Reconnect/relaunch without an app restart or a cloud-check bypass; existing
  progress appeared available to the owner.
- Open-card removal disables Resume; reconnect restores it; paused counts survive
  closing/reopening the app. The owner also reported the subsequent
  verification-pause/resume check passed.
- Internal game-payload growth remained zero during measured external installs;
  prefix/client/prerequisite files still consumed some internal storage.

The main-based PR subsequently compiled and linked successfully with rebuilt
native archives using Xcode 27. The isolated app passed deep/strict signature
verification and was installed. Its first device check exposed missing Dock
packaging: the library was hidden despite the persisted SSD catalog remaining
intact. Dock and the full i386 Wine/DXMT farm were then built, packaged and
reinstalled; the i386 dependency check reported zero missing imports. Device
gameplay acceptance of the corrected package remains pending.
See [BUILDING.md](BUILDING.md#native-link-validation-for-external-storage) for
the additional clean-build prerequisites. Remaining checks include the final
UI/accessibility pass,
native direct launch/CWD (including 32-bit), active background expiration, cloud
upload/conflict continuity and physical iPad low-space/read-only/large-file and
APFS/exFAT combinations. Desktop visibility during startup remains unexplained.
One DirectX prerequisite returned a failure despite successful Borderlands play.
No JIT, graphics, per-game tuning or submodule changes are part of this feature.

The native package's first launch attempt also exposed Steam rewriting
`libraryfolders.vdf` without Madeira's custom ID. Registration now recovers that
entry only after the SSD marker and mappings have been validated and the separate
prefix ownership record matches. Explicit foreign IDs and unowned aliases remain
refused. Host regression coverage includes repeated rewrites and refusal cases;
physical relaunch validation remains pending.
