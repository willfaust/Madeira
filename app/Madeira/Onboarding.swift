// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// First-run setup for JIT, Steam sign-in, Madeira Dock and Wine Mono (docs/LIBRARY.md).
// On a new install, and once after an update that raises the setup revision
// (`madeiraOnboardingRevision` in UserDefaults, which iOS removes with the app,
// is below OnboardingRules.revision), the library opens a full-screen setup: welcome, JIT,
// Steam sign-in, Valve's client components for Madeira Dock (only when Dock is
// available), Wine Mono (only when this device has none), done. After an update, only the
// pages added since the revision this device last saw are shown. Every step can be
// skipped. Settings › JIT or Settings › Steam can reopen it in full.
// env.MADEIRA_ONBOARDING = 0 never opens it.
//
// The JIT page offers three ways in (in-app pairing on iOS 27, a pairing
// file from a computer, StikDebug), each with its own numbered steps. It stores
// only the chosen method and, when selected, pairs on this device through
// OnDevicePairing or imports the pairing file through JITCoordinator.
// Sign-in goes through SteamSignIn (the
// token stays in its Keychain store) and the components through
// MadeiraDockModel.prepareClient(), which downloads and verifies files without
// starting Wine. Setup starts no Wine session and changes no JIT pool, engine
// switch or launch configuration.
// Log tag: [onboarding] (no account names, tokens or paths).

// MARK: - Rules (Foundation and MadeiraConfig only; tests/host/check-onboarding.py compiles this part)

enum OnboardingRules {
    /// The setup revision this device last finished or skipped. Raise `revision` in a
    /// release whose setup every existing install should see once.
    static let revisionKey = "madeiraOnboardingRevision"
    /// 1 was the first setup, stored as `madeiraOnboardingDone` (no longer read); 2 adds
    /// Install LocalDevVPN, on-device pairing and the Madeira JIT shortcut; 3 adds the
    /// Wine Mono download.
    static let revision = 3

    /// `env.MADEIRA_ONBOARDING = 0` (madeira.cfg or the environment) never opens
    /// setup and hides "Run setup again". On by default.
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_ONBOARDING") }

    enum Step: String, CaseIterable {
        case welcome, localDevVPN = "localdevvpn", jit, signIn = "sign-in", dockClient = "dock-client",
             wineMono = "wine-mono", done

        /// The revision whose setup first had this page.
        var introduced: Int {
            switch self {
            case .localDevVPN: return 2
            case .wineMono: return 3
            default: return 1
            }
        }
    }

    /// LocalDevVPN comes first when it is not installed (`localDevVPN`): every JIT way
    /// reaches this device through it. JIT is always offered. Sign-in is offered when
    /// Steam sign-in is enabled, or when Madeira Dock is available (Dock needs a
    /// sign-in). Valve's client components are offered only when Dock is available,
    /// Wine Mono only when this device has none (`wineMono`). With `since` (the revision
    /// this device last saw, after an update) only the pages added after it are offered.
    static func steps(signIn: Bool, dock: Bool, localDevVPN: Bool = false, wineMono: Bool = false,
                      since: Int = 0) -> [Step] {
        var list: [Step] = [.welcome]
        if localDevVPN { list.append(.localDevVPN) }
        list.append(.jit)
        if signIn || dock { list.append(.signIn) }
        if dock { list.append(.dockClient) }
        if wineMono { list.append(.wineMono) }
        list.append(.done)
        return since > 0 ? list.filter { $0 == .welcome || $0 == .done || $0.introduced > since } : list
    }

    /// Whether there is anything to set up between the welcome and done pages.
    static func hasSetup(_ steps: [Step]) -> Bool {
        steps.contains(.jit) || steps.contains(.signIn) || steps.contains(.dockClient) || steps.contains(.wineMono)
    }

    /// Whether setup opens by itself when the library appears.
    static func shouldShow(seen: Int, enabled: Bool, steps: [Step]) -> Bool {
        enabled && seen < revision && hasSetup(steps)
    }

    /// The page after `step`, or nil when setup is finished.
    static func next(after step: Step, in steps: [Step]) -> Step? {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }

    /// "Step n of m" for the pages between welcome and done; nil on those two.
    static func position(of step: Step, in steps: [Step]) -> (number: Int, count: Int)? {
        let middle = steps.filter { $0 != .welcome && $0 != .done }
        guard let index = middle.firstIndex(of: step) else { return nil }
        return (index + 1, middle.count)
    }
}

// MARK: - Setup model

@MainActor final class OnboardingModel: ObservableObject {
    static let shared = OnboardingModel()
    typealias Step = OnboardingRules.Step

    @Published var presented = false
    @Published private(set) var step: Step = .welcome
    /// Considered once per app run, when the library first appears.
    private var considered = false

    static var enabled: Bool { OnboardingRules.enabled }
    /// 0 on a new install, and on one that finished setup before revisions (revision 1).
    static var seen: Int { UserDefaults.standard.integer(forKey: OnboardingRules.revisionKey) }

    /// LocalDevVPN was missing when setup opened, so its page is offered. Fixed for that
    /// run of setup: installing it on the way does not renumber the steps.
    private var offerLocalDevVPN = false
    /// The same for Wine Mono: offered when this device had none when setup opened.
    private var offerWineMono = !WineMonoModel.available
    /// The revision this device had seen when setup opened by itself after an update (only
    /// the pages added since are shown); 0 for a new install and for Run setup again.
    @Published private(set) var since = 0
    var steps: [Step] { steps(since: since) }
    private func steps(since: Int) -> [Step] {
        OnboardingRules.steps(signIn: SteamSignIn.isEnabled, dock: MadeiraDock.enabled, localDevVPN: offerLocalDevVPN,
                              wineMono: offerWineMono, since: since)
    }
    /// Setup can be opened: enabled, and something to set up.
    var available: Bool { Self.enabled && OnboardingRules.hasSetup(steps(since: 0)) }

    private init() {}

    /// The library appeared: open setup once on a new install, and once after an update
    /// that raised the setup revision.
    func presentIfNeeded() {
        guard !considered else { return }
        considered = true
        offerWineMono = !WineMonoModel.available
        guard OnboardingRules.shouldShow(seen: Self.seen, enabled: Self.enabled, steps: steps(since: Self.seen)) else { return }
        open(reason: "revision \(Self.seen)->\(OnboardingRules.revision)", since: Self.seen)
    }

    /// Settings › Steam › Run setup again.
    func rerun() { open(reason: "settings", since: 0) }

    private func open(reason: String, since: Int) {
        // Never over a running session.
        guard available, LibraryModel.shared.current == nil, wine_process_is_running() == 0 else { return }
        offerLocalDevVPN = !LocalDevVPN.isInstalled
        offerWineMono = !WineMonoModel.available
        self.since = since
        LogStore.shared.log("[onboarding] shown reason=\(reason) steps=\(steps.map(\.rawValue).joined(separator: ","))")
        go(.welcome)
        presented = true
    }

    func go(_ next: Step) {
        step = next
        LogStore.shared.log("[onboarding] step=\(next.rawValue)")
    }

    func next() {
        guard let following = OnboardingRules.next(after: step, in: steps) else { finish(); return }
        go(following)
    }

    /// "Skip setup" on the welcome page: done, and not shown again.
    func skip() {
        UserDefaults.standard.set(OnboardingRules.revision, forKey: OnboardingRules.revisionKey)
        LogStore.shared.log("[onboarding] skipped")
        close()
    }

    func finish() {
        UserDefaults.standard.set(OnboardingRules.revision, forKey: OnboardingRules.revisionKey)
        LogStore.shared.log("[onboarding] done")
        close()
    }

    private func close() {
        EndedSessionSurface.hide(reason: "setup-closed")
        presented = false
    }
}

// MARK: - Setup screens

struct OnboardingView: View {
    @ObservedObject private var model = OnboardingModel.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @ObservedObject private var signIn = SteamSignInModel.shared
    @ObservedObject private var dock = MadeiraDockModel.shared
    @ObservedObject private var shortcut = JITNetworkShortcut.shared
    @ObservedObject private var mono = WineMonoModel.shared
    @State private var showSignIn = false
    @State private var importingPairingFile = false
    @State private var pairingImportError: String?
    @State private var jitPath: JITSetupPath?
    /// Asked again whenever Madeira comes back to the front (from the App Store, say).
    @State private var localDevVPNInstalled = LocalDevVPN.isInstalled
    @Environment(\.scenePhase) private var scenePhase

    enum JITSetupPath: String {
        case onDevice = "in-app", pairingFile = "pairing-file", stikDebug = "stikdebug"
        /// After a way in is set up (iOS 27): the Madeira JIT shortcut, on its own page.
        case shortcut
    }

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let position = OnboardingRules.position(of: model.step, in: model.steps), position.count > 1 {
                        Text("Step \(position.number) of \(position.count)")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    switch model.step {
                    case .welcome: welcome
                    case .localDevVPN: localDevVPNPage
                    case .jit: jitPage
                    case .signIn: signInPage
                    case .dockClient: dockClientPage
                    case .wineMono: wineMonoPage
                    case .done: donePage
                    }
                }
                .padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
                .animation(.default, value: jitPath)
                .animation(.default, value: pairing.phase)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $showSignIn) { SteamSignInView() }
        .fileImporter(isPresented: $importingPairingFile,
                      allowedContentTypes: [.propertyList, .data]) { result in
            switch result {
            case .success(let url):
                jit.importPairingFile(url)
                if jit.pairingImported {
                    jit.method = .builtIn
                    pairingImportError = nil
                    LogStore.shared.log("[onboarding] JIT method=built-in pairing=imported")
                }
            case .failure(let failure):
                pairingImportError = failure.localizedDescription
                LogStore.shared.log("[onboarding] pairing import failed")
            }
        }
        .onAppear {
            jit.refreshPairingStatus()
            signIn.refresh()
            dock.refresh()
            localDevVPNInstalled = LocalDevVPN.isInstalled
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { localDevVPNInstalled = LocalDevVPN.isInstalled }
        }
    }

    private func header(_ title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.tint).accessibilityHidden(true)
            Text(title).font(.title.bold()).accessibilityAddTraits(.isHeader)
        }
    }

    private func primary(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 36)
        }.buttonStyle(.borderedProminent).controlSize(.large)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).frame(maxWidth: .infinity, minHeight: 44)
    }

    private func point(_ number: Int, _ text: LocalizedStringKey, done: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                } else {
                    Text("\(number)").font(.subheadline.weight(.bold))
                }
            }
            .frame(width: 26, height: 26)
            .background((done ? Color.green : Color.accentColor).opacity(0.15), in: Circle()).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(done ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? Text("Done") : Text(""))
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 52)).foregroundStyle(.tint).accessibilityHidden(true)
            if model.since > 0 {
                // After an update: only the pages added since this device last ran setup.
                Text("New in Madeira").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("Since you last ran setup, Madeira has something new to set up:").font(.title3)
            } else {
                Text("Welcome to Madeira").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("Madeira runs Windows games on your \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone").")
                    .font(.title3)
                Text("A few optional steps get you ready:").foregroundStyle(.secondary)
            }
            let pages = model.steps
            let offered: [LocalizedStringKey] =
                (pages.contains(.localDevVPN) ? ["Install LocalDevVPN, which Madeira enables JIT through."] : [])
                + (pages.contains(.jit) ? ["Choose how Madeira enables JIT."] : [])
                + (pages.contains(.signIn) ? ["Sign in to Steam in Madeira."] : [])
                + (pages.contains(.dockClient) ? ["Download Valve's Steam client components for Madeira Dock."] : [])
                + (pages.contains(.wineMono) ? ["Download Wine Mono, for games built on .NET Framework."] : [])
            ForEach(offered.indices, id: \.self) { index in point(index + 1, offered[index]) }
            primary("Get started", symbol: "arrow.right") { model.next() }.padding(.top, 8)
            secondary("Skip setup") { model.skip() }
        }
    }

    /// LocalDevVPN first, offered only when it was missing: every JIT way reaches this
    /// device through it. LocalDevVPN.isInstalled asks iOS whether an app handles
    /// localdevvpn:// (canOpenURL; the scheme is declared in Info.plist), so nothing opens.
    private var localDevVPNPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Install LocalDevVPN", symbol: "network")
            Text("Madeira enables JIT through LocalDevVPN, a free app that gives Madeira a network path to this \(device). Install it from the App Store, then come back.")
                .fixedSize(horizontal: false, vertical: true)
            if localDevVPNInstalled {
                Label("LocalDevVPN is installed", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                primary("Continue", symbol: "arrow.right") { model.next() }
            } else {
                primary("Get LocalDevVPN", symbol: "arrow.down.app") {
                    LogStore.shared.log("[onboarding] LocalDevVPN app-store")
                    UIApplication.shared.open(LocalDevVPN.appStore)
                }
                secondary("I'll do this later") { model.next() }
            }
        }
    }

    // JIT: pick one of three ways in, then follow its numbered steps.

    private var pairedOnDevice: Bool { jit.pairingImported && jit.pairingSource == .onDevice }
    private var fileImported: Bool { jit.pairingImported && jit.pairingSource == .imported }

    @ViewBuilder private var jitPage: some View {
        switch jitPath {
        case nil: jitChoices
        case .onDevice: onDeviceGuide
        case .pairingFile: pairingFileGuide
        case .stikDebug: stikDebugGuide
        case .shortcut: shortcutPage
        }
    }

    private var jitChoices: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Set up JIT", symbol: "bolt.fill")
            Text("JIT lets Madeira run Windows code. Choose how your \(device) gets it.")
            VStack(spacing: 12) {
                jitChoice("In-app", symbol: "iphone.radiowaves.left.and.right",
                          detail: !OnDevicePairing.isSupported ? "Needs iOS 27 or later."
                              : pairedOnDevice ? "Paired on this \(device)."
                              : "Pair this \(device) with Madeira in Settings. No computer needed.",
                          done: pairedOnDevice, enabled: OnDevicePairing.isSupported) { choose(.onDevice) }
                jitChoice("In-app with pairing file", symbol: "doc.badge.plus",
                          detail: fileImported ? "Pairing file imported." : "Use a pairing file made on a computer.",
                          done: fileImported) { choose(.pairingFile) }
                jitChoice("StikDebug", symbol: "ant",
                          detail: "Enable JIT with the StikDebug app.",
                          done: jit.method == .stikDebug) { choose(.stikDebug) }
            }
            secondary("I'll do this later") { model.next() }
        }
    }

    private var onDeviceGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Pair on this \(device)", symbol: "iphone.radiowaves.left.and.right")
            VStack(alignment: .leading, spacing: 14) {
                point(1, "Turn on Wi-Fi, then tap **Start pairing** and allow Local Network access.",
                      done: pairing.phase != .idle || pairedOnDevice)
                point(2, "Open Settings › Privacy & Security › Developer Mode, scroll down and tap **Pair with \(OnDevicePairing.hostName)**.",
                      done: pairing.isShowingPin || pairedOnDevice)
                point(3, "Enter the code Madeira shows. It's also in the banner at the top of the screen and in a notification.",
                      done: pairedOnDevice)
            }
            if pairedOnDevice {
                Label("Paired on this \(device)", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                vpnNote
                primary("Continue", symbol: "arrow.right") { useBuiltIn() }
                secondary("Pair again") { startPairing() }
            } else {
                primary("Start pairing", symbol: "dot.radiowaves.left.and.right") { startPairing() }
                    .disabled(pairing.active)
                OnDevicePairingPanel()
            }
            secondary("Back to options") { leaveGuide() }
        }
    }

    private var pairingFileGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Use a pairing file", symbol: "doc.badge.plus")
            VStack(alignment: .leading, spacing: 14) {
                point(1, "On a computer, make this \(device)'s pairing file with the [StikDebug pairing-file guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md).",
                      done: fileImported)
                point(2, "Save it to Files or AirDrop it to this \(device).", done: fileImported)
                point(3, "Tap **Choose pairing file** and pick it.", done: fileImported)
            }
            Label("The pairing file is kept in this \(device)'s Keychain.", systemImage: "lock.fill")
                .font(.subheadline).foregroundStyle(.secondary)
            if fileImported {
                Label("Pairing file imported", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                vpnNote
                primary("Continue", symbol: "arrow.right") { useBuiltIn() }
                secondary("Choose another pairing file") { importPairingFile() }
            } else {
                primary("Choose pairing file", symbol: "folder") { importPairingFile() }
            }
            if let error = pairingImportError ?? jit.error {
                Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
            secondary("Back to options") { leaveGuide() }
        }
    }

    private var stikDebugGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Use StikDebug", symbol: "ant")
            VStack(alignment: .leading, spacing: 14) {
                point(1, "Install [StikDebug](https://github.com/StikDebug/StikDebug/releases/latest) and import this \(device)'s pairing file into it.")
                point(2, "Install and connect [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044).")
                point(3, "When you play, Madeira opens StikDebug to enable JIT, then comes back.")
            }
            primary("Use StikDebug", symbol: "arrow.right") {
                jit.method = .stikDebug
                LogStore.shared.log("[onboarding] JIT method=StikDebug")
                finishJIT()
            }
            secondary("Back to options") { leaveGuide() }
        }
    }

    /// Only on iOS 26: from iOS 27 the Connect automatically page that follows the guide
    /// covers LocalDevVPN.
    @ViewBuilder private var vpnNote: some View {
        if !JITShortcutFile.supported { vpnNoteLabel }
    }

    private var vpnNoteLabel: some View {
        Label {
            Text("Before you play, connect [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044). Madeira enables JIT through it.")
        } icon: {
            Image(systemName: "network")
        }
        .font(.subheadline).foregroundStyle(.secondary)
    }

    private func jitChoice(_ title: String, symbol: String, detail: String, done: Bool, enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.5)
    }

    private func choose(_ way: JITSetupPath) {
        pairingImportError = nil
        LogStore.shared.log("[onboarding] JIT way=\(way.rawValue)")
        jitPath = way
    }

    private func leaveGuide() {
        if pairing.active { pairing.cancel() }
        jitPath = nil
    }

    private func startPairing() {
        pairingImportError = nil
        LogStore.shared.log("[onboarding] JIT in-app pairing started")
        pairing.start()
    }

    private func importPairingFile() {
        pairingImportError = nil
        importingPairingFile = true
    }

    private func useBuiltIn() {
        jit.method = .builtIn
        LogStore.shared.log("[onboarding] JIT method=built-in")
        finishJIT()
    }

    /// A way in is set up: the Madeira JIT shortcut's page on iOS 27, else the next step.
    private func finishJIT() {
        if JITShortcutFile.supported, JITShortcutFile.url != nil {
            jitPath = .shortcut
        } else {
            model.next()
        }
    }

    /// The Madeira JIT shortcut (iOS 27; JITShortcutFile), on its own page so the JIT
    /// guides fit on one screen. Add it from its iCloud link (straight to Add Shortcut)
    /// or, with no internet connection, the local copy through the share sheet; then turn
    /// it on.
    /// It drives LocalDevVPN with LocalDevVPN's own Shortcuts action.
    private var shortcutPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Connect automatically", symbol: "bolt.horizontal.circle")
            Text("With the \(JITNetworkShortcut.name) shortcut, Enable JIT connects LocalDevVPN for you, turns Cellular Data off while there's no Wi-Fi, and puts both back, along with any VPN you were using, once the game starts.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) {
                point(1, "Install [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044).",
                      done: LocalDevVPN.isInstalled)
                point(2, "Tap **Add the shortcut**, then **Add Shortcut** in Shortcuts.")
                point(3, "Turn on **Use it for JIT**.", done: shortcut.enabled)
            }
            Button {
                LogStore.shared.log("[jit-shortcut] add: iCloud link")
                UIApplication.shared.open(JITShortcutFile.iCloudLink)
            } label: {
                Label("Add the shortcut", systemImage: "plus.square.on.square")
                    .fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered).controlSize(.large)
            if let url = JITShortcutFile.url {
                ShareLink(item: url) {
                    Text("No internet connection? Add local copy, then choose the Shortcuts app in the share sheet that pops up.")
                        .font(.footnote).frame(maxWidth: .infinity)
                }
            }
            Toggle("Use it for JIT", isOn: $shortcut.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            primary("Continue", symbol: "arrow.right") {
                LogStore.shared.log("[onboarding] JIT shortcut on=\(shortcut.enabled ? 1 : 0)")
                model.next()
            }
        }
    }

    private var signInPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Sign in to Steam", symbol: "person.crop.circle.badge.checkmark")
            Text(model.steps.contains(.dockClient)
                 ? "When you start a game with Madeira Dock, Madeira hands this sign-in to Valve's own Steam client, which signs in and checks your license."
                 : "Madeira keeps a Steam sign-in so it can start your Steam games with your own account.")
            VStack(alignment: .leading, spacing: 10) {
                Label("Your password goes only to Steam and is never saved.", systemImage: "lock.fill")
                Label("The sign-in is kept in this device's Keychain until you sign out.", systemImage: "iphone")
            }.font(.subheadline).foregroundStyle(.secondary)
            if let name = signIn.accountName {
                Label("Signed in as \(name)", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                primary("Continue", symbol: "arrow.right") { model.next() }
                secondary("Use a different account") {
                    LogStore.shared.log("[onboarding] sign-in replaced")
                    signIn.signOut(); showSignIn = true
                }
            } else {
                primary("Sign in to Steam", symbol: "person.crop.circle") { showSignIn = true }
                secondary("Set up later") { model.next() }
            }
        }
    }

    private var dockClientPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Prepare Madeira Dock", symbol: "shippingbox")
            Text("Madeira Dock starts your installed Steam games through Valve's own Steam client, without the Steam desktop window. It needs the client's components, which Madeira downloads from Valve.")
            if dock.clientInstalled {
                Label("Valve's client components are installed.", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                primary("Continue", symbol: "arrow.right") { model.next() }
            } else {
                Text("About 73 MB from Valve's update servers, checked against pinned SHA-256 sums. No Windows session runs for this.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if dock.preparing {
                    HStack(spacing: 12) { ProgressView(); Text(dock.progress).foregroundStyle(.secondary) }
                } else {
                    if let error = dock.error {
                        Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                    primary(dock.error == nil ? "Download components" : "Try again", symbol: "arrow.down.circle.fill") {
                        LogStore.shared.log("[onboarding] components download")
                        dock.prepareClient()
                    }
                }
                // A running download continues; Settings › Steam › Madeira Dock shows it.
                secondary("Set up later") { model.next() }
            }
        }
    }

    /// Wine Mono, offered when this device has none: games built on .NET Framework need it.
    /// The download continues if the page is left; Settings › .NET Framework shows it.
    private var wineMonoPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Add .NET Framework support", symbol: "shippingbox.and.arrow.backward")
            Text("Some Windows games are built on Microsoft's .NET Framework. Madeira runs them on Wine Mono, the Wine project's open-source .NET runtime.")
            if mono.installed {
                Label("Wine Mono is installed.", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                primary("Continue", symbol: "arrow.right") { model.next() }
            } else {
                Text("Madeira downloads it from WineHQ: about 42 MB, about 130 MB once installed. Most games do not need it; you can also add it later in Settings.")
                    .font(.subheadline).foregroundStyle(.secondary)
                switch mono.phase {
                case .downloading(let f), .installing(let f):
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: f)
                        Text(mono.status).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                case .idle:
                    if let error = mono.error {
                        Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                    primary(mono.error == nil ? "Download Wine Mono" : "Try again", symbol: "arrow.down.circle.fill") {
                        LogStore.shared.log("[onboarding] Wine Mono download")
                        mono.install()
                    }
                }
                secondary("Set up later") { model.next() }
            }
        }
    }

    private var donePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("You're all set", symbol: "checkmark.seal.fill")
            if model.steps.contains(.jit) {
                Text("You can change the JIT method or import a pairing file from Settings › JIT.")
            }
            if model.steps.contains(.dockClient) {
                Text("Settings › Steam › Madeira Dock lists the Steam games installed in Madeira's drive_c and starts them.")
            }
            if model.steps.contains(.wineMono) {
                Text("Settings › .NET Framework downloads or removes Wine Mono.")
            }
            Text("You can run this setup again from Settings › JIT or Settings › Steam.").foregroundStyle(.secondary)
            primary("Go to your library", symbol: "square.grid.2x2.fill") { model.finish() }
        }
    }
}

// MARK: - Settings › Steam

/// The library's Steam settings: the signed-in account, Sign in / Sign out
/// (SteamSignIn; the token stays in its Keychain store), Madeira Dock's sheet
/// and "Run setup again".
struct SteamSettingsSection: View {
    /// Opens Steam sign-in or Madeira Dock. LibraryView presents the sheet from the
    /// Settings Form: a sheet attached to this section closed again as soon as it
    /// slid up whenever the Form rebuilt its rows.
    let open: (SettingsSheet) -> Void
    @ObservedObject private var signIn = SteamSignInModel.shared
    @ObservedObject private var dock = MadeiraDockModel.shared
    @ObservedObject private var onboarding = OnboardingModel.shared
    @ObservedObject private var cloud = SteamCloudSetting.shared
    @State private var confirmSignOut = false

    /// Shown when Steam sign-in or Madeira Dock is available.
    static var shown: Bool { SteamSignIn.isEnabled || MadeiraDock.enabled }

    var body: some View {
        Section {
            if let name = signIn.accountName {
                LabeledContent("Signed in as", value: name)
                Button("Sign out of Steam", role: .destructive) { confirmSignOut = true }
            } else {
                Button { open(.steamSignIn) } label: { Label("Sign in to Steam", systemImage: "person.crop.circle.badge.plus") }
            }
            // Off: no Steam Cloud checks, transfers or prompts before Play (docs/STEAM_CLOUD.md).
            if SteamOwnedLibrary.enabled {
                Toggle("Steam Cloud saves", isOn: $cloud.on)
            }
            if MadeiraDock.enabled {
                Button { open(.dock) } label: { Label("Madeira Dock", systemImage: "shippingbox") }
                if let status = dock.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            if onboarding.available {
                Button { onboarding.rerun() } label: { Label("Run setup again", systemImage: "wand.and.stars") }
            }
        } header: {
            Text("Steam")
        } footer: {
            Text("Madeira keeps a Steam sign-in token in this device's Keychain, for this device only. Signing out removes it.")
        }
        .confirmationDialog("Sign out of Steam?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { signIn.signOut() }
        }
        .onAppear { signIn.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: SteamSignIn.didChange)) { _ in signIn.refresh() }
    }
}

// MARK: - Madeira Dock in the library

extension LibraryEntry {
    static let dockSessionID = UUID(uuidString: "5D0C4A3E-2B7F-4C61-9E0A-6B1D2F3C4E5A")!

    /// A Dock start from the library runs as a library session (full-screen
    /// view, starting screen, in-game menu, one session per run) with this
    /// entry. It is a desktop session: explorer's virtual desktop runs the
    /// host. It is never saved to the library.
    static func dockSession(title: String, width: Int, height: Int) -> LibraryEntry {
        var entry = LibraryEntry(title: title.isEmpty ? "Madeira Dock" : title, relativePath: "windows/system32/explorer.exe", bits: 64)
        entry.id = dockSessionID; entry.desktop = true; entry.resolution = "\(width)x\(height)"
        entry.graphicsAPI = "Madeira Dock"
        return entry
    }
}
