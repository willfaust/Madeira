// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import UIKit

/// The pinch's clicks: the thin shell over what `GridZoomHapticDecider` decides. A light click per level crossed,
/// and a heavy one when the pinch enters the rubber band. Settings > Appearance > "Zoom haptics" switches these
/// (and only these) off; the generators follow the system's haptics setting as well.
@MainActor
final class GridZoomHapticPlayer {
    /// One pair of generators for every session: creating them costs milliseconds (the haptic engine starts), so the
    /// host makes them ready when the page loads, not inside the first pinch.
    static let shared = GridZoomHapticPlayer()
    static let key = "madeiraLibraryZoomHaptics"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    private let step = UIImpactFeedbackGenerator(style: .light)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)

    func prepare() {
        guard Self.enabled else { return }
        step.prepare()
        heavy.prepare()
    }

    func play(_ event: GridZoomHapticDecider.Event) {
        guard Self.enabled else { return }
        switch event {
        case .step:
            step.impactOccurred()
            step.prepare()
        case .limit:
            heavy.impactOccurred(intensity: 1)
            heavy.prepare()
        }
    }
}
