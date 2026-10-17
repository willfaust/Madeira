// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Foundation/CoreGraphics only, so tests/host/check-library-zoom.py compiles it on the host.

import CoreGraphics
import Foundation


/// One level's real layout, as the zoom needs it: built from the attributes a real compositional layout produced for that
/// level (prepared off-screen with the page's own data), never from a closed form, so the zoom's last frame is the real
/// layout to the point. Content coordinates; `.zero` frames are unknown items.
struct GridZoomLevelLayout: Sendable {

    /// One row of one section.
    struct Row: Sendable, Equatable {
        var top: CGFloat
        var height: CGFloat
        var slots: [Int]
    }

    /// One rows section (a titled run, or the page's only grid).
    struct Section: Sendable, Equatable {
        var rows: [Row] = []
        var header: CGRect?
    }

    let coverWidth: CGFloat
    let restCoverHeight: CGFloat
    let leading: CGFloat
    private(set) var sections: [Section]
    private(set) var sectionOf: [Int]
    private(set) var rowOf: [Int]
    private(set) var columnOf: [Int]
    let frames: [CGRect]

    /// `frames`: every slot's item frame; `sectionOf`: the rows-section ordinal of each slot;
    /// `headers`: per rows-section ordinal, its header frame if any.
    init(
        coverWidth: CGFloat, coverHeight: (CGFloat) -> CGFloat, frames: [CGRect],
        sectionOf: [Int], headers: [CGRect?], columnGap: CGFloat
    ) {
        self.coverWidth = coverWidth
        restCoverHeight = coverHeight(coverWidth)
        self.frames = frames
        self.sectionOf = sectionOf
        let known = frames.indices.filter { frames[$0].width > 0 }
        leading = known.map { frames[$0].minX }.min() ?? 0
        sections = headers.map { Section(rows: [], header: $0) }
        rowOf = Array(repeating: -1, count: frames.count)
        columnOf = Array(repeating: -1, count: frames.count)
        let pitch = coverWidth + columnGap
        let order = known.sorted {
            (sectionOf[$0], frames[$0].minY, frames[$0].minX)
                < (sectionOf[$1], frames[$1].minY, frames[$1].minX)
        }
        for slot in order {
            let frame = frames[slot]
            let s = sectionOf[slot]
            guard sections.indices.contains(s) else { continue }
            if let last = sections[s].rows.last, abs(frame.minY - last.top) < 0.5 {
                sections[s].rows[sections[s].rows.count - 1].slots.append(slot)
            } else {
                sections[s].rows.append(Row(top: frame.minY, height: frame.height, slots: [slot]))
            }
            rowOf[slot] = sections[s].rows.count - 1
            columnOf[slot] = max(0, Int(((frame.minX - leading) / pitch).rounded()))
        }
    }

    func band(_ section: Int, _ row: Int) -> CGFloat {
        sections[section].rows[row].height - restCoverHeight
    }
}

/// The zoom's geometry between two levels, from their real layouts. During a pinch only the covers scale: the gaps between
/// cells and each row's label band keep their on-screen size, and both levels of a pair are placed on ONE lattice at every
/// frame so their slots coincide and the crossfade swaps like for like. The pinched section's lattices are anchored at the
/// pinch (the pinched row at `anchorTop`); every other section moves as a block (one shared first-row top per frame, its
/// header on the same slide). Screen y is "virtual": each level's `offsets` entry is the scroll offset that puts the pinched
/// item at `anchorTop` in that level, out of bounds allowed (no clamp while fingers are down). At a level's own cover width
/// and `mix` at its end, the placement equals its real layout (minus its offset) to the point.
struct GridZoomScene: Sendable {

    let columnGap: CGFloat
    let rowGap: CGFloat

    let levels: [GridZoomLevelLayout]
    let anchorSlot: Int
    let anchorTop: CGFloat
    /// Per level: the scroll offset that puts the pinched item's top at `anchorTop`.
    let offsets: [CGFloat]
    /// Where the pinch anchors the lattice horizontally. `.leading` runs it from each level's leading edge; `.trailing` from
    /// the trailing edge (a pinch started on the right keeps the right column under it); `.centre` from the middle, so columns
    /// arrive and leave in pairs. `.centre` needs levels of one column-count parity: a pair whose counts differ by an odd
    /// number rides `sideAnchor`. Every level's columns and gaps fill `row` exactly, so at a level's own width every anchor's
    /// place is its rest frame.
    enum Anchor: Sendable, Equatable { case leading, trailing, centre }
    var anchor: Anchor = .leading
    var sideAnchor: Anchor = .leading
    /// The rows' full width (`LibraryGridGeometry.contentWidth`): what `.trailing` and `.centre` measure from.
    var row: CGFloat = 0

    func anchor(_ x: GridZoomLevelLayout, _ y: GridZoomLevelLayout) -> Anchor {
        guard anchor == .centre else { return anchor }
        return (columnCount(x) - columnCount(y)).isMultiple(of: 2) ? .centre : sideAnchor
    }

    func columnCount(_ l: GridZoomLevelLayout) -> Int {
        max(1, Int(((row + columnGap) / (l.coverWidth + columnGap)).rounded()))
    }

    func x(column: Int, of l: GridZoomLevelLayout, width: CGFloat, anchor: Anchor) -> CGFloat {
        let pitch = width + columnGap
        switch anchor {
        case .leading: return l.leading + CGFloat(column) * pitch
        case .trailing: return l.leading + row - CGFloat(columnCount(l) - column) * pitch + columnGap
        case .centre: return l.leading + (row + columnGap) / 2 + (CGFloat(column) - CGFloat(columnCount(l)) / 2) * pitch
        }
    }

    init(levels: [GridZoomLevelLayout], anchorSlot: Int, anchorTop: CGFloat, columnGap: CGFloat, rowGap: CGFloat) {
        self.columnGap = columnGap
        self.rowGap = rowGap
        self.levels = levels
        self.anchorSlot = anchorSlot
        self.anchorTop = anchorTop
        offsets = levels.map { level in
            guard level.frames.indices.contains(anchorSlot) else { return 0 }
            return level.frames[anchorSlot].minY - anchorTop
        }
    }

    var anchorSection: Int {
        levels.first?.sectionOf.indices.contains(anchorSlot) == true
            ? levels[0].sectionOf[anchorSlot] : 0
    }

    /// One cell's placement: the cover rect (screen, virtual) and its label band's height.
    struct Placed: Sendable, Equatable {
        var cover: CGRect
        var band: CGFloat
        var rect: CGRect {
            CGRect(x: cover.minX, y: cover.minY, width: cover.width, height: cover.height + band)
        }
        static let none = Placed(cover: .zero, band: 0)
    }

    struct Placement: Sendable {
        var a: [Placed]
        var b: [Placed]
        var headerY: [Int: CGFloat]
        /// The slots that were placed (not `.none`), per layer, so a caller walks these and not every slot of a big page.
        var slotsA: [Int] = []
        var slotsB: [Int] = []
    }

    func mix(_ a: Int, _ b: Int, width: CGFloat) -> CGFloat {
        let wa = log(max(0.001, levels[a].coverWidth))
        let wb = log(max(0.001, levels[b].coverWidth))
        guard abs(wb - wa) > 1e-6 else { return 0 }
        return min(1, max(0, (log(max(0.001, width)) - wa) / (wb - wa)))
    }

    /// Every slot's placement at cover width `width` for the pair `(a, b)`.
    ///
    /// `blend` is how far the row tops (label-band heights, each other section's block top and header) have moved from level
    /// `a`'s to level `b`'s: the renderer passes the fade's weight, so the height change of rows that rewrap their titles
    /// glides with the crossfade. Nil: by where `width` falls between the two levels' widths. At 0 the rows are `a`'s exactly,
    /// at 1 `b`'s, so a pair's placement at `blend` 1 equals the next pair's at 0.
    ///
    /// `window` is a range of screen y: only slots whose cell intersects it are placed (a frame needs the few dozen near the
    /// screen of thousands), though row tops still accumulate over the whole row list. Inside it the result is what nil gives.
    func place(
        _ a: Int, _ b: Int, width: CGFloat, blend: CGFloat? = nil,
        window: ClosedRange<CGFloat>? = nil, coverHeight: (CGFloat) -> CGFloat
    ) -> Placement {
        let m = min(1, max(0, blend ?? mix(a, b, width: width)))
        let ch = coverHeight(width)
        func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * m }
        let la = levels[a]
        let lb = levels[b]
        var outA = [Placed](repeating: .none, count: la.frames.count)
        var outB = [Placed](repeating: .none, count: lb.frames.count)
        var headerY: [Int: CGFloat] = [:]
        var slotsA: [Int] = []
        var slotsB: [Int] = []
        let pinched = anchorSection
        let side = anchor(la, lb)
        // Sections are placed outward from the pinched one, per layer (`spans`): within a layer two sections never overlap
        // whatever the blend or the row counts.
        let spans = spans(a, b, blend: m, coverHeight: ch)
        for s in 0..<la.sections.count {
            let ra = la.sections[s].rows
            let rb = lb.sections.indices.contains(s) ? lb.sections[s].rows : []
            // Row tops by row offset j from the section's reference row (j = 0).
            let anchorA = referenceRow(section: s, level: a)
            let anchorB = referenceRow(section: s, level: b)
            var originA = anchorTop
            var originB = anchorTop
            if s != pinched {
                originA = spans.a[s]?.reference ?? spans.b[s]?.reference ?? 0
                originB = spans.b[s]?.reference ?? originA
                if let ha = la.sections[s].header, let first = ra.first, let spanA = spans.a[s] {
                    let hy = spanA.top + (ha.minY - first.top)
                    if let hb = lb.sections.indices.contains(s) ? lb.sections[s].header : nil, let firstB = rb.first, let spanB = spans.b[s] {
                        headerY[s] = lerp(hy, spanB.top + (hb.minY - firstB.top))
                    } else { headerY[s] = hy }
                }
            }
            let lo = -max(anchorA, anchorB)
            let hi = max(ra.count - 1 - anchorA, rb.count - 1 - anchorB)
            guard lo <= hi else { continue }
            // The blended label-band height of row offset `j`: both levels' row at that offset, one alone if only one has it.
            let bandAt = lattice(section: s, a, b, blend: m).band
            let topsA = rowTops(
                lo: lo, hi: max(hi, 0), origin: originA, ch: ch, window: window, band: bandAt)
            let topsB = originB == originA ? topsA : rowTops(
                lo: lo, hi: max(hi, 0), origin: originB, ch: ch, window: window, band: bandAt)
            func emit(_ rows: [GridZoomLevelLayout.Row], anchor: Int, layout: GridZoomLevelLayout,
                      tops: (jMin: Int, jMax: Int, values: [CGFloat]))
                -> [(slot: Int, placed: Placed)]
            {
                var made: [(Int, Placed)] = []
                for j in tops.jMin...tops.jMax {
                    let row = anchor + j
                    guard rows.indices.contains(row) else { continue }
                    let entry = rows[row]
                    let y = tops.values[j - tops.jMin]
                    let band = bandAt(j)
                    if let window, y + ch + band < window.lowerBound || y > window.upperBound {
                        continue
                    }
                    for slot in entry.slots {
                        made.append(
                            (
                                slot,
                                Placed(
                                    cover: CGRect(
                                        x: x(column: layout.columnOf[slot], of: layout, width: width, anchor: side),
                                        y: y, width: width, height: ch),
                                    band: band)
                            ))
                    }
                }
                return made
            }
            for (slot, placed) in emit(ra, anchor: anchorA, layout: la, tops: topsA) {
                outA[slot] = placed
                slotsA.append(slot)
            }
            for (slot, placed) in emit(rb, anchor: anchorB, layout: lb, tops: topsB) {
                outB[slot] = placed
                slotsB.append(slot)
            }
        }
        return Placement(a: outA, b: outB, headerY: headerY, slotsA: slotsA, slotsB: slotsB)
    }

    /// Row tops for row offsets `jMin ... jMax` (index `j - jMin`), accumulated outward from `origin` at j = 0. With a `window`
    /// the accumulation stops once a row lies wholly beyond it, so a page of thousands of rows touches only the few near the screen.
    private func rowTops(
        lo: Int, hi: Int, origin: CGFloat, ch: CGFloat, window: ClosedRange<CGFloat>?,
        band: (Int) -> CGFloat
    ) -> (jMin: Int, jMax: Int, values: [CGFloat]) {
        var ups = [origin]
        var downs: [CGFloat] = []
        var top = origin
        var j = 0
        while j < hi {
            let next = top + ch + band(j) + rowGap
            if let window, next > window.upperBound { break }
            ups.append(next)
            top = next
            j += 1
        }
        top = origin
        j = 0
        while j > lo {
            let b = band(j - 1)
            let prev = top - rowGap - b - ch
            if let window, prev + ch + b < window.lowerBound { break }
            downs.append(prev)
            top = prev
            j -= 1
        }
        return (j, ups.count - 1, downs.reversed() + ups)
    }

    /// The scroll offset the zoom is showing, for the page's own scroll machinery (the large title and the top scroll-edge
    /// blur follow the fingers): where the page would be scrolled for the pinched item to sit at `anchorTop` with the rows
    /// above it as tall as they are now, blended between the two levels by `blend`. At a level's own width and its end of
    /// the blend it is that level's `offsets` entry.
    func pageOffset(
        _ a: Int, _ b: Int, width: CGFloat, blend: CGFloat, coverHeight: (CGFloat) -> CGFloat
    ) -> CGFloat {
        let ch = coverHeight(width)
        func y(_ l: Int) -> CGFloat {
            let level = levels[l]
            guard level.frames.indices.contains(anchorSlot) else { return 0 }
            let section = level.sectionOf[anchorSlot]
            var above = max(0, level.rowOf[anchorSlot])
            for s in 0..<min(section, level.sections.count) {
                above += level.sections[s].rows.count
            }
            return level.frames[anchorSlot].minY + CGFloat(above) * (ch - level.restCoverHeight)
        }
        let m = min(1, max(0, blend))
        return y(a) + (y(b) - y(a)) * m - anchorTop
    }

    // MARK: - Sections

    /// The row a section's rows are counted from: the pinched row in the pinched section; the last row of a section above it
    /// and the first of one below, so rows that meet the pinched section pair with each other at both levels.
    func referenceRow(section s: Int, level: Int) -> Int {
        let layout = levels[level]
        if s == anchorSection { return max(0, layout.rowOf.indices.contains(anchorSlot) ? layout.rowOf[anchorSlot] : 0) }
        guard s < anchorSection, layout.sections.indices.contains(s) else { return 0 }
        return max(0, layout.sections[s].rows.count - 1)
    }

    /// A section's rows as the pair draws them: the reference rows, and the blended label-band height of row offset `j` (one
    /// level's alone if only one has the row).
    func lattice(section s: Int, _ a: Int, _ b: Int, blend m: CGFloat) -> (refA: Int, refB: Int, band: (Int) -> CGFloat) {
        let la = levels[a]
        let lb = levels[b]
        let ra = la.sections.indices.contains(s) ? la.sections[s].rows : []
        let rb = lb.sections.indices.contains(s) ? lb.sections[s].rows : []
        let refA = referenceRow(section: s, level: a)
        let refB = referenceRow(section: s, level: b)
        let band: (Int) -> CGFloat = { j in
            let ia = refA + j
            let ib = refB + j
            let x = ra.indices.contains(ia) ? la.band(s, ia) : nil
            let y = rb.indices.contains(ib) ? lb.band(s, ib) : nil
            switch (x, y) {
            case (let x?, let y?): return x + (y - x) * m
            case (let x?, nil): return x
            case (nil, let y?): return y
            default: return 0
            }
        }
        return (refA, refB, band)
    }

    /// One section of one layer as drawn, in placed (screen, virtual) y: its first row's top, its reference row's top, its
    /// last row's bottom.
    struct Span: Sendable, Equatable {
        var top: CGFloat
        var reference: CGFloat
        var bottom: CGFloat
    }

    /// Every section's span in layer `a` and layer `b` of a pair (nil: no rows at that level).
    struct Spans: Sendable {
        var a: [Span?]
        var b: [Span?]
    }

    /// The layout's own distance between section `s`'s last row and the next section's first at `level`
    /// at rest: the header, the spacing, any notice between them. Rest extents, which do not scale.
    private func gap(after s: Int, level: Int) -> CGFloat {
        let sections = levels[level].sections
        guard sections.indices.contains(s + 1), let last = sections[s].rows.last, let next = sections[s + 1].rows.first else { return 0 }
        return next.top - (last.top + last.height)
    }

    /// Every section's extent in each layer, chained outward from the pinched section at cover height `ch` and blend `m`: a
    /// section below starts at the previous one's bottom plus the layout's gap, a section above ends at the next one's top
    /// less it. At a level's own width and its end of the blend each span is the level's rest layout less its offset.
    func spans(_ a: Int, _ b: Int, blend m: CGFloat, coverHeight ch: CGFloat) -> Spans {
        let count = levels[a].sections.count
        var made: [[Span?]] = []
        for level in [a, b] {
            var out = [Span?](repeating: nil, count: count)
            let sections = levels[level].sections
            func extent(_ s: Int) -> (ref: Int, up: CGFloat, down: CGFloat)? {
                guard sections.indices.contains(s), !sections[s].rows.isEmpty else { return nil }
                let n = sections[s].rows.count
                let l = lattice(section: s, a, b, blend: m)
                let ref = level == a ? l.refA : l.refB
                var up: CGFloat = 0
                var j = -ref
                while j < 0 { up += ch + l.band(j) + rowGap; j += 1 }
                var down: CGFloat = 0
                j = 0
                while j < n - 1 - ref { down += ch + l.band(j) + rowGap; j += 1 }
                down += ch + l.band(n - 1 - ref)
                return (ref, up, down)
            }
            let pinched = anchorSection
            guard count > 0, pinched < count else { made.append(out); continue }
            if let e = extent(pinched) {
                out[pinched] = Span(top: anchorTop - e.up, reference: anchorTop, bottom: anchorTop + e.down)
            }
            var cursor = out[pinched]?.bottom ?? anchorTop
            var s = pinched + 1
            while s < count {
                if let e = extent(s) {
                    let top = cursor + (out[s - 1] == nil ? 0 : gap(after: s - 1, level: level))
                    out[s] = Span(top: top, reference: top + e.up, bottom: top + e.up + e.down)
                    cursor = top + e.up + e.down
                }
                s += 1
            }
            cursor = out[pinched]?.top ?? anchorTop
            s = pinched - 1
            while s >= 0 {
                if let e = extent(s) {
                    let bottom = cursor - (out[s + 1] == nil ? 0 : gap(after: s, level: level))
                    out[s] = Span(top: bottom - e.down - e.up, reference: bottom - e.down, bottom: bottom)
                    cursor = bottom - e.down - e.up
                }
                s -= 1
            }
            made.append(out)
        }
        return Spans(a: made[0], b: made[1])
    }

    /// Where a page element sits in the pair's placed y, kept at its rest distance from the section it belongs to in each
    /// layer so a header never parts from its rows: `lead` (above the section's first row) or trailing (below the last row).
    /// `rest` is per level the element's rest top less the section's rest top (lead) or bottom (trailing). Nil when the
    /// section has no rows at either level.
    func elementY(_ a: Int, _ b: Int, spans: Spans, blend m: CGFloat, section s: Int, trailing: Bool, rest: [CGFloat]) -> CGFloat? {
        func at(_ list: [Span?], _ level: Int) -> CGFloat? {
            guard list.indices.contains(s), let span = list[s], rest.indices.contains(level) else { return nil }
            return (trailing ? span.bottom : span.top) + rest[level]
        }
        switch (at(spans.a, a), at(spans.b, b)) {
        case (let x?, let y?): return x + (y - x) * min(1, max(0, m))
        case (let x?, nil): return x
        case (nil, let y?): return y
        default: return nil
        }
    }

    func restOffset(ofElementAt y: CGFloat, section s: Int, trailing: Bool, level: Int) -> CGFloat? {
        let sections = levels[level].sections
        guard sections.indices.contains(s) else { return nil }
        if trailing {
            guard let last = sections[s].rows.last else { return nil }
            return y - (last.top + last.height)
        }
        guard let first = sections[s].rows.first else { return nil }
        return y - first.top
    }

    // MARK: - The page around the books

    func rows(above sections: Int, level: Int) -> Int {
        levels[level].sections.prefix(max(0, sections)).reduce(0) { $0 + $1.rows.count }
    }

    /// Where a page element sits in the virtual page the zoom shows, in content coordinates: its rest `y` at each level plus
    /// the rows above it times how far the cover height has moved from that level's own (as `pageOffset`), blended by `blend`.
    /// `ys` and `rowsAbove` are per level; an element above every book does not move, one below them all follows the books' end.
    func virtualY(
        _ a: Int, _ b: Int, ys: [CGFloat], rowsAbove: [Int], width: CGFloat, blend: CGFloat,
        coverHeight: (CGFloat) -> CGFloat
    ) -> CGFloat {
        let ch = coverHeight(width)
        func y(_ l: Int) -> CGFloat {
            guard ys.indices.contains(l), rowsAbove.indices.contains(l) else { return 0 }
            return ys[l] + CGFloat(rowsAbove[l]) * (ch - levels[l].restCoverHeight)
        }
        let m = min(1, max(0, blend))
        return y(a) + (y(b) - y(a)) * m
    }

    // MARK: - Which cells are replaced, which stay

    /// A pair's per-slot decision, computed once.
    struct Plan: Sendable {
        var aFades: [Bool]
        var bFades: [Bool]
        var aCandidates: [Int]
        var bCandidates: [Int]
        var aPaired: [Bool]
        var bPaired: [Bool]
    }

    /// Whether `slot` of level `x` has a partner in `y`'s same lattice slot (same section, same row from the reference row,
    /// same column).
    func hasPartner(slot: Int, of x: Int, in y: Int) -> Bool {
        partner(slot: slot, of: x, in: y) != nil
    }

    func partner(slot: Int, of x: Int, in y: Int) -> Int? {
        let lx = levels[x]
        let ly = levels[y]
        guard lx.rowOf.indices.contains(slot) else { return nil }
        let row = lx.rowOf[slot]
        guard row >= 0 else { return nil }
        let s = lx.sectionOf[slot]
        guard ly.sections.indices.contains(s) else { return nil }
        let other = referenceRow(section: s, level: y) + row - referenceRow(section: s, level: x)
        guard ly.sections[s].rows.indices.contains(other) else { return nil }
        let slots = ly.sections[s].rows[other].slots
        var column = lx.columnOf[slot]
        // On a trailing lattice a place is counted from the trailing edge, on a centre one from the middle (the counts differ
        // by an even number there).
        switch anchor(lx, ly) {
        case .leading: break
        case .trailing: column += columnCount(ly) - columnCount(lx)
        case .centre: column += (columnCount(ly) - columnCount(lx)) / 2
        }
        return column >= 0 && column < slots.count ? slots[column] : nil
    }

    /// Edge cells stay; everything else fades. A cell with no partner slot whose place at the other level's width is off
    /// screen is an edge cell: a leaving cell keeps drawing until it leaves the viewport, an arriving one is already there at
    /// full opacity. A cell with no partner that would still sit on screen at the other width fades with the crossfade, so no
    /// cell of the outgoing layout is left over the landed one.
    ///
    /// Nothing a frame can bring on screen is missing: a frame draws a pair at the fingers' width (the fades lag it), which
    /// can be anywhere in the rubber band's range, and the picture rides the page clamp's shift. `margin` widens the
    /// candidates (not the fade decisions) on every side, `widths` adds the widths a frame can draw at (the rubber band's
    /// ends), `shifts` the range of the shift a frame can carry (screen y = placed y + shift).
    func plan(
        _ a: Int, _ b: Int, viewport: CGSize, margin: CGFloat = 0, widths extra: [CGFloat] = [],
        shifts: ClosedRange<CGFloat> = 0...0, coverHeight: (CGFloat) -> CGFloat
    ) -> Plan {
        let screen = CGRect(origin: .zero, size: viewport)
        // On screen means showing at least a point: the arriving column's place at the other width ends exactly at the
        // screen's edge, so a strict test would be decided by a rounding error.
        let shown = screen.insetBy(dx: 0.5, dy: 0.5)
        let reach = CGRect(
            x: 0, y: -shifts.upperBound, width: viewport.width,
            height: viewport.height + shifts.upperBound - shifts.lowerBound
        ).insetBy(dx: -margin, dy: -margin)
        func onScreen(_ p: Placed) -> Bool {
            p.cover.width > 0 && p.rect.intersects(shown)
        }
        // A candidate is a cell the pair may draw: on screen, or within `margin` of it.
        func candidate(_ p: Placed) -> Bool {
            p.cover.width > 0 && p.rect.intersects(reach)
        }
        let wa = levels[a].coverWidth
        let wb = levels[b].coverWidth
        let mid = (wa * wb).squareRoot()
        // Only what can be on screen matters here (`onScreen`): one viewport either side is room.
        let window = (-viewport.height - margin - shifts.upperBound)...(2 * viewport.height + margin - shifts.lowerBound)
        let atA = place(a, b, width: wa, window: window, coverHeight: coverHeight)
        let atMid = place(a, b, width: mid, window: window, coverHeight: coverHeight)
        let atB = place(a, b, width: wb, window: window, coverHeight: coverHeight)
        var aCand = Set<Int>()
        var bCand = Set<Int>()
        // The renderer blends row tops by the fade's weight, not the width: the extremes bound what it can draw.
        var spread = [atA, atMid, atB]
        for blend: CGFloat in [0, 1] {
            for width in [wa, mid, wb] + extra {
                spread.append(
                    place(
                        a, b, width: width, blend: blend, window: window, coverHeight: coverHeight))
            }
        }
        for p in spread {
            for i in p.slotsA where candidate(p.a[i]) { aCand.insert(i) }
            for i in p.slotsB where candidate(p.b[i]) { bCand.insert(i) }
        }
        var aPaired = [Bool](repeating: false, count: levels[a].frames.count)
        var bPaired = [Bool](repeating: false, count: levels[b].frames.count)
        var aFades = aPaired
        var bFades = bPaired
        for i in aCand {
            aPaired[i] = hasPartner(slot: i, of: a, in: b)
            aFades[i] = aPaired[i] || onScreen(atB.a[i])
        }
        for i in bCand {
            bPaired[i] = hasPartner(slot: i, of: b, in: a)
            bFades[i] = bPaired[i] || onScreen(atA.b[i])
        }
        return Plan(
            aFades: aFades, bFades: bFades, aCandidates: aCand.sorted(),
            bCandidates: bCand.sorted(), aPaired: aPaired, bPaired: bPaired)
    }
}

// MARK: - The plans, as pure maths

/// Every pair's plan over everything a frame can draw. Value types only, so it runs on a background task while a pinch
/// begins. `extraWidths` are the widths a frame can draw at besides the levels' own, `shifts` the range of the shift a frame
/// can carry.
struct GridZoomPlanSet: Sendable {
    var plans: [[Int]: GridZoomScene.Plan] = [:]
    var needed: [Set<Int>]

    static func compute(scene: GridZoomScene, viewport: CGSize, extraWidths: [CGFloat], shifts: ClosedRange<CGFloat>,
                        coverHeight: (CGFloat) -> CGFloat) -> GridZoomPlanSet {
        var set = GridZoomPlanSet(needed: Array(repeating: [], count: scene.levels.count))
        guard scene.levels.count >= 2 else { return set }
        for low in 0..<(scene.levels.count - 1) {
            for high in (low + 1)..<scene.levels.count {
                let plan = scene.plan(low, high, viewport: viewport, margin: 120, widths: extraWidths, shifts: shifts,
                                      coverHeight: coverHeight)
                set.plans[[low, high]] = plan
                set.needed[low].formUnion(plan.aCandidates)
                set.needed[high].formUnion(plan.bCandidates)
            }
        }
        return set
    }
}

extension GridZoomScene {
    /// The same zoom pinched somewhere else (the page's top-row hold moves the pinched slot); the levels and lattice settings
    /// are kept.
    func reanchored(slot: Int, top: CGFloat) -> GridZoomScene {
        var out = GridZoomScene(levels: levels, anchorSlot: slot, anchorTop: top, columnGap: columnGap, rowGap: rowGap)
        out.anchor = anchor
        out.sideAnchor = sideAnchor
        out.row = row
        return out
    }
}
