#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Signing that runs out, renewed by Madeira itself (docs/JIT.md).

Source checks:
1. The sign-in an installer leaves is taken into the Keychain at start (this
   device only, readable while unlocked), before anything else runs, and the
   file is deleted; no password is in it, and Info.plist names the version of
   the hand-over Madeira reads.
2. A refresh asks the anisette server and Apple's developer portal with that
   sign-in, registers an App ID that has run out again with its capability and
   its app groups, and installs only a profile that covers the installed copy,
   for the app and for an extension with a profile of its own.
3. The profile goes to the device through the pairing file's tunnel; the
   library's pairing connection is verified, never started anew.
4. It runs by itself only when it can work and never while JIT is being
   enabled; the log carries no token, identifier or account.
5. A pairing file left at Documents/StikJIT/pairingFile.plist is taken into
   the Keychain through the same validation as an import.
6. A copy no installer left a sign-in for signs in to its Apple ID in
   Settings: through isideload, off the main thread, once per anisette server
   until one works and never twice after Apple's refusal; only for the team
   the copy was signed by; and neither the password nor anything that names
   the account is kept, logged or written to disk.
7. The Xcode project, the Settings page, the header and the documentation are
   in step.

On a Mac with swiftc, the portal client and the sign-in's flow are also compiled
and run (signing-refresh-harness.swift) against stand-ins for Apple, the anisette
server, the Keychain and the library: what is asked of Apple and in which order,
the second factor's hand-over between threads, and what is kept.
"""
from pathlib import Path
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def block(text, header):
    start = text.index(header)
    brace = text.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


signing = (app / 'SigningRefresh.swift').read_text()
setup = (app / 'JITSetup.swift').read_text()
library = (app / 'Library.swift').read_text()
main = (app / 'MadeiraApp.swift').read_text()
header = (app / 'MadeiraRPPairing.h').read_text()
rust = (root / 'build/rppairing-ios/src/lib.rs').read_text()
signin = (app / 'AppleSignIn.swift').read_text()
apple = (root / 'build/rppairing-ios/src/apple_id.rs').read_text()
cargo = (root / 'build/rppairing-ios/Cargo.toml').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
docs = (root / 'docs/JIT.md').read_text()
with (app / 'Info.plist').open('rb') as f:
    plist = plistlib.load(f)

# ------------------------------------------------------------------ the sign-in
account = block(signing, 'struct SigningAccount')
store = block(signing, 'enum SigningAccountStore')
take = block(store, 'static func takeIn()')
require(all(f'var {field}:' in account for field in
            ['version', 'teamID', 'adsID', 'token', 'tokenExpires', 'anisetteIdentifier', 'anisetteProvisioning', 'anisetteServers'])
        and 'password' not in account.lower().replace('no password', ''),
        'the sign-in is a portal token and an anisette identity, with no password')
require('static let version = 1' in account and plist.get('MadeiraSigningAccountVersion') == 1
        and 'version == Self.version' in account,
        'Info.plist names the version of the hand-over Madeira reads, and only that one is taken')
require('anisetteIdentifier.count == 16' in account and '!anisetteServers.isEmpty' in account
        and 'anisetteServers.allSatisfy { URL(string: $0)?.scheme == "https" }' in account,
        'an identity that is not 16 bytes, or a server not reached over HTTPS, is refused')
require('kSecAttrAccessibleWhenUnlockedThisDeviceOnly' in store and 'SecItemAdd(add as CFDictionary, nil)' in store
        and '.applicationSupportDirectory' in store and '.documentDirectory' not in signing,
        'the sign-in is kept in the Keychain, this device only; the hand-over file is outside Documents')
require(take.index('guard store(account) else { return }') < take.rindex('removeItem(at: handoff)')
        and take.count('removeItem(at: handoff)') == 2,
        'the file is deleted once the Keychain holds it, and at once when it is not one Madeira can use')
init = block(main, 'init()')
require('SigningAccountStore.takeIn()' in init, 'the sign-in is taken in when Madeira starts, before any game can')
require('SigningAccountStore.forget()' in block(signing, 'func forgetAccount()') and 'Forget Apple sign-in' in signing,
        'Settings can forget the sign-in')
require('SecureField' not in signing and 'TextField' not in signing and 'gsa.apple.com' not in signing
        and 'var appleID: String?' in account,
        'the refresh asks for no Apple ID: a hand-over names none, and a sign-in in Madeira is a sheet of its own')

# ------------------------------------------------------------------ the portal
portal = block(signing, 'struct DeveloperPortal')
opened = block(portal, 'private static func open(')
require('for server in account.anisetteServers' in block(portal, 'static func open(')
        and 'appendingPathComponent("v3/get_headers")' in opened and '"identifier": account.anisetteIdentifier.base64EncodedString()' in opened
        and '"adi_pb": account.anisetteProvisioning.base64EncodedString()' in opened,
        'the anisette servers are asked in turn for the identity\'s one-time headers')
signed = block(portal, 'private func signed(')
require('"X-Apple-GS-Token"' in signed and '"X-Apple-I-Identity-Id"' in signed
        and 'https://developerservices2.apple.com/services' in portal,
        "requests go to Apple's developer portal with the token and the account")
send = block(portal, 'private func send(')
require('if code == 1100 { throw Failure.signInRefused }' in send and 'if status == 401 { throw Failure.signInRefused }' in portal,
        'a token Apple no longer accepts is told from other failures')
renewed = block(portal, 'static func renewedProfile(')
require(renewed.index('portal.appID(for: bundleID)') < renewed.index('portal.addAppID(name: name, bundleID: bundleID)')
        < renewed.index('portal.profile(for: app)'),
        'an App ID that has run out is registered again before the profile is asked for')
require('portal.enableIncreasedMemory(for: app)' in renewed and '"INCREASED_MEMORY_LIMIT"' in portal,
        'a new App ID gets Increased Memory Limit when the installed copy is signed with it')
require('installed.entitlements.subtracting(new.profile.entitlements)' in renewed and 'guard missing.isEmpty' in renewed
        and 'isDisjoint(with: new.profile.certificates)' in renewed,
        'only a profile that grants what the copy is signed with, for one of its certificates, is accepted')
groups = block(portal, 'func assign(groups identifiers: [String]')
require('portal.assign(groups: installed.groups, to: app, named: name)' in renewed
        and 'Set(installed.groups).isSubset(of: new.profile.groups)' in renewed and 'missing.insert(SigningProfile.appGroups)' in renewed
        and groups.index('"updateAppId"') < groups.index('"listApplicationGroups"') < groups.index('"assignApplicationGroupToAppId"')
        and '"addApplicationGroup"' in groups and 'private static let appGroupsFeature = "APG3427HIY"' in portal,
        'a copy signed into an app group gets its App ID back into it, and a profile without the group is refused')
found = block(signing, 'static let installed: [Installed] = {')
require('Bundle.main.builtInPlugInsURL' in found and 'profile.weekly' in found
        and 'profile.appIdentifier ?? bundle.bundleIdentifier' in found and '!found.contains(where: { $0.identifier == identifier })' in found,
        'an extension with a weekly profile for an App ID of its own is renewed too, one signed with the app\'s is not')

# ------------------------------------------------------------------ the device
exported = set(re.findall(r'#\[unsafe\(no_mangle\)\]\s*pub (?:unsafe )?extern "C" fn (\w+)', rust))
require('madeira_rppairing_install_profile' in exported and 'madeira_rppairing_install_profile(' in header,
        'the library exports the profile install and the header declares it')
install = block(rust, 'async fn install_profile(')
require('attempt_pair_verify()' in install and 'validate_pairing(&mut file)' in install
        and '.connect(' not in install.replace('TcpStream::connect(', '').replace('adapter.connect(', '')
        and '.pair(' not in install,
        'the pairing file is verified with the device, and no new pairing is started')
require('connect_tls_psk_tunnel_native' in install and 'MisagentClient::connect_rsd' in install and 'misagent.install(profile)' in install,
        "the profile goes to the device's misagent service through the pairing's tunnel")
require(all(f'"{feature}"' in cargo for feature in ['remote_pairing', 'tunnel_tcp_stack', 'rsd', 'misagent', 'ring']),
        'idevice is built with the tunnel, RSD and misagent')
call = block(signing, 'nonisolated private static func install(')
require('LoopbackProbe.address, devicePort' in call and 'static let devicePort: UInt16 = 49152' in signing
        and 'DispatchQueue.global(' in call and 'madeira_rppairing_string_free(message)' in call,
        'Madeira installs it at LocalDevVPN\'s address, off the main thread')

# ------------------------------------------------------------------ when it runs
refresh = block(signing, 'func refresh(automatic: Bool = false)')
require('guard !automatic else { return false }' in refresh
        and refresh.index('isDebuggerAttached() || JITCoordinator.shared.busy') < refresh.index('DeveloperPortal.renewedProfile(')
        and refresh.index('LoopbackProbe.vpnInterfaceUp') < refresh.index('DeveloperPortal.renewedProfile('),
        'an automatic refresh starts only when it can work, and none starts while JIT is being enabled')
appeared = block(signing, 'func libraryAppeared()')
due = block(signing, 'private func refreshIfDue()')
require('refreshIfDue()' in appeared and 'days <= Self.automaticDays' in due and 'static let automaticDays = 5' in signing
        and 'static let offerDays = 2' in signing and '6 * 3600' in due,
        'it refreshes from five days before, offers from two, and rests six hours after a failure')
require(refresh.index('team != account.teamID') < refresh.index('DeveloperPortal.renewedProfile(')
        and 'for item in installed' in refresh and 'for new in renewed { try await Self.install(new.data, pairing: pairing) }' in refresh
        and refresh.index('for item in installed') < refresh.index('for new in renewed'),
        'a sign-in for another team asks Apple nothing, and every profile is asked for before any is installed')
require('profile.weekly else { expires = nil; return }' in block(signing, 'private func update()')
        and 'defaults.string(forKey: Self.renewedForKey) == profile.uuid' in signing,
        'only a week-long profile is tracked, and a renewed date counts for the installation it renewed')
logged = re.findall(r'LogStore\.shared\.log\("([^"]*)', signing)
require(logged and all(line.startswith('[signing] ') for line in logged)
        and not any(word in line for line in logged for word in ['token', 'adsID', 'teamID', 'bundleID', 'anisette', 'localizedDescription']),
        'the log carries states, days and error kinds: no token, identifier, account or server text')
require('LogStore.shared.log("[signing] refresh failed: \\(Self.logged(error))"' in refresh,
        'a failure is logged by its kind, not by what the server said')

# ------------------------------------------------------------------ the pairing file an installer leaves
data = block(setup, 'static func data() throws -> Data')
move = block(setup, 'private static func moveLegacyFile()')
require(data.index('moveLegacyFile()') < data.index('SecItemCopyMatching'),
        'a pairing file left in Documents is taken in before the Keychain is read')
require('.appendingPathComponent("StikJIT", isDirectory: true)' in setup
        and 'legacyFolder.appendingPathComponent("pairingFile.plist")' in move,
        'the hand-over location is Documents/StikJIT/pairingFile.plist')
require('(try? store(data, source: kept)) != nil' in move and 'try? manager.removeItem(at: file)' in move,
        'it goes through the same validation as an import, and is deleted once the Keychain holds it')

# ------------------------------------------------------------------ the Apple ID sign-in
exported_apple = set(re.findall(r'#\[unsafe\(no_mangle\)\]\s*pub (?:unsafe )?extern "C" fn (\w+)', apple))
require(exported_apple == {'madeira_apple_sign_in'} and 'int32_t madeira_apple_sign_in(' in header
        and 'typedef int32_t (*MadeiraAppleTwoFactorCallback)(' in header and 'mod apple_id;' in rust,
        'the library exports the sign-in and the header declares it and its callback')
require(re.search(r'isideload = \{ version = "=[0-9.]+", default-features = false', cargo) is not None,
        'isideload is pinned to an exact version, without its keyring storage')
require('InMemoryStorage::new()' in apple and 'FsStorage' not in apple and 'std::fs' not in apple
        and not re.search(r'\b(println|eprintln|dbg|tracing::|log::)', apple.split('#[cfg(test)]')[0]),
        'the sign-in writes nothing to disk and logs nothing')
require('default_provider().install_default()' in apple and 'catch_unwind(AssertUnwindSafe(' in apple,
        'the HTTPS client gets its crypto provider, and a panic does not unwind into Swift')
codes = block(apple, 'fn code(&self) -> i32')
require('SignInFailure::Cancelled => 1' in codes and 'SignInFailure::Anisette(_) => 2' in codes and 'SignInFailure::Other(_) => 3' in codes
        and apple.index('get_anisette_data(account.grandslam_client.clone())') < apple.index('account.login(password'),
        'an anisette server that gives nothing is told from a refusal, before Apple hears the password\'s proof')
attempts = block(signin, 'nonisolated private static func signIn(')
require('case 2: failure = .anisette(why)' in attempts and 'case 1: throw Failure.cancelled' in attempts
        and 'default: throw Failure.failed(why)' in attempts and 'madeira_rppairing_string_free(result)' in attempts
        and 'madeira_rppairing_string_free(error)' in attempts,
        'only an anisette failure moves on to the next server: a refusal or a closed prompt ends the sign-in')
started = block(signin, 'func start(appleID: String, password: String)')
require('DispatchQueue.global(' in started and 'SigningAccountStore.load()' in started and 'SigningProfile.embedded?.teamID' in started,
        'the sign-in runs off the main thread, as the identity Madeira holds, for the team this copy was signed by')
made = block(signin, 'func account(appleID: String, signedBy team: String?')
require('teams.contains(where: { $0.id == team })' in made and 'guard account.usable' in made,
        'a sign-in is kept only for the team that signed this copy')
require('URL(string: $0)?.scheme == "https"' in block(signin, 'nonisolated static func servers(after known: [String])')
        and all(server.startswith('"https://') for server in re.findall(r'"https?://[^"]+"', block(signin, 'nonisolated static let anisetteServers'))),
        'anisette servers are reached over HTTPS only')
kept = [line for line in signin.splitlines()
        if re.search(r'SigningAccountStore\.|UserDefaults|SecItem|LogStore|SigningAccount\(|FileManager|\.write\(', line)]
require(kept and not any('password' in line.lower() for line in kept) and 'kSecValueData' not in signin,
        'the password goes to the sign-in and nowhere else')
logged_signin = re.findall(r'LogStore\.shared\.log\("([^"]*)', signin)
require(logged_signin and all(line.startswith('[signing] ') for line in logged_signin)
        and not any(word in line for line in logged_signin for word in ['appleID', 'password', 'token', 'adsID', 'code', 'why', 'localizedDescription']),
        'the sign-in logs how it ended: no Apple ID, code, token or server text')
finished = block(signin, 'private func finished(')
require(finished.index('SigningAccountStore.store(account)') < finished.index('SigningRefresh.shared.signedIn()')
        and 'SigningAccountStore.refused = false' in block(signing, 'func signedIn()'),
        'a sign-in is announced once the Keychain holds it, and clears the refusal')
require('.textContentType(.oneTimeCode)' in signin and 'SecureField("Password"' in signin and 'interactiveDismissDisabled' in signin,
        'the sheet asks for the password in a secure field and the code as a one-time code')
section = block(signing, 'struct SigningSettingsSection')
offer = block(signing, 'struct SigningRefreshOffer')
require('signing.signingIn = true' in section and 'signing.account == nil || signing.signInRefused' in section
        and 'Button("Sign In…") { signing.signingIn = true }' in offer,
        'Settings offers the sign-in without one or after a refusal, and so does the alert over the library')
require(signing.count('AppleSignInSheet()') == 1 and '.sheet(isPresented: $signing.signingIn) { AppleSignInSheet() }' in offer
        and '.sheet(' not in section and '!signingIn' in block(signing, 'private func offerIfDue()'),
        'one place presents the sheet, not each row of the Signing section, and no alert is raised under it: '
        'the sign-in outlasts Apple\'s own alert')

# ------------------------------------------------------------------ in step
require('SigningRefresh.swift in Sources' in project and project.count('/* SigningRefresh.swift */') == 3,
        'the Xcode project compiles SigningRefresh.swift into the app')
require('AppleSignIn.swift in Sources' in project and project.count('/* AppleSignIn.swift */') == 3,
        'the Xcode project compiles AppleSignIn.swift into the app')
require('SigningSettingsSection()' in library and '.modifier(SigningRefreshOffer())' in library,
        'the library shows the Signing section, refreshes and offers')
app_entry = (app / 'MadeiraApp.swift').read_text()
require('nonisolated static var enabled: Bool { MadeiraConfig.flag("MADEIRA_SIGNING_REFRESH", fallback: false) }' in signing
        and 'if SigningRefresh.enabled, settingsShow("signing"' in library
        and 'if SigningRefresh.enabled { SigningAccountStore.takeIn() }' in app_entry
        and offer.count('if SigningRefresh.enabled { signing.libraryAppeared() }') == 2
        and block(signing, 'func libraryAppeared()').count('SigningAccountStore.takeIn()') <= 1,
        'off by default (env.MADEIRA_SIGNING_REFRESH = 1 turns it on): no Settings section, no refresh, '
        'offer or sign-in taken in from an installer')
require('sideinstaller' not in [s.lower() for s in plist['LSApplicationQueriesSchemes']] and 'sideinstaller://' not in signing,
        'the refresh needs no other app: SideInstaller is neither looked for nor opened')
require('Library/Application Support/SigningAccount.plist' in docs and 'Library/Application Support/SigningAccount.plist' in signing
        and 'MadeiraSigningAccountVersion' in docs and 'madeira_rppairing_install_profile' in docs
        and 'Documents/StikJIT/pairingFile.plist' in docs,
        'docs/JIT.md and the source describe the same hand-over and install')
require('madeira_apple_sign_in' in docs and 'Sign in with Apple ID' in docs and 'Sign in with Apple ID…' in signing
        and all(re.search(r'https://([^/"]+)', server).group(1) in docs
                for server in re.findall(r'"https://[^"]+"', block(signin, 'nonisolated static let anisetteServers'))[:1]),
        'docs/JIT.md describes the sign-in and names the anisette server asked first')
notices = (app / 'legal/LICENSES-rppairing-crates.txt').read_text()
require('isideload 0.4.4 (MIT)' in notices and (root / 'LICENSES/MIT-isideload.txt').exists()
        and (app / 'legal/LICENSE-isideload-MIT.txt').exists()
        and all('isideload' in (root / path).read_text() and 'apple-codesign-quick' in (root / path).read_text()
                for path in ['THIRD-PARTY-NOTICES.md', 'app/Madeira/legal/THIRD-PARTY-NOTICES.md']),
        'the notices list isideload and the one LGPL crate it brings')

# ------------------------------------------------------------------ run on the host
def between(text, start, end):
    first = text.index(start)
    return text[first:text.index(end, first)]


swiftc = os.environ.get('SWIFTC') or shutil.which('swiftc')
if sys.platform == 'darwin' and swiftc:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        # The parts that need no UIKit, as they are in the app, without the Keychain.
        (tmp / 'portal.swift').write_text('import Foundation\n\n'
                                          + between(signing, '// MARK: - The profile', '// MARK: - The sign-in')
                                          + between(signing, '/// What it takes to ask Apple', '/// Where the sign-in is kept')
                                          + between(signing, "// MARK: - Apple's developer portal", '// MARK: - Refreshing'))
        (tmp / 'signin.swift').write_text('import Combine\nimport Foundation\n\n'
                                          + between(signin, '// MARK: - The second factor', '// MARK: - The sheet'))
        shutil.copy(Path(__file__).with_name('signing-refresh-harness.swift'), tmp / 'main.swift')
        binary = tmp / 'harness'
        build = subprocess.run([swiftc, '-swift-version', '5', '-o', str(binary), 'main.swift', 'portal.swift', 'signin.swift'],
                               cwd=tmp, capture_output=True, text=True, timeout=600)
        require(build.returncode == 0, 'the portal client and the sign-in compile on the host')
        if build.returncode:
            sys.stdout.write(build.stderr[-4000:])
        else:
            subprocess.run([str(binary), '--fixtures'], check=True, timeout=60)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=300)
            checks = [line for line in run.stdout.splitlines() if line.startswith(('PASS: ', 'FAIL: '))]
            failed = [line for line in run.stdout.splitlines() if not line.startswith('PASS: ') and line != 'ALL PASS']
            require(run.returncode == 0 and len(checks) >= 60 and not failed,
                    f'host run: {len(checks)} checks of what Apple is asked, the second factor and what is kept')
            sys.stdout.write(''.join(line + '\n' for line in failed))
else:
    print('SKIP: no swiftc on a Mac, the portal client and the sign-in were not run')

print('PASS: signing refresh, the installer hand-over and the Apple ID sign-in' if failures == 0 else f'{failures} FAILED')
sys.exit(1 if failures else 0)
