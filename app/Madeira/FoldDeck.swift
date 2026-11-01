// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Julian Scanlan
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Combine
import GameController
import Network
import SwiftUI
import UIKit

// The iPhone Duo's deck (docs/DUO.md). With the Duo folded like a laptop
// (DeviceFold.swift) and touch controls hidden or a controller connected, the flat
// half is laid out as Netflix lays out its Duo player: over the game's blurred glow
// (FoldDeckBackground), a row with Home, the game now playing and the glow's key;
// three large keys, Keyboard, the session menu and Touch controls (Aspect with a
// controller); and a row of small ones for the settings changed most in play. Home
// asks on the deck itself before quitting: a system alert would sit across the fold.
// The deck's controls are drawn as keycaps (FoldKeyFace), and the status bar's time,
// network and battery sit at its top (DeckStatusBar) in place of the system's, over
// the game. The deck's Menu key stands in for the floating menu button (FoldDeckState).

/// FoldDeck is on screen: LibraryHUD leaves out its floating menu button, which the
/// deck's own Menu key replaces and which would sit on the deck's Home key.
final class FoldDeckState: ObservableObject {
    static let shared = FoldDeckState()
    @Published var shown = false
}

struct FoldDeck: View {
    @ObservedObject private var pad = PadStickMouse.shared
    @ObservedObject private var controls = TouchControlsModel.shared
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var dockStart = DockStartScreen.shared
    @AppStorage(FoldDeckBackground.glowKey) private var mirror = true
    /// Home was pressed: the deck asks before quitting the game.
    @State private var confirmingHome = false
    @State private var eco = madeira_get_eco() != 0
    /// The in-game menu's Aspect & scaling picker is shown (MADEIRA_SESSION_TOOLS).
    private let sessionTools = MadeiraConfig.flag("MADEIRA_SESSION_TOOLS")
    /// Eco can change under the deck (the in-game menu, the power governor).
    private let ticks = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                DeckStatusBar()
                // The performance overlay, here rather than floating over the keys.
                if library.performance { LibraryMetrics().allowsHitTesting(false) }
            }
            HStack(spacing: 10) {
                key("house", "Home", style: .square) { confirmingHome = true }
                nowPlaying
                if GameMirror.available && !reduceTransparency {
                    key(mirror ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack", "Glow",
                        style: .square, on: mirror) { mirror.toggle() }
                }
            }
            .frame(height: 56)
            GeometryReader { geo in
                // Netflix's proportions: the middle key is the widest.
                let side = (geo.size.width - 20) * 0.29
                HStack(spacing: 10) {
                    if confirmingHome {
                        key("play.fill", "Keep playing", style: .large) { confirmingHome = false }
                            .frame(width: side)
                        homeQuestion.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
                        key("house.fill", "Quit game", style: .large, tint: .red) {
                            confirmingHome = false
                            library.requestQuit()
                        }
                        .frame(width: side)
                    } else {
                        key("keyboard", "Keyboard", style: .large) { LibraryKeyboard.show() }
                            .frame(width: side)
                        key("line.3.horizontal", "Menu", style: .large) { library.showMenu() }
                        Group {
                            switch thirdKey {
                            case .touch: key("hand.tap", "Touch controls", style: .large) { controls.visible = true }
                            case .aspect: aspectKey(style: .large)
                            case .performance: performanceKey(style: .large)
                            }
                        }
                        .frame(width: side)
                    }
                }
            }
            HStack(spacing: 10) {
                if thirdKey != .aspect && sessionTools { aspectKey(style: .small) }
                if thirdKey != .performance { performanceKey(style: .small) }
                key("leaf", "Eco", on: eco) {
                    eco = madeira_get_eco() == 0   // from what it is now, not what the key last saw
                    madeira_set_eco(eco ? 1 : 0)
                }
            }
            .frame(height: 48)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .foldKeys()
        .dynamicTypeSize(...DynamicTypeSize.xLarge)   // the rows are sized for the deck
        .onAppear { FoldDeckState.shared.shown = true; eco = madeira_get_eco() != 0 }
        .onReceive(ticks) { _ in eco = madeira_get_eco() != 0 }
        .onDisappear { FoldDeckState.shared.shown = false }
    }

    /// The game now playing, as Netflix shows the title: its artwork, its name and the
    /// controller, opening the session menu.
    private var nowPlaying: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            library.showMenu()
        } label: {
            HStack(spacing: 10) {
                cover.frame(width: 28, height: 40).clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(library.activeEntry?.title ?? "Game").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(pad.controllerConnected ? GCController.current?.vendorName ?? "Controller" : "Playing on the upper screen")
                        .font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassFace(GlassShape(cornerRadius: 14))
        }
        .buttonStyle(FoldKeyButtonStyle())
        .accessibilityLabel("\(library.activeEntry?.title ?? "Game"), session menu")
    }

    /// The artwork the starting screen showed: Steam's by App ID for a Dock start or a
    /// Steam game without its own cover, else the library's.
    @ViewBuilder private var cover: some View {
        if let entry = library.activeEntry {
            if let appID = dockStart.appID ?? (entry.coverFile == nil ? entry.steamAppID : nil) {
                SteamGameArtwork(appID: appID)
            } else {
                LibraryArtwork(entry: entry)
            }
        } else {
            Color.white.opacity(0.1)
        }
    }

    private var homeQuestion: some View {
        VStack(spacing: 4) {
            Text("Quit \(library.activeEntry?.title ?? "the game") and go back to the library?")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Unsaved progress will be lost.").font(.subheadline).foregroundStyle(.white.opacity(0.65))
        }
        .padding(12)
    }

    /// The third large key: Touch controls without a controller. With one, the controls
    /// would not show on the deck anyway, so Aspect & scaling takes the place, where the
    /// in-game menu offers it (MADEIRA_SESSION_TOOLS), else the performance overlay.
    private enum ThirdKey { case touch, aspect, performance }
    private var thirdKey: ThirdKey {
        !pad.controllerConnected ? .touch : sessionTools ? .aspect : .performance
    }

    /// Aspect & scaling, one tap to the next mode.
    private func aspectKey(style: KeyStyle) -> some View {
        let modes = DisplayMode.allCases
        return key(library.displayMode.symbol, library.displayMode.label, style: style,
                   accessibility: "Aspect & scaling") {
            let i = modes.firstIndex(of: library.displayMode) ?? 0
            library.displayMode = modes[(i + 1) % modes.count]
        }
    }

    private func performanceKey(style: KeyStyle) -> some View {
        key("speedometer", "Performance", style: style, on: library.performance) { library.performance.toggle() }
    }

    enum KeyStyle { case square, large, small }

    /// A keycap: `square` is a glyph alone (its label read by VoiceOver), `large` a glyph
    /// over its label, `small` the two side by side. `on` lights a key that toggles.
    /// `accessibility`: VoiceOver's name when `label` is the key's value (Aspect's mode).
    private func key(_ symbol: String, _ label: String, style: KeyStyle = .small, on: Bool = false,
                     tint: Color? = nil, accessibility: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Group {
                switch style {
                case .square:
                    Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                        .frame(width: 56)
                case .large:
                    VStack(spacing: 6) {
                        Image(systemName: symbol).font(.system(size: 26, weight: .semibold))
                        Text(label).font(.footnote.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                case .small:
                    HStack(spacing: 6) {
                        Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                        Text(label).font(.footnote.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .foregroundStyle(tint ?? .white)
            .glassFace(GlassShape(cornerRadius: style == .large ? 18 : 14,
                                  tint: on ? Color.accentColor.opacity(0.55) : nil))
        }
        .buttonStyle(FoldKeyButtonStyle())
        .accessibilityLabel(accessibility ?? label)
        .accessibilityValue(accessibility == nil ? "" : label)
        .accessibilityAddTraits(on ? .isSelected : [])
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
                shape.fill(LinearGradient(colors: pressed ? [Color(white: 0.14), Color(white: 0.19)]
                                                          : [Color(white: 0.26), Color(white: 0.13)],
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
    @ObservedObject private var network = DeckNetwork.shared

    var body: some View {
        TimelineView(.everyMinute) { context in
            let battery = Self.battery()
            HStack(spacing: 5) {
                Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .monospacedDigit()
                Image(systemName: network.symbol)
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

/// The network mark for DeckStatusBar, from a path monitor started with the first deck:
/// it reports the current path at once and every change after.
@MainActor
final class DeckNetwork: ObservableObject {
    static let shared = DeckNetwork()
    @Published private(set) var symbol = "wifi"
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let symbol = Self.symbol(for: path)
            Task { @MainActor in if self?.symbol != symbol { self?.symbol = symbol } }
        }
        monitor.start(queue: DispatchQueue(label: "madeira.deck-status.path"))
    }

    private nonisolated static func symbol(for path: NWPath) -> String {
        guard path.status == .satisfied else { return "wifi.slash" }
        // A VPN (Madeira's own or LocalDevVPN, for JIT) is the path's first interface
        // while it runs; Wi-Fi is under it.
        if path.usesInterfaceType(.wifi) || path.availableInterfaces.contains(where: { $0.type == .wifi }) { return "wifi" }
        return path.usesInterfaceType(.cellular) ? "cellularbars" : "network"
    }
}

/// The small key at the top of the deck that turns the game's glow under the touch
/// controls off and on (the same setting as FoldDeck's Mirror button).
struct FoldMirrorKey: View {
    @Binding var on: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if !reduceTransparency { button }
    }

    private var button: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            on.toggle()
        } label: {
            Image(systemName: on ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 28)
                .background(GlassShape(cornerRadius: 9))
        }
        .buttonStyle(FoldKeyButtonStyle())
        .accessibilityLabel("Glow")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A live copy of the game. The game's Metal layer can have only one parent, and it
/// must stay a window-level view for its presents to reach the screen
/// (MetalHostView), so the copy is a portal: UIKit's _UIPortalView draws the same
/// layer a second time, scaled to fit here (or with `fill`, to cover it, cropped),
/// without touching the game. Without that class the deck is plain black.
/// `bottom` keeps the game's lower edge on this view's lower edge rather than
/// centring it, for the deck's reflection: flipped, that edge meets the fold.
struct GameMirror: UIViewRepresentable {
    var fill = false
    var bottom = false

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
        var bottom = false

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
            // its aspect ratio, its centre on this view's centre (or, with `bottom`, its
            // lower edge on this view's).
            let full = source.bounds.size
            let crop = sourceRect.width > 1 && sourceRect.height > 1 ? sourceRect : CGRect(origin: .zero, size: full)
            guard full.width > 1, full.height > 1, bounds.width > 1, bounds.height > 1 else { return }
            let sx = bounds.width / crop.width, sy = bounds.height / crop.height
            let scale = fill ? max(sx, sy) : min(sx, sy)
            portal.transform = .identity
            portal.bounds = CGRect(origin: .zero, size: full)
            portal.transform = CGAffineTransform(scaleX: scale, y: scale)
            portal.center = CGPoint(x: bounds.midX + (full.width / 2 - crop.midX) * scale,
                                    y: bottom ? bounds.maxY - (crop.maxY - full.height / 2) * scale
                                              : bounds.midY + (full.height / 2 - crop.midY) * scale)
        }
    }

    func makeUIView(context: Context) -> Mirror { Mirror(frame: .zero) }
    func updateUIView(_ view: Mirror, context: Context) {
        view.fill = fill
        view.bottom = bottom
        view.setNeedsLayout()
    }
}
