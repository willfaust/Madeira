# Madeira's Dock patches

Changes to Madeira Dock (the `madeira-dock` submodule) that live in this
repository until they are in Dock's own repository. `apply.sh` applies them,
in file-name order, to the `madeira-dock` working tree before
`build/madeira-dock/build.sh` builds `dockhost.exe`; it skips a patch that is
already applied, and `apply.sh --revert` takes them out. The `madeira-dock`
submodule pin does not change.

| Patch | What it fixes |
|---|---|
| `0001-scm-start-steam-client-service-before-ceg-request.patch` | Starts Valve's registered Steam Client Service before the custom-executable (CEG) request, so the request does not fail with 55 while the client's own demand start is still in progress under emulation (`MADEIRA_DOCK_CEG_SERVICE_START=0` skips it) |
| `0002-launch-retry-ceg-request-after-remote-call-failed.patch` | Sends a CEG request that failed with 55 (RemoteCallFailed) again, up to 3 times, 1.5 s apart |
| `0003-launch-start-when-ceg-already-prepared.patch` | Starts the game when Valve's client answers OK with no job, because it already prepared this account's executables (every launch after the first; Black Ops stopped with code 49 here until Repair) |

A patch must apply on the current `madeira-dock` pin. When the pin moves,
rebase the patches onto it (or drop a patch the new pin already covers).
