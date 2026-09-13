import Foundation

/// One control on the on-screen pad.
///
/// Placement is in the same vocabulary `TouchControl` already uses: position as
/// a fraction of the window, size as a multiple of `VirtualPadLayout.baseDiameter`.
/// Fractions rather than points because the device rotates and the game surface
/// changes size, and this table must not have to be re-authored for either.
struct PadControl: Equatable {
    var hit: PadHit
    var nx: Double
    var ny: Double
    var scale: Double
}

/// What a touch on the pad is driving.
enum PadHit: Equatable, Hashable {
    /// A face button, d-pad direction, shoulder or trigger.
    case button(GamepadButton)
    /// A thumbstick: an axis pair, not a button.
    case stick(PadStick)

    /// May a finger that began on `self` continue as `other`?
    ///
    /// A thumb has to be able to slide across a d-pad — that is what a d-pad
    /// is — and to wander around inside one stick without letting go. It must
    /// NOT be able to slide from a button onto a stick, or a press the user
    /// meant as "jump" silently becomes camera panning halfway through the
    /// gesture. Sticks are therefore sticky, and buttons may swap only with
    /// other buttons.
    static func canReassign(from: PadHit?, to: PadHit) -> Bool {
        guard let from else { return true }
        switch (from, to) {
        case let (.button(a), .button(b)):  return a != b
        case let (.stick(a), .stick(b)):    return a == b
        default:                            return false
        }
    }
}

enum PadStick: String, CaseIterable, Hashable {
    case left, right
}

/// Whether the pad is on screen, and when.
///
/// `automatic` is the default because the pad exists to replace the system
/// keyboard, and a user who has to find a switch before they can play has not
/// been helped. It shows exactly while a session is running — that is
/// `RunStatus.phase.isBusy`, which tracks Wine itself — and is out of the way
/// everywhere else.
///
/// It used to key off `GameChromeState.immersive`, which is a LAYOUT fact, not
/// a session one: an iPhone in landscape is "immersive" from launch, so the pad
/// appeared over the home screen before anything was running. Reported as "the
/// controller shows up as soon as I open the app".
enum VirtualPadMode: String, CaseIterable, Codable, Hashable {
    case off
    case automatic
    case always

    var label: String {
        switch self {
        case .off:       return "Off"
        case .automatic: return "In game"
        case .always:    return "Always"
        }
    }

    var detail: String {
        switch self {
        case .off:       return "Hidden"
        case .automatic: return "Appears while the desktop or a game is running"
        case .always:    return "Stays up over the tooling screens too"
        }
    }

    /// Should the pad be up, given whether a session is running?
    func shows(gameOnScreen: Bool) -> Bool {
        switch self {
        case .off:       return false
        case .automatic: return gameOnScreen
        case .always:    return true
        }
    }
}

/// One stick's axis pair. A named struct rather than a tuple because this is
/// stored and compared, and tuples do not carry Equatable conformance with them.
struct PadAxis: Equatable {
    var x = 0.0
    var y = 0.0
}

/// Geometry for the on-screen PlayStation-style pad.
///
/// Pure functions, deliberately. The pad is the one control surface a user
/// cannot work around: if a hit region and the drawn button disagree, or two
/// controls claim the same point, or a shoulder lands under the immersive exit
/// button, the failure is "the game is unplayable" and it reproduces only on
/// hardware. So the table and the hit test live here, where they can be checked
/// without a screen.
enum VirtualPadLayout {
    /// Matches `TouchControlsModel.baseDiameter`, so the pad and the user's own
    /// touch controls share one notion of what "size 1.0" means.
    static let baseDiameter: Double = 64

    /// Points from a cluster's centre out to each of its four buttons. Fixed in
    /// points rather than fractions so a cross or a diamond stays circular on a
    /// phone and on an iPad alike.
    static let armPoints: Double = 40

    /// Gap held between the topmost shoulder row and the immersive chrome
    /// strip, so a trigger can never sit on the exit button.
    static let chromeClearance: Double = 8

    /// Vertical breathing room between the shoulder rows and the top of a
    /// button cluster, and between the clusters and the sticks.
    static let clusterGap: Double = 10

    /// Keeps the sticks off the bottom edge, where the home indicator lives.
    static let bottomMargin: Double = 10

    /// Face and shoulder buttons. 0.78 of the base is a 50pt target: big enough
    /// for a thumb, small enough that a four-button diamond stays distinct.
    static let buttonScale: Double = 0.78
    static let shoulderScale: Double = 0.80

    /// The sticks are the largest targets on the pad on purpose: one is a
    /// continuous axis and the other drives mouse-look, and both are unusable
    /// if a thumb has to aim.
    static let stickScale: Double = 1.5

    /// Fraction of a stick's hit radius that is actual travel. The rest is the
    /// collar around it: a thumb that lands slightly off centre must still
    /// steer, and a stick whose travel reached its own edge would pin at full
    /// deflection before the thumb got anywhere.
    static let stickTravel: Double = 0.6

    /// Slop on every hit region. A tap a hair outside the drawn circle should
    /// still register.
    static let hitSlop: Double = 4

    static let minOpacity: Double = 0.2
    static let defaultOpacity: Double = 0.55

    static func radius(_ c: PadControl) -> Double { c.scale * baseDiameter / 2 }

    static func travel(_ c: PadControl) -> Double { radius(c) * stickTravel }

    static func centre(_ c: PadControl, in bounds: CGSize) -> CGPoint {
        CGPoint(x: c.nx * bounds.width, y: c.ny * bounds.height)
    }

    /// Opacity is a readability compromise: too faint and the pad cannot be
    /// found, too solid and it hides the game. Clamped rather than trusted
    /// because it is persisted and hand-editable.
    static func opacityClamped(_ v: Double) -> Double {
        guard v.isFinite else { return defaultOpacity }
        return min(max(v, minOpacity), 1)
    }

    /// The layout for a window of this size.
    ///
    /// `topInset` is the immersive chrome strip this overlay must not claim:
    /// the pad window sits above the one drawing that strip, so a control
    /// overlapping it would swallow the exit button and strand the user.
    static func controls(for bounds: CGSize, topInset: Double = 0) -> [PadControl] {
        bounds.height > bounds.width
            ? portrait(bounds, topInset: topInset)
            : landscape(bounds, topInset: topInset)
    }

    /// Shoulder rows, in points, never above the chrome strip.
    ///
    /// The 56pt gap is wider than two hit radii, so the two rows cannot overlap
    /// however small the window gets.
    static func shoulderRows(bounds: CGSize, topInset: Double,
                             preferredFraction: Double) -> (bumper: Double, trigger: Double) {
        let r = shoulderScale * baseDiameter / 2
        let floor = topInset + chromeClearance + r
        let trigger = max(bounds.height * preferredFraction, floor)
        return (bumper: trigger + 56, trigger: trigger)
    }

    /// Where the button clusters go, in points.
    ///
    /// Derived from the shoulder row rather than from a fraction of the height:
    /// a fraction happens to clear the shoulders on a 1366pt iPad and collides
    /// with them on a 375pt phone, which is the one device nobody tests on.
    static func clusterCentreY(bounds: CGSize, topInset: Double,
                               preferredShoulderFraction: Double) -> Double {
        let rows = shoulderRows(bounds: bounds, topInset: topInset,
                                preferredFraction: preferredShoulderFraction)
        let shoulderR = shoulderScale * baseDiameter / 2
        let buttonR = buttonScale * baseDiameter / 2
        // The topmost button of a cluster sits `armPoints` above its centre, so
        // the centre has to clear the bumper row by that much plus both radii.
        return rows.bumper + shoulderR + clusterGap + buttonR + armPoints
    }

    /// Where the sticks go, in points: pinned to the bottom, because that is
    /// where a thumb rests whether the device is a phone or an iPad.
    static func stickCentreY(bounds: CGSize) -> Double {
        bounds.height - stickScale * baseDiameter / 2 - bottomMargin
    }

    /// The pad's own hide button: a disc in the middle of the deck.
    ///
    /// Deliberately not a `GamepadButton` and not part of the layout's hit
    /// table. A user who finds the pad in the way has to be able to put it away
    /// without leaving the game, and the alternative — walking to Settings —
    /// means walking through whatever the pad is covering.
    static func hideDisc(for bounds: CGSize, topInset: Double)
        -> (centre: CGPoint, radius: Double) {
        let portrait = bounds.height > bounds.width
        let y = clusterCentreY(bounds: bounds, topInset: topInset,
                               preferredShoulderFraction: portrait ? 0.30 : 0.15)
        return (CGPoint(x: bounds.width / 2, y: y), radius: hideScale * baseDiameter / 2)
    }

    /// A hide disc between two clusters, so it cannot overlap either. Checked
    /// for every reference size in tools/test-app-ui.sh.
    static let hideScale: Double = 0.7

    /// Landscape: d-pad and left stick under the left thumb, face buttons and
    /// right stick under the right, triggers up the sides.
    static func landscape(_ bounds: CGSize, topInset: Double = 0) -> [PadControl] {
        let ax = armPoints / max(bounds.width, 1)
        let ay = armPoints / max(bounds.height, 1)
        let rows = shoulderRows(bounds: bounds, topInset: topInset, preferredFraction: 0.15)
        let ty = rows.trigger / max(bounds.height, 1)
        let by = rows.bumper / max(bounds.height, 1)

        // Clusters sit in the lower half and the sticks inboard of them, which
        // is where a thumb rests when the device is held in two hands.
        let padX = 0.115, faceX = 0.885
        let clusterY = clusterCentreY(bounds: bounds, topInset: topInset,
                                      preferredShoulderFraction: 0.15) / max(bounds.height, 1)
        let stickY = stickCentreY(bounds: bounds) / max(bounds.height, 1)

        var out: [PadControl] = []
        out += cluster(up: .button(.up), right: .button(.right),
                       down: .button(.down), left: .button(.left),
                       x: padX, y: clusterY, ax: ax, ay: ay)
        out.append(PadControl(hit: .stick(.left), nx: 0.24, ny: stickY, scale: stickScale))
        // PlayStation order: triangle up, circle right, cross down, square left.
        out += cluster(up: .button(.y), right: .button(.b),
                       down: .button(.a), left: .button(.x),
                       x: faceX, y: clusterY, ax: ax, ay: ay)
        out.append(PadControl(hit: .stick(.right), nx: 0.76, ny: stickY, scale: stickScale))
        out += shoulders(ty: ty, by: by, leftX: 0.085, rightX: 0.915)
        // Options and share between the sticks, out of both thumbs' way.
        let middleY = (clusterY + stickY) / 2
        out.append(PadControl(hit: .button(.menu), nx: 0.545, ny: middleY, scale: buttonScale))
        out.append(PadControl(hit: .button(.view), nx: 0.455, ny: middleY, scale: buttonScale))
        return out
    }

    /// Portrait: the same pad, squeezed. The shoulders move to mid-height
    /// because the top corners of a phone in portrait are out of reach.
    static func portrait(_ bounds: CGSize, topInset: Double = 0) -> [PadControl] {
        let ax = armPoints / max(bounds.width, 1)
        let ay = armPoints / max(bounds.height, 1)
        let rows = shoulderRows(bounds: bounds, topInset: topInset, preferredFraction: 0.30)
        let ty = rows.trigger / max(bounds.height, 1)
        let by = rows.bumper / max(bounds.height, 1)

        let padX = 0.18, faceX = 0.82
        let clusterY = clusterCentreY(bounds: bounds, topInset: topInset,
                                      preferredShoulderFraction: 0.30) / max(bounds.height, 1)
        let stickY = stickCentreY(bounds: bounds) / max(bounds.height, 1)

        var out: [PadControl] = []
        out += cluster(up: .button(.up), right: .button(.right),
                       down: .button(.down), left: .button(.left),
                       x: padX, y: clusterY, ax: ax, ay: ay)
        out.append(PadControl(hit: .stick(.left), nx: 0.22, ny: stickY, scale: stickScale))
        out += cluster(up: .button(.y), right: .button(.b),
                       down: .button(.a), left: .button(.x),
                       x: faceX, y: clusterY, ax: ax, ay: ay)
        out.append(PadControl(hit: .stick(.right), nx: 0.78, ny: stickY, scale: stickScale))
        out += shoulders(ty: ty, by: by, leftX: 0.10, rightX: 0.90)
        let middleY = (clusterY + stickY) / 2
        out.append(PadControl(hit: .button(.menu), nx: 0.58, ny: middleY, scale: buttonScale))
        out.append(PadControl(hit: .button(.view), nx: 0.42, ny: middleY, scale: buttonScale))
        return out
    }

    /// Four buttons around a centre, clockwise from up.
    private static func cluster(up: PadHit, right: PadHit, down: PadHit, left: PadHit,
                                x: Double, y: Double, ax: Double, ay: Double) -> [PadControl] {
        [
            PadControl(hit: up,    nx: x,      ny: y - ay, scale: buttonScale),
            PadControl(hit: right, nx: x + ax, ny: y,      scale: buttonScale),
            PadControl(hit: down,  nx: x,      ny: y + ay, scale: buttonScale),
            PadControl(hit: left,  nx: x - ax, ny: y,      scale: buttonScale),
        ]
    }

    private static func shoulders(ty: Double, by: Double,
                                  leftX: Double, rightX: Double) -> [PadControl] {
        [
            PadControl(hit: .button(.lt), nx: leftX,  ny: ty, scale: shoulderScale),
            PadControl(hit: .button(.lb), nx: leftX,  ny: by, scale: shoulderScale),
            PadControl(hit: .button(.rt), nx: rightX, ny: ty, scale: shoulderScale),
            PadControl(hit: .button(.rb), nx: rightX, ny: by, scale: shoulderScale),
        ]
    }

    /// What is under this window point, if anything.
    ///
    /// Buttons win over sticks when the two overlap: the sticks are the biggest
    /// targets on the pad, and a face button drawn on top of one must keep
    /// working. Nearest wins within a class, so the geometry — not the order of
    /// the table — decides.
    static func hit(_ p: CGPoint, in bounds: CGSize, controls: [PadControl]) -> PadHit? {
        var bestButton: (hit: PadHit, distance: Double)?
        var bestStick: (hit: PadHit, distance: Double)?
        for c in controls {
            let centre = centre(c, in: bounds)
            // Double, not CGFloat: the radii and offsets in this file are all
            // Double, and mixing the two silently picks the platform's width.
            let dx = Double(p.x - centre.x), dy = Double(p.y - centre.y)
            let d = (dx * dx + dy * dy).squareRoot()
            guard d <= radius(c) + hitSlop else { continue }
            switch c.hit {
            case .button:
                if bestButton == nil || d < bestButton!.distance { bestButton = (c.hit, d) }
            case .stick:
                if bestStick == nil || d < bestStick!.distance { bestStick = (c.hit, d) }
            }
        }
        return bestButton?.hit ?? bestStick?.hit
    }

    /// A stick's deflection for a touch, as `GamepadInput` wants it: -1...1 with
    /// +y UP.
    ///
    /// The sign flip is the whole reason this is a function and not two
    /// subtractions at the call site. The screen's y grows downward and the
    /// sticks do not, and an inverted stick reads as "the pad is broken" rather
    /// than "one axis is negated" — the same trap `GamepadMap.output` documents
    /// for the mouse-look axis.
    static func stickVector(centre: CGPoint, travel: Double, at p: CGPoint) -> PadAxis {
        guard travel > 0 else { return PadAxis() }
        var x = (p.x - centre.x) / travel
        var y = (p.y - centre.y) / travel
        // Clamped to the unit circle, not the unit square: a diagonal push must
        // not be 1.41 times faster than a straight one.
        let m = (x * x + y * y).squareRoot()
        if m > 1 { x /= m; y /= m }
        return PadAxis(x: x, y: -y)
    }
}

/// Multi-touch bookkeeping for the pad, as pure state.
///
/// The subtle failures all live here: two thumbs on one button must keep it
/// held until the LAST one lifts, and lifting the thumb that happens to be on a
/// stick must clear that stick's axis, or the camera keeps panning forever
/// after the finger is gone. Both are invisible in a screenshot and obvious in
/// a test.
struct VirtualPadTouchState: Equatable {
    /// Active touches by identity, so a button held by two thumbs is released
    /// once.
    private(set) var active: [Int: PadHit] = [:]
    private var axes: [PadStick: PadAxis] = [:]

    /// The buttons currently held, by anyone.
    var buttons: Set<GamepadButton> {
        var out = Set<GamepadButton>()
        for hit in active.values {
            if case .button(let b) = hit { out.insert(b) }
        }
        return out
    }

    var input: GamepadInput {
        var i = GamepadInput()
        i.buttons = buttons
        i.leftX = axes[.left]?.x ?? 0
        i.leftY = axes[.left]?.y ?? 0
        i.rightX = axes[.right]?.x ?? 0
        i.rightY = axes[.right]?.y ?? 0
        return i
    }

    /// True when nothing is held, so the bridge can stop its tick.
    var isIdle: Bool { active.isEmpty }

    /// What this finger is currently driving, if it is still down.
    func hit(of touch: Int) -> PadHit? { active[touch] }

    mutating func begin(_ hit: PadHit, touch: Int) {
        active[touch] = hit
        if case .stick(let s) = hit { axes[s] = PadAxis() }
    }

    mutating func move(_ stick: PadStick, to axis: PadAxis) {
        axes[stick] = axis
    }

    mutating func end(touch: Int) {
        guard let hit = active.removeValue(forKey: touch) else { return }
        // Only clear the axis when the last touch on this stick has gone.
        if case .stick(let s) = hit, !active.values.contains(.stick(s)) {
            axes[s] = nil
        }
    }

    mutating func endAll() {
        active.removeAll()
        axes.removeAll()
    }
}
