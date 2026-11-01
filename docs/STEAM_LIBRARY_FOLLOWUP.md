# Native Steam Library failure — 2026-11-01

Scope: the **Library** tab displays “Failed to load”; this is not Downloads.
The user confirms successful Windows Steam sign-in and rendered Chromium UI.
Those working paths and installed data must be retained.

## Evidence and limits

The first supplied attachment had 41,333 Madeira lines. Its path disappeared
when the request was repeated. The reattached files were copied to untracked
workspace storage immediately: 20,039 Madeira lines and 6,025 cumulative CEF
lines. They identify the delivered E1CA4E18-2EB6-39BD-9103-E65049E355DD image.
The newest Madeira capture begins at local14:51; CEF contains older08:37–08:41
entries and later19:51 startup. The label084246 does not identify every entry
in this cumulative file. Do not attribute the old authentication polling errors
to the user's now-working sign-in.

The retained08:42 session's CEF output contains:

* 08:39:22 TypeError, undefined.get, shared chunk2dcc5aaf7;
* 08:39:51 SteamApp Init - AppStore - AppStore - ERROR Remote call failed;
* 08:40:02 MobX Autorun reports the same undefined.get error;
* 08:40:50 and08:41:41 navigation tracking identifies /library/home.

This establishes a failed AppStore initialization before the observed Library
navigation. It does not identify the RPC method, response or first cause.
Reading library.js is insufficient to establish that game data arrived.
Madeira's installed=2 ready=2 confirms its own manifest discovery, not Windows
Steam's authenticated Apps API result for730.

Port27018 samples report real nonblocking completion, err0, peerYES, followed by
TLS exchanges. The initial connect ret=-1 is not itself a failed connection.
Other sockets show real Darwin errors65/61 but lack the request ownership and
endpoint correlation needed to attribute them to the Library RPC. No socket
error is converted to success and no connection guard is removed.

## On-device observer

The candidate uses CEF's normal developer protocol, with a randomly selected
loopback port passed only to the native Steam browser launch. It does not bind
an external interface, intercept requests, weaken certificates, or change Steam
credentials. The app's ATS exception permits local networking only. The CEF
developer endpoint exists while that browser lives; the app's observations stop
after ten minutes. `env.MADEIRA_STEAM_LIBRARY_TRACE_OFF=1` disables it next start.
Only startup commands naming steam.exe, steam-launch.bat or the new native launch
script enable the observer. Dock and ordinary game starts retain their paths.

The observer records navigation, failed resource URL/status or net error,
console error classifications with source line/column stacks, unhandled
exceptions/rejections, WebSocket direction/length/errors, and selected
SteamClient.Apps method names and argument counts. Query strings, fragments,
headers, cookies, bodies and raw RPC payloads are excluded. Public resource
paths remain available for diagnosis. It does not record the whole owned-game
list; array count and presence of AppID730 are sufficient for this test.

Diagnostic method wrappers preserve this, argument and callback identities,
synchronous results, original promise identity and thrown error identity.
Callback arguments are not wrapped. Promise responses are inspected through
Runtime.getProperties; no then/catch/awaitPromise handler is attached, preserving
unhandled-rejection behavior. Response metadata reports type/count,730 presence,
numeric error code and the specific Remote-call-failed classification. Pending
responses are sampled for25seconds. Weak references and inspector object groups
bound retention. Read-only/locked bindings can refuse instrumentation; this is
reported rather than overriding their attributes.

Bounds: four page connections,300 emitted records,8,000 received events,512
in-flight request records,64 command callbacks and24 inspected promises.
Each page's JS observer emits at most160 events. The observer is diagnostic;
it does not claim to repair the still-unidentified Library RPC.

## Normal Windows Steam launch alternative

Game details > Steam > Start with > **Steam client**, then Play, starts the
existing Windows client with its normal `-applaunch <AppID>` mechanism. The
currently working client flags and service prerequisite are reused. Steam owns
sign-in, ownership checks, launch settings and game creation. No game executable
is substituted and no Dock authentication handoff is used.

The app re-reads the original appmanifest, checks its numeric ID and installed
state, confirms its recorded game folder and existing steam.exe, and writes only
an app-owned transient launch script. It does not reinstall, repair, rewrite
manifests, clear sign-in data, or modify Steam/CS2 files. The original saved game
entry and per-game preferences remain separate from the generated command.
This mode requires ending the current Wine session before starting; it is not
an IPC command injected into an already-running Steam instance. Saved Windows
Steam authentication remains in the same prefix. Existing Dock/direct modes
remain defaults until the user explicitly chooses Steam client.

## Validation and acceptance

Node executes the actual observer against native-style APIs and verifies
argument/callback/result/promise/throw identities, unhandled rejection, metadata
failure isolation and logging bounds. The macOS suite compiles the actual Swift
actor and native-launch preparation, using real appmanifest parsing and fixture
files to check no installed/auth data changes. Existing CEF-policy, Steam
identity, JIT, process, controller-related and packaging checks remain in CI.

The underlying Library failure is unresolved until a device trace names its
first failed RPC/resource and response. No Library success, Windows Steam
recognition of730, or CS2 launch is claimed from these source/host checks. VAC,
Steam authentication and existing installation checks remain authoritative.
