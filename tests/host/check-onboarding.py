#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""First-run setup in the library (app/Madeira/Onboarding.swift), on the host.

1. Swift: compiles the production OnboardingRules with the production
   MadeiraConfig.swift (HOME pointed at a scratch directory) and checks the
   JIT page, pages with and without Madeira Dock and Steam sign-in, the
   first-run decision and the UserDefaults done key, navigation and the step
   counter, and the MADEIRA_ONBOARDING switch from madeira.cfg and from the
   environment.
2. Source checks: the library opens setup once and reopens it from Settings,
   never over a session; JIT setup uses the coordinator's pairing import and
   method selection, while Steam settings use only sign-in's and Dock's public
   pieces (no Keychain or token access here); setup starts no Wine session and
   touches no JIT pool, engine switch or launch environment; no program-name
   list; no account, token or path in a log line; a Dock start from the library
   is an unsaved library session behind the one-session-per-run rule; the file
   is in the Xcode project.

Synthetic data only: no Steam, Wine or credentials. Needs `swiftc` on PATH
(or SWIFTC).
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def block(text, header):
    p = text.index(header)
    a = text.index('{', p)
    n, b = 1, a + 1
    while n:
        n += (text[b] == '{') - (text[b] == '}')
        b += 1
    return text[p:b]


onboarding = (app / 'Onboarding.swift').read_text()
library = (app / 'Library.swift').read_text()
content = (app / 'ContentView.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
docs = (root / 'docs/LIBRARY.md').read_text()
jit_setup = (app / 'JITSetup.swift').read_text()

rules = onboarding[onboarding.index('// MARK: - Rules'):onboarding.index('// MARK: - Setup model')]
model = block(onboarding, 'final class OnboardingModel')
settings_section = block(onboarding, 'struct SteamSettingsSection: View')
jit_settings_section = block(jit_setup, 'struct JITSettingsSection: View')

# ------------------------------------------------------------------ static: provenance and project
require(onboarding.startswith('// SPDX-License-Identifier: GPL-3.0-or-later\n// Copyright 2026 125hz\n'
                              '// Madeira Converter Exception: see LICENSE-EXCEPTION.md\n'),
        'Onboarding.swift: GPL-3.0-or-later, Copyright 2026 125hz, Converter Exception')
require('/* Onboarding.swift in Sources */,' in project and 'path = "Onboarding.swift"' in project,
        'Onboarding.swift is built by the Xcode project')
require(not re.search(r'\b(SwiftUI|UIKit|View|UIDevice)\b', rules.replace('// MARK: - Rules', '')),
        'the rules are Foundation-only (compiled on the host)')

# ------------------------------------------------------------------ static: when setup opens
present = block(model, 'func presentIfNeeded()')
require('guard !considered' in present and 'OnboardingRules.shouldShow(seen: Self.seen, enabled: Self.enabled, steps: steps(since: Self.seen))' in present
        and 'open(reason: "revision \\(Self.seen)->\\(OnboardingRules.revision)", since: Self.seen)' in present,
        'setup is considered once per run, opens only by the rules, and after an update shows only the new pages')
require('func rerun() { open(reason: "settings", since: 0) }' in model,
        'Run setup again shows every page')
opener = block(model, 'private func open(reason: String, since: Int)')
require('LibraryModel.shared.current == nil' in opener and 'wine_process_is_running() == 0' in opener and 'guard available' in opener,
        'setup never opens over a running session, or with nothing to set up')
require('OnboardingRules.steps(signIn: SteamSignIn.isEnabled, dock: MadeiraDock.enabled, localDevVPN: offerLocalDevVPN,\n'
        '                              wineMono: offerWineMono, vcRedist: offerVCRedist, since: since)' in model,
        'the pages follow the sign-in and Dock switches, whether LocalDevVPN, Wine Mono and the VC++ runtime are here, and the revision seen')
require(block(model, 'private static func vcRedistOffered()').count('VCRedistModel.enabled') == 1
        and 'offerVCRedist = Self.vcRedistOffered()' in opener,
        "the Visual C++ page follows its switch and the prefix's registry, decided when setup opens")
require(opener.index('offerLocalDevVPN = !LocalDevVPN.isInstalled') < opener.index('[onboarding] shown')
        and opener.index('offerWineMono = !WineMonoModel.available') < opener.index('[onboarding] shown'),
        "LocalDevVPN's and Wine Mono's pages are decided once, when setup opens, so installing on the way does not renumber the steps")
stamp = 'UserDefaults.standard.set(OnboardingRules.revision, forKey: OnboardingRules.revisionKey)'
require(model.count(stamp) == 2 and stamp in block(model, 'func finish()') and stamp in block(model, 'func skip()')
        and 'removeObject' not in onboarding and 'set(false' not in onboarding and 'set(0' not in onboarding,
        'only finishing or skipping stores the setup revision; nothing clears it')
require('static var enabled: Bool { OnboardingRules.enabled }' in model, 'the model uses the rules switch')
require('.fullScreenCover(isPresented: $onboarding.presented) { OnboardingView() }' in library,
        'Library: setup is presented over the library')
require('onboarding.presentIfNeeded()' in block(library, 'struct LibraryView: View'),
        'Library: setup is considered when the library appears')
require(library.count('!onboarding.presented') >= 2, 'Library: controller commands do not act behind setup')
require('if onboarding.available {' in settings_section and 'onboarding.rerun()' in settings_section,
        'Settings › Steam: Run setup again, hidden with MADEIRA_ONBOARDING=0')
require('if onboarding.available {' in jit_settings_section and 'onboarding.rerun()' in jit_settings_section,
        'Settings › JIT: Run setup again, hidden with MADEIRA_ONBOARDING=0')

# ------------------------------------------------------------------ static: skippable steps
view = block(onboarding, 'struct OnboardingView: View')
for page in ['private var signInPage', 'private var dockClientPage', 'private var wineMonoPage', 'private var vcRedistPage']:
    require('secondary("Set up later") { model.next() }' in block(view, page), f'{page.split()[-1]}: Set up later')
require('secondary("Skip setup") { model.skip() }' in block(view, 'private var welcome'), 'welcome: visible Skip setup')
jit_page = block(view, 'private var jitPage')
choices = block(view, 'private var jitChoices')
require(all(f'case .{path}: {guide}' in jit_page for path, guide in
            [('onDevice', 'onDeviceGuide'), ('pairingFile', 'pairingFileGuide'), ('stikDebug', 'stikDebugGuide')]),
        'JIT: each of the three ways in has its own guide')
require(all(f'jitChoice("{title}"' in choices for title in ['In-app', 'In-app with pairing file', 'StikDebug'])
        and 'enabled: OnDevicePairing.isSupported' in choices,
        'JIT: In-app (iOS 27), In-app with pairing file, StikDebug')
on_device = block(view, 'private var onDeviceGuide')
require('startPairing()' in on_device and 'OnDevicePairingPanel()' in on_device
        and 'pairing.start()' in block(view, 'private func startPairing'),
        'JIT: the on-device guide pairs and shows its progress')
require('importPairingFile()' in block(view, 'private var pairingFileGuide')
        and 'importingPairingFile = true' in block(view, 'private func importPairingFile'),
        'JIT: the pairing-file guide imports')
require('jit.method = .stikDebug' in block(view, 'private var stikDebugGuide'), 'JIT: the StikDebug guide selects StikDebug')
for guide in ['onDeviceGuide', 'pairingFileGuide', 'stikDebugGuide']:
    require('secondary("Back to options") { leaveGuide() }' in block(view, f'private var {guide}'), f'JIT: {guide} goes back')
require('pairing.cancel()' in block(view, 'private func leaveGuide'), 'JIT: leaving the guide stops a waiting pairing')
require("secondary(\"I'll do this later\") { model.next() }" in choices, 'JIT: visible defer choice')
require('jit.importPairingFile(url)' in view and 'jit.method = .builtIn' in view,
        'JIT: validated import selects Built-in StikJIT through the coordinator')
ldv_page = block(view, 'private var localDevVPNPage')
require('UIApplication.shared.open(LocalDevVPN.appStore)' in ldv_page and "secondary(\"I'll do this later\") { model.next() }" in ldv_page
        and 'if localDevVPNInstalled' in ldv_page and 'case .localDevVPN: localDevVPNPage' in view,
        "LocalDevVPN's page sends a missing LocalDevVPN to the App Store, and can be skipped")
require('if phase == .active { localDevVPNInstalled = LocalDevVPN.isInstalled }' in view
        and 'UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!)' in (app / 'JITSetup.swift').read_text(),
        'LocalDevVPN is checked with canOpenURL (nothing opens), again whenever Madeira comes back to the front')
require('onTapGesture' not in onboarding, 'no hidden gestures')
require('dock.prepareClient()' in block(view, 'private var dockClientPage'), "components through Dock's verified download")

# ------------------------------------------------------------------ static: sign-in and tokens
require('SteamSignInView()' in view and 'open(.steamSignIn)' in settings_section
        and 'case .steamSignIn: SteamSignInView()' in library, "sign-in through #45's sheet")
require('signIn.signOut()' in settings_section, "sign-out through #45's model")
require('open(.dock)' in settings_section and 'case .dock: MadeiraDockView(start: startDock)' in library,
        "Settings opens Dock's sheet")
for forbidden in ['SteamTokenStore', 'credentialsForDock', 'refreshToken', 'SecItem', 'kSec', 'accessToken']:
    require(forbidden not in onboarding, f'Onboarding.swift: no {forbidden} (tokens only via the sign-in store)')
for line in onboarding.splitlines():
    if re.search(r'LogStore|SteamLog\.|print\(|NSLog|fputs', line):
        require(re.search(r'\\\((name|account|signIn|token|url|path|game|status|error)', line) is None,
                f'no account, token or path in "{line.strip()[:70]}"')

# ------------------------------------------------------------------ static: no Wine, pool, engine or exe-name behaviour
for forbidden in ['runWineFullSequence', 'setenv(', 'unsetenv(', 'MADEIRA_EXE', 'MADEIRA_ARGS', 'jit_', 'StikJITHelper',
                  'poolSize', 'JITPool', 'MADEIRA_POOL', 'FEX_', 'DXMT', 'MADEIRA_JIT', 'steamwebhelper', 'SteamSetup',
                  'inproc-sync', 'swap-mb', 'MADEIRA_FASTSYNC', 'madsync']:
    require(forbidden not in onboarding, f'Onboarding.swift: no {forbidden}')
require(not re.search(r'\b(512|896|1024|1152)\b', onboarding), 'Onboarding.swift: no pool size')
exes = {m.split('/')[-1].split('\\')[-1].lower() for m in re.findall(r'"([^"\n]*?\.exe)"', onboarding)}
require(exes <= {'explorer.exe'}, f'Onboarding.swift: no program-name list ({sorted(exes)})')
require('.exe' not in rules, 'rules key nothing on program names')

# ------------------------------------------------------------------ static: Dock from the library
start = block(content, 'private func startDock(_ game: DockGame, compactPool: Bool')
require('LibraryView(play: launchLibraryEntry, enableJIT: enableJIT,\n                                startDock: { startDock($0, compactPool: $1) })' in content,
        "ContentView hands Dock's start to the library")
held = start.index('LibraryModel.sessionsThisRun > 0, MadeiraConfig.flag("MADEIRA_ONE_SESSION_PER_RUN")')
require(held < start.index('MadeiraDock.writeHandoff('), 'a held Dock start writes no sign-in transfer')
require('else { library.begin(.dockSession(title: game.name, width: width, height: height), remember: false, dock: game) }' in start
        and start.index('library.begin(') < start.index('runWineFullSequence('),
        'a Dock start from Settings is an unsaved library session')
# A Steam game started from its Game details page (SteamGames.swift) is its own library entry: its
# display, overlay and control settings apply, and its profile never replaces Dock's environment
# (LibraryEntry.configureLaunch returns before MADEIRA_EXE for a Steam game; check-steam-games.py).
# Either way the library is told which game Dock starts (its starting screen, DockStartScreen.swift).
require('if let profile { library.begin(profile, dock: game) }' in start and start.count('runWineFullSequence(') == 1
        and 'runWineFullSequence(profile: profile)' in start,
        "Dock's launch path takes a Steam game's own profile, and only that")
configure = block(library, 'func configureLaunch()')
require(configure.index('if steamAppID != nil {') < configure.index('setenv("MADEIRA_EXE"'),
        "a Steam game's profile leaves Dock's program, arguments and desktop in place")
begin = block(library, 'func begin(_ entry: LibraryEntry, remember: Bool = true, dock: DockGame? = nil)')
require('if remember { var played = entry; played.lastPlayed = Date(); save(played) }' in begin,
        'begin(remember: false) neither adds nor stamps an entry')
dock_entry = block(onboarding, 'static func dockSession(')
require('entry.desktop = true' in dock_entry and 'save(' not in dock_entry, 'the Dock session entry is a desktop session, never saved')
require('MADEIRA_ONBOARDING' in docs and '## First-run setup' in docs,
        'docs/LIBRARY.md documents setup and its switch')

# ------------------------------------------------------------------ compiled rules
checks = r'''
import Foundation
@main struct Checks {
    static var failed = 0
    static func expect(_ condition: Bool, _ label: String) {
        print((condition ? "PASS: " : "FAIL: ") + label)
        if !condition { failed += 1 }
    }
    static func main() {
        typealias R = OnboardingRules
        let full: [R.Step] = [.welcome, .jit, .signIn, .dockClient, .done]
        expect(R.revisionKey == "madeiraOnboardingRevision" && R.revision >= 2, "revision key; revision 2 or later")
        expect(R.Step.jit.rawValue == "jit" && R.Step.signIn.rawValue == "sign-in"
               && R.Step.dockClient.rawValue == "dock-client", "log step names")

        // JIT is always present; Steam pages still follow their feature switches.
        expect(R.steps(signIn: true, dock: true) == full, "with Dock: JIT, sign-in, then Valve's client components")
        expect(R.steps(signIn: true, dock: false) == [.welcome, .jit, .signIn, .done],
               "without Dock: JIT and sign-in, no components page")
        expect(R.steps(signIn: false, dock: true) == full, "Dock keeps the sign-in page after JIT (it needs a sign-in)")
        expect(R.steps(signIn: true, dock: true, localDevVPN: true) == [.welcome, .localDevVPN, .jit, .signIn, .dockClient, .done]
               && R.steps(signIn: false, dock: false, localDevVPN: true) == [.welcome, .localDevVPN, .jit, .done],
               "LocalDevVPN missing: its page comes first, before JIT")
        expect(R.position(of: .localDevVPN, in: [.welcome, .localDevVPN, .jit, .done])! == (1, 2)
               && R.Step.localDevVPN.rawValue == "localdevvpn", "LocalDevVPN's page counts as step 1")
        expect(R.steps(signIn: false, dock: false) == [.welcome, .jit, .done],
               "JIT remains when Steam setup is unavailable")
        // Wine Mono (revision 3): offered when this device has none, before done; after an
        // update from revision 2 only it is shown.
        expect(R.Step.wineMono.rawValue == "wine-mono" && R.Step.wineMono.introduced == 3
               && R.Step.localDevVPN.introduced == 2 && R.Step.jit.introduced == 1, "revision 3 adds Wine Mono")
        expect(R.steps(signIn: true, dock: true, wineMono: true) == [.welcome, .jit, .signIn, .dockClient, .wineMono, .done],
               "Wine Mono's page comes last, before done")
        // The Visual C++ runtime (revision 4): offered while the prefix lacks it, after Wine
        // Mono; after an update from revision 3 only it is shown.
        expect(R.revision == 4 && R.Step.vcRedist.rawValue == "vc-redist" && R.Step.vcRedist.introduced == 4,
               "revision 4 adds the Visual C++ runtime")
        expect(R.steps(signIn: true, dock: true, wineMono: true, vcRedist: true)
                   == [.welcome, .jit, .signIn, .dockClient, .wineMono, .vcRedist, .done]
               && R.steps(signIn: false, dock: false, vcRedist: true) == [.welcome, .jit, .vcRedist, .done],
               "the Visual C++ page comes after Wine Mono, before done")
        expect(R.steps(signIn: true, dock: true, wineMono: true, vcRedist: true, since: 3) == [.welcome, .vcRedist, .done]
               && R.steps(signIn: true, dock: true, wineMono: true, vcRedist: false, since: 3) == [.welcome, .done]
               && R.hasSetup([.welcome, .vcRedist, .done]) && !R.hasSetup([.welcome, .done]),
               "an update from revision 3 shows setup only when the runtime is missing")
        expect(R.steps(signIn: true, dock: true, localDevVPN: true, wineMono: true, since: 2) == [.welcome, .wineMono, .done]
               && R.steps(signIn: true, dock: true, localDevVPN: true, wineMono: true, since: 1) == [.welcome, .localDevVPN, .wineMono, .done],
               "after an update only the pages added since the revision seen")
        expect(!R.shouldShow(seen: 2, enabled: true, steps: R.steps(signIn: true, dock: true, wineMono: false, since: 2))
               && R.shouldShow(seen: 2, enabled: true, steps: R.steps(signIn: true, dock: true, wineMono: true, since: 2))
               && R.hasSetup([.welcome, .wineMono, .done]),
               "an update shows setup only when a new page applies (Wine Mono missing)")
        expect(R.hasSetup(full) && R.hasSetup([.welcome, .jit, .done])
               && !R.hasSetup([.welcome, .done]), "hasSetup")

        // First-run decision.
        expect(R.shouldShow(seen: 0, enabled: true, steps: full), "new install shows setup")
        expect(R.shouldShow(seen: R.revision - 1, enabled: true, steps: full),
               "an update that raised the revision shows setup once more")
        expect(!R.shouldShow(seen: R.revision, enabled: true, steps: full)
               && !R.shouldShow(seen: R.revision + 1, enabled: true, steps: full),
               "setup finished or skipped at this revision (or a later one, after a downgrade) stays closed")
        expect(!R.shouldShow(seen: 0, enabled: false, steps: full), "MADEIRA_ONBOARDING=0 never shows it")
        expect(!R.shouldShow(seen: 0, enabled: true, steps: [.welcome, .done]),
               "synthetic setup with no middle page never shows")

        // The revision in UserDefaults.
        let suite = "madeira-onboarding-check"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        expect(R.shouldShow(seen: defaults.integer(forKey: R.revisionKey), enabled: true, steps: full), "missing key (fresh install) shows setup")
        defaults.set(true, forKey: "madeiraOnboardingDone")
        expect(R.shouldShow(seen: defaults.integer(forKey: R.revisionKey), enabled: true, steps: full),
               "setup finished before revisions (only madeiraOnboardingDone) shows once more")
        defaults.set(R.revision, forKey: R.revisionKey)
        expect(!R.shouldShow(seen: defaults.integer(forKey: R.revisionKey), enabled: true, steps: full), "stored revision hides setup")
        defaults.removePersistentDomain(forName: suite)

        // Navigation and the step counter.
        var walked: [R.Step] = [.welcome]
        while let next = R.next(after: walked.last!, in: full) { walked.append(next) }
        expect(walked == full, "Next walks every page in order")
        expect(R.next(after: .done, in: full) == nil, "done is the last page")
        expect(R.next(after: .dockClient, in: [.welcome, .jit, .signIn, .done]) == nil,
               "a page not in the list ends setup")
        expect(R.next(after: .signIn, in: [.welcome, .jit, .signIn, .done]) == .done,
               "without Dock, sign-in leads to done")
        expect(R.position(of: .jit, in: full)! == (1, 3)
               && R.position(of: .signIn, in: full)! == (2, 3)
               && R.position(of: .dockClient, in: full)! == (3, 3), "step n of m with Dock")
        expect(R.position(of: .jit, in: [.welcome, .jit, .signIn, .done])! == (1, 2)
               && R.position(of: .signIn, in: [.welcome, .jit, .signIn, .done])! == (2, 2),
               "two steps without Dock")
        expect(R.position(of: .welcome, in: full) == nil && R.position(of: .done, in: full) == nil, "no counter on welcome and done")

        // The switch: default on; env.MADEIRA_ONBOARDING = 0 in madeira.cfg; the environment.
        let docs = MadeiraConfig.documents!
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let cfg = docs.appendingPathComponent("madeira.cfg")
        try? FileManager.default.removeItem(at: cfg)
        unsetenv("MADEIRA_ONBOARDING")
        expect(R.enabled, "MADEIRA_ONBOARDING is on by default")
        setenv("MADEIRA_ONBOARDING", "0", 1)
        expect(!R.enabled, "MADEIRA_ONBOARDING=0 in the environment turns setup off")
        unsetenv("MADEIRA_ONBOARDING")
        try! "# notes\nenv.MADEIRA_ONBOARDING = 0\n".write(to: cfg, atomically: true, encoding: .utf8)
        expect(!R.enabled, "env.MADEIRA_ONBOARDING = 0 in madeira.cfg turns setup off")
        try! "env.MADEIRA_ONBOARDING = 1\n".write(to: cfg, atomically: true, encoding: .utf8)
        expect(R.enabled, "env.MADEIRA_ONBOARDING = 1 keeps it on")
        exit(failed == 0 ? 0 : 1)
    }
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-onboarding-check-') as tmp:
    folder = Path(tmp)
    (folder / 'Rules.swift').write_text('import Foundation\n' + rules)
    (folder / 'Checks.swift').write_text(checks)
    home = folder / 'home'
    home.mkdir()
    exe = folder / 'check'
    build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-o', str(exe),
                            str(folder / 'Rules.swift'), str(app / 'MadeiraConfig.swift'), str(folder / 'Checks.swift')],
                           capture_output=True, text=True)
    require(build.returncode == 0, 'production onboarding rules and MadeiraConfig compile on the host')
    if build.returncode:
        sys.stdout.write(build.stderr[-4000:])
    else:
        env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
        env.pop('MADEIRA_ONBOARDING', None)
        run = subprocess.run([str(exe)], env=env, capture_output=True, text=True)
        sys.stdout.write(run.stdout)
        if run.returncode:
            sys.stdout.write(run.stderr[-4000:])
        require(run.returncode == 0, 'onboarding rule checks pass')

if failures:
    print(f'check-onboarding: {failures} FAILED')
    sys.exit(1)
print('check-onboarding: PASS')
