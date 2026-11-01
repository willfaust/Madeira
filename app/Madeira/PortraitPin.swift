// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Julian Scanlan
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import GameController
import UIKit

// Portrait with a controller (docs/DUO.md, "Portrait with a controller"). Held
// upright, a library session fits the game into a band across the middle of the
// tall window, with empty space above and below. A swipe up or down in that space
// moves the game to the top or the bottom of the screen, and back to the middle,
// so it can sit where the eyes are while the hands hold the controller. The choice
// is kept (`madeiraPortraitPin`). Without a controller but with touch controls, the
// game goes to the top and the controls take the space below it (PortraitDeck). In
// landscape, folded (DeviceFold.swift) or where the game fills the height, nothing
// changes, and touches in the empty space reach the game as before. Log tag:
// [portrait-pin].

@MainActor
enum PortraitPin: String {
    case middle, top, bottom

    private static let key = "madeiraPortraitPin"

    static var current: PortraitPin {
        get { UserDefaults.standard.string(forKey: key).flatMap(PortraitPin.init(rawValue:)) ?? .middle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// The display refresh a swipe asks for; MetalBackedView animates the move.
    static let reason = "portrait-pin"

    /// A pin can apply: a library session in a portrait view, with a controller.
    static func applies(in bounds: CGRect) -> Bool {
        bounds.height > bounds.width && LibraryModel.shared.current != nil
            && PadStickMouse.shared.controllerConnected
    }

    /// `bounds`, narrowed to the band the game takes at the pinned edge (inside
    /// `insets`, the safe area). `game` is the game's rect centred in `bounds`
    /// (GameSurfaceLayout.rect); laid out in the band, it moves there at the
    /// same size.
    static func bounds(_ bounds: CGRect, game: CGRect, insets: UIEdgeInsets) -> CGRect {
        // Touch controls take the space below the game (PortraitDeck), when it is usable.
        let below = CGSize(width: bounds.width, height: bounds.maxY - (bounds.minY + insets.top + game.height))
        let deck = PortraitDeck.applies(in: bounds) && PortraitDeck.usable(below)
        let pin: PortraitPin = deck ? .top : current
        guard pin != .middle, deck || applies(in: bounds), game.height < bounds.height - 1 else { return bounds }
        let y = pin == .top
            ? min(bounds.minY + insets.top, bounds.maxY - game.height)
            : max(bounds.maxY - insets.bottom - game.height, bounds.minY)
        return CGRect(x: bounds.minX, y: y, width: bounds.width, height: game.height)
    }

    /// One step towards the top (`up`) or the bottom.
    static func step(up: Bool) {
        let next: PortraitPin
        switch (current, up) {
        case (.bottom, true), (.top, false): next = .middle
        case (_, true): next = .top
        case (_, false): next = .bottom
        }
        guard next != current else { return }
        current = next
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        LogStore.shared.log("[portrait-pin] \(next.rawValue)")
        MetalBackedView.refreshDisplayMode(reason: reason)
    }

    /// Connecting or disconnecting a controller moves the game (applies(in:)).
    static func observeControllers() { _ = observers }
    private static let observers: [NSObjectProtocol] = [Notification.Name.GCControllerDidConnect,
                                                       .GCControllerDidDisconnect].map { name in
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MetalBackedView.refreshDisplayMode(reason: "controller")
        }
    }
}

/// Portrait with touch controls (docs/DUO.md). Held upright without a controller, a
/// library session's touch controls lay over the game, their landscape layout
/// squeezed into the narrow window until they ran into each other. Instead the game
/// moves to the top, as pinned there, and the space below it becomes a deck like the
/// folded Duo's: the controls, the menu button and the game's glow are drawn there
/// (TouchControlsOverlay, sessionBody) and the controls window takes every touch in
/// it. Log tag: [portrait-deck].
@MainActor
final class PortraitDeck: ObservableObject {
    static let shared = PortraitDeck()

    /// The space below the game, in window coordinates; nil when this does not apply
    /// or that space is not usable.
    @Published private(set) var rect: CGRect?

    /// It can apply: a library session in a portrait view on an iPhone, not folded,
    /// with touch controls on screen and no controller.
    static func applies(in bounds: CGRect) -> Bool {
        let controls = TouchControlsModel.shared
        return UIDevice.current.userInterfaceIdiom == .phone
            && bounds.height > bounds.width && LibraryModel.shared.current != nil
            && DeviceFold.shared.layout == nil && !PadStickMouse.shared.controllerConnected
            && controls.visible && !controls.controls.isEmpty
    }

    /// The space below the game can hold the controls: 160 points or more, and wider
    /// than tall. The controls' landscape layout does not survive a taller space: on an
    /// ordinary iPhone upright it was squeezed sideways, so there they stay over the game
    /// as before. The Duo open flat leaves a space wider than tall.
    static func usable(_ below: CGSize) -> Bool {
        below.height >= 160 && below.height <= below.width
    }

    /// MetalBackedView has laid the game out at `game` in a window of `window`.
    func update(game: CGRect, in window: CGRect, applies: Bool) {
        let below = CGRect(x: window.minX, y: game.maxY.rounded(), width: window.width,
                           height: window.maxY - game.maxY.rounded())
        let new = applies && Self.usable(below.size) ? below : nil
        guard new != rect else { return }
        rect = new
        LogStore.shared.log("[portrait-deck] \(new.map { "deck=\($0)" } ?? "off")")
    }
}

/// Swipes in the empty space above or below the game (PortraitPin). A touch that
/// starts there while a pin can apply belongs to the swipe and never reaches the
/// game; MetalBackedView hands each touch event here first.
@MainActor
final class PortraitPinSwipe {
    private var starts: [ObjectIdentifier: CGPoint] = [:]

    /// True when every touch in `touches` belongs to a swipe, so the view ignores them.
    func intercept(_ touches: Set<UITouch>, _ phase: UITouch.Phase, in view: UIView, game: CGRect) -> Bool {
        var mine = 0
        for touch in touches {
            let id = ObjectIdentifier(touch), p = touch.location(in: view)
            switch phase {
            case .began:
                guard PortraitPin.applies(in: view.bounds), !game.contains(p) else { continue }
                starts[id] = p
            case .ended:
                guard let start = starts.removeValue(forKey: id) else { continue }
                let dx = p.x - start.x, dy = p.y - start.y
                if abs(dy) > 40, abs(dy) > abs(dx) * 1.5 { PortraitPin.step(up: dy < 0) }
            case .cancelled:
                guard starts.removeValue(forKey: id) != nil else { continue }
            default:
                guard starts[id] != nil else { continue }
            }
            mine += 1
        }
        return mine > 0 && mine == touches.count
    }
}
