// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit
import Combine
import GameController

// Controller plumbing the new look's pad highlight (PadHighlight.swift) relies on: the window's
// claim on controller events, so iOS 18's own focus does not also walk and press a page's buttons,
// and the Form that takes no system focus while a controller is connected. The pad is player 1's,
// read by GamepadInput and turned into commands by LibraryController, so it only reaches the menus
// while no game runs.

@MainActor final class MenuPad: ObservableObject {
    static let shared = MenuPad()
    /// Sheets open over the library (a store game's sheet): the library leaves the pad to them.
    var sheets = 0

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
        LogStore.shared.log("[menu-pad] system focus held off the rows while the highlight shows")
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
    /// Advanced). So this view also holds the system focus itself while the highlight shows: it is
    /// focusable, draws nothing, takes the focus whenever it lands elsewhere in its window,
    /// and does not let a direction move it away. Touch lets the focus go.
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
            let shown = PadHighlight.enabled && PadHighlight.shared.shown
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

extension View {
    /// A controller-reachable item (MenuPad): `id` is unique on the page.
    @ViewBuilder func menuPad(_ id: String, cornerRadius: CGFloat = 14, action: @escaping () -> Void) -> some View {
        if PadHighlight.enabled { padItem(id, cornerRadius: cornerRadius, press: action) } else { self }
    }

    /// A Form the system's focus must not walk while a controller is connected
    /// (MenuPadNoSystemFocus): Game details and its pages.
    @ViewBuilder func menuPadNoSystemFocus() -> some View {
        if PadHighlight.enabled, GamepadInput.enabled, !GCController.controllers().isEmpty {
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
            // B closes the sheet, A runs its Install or Open.
            .padLayer("sheet", back: { dismiss() }, accept: accept)
            .onAppear { MenuPad.shared.sheets += 1 }
            .onDisappear { MenuPad.shared.sheets = max(0, MenuPad.shared.sheets - 1) }
    }
}

/// A store's game card for the new highlight: A presses it, as a tap does.
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
