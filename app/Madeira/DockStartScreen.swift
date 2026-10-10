// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

// The starting screen of a game started through Madeira Dock (docs/MADEIRA_DOCK.md,
// "Starting screen"). A Dock start is a desktop session: explorer's virtual desktop
// runs the Dock host. The desktop's first GDI frame (explorer's own windows, the
// host's console window) used to end the starting screen, so the user watched the
// Wine desktop instead of the game. The starting screen now stays, with the Dock's
// status, until a window of the started game is up; a window that may need an answer
// reveals the desktop, and Show desktop reveals it on request.
//
// Which window is which comes from Winios.m's census (the owning program of every
// top-level window, with its executable path) and is decided by WHERE that program
// lives on drive C, never by its name:
//   - C:\windows\ holds Wine's own programs (shell, services, console hosts,
//     msiexec) and the Dock host: never the game;
//   - the Steam client's folder, outside its steamapps library, holds Valve's
//     client programs: a dialog of theirs may need the user;
//   - any other program is the game (or its own launcher) once the Dock host has
//     started. Before that, the game's one-time installs run from the batch, and a
//     window first shown then is an installer's: never the game, and a dialog of
//     theirs may need the user.
// Log tag: [steam-launch-view] (scene names, window sizes and owner classes only).

// MARK: - Rules (Foundation only; tests/host/check-dock-start-screen.py compiles this part)

/// One top-level window of a Dock start's Wine desktop, as Winios.m's census reports it.
/// `image`: the owning program's executable path, "" when it could not be read.
struct SteamLaunchWindow: Equatable {
    var image: String
    var width: Int
    var height: Int
    var visible: Bool
    /// The window put a frame on screen: GDI content, or a D3D swapchain of its own.
    var drawn: Bool
    var pid: UInt32 = 0
    var hwnd: UInt64 = 0
}

/// What a Dock start is showing.
enum SteamLaunchScene: Equatable {
    /// Nothing for the user yet; the host and Valve's client work in the background.
    case waiting
    /// A window that may need the user: a dialog of Valve's client or of a one-time installer.
    case steamWindow
    /// A window of the started game is up.
    case game

    var name: String {
        switch self {
        case .waiting: return "waiting"
        case .steamWindow: return "steam-window"
        case .game: return "game"
        }
    }

    enum Owner: String { case client = "steam-client", helper, other, unknown }

    /// Where programs live on drive C, lower case, each ending in a backslash.
    struct Places: Equatable {
        var windows: String
        var client: String
        var clientLibrary: String
        /// `clientRoot`: the Steam client's folder as a Windows path ("C:\Program Files (x86)\Steam").
        init(clientRoot: String, windows: String = "C:\\windows") {
            func folder(_ path: String) -> String {
                let p = SteamLaunchScene.path(path)
                return p.hasSuffix("\\") ? p : p + "\\"
            }
            self.windows = folder(windows)
            self.client = folder(clientRoot)
            self.clientLibrary = client + "steamapps\\"
        }
    }

    /// Smaller shown windows are tray lists, tool strips and caption fragments.
    static let gameMinimum = (width: 160, height: 120)
    static let dialogMinimum = (width: 240, height: 120)

    /// A Windows or NT path in the census's form: lower case, backslashes, no
    /// "\??\" or "\\?\" prefix.
    static func path(_ image: String) -> String {
        var p = image.lowercased().replacingOccurrences(of: "/", with: "\\")
        if p.hasPrefix("\\??\\") || p.hasPrefix("\\\\?\\") { p.removeFirst(4) }
        return p
    }

    static func owner(_ image: String, places: Places) -> Owner {
        let p = path(image)
        if p.isEmpty { return .unknown }
        if p.hasPrefix(places.windows) { return .helper }
        if p.hasPrefix(places.client) && !p.hasPrefix(places.clientLibrary) { return .client }
        return .other
    }

    /// `rendered`: D3D frames reached the screen since the start began. Stands in
    /// for a window whose owner could not be read, never for a known helper.
    /// `early`: windows first shown before the Dock host started (the one-time
    /// installs), which are never the game's. `installerReveal`: an early window's
    /// dialog may need the user. Returns the window that decided, for the log.
    static func decide(_ windows: [SteamLaunchWindow], rendered: Bool, places: Places,
                       early: Set<UInt64> = [], installerReveal: Bool = true) -> (scene: SteamLaunchScene, window: SteamLaunchWindow?) {
        var steam: SteamLaunchWindow?
        for window in windows where window.visible {
            let gameSized = window.width >= gameMinimum.width && window.height >= gameMinimum.height
            let dialogSized = window.width >= dialogMinimum.width && window.height >= dialogMinimum.height
            let installer = early.contains(window.hwnd)
            switch owner(window.image, places: places) {
            case .other where !installer && gameSized && (window.drawn || rendered): return (.game, window)
            case .unknown where !installer && gameSized && rendered: return (.game, window)
            case .client where steam == nil && window.drawn && dialogSized:
                steam = window
            // A one-time installer that fails can show an error box and wait for OK, and
            // the start waits for it. MADEIRA_DOCK_INSTALLER_REVEAL=0 keeps them hidden.
            case .other where installer && steam == nil && window.drawn && dialogSized && installerReveal:
                steam = window
            default: break
            }
        }
        return steam.map { (.steamWindow, $0) } ?? (.waiting, nil)
    }
}

/// Whether the starting screen covers the Wine desktop during a Dock start.
/// DockStartScreen feeds it the scene every 0.5 s. The game's window ends the
/// hold. A window that may need the user, shown for `revealDelay` s, reveals the
/// desktop (when auto-reveal is on); once it has been gone for `coverDelay` s the
/// starting screen returns, at most `maxAutoReveals` times, after which the
/// desktop stays. Show desktop reveals it for good.
struct SteamLaunchHold {
    enum Action: Equatable { case none, showGame, reveal, cover }
    static let revealDelay = 2.0, coverDelay = 4.0, maxAutoReveals = 6
    let autoReveal: Bool
    private(set) var scene = SteamLaunchScene.waiting
    private(set) var revealed = false
    private(set) var manual = false
    private(set) var finished = false
    private(set) var autoReveals = 0
    private var steamSince: Double?
    private var clearSince: Double?

    init(autoReveal: Bool) { self.autoReveal = autoReveal }

    /// A window that may need the user is up and the starting screen still hides it.
    var needsAttention: Bool { !finished && !revealed && scene == .steamWindow }

    mutating func step(_ next: SteamLaunchScene, now: Double) -> Action {
        guard !finished else { return .none }
        scene = next
        switch next {
        case .game:
            finished = true
            return .showGame
        case .steamWindow:
            clearSince = nil
            let since = steamSince ?? now
            steamSince = since
            guard autoReveal, !revealed, autoReveals < Self.maxAutoReveals, now - since >= Self.revealDelay else { return .none }
            revealed = true
            autoReveals += 1
            return .reveal
        case .waiting:
            steamSince = nil
            guard revealed, !manual, autoReveals < Self.maxAutoReveals else { clearSince = nil; return .none }
            let since = clearSince ?? now
            clearSince = since
            guard now - since >= Self.coverDelay else { return .none }
            revealed = false
            clearSince = nil
            return .cover
        }
    }

    /// The user asked to see the desktop: shown at once, and never covered again.
    /// Returns false when it is already shown that way.
    mutating func showDesktop() -> Bool {
        guard !finished, !manual else { return false }
        revealed = true
        manual = true
        return true
    }
}

/// The starting screen's text for a Dock start, from the host's numeric report.
/// The host writes its fields as it goes (madeira-dock src/main.c,
/// session.c, launch.c), and the text follows the furthest stage reported: the
/// host started (probe-start-bits), the sign-in submitted, signed in, the game's
/// license confirmed, the game's executable prepared (only for a game that needs
/// it) and Steam's launch accepted (launch-client-error=0). Steam's own waits
/// (content, configuration, another session) come first.
enum DockStartStatus {
    /// Seconds without the host's first field before the text says it is late.
    static let slowAfter = 30.0

    /// What the start is doing. `installers`: this start runs the game's one-time
    /// installs first; `installerProgress`: their progress in words;
    /// `installsFinished`: they ended, and the host starts next. `waited`: seconds
    /// since the host could start (the start began, or the installs finished); it
    /// only matters before the host's first field.
    static func text(_ fields: [String: String], installers: Bool, installerProgress: String?,
                     installsFinished: Bool, waited: Double) -> String {
        if fields["launch-option-missing"] != nil || fields["launch-option-invalid"] != nil {
            return "Steam rejected this game's launch option."
        }
        if fields["launch-update-wait"] != nil && fields["launch-update-ready"] == nil {
            return "Steam is installing content this game needs. The game starts when it finishes…"
        }
        // Steam still counts an earlier session as playing (error 35); the Dock asks again.
        if fields["launch-session-wait"] != nil && fields["launch-client-error"] == "35" {
            return "Steam says this account is still playing in another session. Waiting for Steam to end it (up to 3 minutes)…"
        }
        // Right after sign-in Steam may not have the game's configuration yet (22, 23); the Dock asks again.
        if fields["launch-config-wait"] != nil && (fields["launch-client-error"] == "22" || fields["launch-client-error"] == "23") {
            return "Steam is still loading this game's configuration. Waiting for it…"
        }
        if fields["launch-client-error"] == "0" { return "The game is starting. Waiting for its window…" }
        if ["ceg-scm", "ceg-request-busy", "ceg-request"].contains(where: { fields[$0] != nil }) && fields["ceg-result"] == nil {
            return "Steam is preparing this game's executable…"
        }
        // Offline start: Valve's client signs in from what it saved while online.
        if fields["session-offline-listed"] == "1" { return "Offline: Steam found this game's license in what it saved. Starting the game…" }
        if fields["session-offline-logon-result"] == "1" || fields["session-offline-logon-retry"] == "1" {
            return "Offline: Steam signed in from its saved sign-in. Checking this game's license…"
        }
        if fields["session-offline-requested"] != nil || fields["session-offline-fallback"] != nil {
            return "No connection. Asking Steam to sign in offline…"
        }
        if fields["session-requested-app-listed"] == "1" { return "License confirmed. Steam is starting the game…" }
        if fields["session-authenticated-online"] == "1" { return "Signed in. Waiting for Steam to confirm this game's license…" }
        if fields["session-native-token-submitted"] != nil || fields["session-logon-start-result"] != nil {
            return "Signing in to Steam…"
        }
        if hostStarted(fields) { return "Loading Steam…" }
        // Before the host's first field: the one-time installs run first, then the host starts.
        let starting = waited >= slowAfter ? "Still starting Madeira Dock…" : "Starting Madeira Dock…"
        guard installers else { return starting }
        guard installsFinished else { return installerProgress ?? "Running this game's one-time installs…" }
        return (installerProgress ?? "One-time installs finished.") + "\n" + starting
    }

    /// The host has started (its first report field): the one-time installs are over.
    static func hostStarted(_ fields: [String: String]) -> Bool { fields["probe-start-bits"] != nil }

    /// The host reported a result. The host waits for the game it started, so a
    /// result while the starting screen is up means no game window appeared; any
    /// non-zero result is a failure too. nil when the start goes on.
    static func failure(result: Int?, words: String?, launching: Bool) -> String? {
        guard let result, launching || result != 0 else { return nil }
        return words ?? "Madeira Dock exited before a game window appeared. Export the diagnostic log."
    }
}

// MARK: - Model

extension SteamLaunchScene.Places {
    /// Madeira's Wine prefix: C:\windows and the Steam client Madeira Dock drives.
    static var standard: Self { Self(clientRoot: SteamRuntimeFiles.windowsRoot) }
}

/// A Dock start's starting screen: LibraryModel calls begin, poll and finish, and
/// LibraryHUD shows what it publishes. Like LibraryModel, it is used on the main
/// thread only (the session timer and the views).
final class DockStartScreen: ObservableObject {
    static let shared = DockStartScreen()

    /// A Dock start's session runs (the status line, a failure and its Close session).
    @Published private(set) var active = false
    /// The started game's App ID, for its artwork.
    @Published private(set) var appID: Int?
    /// Why the start stopped (the host's report in words); the starting screen stays.
    @Published private(set) var failure: String?
    /// The starting screen holds the desktop back and offers Show desktop.
    @Published private(set) var holding = false
    /// A window that may need the user is up behind the starting screen.
    @Published private(set) var attention = false

    private var hold: SteamLaunchHold?
    private var sceneLines = 0
    private var early = Set<UInt64>()
    private var hostStarted = false
    private var exitObserved = false
    private var started = Date()
    private let places = SteamLaunchScene.Places.standard

    /// A library session begins; `game` is set for a Dock start.
    func begin(_ game: DockGame?, at start: Date) {
        endHold(reason: nil)
        winios_window_census_enable(0)
        active = game != nil; appID = game?.id; failure = nil
        exitObserved = false; hostStarted = false; early = []; started = start
        guard let game, MadeiraConfig.flag("MADEIRA_DOCK_HIDE_DESKTOP") else { return }   // 0: a Dock start's starting screen ends on the desktop's first frame, as before
        let hold = SteamLaunchHold(autoReveal: MadeiraConfig.flag("MADEIRA_DOCK_AUTO_REVEAL"))   // 0: a window that may need the user never reveals the desktop by itself (Show desktop still does)
        self.hold = hold; sceneLines = 0; holding = true
        winios_window_census_enable(1)
        LogStore.shared.log("[steam-launch-view] hold app=\(game.id) auto-reveal=\(hold.autoReveal ? 1 : 0)")
    }

    /// The session ended.
    func finish() {
        endHold(reason: "session-ended")
        winios_window_census_enable(0)
        active = false; appID = nil; failure = nil
    }

    /// Every 0.5 s from LibraryModel.poll while a session runs. `rendered`: D3D
    /// frames reached the screen since the start began.
    func poll(_ model: LibraryModel, rendered: Bool) {
        guard active else { return }
        let elapsed = Date().timeIntervalSince(started)
        var report: MadeiraDock.Report?
        // The host's result: a start that stopped keeps the starting screen with the report's words.
        if !exitObserved && MadeiraConfig.flag("MADEIRA_DOCK_STATUS") {   // 0: the starting screen does not watch the host's result
            let current = MainActor.assumeIsolated { MadeiraDock.pollReport() }
            report = current
            if current.result != nil {
                exitObserved = true
                if let words = DockStartStatus.failure(result: current.result, words: current.failure, launching: model.launching) {
                    failure = words
                    LogStore.shared.log("[dock-status] host-ended result=\(current.result ?? 0) starting=\(model.launching ? 1 : 0)", level: .error)
                    MainActor.assumeIsolated { MadeiraDock.cleanup() }
                }
            }
        }
        guard var hold else { return }
        if !hostStarted {
            hostStarted = DockStartStatus.hostStarted((report ?? MainActor.assumeIsolated { MadeiraDock.pollReport() }).fields)
        }
        let windows = Self.censusWindows()
        // Windows shown before the host started belong to the one-time installs.
        if !hostStarted { for window in windows where window.visible { early.insert(window.hwnd) } }
        let installerReveal = MadeiraConfig.flag("MADEIRA_DOCK_INSTALLER_REVEAL")   // 0: a one-time installer's dialog never reveals the desktop by itself
        let decision = SteamLaunchScene.decide(windows, rendered: rendered, places: places, early: early, installerReveal: installerReveal)
        if decision.scene != hold.scene, sceneLines < 24 {
            sceneLines += 1
            let window = decision.window.map {
                " window=\($0.width)x\($0.height) owner=\(SteamLaunchScene.owner($0.image, places: places).rawValue)" +
                    (early.contains($0.hwnd) ? "-installer" : "") + " pid=\(String($0.pid, radix: 16))"
            } ?? ""
            LogStore.shared.log("[steam-launch-view] scene=\(decision.scene.name) shown=\(windows.filter(\.visible).count)\(window) t=\(Int(elapsed))s")
        }
        let action = hold.step(decision.scene, now: elapsed)
        self.hold = hold
        switch action {
        case .none:
            break
        case .showGame:
            endHold(reason: "game-window")
            if model.launching { model.showGameView(reason: "game-window") }
            return
        case .reveal:
            LogStore.shared.log("[steam-launch-view] reveal reason=steam-window count=\(hold.autoReveals) t=\(Int(elapsed))s")
            if model.launching { model.showGameView(reason: "steam-window") }
        case .cover:
            // The window was answered; back to the starting screen.
            LogStore.shared.log("[steam-launch-view] cover reason=steam-window-closed t=\(Int(elapsed))s")
            LibraryKeyboard.hide(); model.menu = false
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { model.launching = true }
        }
        if attention != hold.needsAttention { attention = hold.needsAttention }
    }

    /// Show desktop on the starting screen: the desktop stays until the game's window is up.
    func showDesktop(_ model: LibraryModel) {
        guard var hold, hold.showDesktop() else { return }
        self.hold = hold
        attention = false
        LogStore.shared.log("[steam-launch-view] reveal reason=button scene=\(hold.scene.name) t=\(Int(Date().timeIntervalSince(started)))s")
        model.showGameView(reason: "show-desktop")
    }

    private func endHold(reason: String?) {
        guard hold != nil || holding else { return }
        if let reason, let hold {
            LogStore.shared.log("[steam-launch-view] end reason=\(reason) scene=\(hold.scene.name) revealed=\(hold.revealed ? 1 : 0) t=\(Int(Date().timeIntervalSince(started)))s")
        }
        hold = nil
        holding = false; attention = false
        // 2: the game's window is found, but its main window may still be shown for the first time
        // minimized; Winios.m goes on restoring such windows until finish() ends the session.
        winios_window_census_enable(reason == "game-window" ? 2 : 0)
    }

    /// Winios.m's census as SteamLaunchScene reads it.
    private static func censusWindows() -> [SteamLaunchWindow] {
        var raw = [winios_census_window](repeating: winios_census_window(), count: Int(WINIOS_CENSUS_MAX))
        let count = Int(winios_window_census(&raw, Int32(raw.count)))
        return raw.prefix(max(0, min(count, raw.count))).map { window in
            let image = withUnsafeBytes(of: window.image) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
            return SteamLaunchWindow(image: image, width: Int(window.w), height: Int(window.h), visible: window.visible != 0,
                                     drawn: window.presents > 0 || window.metal != 0, pid: window.pid, hwnd: window.hwnd)
        }
    }
}

/// The started game's Steam artwork as the starting screen's backdrop: the wide
/// library hero, else the cover (public store artwork by App ID, no account data).
struct SteamLaunchBackdrop: View {
    let appID: Int
    @State private var useCover = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                AsyncImage(url: useCover ? SteamGamesRules.cover(appID) : Self.hero(appID)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    case .failure:
                        Color.clear.onAppear { useCover = true }
                    default:
                        Color.clear
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .accessibilityHidden(true)
    }

    static func hero(_ appID: Int) -> URL? {
        guard appID > 0 else { return nil }
        return URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_hero.jpg")
    }
}
