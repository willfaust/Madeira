import SwiftUI

// The library as a store sidebar: a list of shelves on
// the left (Ready to play, then each store, then Other games) and the chosen shelf's
// games on the right. Sideways on an iPad the list shows names; upright, on an iPhone
// and in narrow windows it folds to a rail of store icons, and ≡ slides the full list
// out over the page. Windows desktop and Settings sit at the bottom of the list.
// Each store's page is that store's own section (sign-in, installs and game pages are
// unchanged). Settings › Appearance › Store sidebar turns it off; env.MADEIRA_LIBRARY_SIDEBAR = 0
// takes the sidebar and that switch away: the earlier page with its store tabs.

enum LibrarySidebar {
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_LIBRARY_SIDEBAR") }
    static let key = "madeiraLibraryShelf"
    /// Settings › Appearance › Store sidebar: off brings back the earlier page without a restart.
    static let settingKey = "madeiraLibrarySidebar"
    /// Wide and sideways: the list with names. Anything else: the icon rail.
    static func showsNames(_ size: CGSize) -> Bool { size.width >= 900 && size.width > size.height }

    // Design D's colours in dark mode; the system's grouped colours in light mode.
    static let page = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x14 / 255, green: 0x15 / 255, blue: 0x18 / 255, alpha: 1) : .systemGroupedBackground })
    static let bar = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x1c / 255, green: 0x1d / 255, blue: 0x21 / 255, alpha: 1) : .secondarySystemGroupedBackground })
    static let picked = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x30 / 255, green: 0x32 / 255, blue: 0x3a / 255, alpha: 1) : .tertiarySystemFill })
    static let line = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x2c / 255, green: 0x2d / 255, blue: 0x33 / 255, alpha: 1) : .separator })
    static let blue = Color(red: 0x4a / 255, green: 0x8c / 255, blue: 0xff / 255)
    static let green = Color(red: 0x34 / 255, green: 0xc7 / 255, blue: 0x59 / 255)
    /// Search fields, the page's buttons and the status card.
    static let chip = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x2a / 255, green: 0x2b / 255, blue: 0x31 / 255, alpha: 1) : .tertiarySystemFill })
    static let card = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x22 / 255, green: 0x23 / 255, blue: 0x28 / 255, alpha: 1) : .systemBackground })
    /// Settings laid out like the iPad's own Settings app: the list always on the left.
    @MainActor static var padSettings: Bool { UIDevice.current.userInterfaceIdiom == .pad }
}

/// One entry of the sidebar.
enum LibraryShelf: String, CaseIterable, Identifiable {
    case ready, steam, epic, gog, itch, ea, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ready: return L("Ready to play")
        case .steam: return "Steam"
        case .epic: return "Epic Games"
        case .gog: return "GOG"
        case .itch: return "itch.io"
        case .ea: return "EA app"
        case .other: return L("Other games")
        }
    }

    /// Ready to play, the stores that are turned on, and Other games last.
    @MainActor static var available: [LibraryShelf] {
        var shelves: [LibraryShelf] = [.ready]
        if MadeiraDock.enabled { shelves.append(.steam) }
        if EpicLibrary.enabled { shelves.append(.epic) }
        if GOGLibrary.enabled { shelves.append(.gog) }
        if ItchLibrary.enabled { shelves.append(.itch) }
        if EALibrary.enabled { shelves.append(.ea) }
        shelves.append(.other)
        return shelves
    }

    /// The stored shelf, or Ready to play when it is not offered (its store was turned off).
    @MainActor static func current(_ stored: String) -> LibraryShelf {
        guard let shelf = LibraryShelf(rawValue: stored), available.contains(shelf) else { return .ready }
        return shelf
    }

    /// A store's page is its section, whose title folds it away: opening the page from the
    /// sidebar unfolds it, so a page is never empty because of an old fold.
    func unfold() {
        let defaults = UserDefaults.standard
        switch self {
        case .steam: defaults.set(false, forKey: "madeiraLibraryHideInstalled"); defaults.set(true, forKey: "madeiraSteamShowUninstalled")
        case .epic: defaults.set(false, forKey: "madeiraLibraryHideEpic"); defaults.set(true, forKey: "madeiraEpicShowUninstalled")
        case .gog: defaults.set(false, forKey: "madeiraLibraryHideGOG"); defaults.set(true, forKey: "madeiraGOGShowUninstalled")
        case .itch: defaults.set(false, forKey: "madeiraLibraryHideItch"); defaults.set(true, forKey: "madeiraItchShowUninstalled")
        case .ea: defaults.set(false, forKey: "madeiraLibraryHideEA"); defaults.set(true, forKey: "madeiraEAShowUninstalled")
        case .other: defaults.set(false, forKey: "madeiraLibraryHideOthers")
        case .ready: break
        }
    }
}

/// A shelf's square icon: a letter on the store's colour (a play mark for Ready to play, a plus for Other games).
struct LibraryShelfBadge: View {
    let shelf: LibraryShelf
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26).fill(color)
            switch shelf {
            case .ready: Image(systemName: "play.fill").font(.system(size: size * 0.4, weight: .bold))
            case .other: Image(systemName: "plus").font(.system(size: size * 0.45, weight: .bold))
            default: Text(letter).font(.system(size: size * (letter.count > 1 ? 0.36 : 0.46), weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
    private var letter: String {
        switch shelf {
        case .steam: return "S"
        case .epic: return "E"
        case .gog: return "G"
        case .itch: return "i"
        case .ea: return "EA"
        default: return ""
        }
    }
    private var color: Color {
        switch shelf {
        case .ready: return LibrarySidebar.blue
        case .steam: return Color(red: 0x2b / 255, green: 0x5d / 255, blue: 0x93 / 255)
        case .epic: return Color(red: 0x4a / 255, green: 0x4b / 255, blue: 0x52 / 255)
        case .gog: return Color(red: 0x2f / 255, green: 0x7a / 255, blue: 0x8a / 255)
        case .itch: return Color(red: 0xb8 / 255, green: 0x43 / 255, blue: 0x3b / 255)
        case .ea: return Color(red: 0xb0 / 255, green: 0x73 / 255, blue: 0x2a / 255)
        case .other: return Color(red: 0x55 / 255, green: 0x57 / 255, blue: 0x5f / 255)
        }
    }
}

/// The shelf counts and sign-in states the sidebar shows beside each name.
@MainActor private struct LibraryShelfNote {
    let ready: Int
    let others: Int
    func text(_ shelf: LibraryShelf) -> String {
        switch shelf {
        case .ready: return ready > 0 ? "\(ready)" : ""
        case .other: return others > 0 ? "\(others)" : ""
        case .steam:
            let steam = SteamOwnedLibrary.shared
            if SteamOwnedLibrary.enabled && !steam.signedIn { return L("Sign in") }
            let count = SteamGamesRules.items(installed: SteamGamesModel.shared.games, owned: SteamOwnedLibrary.enabled ? steam.owned : [], search: "").count
            return count > 0 ? "\(count)" : ""
        case .epic:
            let epic = EpicLibrary.shared
            return epic.signedIn ? count(EpicGamesRules.items(epic, search: "").count) : L("Sign in")
        case .gog:
            let gog = GOGLibrary.shared
            return gog.signedIn ? count(GOGGamesRules.items(gog, search: "").count) : L("Sign in")
        case .itch:
            let itch = ItchLibrary.shared
            return itch.signedIn ? count(ItchGamesRules.items(itch, search: "").count) : L("Sign in")
        case .ea:
            let ea = EALibrary.shared
            return ea.signedIn ? count(EAGamesRules.items(ea, search: "").count) : L("Sign in")
        }
    }
    private func count(_ n: Int) -> String { n > 0 ? "\(n)" : "" }
}

/// The sidebar and the page beside it. `page` draws a shelf's page for a content width.
struct LibrarySidebarFrame<Page: View>: View {
    @Binding var selection: String
    /// How many games Ready to play and Other games hold, for the list.
    let readyCount: Int
    let otherCount: Int
    /// The library's search: its field is at the top of the list, and 🔍 on the rail opens it.
    @Binding var search: String
    let desktop: () -> Void
    let settings: () -> Void
    /// The page for a shelf, its width, and whether the icon rail is showing (no names).
    @ViewBuilder let page: (LibraryShelf, CGFloat, Bool) -> Page
    @State private var drawer = false
    @FocusState private var searchFocused: Bool
    /// A controller's ring on the list's rows and the rail's icons (MenuPad.swift).
    @ObservedObject private var pad = MenuPad.shared
    // The stores' sign-in and game counts redraw the list when they change.
    @ObservedObject private var steamGames = SteamGamesModel.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var gog = GOGLibrary.shared
    @ObservedObject private var epic = EpicLibrary.shared
    @ObservedObject private var itch = ItchLibrary.shared
    @ObservedObject private var ea = EALibrary.shared

    private var current: LibraryShelf { LibraryShelf.current(selection) }
    /// The slid-out list opens and closes at once, like the store switch (Cameron, Nov 7: the ≡
    /// and search buttons were still slow; "Yes, instant"). withAnimation(nil) changes it unanimated.
    private var animation: Animation? { nil }

    var body: some View {
        GeometryReader { geometry in
            let names = LibrarySidebar.showsNames(geometry.size)
            let barWidth: CGFloat = names ? 250 : 64
            HStack(spacing: 0) {
                Group { if names { list(closing: false) } else { rail(tall: geometry.size.height >= 480) } }
                    .frame(width: barWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    // Top to bottom of the screen: no edge where the bar used to end.
                    .background(LibrarySidebar.bar.ignoresSafeArea(edges: [.top, .bottom, .leading]))
                    .overlay(alignment: .trailing) { LibrarySidebar.line.frame(width: 1).ignoresSafeArea(edges: [.top, .bottom]) }
                page(current, max(1, geometry.size.width - barWidth), !names)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // ≡ on the rail: the full list slides out over the page; a tap outside closes it.
            .overlay(alignment: .leading) {
                if drawer && !names {
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.45).ignoresSafeArea()
                            .onTapGesture { withAnimation(animation) { drawer = false } }
                            .accessibilityLabel("Hide store names").accessibilityAddTraits(.isButton)
                        list(closing: true)
                            .frame(width: min(300, geometry.size.width - 56))
                            .frame(maxHeight: .infinity, alignment: .top)
                            .background(LibrarySidebar.bar.ignoresSafeArea(edges: [.top, .bottom, .leading]))
                            .transition(.move(edge: .leading))
                    }
                }
            }
            .onChange(of: names) { _, wide in if wide { drawer = false } }
            .onChange(of: drawer) { _, open in if !open { searchFocused = false } }
            // View on a controller: the search field (in the slid-out list on the rail).
            .onReceive(pad.search) {
                if names { searchFocused = true; return }
                withAnimation(animation) { drawer = true }
                // The field is there on the next turn of the run loop: no wait for a slide.
                DispatchQueue.main.async { searchFocused = true }
            }
        }
        .background(LibrarySidebar.page.ignoresSafeArea())
        .onAppear { LogStore.shared.log("[library-sidebar] shelf=\(current.rawValue)") }
    }

    private func pick(_ shelf: LibraryShelf) {
        shelf.unfold()
        // The highlight and the page change at once, unanimated (Cameron, Wave 9: an animated
        // change waited on the new page and felt laggy); only the slid-out list slides away.
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) { selection = shelf.rawValue }
        if drawer { withAnimation(animation) { drawer = false } }
    }

    /// The list with names: the sidebar sideways on an iPad, and the drawer ≡ opens.
    private func list(closing: Bool) -> some View {
        let note = LibraryShelfNote(ready: readyCount, others: otherCount)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if closing {
                    Button { withAnimation(animation) { drawer = false } } label: {
                        Image(systemName: "line.3.horizontal").font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide store names")
                }
                LibrarySidebarTitle()
            }
            .padding(.leading, closing ? 6 : 14).padding(.top, closing ? 0 : 10)
            searchField
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(LibraryShelf.available) { shelf in
                        if shelf == .other { Spacer(minLength: 10) }
                        Button { pick(shelf) } label: {
                            HStack(spacing: 12) {
                                LibraryShelfBadge(shelf: shelf, size: 28)
                                Text(shelf.title).font(.body.weight(.medium)).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(note.text(shelf)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 10).frame(minHeight: 44)
                            .background(current == shelf ? LibrarySidebar.picked : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .overlay { ring(MenuPad.side(shelf), radius: 10) }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(current == shelf ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 10)
            }
            LibrarySidebar.line.frame(height: 1).padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 2) {
                bottomRow(L("Windows desktop"), "desktopcomputer", pad: MenuPad.desktopRow) { drawer = false; desktop() }
                bottomRow(L("Settings"), "gearshape", pad: MenuPad.settingsRow) { drawer = false; settings() }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }

    /// Search, at the top of the list: it filters the page beside it as you type.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L("Search your library"), text: $search)
                .focused($searchFocused)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                // Over the page (the drawer), Search closes the list to show what was found.
                .onSubmit { withAnimation(animation) { drawer = false } }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 38)
        .background(LibrarySidebar.chip, in: Capsule())
    }

    private func bottomRow(_ title: String, _ symbol: String, pad id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.body.weight(.medium)).frame(width: 28)
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(minHeight: 44)
            .overlay { ring(id, radius: 10) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The controller's ring on a row or icon of the sidebar.
    private func ring(_ id: String, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(LibrarySidebar.blue, lineWidth: 3)
            .opacity(pad.ring && pad.focus == id ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// The icon rail: ≡, the shelves' icons, and (when there is room) Windows desktop and Settings.
    private func rail(tall: Bool) -> some View {
        VStack(spacing: 4) {
            Button { withAnimation(animation) { drawer = true } } label: {
                Image(systemName: "line.3.horizontal").font(.title3.weight(.semibold)).frame(width: 48, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show store names")
            // 🔍: the list slides out with its search field ready to type in.
            Button {
                withAnimation(animation) { drawer = true }
                // The field is there on the next turn of the run loop: no wait for a slide.
                DispatchQueue.main.async { searchFocused = true }
            } label: {
                Image(systemName: "magnifyingglass").font(.title3.weight(.semibold)).frame(width: 48, height: 44)
                    .foregroundStyle(search.isEmpty ? Color.primary : LibrarySidebar.blue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search your library")
            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(LibraryShelf.available) { shelf in
                        Button { pick(shelf) } label: {
                            LibraryShelfBadge(shelf: shelf, size: 30)
                                .frame(width: 48, height: 46)
                                .background(current == shelf ? LibrarySidebar.picked : .clear, in: RoundedRectangle(cornerRadius: 12))
                                .overlay { ring(MenuPad.side(shelf), radius: 12) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(shelf.title)
                        .accessibilityAddTraits(current == shelf ? .isSelected : [])
                    }
                }
                .padding(.top, 4)
            }
            if tall {
                Button(action: desktop) {
                    Image(systemName: "desktopcomputer").font(.body.weight(.medium)).frame(width: 48, height: 44)
                        .overlay { ring(MenuPad.desktopRow, radius: 12) }
                }
                .buttonStyle(.plain).accessibilityLabel("Windows desktop")
                Button(action: settings) {
                    Image(systemName: "gearshape").font(.body.weight(.medium)).frame(width: 48, height: 44)
                        .overlay { ring(MenuPad.settingsRow, radius: 12) }
                }
                .buttonStyle(.plain).accessibilityLabel("Settings")
                .padding(.bottom, 8)
            }
        }
        .padding(.top, 6)
        .foregroundStyle(.primary)
    }
}

/// "Madeira" and its JIT bolt, at the top of the store list.
struct LibrarySidebarTitle: View {
    @ObservedObject private var jitState = LibraryJITState.shared
    var body: some View {
        let jit = jitState.enabled
        HStack(spacing: 8) {
            Text(LibraryHeaderAlignment.title).font(.title.bold()).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Image(systemName: jit ? "bolt.fill" : "bolt")
                .font(.headline)
                .foregroundStyle(jit ? LibrarySidebar.blue : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityLabel(jit ? L("JIT enabled") : L("JIT not enabled"))
        }
        .frame(minHeight: 44)
    }
}

/// The top of the sidebar's page, which hides the navigation bar so the sidebar can run the
/// full height: JIT and Memory+ when the list is folded to icons (iPad upright, iPhone),
/// what is being searched for, and the library menu with + at the right.
struct LibrarySidebarHeader<Options: View>: View {
    @Binding var search: String
    /// The icon rail is showing, so the list's title and search are out of sight.
    let rail: Bool
    @ViewBuilder let options: () -> Options
    let add: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if rail { LibraryStatusChips() }
            if rail && !search.isEmpty {
                // The search field is in the folded list: show what it holds, and clear it here.
                Button { search = "" } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass").accessibilityHidden(true)
                        Text(verbatim: search).lineLimit(1)
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .font(.footnote.weight(.semibold)).padding(.horizontal, 10).frame(height: 28)
                    .background(LibrarySidebar.chip, in: Capsule())
                }
                .buttonStyle(.plain).accessibilityLabel("Clear")
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                options()
                    .labelStyle(.iconOnly).font(.title3).frame(width: 42, height: 42)
                Button(action: add) { Label("Add executable", systemImage: "plus").labelStyle(.iconOnly).font(.title3) }
                    .frame(width: 42, height: 42)
            }
            .padding(.horizontal, 4)
            .background(LibrarySidebar.chip, in: Capsule())
        }
        .padding(.top, 4)
    }
}

/// JIT and Memory+, green when on and grey when off; checked every 2 s, as Settings' status is.
struct LibraryStatusChips: View {
    @State private var jit = false
    @State private var memory = false
    let ticks = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 8) {
            chip("JIT", jit, icon: "bolt.fill")
            chip("Memory+", memory, icon: "circle.fill")
        }
        .onAppear { update() }.onReceive(ticks) { _ in update() }
    }
    private func chip(_ name: String, _ on: Bool, icon: String) -> some View {
        let color = on ? LibrarySidebar.green : Color.secondary
        return HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: icon == "circle.fill" ? 7 : 11, weight: .bold))
            Text(verbatim: name)
        }
        .font(.footnote.weight(.semibold)).foregroundStyle(color)
        .padding(.horizontal, 10).frame(height: 26)
        .background(color.opacity(on ? 0.16 : 0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name)).accessibilityValue(on ? L("On") : L("Off"))
    }
    private func update() { jit = StikJITHelper.ready; memory = EntitlementStatus.check().increasedMemory }
}

/// A shelf's title above its games (Ready to play and Other games; a store's section has its own).
struct LibraryShelfTitle: View {
    let title: String
    let note: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.7)
            if !note.isEmpty { Text(note).font(.subheadline).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Ready to play

/// Every installed game of every store and the games you added, most recently played first.
struct LibraryReadyGame: Identifiable {
    let id: String
    let entry: LibraryEntry
    let store: String

    /// "Steam · Played yesterday", "Epic Games · Not played yet".
    var note: String {
        guard let played = entry.lastPlayed else { return store + " · " + L("Not played yet") }
        let calendar = Calendar.current
        if calendar.isDateInToday(played) { return store + " · " + L("Played today") }
        if calendar.isDateInYesterday(played) { return store + " · " + L("Played yesterday") }
        return store + " · " + played.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The games you added (Other games): listed in the library and from no store.
    @MainActor static func added() -> [LibraryEntry] {
        LibraryModel.shared.entries.filter { entry in
            entry.desktop != true && entry.listedInLibrary && entry.steamAppID == nil && entry.epicAppName == nil
                && entry.gogProductID == nil && entry.itchGameID == nil && entry.eaOfferID == nil
        }
    }

    @MainActor static func all(search: String) -> [LibraryReadyGame] {
        let library = LibraryModel.shared
        var games: [LibraryReadyGame] = []
        // Steam: every game Steam lists as fully installed, not while it updates.
        if MadeiraDock.enabled {
            for game in SteamGamesModel.shared.games where game.installed && SteamOwnedLibrary.shared.downloads[game.id] == nil {
                games.append(.init(id: "steam:\(game.id)", entry: library.steamEntry(game), store: "Steam"))
            }
        }
        if EpicLibrary.enabled {
            for (app, game) in EpicLibrary.shared.installed where EpicLibrary.shared.downloads[app] == nil {
                games.append(.init(id: "epic:" + app, entry: library.epicEntry(game), store: "Epic Games"))
            }
        }
        if GOGLibrary.enabled {
            for (product, game) in GOGLibrary.shared.installed where GOGLibrary.shared.downloads[product] == nil {
                games.append(.init(id: "gog:" + product, entry: library.gogEntry(game), store: "GOG"))
            }
        }
        if ItchLibrary.enabled {
            for (id, game) in ItchLibrary.shared.installed where ItchLibrary.shared.downloads[id] == nil {
                games.append(.init(id: "itch:\(id)", entry: library.itchEntry(game), store: "itch.io"))
            }
        }
        if EALibrary.enabled {
            for (offer, game) in EALibrary.shared.installed where EALibrary.shared.downloads[offer] == nil {
                games.append(.init(id: "ea:" + offer, entry: library.eaEntry(game), store: "EA app"))
            }
        }
        // The games you added.
        for entry in added() {
            games.append(.init(id: "entry:" + entry.id.uuidString, entry: entry, store: L("Other games")))
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        return games
            .filter { query.isEmpty || $0.entry.title.localizedCaseInsensitiveContains(query) }
            .sorted {
                if $0.entry.lastPlayed != $1.entry.lastPlayed { return ($0.entry.lastPlayed ?? .distantPast) > ($1.entry.lastPlayed ?? .distantPast) }
                return $0.entry.title.localizedStandardCompare($1.entry.title) == .orderedAscending
            }
    }
}

/// Ready to play's page: one grid of covers; a cover opens the game's page, where Play is.
struct LibraryReadyGames: View {
    let search: String
    let width: CGFloat
    let open: (LibraryEntry) -> Void
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var steamGames = SteamGamesModel.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var gog = GOGLibrary.shared
    @ObservedObject private var epic = EpicLibrary.shared
    @ObservedObject private var itch = ItchLibrary.shared
    @ObservedObject private var ea = EALibrary.shared

    var body: some View {
        let games = LibraryReadyGame.all(search: search)
        VStack(alignment: .leading, spacing: 18) {
            LibraryShelfTitle(title: L("Ready to play"), note: games.isEmpty ? "" : (games.count == 1 ? L("1 game, from every store") : String(format: L("%@ games, from every store"), String(games.count))))
            if games.isEmpty {
                Text(search.isEmpty
                     ? L("Nothing is installed yet. Pick a store on the left to sign in and install a game.")
                     : L("No installed games match your search."))
                    .foregroundStyle(.secondary)
            } else {
                // Two covers across an iPhone, more as the page widens.
                let inner = max(1, width - 32)
                let columns = max(2, Int((inner + 16) / 176))
                let cover = (inner - CGFloat(columns - 1) * 16) / CGFloat(columns)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cover), spacing: 16, alignment: .top), count: columns),
                          alignment: .leading, spacing: 20) {
                    ForEach(games) { game in
                        Button { open(game.entry) } label: { LibraryReadyCard(game: game) }
                            .libraryCardButtonStyle(grid: true, pad: "ready:\(game.id)")
                    }
                }
            }
        }
    }
}

/// A cover, the game's name and where it is from.
struct LibraryReadyCard: View {
    let game: LibraryReadyGame
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LibraryArtwork(entry: game.entry).aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(game.entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(game.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the game's page")
    }
}
