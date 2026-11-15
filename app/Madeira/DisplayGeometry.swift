// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Lee Simpson
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// [display-geometry]: the screen as Madeira sees it, logged at launch and on
// every scene geometry or size-class change. The `[device]` line at launch
// (EntitlementChecker.swift) says nothing about a screen that changes while
// the app runs: a foldable (iPhone Duo) folds and unfolds, Stage Manager
// resizes. A line is written only when the reading differs from the scene's
// last one, so repeated callbacks for the same layout stay out of the log.

/// One reading of a scene's display. Foundation-only so the host checks can
/// build it (tests/host/check-duo-display.py).
struct DisplayGeometry: Equatable {
    /// Posted on the main queue when the app's own scene has a new reading. A
    /// fold that stays in landscape changes the scene's size without an
    /// orientation change, so the game layer and the touch controls re-frame
    /// on this as well as on UIDevice.orientationDidChangeNotification.
    static let changed = Notification.Name("MadeiraDisplayGeometryChanged")

    struct Insets: Equatable { var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0 }

    /// The scene in points, as laid out now (Stage Manager or Split View can make it smaller than the screen).
    var scene: CGSize
    /// The scene's UIScreen in points, and UIScreen.nativeBounds in pixels (portrait-up).
    var screen: CGSize
    var native: CGSize
    var scale: CGFloat
    var nativeScale: CGFloat
    var orientation: String
    var horizontal: String
    var vertical: String
    var idiom: String
    var safeArea: Insets
    var screens: Int
    var maxFPS: Int

    private static func size(_ s: CGSize) -> String { "\(Self.number(s.width))x\(Self.number(s.height))" }
    private static func number(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", Double(v))
    }

    /// The log line's fields, without the `[display-geometry] <reason>` prefix.
    var line: String {
        let i = safeArea
        return "scene=\(Self.size(scene))pt screen=\(Self.size(screen))pt native=\(Self.size(native))px"
            + " scale=\(Self.number(scale)) native-scale=\(String(format: "%.3f", Double(nativeScale)))"
            + " orientation=\(orientation) size-class=\(horizontal)/\(vertical) idiom=\(idiom)"
            + " safe-area=\(Self.number(i.top)),\(Self.number(i.left)),\(Self.number(i.bottom)),\(Self.number(i.right))"
            + " screens=\(screens) max-fps=\(maxFPS)"
    }
}

#if canImport(UIKit)
extension DisplayGeometry {
    @MainActor init(_ scene: UIWindowScene) {
        let screen = scene.screen
        let window = scene.keyWindow ?? scene.windows.first
        let insets = window?.safeAreaInsets ?? .zero
        self.init(scene: scene.coordinateSpace.bounds.size,
                  screen: screen.bounds.size,
                  native: screen.nativeBounds.size,
                  scale: screen.scale,
                  nativeScale: screen.nativeScale,
                  orientation: Self.name(scene.effectiveGeometry.interfaceOrientation),
                  horizontal: Self.name(scene.traitCollection.horizontalSizeClass),
                  vertical: Self.name(scene.traitCollection.verticalSizeClass),
                  idiom: Self.name(scene.traitCollection.userInterfaceIdiom),
                  safeArea: Insets(top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right),
                  screens: UIScreen.screens.count,
                  maxFPS: screen.maximumFramesPerSecond)
    }

    static func name(_ o: UIInterfaceOrientation) -> String {
        switch o {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portrait-upside-down"
        case .landscapeLeft: return "landscape-left"
        case .landscapeRight: return "landscape-right"
        case .unknown: return "unknown"
        @unknown default: return "other(\(o.rawValue))"
        }
    }

    static func name(_ c: UIUserInterfaceSizeClass) -> String {
        switch c {
        case .compact: return "compact"
        case .regular: return "regular"
        case .unspecified: return "unspecified"
        @unknown default: return "other(\(c.rawValue))"
        }
    }

    static func name(_ i: UIUserInterfaceIdiom) -> String {
        switch i {
        case .phone: return "phone"
        case .pad: return "pad"
        case .mac: return "mac"
        case .tv: return "tv"
        case .carPlay: return "carplay"
        case .unspecified: return "unspecified"
        default: return "other(\(i.rawValue))"
        }
    }
}

/// Watches every window scene's effective geometry (KVO) and size classes
/// (trait registration) and writes a `[display-geometry]` line when either
/// changes. Started from MadeiraApp.init, before any scene connects.
@MainActor final class DisplayGeometryMonitor {
    static let shared = DisplayGeometryMonitor()

    private struct Watch {
        let geometry: NSKeyValueObservation
        let traits: UITraitChangeRegistration
    }
    private var watches: [ObjectIdentifier: Watch] = [:]
    private var last: [ObjectIdentifier: DisplayGeometry] = [:]
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let scene = note.object as? UIWindowScene { DisplayGeometryMonitor.shared.watch(scene, reason: "connect") }
            }
        }
        center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let scene = note.object as? UIWindowScene { DisplayGeometryMonitor.shared.report(scene, reason: "activate") }
            }
        }
        center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let scene = note.object as? UIScene else { return }
                LogStore.shared.log("[display-geometry] disconnect scenes=\(UIApplication.shared.connectedScenes.count)")
                let id = ObjectIdentifier(scene)
                DisplayGeometryMonitor.shared.watches[id] = nil
                DisplayGeometryMonitor.shared.last[id] = nil
            }
        }
        for name in [UIScreen.didConnectNotification, UIScreen.didDisconnectNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    let what = note.name == UIScreen.didConnectNotification ? "screen-connect" : "screen-disconnect"
                    LogStore.shared.log("[display-geometry] \(what) screens=\(UIScreen.screens.count)")
                }
            }
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            watch(scene, reason: "launch")
        }
    }

    private func watch(_ scene: UIWindowScene, reason: String) {
        let id = ObjectIdentifier(scene)
        guard watches[id] == nil else { return }
        // UIKit changes effectiveGeometry on the main thread; the window's safe
        // area follows in the same layout pass, so the line is read just after.
        let geometry = scene.observe(\.effectiveGeometry, options: [.new]) { scene, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DisplayGeometryMonitor.shared.report(scene, reason: "geometry") }
            }
        }
        let traits = scene.registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) {
            (scene: UIWindowScene, _: UITraitCollection) in
            MainActor.assumeIsolated { DisplayGeometryMonitor.shared.report(scene, reason: "traits") }
        }
        watches[id] = Watch(geometry: geometry, traits: traits)
        report(scene, reason: reason)
    }

    func report(_ scene: UIWindowScene, reason: String) {
        let id = ObjectIdentifier(scene)
        if watches[id] == nil { watch(scene, reason: reason); return }
        let now = DisplayGeometry(scene)
        guard last[id] != now else { return }
        last[id] = now
        LogStore.shared.log("[display-geometry] \(reason) \(now.line)")
        // The app's own screen (not an external display's scene) sets the
        // Resolution choices: a foldable's fold changes them, a rotation does not.
        guard scene.session.role == .windowApplication else { return }
        NotificationCenter.default.post(name: DisplayGeometry.changed, object: scene)
        if ResolutionChoices.update(.landscape(points: now.screen, pixels: now.native)) {
            let d = ResolutionChoices.defaultSize()
            LogStore.shared.log("[display-geometry] resolution choices follow the screen: default \(d.w)x\(d.h)"
                + (ResolutionChoices.screen720Value.map { " 720-lines \($0)" } ?? ""))
        }
    }
}
#endif
