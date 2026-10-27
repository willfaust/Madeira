// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Julian Scanlan
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import GameController
import SwiftUI
import UIKit

// The iPhone Duo's deck (docs/DUO.md). With the Duo folded like a laptop
// (DeviceFold.swift) and touch controls hidden or a controller connected, the flat
// half shows a copy of the game, which can be turned off, and the few things a
// controller has no button for: the game menu, the keyboard and touch controls.
// Folded, the deck's controls are drawn as keycaps (FoldKeyFace).

struct FoldDeck: View {
    @ObservedObject private var pad = PadStickMouse.shared
    @ObservedObject private var controls = TouchControlsModel.shared
    @AppStorage("madeiraFoldMirror") private var mirror = true

    var body: some View {
        VStack(spacing: 10) {
            if mirror && GameMirror.available {
                GameMirror()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(false)
            } else {
                Spacer(minLength: 0)
                status
                Spacer(minLength: 0)
            }
            buttons
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .foldKeys()
    }

    private var status: some View {
        HStack(spacing: 12) {
            Image(systemName: pad.controllerConnected ? "gamecontroller.fill" : "gamecontroller")
                .font(.system(size: 28))
            VStack(alignment: .leading, spacing: 2) {
                Text(GCController.current?.vendorName ?? (pad.controllerConnected ? "Controller" : "No controller"))
                    .font(.headline)
                Text("Playing on the upper screen").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            button("line.3.horizontal", "Menu") { LibraryModel.shared.showMenu() }
            button("keyboard", "Keyboard") { LibraryKeyboard.show() }
            if !pad.controllerConnected {
                button("hand.tap", "Touch") { controls.visible = true }
            }
            if GameMirror.available {
                button(mirror ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle", "Mirror") { mirror.toggle() }
            }
        }
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(label).font(.caption2)
            }
            .frame(width: 68, height: 46)
            .background(GlassShape())
        }
        .buttonStyle(FoldKeyButtonStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - Keycaps

// Folded like a laptop, the deck lies on the table like a keyboard, so its controls are
// drawn as physical keys rather than glass: a raised cap lit from above, standing on a
// darker skirt it sinks into while pressed. Everything drawn with glassFace inside a
// view marked `.foldKeys()` takes the keycap (ContentView.swift, GlassFace); a control
// says it is held through `foldKeyPressed`. Nothing changes outside the deck.

private struct FoldKeysKey: EnvironmentKey { static let defaultValue = false }
private struct FoldKeyPressedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Glass faces in this view are drawn as keycaps.
    var foldKeys: Bool {
        get { self[FoldKeysKey.self] }
        set { self[FoldKeysKey.self] = newValue }
    }
    /// The keycap is held down.
    var foldKeyPressed: Bool {
        get { self[FoldKeyPressedKey.self] }
        set { self[FoldKeyPressedKey.self] = newValue }
    }
}

extension View {
    /// Draws this view's glass faces as keycaps while `on`.
    func foldKeys(_ on: Bool = true) -> some View { environment(\.foldKeys, on) }
}

/// A keycap in `shape`: the skirt, the cap with its top-lit gradient and edge, and a
/// tint for coloured buttons (A/B/X/Y). Pressed, the cap sinks onto the skirt and its
/// shadow tightens.
struct FoldKeyFace: View {
    let shape: AnyShape
    var tint: Color?
    var pressed = false

    var body: some View {
        let travel: CGFloat = pressed ? 1 : 3.5
        ZStack {
            shape.fill(Color(white: 0.05))
                .offset(y: travel)
            ZStack {
                shape.fill(LinearGradient(colors: pressed ? [Color(white: 0.17), Color(white: 0.23)]
                                                          : [Color(white: 0.32), Color(white: 0.16)],
                                          startPoint: .top, endPoint: .bottom))
                if let tint { shape.fill(tint.opacity(pressed ? 0.45 : 0.6)) }
                shape.fill(LinearGradient(colors: [.white.opacity(pressed ? 0.04 : 0.16), .clear],
                                          startPoint: .top, endPoint: .center))
                shape.stroke(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.06)],
                                            startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .offset(y: pressed ? travel - 1 : 0)
        }
        .shadow(color: .black.opacity(0.6), radius: pressed ? 1 : 4, y: pressed ? 1 : 4)
    }
}

/// A Button whose label's keycap sinks while it is held.
struct FoldKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.foldKeyPressed, configuration.isPressed)
    }
}

/// The small key at the top of the deck that shows or hides the copy of the game under
/// the touch controls (the same setting as FoldDeck's Mirror button).
struct FoldMirrorKey: View {
    @Binding var on: Bool

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            on.toggle()
        } label: {
            Image(systemName: on ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 28)
                .background(GlassShape(cornerRadius: 9))
        }
        .buttonStyle(FoldKeyButtonStyle())
        .accessibilityLabel(on ? "Hide the game on this screen" : "Show the game on this screen")
    }
}

/// A live copy of the game. The game's Metal layer can have only one parent, and it
/// must stay a window-level view for its presents to reach the screen
/// (MetalHostView), so the copy is a portal: UIKit's _UIPortalView draws the same
/// layer a second time, scaled to fit here, without touching the game. Without
/// that class the deck shows the controller's status instead.
struct GameMirror: UIViewRepresentable {
    private static let portalClass = NSClassFromString("_UIPortalView") as? UIView.Type
    static var available: Bool {
        portalClass?.instancesRespond(to: NSSelectorFromString("setSourceView:")) == true
    }

    final class Mirror: UIView {
        private var portal: UIView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .black
            clipsToBounds = true
            guard GameMirror.available, let portalClass = GameMirror.portalClass else { return }
            let portal = portalClass.init(frame: .zero)
            portal.setValue(MetalHostView.shared, forKey: "sourceView")
            for (key, value) in ["hidesSourceView": false, "matchesPosition": false,
                                 "matchesTransform": false, "matchesAlpha": false, "allowsHitTesting": false]
            where portal.responds(to: NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):")) {
                portal.setValue(value, forKey: key)
            }
            portal.isUserInteractionEnabled = false
            addSubview(portal)
            self.portal = portal
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let portal else { return }
            // The game's own size, fitted into the deck at its aspect ratio.
            let source = MetalHostView.shared.bounds.size
            guard source.width > 1, source.height > 1, bounds.width > 1, bounds.height > 1 else { return }
            let scale = min(bounds.width / source.width, bounds.height / source.height)
            portal.transform = .identity
            portal.bounds = CGRect(origin: .zero, size: source)
            portal.transform = CGAffineTransform(scaleX: scale, y: scale)
            portal.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    func makeUIView(context: Context) -> Mirror { Mirror(frame: .zero) }
    func updateUIView(_ view: Mirror, context: Context) { view.setNeedsLayout() }
}
