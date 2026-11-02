# JIT setup

Madeira needs an attached debugger to create executable memory on iOS. It can
use either the StikDebug app or its built-in StikJIT helper. Both methods send
the same bundled `madeira-jit.js` debugger script to the current Madeira
process.

## Automatic selection

The default **Automatic** method uses StikDebug when iOS reports that its
`stikdebug://` URL scheme is installed. Otherwise, it uses Built-in StikJIT.
Madeira does not silently switch methods after a failed attempt; the error is
shown so the pairing, VPN, or Developer Disk Image problem can be fixed.

Choose a method under **Settings → JIT**, or open **JIT setup** for its guided
setup and status. First-run setup offers three ways in, each with its own
numbered steps: **In-app** (pair this iPhone with Madeira, iOS 27 and
later) and **In-app with pairing file** both select Built-in StikJIT,
**StikDebug** selects StikDebug, and setting it up later leaves the current
method unchanged.

**Play** enables JIT itself when it is off: it runs the same flow as **Enable
JIT** (the loopback check and the Madeira JIT shortcut included), then starts
the game once the debugger is attached. Meanwhile the button reads **Starting
JIT**, with a spinner, and the game's page stays open. If JIT does not come on, the usual
error is shown and the game is not started; enabling JIT later starts nothing.
This also covers JIT enabled from StikDebug's own list, which sets CS_DEBUGGED
and leaves, so no debugger is attached.

## StikDebug

1. Install [StikDebug](https://github.com/StikDebug/StikDebug/releases/latest).
2. Import this iPhone's pairing file into StikDebug.
3. Install and connect
   [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044).
4. In Madeira, tap **Enable JIT**.

Madeira opens StikDebug's canonical `stikdebug://enable-jit` URL with Madeira's
bundle identifier, current process ID, and custom script. It waits up to 90
seconds for both the `CS_DEBUGGED` flag and a live debugger connection. Enabling
Madeira from StikDebug's own app list is not equivalent because that flow can
detach before Madeira creates its JIT pool.

## Built-in StikJIT

Built-in JIT requires iOS 26 or later and a normal sideloaded installation. It
is unavailable in the simulator and inside LiveContainer. It needs this
iPhone's remote pairing file, which Madeira can make itself on iOS 27, or
import.

### In-app pairing (iOS 27 and later)

iOS 27 can pair with a computer it finds on the local network, started from
the iPhone. Madeira plays that computer for its own iPhone, so no computer is
needed.

1. Turn on Wi-Fi. Tap **In-app**, then **Start pairing**, during first-run setup, or
   **Pair in Madeira** in **Settings → JIT → JIT setup**, and allow Local
   Network access when iOS asks.
2. Open **Settings → Privacy & Security → Developer Mode**, scroll down and
   tap **Pair with Madeira**.
3. Enter the code Madeira shows. It appears in iOS's background-task banner
   and as a notification, and in Madeira when you return.
4. Back in Madeira, continue with LocalDevVPN, **Check setup** and
   **Enable JIT** as below.

Madeira keeps running in the background while you are in Settings through an
iOS continued-processing task (`<bundle id>.pairing.session`). If iOS refuses
it, typically because the sideloader changed the bundle identifier, Madeira
only gets the usual ~30 seconds in the background and says so; go to Settings
straight away. A pairing that has not finished after five minutes is stopped.

Every pairing makes a new host key. The identifier stays the same, so the
iPhone replaces its earlier record for Madeira, and only the newest pairing
file works.

The pairing runs in `libmadeira_rppairing.a` (`build/rppairing-ios`), a small
wrapper around [idevice](https://github.com/jkcoxson/idevice)'s pairable-host
implementation. `app/Madeira/JITPairing.swift` advertises it as a
`_remotepairing-pairable-host._tcp` Bonjour service through mDNSResponder, so
only the Local Network permission is needed.

### Pairing file from a computer

1. Create a pairing file for this iPhone by following the
   [StikDebug pairing-file guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md).
2. Tap **In-app with pairing file**, then **Choose pairing file**, during first-run setup, or open
   **Settings → JIT → JIT setup** and tap **Import pairing file**.

### Enabling JIT

1. Install and connect LocalDevVPN.
2. Tap **Check setup**. Madeira checks VPN reachability and downloads, mounts,
   and verifies the matching Developer Disk Image when needed.
3. Tap **Enable JIT**.

Either way, the pairing file is kept in the Keychain, for this device only and
readable while it is unlocked, as the Steam sign-in token is. It is a credential
for the iPhone itself, so it is never stored in `Documents`, where the Files app
and every Windows program in Madeira could read it. Madeira sends its bytes only
to its bundled helper process for the current request. A copy an earlier build
left at `Documents/StikJIT/pairingFile.plist` is moved into the Keychain and
deleted the first time Madeira reads it. An installer that already holds this
iPhone's pairing file hands it over the same way:
[SideInstaller](https://github.com/FrizzleM/SideInstaller) writes it there when
it installs Madeira, and Madeira takes it in, as an imported file, the next time
it looks for one.

The helper is a classic app extension (`PlugIns/MadeiraJITHelper.appex`, on
the `com.apple.ar.viewer` extension point, as LiveContainer's LiveProcess is). A
separate process is required because a process cannot synchronously debug
itself. Madeira starts it through `NSExtension` by the bundle ID the helper has
in this installation, so it is found after a sideloader renames Madeira's bundle
ID (SideStore, AltStore and Plume append the team ID, to the helper's ID as
well). The request (PID, pairing data, script) goes in the extension request;
the helper uses StikJIT with `forceScript` enabled, stays alive while Madeira's
script services debugger requests, and answers when the request completes.
StikJIT.framework is in Madeira's own `Frameworks` folder (the helper loads it
through `@executable_path/../../Frameworks`), where sideloaders re-sign it.

An ExtensionKit extension, which the helper was before, does not survive such a
rename: its extension point is named in files sideloaders do not rewrite, so
iOS registers none for the renamed Madeira and the lookup fails ("Failed to add
observer").

If setup reports stale Developer Disk Image data after an iOS update, use
**Reset Developer Disk Image**, then **Check setup** again.

If the device resets the connection, it no longer accepts the pairing (each
in-app pairing replaces the last), so Madeira offers **Pair Again**. If the
device can't be reached, it offers **Connect LocalDevVPN**, or **Get
LocalDevVPN** when the app isn't installed; LocalDevVPN returns to Madeira
through its `madeira://` URL scheme once connected.

## LocalDevVPN, cellular data and the Madeira JIT shortcut

Both methods reach this iPhone's `lockdownd` through LocalDevVPN's loopback
(`10.7.0.1:62078`). The loopback works on Wi-Fi, or with no network at all,
but not while cellular data is in use.

**Enable JIT** first checks the loopback directly
(`app/Madeira/JITNetwork.swift`), in two steps that do not depend on what
`lockdownd` says (over USB it answers a plain `QueryType`; through the tunnel it
closed the connection instead):

1. The route: which interface traffic to `10.7.0.1` would leave by, asked of the
   kernel without sending anything. It must be LocalDevVPN's tunnel, whose
   address is in `10.7.0.0/16`. Through Wi-Fi or cellular, or through another
   VPN that carries all traffic (it accepts the connection, and the JIT helper
   then reads "early eof"), the check fails at once, so a network or VPN that
   accepts any connection is never asked.
2. Through a VPN interface: a TCP connection, at most 0.4 s. Through a working
   loopback it opens in milliseconds, and JIT is enabled with nothing else
   opening; over cellular data, where the tunnel does not work, it fails.

On a network that accepts any connection, the helper's own error reads "early
eof"; after a check that found no loopback, Madeira explains any JIT failure as
LocalDevVPN not routing.

When the loopback does not answer and **Settings → JIT → Madeira JIT
shortcut** is on (`env.MADEIRA_JIT_SHORTCUT = 1`), Madeira runs your
**Madeira JIT** shortcut:

- **"start"** (with "cellular" when Madeira sees cellular data and no Wi-Fi):
  keep the VPN that is connected now, if any (iOS connects one VPN at a time,
  so LocalDevVPN replaces it); turn Cellular Data off, only when asked; connect
  LocalDevVPN; and output the kept VPN, which tells Madeira whether one was on.
  LocalDevVPN's Connect can return before its tunnel routes, so Madeira checks
  the loopback again for up to 15 s, going on the moment it works, and enables
  JIT.
- **"done"**: with "cellular", turn Cellular Data back on; with "vpn-off" (no
  VPN was on), disconnect LocalDevVPN; with "vpn-restore", connect the kept VPN
  again (it replaces LocalDevVPN). Neither VPN word when LocalDevVPN was already
  connected. Madeira runs it once a game's JIT pool is mapped and the debugger
  has detached, before Wine starts, or at once if enabling JIT fails.

The shortcut keeps the VPN with **Store Content** (iOS 27): only that keeps a
VPN that **Set VPN** accepts. Saved as text (to a file, or as a name Madeira
passes back) it is only its name, and Set VPN cannot convert it ("couldn't
convert from Text to VPN"). Madeira keeps the "done" it owes on disk, so if it
is closed or crashes in between, the next launch runs it. On iOS 26, which has
no Store Content, use the LocalDevVPN prompt instead.

With the shortcut on, Madeira never opens LocalDevVPN's own link: when JIT still
cannot connect, the alert offers **Connect with Madeira JIT**, which enables JIT
again through the shortcut (on the JIT setup page it runs the shortcut, then
checks the loopback). Without it, the alert offers **Connect LocalDevVPN**.

An app can only run a shortcut by opening the Shortcuts app, so each run leaves
Madeira for a moment and returns through `madeira://jit-network/…`
(x-callback-url). Between **Enable JIT** and the game starting, cellular data
stays off.

**Known gap: no network at all.** With Wi-Fi and Cellular Data both off and
LocalDevVPN not connected, the shortcut cannot help: LocalDevVPN does not
connect without any network, so after the 15 s wait the JIT attempt times out
(`[jit-loopback] … no route`) and Madeira reports it cannot reach the device.
LocalDevVPN that was already connected keeps working with no network. Untested
fixes: the shortcut turning Wi-Fi on first (the radio alone, without joining a
network, may be enough; Control Center's Wi-Fi button only disconnects and
leaves the radio on, while Settings turns it off), or turning Cellular Data on
just long enough to connect LocalDevVPN, then off again. Madeira can tell this
case apart (its network path has no interface) and could pass the shortcut a
word for it.

### Getting the shortcut

On iOS 27 and later, setup shows **Connect automatically** on its own page
after any JIT guide, with **Add the shortcut** and the **Use it for JIT**
switch, and **Settings → JIT** has **Add the Madeira JIT shortcut**. Both open its iCloud link, which takes Shortcuts straight to **Add
Shortcut**, but needs a connection: iOS opens a shortcut directly only from an
iCloud link. Without one, **No internet connection? Add local copy** shares
the bundled `app/Madeira/Madeira JIT.shortcut` (a signed export): choose the
**Shortcuts** app in the share sheet, then **Add Shortcut**. Only the share sheet
can hand a file to Shortcuts: iOS gives Shortcuts the file only when the user
picks it there. Either way it is named **Madeira JIT**; then turn it on.

The iCloud link lives only while the shared shortcut stays in its owner's
library: deleting it there breaks the link. The iCloud link and the bundled
file must be the same shortcut. After changing
it, share a new iCloud link and export a new file (**Share** → **Options** →
**Anyone** → **Save to Files**), and replace both (`JITShortcutFile` in
`JITNetwork.swift`, and the file, keeping its name). The file's signing
certificate expires on 26 Oct 2027.

Its steps, to make it by hand (name it exactly **Madeira JIT**):

1. **Text**, with the *Shortcut Input* variable inside it. (*Shortcut Input* on
   its own is untyped, so **If** offers only "has any value"; its text offers
   "contains".)
2. **If** *Text* contains `start`
   1. **Get Current VPN** (before LocalDevVPN replaces it).
   2. **Store Content**: *Current VPN*, named `previous VPN`.
   3. **If** *Text* contains `cellular`: **Set Cellular Data** *Off*. End If.
   4. LocalDevVPN's **Connect** action (or **Set VPN** → *Connect* → LocalDevVPN).
   5. **Stop and Output** *Current VPN*.
3. **Otherwise**
   1. **If** *Text* contains `cellular`: **Set Cellular Data** *On*. End If.
   2. **If** *Text* contains `vpn-off`: LocalDevVPN's **Disconnect** action (or
      **Set VPN** → *Disconnect*). End If.
   3. **If** *Text* contains `vpn-restore`: **Get Stored Content** `previous
      VPN`, then **Set VPN** → *Connect* → that stored content, wired straight in
      (no Text in between). End If.
4. End If.

Then turn on **Settings → JIT → Madeira JIT shortcut**. Without the shortcut,
leave it off: Shortcuts would only report that the shortcut is missing.

## Signing and installation

The app and `MadeiraJITHelper` extension must be signed together. Sideloaders
must keep and provision the app extension (some ask whether to keep app
extensions). If an installer drops it, Madeira says the helper is missing;
select StikDebug instead.

To build Madeira under another bundle identifier, set the
`MADEIRA_BUNDLE_IDENTIFIER` build setting (for example in an `.xcconfig`
passed with `-xcconfig`). The app and the helper (`<id>.JITHelper`) follow it.

JIT also requires Madeira's executable to be signed as debuggable. Madeira
reports a signing error before attempting either method when that entitlement
is missing.

### Refreshing the signing

Off by default: refresh the signing with the installer that signed Madeira
(SideStore, AltStore, SideInstaller, a computer). A refresh asks Apple's
developer portal for a profile on the same Apple ID other sideloaded apps are
signed with, so Madeira leaves that to the installer. With it off, Settings has
no Signing section, nothing runs over the library and Madeira takes in no
sign-in an installer left. `env.MADEIRA_SIGNING_REFRESH = 1` in madeira.cfg
turns all of what follows back on.

A copy signed with a free Apple ID opens for seven days: that is how long its
provisioning profile lasts. **Settings → Signing** shows when it runs out, for
such a week-long profile only (a paid account's lasts a year). A new profile for
the same App ID, installed on the device, gives it seven more days, and Madeira
is not installed again. Madeira does that itself when it holds a sign-in to
Apple's developer portal: a token, never a password. It gets one from the
installer, or from an Apple ID sign-in in Settings.

[SideInstaller](https://github.com/FrizzleM/SideInstaller) leaves that sign-in
when it installs Madeira: the developer-portal token it signed in with
(`com.apple.gs.xcode.auth`), the team, the anisette identity the token was
issued to and the anisette servers SideInstaller uses. There is no password in
it, and the token only reaches the developer portal. SideInstaller writes it to
`Library/Application Support/SigningAccount.plist`, and only into a build whose
Info.plist names the version of the file it reads
(`MadeiraSigningAccountVersion`). Madeira moves the file into the Keychain when
it starts, before any Windows program runs, and deletes it. Apple states when
the token expires, which Settings shows; **Forget Apple sign-in** removes it.

A copy installed another way (SideStore, AltStore, Sideloadly, iloader, Xcode)
has no such file. **Settings → Signing → Sign in with Apple ID** makes the same
sign-in from the Apple ID that installed it (`app/Madeira/AppleSignIn.swift`):

- The sign-in is [isideload](https://github.com/nab138/isideload)'s, the
  library SideInstaller and iloader use (`madeira_apple_sign_in` in
  `build/rppairing-ios/src/apple_id.rs`): Apple's SRP exchange, in which the
  password does not leave the device, then the second factor when Apple asks
  for one (a code from a trusted device or by text).
- Madeira tells Apple it is iTunes on a Windows PC. The anisette servers make
  their data with Apple's library for Android. Since October 2026 Apple refuses
  a Mac on them ("This action cannot be completed at this time", error -80045),
  and since 2026-10-15 it answers the Android phone Madeira said it was in
  between with HTTP 503; the Windows PC gets through. Signed in as the Android
  phone, Apple sent the code to the trusted devices without being asked and did
  not say that it did, so when that happens Madeira asks for the code itself. A
  text cannot be asked for on this path.
- What Madeira keeps, in the Keychain, is what an installer hands over: the
  token, the team and the anisette identity, and the Apple ID's address to show
  in Settings. The password is not kept, so when Apple no longer accepts the
  token Madeira asks to sign in again; the identity is signed in as again, and
  Apple seldom asks for the code twice.
- An anisette server supplies the device data Apple asks for: `ani.sidestore.io`
  first, then five more from the list SideStore and SideInstaller read, when
  one gives nothing Apple takes. It sees neither the Apple ID nor the password.
  The list's two servers on Apple's library for Windows (`win.ani.sidestore.io`,
  `ani.jkcoxson.com`) are left out: Apple asks a new machine of theirs to be
  resynced first (error -22421), which isideload 0.4.4 cannot do. A server that
  gets that answer counts as one that gave nothing Apple takes.
- The Apple ID has to be the one this copy was signed with: Madeira takes the
  team from its own provisioning profile, and keeps no sign-in for another.

A refresh (`app/Madeira/SigningRefresh.swift`):

1. asks an anisette server for the identity's one-time headers: the one the
   sign-in was made through, then the others it holds;
2. finds Madeira's App ID in the portal, or registers it again when it has run
   out (a free Apple ID's lasts a week), with Increased Memory Limit enabled on
   the new one, and in the app group its installer signed it into, if any
   (iloader does, and SideStore and AltStore for an app that asks for one);
3. downloads the team provisioning profile, and checks that it grants what the
   installed copy is signed with and lists one of its certificates;
4. installs it on this device through LocalDevVPN, with the Built-in StikJIT
   pairing file (`madeira_rppairing_install_profile` in `build/rppairing-ios`:
   idevice's misagent client over the remote-pairing tunnel StikJIT uses too).

An extension an installer gave an App ID and a profile of its own (SideStore,
AltStore and Xcode do; SideInstaller and iloader sign the JIT helper with the
app's profile) is renewed the same way, in the same refresh.

It runs by itself when the library is on screen, LocalDevVPN is connected and
five days or fewer are left, and not while JIT is being enabled or a debugger
is attached. In the last two days, when that has not worked, the library says so
once a day and offers **Connect LocalDevVPN** or **Refresh Now**. The profile in
the bundle stays the one Madeira was installed with, so the new date is kept in
UserDefaults, for this installation.

When Apple no longer accepts the token (it has expired, or the Apple ID's
password changed), Madeira says so and offers **Sign In**; installing it again
with SideInstaller hands over a new one too. Without a sign-in, refresh Madeira
from the app that installed it; after one that renews the profile without
Madeira knowing (SideStore, AltStore), Settings shows no date once its own has
passed, until Madeira refreshes it itself. SideInstaller signs Madeira without
an app group, so that an App ID Madeira registers again needs none.

## Licensing

The bundled StikJIT 1.9.0 XCFramework is from
[StikDebug/StikJIT](https://github.com/StikDebug/StikJIT/releases/tag/1.9.0)
(`StikJIT.xcframework.zip` SHA-256
`806664393770c68e75f2b6429955bfdd88cfaad09fec2ba70f8ed615ff90c060`)
and is licensed under MPL-2.0. It includes the
[idevice](https://github.com/jkcoxson/idevice) library, licensed under MIT.
Corresponding source and license links are recorded in
[`THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md).

In-app pairing, the signing refresh and the Apple ID sign-in link idevice
0.1.68, [isideload](https://github.com/nab138/isideload) 0.4.4 (MIT) and their
Rust dependencies into the app from crates.io, pinned by
`build/rppairing-ios/Cargo.lock`. Those are under MIT, Apache-2.0, BSD, ISC,
Zlib, Unicode-3.0 or CDLA-Permissive-2.0, but for apple-codesign-quick
(LGPL-2.1-or-later), which isideload signs apps with and Madeira does not call.
Their notices are bundled as `legal/LICENSES-rppairing-crates.txt`.
