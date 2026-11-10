// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit
import Combine
import GameController

// A controller in Madeira's own menus with New look off (Settings › Appearance): the blue ring
// on the store pages, their game sheets and Game details. The pad is player 1's, read by GamepadInput and
// turned into commands by LibraryController, so it only reaches the menus while no game runs.
// Wave 8's store sidebar, which this ring was first made for, is gone (Cameron, Nov 9); with New
// look on, PadHighlight.swift does all of this and MenuPad.enabled is false.
// The first press only shows the ring (where it was); touching the screen hides it.
// env.MADEIRA_MENU_CONTROLLER = 0 turns this off.

@MainActor final class MenuPad: ObservableObject {
    static let shared = MenuPad()
    /// (new-look) Only with New look off: the new look has its own highlight (PadHighlight.swift).
    static var enabled: Bool { !NewLook.enabled && MadeiraConfig.flag("MADEIRA_MENU_CONTROLLER") }

    /// The ring is showing (the controller was used since the last touch).
    @Published private(set) var ring = false
    /// What the ring is on: a cover or button of the page, or a sidebar row ("side:…").
    @Published var focus: String?
    /// A ringed item that A pressed: the item runs its own action (MenuPadFocusable).
    let press = PassthroughSubject<String, Never>()
    /// View on the controller: the sidebar's search field.
    let search = PassthroughSubject<Void, Never>()
    /// Sheets open over the library (a store game's sheet): the library leaves the pad to them.
    var sheets = 0
    /// A game page or sheet just closed with B: the library ignores presses until then, so the
    /// same B does not also move the ring.
    var quietUntil = Date.distantPast
    /// Where each ringed item is on the page, in the page's own space (not published:
    /// the frames change with every layout, and only a press reads them).
    var frames: [String: CGRect] = [:]
    /// The ring's place on each store's page, for coming back to it.
    var remembered: [String: String] = [:]
    private var watching = false


    /// Shows the ring; true when it was hidden, so this press only brings it back.
    @discardableResult func show() -> Bool {
        installTouchWatch()
        guard !ring else { return false }
        withAnimation(Self.animation) { ring = true }
        return true
    }
    func hide() {
        guard ring else { return }
        withAnimation(Self.animation) { ring = false }
    }
    func move(to id: String?) {
        guard id != focus else { return }
        withAnimation(Self.animation) { focus = id }
    }
    /// Short, so the ring keeps up with a held stick (Cameron, Wave 9: the highlight felt slow).
    static var animation: Animation? { UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.08) }

    /// The nearest item from `from` in a direction ("up", "down", "left", "right"), or `jump`
    /// points away (L2/R2): the item closest to that point below or above.
    static func nearest(from: CGRect, direction: String, in frames: [String: CGRect], jump: CGFloat? = nil) -> String? {
        let x = from.midX, y = from.midY
        var best: (String, CGFloat)?
        for (id, frame) in frames {
            let dx = frame.midX - x, dy = frame.midY - y
            let score: CGFloat
            if let jump {
                guard direction == "down" ? dy > 1 : dy < -1 else { continue }
                score = abs(abs(dy) - jump) + abs(dx) * 0.5
            } else {
                switch direction {
                case "down": guard dy > 1, frame.minY >= from.midY else { continue }; score = dy + abs(dx) * 2
                case "up": guard dy < -1, frame.maxY <= from.midY else { continue }; score = -dy + abs(dx) * 2
                case "right": guard dx > 1, frame.minX >= from.midX, abs(dy) < max(from.height, frame.height) else { continue }; score = dx + abs(dy) * 3
                case "left": guard dx < -1, frame.maxX <= from.midX, abs(dy) < max(from.height, frame.height) else { continue }; score = -dx + abs(dy) * 3
                default: continue
                }
            }
            if best == nil || score < best!.1 { best = (id, score) }
        }
        return best?.0
    }

    /// Touching the screen hides the ring: a recognizer on the window that never takes a touch.
    private func installTouchWatch() {
        guard !watching else { return }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        guard let window else { return }
        watching = true
        window.addGestureRecognizer(MenuPadTouchWatch { MenuPad.shared.hide() })
        claimControllerEvents()
    }

    /// iOS 18 routes a controller into UIKit's own focus as well: on a page or sheet without a
    /// claim, the D-pad walked its buttons and A pressed them, besides Madeira's own commands
    /// (Cameron, Wave 9). Claimed on the window, every page and sheet in it is covered; Madeira
    /// reads the pad itself (GamepadInput), so nothing is lost.
    func claimControllerEvents() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: { $0.isKeyWindow }) else { return }
        GamepadEventClaim.install(on: window)
        if !claimLogged { claimLogged = true; LogStore.shared.log("[menu-pad] controller events claimed on the window") }
        watchSystemFocus()
    }
    private var claimLogged = false

    /// The log names where the system's own focus goes while the ring shows (the first 30
    /// moves), so a page that still walks by itself can be traced.
    private func watchSystemFocus() {
        guard !focusWatched else { return }
        focusWatched = true
        NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { note in
            let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            let next = context?.nextFocusedItem.map { String(describing: type(of: $0)) } ?? "nothing"
            MainActor.assumeIsolated {
                guard MenuPad.shared.focusMoves < 30 else { return }
                MenuPad.shared.focusMoves += 1
                LogStore.shared.log("[menu-pad] system focus moved to \(next)")
            }
        }
    }
    private var focusWatched = false
    private var focusMoves = 0
    /// A list that no longer takes the system's focus (MenuPadNoSystemFocus), logged once.
    func noFocusApplied(_ count: Int) {
        guard !noFocusLogged else { return }
        noFocusLogged = true
        LogStore.shared.log("[menu-pad] game details list takes no system focus (\(count))")
    }
    private var noFocusLogged = false
    /// The system focus was taken off a row and held (MenuPadNoSystemFocus.Probe), logged once.
    func focusHeld() {
        guard !heldLogged else { return }
        heldLogged = true
        LogStore.shared.log("[menu-pad] system focus held off the rows while the ring shows")
    }
    private var heldLogged = false
}

/// iPadOS walks a Form with the controller through its own focus: one A on a cover opened Game
/// details, then Controls and Gyro aim & turbo opened by themselves and the walk ended at the
/// bottom (Cameron, Wave 10, after the window's claim). While a controller is connected the
/// Form's list takes no system focus; touch, and Madeira's own commands, work as before.
struct MenuPadNoSystemFocus: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {}

    /// Wave 12 (Cameron's log): the list's cells took the system focus even with allowsFocus
    /// off, and its blue fill walked under Madeira's ring (Uninstall lit while the ring was on
    /// Advanced). So this view also holds the system focus itself while the ring shows: it is
    /// focusable, draws nothing, takes the focus whenever it lands elsewhere in its window,
    /// and does not let a direction move it away. Touch hides the ring and lets focus go.
    final class Probe: UIView {
        private var watch: NSObjectProtocol?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            focusEffect = nil
        }
        required init?(coder: NSCoder) { nil }
        deinit { if let watch { NotificationCenter.default.removeObserver(watch) } }
        private var holding: Bool {
            let shown = (MenuPad.enabled && MenuPad.shared.ring) || (PadHighlight.enabled && PadHighlight.shared.shown)
            return shown && window != nil && !GCController.controllers().isEmpty
        }
        override var canBecomeFocused: Bool { holding }
        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            if context.previouslyFocusedItem === self, holding { return false }
            return super.shouldUpdateFocus(in: context)
        }
        private func hold() {
            guard holding, let system = UIFocusSystem.focusSystem(for: self), system.focusedItem !== self else { return }
            system.requestFocusUpdate(to: self)
            system.updateFocusIfNeeded()
            MenuPad.shared.focusHeld()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let watch { NotificationCenter.default.removeObserver(watch); self.watch = nil }
            guard window != nil else { return }
            watch = NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hold() }
            }
            // The list is in the hierarchy once the Form's first layout ran.
            DispatchQueue.main.async { [weak self] in self?.apply(); self?.hold() }
        }
        private func apply() {
            // Inside a row: the list is an ancestor.
            var up = superview
            while let view = up {
                if let list = view as? UICollectionView {
                    list.allowsFocus = false; list.selectionFollowsFocus = false
                    MenuPad.shared.noFocusApplied(1)
                    return
                }
                up = view.superview
            }
            var ancestor = superview
            for _ in 0..<8 {
                guard let view = ancestor else { return }
                let found = Self.lists(in: view, depth: 5)
                if !found.isEmpty {
                    for list in found { list.allowsFocus = false; list.selectionFollowsFocus = false }
                    MenuPad.shared.noFocusApplied(found.count)
                    return
                }
                ancestor = view.superview
            }
        }
        static func lists(in view: UIView, depth: Int) -> [UICollectionView] {
            if let list = view as? UICollectionView { return [list] }
            guard depth > 0 else { return [] }
            return view.subviews.flatMap { lists(in: $0, depth: depth - 1) }
        }
    }
}

/// Sees every touch on the window and fails at once, so taps, scrolls and buttons are untouched.
final class MenuPadTouchWatch: UIGestureRecognizer {
    private let touched: @MainActor () -> Void
    init(_ touched: @escaping @MainActor () -> Void) {
        self.touched = touched
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        touched()
        state = .failed
    }
}

/// The page's coordinate space, for the ringed items' frames.
enum MenuPadSpace { static let name = "menuPadPage" }

struct MenuPadFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Makes a cover or button reachable with the controller: the blue ring and a slight lift when
/// it is ringed, its frame for moving between items, and A running `action`.
struct MenuPadFocusable: ViewModifier {
    let id: String
    var cornerRadius: CGFloat = 14
    let action: () -> Void
    @ObservedObject private var pad = MenuPad.shared
    func body(content: Content) -> some View {
        let on = pad.ring && pad.focus == id
        content
            .scaleEffect(on ? 1.04 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(MenuPadColor.blue, lineWidth: 4)
                    .padding(-5)
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .zIndex(on ? 1 : 0)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: MenuPadFrames.self, value: [id: geometry.frame(in: .named(MenuPadSpace.name))])
            })
            .id(id)
            .onReceive(pad.press) { pressed in if pressed == id { action() } }
    }
}

extension View {
    /// A controller-reachable item (MenuPad): `id` is unique on the page.
    @ViewBuilder func menuPad(_ id: String, cornerRadius: CGFloat = 14, action: @escaping () -> Void) -> some View {
        if MenuPad.enabled { modifier(MenuPadFocusable(id: id, cornerRadius: cornerRadius, action: action)) }
        // (new-look) The same item for the new highlight (a store's sign-in card).
        else if PadHighlight.enabled { padItem(id, cornerRadius: cornerRadius, press: action) }
        else { self }
    }

    /// A Form the system's focus must not walk while a controller is connected
    /// (MenuPadNoSystemFocus): Game details and its pages.
    @ViewBuilder func menuPadNoSystemFocus() -> some View {
        if MenuPad.enabled || PadHighlight.enabled, GamepadInput.enabled, !GCController.controllers().isEmpty {
            background(MenuPadNoSystemFocus().frame(width: 1, height: 1).allowsHitTesting(false))
        } else { self }
    }

    /// A sheet over the library (a store game's sheet): while it is up the library leaves the
    /// pad alone; B closes it and A runs `accept` (its Install or Open), when it has one.
    func menuPadSheet(accept: (() -> Void)? = nil) -> some View { modifier(MenuPadSheet(accept: accept)) }
}

struct MenuPadSheet: ViewModifier {
    let accept: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content
            .modifier(ClaimGamepadEvents())
            // (new-look) The new highlight: B closes the sheet, A runs its Install or Open.
            .padLayer("sheet", back: { dismiss() }, accept: accept)
            .onAppear { MenuPad.shared.sheets += 1 }
            .onDisappear {
                MenuPad.shared.sheets = max(0, MenuPad.shared.sheets - 1)
                MenuPad.shared.quietUntil = Date().addingTimeInterval(0.3)
            }
            .onReceive(LibraryController.shared.commands) { command in
                guard MenuPad.enabled else { return }
                if command == "back" { dismiss() }
                else if command == "accept", let accept { accept() }
            }
    }
}

/// (new-look) A store's game card for the new highlight: A presses it, as a tap does.
struct PadCardStyle: PrimitiveButtonStyle {
    let id: String
    let grid: Bool
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if grid { Button(action: configuration.trigger) { configuration.label }.buttonStyle(LibraryCardButtonStyle()) }
            else { Button(action: configuration.trigger) { configuration.label }.buttonStyle(.plain) }
        }
        .padItem(id, cornerRadius: grid ? 16 : 12, press: configuration.trigger)
    }
}

/// A library card's button style that a controller's A can press: the card's own style
/// (LibraryCardButtonStyle or plain) inside, with the ring around it.
struct MenuPadCardStyle: PrimitiveButtonStyle {
    let id: String
    let grid: Bool
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if grid { Button(action: configuration.trigger) { configuration.label }.buttonStyle(LibraryCardButtonStyle()) }
            else { Button(action: configuration.trigger) { configuration.label }.buttonStyle(.plain) }
        }
        .modifier(MenuPadFocusable(id: id, cornerRadius: grid ? 16 : 12, action: configuration.trigger))
    }
}

/// The old ring's colours (Wave 8's design D), kept for Game details and Settings with New look off.
enum MenuPadColor {
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
}
