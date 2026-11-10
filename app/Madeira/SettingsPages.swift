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

        /// The colour of the page's icon square on iPad (SettingsSplit).
        var color: Color {
            func rgb(_ value: Int) -> Color { Color(red: Double(value >> 16) / 255, green: Double(value >> 8 & 0xff) / 255, blue: Double(value & 0xff) / 255) }
            switch self {
            case .steam: return rgb(0x2b5d93)
            case .gog: return rgb(0x2f7a8a)
            case .itch: return rgb(0xb8433b)
            case .epic: return rgb(0x4a4b52)
            case .ea: return rgb(0xb0732a)
            case .runtimes: return rgb(0x6a5acd)
            case .displayGraphics: return rgb(0x2e8b57)
            case .memory: return rgb(0xc0574a)
            case .pointer: return rgb(0x5a5f6b)
            case .jit: return rgb(0xe0a000)
            case .signing: return rgb(0x3a8fb7)
            case .saves: return rgb(0x4b8f5a)
            case .drives, .advanced, .logs: return rgb(0x6b6f78)
            case .appearance: return rgb(0x4a8cff)
            case .credits: return rgb(0xc2415a)
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

    /// The rows of the Settings tab, in groups.
    static let groups: [(String?, [Page])] = [
        ("Getting games", [.steam, .gog, .itch, .epic, .ea, .runtimes]),
        ("Running games", [.displayGraphics, .memory, .pointer]),
        ("Device", [.jit, .signing, .saves, .drives]),
        (nil, [.appearance, .advanced, .logs, .credits]),
    ]

    /// The new look's Settings tab: short groups as in its mock-up, games first. Signing in to a
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
    /// On iPad (SettingsSplit): a card with the page's icon, title and what it is for, first.
    var header = false
    @State private var sheet: SettingsSheet?
    @State private var refresh = 0
    @ObservedObject private var input = InputSettings.shared
    @ObservedObject private var liquidMetal = LiquidMetalSetting.shared
    @AppStorage(LibraryGridArm.key) private var zoomableGrid = false
    @AppStorage(GridZoomHapticPlayer.key) private var zoomHaptics = true
    @AppStorage(NewLook.key) private var newLookOn = true
    @AppStorage(NewLook.coverWidthKey) private var coverWidth: Double = 104
    @AppStorage(TouchControlStyle.key) private var controlStyle = "glass"
    @State private var developerUI = !FrontendChoice.preferNew
    @State private var restartNotice = false

    var body: some View {
        Form {
            if header { SettingsPageHeader(page: page) }
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
            // The new look (NewLook.swift), on unless env.MADEIRA_NEW_LOOK = 0.
            if NewLook.allowed {
                Toggle("New look", isOn: $newLookOn)
                if newLookOn {
                    // (new-look) The Library's covers; a pinch on them changes it too. A on it steps to the next size.
                    Picker("Cover size", selection: Binding(get: { NewLook.coverStep(coverWidth) },
                                                            set: { coverWidth = NewLook.coverWidths[$0] })) {
                        Text("Small").tag(0)
                        Text("Medium").tag(1)
                        Text("Large").tag(2)
                    }
                    .padItem("ap-cover-size", cornerRadius: 12) { coverWidth = NewLook.coverWidths[(NewLook.coverStep(coverWidth) + 1) % 3] }
                }
            }
            Toggle("New library grid", isOn: $zoomableGrid)
            if zoomableGrid {
                Toggle("Zoom haptics", isOn: $zoomHaptics)
            }
        } footer: {
            Text(NewLook.allowed
                 ? L("New look: a tab bar, every installed game on one page, the Madeira island behind it and one controller highlight. Off, the library is one page with store tabs, as before. New library grid applies only with New look off: pinch the cards to change how many fit across. Zoom haptics click as the pinch crosses a size.")
                 : L("Pinch the library's cards to change how many fit across. Off, the cards use the original grid. Zoom haptics click as the pinch crosses a size."))
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

/// A page's square icon on its colour, as in the iPad's own Settings app.
struct SettingsPageIcon: View {
    let page: SettingsPages.Page
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: page.symbol)
            .font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(page.color, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The card at the top of a page on iPad: the big icon, the title and what the page is for.
struct SettingsPageHeader: View {
    let page: SettingsPages.Page
    var body: some View {
        Section {
            VStack(spacing: 8) {
                SettingsPageIcon(page: page, size: 58)
                Text(page.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(page.blurb).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
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
