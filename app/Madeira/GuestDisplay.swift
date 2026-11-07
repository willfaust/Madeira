import Foundation
#if canImport(UIKit)
import UIKit
#endif

// The guest's virtual monitor and how it is laid out on the device's screen.
//
// A game renders for the virtual monitor win32u reports (build/win32u-unix/
// sysparams_ios.c): it starts at the session default from MADEIRA_SCREEN_W/H,
// and a game's ChangeDisplaySettings programs a new mode, which win32u
// publishes through winios_display_mode_changed() (IOSDisplayShim.m;
// MADEIRA_VIRTUAL_MODE_SET=0 keeps the session default). MetalBackedView reads the current size back (winios_screen_size) and places
// the presented layer with GameSurfaceLayout, so the layer's frame and the
// touch mapping always agree. A library entry chooses the monitor size
// (Resolution) and how it is scaled (Aspect & scaling); the developer
// interface keeps Fit.

/// How the guest surface is mapped into the view's bounds.
enum DisplayMode: String, CaseIterable {
    case fit, fill, stretch, aspect, blend

    /// Older settings stored "fitHeight" (Fill height); it behaved as Fit in
    /// landscape and is gone from the picker, so it decodes to Fit.
    init?(rawValue: String) {
        switch rawValue {
        case "fit", "fitHeight": self = .fit
        case "fill": self = .fill
        case "stretch": self = .stretch
        case "aspect": self = .aspect
        case "blend": self = .blend
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .fit:       return "Fit"
        case .fill:      return "Fill"
        case .stretch:   return "Stretch"
        case .aspect:    return "Aspect"
        case .blend:     return "Blend"
        }
    }
    var symbol: String {
        switch self {
        case .fit:       return "aspectratio"
        case .fill:      return "arrow.up.left.and.arrow.down.right"
        case .stretch:   return "rectangle.expand.vertical"
        case .aspect:    return "rectangle.ratio.16.to.9"
        case .blend:     return "rectangle.compress.vertical"
        }
    }
}

/// Geometry shared by the presented layer's frame and the touch mapping: if
/// the two did their own aspect math, Fill and Stretch would skew input the
/// moment they disagreed by a rounding hair.
enum GameSurfaceLayout {
    /// The rect, in `bounds`'s coordinate space, that the guest surface
    /// occupies for `mode`.
    ///
    /// - Fit: the guest's shape, as large as fits, centred (letterbox).
    /// - Fill: the guest's shape, covering `bounds`; one axis overflows and
    ///   is cropped.
    /// - Stretch: exactly `bounds`.
    /// - Aspect: like Fit, but on the shape of what is actually presented
    ///   (`aspect`, the swapchain drawable, i.e. the game's back buffer). A
    ///   game whose back buffer is 4:3 on a 16:9 monitor is stretched by the
    ///   layer in every other mode; here it is scaled uniformly. Falls back to
    ///   the guest shape until a drawable size is known (`aspect == .zero`).
    /// - Blend: halfway between Fill and Stretch. The picture takes the
    ///   geometric mean of the guest's shape and `bounds`'s and covers
    ///   `bounds`, so half of the shape difference is cropped and half is
    ///   stretched (madeira-duo: PoE2 draws 16:10 at the narrowest, the
    ///   unfolded Duo is ~1.42:1; Stretch squashed it 11%, Fill cropped 5.5%
    ///   a side, Blend is ~5.5% squash and ~3% a side).
    static func rect(guest: CGSize, aspect: CGSize = .zero, bounds: CGRect, mode: DisplayMode) -> CGRect {
        guard guest.width > 0, guest.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        if mode == .stretch { return bounds }
        let useDrawable = mode == .aspect && aspect.width > 0 && aspect.height > 0
        var shape = useDrawable ? aspect : guest
        if mode == .blend {
            let guestAspect = guest.width / guest.height, boundsAspect = bounds.width / bounds.height
            shape = CGSize(width: (guestAspect * boundsAspect).squareRoot(), height: 1)
        }
        let sx = bounds.width / shape.width, sy = bounds.height / shape.height
        let scale = mode == .fill || mode == .blend ? max(sx, sy) : min(sx, sy)
        let w = shape.width * scale, h = shape.height * scale
        return CGRect(x: bounds.minX + (bounds.width - w) / 2,
                      y: bounds.minY + (bounds.height - h) / 2,
                      width: w, height: h)
    }

    /// A point in `bounds`'s coordinate space (a touch) in guest pixels for
    /// `mode`, clamped to the guest surface; a touch in Fill's cropped margin
    /// clamps to the nearest edge.
    static func map(point: CGPoint, guest: CGSize, aspect: CGSize = .zero, bounds: CGRect, mode: DisplayMode) -> CGPoint {
        let r = rect(guest: guest, aspect: aspect, bounds: bounds, mode: mode)
        guard r.width > 0, r.height > 0 else { return .zero }
        let x = (point.x - r.minX) * guest.width / r.width
        let y = (point.y - r.minY) * guest.height / r.height
        return CGPoint(x: min(max(x, 0), guest.width - 1),
                       y: min(max(y, 0), guest.height - 1))
    }
}

/// The session default of the guest's virtual monitor.
enum GuestDisplay {
    /// Standard modes a session default is chosen from when no size is given.
    static let standardModes: [(w: Int, h: Int)] = [
        (640, 480), (800, 600), (1024, 768), (1152, 864),
        (1280, 720), (1280, 768), (1280, 800), (1280, 960),
        (1280, 1024), (1360, 768), (1366, 768), (1440, 900),
        (1600, 900), (1600, 1200), (1680, 1050), (1920, 1080),
        (1920, 1200), (2048, 1536), (2560, 1440),
    ]

    /// The standard mode nearest a landscape view's shape, and among modes of
    /// effectively the same shape (0.9 to 2.1 megapixels) the cheapest: a
    /// 19.5:9 phone gets 1280x720, a 4:3 tablet 1152x864.
    static func defaultMode(forLandscapeView size: CGSize) -> (w: Int, h: Int) {
        let fallback = (w: 1280, h: 720)
        guard size.width > 0, size.height > 0 else { return fallback }
        let want = Double(max(size.width, size.height) / min(size.width, size.height))
        let candidates = standardModes.filter { m in
            let px = m.w * m.h
            return px >= 900_000 && px <= 2_100_000
        }
        guard !candidates.isEmpty else { return fallback }
        let error = { (m: (w: Int, h: Int)) in abs(Double(m.w) / Double(m.h) - want) }
        let best = candidates.map(error).min()!
        return candidates.filter { error($0) <= best + 0.01 }
                         .min { $0.w * $0.h < $1.w * $1.h }!
    }

    /// Chooses the session's virtual monitor and exports it for win32u, which
    /// reads MADEIRA_SCREEN_W/H (and MADEIRA_SCREEN_SRC for its log line) the
    /// first time the monitor is queried. `knob` is a "WxH" choice (a library
    /// entry's Resolution); without a valid one the default is the standard
    /// mode nearest the view's shape.
    ///
    /// The size is also published to IOSDisplayShim, so a layout that already
    /// ran re-reads it (MadeiraDisplayModeChangedNotification).
    @discardableResult
    static func configureSessionDefault(view: CGSize, knob: String?) -> (w: Int, h: Int, source: String) {
        var mode = defaultMode(forLandscapeView: view)
        var source = "view"
        if let raw = knob?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let parts = raw.lowercased().split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 {
                mode = (w, h)
                source = "knob"
            }
        }
        setenv("MADEIRA_SCREEN_W", String(mode.w), 1)
        setenv("MADEIRA_SCREEN_H", String(mode.h), 1)
        setenv("MADEIRA_SCREEN_SRC", source, 1)
        winios_display_mode_changed(Int32(mode.w), Int32(mode.h))
        return (mode.w, mode.h, source)
    }
}

/// ml1172: the Resolution choices, built from this device's screen.
///
/// Upstream's library offered one fixed list whose default, 1408x648, is a
/// 19.5:9 phone's landscape shape: on an iPad, Fit leaves a third of the
/// screen black. The fork's ml1157 list (0.8x to 2x the screen in points)
/// was device-shaped but far too small on a phone, whose points are few.
/// Here the sizes that fill the screen have its shape at fixed pixel counts,
/// so a choice costs the GPU the same on every device, followed by the usual
/// PC sizes (16:9, 4:3) with a note on how each fits this screen. The
/// library's Resolution picker (games and the Desktop entry) and the
/// developer interface's Resolution menu both show this list; its first
/// choice is the default.
enum ResolutionChoices {
    struct Choice: Hashable {
        let w: Int, h: Int
        let label: String
        var value: String { "\(w)x\(h)" }
    }

    struct Group {
        let title: String
        let choices: [Choice]
    }

    /// The screen in landscape: `points` give its shape, `pixels` its native size.
    struct Screen {
        var points: CGSize
        var pixels: CGSize
    }

    /// Read once. MadeiraApp.init touches it first, on the main thread;
    /// library entries (whose default comes from it) are also made off it.
    static var screen: Screen = {
        #if canImport(UIKit)
        let b = UIScreen.main.bounds, n = UIScreen.main.nativeBounds
        return Screen(points: CGSize(width: max(b.width, b.height), height: min(b.width, b.height)),
                      pixels: CGSize(width: max(n.width, n.height), height: min(n.width, n.height)))
        #else
        // Hosts without UIKit (the host tests): an 11-inch iPad.
        return Screen(points: CGSize(width: 1180, height: 820), pixels: CGSize(width: 2360, height: 1640))
        #endif
    }()

    /// Pixel counts of the screen-shaped choices: a light one (944x656's, 0.8x
    /// an 11-inch iPad's points), the default (1280x720's: 1408x648 on a 19.5:9
    /// iPhone, the size every entry had before these choices, so a game's mode
    /// list is unchanged), then 1920x1080's.
    static let budgets: [(pixels: Int, name: String)] = [
        (944 * 656, "light"), (1280 * 720, "default"), (1920 * 1080, "≈1080p"),
    ]
    static let defaultBudget = 1
    static let widescreen = [(960, 540), (1280, 720), (1600, 900), (1920, 1080), (2560, 1440)]
    static let classic = [(640, 480), (800, 600), (1024, 768), (1280, 960)]

    static func aspect(_ s: Screen) -> Double {
        s.points.height > 0 ? Double(s.points.width / s.points.height) : 16.0 / 9
    }

    /// The screen's shape at about `pixels`, both sides multiples of 8.
    static func shape(_ s: Screen, pixels: Int) -> (w: Int, h: Int) {
        let a = aspect(s)
        let h = Int(((Double(pixels) / a).squareRoot() / 8).rounded()) * 8
        return (Int((Double(h) * a / 8).rounded()) * 8, h)
    }

    /// Whether a w x h monitor has this screen's shape: within 1.5%, where
    /// Fit fills both axes (GameSurfaceLayout.rect).
    static func fills(_ w: Int, _ h: Int, screen s: Screen = screen) -> Bool {
        h > 0 && abs(Double(w) / Double(h) / aspect(s) - 1) < 0.015
    }

    static func defaultSize(for s: Screen = screen) -> (w: Int, h: Int) { shape(s, pixels: budgets[defaultBudget].pixels) }
    static var defaultValue: String { let d = defaultSize(); return "\(d.w)x\(d.h)" }

    /// madeira-bcd: the screen's shape at `lines` lines, the width a multiple of 8.
    static func lines(_ s: Screen, _ lines: Int) -> (w: Int, h: Int) {
        (Int((Double(lines) * aspect(s) / 8).rounded()) * 8, lines)
    }

    /// madeira-bcd: this screen's shape at 720 lines (1568x720 on a 19.5:9 iPhone),
    /// offered when the default has fewer lines. Red Dead Redemption 2 lists only
    /// modes of at least 720 lines for full screen, so on a phone, whose default
    /// is 1408x648, it offered 960x720 and 1024x768 and the picture did not fill
    /// the screen (owner's run of 2026-10-09 11:34). A game's recommended settings
    /// name it as GameRecommendation.screen720.
    static func screen720(for s: Screen = screen) -> (w: Int, h: Int)? {
        let d = defaultSize(for: s), l = lines(s, 720), native = Int(s.pixels.width) * Int(s.pixels.height)
        return d.h < 720 && l.w * l.h < native ? l : nil
    }
    static var screen720Value: String? { screen720().map { "\($0.w)x\($0.h)" } }

    static func groups(for s: Screen = screen) -> [Group] {
        let native = (w: Int(s.pixels.width), h: Int(s.pixels.height))
        var own: [Choice] = []
        for (i, b) in budgets.enumerated() {
            let (w, h) = shape(s, pixels: b.pixels)
            // More pixels than the screen has only cost more (never the light or default size).
            if i > defaultBudget && w * h >= native.w * native.h { break }
            own.append(Choice(w: w, h: h, label: "\(w)×\(h) · \(b.name)"))
            if i == defaultBudget, let l = screen720(for: s) {
                own.append(Choice(w: l.w, h: l.h, label: "\(l.w)×\(l.h) · 720 lines"))
            }
        }
        if native.w <= 3840, native.h <= 2160, !own.contains(where: { $0.w == native.w && $0.h == native.h }) {
            own.append(Choice(w: native.w, h: native.h, label: "\(native.w)×\(native.h) · native"))
        }
        var out = [Group(title: "This screen's shape", choices: own)]
        for (name, sizes) in [("16:9 widescreen", widescreen), ("4:3 classic", classic)] {
            let (w0, h0) = sizes[0]
            let r = Double(w0) / Double(h0) / aspect(s)
            let note = fills(w0, h0, screen: s) ? "fills this screen" : (r > 1 ? "bars above and below" : "bars at the sides")
            // A size already offered in this screen's shape (1280x720 on a 16:9 phone) is listed once.
            let rest = sizes.filter { size in !own.contains(where: { $0.w == size.0 && $0.h == size.1 }) }
            if !rest.isEmpty {
                out.append(Group(title: "\(name) · \(note)", choices: rest.map { Choice(w: $0.0, h: $0.1, label: "\($0.0)×\($0.1)") }))
            }
        }
        return out
    }

    /// The screen's shape at 480 lines, which MetalFX 1.5× brings to 720 (the
    /// library offers it while a game uses MetalFX 1.5×); nil when `groups`
    /// already have that size (640x480 on a 4:3 iPad).
    static func metalFX(for s: Screen = screen, in groups: [Group]) -> Choice? {
        let w = Int((480 * aspect(s) / 8).rounded()) * 8
        guard (640...4096).contains(w), !groups.contains(where: { $0.choices.contains { $0.w == w && $0.h == 480 } }) else { return nil }
        return Choice(w: w, h: 480, label: "\(w)×480 · for MetalFX 1.5×")
    }

    /// A stored "WxH" that none of `groups` offers (a size chosen on another
    /// device, or typed into madeira.cfg), so a picker never shows a blank
    /// choice; nil when it is offered or does not parse.
    static func extra(_ value: String, in groups: [Group], note: String) -> Choice? {
        let p = value.lowercased().split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count == 2, !groups.contains(where: { $0.choices.contains { $0.w == p[0] && $0.h == p[1] } }) else { return nil }
        return Choice(w: p[0], h: p[1], label: "\(p[0])×\(p[1]) · \(note)")
    }
}
