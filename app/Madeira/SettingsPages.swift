// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

// Settings in pages, as Game details is: the Settings tab lists a few groups of rows,
// and each row opens a page with the sections that were on the one long page. Each
// section is the same view it was there. While the search field holds text, the tab
// shows the one long page filtered, as before, so a match is found wherever it lives.
// env.MADEIRA_SETTINGS_PAGES = 0 keeps the one long page.

enum SettingsPages {
    /// On by default: the Settings tab lists its pages, each opening the sections it holds.
    /// 0: the one long page with every section, as before.
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_SETTINGS_PAGES") }

    enum Page: Hashable, CaseIterable {
        case steam, itch, epic, runtimes, graphics, display, memory, pointer, jit, signing, saves, drives,
             appearance, advanced, credits

        var title: String {
            switch self {
            case .steam: return "Steam and Dock"
            case .itch: return "itch.io"
            case .epic: return "Epic Games"
            case .runtimes: return "Runtimes"
            case .graphics: return "Graphics"
            case .display: return "Display"
            case .memory: return "Memory and sync"
            case .pointer: return "Pointer and touch"
            case .jit: return "JIT"
            case .signing: return "Signing"
            case .saves: return "Saves and backups"
            case .drives: return "External drives"
            case .appearance: return "Appearance"
            case .advanced: return "Advanced"
            case .credits: return "Credits"
            }
        }

        var symbol: String {
            switch self {
            case .steam: return "shippingbox"
            case .itch: return "arrow.down.app"
            case .epic: return "gamecontroller"
            case .runtimes: return "puzzlepiece.extension"
            case .graphics: return "cpu"
            case .display: return "display"
            case .memory: return "memorychip"
            case .pointer: return "cursorarrow"
            case .jit: return "bolt"
            case .signing: return "signature"
            case .saves: return "externaldrive.badge.timemachine"
            case .drives: return "externaldrive"
            case .appearance: return "paintpalette"
            case .advanced: return "wrench.and.screwdriver"
            case .credits: return "heart"
            }
        }

        // A page shows when the long page would show its sections: the same switches.
        @MainActor var shown: Bool {
            switch self {
            case .steam: return SteamSettingsSection.shown
            case .itch: return ItchLibrary.enabled
            case .epic: return EpicLibrary.enabled
            case .signing: return SigningRefresh.enabled
            case .graphics: return GraphicsSettings.shown
            case .display, .memory: return LibraryView.runtimeSettingsShown
            default: return true
            }
        }
    }

    /// The rows of the Settings tab, in groups.
    static let groups: [(String?, [Page])] = [
        ("Getting games", [.steam, .itch, .epic, .runtimes]),
        ("Running games", [.graphics, .display, .memory, .pointer]),
        ("Device", [.jit, .signing, .saves, .drives]),
        (nil, [.appearance, .advanced, .credits]),
    ]
}

/// The Settings tab's first page: the status, then a row for each page.
struct SettingsPagesList: View {
    var startDock: (DockGame, Bool) -> Void
    @ObservedObject private var jitState = LibraryJITState.shared
    @ObservedObject private var liquidMetal = LiquidMetalSetting.shared

    var body: some View {
        Form {
            Section { LibraryStatus().listRowBackground(Color.clear) }
            ForEach(Array(SettingsPages.groups.enumerated()), id: \.offset) { _, group in
                let pages = group.1.filter(\.shown)
                if !pages.isEmpty {
                    Section {
                        ForEach(pages, id: \.self) { page in
                            NavigationLink { SettingsPageView(page: page, startDock: startDock) } label: { row(page) }
                        }
                    } header: { if let title = group.0 { Text(title) } }
                }
            }
        }
    }

    @ViewBuilder private func row(_ page: SettingsPages.Page) -> some View {
        if let value = summary(page) {
            LabeledContent { Text(value).lineLimit(1) } label: { Label(page.title, systemImage: page.symbol) }
        } else {
            Label(page.title, systemImage: page.symbol)
        }
    }

    private func summary(_ page: SettingsPages.Page) -> String? {
        switch page {
        case .jit: return jitState.enabled ? "On" : "Off"
        case .appearance: return liquidMetal.on ? "Liquid metal" : "Liquid Glass"
        default: return nil
        }
    }
}

/// One page. Its sheets hang off its own Form, as the long page's did, never off a
/// page the navigation has covered.
struct SettingsPageView: View {
    let page: SettingsPages.Page
    var startDock: (DockGame, Bool) -> Void
    @State private var sheet: SettingsSheet?
    @State private var refresh = 0
    @ObservedObject private var input = InputSettings.shared
    @ObservedObject private var liquidMetal = LiquidMetalSetting.shared
    @AppStorage(LibraryGridArm.key) private var zoomableGrid = false
    @AppStorage(GridZoomHapticPlayer.key) private var zoomHaptics = true
    @State private var developerUI = !FrontendChoice.preferNew
    @State private var restartNotice = false

    var body: some View {
        Form { content }
            .navigationTitle(page.title).navigationBarTitleDisplayMode(.inline)
            .alert("Restart Madeira", isPresented: $restartNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Close Madeira from the app switcher and open it again to switch interfaces.")
            }
            .sheet(item: $sheet, onDismiss: { refresh += 1 }) { sheet in
                switch sheet {
                case .allSettings: AllSettingsView()
                case .steamSignIn: SteamSignInView()
                case .epicSignIn: EpicSignInView()
                case .dock: MadeiraDockView(start: startDock)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .steam: SteamSettingsSection(open: { sheet = $0 })
        case .itch: ItchSettingsSection()
        case .epic: EpicSettingsSection(open: { sheet = $0 })
        case .runtimes:
            WineMonoSettingsSection()
            if VCRedistModel.enabled { VCRedistSettingsSection() }
            WineGeckoSettingsSection()
        case .graphics: GraphicsSettings(refresh: refresh)
        case .display: DisplayRateSettings()
        case .memory: RuntimeMemorySyncSettings(open: { sheet = $0 }, refresh: refresh)
        case .pointer: Section("Pointer") { LibraryPointerSettings() }
        case .jit: JITSettingsSection()
        case .signing: SigningSettingsSection()
        case .saves: SavesSection()
        case .drives: ExternalDrivesSection()
        case .appearance: appearance
        case .advanced:
            Section {
                Toggle("Extended logging", isOn: $input.diagnostics)
            } header: { Text("Diagnostics") }
            Section {
                Button("All settings") { sheet = .allSettings }
            } footer: {
                Text("Every option Madeira reads from madeira.cfg, by subsystem.")
            }
        case .credits: SettingsCreditsSection()
        }
    }

    @ViewBuilder private var appearance: some View {
        Section {
            Toggle("Liquid metal", isOn: $liquidMetal.on)
        } footer: {
            Text("Flowing chrome on the bars and the Desktop button. Off, they use the system's Liquid Glass.")
        }
        Section {
            Toggle("New library grid", isOn: $zoomableGrid)
            if zoomableGrid {
                Toggle("Zoom haptics", isOn: $zoomHaptics)
            }
        } footer: {
            Text("Pinch the library's cards to change how many fit across. Off, the cards use the original grid. Zoom haptics click as the pinch crosses a size.")
        }
        Section {
            Toggle("Use developer interface", isOn: Binding(get: { developerUI }, set: { on in
                developerUI = on; FrontendChoice.choose(new: !on); restartNotice = true
            }))
        } header: { Text("Interface") } footer: {
            Text("The developer interface is Madeira's original diagnostic screen. The change applies after Madeira restarts.")
        }
    }
}

/// The credits, on their own page and last on the long one.
struct SettingsCreditsSection: View {
    var body: some View {
        Section {
            MadeiraCredit(name: "Will Faust", handle: "willfaust", role: "Created Madeira")
            MadeiraCredit(name: "Nick", handle: "125hz", role: "32-bit game support, the game library and Madeira Dock")
            MadeiraCredit(name: "Jfishin", handle: "Jfishin", role: "The original native Steam sign-in, library and downloads")
            MadeiraCredit(name: "Jesse", handle: "JesseLovelace", role: "Steam Cloud saves, faster game launches, and fixes that let more games run")
            MadeiraCredit(name: "Dan Perks", handle: "danperks", role: "In-app JIT without StikDebug, and pairing without a computer")
            MadeiraCredit(name: "bahacan16", handle: "bahacan16", role: "Direct3D 12 and DXMT fixes, game launcher windows, per-game settings, PlayStation controllers, and save backups")
            MadeiraCredit(name: "spitefulowl", handle: "spitefulowl", role: "Wine and FEX runtime fixes, DXMT texture and memory fixes, audio, the swap tier, and library launch options")
            MadeiraCredit(name: "meshoklv", handle: "meshoklv", role: "Controller fixes for games that ship their own XInput or need focus, touch taps that stay off the mouse, and a crash-guard fix")
            MadeiraCredit(name: "TheHadesc", handle: "TheHadesc", role: "Madeira Dock starts for games whose Steam launch entries do not start at zero, and a touch gamepad that survives the in-game keyboard")
        } header: { Text("Credits") } footer: {
            Text("Madeira is built on Wine, FEX-Emu, DXMT by Feifan He (3Shain) with the Direct3D 9 frontend by David Acevedo (dacevedo12), rpmalloc by Mattias Jansson, StikDebug, StikJIT and idevice. Thank you to everyone who contributes to these projects.")
        }
    }
}
