// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Foundation/CoreGraphics only, so tests/host/check-library-zoom.py compiles it on the host.

import CoreGraphics
import Foundation

/// The Photos-style grid zoom's arithmetic. Nothing here knows UIKit: a host hands it the cover widths of its levels,
/// both layouts' frames and a pinch scale, and renders what comes back. The transition is a pure function of ONE progress
/// value, which is what makes a release interruptible and a scrub reversible.
///
/// The levels (smallest cover first) sit at integer positions `0 … n−1`. A pinch moves a continuous coordinate `t`: the
/// cover width times the pinch scale falls between two levels' widths (in log space, so 2× in and 2× out are equally
/// far); `segment(t)` names those two levels and how far between them.
///
/// Inside a segment an interior cell (visible in both layouts) crossfades its two renderings near the end the pinch
/// entered from, so the user can scrub back across that point. An edge cell (visible in one layout) keeps its one
/// rendering, so its label size never changes mid-animation.
enum GridZoomTransition {

    // MARK: - The coordinate

    /// The level coordinate after a pinch of `scale` from `base`; `widths` are the levels' cover widths, ascending.
    /// Past either end it keeps going at the end segment's log rate (`rubberBand` arrests it).
    static func coordinate(base: CGFloat, scale: CGFloat, widths: [CGFloat]) -> CGFloat {
        guard widths.count >= 2, scale > 0 else { return base }
        return coordinate(ofWidth: width(at: base, widths: widths) * scale, widths: widths)
    }

    /// The coordinate at which the cover is `width` wide (the inverse of `width(at:)`, extrapolated past the ends).
    static func coordinate(ofWidth width: CGFloat, widths: [CGFloat]) -> CGFloat {
        guard widths.count >= 2 else { return 0 }
        let target = log(max(0.001, width))
        let logs = widths.map { log(max(0.001, $0)) }
        // The first segment whose top the target does not pass; the last one otherwise
        // (and the first extrapolates below its bottom).
        let k = (0..<(logs.count - 1)).first { target <= logs[$0 + 1] } ?? (logs.count - 2)
        let span = logs[k + 1] - logs[k]
        guard abs(span) > 1e-6 else { return CGFloat(k) }
        return CGFloat(k) + (target - logs[k]) / span
    }

    static func width(at t: CGFloat, widths: [CGFloat]) -> CGFloat {
        guard widths.count >= 2 else { return widths.first ?? 0 }
        let (k, p) = segment(t, count: widths.count)
        let a = log(max(0.001, widths[k]))
        let b = log(max(0.001, widths[k + 1]))
        return exp(a + (b - a) * p)
    }

    /// The segment `t` is in and how far through it (`progress` leaves 0 … 1 slightly at the ends under a rubber band's give).
    static func segment(_ t: CGFloat, count: Int) -> (lower: Int, progress: CGFloat) {
        guard count >= 2 else { return (0, 0) }
        let k = min(count - 2, max(0, Int(t.rounded(.down))))
        return (k, t - CGFloat(k))
    }

    /// Past the first / last level the pinch gives a little, with steeply diminishing response (a scroll view's overscroll),
    /// then springs back on release; `give` is the most the coordinate can leave the range, in levels.
    static func rubberBand(
        _ t: CGFloat, levels: Int, give: CGFloat = rubberBandGive
    ) -> CGFloat {
        let top = CGFloat(max(0, levels - 1))
        if t < 0 { return -damped(-t, give: give) }
        if t > top { return top + damped(t - top, give: give) }
        return t
    }

    static let rubberBandGive: CGFloat = 0.3

    private static func damped(_ excess: CGFloat, give: CGFloat) -> CGFloat {
        give * (1 - 1 / (excess / give + 1))
    }

    // MARK: - The plan for one segment

    /// One item's two placements, screen coordinates (content minus the level's offset).
    struct CellPlan: Equatable, Sendable {
        var index: Int
        var lower: CGRect
        var upper: CGRect
        var visibleInLower: Bool
        var visibleInUpper: Bool

        enum Role: Equatable, Sendable {
            case interior
            case lowerEdge
            case upperEdge
            case absent
        }

        var role: Role {
            switch (visibleInLower, visibleInUpper) {
            case (true, true): .interior
            case (true, false): .lowerEdge
            case (false, true): .upperEdge
            case (false, false): .absent
            }
        }
    }

    /// Classifies every item of a segment. The frames are content frames (same order, same count), the offsets each
    /// layout's scroll offset, `viewport` the visible bounds' size. Items visible in neither layout are dropped.
    static func plan(
        lowerFrames: [CGRect], lowerOffset: CGFloat, upperFrames: [CGRect],
        upperOffset: CGFloat, viewport: CGSize
    ) -> [CellPlan] {
        let bounds = CGRect(origin: .zero, size: viewport)
        var plans: [CellPlan] = []
        for index in 0..<min(lowerFrames.count, upperFrames.count) {
            let lower = lowerFrames[index].offsetBy(dx: 0, dy: -lowerOffset)
            let upper = upperFrames[index].offsetBy(dx: 0, dy: -upperOffset)
            let plan = CellPlan(
                index: index, lower: lower, upper: upper,
                visibleInLower: lower.intersects(bounds), visibleInUpper: upper.intersects(bounds))
            if plan.role != .absent { plans.append(plan) }
        }
        return plans
    }

    /// A layout's cell frame under the zoom. Each level's layout is zoomed rigidly about `pivot` (the grid's leading edge at
    /// the anchor's y) by the ratio of the pinch's cover width to that layout's own, so both layouts of a segment show
    /// covers of the same width at every progress and the crossfade hides a reflow, not a collision. At a level's own width
    /// the scale is 1.
    static func zoomed(_ rest: CGRect, scale: CGFloat, pivot: CGPoint) -> CGRect {
        CGRect(
            x: pivot.x + (rest.minX - pivot.x) * scale, y: pivot.y + (rest.minY - pivot.y) * scale,
            width: rest.width * scale, height: rest.height * scale)
    }

    enum Entry: Sendable { case fromLower, fromUpper }

    /// The upper rendering's weight at `progress` (the lower's is `1 −` this): a smoothstep over 15 % to 35 % of the way
    /// in from the end the pinch entered at.
    static func upperWeight(progress p: CGFloat, entry: Entry) -> CGFloat {
        let window: ClosedRange<CGFloat> = entry == .fromLower ? 0.15...0.35 : 0.65...0.85
        let x = min(1, max(0, (p - window.lowerBound) / (window.upperBound - window.lowerBound)))
        return x * x * (3 - 2 * x)
    }

    /// The opacities (lower rendering, upper rendering) of a cell. An edge cell keeps one rendering at full opacity; an
    /// interior pair always sums to 1 (no dip through the page). A rendering that is not ready (covers not decoded) is
    /// never faded in: the ready one keeps zooming alone.
    static func opacities(
        _ plan: CellPlan, progress p: CGFloat, entry: Entry, upperReady: Bool = true,
        lowerReady: Bool = true
    ) -> (lower: CGFloat, upper: CGFloat) {
        switch plan.role {
        case .lowerEdge: return (1, 0)
        case .upperEdge: return (0, 1)
        case .absent: return (0, 0)
        case .interior:
            let weight: CGFloat
            if !upperReady {
                weight = 0
            } else if !lowerReady {
                weight = 1
            } else {
                weight = upperWeight(progress: p, entry: entry)
            }
            return (1 - weight, weight)
        }
    }

    // MARK: - Release

    /// The level a release settles on: the coordinate projected a short way along `velocity` (levels per second), then
    /// rounded, so position and flick both decide. `commitPoint` is the fraction of the way to the next level at which
    /// the release commits to it (0.5 is plain rounding).
    static func settleLevel(
        coordinate t: CGFloat, velocity: CGFloat, levels: Int, lookahead: CGFloat = 0.12,
        commitPoint: CGFloat = 0.5
    ) -> Int {
        let projected = t + velocity * lookahead
        let base = projected.rounded(.down)
        let level = Int(base) + (projected - base >= commitPoint ? 1 : 0)
        return min(max(0, levels - 1), max(0, level))
    }

    /// A spring from `from` to `to` that starts at the finger's velocity, so there is no jump on release. The closed-form
    /// underdamped oscillator, so it can be sampled at any time and a new pinch can read where it was interrupted.
    struct Spring: Equatable, Sendable {
        /// The release spring's feel: a lower damping ratio overshoots more; a lower omega makes every release longer.
        static let springOmega: CGFloat = 7.5
        static let springZeta: CGFloat = 0.55

        var from: CGFloat
        var to: CGFloat
        var velocity: CGFloat
        var omega: CGFloat = springOmega
        var zeta: CGFloat = springZeta

        init(from: CGFloat, to: CGFloat, velocity: CGFloat) {
            self.from = from
            self.to = to
            self.velocity = velocity
        }

        func value(at time: CGFloat) -> CGFloat {
            let x0 = from - to
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega * time)
            let c = (velocity + zeta * omega * x0) / wd
            return to + decay * (x0 * cos(wd * time) + c * sin(wd * time))
        }

        /// How far through its move the spring is at `time`: 0 at the start, 1 at the target, past 1 while it overshoots
        /// (the page offset's settle rides it). 1 when there is nowhere to go.
        func progress(at time: CGFloat) -> CGFloat {
            guard abs(to - from) > 1e-4 else { return 1 }
            return (value(at: time) - from) / (to - from)
        }

        func speed(at time: CGFloat) -> CGFloat {
            let h: CGFloat = 0.002
            let before = max(0, time - h)
            return abs(value(at: time + h) - value(at: before)) / (time + h - before)
        }

        /// Whether the motion is below a visible threshold: near the target AND nearly still (position alone would cut
        /// off an overshooting release at its first pass through the target).
        func isSettled(at time: CGFloat) -> Bool {
            abs(value(at: time) - to) < 0.004 && speed(at: time) < Self.settledSpeed && time > 0.1
        }

        static let settledSpeed: CGFloat = 0.02
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}

/// The zoom's crossfades: each segment (the stretch between two adjacent levels) has a midpoint trigger that sets off
/// its own fade. Fades of different segments run concurrently, and a pinch that turns back across a midpoint reverses
/// that fade where it is.
///
/// Every fade runs at one shared rate (shares per second) = the base rate + the gain × the low-passed pinch speed above a
/// crawl, its change limited per second (`rateSlew`). The state is one `share` per segment (0: the lower level shows, 1:
/// the upper) moving linearly toward its target; `position` adds the eased shares into one coordinate on the level axis,
/// which is all a renderer needs: the two levels around it and how far between them.
struct GridZoomFades: Sendable {

    // MARK: - Constants

    static let midpoint: CGFloat = 0.5
    static let hysteresis: CGFloat = 0.03
    /// A fade's duration at a slow pinch and at a fast one, in seconds; never outside them.
    static let slow: CGFloat = 0.7
    static let fast: CGFloat = 0.2
    static let slowSpeed: CGFloat = 0.5
    static let fastSpeed: CGFloat = 1.75

    /// How long a DIRECT fade (the menu / keyboard step, no pinch) begun at `speed` (levels per second)
    /// takes: `slow` at a crawl, `fast` at a flick, 1 / speed in between.
    static func duration(forSpeed speed: CGFloat, scale: CGFloat = 1) -> CGFloat {
        let s = max(abs(speed), 0.001)
        return scale * min(slow, max(fast, slow * slowSpeed / s))
    }

    static var baseRate: CGFloat { 1 / slow }
    static var maxRate: CGFloat { 1 / fast }
    /// What a unit of pinch speed above `slowSpeed` adds to the rate: the slope that makes the steady-state rate equal
    /// `1 / duration(forSpeed:)` between the two speeds.
    static var shippedGain: CGFloat { (maxRate - baseRate) / (fastSpeed - slowSpeed) }
    static let rateSlew: CGFloat = 40

    /// The rate the pinch speed asks for, never past `maxRate`; `gain` 0 is a fade on time alone.
    static func targetRate(forSpeed speed: CGFloat, gain: CGFloat = 1) -> CGFloat {
        min(maxRate, baseRate + gain * shippedGain * max(0, abs(speed) - slowSpeed))
    }

    // The page GEOMETRY (row tops, page offset) does not run these fades: it follows the pinch's coordinate
    // itself. Only the opacities fade on a clock.

    static func eased(_ share: CGFloat) -> CGFloat {
        let x = min(1, max(0, share))
        return x * x * (3 - 2 * x)
    }

    // MARK: - State

    private(set) var shares: [CGFloat]
    private(set) var targets: [CGFloat]
    let scale: CGFloat
    let smoothing: CGFloat
    let gain: CGFloat
    /// The fades' common rate (shares per second, before `scale`), and the pinch speed last told to them, low-passed.
    private(set) var rate: CGFloat
    private(set) var filteredSpeed: CGFloat = 0
    private var speedInput: CGFloat = 0
    /// The blend: the picture on screen when the fades were last re-aimed, the level they now head for, the position then,
    /// and how far the destination has come in over that picture (monotone, 0 … 1). See `blend`.
    var blendBase: GridZoomBlend
    var blendDestination: Int
    var blendAimPosition: CGFloat
    /// The segments' shares when the blend was aimed: where the position cannot tell the travel (two fades
    /// in opposite directions leave it where it was), the shares' own travel does (`blendTravel`).
    var blendAimShares: [CGFloat]
    var blendProgress: CGFloat = 1

    /// `count` levels, the zoom beginning on `level`: the segments below it are done.
    init(
        count: Int, level: Int, scale: CGFloat = 1,
        smoothing: CGFloat = GridZoomFeel.fadeSmoothing,
        gain: CGFloat = GridZoomFeel.fadeSpeedGain
    ) {
        self.scale = scale
        self.smoothing = smoothing
        self.gain = gain
        rate = Self.baseRate
        let segments = max(0, count - 1)
        shares = (0..<segments).map { $0 < level ? 1 : 0 }
        targets = shares
        let origin = min(max(0, level), segments)
        blendBase = .level(origin)
        blendDestination = origin
        blendAimPosition = CGFloat(origin)
        blendAimShares = shares
    }

    var segments: Int { shares.count }
    var isSettled: Bool { zip(shares, targets).allSatisfy { $0 == $1 } }

    var position: CGFloat { shares.reduce(0) { $0 + Self.eased($1) } }

    var destination: Int { Int(targets.reduce(0, +).rounded()) }

    /// Which two levels to draw, and the upper's weight over the lower, for the pinch's coordinate `t`: the pair around the
    /// fade position while a fade is in flight, else the pair around `t` (so arriving cells are there before a fade starts).
    func pair(t: CGFloat) -> (lower: Int, upper: Int, weight: CGFloat) {
        guard segments >= 1 else { return (0, 0, 0) }
        let p = position
        let last = segments  // the top level index
        let inFlight = abs(p - p.rounded()) > 1e-4
        if inFlight {
            let lower = min(segments - 1, max(0, Int(p.rounded(.down))))
            return (lower, lower + 1, min(1, max(0, p - CGFloat(lower))))
        }
        return restingPair(min(last, max(0, Int(p.rounded()))), t: t)
    }

    /// The pair drawn when `level` is fully shown and the pinch is at `t`: the level and its neighbour on `t`'s side,
    /// waiting at weight 0 or 1 so the neighbour's arriving cells are in place.
    func restingPair(_ level: Int, t: CGFloat) -> (lower: Int, upper: Int, weight: CGFloat) {
        guard segments >= 1 else { return (0, 0, 0) }
        let around = min(segments - 1, max(0, Int(t.rounded(.down))))
        if level == around { return (around, around + 1, 0) }
        if level == around + 1 { return (around, around + 1, 1) }
        return level < around ? (level, level + 1, 0) : (level - 1, level, 1)
    }

    private mutating func reaim(from before: [CGFloat], drawn: GridZoomBlend) {
        guard targets != before else { return }
        blendBase = drawn.normalized()
        blendDestination = min(segments, max(0, destination))
        blendAimPosition = position
        blendAimShares = shares
        blendProgress = 0
    }

    // MARK: - Driving

    /// Sets off, reverses or holds every segment's fade for the coordinate `t`: a segment's target is 1 once `t` is past its
    /// midpoint (plus hysteresis), 0 once back before it. `speed` feeds the fades' shared rate (`advance`).
    mutating func update(t: CGFloat, speed: CGFloat) {
        let before = targets
        let drawn = blendNow
        defer { reaim(from: before, drawn: drawn) }
        speedInput = abs(speed)
        for s in 0..<segments {
            let mid = CGFloat(s) + Self.midpoint
            var target = targets[s]
            if t > mid + Self.hysteresis {
                target = 1
            } else if t < mid - Self.hysteresis {
                target = 0
            }
            targets[s] = target
        }
    }

    mutating func force(_ level: Int, speed: CGFloat) {
        let before = targets
        let drawn = blendNow
        defer { reaim(from: before, drawn: drawn) }
        speedInput = abs(speed)
        for s in 0..<segments { targets[s] = s < level ? 1 : 0 }
    }

    /// Runs every fade on for `dt` seconds at the common rate, which follows the low-passed pinch speed (`speed`, levels per
    /// second; omitted, the last one told stands) with its change limited per second. Called every frame, also while no
    /// fade runs, so a fade set off by a flick starts at the rate the flick has built up.
    mutating func advance(by dt: CGFloat, speed: CGFloat? = nil) {
        if let speed { speedInput = abs(speed) }
        let k = smoothing > 0 ? 1 - CGFloat(exp(Double(-dt / smoothing))) : 1
        filteredSpeed += (speedInput - filteredSpeed) * k
        let wanted = Self.targetRate(forSpeed: filteredSpeed, gain: gain)
        let limit = Self.rateSlew * dt
        rate += min(limit, max(-limit, wanted - rate))
        for s in 0..<segments where shares[s] != targets[s] {
            let step = dt * rate / scale
            shares[s] =
                shares[s] < targets[s]
                ? min(targets[s], shares[s] + step) : max(targets[s], shares[s] - step)
        }
        blendProgress = max(blendProgress, blendTravel())
        if isSettled {
            let origin = min(segments, max(0, Int(position.rounded())))
            blendBase = .level(origin)
            blendDestination = origin
            blendAimPosition = CGFloat(origin)
            blendAimShares = shares
            blendProgress = 1
        }
    }
}

/// What a zoom frame draws: a pair, and any levels fading in over it. A fade re-aimed in flight keeps everything on screen
/// and fades the new target in over it: the pair underneath keeps the weights it had at the re-aim and each overlay is
/// drawn at its own alpha over everything below it, so every level's share moves continuously. A re-aim back to a level
/// already drawn raises that level in place.
///
/// Geometry is mixed the same way (`mix`): every quantity placed by a pair's weight (row tops, page offset, page height) is
/// linear in it, so the blended value is the pair's, then each overlay's laid over it at its alpha.
struct GridZoomBlend: Sendable, Equatable {

    struct Overlay: Sendable, Equatable {
        var level: Int
        var alpha: CGFloat

        init(level: Int, alpha: CGFloat) {
            self.level = level
            self.alpha = alpha
        }
    }

    /// The pair underneath, as the renderer draws a pair: `lower`'s covers are the backdrop, `upper`
    /// fades over them at `weight`.
    var lower: Int
    var upper: Int
    var weight: CGFloat
    var overlays: [Overlay]

    init(lower: Int, upper: Int, weight: CGFloat, overlays: [Overlay] = []) {
        self.lower = lower
        self.upper = upper
        self.weight = weight
        self.overlays = overlays
    }

    init(_ pair: (lower: Int, upper: Int, weight: CGFloat)) {
        self.init(lower: pair.lower, upper: pair.upper, weight: pair.weight)
    }

    static func level(_ level: Int) -> GridZoomBlend {
        GridZoomBlend(lower: level, upper: level, weight: 0)
    }

    var pair: (lower: Int, upper: Int, weight: CGFloat) { (lower, upper, weight) }

    var levels: [Int] {
        var out = [lower]
        if upper != lower { out.append(upper) }
        for overlay in overlays where !out.contains(overlay.level) { out.append(overlay.level) }
        return out
    }

    var single: Int? {
        guard overlays.allSatisfy({ $0.alpha <= 0 }) else { return nil }
        if lower == upper || weight <= 0 { return lower }
        return weight >= 1 ? upper : nil
    }

    /// How much of the picture `level` is: its share of the pair times what every overlay above it leaves showing.
    func share(of level: Int) -> CGFloat {
        var share: CGFloat = 0
        if level == lower { share += lower == upper ? 1 : 1 - weight }
        if level == upper, upper != lower { share += weight }
        for overlay in overlays {
            share *= 1 - overlay.alpha
            if overlay.level == level { share += overlay.alpha }
        }
        return share
    }

    /// The same blend with coordinate indices turned into level indices (`steps[k]` is the level at coordinate `k`).
    func mapped(through steps: [Int]) -> GridZoomBlend {
        guard let last = steps.indices.last else { return self }
        func level(_ k: Int) -> Int { steps[min(last, max(0, k))] }
        var out = self
        out.lower = level(lower)
        out.upper = level(upper)
        out.overlays = overlays.map { Overlay(level: level($0.level), alpha: $0.alpha) }
        return out
    }

    /// A quantity placed by a pair's weight, for the whole blend: the pair's value, then each overlay's own laid over it.
    func mix(
        pair: (_ lower: Int, _ upper: Int, _ weight: CGFloat) -> CGFloat,
        level: (Int) -> CGFloat
    ) -> CGFloat {
        var value = pair(lower, upper, weight)
        for overlay in overlays where overlay.alpha > 0 {
            value += (level(overlay.level) - value) * overlay.alpha
        }
        return value
    }

    /// The picture as `destination` fades in over it, `progress` of the way (0 … 1): everything already drawn keeps its
    /// weights and goes down in proportion; at 1 the destination shows alone. A destination already in the blend rises in place.
    func aimed(at destination: Int, progress: CGFloat) -> GridZoomBlend {
        let c = min(1, max(0, progress))
        if let alone = single {
            if alone == destination { return .level(alone) }
            return destination > alone
                ? GridZoomBlend(lower: alone, upper: destination, weight: c)
                : GridZoomBlend(lower: destination, upper: alone, weight: 1 - c)
        }
        var next = self
        var present = false
        for index in next.overlays.indices {
            if next.overlays[index].level == destination {
                next.overlays[index].alpha += (1 - next.overlays[index].alpha) * c
                present = true
            } else {
                next.overlays[index].alpha *= 1 - c
            }
        }
        if destination == lower, lower != upper {
            next.weight = weight * (1 - c)
            present = true
        } else if destination == upper {
            next.weight = weight + (1 - weight) * c
            present = true
        }
        if !present { next.overlays.append(Overlay(level: destination, alpha: c)) }
        return next.normalized()
    }

    /// The same picture, minimal: overlays that show nothing are dropped, one that shows fully hides
    /// everything below it, and a blend that is one level is that level.
    func normalized() -> GridZoomBlend {
        var next = self
        next.overlays.removeAll { $0.alpha <= 1e-6 }
        if let top = next.overlays.lastIndex(where: { $0.alpha >= 1 - 1e-6 }) {
            let level = next.overlays[top].level
            let above = Array(next.overlays[(top + 1)...])
            next = .level(level)
            next.overlays = above
        }
        if next.overlays.isEmpty, let alone = next.single, next.lower != next.upper {
            return .level(alone)
        }
        return next
    }
}

extension GridZoomFades {

    /// The blend to draw for the coordinate `t`: `pair(t:)` outside a flight; in flight, the picture drawn when the fades
    /// were last re-aimed with the destination faded in over it, as far as the position has travelled to it. A blend that
    /// has become one level is drawn as that level at rest (a pair of a level with itself would draw nothing).
    func blend(t: CGFloat) -> GridZoomBlend {
        guard segments >= 1, !isSettled else { return GridZoomBlend(pair(t: t)) }
        let blend = blendBase.aimed(at: blendDestination, progress: blendProgress)
        if blend.overlays.isEmpty, blend.lower == blend.upper {
            return GridZoomBlend(restingPair(blend.lower, t: t))
        }
        return blend
    }

    /// The blend on screen now, as one level when the fades are settled (the re-aim's starting
    /// picture; the coordinate only decides which neighbour waits at weight 0 or 1).
    var blendNow: GridZoomBlend {
        guard segments >= 1, !isSettled else {
            return .level(min(segments, max(0, Int(position.rounded()))))
        }
        return blendBase.aimed(at: blendDestination, progress: blendProgress)
    }

    func blendTravel() -> CGFloat {
        let dest = CGFloat(blendDestination)
        let remaining = abs(dest - blendAimPosition)
        guard remaining > 1e-4 else {
            // The position is already at the destination (two fades in opposite directions cancel in it) but the picture
            // is not: its travel is the shares'.
            let total = zip(blendAimShares, targets).reduce(0) { $0 + abs($1.1 - $1.0) }
            guard total > 1e-6 else { return 1 }
            let done = zip(blendAimShares, shares).reduce(0) { $0 + abs($1.1 - $1.0) }
            return min(1, done / total)
        }
        let travelled =
            dest >= blendAimPosition ? position - blendAimPosition : blendAimPosition - position
        return min(1, max(0, travelled / remaining))
    }
}

/// The arithmetic of where a zoom lands. The mistakes it holds (screen vs content coordinates, insets, the
/// end-of-content clamp) are easy to make and invisible until a card jumps.
enum GridZoomGeometry {

    /// The scroll offset that lands the pinched item. `itemMinY` / `itemHeight` are its frame in the new layout (content
    /// coordinates), `screenY` where its top should sit measured from the top of the scroll view's bounds, the insets the
    /// adjusted ones (the bars). The wanted top is first kept inside the visible band, then the offset is clamped to the
    /// scrollable range (the grid stays top-filled, never a gap).
    static func landingOffset(
        itemMinY: CGFloat, itemHeight: CGFloat, screenY: CGFloat,
        viewportHeight: CGFloat, contentHeight: CGFloat,
        topInset: CGFloat = 0, bottomInset: CGFloat = 0
    ) -> CGFloat {
        let lowestTop = max(topInset, viewportHeight - bottomInset - itemHeight)
        let top = min(lowestTop, max(topInset, screenY))
        let minOffset = -topInset
        let maxOffset = max(minOffset, contentHeight + bottomInset - viewportHeight)
        return min(maxOffset, max(minOffset, itemMinY - top))
    }
}

/// A picture the pinch has moved past is gone within a bound (otherwise a fast zoom in then out leaves a stale picture over
/// the arriving one). The crossfade runs on time, so a pinch crossing several levels faster than a fade runs leaves
/// pictures of levels it has left still drawn. A picture the geometry (the pair around the coordinate `t`) no longer holds,
/// and that is not where the fade is heading, is a leaver: it fades out on a smoothstep schedule of at most `bound`
/// seconds from the moment it left, and its share goes to the geometry's pair. A leaver that comes back inside the pair is
/// raised again along the same schedule, so no share moves in one frame. The arriving picture is never capped. With
/// nothing leaving, `blend` is the fades' own blend, bit for bit.
struct GridZoomLag: Sendable {

    var bound: CGFloat
    private var gone: [Int: CGFloat] = [:]

    init(bound: CGFloat = GridZoomFeel.fadeOutBound) { self.bound = bound }

    var isSettled: Bool { gone.isEmpty }

    static func pair(around t: CGFloat, count: Int) -> Set<Int> {
        guard count >= 2 else { return [0] }
        let (lower, _) = GridZoomTransition.segment(t, count: count)
        return [lower, lower + 1]
    }

    /// The share the GEOMETRY gives `level` at the coordinate `t` of `count` levels: the pair around `t`, split
    /// by the coordinate's place in its segment (a function of `t` alone).
    static func geometryShare(of level: Int, t: CGFloat, count: Int) -> CGFloat {
        let (lower, progress) = GridZoomTransition.segment(t, count: count)
        let upper = min(1, max(0, progress))
        if level == lower { return 1 - upper }
        return level == lower + 1 ? upper : 0
    }

    static func keeping(_ gone: CGFloat) -> CGFloat { 1 - GridZoomFades.eased(gone) }

    /// Runs the fade-outs on for `dt`: every level of the fades' blend that the pair and the destination do not hold goes on
    /// leaving, one they hold again comes back, one the blend no longer draws is forgotten.
    mutating func advance(by dt: CGFloat, fades: GridZoomFades, t: CGFloat) {
        let raw = fades.blend(t: t)
        let held = Self.held(fades: fades, t: t)
        let step = bound > 0 ? dt / bound : 1
        for level in raw.levels where raw.share(of: level) > 1e-6 || gone[level] != nil {
            let was = gone[level] ?? 0
            let next = held.contains(level) ? max(0, was - step) : min(1, was + step)
            if next > 0 { gone[level] = next } else { gone[level] = nil }
        }
        for level in Array(gone.keys) where raw.share(of: level) <= 1e-6 { gone[level] = nil }
    }

    /// The levels nothing may take away: the fades' destination and the pair's levels the geometry gives a share
    /// (the pair's other level, at zero share once the coordinate has reached an end or a level, is leaving).
    static func held(fades: GridZoomFades, t: CGFloat) -> Set<Int> {
        let count = fades.segments + 1
        var held = pair(around: t, count: count).filter { geometryShare(of: $0, t: t, count: count) > 1e-6 }
        if fades.segments >= 1 { held.insert(min(fades.segments, max(0, fades.destination))) }
        return held
    }

    /// The blend to draw for the coordinate `t`: the fades' own while no level is outside the geometry's pair; else the held
    /// levels as the fades drew them, the levels that left on top as overlays at their fade-out, and the geometry's pair
    /// taking what they give up. Pure: it reads the state `advance` keeps.
    ///
    /// The freed share goes to the pair around `t`, split the way the coordinate splits it (a function of `t` alone, so it
    /// is continuous whatever the fades do). A leaver is an overlay on top, never a backdrop: a pair's lower level is drawn
    /// opaque under the incoming fade, which only holds where both sit on one lattice, so a level the geometry has left
    /// would show as a stale picture and vanish in one frame.
    func blend(fades: GridZoomFades, t: CGFloat) -> GridZoomBlend {
        let raw = fades.blend(t: t)
        guard fades.segments >= 1 else { return raw }
        let held = Self.held(fades: fades, t: t)
        let leaving = raw.levels.filter { !held.contains($0) && raw.share(of: $0) > 1e-6 }
        guard !leaving.isEmpty || !gone.isEmpty else { return raw }
        let (lower, progress) = GridZoomTransition.segment(t, count: fades.segments + 1)
        let pair = [lower, lower + 1]
        let upperShare = min(1, max(0, progress))
        // The pair stays the stack's base (a pair's other level at zero share is still the pair's, fading out).
        var base = raw.levels.filter { held.contains($0) || pair.contains($0) }
        for level in pair + [min(fades.segments, max(0, fades.destination))] where !base.contains(level) { base.append(level) }
        let out = raw.levels.filter { !base.contains($0) }
        var share: [Int: CGFloat] = [:]
        var total: CGFloat = 0
        for level in base + out {
            let value = raw.share(of: level) * Self.keeping(gone[level] ?? 0)
            share[level] = value
            total += value
        }
        let freed = max(0, 1 - total)
        share[pair[0], default: 0] += freed * (1 - upperShare)
        share[pair[1], default: 0] += freed * upperShare
        let stacked = Self.stack(base: base, overlays: out, share: share, weight: raw.weight)
        // One level alone is drawn as that level at rest (`GridZoomFades.blend`: a bare level is no pair).
        if stacked.overlays.isEmpty, stacked.lower == stacked.upper {
            return GridZoomBlend(fades.restingPair(stacked.lower, t: t))
        }
        return stacked
    }

    /// The blend with these `share`s: `base` (bottom first) is the held levels - the first two the pair
    /// (lower index first, as the renderer draws it), any more overlays - then `overlays` on top, each at
    /// its share of everything up to it.
    static func stack(
        base: [Int], overlays: [Int], share: [Int: CGFloat], weight: CGFloat
    ) -> GridZoomBlend {
        var out: GridZoomBlend
        var total: CGFloat
        var rest = Array(base.dropFirst(min(2, base.count)))
        if base.count >= 2 {
            let a = min(base[0], base[1])
            let b = max(base[0], base[1])
            let sa = share[a] ?? 0
            let sb = share[b] ?? 0
            out = GridZoomBlend(
                lower: a, upper: b, weight: sa + sb > 1e-9 ? sb / (sa + sb) : weight)
            total = sa + sb
        } else {
            out = .level(base[0])
            total = share[base[0]] ?? 0
        }
        rest += overlays
        for level in rest {
            let s = share[level] ?? 0
            total += s
            out.overlays.append(.init(level: level, alpha: total > 1e-9 ? min(1, s / total) : 0))
        }
        return out.normalized()
    }
}

/// The grid zoom's feel: the release spring, the rubber band, the caps on how fast the picture catches quick fingers up,
/// and the crossfade's coupling to the pinch speed. Plain constants.
enum GridZoomFeel {
    /// Stretches the release spring's duration (its natural frequency is `springOmega / releaseScale`).
    static let releaseScale: CGFloat = 0.5
    /// The level-to-level release spring's damping ratio (lower = more overshoot).
    static let bounce: CGFloat = 0.65
    /// The slowest a release may launch, as a share of `omega x distance` toward the target: a slow release overshoots
    /// about as much as a quick pinch's.
    static let liveliness: CGFloat = 0.9
    /// How far ahead (seconds) the finger's velocity is projected when the release picks its level, and the fraction of
    /// the way to the next level that commits to it.
    static let commitLookahead: CGFloat = 0.12
    static let commitPoint: CGFloat = 0.5
    /// A pinch past the first or last level: how far the rubber band gives, and its release spring's damping and speed.
    static let rubberReach: CGFloat = GridZoomTransition.rubberBandGive
    static let rubberBounce: CGFloat = 0.9
    static let rubberResponse: CGFloat = 0.9
    /// Bounds on the picture catching quick fingers up: the speed a release carries into its spring (levels/s), the most it
    /// may move in the first frame of a pinch (levels), and its multiple of the pinch's own recent per-frame motion.
    static let speedLimit: CGFloat = 8
    static let catchUpFloor: CGFloat = 0.08
    static let catchUpGain: CGFloat = 2
    /// The crossfade's coupling to the pinch speed: the low-pass time (seconds) on the speed, what that speed adds to the
    /// base rate, and the longest a picture the zoom has moved past takes to fade out (seconds).
    static let fadeSmoothing: CGFloat = 0.06
    static let fadeSpeedGain: CGFloat = 0.6
    static let fadeOutBound: CGFloat = 0.1
    /// The width of the zone at a zoom's start that zooms from the centre, in percent of the grid's width (the sides
    /// split the rest equally).
    static let centreZone: CGFloat = 26

    /// Whether `coordinate` is stretched past the first or last of `levels` (the rubber band is out).
    static func isOverLimit(_ coordinate: CGFloat, levels: Int) -> Bool {
        coordinate < 0 || coordinate > CGFloat(max(0, levels - 1))
    }

    /// The natural frequency a release springs at: the level-to-level spring's, or the over-limit one's (scaled by
    /// `rubberResponse`) when the rubber band is out.
    static func omega(overLimit: Bool) -> CGFloat {
        GridZoomTransition.Spring.springOmega / releaseScale * (overLimit ? rubberResponse : 1)
    }

    static func geometryWeight(progress: CGFloat) -> CGFloat { min(1, max(0, progress)) }

    /// The level a release lets go at `coordinate` (moving at `velocity` levels/s) settles on: at most the adjacent one.
    static func settleLevel(coordinate: CGFloat, velocity: CGFloat, levels: Int) -> Int {
        let level = GridZoomTransition.settleLevel(
            coordinate: coordinate, velocity: velocity, levels: levels, lookahead: commitLookahead,
            commitPoint: commitPoint)
        let lower = Int(coordinate.rounded(.down))
        return min(max(0, levels - 1), max(0, min(max(level, lower), lower + 1)))
    }

    /// The velocity a release's spring starts at: the finger's, but never slower toward the target than
    /// `liveliness x omega x distance` (a from-rest spring on a small move reads as a slide that stops dead). `cap` bounds it.
    static func launchVelocity(
        from: CGFloat, to: CGFloat, velocity: CGFloat, cap: CGFloat, overLimit: Bool = false
    ) -> CGFloat {
        let distance = to - from
        guard abs(distance) > 1e-4 else { return velocity }
        let omega = omega(overLimit: overLimit)
        let direction: CGFloat = distance > 0 ? 1 : -1
        let minimum = min(cap, liveliness * omega * abs(distance))
        let toward = velocity * direction
        return toward >= minimum ? velocity : direction * minimum
    }

    static func spring(from: CGFloat, to: CGFloat, velocity: CGFloat, overLimit: Bool = false) -> GridZoomTransition.Spring {
        var spring = GridZoomTransition.Spring(from: from, to: to, velocity: velocity)
        spring.omega = omega(overLimit: overLimit)
        spring.zeta = overLimit ? rubberBounce : bounce
        return spring
    }
}

/// A pinch started in the middle of the grid zooms from the centre, two columns at a time. The pure decisions: which anchor
/// a start centroid picks, and which levels such a pinch steps through.
enum GridZoomCentre {

    /// The start centroid's anchor: the middle `centreZone` percent of the width is `.centre` (100 / 3 is equal thirds, 20
    /// gives 40 / 20 / 40), otherwise the side the fingers are on. `side` is what a centre pinch falls back to where it has
    /// no 2-step. Screen-left / right throughout: `.leading` / `.trailing` are the scene's physical columns and do not mirror.
    static func anchor(
        startX: CGFloat, width: CGFloat, centreZone: CGFloat = GridZoomFeel.centreZone
    ) -> (anchor: GridZoomScene.Anchor, side: GridZoomScene.Anchor) {
        let side: GridZoomScene.Anchor = startX > width / 2 ? .trailing : .leading
        let zone = min(100, max(0, centreZone)) / 100
        let lower = width * (1 - zone) / 2
        let upper = width - lower
        let middle = startX >= lower && startX <= upper
        return (middle ? .centre : side, side)
    }

    /// Each level's column count across a row `row` wide (the scene's own rule, `GridZoomScene.columnCount`; `gap` is the page's column gap).
    static func columnCounts(coverWidths: [CGFloat], row: CGFloat, gap: CGFloat) -> [Int] {
        coverWidths.map { max(1, Int(((row + gap) / ($0 + gap)).rounded())) }
    }

    /// The levels a pinch's coordinate runs over for its line: every level, except on `.centre` the 2-step `chain` from
    /// `start`. Nil for a centre line with no 2-step (the caller then uses the side).
    static func steps(
        anchor: GridZoomScene.Anchor, columns: [Int], start: Int
    ) -> [Int]? {
        guard anchor == .centre else { return Array(columns.indices) }
        return chain(columns: columns, start: start)
    }

    /// The levels a centre pinch steps through, as ascending indices into `columns` (one column count per level). From
    /// `start` each direction goes to the nearest level of the same column-count parity and on through that parity, so
    /// columns arrive and leave in pairs. A direction with none but with an adjacent level gets that level as a fallback;
    /// nil when neither direction has a 2-step.
    static func chain(columns: [Int], start: Int) -> [Int]? {
        guard columns.indices.contains(start) else { return nil }
        let parity = columns[start] % 2
        var chain = [start]
        var steps = 0
        for direction in [-1, 1] {
            var same: [Int] = []
            var index = start + direction
            while columns.indices.contains(index) {
                if columns[index] % 2 == parity { same.append(index) }
                index += direction
            }
            if !same.isEmpty {
                chain += same
                steps += 1
            } else if columns.indices.contains(start + direction) {
                chain.append(start + direction)
            }
        }
        return steps > 0 ? chain.sorted() : nil
    }
}

/// When a pinch clicks: one light click each time the level the pinch would land on if released now changes (at the commit
/// threshold, not when the grid visibly arrives), and one heavier bump when it enters the rubber band past the first or
/// last level. Pure: the shells only play what `update` returns.
struct GridZoomHapticDecider: Sendable {
    enum Event: Sendable, Equatable { case step, limit }

    /// How far past a level's half-way line the coordinate must go before the landing level changes
    /// (a finger hovering on the line never chatters), and how far past the end level the rubber band
    /// starts / how near the end level the pinch must come back to re-arm the limit bump.
    static let hysteresis: CGFloat = 0.06
    static let limitEnter: CGFloat = 0.04
    static let limitRearm: CGFloat = 0.02

    private var landing: Int
    private var limitArmed = true

    /// `level`: the coordinate's level at the pinch's begin.
    init(level: Int) { landing = level }
    /// The coordinate `t` (levels, rubber-banded past `0 ... count - 1`) moved: the clicks it earns.
    mutating func update(t: CGFloat, count: Int) -> [Event] {
        var events: [Event] = []
        let last = CGFloat(count - 1)
        let over = max(-t, t - last)
        if limitArmed, over > Self.limitEnter {
            limitArmed = false
            events.append(.limit)
        } else if !limitArmed, over < Self.limitRearm {
            limitArmed = true
        }
        let clamped = min(last, max(0, t))
        if abs(clamped - CGFloat(landing)) > 0.5 + Self.hysteresis {
            let next = Int(clamped.rounded())
            // One click per level crossed (a fast pinch over three levels is three clicks).
            events += Array(repeating: .step, count: abs(next - landing))
            landing = next
        }
        return events
    }
}
