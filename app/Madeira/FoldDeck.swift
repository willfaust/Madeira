// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Julian Scanlan
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import GameController
import Network
import SwiftUI
import UIKit

// The iPhone Duo's deck (docs/DUO.md). With the Duo folded like a laptop
// (DeviceFold.swift) and touch controls hidden or a controller connected, the flat
// half shows the few things a controller has no button for: going home, the
// keyboard and touch controls (the menu button of LibraryHUD, on the deck as well,
// opens the game menu), over the game's blurred glow (FoldDeckBackground), which
// can be turned off. Home asks on the deck itself before quitting: a system alert
// would sit across the fold. Folded, the deck's controls are drawn as keycaps
// (FoldKeyFace), and the status bar's time, network and battery sit at its top
// (DeckStatusBar) in place of the system's, over the game.

struct FoldDeck: View {
    @ObservedObject private var pad = PadStickMouse.shared
    @ObservedObject private var controls = TouchControlsModel.shared
    @AppStorage(FoldDeckBackground.glowKey) private var mirror = true
    /// Home was pressed: the deck asks before quitting the game.
    @State private var confirmingHome = false

    var body: some View {
        VStack(spacing: 10) {
            DeckStatusBar()
            Spacer(minLength: 0)
            Group { if confirmingHome { homeQuestion } else { status } }
                .padding(16)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
            Spacer(minLength: 0)
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

    private var homeQuestion: some View {
        VStack(spacing: 4) {
            Text("Quit \(LibraryModel.shared.activeEntry?.title ?? "the game") and go back to the library?")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Unsaved progress will be lost.").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if confirmingHome {
                button("play.fill", "Keep playing", width: 132) { confirmingHome = false }
                button("house.fill", "Quit game", width: 132, tint: .red) {
                    confirmingHome = false
                    LibraryModel.shared.requestQuit()
                }
            } else {
                button("house", "Home") { confirmingHome = true }
                button("keyboard", "Keyboard") { LibraryKeyboard.show() }
                if !pad.controllerConnected {
                    button("hand.tap", "Touch") { controls.visible = true }
                }
                if GameMirror.available {
                    button(mirror ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle", "Mirror") { mirror.toggle() }
                }
            }
        }
    }

    private func button(_ symbol: String, _ label: String, width: CGFloat = 68, tint: Color? = nil,
                        _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(label).font(.caption2)
            }
            .foregroundStyle(tint ?? .white)
            .frame(width: width, height: 46)
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

/// The status bar's time, network and battery, at the top of the deck while folded. The
/// system's own sits across the top of the game, and is hidden then (TouchControlsHost).
/// Wi-Fi strength has no public API, so the Wi-Fi mark is always full.
struct DeckStatusBar: View {
    private static let monitor: NWPathMonitor = {
        let m = NWPathMonitor()
        m.start(queue: DispatchQueue(label: "madeira.deck-status.path"))
        return m
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let battery = Self.battery()
            HStack(spacing: 5) {
                Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .monospacedDigit()
                Image(systemName: Self.networkSymbol())
                Image(systemName: battery.symbol).foregroundStyle(battery.tint)
                if let percent = battery.percent { Text("\(percent)%").monospacedDigit() }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .shadow(color: .black.opacity(0.5), radius: 2)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private static func networkSymbol() -> String {
        let path = monitor.currentPath
        guard path.status == .satisfied else { return "wifi.slash" }
        // A VPN (LocalDevVPN, for JIT) is the path's first interface while it runs; Wi-Fi is under it.
        if path.usesInterfaceType(.wifi) || path.availableInterfaces.contains(where: { $0.type == .wifi }) { return "wifi" }
        return path.usesInterfaceType(.cellular) ? "cellularbars" : "network"
    }

    private static func battery() -> (symbol: String, percent: Int?, tint: Color) {
        let device = UIDevice.current
        // The performance overlay switches monitoring off when it closes (LibraryHUD).
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let charging = device.batteryState == .charging || device.batteryState == .full
        guard device.batteryLevel >= 0 else { return ("battery.100percent", nil, .white) }
        let percent = Int((device.batteryLevel * 100).rounded())
        let symbol = charging ? "battery.100percent.bolt"
            : percent > 87 ? "battery.100percent" : percent > 62 ? "battery.75percent"
            : percent > 37 ? "battery.50percent" : percent > 12 ? "battery.25percent" : "battery.0percent"
        let tint: Color = ProcessInfo.processInfo.isLowPowerModeEnabled ? .yellow
            : percent <= 20 && !charging ? .red : .white
        return (symbol, percent, tint)
    }
}

/// The small key at the top of the deck that turns the game's glow under the touch
/// controls off and on (the same setting as FoldDeck's Mirror button).
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
/// layer a second time, scaled to fit here (or with `fill`, to cover it, cropped),
/// without touching the game. Without that class the deck is plain black.
struct GameMirror: UIViewRepresentable {
    var fill = false

    private static let portalClass = NSClassFromString("_UIPortalView") as? UIView.Type
    static var available: Bool {
        portalClass?.instancesRespond(to: NSSelectorFromString("setSourceView:")) == true
    }

    final class Mirror: UIView {
        private var portal: UIView?
        private weak var source: UIView?
        private var sourceRect = CGRect.zero   // the part of `source` the game takes
        private var timer: Timer?
        var fill = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .black
            clipsToBounds = true
            guard GameMirror.available, let portalClass = GameMirror.portalClass else { return }
            let portal = portalClass.init(frame: .zero)
            for (key, value) in ["hidesSourceView": false, "matchesPosition": false,
                                 "matchesTransform": false, "matchesAlpha": false, "allowsHitTesting": false]
            where portal.responds(to: NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):")) {
                portal.setValue(value, forKey: key)
            }
            portal.isUserInteractionEnabled = false
            addSubview(portal)
            self.portal = portal
            _ = pickSource()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// The game is drawn by MetalHostView, or in a Madeira Dock (desktop) session by
        /// Winios's compositor view beside it: copying MetalHostView there showed black.
        /// The portal copies whichever is drawing, cropped to the part the game takes.
        /// Returns true when that changed.
        private func pickSource() -> Bool {
            var x = 0.0, y = 0.0, w = 0.0, h = 0.0
            let view: UIView, rect: CGRect
            if let ref = winios_compositor_mirror_source(&x, &y, &w, &h) {
                view = Unmanaged<UIView>.fromOpaque(UnsafeRawPointer(ref)).takeUnretainedValue()
                rect = CGRect(x: x, y: y, width: w, height: h)
            } else {
                view = MetalHostView.shared
                rect = view.bounds
            }
            guard view !== source || rect != sourceRect else { return false }
            if view !== source { portal?.setValue(view, forKey: "sourceView") }
            source = view
            sourceRect = rect
            LogStore.shared.log("[fold] mirror source=\(type(of: view)) game=\(Int(rect.width))x\(Int(rect.height)) at \(Int(rect.minX)),\(Int(rect.minY))")
            return true
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            timer?.invalidate(); timer = nil
            guard window != nil, portal != nil else { return }
            // A session's compositor comes and goes after this view exists.
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.pickSource() else { return }
                    self.setNeedsLayout()
                }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            _ = pickSource()
            guard let portal, let source else { return }
            // The game's part of the source, fitted into this view (or covering it) at
            // its aspect ratio, its centre on this view's centre.
            let full = source.bounds.size
            let crop = sourceRect.width > 1 && sourceRect.height > 1 ? sourceRect : CGRect(origin: .zero, size: full)
            guard full.width > 1, full.height > 1, bounds.width > 1, bounds.height > 1 else { return }
            let sx = bounds.width / crop.width, sy = bounds.height / crop.height
            let scale = fill ? max(sx, sy) : min(sx, sy)
            portal.transform = .identity
            portal.bounds = CGRect(origin: .zero, size: full)
            portal.transform = CGAffineTransform(scaleX: scale, y: scale)
            portal.center = CGPoint(x: bounds.midX + (full.width / 2 - crop.midX) * scale,
                                    y: bounds.midY + (full.height / 2 - crop.midY) * scale)
        }
    }

    func makeUIView(context: Context) -> Mirror { Mirror(frame: .zero) }
    func updateUIView(_ view: Mirror, context: Context) {
        view.fill = fill
        view.setNeedsLayout()
    }
}
