// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import UIKit

// The zoomable grid's pinch (docs/zoomable-grid.md, section 3). A pinch is one
// session: every level's layout comes from LibraryGridLayoutModel (the live
// layout's own function), the cards are drawn by the session's stage
// (LibraryGridZoomStage.swift) while the real cells are hidden, the real scroll
// view follows the zoom, the levels crossfade mid-pinch, the ends rubber-band,
// and a release settles on a spring a new pinch can interrupt. The collection
// view's layout changes once, at the landing.

@MainActor
final class LibraryGridZoomSession {

    struct Level {
        let columns: Int
        let cardWidth: CGFloat
        let page: LibraryGridLevelPage
    }

    weak var host: LibraryGridHostController?
    /// Narrowest card first (most columns first). ALL of the page's levels.
    let levels: [Level]
    let startLevel: Int
    let slots: [Int]
    let fixedItems: [Int]
    let viewport: CGSize
    /// The pinch's coordinate runs over `steps` (`steps[k]` is the level at coordinate `k`): every level for a side line, the
    /// 2-step same-parity chain for the centre line (`GridZoomCentre.steps`). `levels` are always all of them.
    let steps: [Int]
    /// The pinched card (an index into `slots`) and its top in the visible bounds. The page's top-row hold may
    /// move them at the begin (`holdTopRowIfFloorBinds`); never after.
    private(set) var anchor: Int
    private(set) var anchorTop: CGFloat
    private(set) var scene: GridZoomScene!
    /// Per level: the offset the landing would use (the pinched card where it was, kept in the content), and how
    /// far the virtual offset is from it.
    private(set) var realOffsets: [CGFloat] = []
    private(set) var deltas: [CGFloat] = []
    var plans: [[Int]: GridZoomScene.Plan] = [:]
    var needed: [Set<Int>] = []
    let beginOffset: CGFloat
    let beginInsetTop: CGFloat
    let beginInsetBottom: CGFloat


    var baseT: CGFloat
    var t: CGFloat
    private(set) var fingerT: CGFloat
    private var stepEMA: CGFloat = 0
    private var movingFrames = 0
    var easedSinceTick = false
    var easeFloor: CGFloat { GridZoomFeel.catchUpFloor }
    var easeGain: CGFloat { GridZoomFeel.catchUpGain }
    static let settledFloor: CGFloat = 0.012
    static let establishedAfter = 6
    var lastScale: CGFloat = 1
    var fades: GridZoomFades
    var lag: GridZoomLag
    var settling = false
    var settleTarget: Int?
    var settleStart: CFTimeInterval = 0
    var link: CADisplayLink?
    private var linkProxy: LibraryGridLinkProxy?
    enum Motion {
        case spring(GridZoomTransition.Spring, start: CFTimeInterval)
        case linear(from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval)
    }
    var motion: Motion?
    var motionDone = false
    var lastTick: CFTimeInterval = 0
    var lastT: CGFloat
    var lastMoveTime: CFTimeInterval = CACurrentMediaTime()
    var speed: CGFloat = 0
    var displayVelocity: CGFloat = 0
    var shownShift: CGFloat = 0
    var clampShift: CGFloat = 0
    var shownOffset: CGFloat = 0
    var followsRealScroll = true
    private var holdingOffset = false
    var maxReleaseVelocity: CGFloat { GridZoomFeel.speedLimit }
    static let shiftDuration: CFTimeInterval = 0.25
    static let shiftOvershoot: CGFloat = 1.25

    var haptics = (decider: GridZoomHapticDecider(level: 0), player: GridZoomHapticPlayer.shared)

    var stage: LibraryGridZoomStage!

    var coordCount: Int { steps.count }
    var widths: [CGFloat] { steps.map { levels[$0].cardWidth } }
    func coordinate(ofLevel level: Int) -> Int? { steps.firstIndex(of: level) }
    var homeCoordinate: Int { coordinate(ofLevel: startLevel) ?? 0 }
    func inLevels(_ blend: GridZoomBlend) -> GridZoomBlend { blend.mapped(through: steps) }

    // MARK: Making one

    /// A session over the live page, or nil when there is nothing to zoom. The synchronous way (base, aim, session and plans
    /// inline), used by the picker and the release-before-ready fallback; a pinch normally comes through `LibraryGridZoomStartBuild`.
    static func make(host: LibraryGridHostController, at point: CGPoint, centreSteps: Bool = true) -> LibraryGridZoomSession? {
        guard let base = host.zoomStartBaseNow() else { return nil }
        let aim = GridZoomAim.pick(base: base, host: host, point: point, centreSteps: centreSteps)
        let session = LibraryGridZoomSession(host: host, base: base, aim: aim)
        session.makePlans()
        return session
    }

    /// The session over `base` aimed at `aim`, everything but the plans (`makePlans` / `apply(plans:)`); `layouts` when made ahead.
    init(host: LibraryGridHostController, base: GridZoomBase, aim: GridZoomAim, layouts: [GridZoomLevelLayout]? = nil) {
        self.host = host
        levels = base.levels
        startLevel = base.startLevel
        slots = base.slots
        fixedItems = base.fixedItems
        steps = aim.steps
        let collection = host.collectionView!
        viewport = collection.bounds.size
        let coordinate = aim.steps.firstIndex(of: base.startLevel) ?? 0
        baseT = CGFloat(coordinate); t = baseT; fingerT = baseT; lastT = baseT
        beginOffset = collection.contentOffset.y
        beginInsetTop = collection.adjustedContentInset.top
        beginInsetBottom = collection.adjustedContentInset.bottom
        shownOffset = beginOffset
        fades = GridZoomFades(count: aim.steps.count, level: coordinate)
        lag = GridZoomLag()
        haptics.decider = GridZoomHapticDecider(level: coordinate)
        anchor = aim.anchor
        anchorTop = aim.anchorTop
        makeScene(line: aim.line, side: aim.side, layouts: layouts)
        holdTopRowIfFloorBinds()
        computeLandingOffsets()
    }

    static func gridOrdinals(of host: LibraryGridHostController?) -> [Int] {
        var ordinal = 0
        return (host?.blocks ?? []).map { block in
            if case .grid = block.kind { ordinal += 1; return ordinal - 1 } else { return -1 }
        }
    }

    nonisolated static func makeLayouts(levels: [Level], slots: [Int], gridOrdinal: [Int]) -> [GridZoomLevelLayout] {
        let grids = gridOrdinal.filter { $0 >= 0 }.count
        return levels.map { level -> GridZoomLevelLayout in
            let result = level.page.result
            var sectionOf: [Int] = []
            sectionOf.reserveCapacity(slots.count)
            for (b, range) in result.ranges.enumerated() where gridOrdinal[b] >= 0 {
                sectionOf += Array(repeating: gridOrdinal[b], count: range.count)
            }
            return GridZoomLevelLayout(coverWidth: level.cardWidth, coverHeight: LibraryGridGeometry.coverHeight(cardWidth:),
                                       frames: slots.map { result.frames[$0] }, sectionOf: sectionOf,
                                       headers: Array(repeating: nil, count: grids), columnGap: LibraryGridGeometry.columnGap)
        }
    }

    private func makeScene(line: GridZoomScene.Anchor, side: GridZoomScene.Anchor, layouts made: [GridZoomLevelLayout]?) {
        let layouts = made ?? Self.makeLayouts(levels: levels, slots: slots, gridOrdinal: Self.gridOrdinals(of: host))
        scene = GridZoomScene(levels: layouts, anchorSlot: anchor, anchorTop: anchorTop,
                              columnGap: LibraryGridGeometry.columnGap, rowGap: LibraryGridGeometry.rowGap)
        scene.anchor = line
        scene.sideAnchor = side
        scene.row = host?.contentWidth ?? 0
    }

    /// Per level: the offset the real layout lands at (the pinched item where it was, kept inside the content), and the virtual one's distance from it.
    private func computeLandingOffsets() {
        realOffsets = levels.indices.map { level in
            guard level != startLevel else { return beginOffset }
            let frame = scene.levels[level].frames[anchor]
            return GridZoomGeometry.landingOffset(itemMinY: frame.minY, itemHeight: frame.height, screenY: anchorTop,
                                                  viewportHeight: viewport.height, contentHeight: levels[level].page.result.contentHeight,
                                                  topInset: beginInsetTop, bottomInset: beginInsetBottom)
        }
        deltas = levels.indices.map { $0 == startLevel ? 0 : scene.offsets[$0] - realOffsets[$0] }
    }

    /// The vertical anchor is the line that holds still: the pinched card's row, unless holding that row's screen y would need
    /// content above the page top at a neighbouring level; then it moves up to the lowest row of the card's section every
    /// neighbour can hold, ultimately the page's top row, which gains or loses cards as they reflow into it. Decided once at
    /// begin from the layouts: the picture never switches anchors mid-zoom, and the landing keeps the chosen row.
    private func holdTopRowIfFloorBinds() {
        guard let begin = scene.levels[safe: startLevel], begin.sectionOf.indices.contains(anchor),
              begin.rowOf.indices.contains(anchor) else { return }
        let section = begin.sectionOf[anchor]
        let cardRow = begin.rowOf[anchor]
        guard cardRow > 0, begin.sections.indices.contains(section) else { return }
        // The levels the coordinate can reach next to the start (the line's own steps).
        let at = steps.firstIndex(of: startLevel) ?? 0
        let neighbours = [at - 1, at + 1].filter { steps.indices.contains($0) }.map { steps[$0] }
        let floor = -beginInsetTop
        func binds(_ slot: Int, top: CGFloat) -> Bool {
            neighbours.contains { level in
                guard let frame = scene.levels[level].frames[safe: slot], frame.width > 0 else { return false }
                return frame.minY - top < floor - 0.5
            }
        }
        /// Whether most of `slot`'s row shows below the top bar (a top row scrolled out of sight has nothing to hold still).
        func shows(_ slot: Int, top: CGFloat) -> Bool {
            guard let frame = begin.frames[safe: slot], frame.height > 0 else { return false }
            let visible = min(top + frame.height, viewport.height) - max(top, beginInsetTop)
            return visible >= frame.height / 2
        }
        func candidate(_ row: Int) -> (slot: Int, top: CGFloat)? {
            guard let slot = begin.sections[section].rows[safe: row]?.slots.first, let frame = begin.frames[safe: slot] else { return nil }
            return (slot, frame.minY - beginOffset)
        }
        guard binds(anchor, top: anchorTop) else { return }
        for row in stride(from: cardRow, through: 0, by: -1) {
            guard let next = candidate(row) else { continue }
            if binds(next.slot, top: next.top) { continue }
            guard shows(next.slot, top: next.top) else { return }
            scene = scene.reanchored(slot: next.slot, top: next.top)
            anchor = next.slot
            anchorTop = next.top
            return
        }
    }

    struct PairPlan {
        var fromFades: [Bool]
        var toFades: [Bool]
        var fromCandidates: [Int]
        var toCandidates: [Int]
        var fromPaired: [Bool]
        var toPaired: [Bool]
    }

    func plan(from: Int, to: Int) -> PairPlan? {
        guard from != to, let plan = plans[[min(from, to), max(from, to)]] else { return nil }
        if from < to {
            return PairPlan(fromFades: plan.aFades, toFades: plan.bFades, fromCandidates: plan.aCandidates,
                            toCandidates: plan.bCandidates, fromPaired: plan.aPaired, toPaired: plan.bPaired)
        }
        return PairPlan(fromFades: plan.bFades, toFades: plan.aFades, fromCandidates: plan.bCandidates,
                        toCandidates: plan.aCandidates, fromPaired: plan.bPaired, toPaired: plan.aPaired)
    }

    // MARK: Showing it

    /// Shows the session over the collection view: the stage built (or its prepared views taken), the clock started, the first frame drawn.
    func present(over collection: UICollectionView, prepared stage: LibraryGridZoomStage? = nil) {
        self.stage = stage ?? LibraryGridZoomStage(session: self, collection: collection)
        self.stage.present()
        startLink()
        render()
    }

    // MARK: Gesture

    func pinch(scale: CGFloat) {
        guard !settling else { return }
        lastScale = scale
        let raw = GridZoomTransition.coordinate(base: baseT, scale: scale, widths: widths)
        fingerT = GridZoomTransition.rubberBand(raw, levels: coordCount, give: GridZoomFeel.rubberReach)
        // The clicks follow the FINGERS' level, not the crossfade.
        for event in haptics.decider.update(t: fingerT, count: coordCount) { haptics.player.play(event) }
        easeToFingers()
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        stepClock()
        render()
    }

    /// A pinch the bridge carried begins here: the fingers are already `scale` into the gesture and the live grid was scaled to
    /// follow them, so the coordinate starts where they are (an ease from rest would draw the session behind the picture it replaces).
    func seedPinch(scale: CGFloat) {
        placeAtFingers(scale: scale)
        haptics.decider = GridZoomHapticDecider(level: Int(fingerT.rounded()))
    }

    /// The coordinate at the fingers' scale, with no ease (`seedPinch`, and the bridge's frames: `bridgeFrame`).
    private func placeAtFingers(scale: CGFloat) {
        lastScale = scale
        let raw = GridZoomTransition.coordinate(base: baseT, scale: scale, widths: widths)
        fingerT = GridZoomTransition.rubberBand(raw, levels: coordCount, give: GridZoomFeel.rubberReach)
        t = fingerT
        lastT = fingerT
    }

    /// A bridge frame's placement by the session's own rule: before the stage is shown the live cells are placed where the
    /// session would put them at the fingers' `scale` (same coordinate, same pair's lattice, same page shift), so the frame the
    /// session draws on taking over is this frame. Needs only the scene.
    func bridgeFrame(scale: CGFloat) -> (placer: LibraryGridZoomFramePlacer, shift: CGFloat) {
        placeAtFingers(scale: scale)
        let width = GridZoomTransition.width(at: t, widths: widths)
        let geometry = frameGeometry()
        let pageTop = pageOffset(geometry, width: width)
        let placed = placedFrameShift(geometry, width: width, pageTop: pageTop)
        shownShift = placed.shift
        return placed
    }

    func slot(ofItem item: Int) -> Int? {
        var low = 0, high = slots.count
        while low < high {
            let mid = (low + high) / 2
            if slots[mid] < item { low = mid + 1 } else { high = mid }
        }
        return low < slots.count && slots[low] == item ? low : nil
    }

    /// The displayed coordinate follows the fingers, never faster than a frame may move it: a late frame leaves the fingers
    /// several frames ahead, and jumping there in one frame is a visible snap. The cap is a multiple of the recent per-frame
    /// motion, so a steady pinch never meets it.
    func easeToFingers() {
        let delta = fingerT - t
        guard delta != 0 else { stepEMA *= 0.7; return }
        movingFrames += 1
        let floor = movingFrames > Self.establishedAfter ? Self.settledFloor : easeFloor
        let cap = max(floor, easeGain * stepEMA)
        let step = abs(delta) <= cap ? delta : (delta < 0 ? -cap : cap)
        t += step
        stepEMA = stepEMA * 0.7 + abs(step) * 0.3
        easedSinceTick = true
    }

    /// Picks up a settle that was running when a new pinch began inside it. The session goes on about the same line it began
    /// with, wherever the new fingers are (a mid-zoom side switch would show a slide, a snap or a double); the new fingers'
    /// side picks the line of the next fresh zoom.
    func interrupt() {
        stopMotion()
        settling = false
        settleTarget = nil
        baseT = t
        fingerT = t
        lastScale = 1
        movingFrames = 0
        haptics.decider = GridZoomHapticDecider(level: Int(t.rounded()))
    }

    func release(velocity: CGFloat, cancelled: Bool) {
        guard !settling else { return }
        let (lower, _) = GridZoomTransition.segment(t, count: coordCount)
        let span = log(widths[lower + 1] / widths[lower])
        let inRange = t >= 0 && t <= CGFloat(coordCount - 1)
        let raw = inRange && span > 0 ? velocity / max(0.2, lastScale) / span : 0
        let levelVelocity = min(maxReleaseVelocity, max(-maxReleaseVelocity, raw))
        var landing = homeCoordinate
        if !cancelled { landing = GridZoomFeel.settleLevel(coordinate: t, velocity: levelVelocity, levels: coordCount) }
        let carried = min(maxReleaseVelocity, max(-maxReleaseVelocity, displayVelocity))
        settle(to: landing, velocity: carried)
    }

    func settle(to level: Int, velocity: CGFloat) {
        settling = true
        settleTarget = level
        stage.prefetch(level: steps[level])
        stage.prioritizeLabels(landing: steps[level])
        motionDone = false
        let now = CACurrentMediaTime()
        settleStart = now
        fades.force(level, speed: speed)
        if UIAccessibility.isReduceMotionEnabled {
            motion = .linear(from: t, to: CGFloat(level), start: now, duration: 0.15)
        } else {
            // However slowly it was let go the settle launches at least `liveliness` of the way; a release with the rubber band
            // out springs on its own curve.
            let over = GridZoomFeel.isOverLimit(t, levels: coordCount)
            let launch = GridZoomFeel.launchVelocity(from: t, to: CGFloat(level), velocity: velocity, cap: maxReleaseVelocity, overLimit: over)
            motion = .spring(GridZoomFeel.spring(from: t, to: CGFloat(level), velocity: launch, overLimit: over), start: now)
        }
    }

    /// How far the settle has brought the offset back into bounds, 0 ... 1 (0 with the fingers down). It rides the release
    /// spring, overshooting with it a little; a settle with nowhere to go on the level axis and the Reduce Motion path keep a
    /// short smoothstep.
    var settleShift: CGFloat {
        guard settling else { return 0 }
        let now = CACurrentMediaTime()
        if case .spring(let spring, let start)? = motion, abs(spring.to - spring.from) > 0.02 {
            return min(Self.shiftOvershoot, max(0, spring.progress(at: CGFloat(now - start))))
        }
        let x = min(1, max(0, CGFloat((now - settleStart) / Self.shiftDuration)))
        return x * x * (3 - 2 * x)
    }

    var shiftSettled: Bool {
        guard settling, let target = settleTarget else { return true }
        if abs(deltas[steps[target]] - shownShift) <= 0.5 { return true }
        if case .spring(let spring, _)? = motion, abs(spring.to - spring.from) > 0.02 { return motionDone }
        return CACurrentMediaTime() - settleStart >= Self.shiftDuration
    }

    // MARK: The clock

    func startLink() {
        guard link == nil else { return }
        let proxy = LibraryGridLinkProxy { [weak self] in self?.tick() }
        let link = CADisplayLink(target: proxy, selector: #selector(LibraryGridLinkProxy.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        linkProxy = proxy
        lastTick = CACurrentMediaTime()
    }

    func stepClock() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        guard dt > 0.0005 else { return }
        // The speed is measured between the frames the coordinate moved in (a tick between two touch events says nothing).
        if t != lastT {
            let span = max(0.004, now - lastMoveTime)
            displayVelocity = (t - lastT) / CGFloat(span)
            speed = speed * 0.7 + abs(displayVelocity) * 0.3
            lastT = t
            lastMoveTime = now
        } else if now - lastMoveTime > 0.08 {
            displayVelocity = 0
            speed *= 0.7
        }
        if !settling { fades.update(t: t, speed: speed) }
        fades.advance(by: CGFloat(dt), speed: speed)
        lag.advance(by: CGFloat(dt), fades: fades, t: t)
    }

    private func tick() {
        if settling, !motionDone, let motion, let target = settleTarget {
            let now = CACurrentMediaTime()
            switch motion {
            case .spring(let spring, let start):
                let elapsed = CGFloat(now - start)
                t = spring.value(at: elapsed)
                // The cap: e^-8 of the amplitude, whatever the feel's pace.
                let cap = 8 / max(0.5, spring.zeta * spring.omega)
                motionDone = spring.isSettled(at: elapsed) || elapsed > cap
            case .linear(let from, let to, let start, let duration):
                let x = min(1, CGFloat((now - start) / duration))
                t = from + (to - from) * x * x * (3 - 2 * x)
                motionDone = x >= 1
            }
            if motionDone { t = CGFloat(target) }
        }
        // A frame the pinch did not update in (it was late, or the fingers are still) finishes any easing it owes.
        if !settling {
            if !easedSinceTick, t != fingerT { easeToFingers() }
            easedSinceTick = false
        }
        stepClock()
        render()
        stage.upgradeCovers()
        // Lands when the MOTION lands: the spring, the offset shift, every fade.
        if settling, motionDone, fades.isSettled, lag.isSettled, shiftSettled, let target = settleTarget {
            stopMotion()
            host?.finishZoom(self, landingOn: steps[target])
        }
    }

    func stopMotion() {
        motion = nil
        motionDone = false
    }

    func abandon() {
        guard let host else { return }
        stopMotion()
        let coordinate = min(coordCount - 1, max(0, Int(t.rounded())))
        host.finishZoom(self, landingOn: steps[coordinate], abandoned: true)
    }

    // MARK: The page offset

    func pageOffset(_ blend: GridZoomBlend, width: CGFloat) -> CGFloat {
        let ch = LibraryGridGeometry.coverHeight(cardWidth:)
        return blend.mix(pair: { scene.pageOffset($0, $1, width: width, blend: $2, coverHeight: ch) },
                         level: { scene.pageOffset($0, $0, width: width, blend: 0, coverHeight: ch) })
    }

    func virtualPageHeight(_ blend: GridZoomBlend, width: CGFloat) -> CGFloat {
        let ys = levels.map(\.page.result.contentHeight)
        let rows = levels.indices.map { scene.rows(above: Int.max, level: $0) }
        let ch = LibraryGridGeometry.coverHeight(cardWidth:)
        func height(_ a: Int, _ b: Int, _ w: CGFloat) -> CGFloat {
            scene.virtualY(a, b, ys: ys, rowsAbove: rows, width: width, blend: w, coverHeight: ch)
        }
        return blend.mix(pair: height, level: { height($0, $0, 0) })
    }

    /// The shift that keeps the shown offset inside the blended page (top: minus the top inset; bottom: the blended height minus
    /// the viewport plus the bottom inset), easing to the landed level's own while settling. `drawnTop`: the top clamp on the
    /// rows as drawn.
    func frameShift(pageTop: CGFloat, blend: GridZoomBlend, width: CGFloat, drawnTop: CGFloat = 0) -> CGFloat {
        clampShift = clampAmount(pageTop: pageTop, height: virtualPageHeight(blend, width: width))
        if clampShift <= 0 { clampShift = min(clampShift, drawnTop) }
        guard settling, let target = settleTarget else { return clampShift }
        return clampShift + (deltas[steps[target]] - clampShift) * settleShift
    }

    /// The frame's placer and its shift. The placer is built first (the drawn first rows decide the top clamp); its window is
    /// last frame's shift plus a margin, so a frame whose shift moved a little still has every cell it draws. The shift is
    /// floored (`floorShift`): content is never pulled down past the page top.
    func placedFrameShift(_ geometry: GridZoomBlend, width: CGFloat, pageTop: CGFloat)
        -> (placer: LibraryGridZoomFramePlacer, shift: CGFloat)
    {
        let placer = LibraryGridZoomFramePlacer(
            scene: scene, geometry: geometry, width: width,
            window: (-shownShift - 1.5 * viewport.height - 200)...(-shownShift + 2.5 * viewport.height + 200))
        let eased = frameShift(pageTop: pageTop, blend: geometry, width: width,
                               drawnTop: drawnTopClamp(geometry, placer: placer))
        return (placer, floorShift(eased, pageTop: pageTop))
    }

    /// The real offset for the zoom's page offset: the same fraction of the way down the real (start level's) extent, so the
    /// scroll indicator and the edge blur read an in-range position.
    func realOffset(pageTop: CGFloat, blend: GridZoomBlend, width: CGFloat, in collection: UICollectionView) -> CGFloat {
        let height = virtualPageHeight(blend, width: width)
        let extra = height - levels[startLevel].page.result.contentHeight
        let low = -beginInsetTop
        let high = height + beginInsetBottom - viewport.height
        let fraction = high > low ? min(1, max(0, (pageTop - low) / (high - low))) : 0
        var base = pageTop - fraction * extra
        if !settling {
            let realMax = collection.contentSize.height + beginInsetBottom - collection.bounds.height
            if realMax > low { base = min(base, realMax) }
        }
        return base
    }

    func realScrolled() {
        guard followsRealScroll, !holdingOffset, let collection = host?.collectionView,
              abs(collection.contentOffset.y - shownOffset) > 0.01 else { return }
        holdingOffset = true
        defer { holdingOffset = false }
        collection.contentOffset = CGPoint(x: collection.contentOffset.x, y: shownOffset)
    }

    // MARK: Drawing

    func render() {
        stage?.render()
    }

    func teardown() {
        link?.invalidate()
        link = nil
        linkProxy = nil
        stopMotion()
        stage?.teardown()
    }

    func apply(plans set: GridZoomPlanSet) {
        plans = set.plans
        needed = set.needed
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

@MainActor final class LibraryGridNextFrame: NSObject {
    private var link: CADisplayLink?
    private let action: () -> Void
    private static var waiting: Set<LibraryGridNextFrame> = []
    private init(_ action: @escaping () -> Void) { self.action = action }
    static func run(_ action: @escaping () -> Void) {
        let next = LibraryGridNextFrame(action)
        let link = CADisplayLink(target: next, selector: #selector(fire))
        link.add(to: .main, forMode: .common)
        next.link = link
        waiting.insert(next)
    }
    @objc private func fire() {
        link?.invalidate()
        link = nil
        Self.waiting.remove(self)
        action()
    }
}

final class LibraryGridLinkProxy: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

// MARK: - The host's side

extension LibraryGridHostController: UIGestureRecognizerDelegate {
    func installPinch() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        collectionView.addGestureRecognizer(pinch)
        let tracker = LibraryGridTouchTracker { [weak self] in self?.multiTouchChanged($0) }
        tracker.onTwoFingers = { [weak self] location in MainActor.assumeIsolated { self?.noteTwoFingersDown(at: location) } }
        tracker.delegate = self
        collectionView.addGestureRecognizer(tracker)
    }

    /// The multi-touch gate: true from a second finger's landing until every finger is up.
    /// Nothing opens while it is true, and any card's press is released at once.
    private func multiTouchChanged(_ now: Bool) {
        if now {
            multiTouch = true
            for cell in collectionView.visibleCells where cell.isHighlighted { cell.isHighlighted = false }
            for path in collectionView.indexPathsForSelectedItems ?? [] { collectionView.deselectItem(at: path, animated: false) }
        } else {
            // After the lifts' own selection pass (which runs in this same event).
            DispatchQueue.main.async { [weak self] in self?.multiTouch = false; self?.fingersAllUp() }
        }
    }

    /// A hosted element's SwiftUI gestures (a Button's, one UIKitResponderGestureRecognizer on the hosting view)
    /// begin on the first finger down and, left to the default, hold the pinch off. The pinch runs beside them,
    /// and `cancelCardGestures` cancels them the moment it begins, so nothing taps through.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if g is LibraryGridTouchTracker || other is LibraryGridTouchTracker { return true }
        return g is UIPinchGestureRecognizer && other.view !== collectionView && other.view?.isDescendant(of: collectionView) == true
    }

    /// Cancels every gesture of the cells (a recognizer disabled and enabled again ends what it was tracking), so a
    /// pinch's fingers do not tap anything when they lift.
    func cancelCardGestures() {
        func visit(_ view: UIView) {
            for g in view.gestureRecognizers ?? [] where !(g is UIPinchGestureRecognizer) { g.isEnabled = false; g.isEnabled = true }
            view.subviews.forEach(visit)
        }
        for cell in collectionView.visibleCells { visit(cell) }
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        return stops.count >= 2 && items.contains { if case .card = $0 { return true } else { return false } }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        let location = gesture.location(in: collectionView)
        let visible = CGPoint(x: location.x - collectionView.contentOffset.x, y: location.y - collectionView.contentOffset.y)
        switch gesture.state {
        case .began:
            cancelCardGestures()
            // The first frame follows the fingers before this returns: the session if one is ready, else the bridge
            // (LibraryGridZoomStart.swift). The recognizer's scale is rebased to 1 here; every later frame is measured from this one.
            guard pinchBegan(at: visible) else { return }
            gesture.scale = 1
        case .changed:
            // Two fingers lifting to one moves the centroid by half a hand: hold it.
            guard gesture.numberOfTouches >= 2 else { return }
            pinchChanged(scale: gesture.scale, at: visible)
        case .ended:
            pinchEnded(velocity: gesture.velocity, cancelled: false)
        default:
            pinchEnded(velocity: 0, cancelled: true)
        }
    }

    @discardableResult
    func beginZoom(at point: CGPoint, centreSteps: Bool = true) -> LibraryGridZoomSession? {
        if let running = zoom {
            guard running.settling else { return nil }
            running.interrupt()
            return running
        }
        if let ready = takeReadyZoomStart(at: point, centreSteps: centreSteps) {
            let session = attachZoom(ready)
            return session
        }
        // A start made for other fingers hands its views back before this one takes them.
        discardZoomStart()
        guard let session = LibraryGridZoomSession.make(host: self, at: point, centreSteps: centreSteps) else { return nil }
        let attached = attachZoom(session)
        return attached
    }

    /// A session begins: it becomes the zoom, the idle work stands down, the live grid is held still and the session is shown.
    @discardableResult
    func attachZoom(_ session: LibraryGridZoomSession) -> LibraryGridZoomSession {
        zoom = session
        session.haptics.player.prepare()
        cancelZoomIdleWork()
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
        collectionView.panGestureRecognizer.isEnabled = false
        LibraryCoverCache.shared.paused = true
        session.present(over: collectionView, prepared: session.stage)
        return session
    }

    /// The landing: the ONE real layout change of a zoom (when the level changed), the
    /// real cells back, the stage gone, the stored size written after the frame.
    func finishZoom(_ session: LibraryGridZoomSession, landingOn level: Int, abandoned: Bool = false) {
        guard zoom === session else { return }
        session.followsRealScroll = false
        let landed = session.levels[level]
        if level != session.startLevel {
            let anchorItem = session.slots[session.anchor]
            func landingOffset(_ page: LibraryGridLevelPage) -> CGFloat {
                let frame = page.result.frames[anchorItem]
                return GridZoomGeometry.landingOffset(itemMinY: frame.minY, itemHeight: frame.height, screenY: session.anchorTop,
                                                      viewportHeight: collectionView.bounds.height, contentHeight: page.result.contentHeight,
                                                      topInset: session.beginInsetTop, bottomInset: session.beginInsetBottom)
            }
            // A level laid out from estimates: the cards that land on or near the screen are measured now, so the real cells never show one.
            var page = landed.page
            if !page.exact, !abandoned {
                page = measuringWindow(levelPage(columns: landed.columns)) { landingOffset($0) }
            }
            commitColumns(landed.columns, page: page)
            // The offset first, then ONE layout pass: the layout is built where the page lands, so no cell is made for a region never shown.
            UIView.performWithoutAnimation {
                if !abandoned {
                    collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: landingOffset(page))
                }
                collectionView.layoutIfNeeded()
            }
        } else if !abandoned {
            collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: session.beginOffset)
        }
        // The zoom held the real offset `edgeHold` above the page's top: back onto it (the landing is a floor).
        session.snapToFloor(in: collectionView)
        // Inside the page's range at the current insets (they can change while a zoom runs).
        let top = -collectionView.adjustedContentInset.top
        let bottom = max(top, collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height)
        let clamped = min(bottom, max(top, collectionView.contentOffset.y))
        if abs(clamped - collectionView.contentOffset.y) > 0.5 {
            collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: clamped)
        }
        session.teardown()
        zoom = nil
        for case let cell as LibraryGridCardCell in collectionView.visibleCells { cell.releaseHeldWork() }   // work held while the zoom ran
        collectionView.panGestureRecognizer.isEnabled = true
        if level != session.startLevel {
            // The stored size follows once the layout is quiet (an observable write re-renders the page). The position is among
            // the levels the zoom ran on: after a rotation mid-zoom the current stops are another width's, where the landed
            // column count may not exist.
            let count = session.levels.count
            let position = LibraryGridGeometry.position(index: count - 1 - level, count: count)
            landedPosition = position
            writeLanded(position, cardWidth: landed.cardWidth)
        }
        zoomEnded()
    }
}

extension LibraryGridHostController {
    /// The stored size follows a landing once the page is quiet: the write re-renders the whole library page, so it never lands
    /// inside a frame of a zoom.
    func writeLanded(_ position: Double, cardWidth: CGFloat) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.landedPosition == position else { return }
            if self.zoom != nil { self.writeLanded(position, cardWidth: cardWidth); return }
            self.props?.landed(position, cardWidth)
        }
    }
}



/// Watches the touches on the collection view and never recognises, delays or cancels one. It says when a second finger lands
/// and when the last one lifts (`changed`: the multi-touch gate), and reports the centroid of a pinch's two fingers as they
/// land (`onTwoFingers`), before the pinch recognizer begins (it waits for the fingers to move), so the zoom's start can
/// already be built. Fingers down are derived from the touches' own phases, never counted: a count drifts when a began has no
/// matching end and the gate is stuck for good. It lets go (`.failed`) the moment no finger is down.
final class LibraryGridTouchTracker: UIGestureRecognizer {
    private var multi = false
    private let changed: (Bool) -> Void
    var onTwoFingers: ((CGPoint) -> Void)?

    /// The two-finger report is made once per sequence, and not at all when it starts with a lone finger that lingers,
    /// moves or lifts, or with three fingers.
    private var reported = false
    private var gaveUp = false
    /// A lone finger that has been down this long is not the first of a pinch's two.
    static let loneFingerPatience: TimeInterval = 0.15
    private var firstDown: TimeInterval?

    init(changed: @escaping (Bool) -> Void) {
        self.changed = changed
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        update(event, touches)
        guard !reported, !gaveUp else { return }
        let all = event.touches(for: self) ?? touches
        if firstDown == nil { firstDown = event.timestamp }
        guard all.count == 2, let view else {
            if all.count > 2 { gaveUp = true }
            return
        }
        let points = all.map { $0.location(in: view) }
        reported = true
        onTwoFingers?(CGPoint(x: points.map(\.x).reduce(0, +) / 2, y: points.map(\.y).reduce(0, +) / 2))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { update(event, touches); giveUpIfIdle(event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { update(event, touches); giveUpIfIdle(event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { update(event, touches); giveUpIfIdle(event) }

    private func update(_ event: UIEvent, _ touches: Set<UITouch>) {
        let live = (event.touches(for: self) ?? touches).filter { $0.phase != .ended && $0.phase != .cancelled }.count
        if live >= 2, !multi { multi = true; changed(true) }
        if live == 0 {
            if multi { multi = false; changed(false) }
            state = .failed
        }
    }

    private func giveUpIfIdle(_ event: UIEvent) {
        guard !reported, !gaveUp else { return }
        let live = (event.touches(for: self) ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
        let lingering = firstDown.map { event.timestamp - $0 > Self.loneFingerPatience } ?? true
        if live.count != 1 || lingering { gaveUp = true }
    }

    override func reset() {
        super.reset()
        if multi { multi = false; changed(false) }
        reported = false
        gaveUp = false
        firstDown = nil
    }
}
