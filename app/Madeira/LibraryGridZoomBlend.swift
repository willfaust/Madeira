// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import UIKit

// What a frame draws, in two halves (docs/zoomable-grid.md, section 3):
//
// - the OPACITY of every cell the blend holds (`frameAlphas`, the edge columns handed over with the
//   fade: `handOverEdges`), which follows `fades`;
// - the POSITION of every cell (`LibraryGridZoomFramePlacer`), which follows the pinch's coordinate itself (`frameGeometry`), so
//   it never trails the fingers and stops the frame the coordinate does.

extension LibraryGridZoomSession {

    struct Key: Hashable {
        let level: Int
        let index: Int
    }

    typealias Alphas = [Key: (cover: CGFloat, label: CGFloat)]

    static func stackZ(rank: Int) -> CGFloat { 0.5 + CGFloat(rank) * 0.01 }

    func frameBlend() -> GridZoomBlend { inLevels(lag.blend(fades: fades, t: t)) }

    /// The blend this frame's positions follow: the coordinate itself (the zoom would otherwise trail the fingers from rest). Row
    /// tops, section blocks, headers, page offset and page views are the pair around `t` mixed by `t`'s place in its segment, which is
    /// also where the covers' width is, so a card edge stays under a finger from the first frame. Only the opacities keep the timed crossfade.
    func frameGeometry() -> GridZoomBlend {
        guard coordCount >= 2 else { return frameBlend() }
        let (lower, progress) = GridZoomTransition.segment(t, count: coordCount)
        return inLevels(GridZoomBlend(lower: lower, upper: lower + 1, weight: GridZoomFeel.geometryWeight(progress: progress)))
    }

    // MARK: Opacities

    /// Every cell a blend draws, at its cover and label alpha: the pair underneath as the pair code fades it; each overlay over everything below it.
    func frameAlphas(_ blend: GridZoomBlend) -> Alphas {
        let lower = blend.lower
        let upper = blend.upper
        var alphas: Alphas = [:]
        if lower != upper, let decisions = plan(from: lower, to: upper) {
            // The outgoing covers stay opaque under the incoming fade (no dip) and leave once it is complete; labels fade symmetrically.
            let w = blend.weight
            for i in decisions.fromCandidates {
                let fades = decisions.fromFades[i], paired = decisions.fromPaired[i]
                let cover: CGFloat = !fades ? 1 : (paired ? (w >= 0.999 ? 0 : 1) : 1 - w)
                alphas[Key(level: lower, index: i)] = (cover, fades ? 1 - w : 1)
            }
            for i in decisions.toCandidates {
                let a: CGFloat = decisions.toFades[i] ? w : 1
                alphas[Key(level: upper, index: i)] = (a, a)
            }
        } else if let first = blend.overlays.first, let decisions = plan(from: lower, to: first.level) {
            for i in decisions.fromCandidates { alphas[Key(level: lower, index: i)] = (1, 1) }
        }
        for overlay in blend.overlays {
            let x = overlay.level, a = overlay.alpha
            let below = Set(alphas.keys.map(\.level))
            for (key, value) in alphas {
                guard let decisions = plan(from: key.level, to: x) else { continue }
                let fades = decisions.fromFades.indices.contains(key.index) ? decisions.fromFades[key.index] : true
                let paired = decisions.fromPaired.indices.contains(key.index) ? decisions.fromPaired[key.index] : false
                let backdrop = key.level == lower ? value.cover + (1 - value.cover) * a : value.cover
                let cover = paired ? (a >= 0.999 ? 0 : backdrop) : (fades ? value.cover * (1 - a) : value.cover)
                alphas[key] = (cover, fades ? value.label * (1 - a) : value.label)
            }
            var arriving: [Int: Bool] = [:]
            for y in below {
                guard let decisions = plan(from: y, to: x) else { continue }
                for i in decisions.toCandidates { arriving[i] = (arriving[i] ?? false) || decisions.toFades[i] }
            }
            for (i, fades) in arriving { alphas[Key(level: x, index: i)] = fades ? (a, a) : (1, 1) }
        }
        return alphas
    }

    /// An edge column hands over with the fade, like every other cell. An edge cell (no partner at the destination, off screen at its
    /// width) is drawn whole while its level is in the picture; the frame the blend became the settled pair it is either gone or
    /// there whole. So as the destination's share `s` comes up, the settled pair's other level's edge cells come up to opaque and
    /// every other level's edge cells leave (a cover under one stays opaque until it is complete, as a paired cover does). At rest
    /// `s` is 1 and nothing changes.
    func handOverEdges(_ alphas: inout Alphas, blend: GridZoomBlend) {
        guard coordCount >= 2, !fades.isSettled else { return }
        let coordinateDestination = min(coordCount - 1, max(0, fades.destination))
        let rest = fades.restingPair(coordinateDestination, t: t)
        let destination = steps[coordinateDestination]
        let next = steps[rest.lower == coordinateDestination ? rest.upper : rest.lower]
        guard next != destination, let arriving = plan(from: next, to: destination) else { return }
        let s = min(1, max(0, blend.share(of: destination)))
        let edges = Set(arriving.fromCandidates.filter { !arriving.fromFades[$0] })
        let drawn = blend.levels
        // A level outside the blend's range is drawn by `drawEdgeCells` (arriving whole from off screen); one the blend draws or skipped over comes up with the fade.
        if drawn.contains(next) || (next > (drawn.min() ?? next) && next < (drawn.max() ?? next)) {
            for i in edges {
                let key = Key(level: next, index: i)
                let value = alphas[key] ?? (0, 0)
                alphas[key] = (value.cover + (1 - value.cover) * s, value.label + (1 - value.label) * s)
            }
        }
        var toDestination: [Int: PairPlan] = [:]
        for (key, value) in alphas where key.level != destination && key.level != next {
            if toDestination[key.level] == nil { toDestination[key.level] = plan(from: key.level, to: destination) }
            guard let decisions = toDestination[key.level],
                  !(decisions.fromFades.indices.contains(key.index) ? decisions.fromFades[key.index] : false)
            else { continue }
            let backed = scene.partner(slot: key.index, of: key.level, in: next).map(edges.contains) ?? false
            alphas[key] = (backed ? (s >= 0.999 ? 0 : value.cover) : value.cover * (1 - s), value.label * (1 - s))
        }
    }

    // MARK: Reach

    /// Nothing a zoom can bring on screen is missing. A frame draws a pair at the fingers' width, which the fades lag (a quick zoom
    /// draws the pair it is leaving at the next level's width, or at the rubber band's), and the whole picture rides the page
    /// clamp's shift and the settle's landing shift. The plans' candidates cover every width and shift a frame can carry, so a row
    /// those bring on screen has a view before it shows. `reachWidths`: the widths besides the levels' own, the rubber band's ends.
    var reachWidths: [CGFloat] {
        let give = GridZoomFeel.rubberReach
        func ends(_ widths: [CGFloat]) -> [CGFloat] {
            let top = CGFloat(widths.count - 1)
            return [GridZoomTransition.width(at: -give, widths: widths), GridZoomTransition.width(at: top + give, widths: widths)]
        }
        // A chain's coordinate has its own ends (two columns a step); the levels' own stay covered.
        let all = levels.map(\.cardWidth)
        return widths == all ? ends(all) : ends(widths) + ends(all)
    }

    func clampAmount(pageTop: CGFloat, height: CGFloat) -> CGFloat {
        let low = -beginInsetTop
        let high = max(low, height + beginInsetBottom - viewport.height)
        return pageTop - min(high, max(low, pageTop))
    }

    func reachShifts() -> ClosedRange<CGFloat> {
        let ch = LibraryGridGeometry.coverHeight(cardWidth:)
        var lo: CGFloat = 0
        var hi: CGFloat = 0
        for level in 0..<levels.count {
            for width in reachWidths + [levels[level].cardWidth] {
                let top = scene.pageOffset(level, level, width: width, blend: 0, coverHeight: ch)
                let c = clampAmount(pageTop: top, height: virtualPageHeight(level, level, width: width, blend: 0))
                lo = min(lo, c)
                hi = max(hi, c)
            }
            if deltas.indices.contains(level) {
                lo = min(lo, deltas[level])
                hi = max(hi, deltas[level])
            }
        }
        return lo...hi
    }

    func virtualPageHeight(_ from: Int, _ to: Int, width: CGFloat, blend: CGFloat) -> CGFloat {
        scene.virtualY(from, to, ys: levels.map(\.page.result.contentHeight),
                       rowsAbove: (0..<levels.count).map { scene.rows(above: Int.max, level: $0) },
                       width: width, blend: blend, coverHeight: LibraryGridGeometry.coverHeight(cardWidth:))
    }

    /// What the plans are taken over: the widths a frame can draw at besides the levels' own, and the shifts it can carry. Read on the
    /// main thread (they ask the scene and the page); the plans themselves are pure (`GridZoomPlanSet`).
    func planInputs() -> (widths: [CGFloat], shifts: ClosedRange<CGFloat>) { (reachWidths, reachShifts()) }

    func makePlans() {
        let inputs = planInputs()
        apply(plans: GridZoomPlanSet.compute(scene: scene, viewport: viewport, extraWidths: inputs.widths, shifts: inputs.shifts,
                                             coverHeight: LibraryGridGeometry.coverHeight(cardWidth:)))
    }

    // MARK: The page top

    /// The top clamp on what is drawn: how far the levels' first drawn rows sit below their resting place, the worst level's, ramped
    /// in with its share of the picture (0 or negative: the shift that brings them back; screen y of everything drawn is
    /// `placed + shift`). The page clamp (`clampAmount`) reads the offset model; the rows are placed from the anchor outward, so a
    /// level with fewer rows above the anchor than the pair's (a zoom-out's destination) has its first row lower on the lattice than
    /// the model's page top. This asks the placement itself, per level, so the clamp holds in the frame the row would pass its place.
    func drawnTopClamp(_ blend: GridZoomBlend, placer: LibraryGridZoomFramePlacer) -> CGFloat {
        var clamp: CGFloat = 0
        for level in blend.levels {
            let share = blend.share(of: level)
            guard share > 0.001, let section = scene.levels[level].sections.first,
                  let slot = section.rows.first?.slots.first,
                  let placed = placer.position(level, slot), placed.cover.width > 0 else { continue }
            // Its resting place on screen: the rest y plus the inset (the page at its very top).
            let allowed = scene.levels[level].frames[slot].minY + beginInsetTop
            // Proportional to the level's share: a level that is 8 % of the picture moves the page 8 % of what it would need at 100 %,
            // so the anchor slides from the card to the page top at the zoom's own pace instead of jumping in the first frames.
            clamp += min(0, allowed - placed.cover.minY) * share
        }
        return clamp
    }

    /// The top floor (content may never be pulled down past the page top; it may scroll up freely): the shown offset never goes below
    /// the page's very top (minus the inset), in any frame. The clamp holds it for a pinch frame; the settle's ease and the spring's
    /// overshoot can pass it, so the shift is capped here.
    func floorShift(_ shift: CGFloat, pageTop: CGFloat) -> CGFloat {
        min(shift, pageTop + beginInsetTop)
    }

    /// The real offset stays `edgeHold` above the floor while the zoom runs: UIKit's scroll-edge blur is driven by the real offset and at
    /// exactly `-inset` it switches off, so the rows still fading under the bar went bright and sharp in one frame. The stage is placed in
    /// screen terms (`dy = offset + shift`), so the hold moves nothing drawn; the landing and `snapToFloor` put the offset exactly on the floor.
    static let edgeHold: CGFloat = 1

    func wantedRealOffset(base: CGFloat, shift: CGFloat, in collection: UICollectionView) -> CGFloat {
        let low = -beginInsetTop + Self.edgeHold
        let high = max(low, collection.contentSize.height + beginInsetBottom - collection.bounds.height)
        return max(low, settling ? base - (shift - clampShift) : min(high, base))
    }

    func snapToFloor(in collection: UICollectionView) {
        let top = -beginInsetTop
        if collection.contentOffset.y > top, collection.contentOffset.y <= top + Self.edgeHold + 0.01 {
            collection.contentOffset = CGPoint(x: collection.contentOffset.x, y: top)
        }
    }
}

/// Where every level's cells sit this frame: on the rows of the frame's geometry blend. A level the blend's pair holds takes the
/// pair's own placement; any other level's cells are its slots placed on each blended level's rows and mixed as the blend mixes
/// them (`GridZoomScene.place`), so every layer drawn shares the one set of row tops.
@MainActor
final class LibraryGridZoomFramePlacer {
    let scene: GridZoomScene
    let geometry: GridZoomBlend
    let width: CGFloat
    let window: ClosedRange<CGFloat>
    let base: GridZoomScene.Placement
    private var memo: [[Int]: GridZoomScene.Placement] = [:]

    init(scene: GridZoomScene, geometry: GridZoomBlend, width: CGFloat, window: ClosedRange<CGFloat>) {
        self.scene = scene
        self.geometry = geometry
        self.width = width
        self.window = window
        base = scene.place(geometry.lower, geometry.upper, width: width, blend: geometry.weight,
                           window: window, coverHeight: LibraryGridGeometry.coverHeight(cardWidth:))
    }

    private func on(_ y: Int, _ x: Int) -> GridZoomScene.Placement {
        if let known = memo[[y, x]] { return known }
        let made = scene.place(y, x, width: width, blend: y == x ? 0 : 1, window: window,
                               coverHeight: LibraryGridGeometry.coverHeight(cardWidth:))
        memo[[y, x]] = made
        return made
    }

    private func lerp(_ p: GridZoomScene.Placed?, _ q: GridZoomScene.Placed, _ m: CGFloat) -> GridZoomScene.Placed? {
        guard let p else { return nil }
        guard q.cover.width > 0 else { return p }
        var out = p
        out.cover.origin.y += (q.cover.minY - p.cover.minY) * m
        out.band += (q.band - p.band) * m
        return out
    }

    func position(_ y: Int, _ i: Int) -> GridZoomScene.Placed? {
        let g = geometry
        var p: GridZoomScene.Placed?
        if y == g.lower {
            p = base.a.indices.contains(i) ? base.a[i] : nil
        } else if y == g.upper {
            p = base.b.indices.contains(i) ? base.b[i] : nil
        } else {
            let low = on(y, g.lower).a
            let high = on(y, g.upper).a
            if low.indices.contains(i), low[i].cover.width > 0, high.indices.contains(i) {
                p = lerp(low[i], high[i], g.weight)
            }
        }
        guard let start = p, start.cover.width > 0 else { return nil }
        p = start
        for overlay in g.overlays where overlay.alpha > 0 {
            let q = on(y, overlay.level).a
            if q.indices.contains(i) { p = lerp(p, q[i], overlay.alpha) }
        }
        return p
    }
}
