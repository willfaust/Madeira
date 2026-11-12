// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

// Settings in pages, as Game details is: the Settings tab lists a few groups of rows,
// and each row opens a page with the sections it holds.

enum SettingsPages {
    enum Page: Hashable, CaseIterable {
        case steam, gog, itch, epic, ea, runtimes, displayGraphics, memory, pointer, jit, signing, saves, drives,
             appearance, advanced, logs, credits

        var title: String {
            switch self {
            case .steam: return "Steam and Dock"
            case .gog: return "GOG"
            case .itch: return "itch.io"
            case .epic: return "Epic Games"
            case .ea: return "EA app"
            case .runtimes: return "Runtimes"
            case .displayGraphics: return "Display and Graphics"
            case .memory: return "Memory and sync"
            case .pointer: return "Pointer and touch"
            case .jit: return "JIT"
            case .signing: return "Signing"
            case .saves: return "Saves and backups"
            case .drives: return "External drives"
            case .appearance: return "Appearance"
            case .advanced: return "Advanced"
            case .logs: return "Logs"
            case .credits: return "Credits"
            }
        }

        var symbol: String {
            switch self {
            case .steam: return "shippingbox"
            case .gog: return "bag"
            case .itch: return "arrow.down.app"
            case .epic: return "gamecontroller"
            case .ea: return "arrow.down.circle"
            case .runtimes: return "puzzlepiece.extension"
            case .displayGraphics: return "display"
            case .memory: return "memorychip"
            case .pointer: return "cursorarrow"
            case .jit: return "bolt"
            case .signing: return "signature"
            case .saves: return "externaldrive.badge.timemachine"
            case .drives: return "externaldrive"
            case .appearance: return "paintpalette"
            case .advanced: return "wrench.and.screwdriver"
            case .logs: return "doc.text.magnifyingglass"
            case .credits: return "heart"
            }
        }

        /// The page's name for the iPad layout's stored choice.
        var key: String { String(describing: self) }

        /// The store a store's page is for (its logo is the page's icon).
        var store: NewLookStore? {
            switch self {
            case .steam: return .steam
            case .gog: return .gog
            case .itch: return .itch
            case .epic: return .epic
            case .ea: return .ea
            default: return nil
            }
        }

        /// One line under the page's title on iPad, saying what the page is for.
        var blurb: String {
            switch self {
            case .steam: return L("Sign in to Steam and start games with Madeira Dock.")
            case .gog: return L("Sign in to GOG to install your GOG games.")
            case .itch: return L("Sign in to itch.io to install your itch.io games.")
            case .epic: return L("Sign in to Epic Games to install your Epic games.")
            case .ea: return L("Sign in to the EA app to install your EA games.")
            case .runtimes: return L("The extra Windows parts some games need to start.")
            case .displayGraphics: return L("How games are drawn, and their frame rate on this screen.")
            case .memory: return L("How games use this device's memory.")
            case .pointer: return L("The mouse pointer and touch in games.")
            case .jit: return L("JIT lets games run fast. Madeira needs it to play.")
            case .signing: return L("When this copy of Madeira needs signing again.")
            case .saves: return L("Back up your game saves and bring them back.")
            case .drives: return L("Keep games on an external drive.")
            case .appearance: return L("How Madeira looks: the library's store sidebar, the bars, and the touch buttons in games.")
            case .advanced: return L("Logs, help and every option, for when something goes wrong.")
            case .logs: return L("What Madeira and your games wrote while running.")
            case .credits: return L("The people and projects Madeira is built on.")
            }
        }

        // A page shows when the long page would show its sections: the same switches.
        @MainActor var shown: Bool {
            switch self {
            case .steam: return SteamSettingsSection.shown
            case .gog: return GOGLibrary.enabled
            case .itch: return ItchLibrary.enabled
            case .epic: return EpicLibrary.enabled
            case .ea: return EALibrary.enabled
            case .signing: return SigningRefresh.enabled
            // One page for both (display-graphics): it shows when either part would.
            case .displayGraphics: return GraphicsSettings.shown || LibraryView.runtimeSettingsShown
            case .memory: return LibraryView.runtimeSettingsShown
            default: return true
            }
        }
    }

    /// The Settings tab: short groups as in the mock-up, games first. Signing in to a
    /// store is also on the Stores tab, so the stores come lower down.
    static let newLookGroups: [(String?, [Page])] = [
        ("Games", [.displayGraphics, .memory, .pointer, .runtimes]),
        ("Storage", [.saves, .drives]),
        ("This device", [.jit, .signing]),
        ("Stores", [.steam, .gog, .itch, .epic, .ea]),
        ("Look", [.appearance]),
        ("Help", [.logs, .advanced]),
        ("About", [.credits]),
    ]
}

/// One page. Its sheets hang off its own Form, never off a page the navigation has covered.
struct SettingsPageView: View {
    let page: SettingsPages.Page
    var startDock: (DockGame, Bool) -> Void
    @State private var sheet: SettingsSheet?
    @State private var refresh = 0
    @ObservedObject private var input = InputSettings.shared
    @ObservedObject private var liquidMetal = LiquidMetalSetting.shared
    @AppStorage(NewLook.zoomHapticsKey) private var zoomHaptics = true
    @AppStorage(NewLook.coverWidthKey) private var coverWidth: Double = 104
    @AppStorage(TouchControlStyle.key) private var controlStyle = "glass"
    @State private var developerUI = !FrontendChoice.preferNew
    @State private var restartNotice = false

    var body: some View {
        Form {
            content
        }
            .navigationTitle(page.title).navigationBarTitleDisplayMode(.inline)
            // (new-look) The island behind the page, and B goes back.
            .modifier(NewLookSettingsChrome())
            .alert("Restart Madeira", isPresented: $restartNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Close Madeira from the app switcher and open it again to switch interfaces.")
            }
            .sheet(item: $sheet, onDismiss: { refresh += 1 }) { sheet in
                Group {
                    switch sheet {
                    case .allSettings: AllSettingsView()
                    case .steamSignIn: SteamSignInView()
                    case .gogSignIn: GOGSignInView()
                    case .epicSignIn: EpicSignInView()
                    case .eaSignIn: EASignInView()
                    case .dock: MadeiraDockView(start: startDock)
                    }
                }
                // A controller's B closes it, and the Settings list leaves the pad alone meanwhile.
                .menuPadSheet()
                .logScreen("Settings sheet: \(String(describing: sheet))")
            }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .steam: SteamSettingsSection(open: { sheet = $0 })
        case .gog: GOGSettingsSection(open: { sheet = $0 })
        case .itch: ItchSettingsSection()
        case .epic: EpicSettingsSection(open: { sheet = $0 })
        case .ea: EASettingsSection(open: { sheet = $0 })
        case .runtimes:
            WineMonoSettingsSection()
            if VCRedistModel.enabled { VCRedistSettingsSection() }
            WineGeckoSettingsSection()
        case .displayGraphics:
            // The Direct3D and Vulkan pickers first, then the display rate in its own section.
            if GraphicsSettings.shown { GraphicsSettings(refresh: refresh) }
            if LibraryView.runtimeSettingsShown { DisplayRateSettings() }
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
                // GetHelpView.swift: the scrubbed report as one .txt for the Madeira Discord (Cameron, Nov 8).
                DiscordLogButton(entry: nil, row: true)
                NavigationLink { Form { LogsSection() }.navigationTitle("Logs") } label: {
                    Label("Logs", systemImage: "doc.text.magnifyingglass")      // LogsView.swift
                }
            } header: { Text("Diagnostics") } footer: {
                Text("Save copy for Discord makes one text file (up to 5 MB) with the last game's log and your settings, with personal details taken out. Post it in the Madeira Discord.")
            }
            Section {
                Button("All settings") { sheet = .allSettings }
            } footer: {
                Text("Every option Madeira reads from madeira.cfg, by subsystem.")
            }
        case .logs: LogsSection()
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
            Picker("Touch control buttons", selection: $controlStyle) {
                ForEach(TouchControlStyle.styles, id: \.id) { Text($0.name).tag($0.id) }
            }
        } footer: {
            Text("Glass is the system's Liquid Glass. Solid draws each button as a plain opaque disc; a game's Opacity slider still fades them.")
        }
        Section {
            // The Library's covers; a pinch on them changes it too. A on it steps to the next size.
            Picker("Cover size", selection: Binding(get: { NewLook.coverStep(coverWidth) },
                                                    set: { coverWidth = NewLook.coverWidths[$0] })) {
                Text("Small").tag(0)
                Text("Medium").tag(1)
                Text("Large").tag(2)
            }
            .padItem("ap-cover-size", cornerRadius: 12) { coverWidth = NewLook.coverWidths[(NewLook.coverStep(coverWidth) + 1) % 3] }
            Toggle("Zoom haptics", isOn: $zoomHaptics)
        } footer: {
            Text("Pinch the library's covers to change how many fit across. Zoom haptics click as the pinch crosses a size.")
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

/// The credits, on their own page.
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
