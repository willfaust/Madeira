#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 LiamTheAppDev
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""The zoomable library grid (docs/zoomable-grid.md), on the host.

1. Swift: compiles the production zoom model (LibraryGridZoomModel.swift,
   LibraryGridZoomScene.swift) and the grid geometry (LibraryGridLevels.swift's
   Foundation-only part) and checks the levels (full width at every level, the
   picker's Cards and Compact targets), the page layout (rows take their
   tallest card, frames in page order), the scene (each level's own width and
   end of the blend IS that level's layout; blocks never overlap), the fades
   and the release spring.
2. Source checks: the zoomable page is built from the same rules as the SwiftUI
   page, the original grid is kept behind the switch, and the new files
   are in the Xcode project.

Synthetic data only.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def between(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i)]


library = (app / 'Library.swift').read_text()
levels = (app / 'LibraryGridLevels.swift').read_text()
page = (app / 'LibraryGridPage.swift').read_text()
host = (app / 'LibraryGridHost.swift').read_text()
zoom = (app / 'LibraryGridZoom.swift').read_text()
stage = (app / 'LibraryGridZoomStage.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
docs = (root / 'docs/zoomable-grid.md').read_text()

# ------------------------------------------------------------------ sources
view = between(library, 'struct LibraryView: View {', 'struct ExecutableBrowser: View {')
require('LibraryGridArm.zoomable(setting: zoomableGrid, layout: layout) { zoomableLibrary } else { library }' in view,
        'arms: the zoomable page in the card layouts, else the original page')
require('LibraryCells(items: items, layout: layout, width: viewportWidth)' in view and 'struct LibraryCells<' in library
        and 'LazyVGrid(columns:' in library, 'the original LazyVGrid grid is kept')
require('static let key = "madeiraLibraryNewGrid"' in page
        and 'static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? false }' in page
        and '@AppStorage(LibraryGridArm.key) private var zoomableGrid = false' in view
        and 'layout == "cards" || layout == "compact"' in page, 'arms: the "New library grid" setting (off by default, the same default at both reads) picks the page; list layouts never zoom')
require('Toggle("New library grid", isOn: $zoomableGrid)' in view and 'Toggle("Zoom haptics", isOn: $zoomHaptics)' in view
        and 'MADEIRA_LIBRARY_ZOOM' not in page + view + library, 'Settings › Appearance: the two switches, no config flag')
for rule in ['LibraryGridSteamItems.items(installed: model.games, owned: owned, search: inputs.search)',
             'SteamGamesRules.groups(items, downloading: Set(account.downloads.keys))',
             'SteamGamesRules.sorted(groups.installed, by: inputs.sort, recorded: Self.recorded())',
             'let steamFirst = MadeiraDock.enabled && LibraryGridSteamItems.hasInstalled',
             'let items = SteamGamesRules.items(installed: installed, owned: owned, search: search)',
             'LibraryGrouping.groups(games, by: inputs.group, sort: inputs.sort)',
             'guard installed || (enabled && account.signedIn) else { continue }',
             'SteamGamesRules.showsSignIn(library: libraryEnabled, signedIn: account.signedIn)']:
    require(rule in page, f'page model uses the SwiftUI page\'s rule: {rule[:60]}')
steam_section = (app / 'SteamGames.swift').read_text()
for rule in ['return SteamGamesRules.showsSection(dock: MadeiraDock.enabled, library: library,',
             'signedIn: library && account.signedIn, count: total)',
             'return !groups.installed.isEmpty || !groups.downloading.isEmpty']:
    require(rule in page and rule in steam_section, f'LibraryGridSteamItems states SteamGamesSection\'s rule: {rule[:50]}')
require('SteamGamesSection.shown' not in between(page, 'struct LibraryGridPageModel', '// MARK: Labels'),
        'the page build reads the section rules through the memo (one items() per change)')
label_text = between(levels, 'struct LibraryCardLabel: Hashable {', 'final class LibraryLabelBitmaps')
require('UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: LibraryGridTitle.size(cardWidth: w), compatibleWith: traits)' in label_text
        and '.semibold' in label_text, 'title: the level\'s size scaled by Dynamic Type (UIFontMetrics), semibold')
require('fonts.at(cardWidth: cardWidth)' in label_text and 'fonts.at(cardWidth: size.width)' in label_text
        and 'func at(_ style' not in label_text, 'title: the band measure, the estimate and the draw all take the level\'s fonts from its card width')
draw_text = between(label_text, 'func draw(size: CGSize, fonts: Fonts)', 'let rows = pillPlacement')
measure_text = between(label_text, 'private static func layoutTitle', 'private struct PillWidthKey')
require('Self.titleLayout(' in draw_text and 'titleLayout(' in measure_text and 'drawGlyphs' in draw_text
        and '(title as NSString).draw' not in draw_text, 'title: measured and drawn by the same TextKit layout (titleLayout)')
require('titleHalfPoints' in levels, 'title: the drawn-label cache is keyed by the title size')
require('LibraryBadges.formatTexts(entry, note: status.badge)' in page and 'static func formatTexts(' in library,
        'measured labels: the pills from LibraryBadges\' own texts')
require('panGestureRecognizer.isEnabled = false' in zoom and 'isScrollEnabled' not in zoom + stage + host,
        'the pinch pauses the pan, never scrolling')
require(stage.count('layoutIfNeeded') == 1 and 'static func renderInWindow' in stage and 'CATransaction.setDisableActions(true)' in stage,
        'no layout per frame (only the stand-ins rendered once at insertion), actions off')
require('func sizeThatFits(_ proposal: ProposedViewSize' in host, 'the representable answers sizeThatFits')
require('insertSubview(container, belowSubview: edge)' in stage, 'the stage sits below the scroll-edge view')
for name in ['LibraryGridZoomBlend.swift', 'LibraryGridZoomModel.swift', 'LibraryGridZoomScene.swift', 'LibraryGridLevels.swift', 'LibraryCoverCache.swift',
             'LibraryGridPage.swift', 'LibraryGridHost.swift', 'LibraryGridZoom.swift', 'LibraryGridZoomStage.swift']:
    require(f'/* {name} in Sources */' in project, f'{name} is built by the Xcode project')
require('Real Steam data' in docs and 'madeiraSteamInstalledSnapshot.v1' in docs and 'Card size' in docs, 'docs: the real-data section, the snapshot key and the card-size control')

# ------------------------------------------------------------------ Swift
geometry = between(levels, '// MARK: - Geometry', '// MARK: - Card labels')
checks = r'''
import CoreGraphics
import Foundation

@main
struct Checks {
    static var failures = 0
    static func require(_ ok: Bool, _ label: String) {
        print((ok ? "PASS: " : "FAIL: ") + label)
        if !ok { failures += 1 }
    }
    static func near(_ a: CGFloat, _ b: CGFloat, _ e: CGFloat = 0.01) -> Bool { abs(a - b) <= e }

    static func main() {
        let G = LibraryGridGeometry.self
        // Levels.
        let phone = G.contentWidth(viewport: 390)
        require(G.stops(content: phone) == [2, 3, 4], "a 390 pt phone: 2, 3 and 4 columns (got \(G.stops(content: phone)))")
        let pad = G.contentWidth(viewport: 1024)
        let padStops = G.stops(content: pad)
        require(padStops.count == G.maxStops && padStops.first! < padStops.last!, "an iPad: five levels, fewest columns first (\(padStops))")
        require(near(G.contentWidth(viewport: 1400), 1100 - 32), "the page keeps its 1100 pt cap")
        var full = true
        for n in 2...12 {
            let w = G.cardWidth(content: phone, columns: n)
            full = full && near(CGFloat(n) * w + CGFloat(n - 1) * G.columnGap, phone)
        }
        require(full, "the cards and gaps fill the width at every level")
        require(G.stops(content: phone)[G.nearestStop(to: G.cardsTarget, content: phone)] == 2
                && G.stops(content: phone)[G.nearestStop(to: G.compactTarget, content: phone)] == 3,
                "the picker: Cards is 2 columns and Compact cards 3 on a phone, as today")
        require(LibraryGridSize.columns(layout: "compact", position: -1, content: phone) == 3
                && LibraryGridSize.columns(layout: "cards", position: 1, content: phone) == 4,
                "a stored position wins over the picker's entry")
        require(G.stopIndex(position: 0.5, count: 2) == 0, "a position between two levels takes the bigger cards")

        // The title's size: clamped at both ends, a straight line between, in half points, never decreasing with width.
        let T = LibraryGridTitle.self
        require(T.size(cardWidth: 40) == 12 && T.size(cardWidth: 77) == 12 && T.size(cardWidth: 77.5) == 12, "title: 12 pt at 77 pt and under")
        require(T.size(cardWidth: 160) == 15 && T.size(cardWidth: 175) == 15 && T.size(cardWidth: 400) == 15, "title: 15 pt at 160 pt and over")
        var title = true, halves = true, prev: CGFloat = 0
        var w: CGFloat = 40
        while w <= 300 {
            let s = T.size(cardWidth: w)
            title = title && s >= prev && s >= 12 && s <= 15
            halves = halves && near(s * 2, (s * 2).rounded(), 1e-9)
            prev = s
            w += 0.25
        }
        require(title, "title: monotonic in the card width and inside 12...15")
        require(halves, "title: always a multiple of half a point")
        require(near(T.size(cardWidth: 118.5), 13.5, 0.01), "title: the middle of the range is the middle size")
        let p402 = G.contentWidth(viewport: 402)
        let sizes402 = [2, 3, 4].map { T.size(cardWidth: G.cardWidth(content: p402, columns: $0)) }
        require(sizes402 == [15, 13, 12], "title: a 402 pt portrait phone, 2/3/4 across, is 15/13/12 (got \(sizes402))")
        let p440 = G.contentWidth(viewport: 440)
        let sizes440 = [2, 3, 4].map { T.size(cardWidth: G.cardWidth(content: p440, columns: $0)) }
        require(sizes440 == [15, 13.5, 12.5], "title: a 440 pt portrait phone is 15/13.5/12.5 (got \(sizes440))")
        let landscape = G.contentWidth(viewport: 874)
        let steps = G.stops(content: landscape).map { T.size(cardWidth: G.cardWidth(content: landscape, columns: $0)) }
        var distinct = true
        for i in 1..<steps.count { distinct = distinct && steps[i] <= steps[i - 1] }
        require(distinct && Set(steps).count > 2, "title: landscape's finer levels step by half points (\(steps))")

        // The page layout.
        let blocks: [LibraryGridLayoutModel.Block] = [.fixed(height: 44, spacing: 0), .fixed(height: 30, spacing: 24),
                                                      .grid(bands: [40, 62, 40, 40, 80], spacing: 14),
                                                      .fixed(height: 30, spacing: 24), .grid(bands: [40, 40, 40], spacing: 14)]
        let r = LibraryGridLayoutModel.layout(blocks, columns: 2, content: phone, originX: 16)
        require(r.frames.count == 2 + 5 + 1 + 3 && r.ranges.count == 5, "one frame per fixed element and per card")
        require(r.frames[2].height == r.frames[3].height && r.frames[3].height > r.frames[4].height - 23,
                "a row takes its tallest card's band")
        var ordered = true
        for i in 1..<r.frames.count { ordered = ordered && r.frames[i].minY >= r.frames[i - 1].minY - 0.001 && r.frames[i].maxY >= r.frames[i - 1].maxY - 0.001 }
        require(ordered, "frames are in page order (the layout's binary search)")
        require(r.rows == [0, 0, 3, 0, 2] && r.rowsAbove == [0, 0, 0, 3, 3], "rows per block and rows above each block")
        require(near(r.frames[2].minY, 16 + 44 + 24 + 30 + 14), "blocks keep the page's 16 / 24 / 14 spacing")

        // The scene: two levels of the same page.
        func level(_ n: Int) -> (GridZoomLevelLayout, LibraryGridLayoutModel.Result) {
            let res = LibraryGridLayoutModel.layout(blocks, columns: n, content: phone, originX: 16)
            var frames: [CGRect] = [], sectionOf: [Int] = []
            for (b, s) in [(2, 0), (4, 1)] { for i in res.ranges[b] { frames.append(res.frames[i]); sectionOf.append(s) } }
            return (GridZoomLevelLayout(coverWidth: res.cardWidth, coverHeight: G.coverHeight(cardWidth:), frames: frames,
                                        sectionOf: sectionOf, headers: [nil, nil], columnGap: G.columnGap), res)
        }
        let (l3, _) = level(3), (l2, _) = level(2)
        let scene = GridZoomScene(levels: [l3, l2], anchorSlot: 1, anchorTop: 300, columnGap: G.columnGap, rowGap: G.rowGap)
        let ch = G.coverHeight(cardWidth:)
        for (lv, blend) in [(0, CGFloat(0)), (1, CGFloat(1))] {
            let p = scene.place(0, 1, width: scene.levels[lv].coverWidth, blend: blend, coverHeight: ch)
            let placed = lv == 0 ? p.a : p.b
            var same = true
            for (slot, frame) in scene.levels[lv].frames.enumerated() {
                let want = frame.offsetBy(dx: 0, dy: -scene.offsets[lv])
                same = same && near(placed[slot].cover.minX, want.minX, 0.5) && near(placed[slot].cover.minY, want.minY, 0.5)
                    && near(placed[slot].rect.height, want.height, 0.5)
            }
            require(same, "a level's own width and end of the blend IS its layout (level \(lv))")
        }
        var apart = true
        for k in 0...20 {
            let m = CGFloat(k) / 20
            let w = exp(log(l3.coverWidth) + (log(l2.coverWidth) - log(l3.coverWidth)) * m)
            let p = scene.place(0, 1, width: w, blend: m, coverHeight: ch)
            let bottom0 = (0..<5).map { max(p.a[$0].rect.maxY * (1 - m), 0) + p.b[$0].rect.maxY * m }.max()!
            let top1 = (5..<8).map { p.a[$0].cover.minY * (1 - m) + p.b[$0].cover.minY * m }.min()!
            apart = apart && top1 >= bottom0 - 1
        }
        require(apart, "the next block never runs into the pinched one, at any blend")

        // Sections: a page of headed sections, pinched in each, at three levels. Inside
        // ONE level's layer no section reaches into the next; each header stays between its section and the
        // one above; a level's own width and end of the blend is its rest layout; two pairs agree where they meet.
        do {
            func bands(_ n: Int) -> [CGFloat] { (0..<n).map { $0 % 3 == 0 ? 62 : 40 } }
            let sectioned: [LibraryGridLayoutModel.Block] = [
                .fixed(height: 30, spacing: 0), .grid(bands: bands(23), spacing: 14),
                .fixed(height: 30, spacing: 24), .grid(bands: bands(17), spacing: 14),
                .fixed(height: 30, spacing: 24), .grid(bands: bands(31), spacing: 14)]
            let gridBlocks = [1, 3, 5], headerBlocks = [0, 2, 4]
            let results = [4, 3, 2].map { LibraryGridLayoutModel.layout(sectioned, columns: $0, content: phone, originX: 16) }
            let stack = results.map { res -> GridZoomLevelLayout in
                var frames: [CGRect] = [], sectionOf: [Int] = []
                for (s, b) in gridBlocks.enumerated() { for i in res.ranges[b] { frames.append(res.frames[i]); sectionOf.append(s) } }
                return GridZoomLevelLayout(coverWidth: res.cardWidth, coverHeight: G.coverHeight(cardWidth:), frames: frames,
                                           sectionOf: sectionOf, headers: [nil, nil, nil], columnGap: G.columnGap)
            }
            var layerOverlap: CGFloat = 0, headerOut: CGFloat = 0, restDrift: CGFloat = 0, seam: CGFloat = 0
            for section in 0..<3 {
                for frac in [0.0, 0.3, 1.0] {
                    let count = stack[0].sectionOf.filter { $0 == section }.count
                    let slot = stack[0].sectionOf.firstIndex(of: section)! + Int(Double(count - 1) * frac)
                    let sc = GridZoomScene(levels: stack, anchorSlot: slot, anchorTop: 300, columnGap: G.columnGap, rowGap: G.rowGap)
                    for (a, b) in [(0, 1), (1, 2)] {
                        for k in 0...20 {
                            let m = CGFloat(k) / 20
                            let w = exp(log(stack[a].coverWidth) + (log(stack[b].coverWidth) - log(stack[a].coverWidth)) * m)
                            let p = sc.place(a, b, width: w, blend: m, coverHeight: ch)
                            let sp = sc.spans(a, b, blend: m, coverHeight: ch(w))
                            func extent(_ placed: [GridZoomScene.Placed], _ level: Int, _ s: Int) -> (CGFloat, CGFloat)? {
                                let cells = placed.indices.filter { stack[level].sectionOf[$0] == s && placed[$0].cover.width > 0 }
                                guard !cells.isEmpty else { return nil }
                                return (cells.map { placed[$0].cover.minY }.min()!, cells.map { placed[$0].rect.maxY }.max()!)
                            }
                            for s in 1..<3 {
                                for (placed, level) in [(p.a, a), (p.b, b)] {
                                    if let up = extent(placed, level, s - 1), let down = extent(placed, level, s) {
                                        layerOverlap = max(layerOverlap, up.1 - down.0)
                                    }
                                }
                            }
                            for s in 0..<3 {
                                func restHeader(_ l: Int) -> CGFloat? {
                                    sc.restOffset(ofElementAt: results[l].frames[results[l].ranges[headerBlocks[s]].lowerBound].minY, section: s, trailing: false, level: l)
                                }
                                var rest = [CGFloat](repeating: 0, count: 3)
                                rest[a] = restHeader(a)!; rest[b] = restHeader(b)!
                                let y = sc.elementY(a, b, spans: sp, blend: m, section: s, trailing: false, rest: rest)!
                                let top = sp.a[s]!.top + (sp.b[s]!.top - sp.a[s]!.top) * m
                                headerOut = max(headerOut, y + 30 - top)
                                if s > 0 {
                                    let above = sp.a[s - 1]!.bottom + (sp.b[s - 1]!.bottom - sp.a[s - 1]!.bottom) * m
                                    headerOut = max(headerOut, above - y)
                                }
                            }
                        }
                        // The seam: pair (a, b) at its end of the blend is level b's layer, as is (b, c) at its start.
                    }
                    let end = sc.place(0, 1, width: stack[1].coverWidth, blend: 1, coverHeight: ch)
                    let start = sc.place(1, 2, width: stack[1].coverWidth, blend: 0, coverHeight: ch)
                    for i in 0..<stack[1].frames.count {
                        seam = max(seam, abs(end.b[i].cover.minY - start.a[i].cover.minY), abs(end.b[i].cover.minX - start.a[i].cover.minX))
                    }
                    for lv in 0..<3 {
                        let nb = lv == 2 ? 1 : lv + 1
                        let p = lv == 2 ? sc.place(1, 2, width: stack[2].coverWidth, blend: 1, coverHeight: ch)
                                        : sc.place(lv, nb, width: stack[lv].coverWidth, blend: 0, coverHeight: ch)
                        let placed = lv == 2 ? p.b : p.a
                        for (i, f) in stack[lv].frames.enumerated() {
                            restDrift = max(restDrift, abs(placed[i].cover.minY - (f.minY - sc.offsets[lv])))
                        }
                    }
                }
            }
            require(layerOverlap <= 0.5, "sections: inside one level's layer no section reaches into the next, at any blend (worst \(layerOverlap) pt)")
            require(headerOut <= 0.5, "sections: a header stays between its section and the one above (worst \(headerOut) pt)")
            require(restDrift <= 0.5, "sections: a level's own width and end of the blend is its rest layout, every section (worst \(restDrift) pt)")
            require(seam <= 0.5, "sections: the pair's end of the blend is the next pair's start (worst \(seam) pt)")
            // The rows that meet the pinched section pair with each other: the last row of a section above, the first of one below.
            let pin = GridZoomScene(levels: stack, anchorSlot: stack[0].sectionOf.firstIndex(of: 1)! + 3, anchorTop: 300, columnGap: G.columnGap, rowGap: G.rowGap)
            let lastAbove = stack[0].sections[0].rows.last!.slots[0]
            let partnerAbove = pin.partner(slot: lastAbove, of: 0, in: 2)
            let firstBelow = stack[0].sections[2].rows.first!.slots[0]
            let partnerBelow = pin.partner(slot: firstBelow, of: 0, in: 2)
            require(partnerAbove != nil && stack[2].rowOf[partnerAbove!] == stack[2].sections[0].rows.count - 1
                    && partnerBelow != nil && stack[2].rowOf[partnerBelow!] == 0,
                    "sections: the last row above and the first row below the pinched section pair across levels")
        }

        // The mirrored zoom: a trailing-anchored lattice.
        var mirrored = GridZoomScene(levels: [l3, l2], anchorSlot: 1, anchorTop: 300, columnGap: G.columnGap, rowGap: G.rowGap)
        mirrored.anchor = .trailing; mirrored.row = phone
        for (lv, blend) in [(0, CGFloat(0)), (1, CGFloat(1))] {
            let p = mirrored.place(0, 1, width: mirrored.levels[lv].coverWidth, blend: blend, coverHeight: ch)
            let placed = lv == 0 ? p.a : p.b
            var same = true
            for (slot, frame) in mirrored.levels[lv].frames.enumerated() {
                same = same && near(placed[slot].cover.minX, frame.minX, 0.5) && near(placed[slot].cover.maxX, frame.maxX, 0.5)
            }
            require(same, "mirrored: a level's own width on the trailing lattice IS its rest frame, x included (level \(lv))")
        }
        do {
            // Full rows end on the trailing edge at every width; the left arm is unchanged.
            let mid = (l3.coverWidth * l2.coverWidth).squareRoot()
            let m = mirrored.place(0, 1, width: mid, blend: 0.5, coverHeight: ch)
            let left = scene.place(0, 1, width: mid, blend: 0.5, coverHeight: ch)
            let edge = 16 + phone
            var ends = true, leftSame = true
            for slot in 0..<l3.frames.count where l3.columnOf[slot] == 2 { ends = ends && near(m.a[slot].cover.maxX, edge, 0.5) }
            for slot in 0..<l3.frames.count { leftSame = leftSame && near(left.a[slot].cover.minX, 16 + CGFloat(l3.columnOf[slot]) * (mid + G.columnGap), 0.01) }
            require(ends, "mirrored: the last column ends on the trailing edge at every width")
            require(leftSame, "mirrored: the left arm (no trailing row) is today's lattice")
            // Places are counted from the trailing edge: 3-wide column 2 (the right one) pairs with 2-wide column 1.
            let right = (0..<l3.frames.count).first { l3.columnOf[$0] == 2 && l3.rowOf[$0] == 0 }!
            let rightPair = mirrored.partner(slot: right, of: 0, in: 1)
            require(rightPair != nil && l2.columnOf[rightPair!] == 1, "mirrored: partners are counted from the right")
        }

        // Reach: candidates over the rubber band's widths and a shift range hold the plain ones.
        let viewport = CGSize(width: 390, height: 700)
        let plain = scene.plan(0, 1, viewport: viewport, margin: 120, coverHeight: ch)
        let wide = scene.plan(0, 1, viewport: viewport, margin: 120, widths: [l3.coverWidth * 0.8, l2.coverWidth * 1.2],
                              shifts: -200...150, coverHeight: ch)
        require(Set(plain.aCandidates).isSubset(of: Set(wide.aCandidates)) && Set(plain.bCandidates).isSubset(of: Set(wide.bCandidates))
                && wide.aCandidates.count + wide.bCandidates.count >= plain.aCandidates.count + plain.bCandidates.count,
                "reach: the widened plan holds every plain candidate")
        require(plain.aFades.count == wide.aFades.count, "reach: same slots")

        // Fades: a quick two-step zoom is one blend; it settles.
        var fades = GridZoomFades(count: 3, level: 0)
        fades.update(t: 0.6, speed: 3); fades.advance(by: 0.05)
        fades.update(t: 1.6, speed: 3); fades.advance(by: 0.05)
        let b = fades.blend(t: 1.6)
        require(b.levels.contains(2) && b.share(of: 0) + b.share(of: 1) + b.share(of: 2) > 0.999,
                "a re-aim fades the new target in over what is shown, shares adding to 1")
        for _ in 0..<200 { fades.advance(by: 1.0 / 60) }
        require(fades.isSettled && fades.destination == 2 && fades.blend(t: 2).single == 2, "the fades settle on the destination")
        // The shared fade rate: one rate for every fade, following the pinch speed, never
        // faster than its slew; a slow pinch's fade takes the base time, a flick's the quick one.
        var slow = GridZoomFades(count: 3, level: 0), quickRate = GridZoomFades(count: 3, level: 0)
        slow.update(t: 0.7, speed: 0.2); quickRate.update(t: 0.7, speed: 4)
        var slowFrames = 0, quickFrames = 0
        while !slow.isSettled && slowFrames < 2000 { slow.advance(by: 1.0 / 120, speed: 0.2); slowFrames += 1 }
        while !quickRate.isSettled && quickFrames < 2000 { quickRate.advance(by: 1.0 / 120, speed: 4); quickFrames += 1 }
        require(slowFrames > 2 * quickFrames && Double(slowFrames) / 120 > 0.5 && Double(quickFrames) / 120 < 0.5,
                "fades: a flick's dissolve is quicker than a crawl's (\(slowFrames) vs \(quickFrames) frames at 120 Hz)")
        // Lag (the leaver bound): a fast in-out leaves no stale picture past the bound.
        var lagFades = GridZoomFades(count: 3, level: 2), lag = GridZoomLag(bound: 0.1)
        var tt: CGFloat = 2
        var staleSince: Int? = nil, worstStale = 0, sharesOK = true
        for f in 0..<240 {
            tt = f < 40 ? 2 - 2 * CGFloat(f) / 40 : (f < 80 ? CGFloat(f - 40) * 2 / 40 : 2)   // quick in to level 0 and back
            lagFades.update(t: tt, speed: 5); lagFades.advance(by: 1.0 / 120, speed: 5)
            lag.advance(by: 1.0 / 120, fades: lagFades, t: tt)
            let bl = lag.blend(fades: lagFades, t: tt)
            let pair = GridZoomLag.pair(around: tt, count: 3)
            let dest = lagFades.destination
            let stale = bl.levels.contains { !pair.contains($0) && $0 != dest && bl.share(of: $0) > 0.02 }
            if stale { staleSince = staleSince ?? f } else { staleSince = nil }
            if let since = staleSince { worstStale = max(worstStale, f - since) }
            var total: CGFloat = 0
            for l in bl.levels { total += bl.share(of: l) }
            sharesOK = sharesOK && near(total, 1, 0.001)
        }
        require(sharesOK, "lag: shares add to 1 in every frame")
        require(worstStale <= 14, "lag: a picture outside the geometry's pair and the destination is gone within ~0.1 s (\(worstStale) frames)")
        // Geometry follows the coordinate (zoom-latency): the weight is the coordinate's progress.
        require(near(GridZoomFeel.geometryWeight(progress: 0.37), 0.37, 1e-6), "geometry: the page follows the coordinate itself")
        // The line: anchors by where the pinch starts, the centre zone's width, the centre chain.
        require(GridZoomCentre.anchor(startX: 50, width: 390).anchor == .leading && GridZoomCentre.anchor(startX: 200, width: 390).anchor == .centre
                && GridZoomCentre.anchor(startX: 340, width: 390).anchor == .trailing, "centre: equal thirds pick leading / centre / trailing")
        require(GridZoomCentre.anchor(startX: 130, width: 390, centreZone: 20).anchor == .leading && GridZoomCentre.anchor(startX: 130, width: 390, centreZone: 60).anchor == .centre,
                "centre: the zone's width decides (20 % leaves 130 on the left, 60 % takes it)")
        require(GridZoomCentre.steps(anchor: .leading, columns: [4, 3, 2], start: 0) == [0, 1, 2]
                && GridZoomCentre.steps(anchor: .centre, columns: [4, 3, 2], start: 0)! == [0, 2], "centre: the 2-step chain skips the odd level, a side line runs over every level")
        require(GridZoomCentre.chain(columns: [4, 3], start: 0) == nil || GridZoomCentre.chain(columns: [4, 3], start: 0)! == [0, 1], "centre: no same-parity level falls back to the side")
        // Clicks: one per level crossed, one limit bump entering the rubber band.
        var dec = GridZoomHapticDecider(level: 2)
        var events: [GridZoomHapticDecider.Event] = []
        for t in stride(from: CGFloat(2), through: -0.2, by: -0.05) { events += dec.update(t: t, count: 3) }
        require(events.filter { $0 == .step }.count == 2 && events.filter { $0 == .limit }.count == 1, "haptics: a step click per level crossed and one limit click (\(events))")
        // The centre-anchored lattice (4 and 2 columns, same parity): a level's own width IS its rest frame, columns come in pairs.
        do {
            let (l4, _) = level(4)
            var centre = GridZoomScene(levels: [l4, l2], anchorSlot: 1, anchorTop: 300, columnGap: G.columnGap, rowGap: G.rowGap)
            centre.anchor = .centre; centre.row = phone
            for (lv, blend) in [(0, CGFloat(0)), (1, CGFloat(1))] {
                let p = centre.place(0, 1, width: centre.levels[lv].coverWidth, blend: blend, coverHeight: ch)
                let placed = lv == 0 ? p.a : p.b
                var same = true
                for (slot, frame) in centre.levels[lv].frames.enumerated() where centre.levels[lv].columnOf[slot] >= 0 {
                    same = same && near(placed[slot].cover.minX, frame.minX, 0.5) && near(placed[slot].cover.maxX, frame.maxX, 0.5)
                }
                require(same, "centre: a level's own width on the centre lattice IS its rest frame, x included (level \(lv))")
            }
            let mid = (l4.coverWidth * l2.coverWidth).squareRoot()
            let m = centre.place(0, 1, width: mid, blend: 0.5, coverHeight: ch)
            var mirroredAbout = true
            for slot in 0..<l4.frames.count where l4.rowOf[slot] == 0 && l4.sectionOf[slot] == 0 {
                let col = l4.columnOf[slot]
                let twin = (0..<l4.frames.count).first { l4.sectionOf[$0] == 0 && l4.rowOf[$0] == 0 && l4.columnOf[$0] == 3 - col }
                if let twin, m.a[slot].cover.width > 0 {
                    mirroredAbout = mirroredAbout && near(m.a[slot].cover.midX + m.a[twin].cover.midX, 16 * 2 + phone, 0.5)
                }
            }
            require(mirroredAbout, "centre: columns sit symmetrically about the middle at every width")
            let left = (0..<l4.frames.count).first { l4.columnOf[$0] == 1 && l4.rowOf[$0] == 0 && l4.sectionOf[$0] == 0 }!
            let pair = centre.partner(slot: left, of: 0, in: 1)
            require(pair != nil && l2.columnOf[pair!] == 0, "centre: 4-wide column 1 pairs with 2-wide column 0 (columns arrive in pairs)")
        }
        // A blend that has become one level before the fades settle is the resting pair, never a pair of one level.
        var quick = GridZoomFades(count: 3, level: 0)
        quick.update(t: 0.6, speed: 3); quick.advance(by: 0.02)
        quick.update(t: 1.6, speed: 3); quick.advance(by: 0.02)
        var lone = true
        for _ in 0..<400 {
            quick.advance(by: 1.0 / 120)
            let bl = quick.blend(t: 1.6)
            if bl.overlays.isEmpty && bl.lower == bl.upper { lone = false }
        }
        require(lone, "a blend that became one level is drawn as the resting pair")
        let rest = GridZoomFades(count: 3, level: 0).restingPair(1, t: 1.4)
        require(rest.lower == 1 && rest.upper == 2 && rest.weight == 0, "restingPair: the level and its neighbour on t's side")
        let spring = GridZoomTransition.Spring(from: 0.7, to: 1, velocity: 2)
        require(spring.isSettled(at: 3) && near(spring.value(at: 0), 0.7), "the release spring starts where it was let go and settles")
        require(GridZoomTransition.settleLevel(coordinate: 1.4, velocity: 6, levels: 3) == 2, "a flick carries the release one level on")
        exit(failures == 0 ? 0 : 1)
    }
}
'''

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'geometry.swift').write_text('import CoreGraphics\nimport Foundation\n' + geometry)
    (tmp / 'checks.swift').write_text(checks)
    out = tmp / 'checks'
    build = subprocess.run([SWIFTC, '-parse-as-library', '-o', str(out), str(app / 'LibraryGridZoomModel.swift'),
                            str(app / 'LibraryGridZoomScene.swift'), str(tmp / 'geometry.swift'), str(tmp / 'checks.swift')],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stdout + build.stderr)
        require(False, 'the zoom model and geometry compile on the host')
    else:
        run = subprocess.run([str(out)], capture_output=True, text=True)
        print(run.stdout, end='')
        if run.returncode != 0:
            failures += 1

# ------------------------------------------------------------------ the deferred-work gate
gate_checks = r'''
import Foundation

@main
struct GateChecks {
    static var failures = 0
    static func require(_ ok: Bool, _ label: String) {
        print((ok ? "PASS: " : "FAIL: ") + label)
        if !ok { failures += 1 }
    }
    @MainActor static func main() {
        var clock: TimeInterval = 1000
        let gate = DeferredMainWork()
        gate.now = { clock }
        var runs = 0
        gate.schedule(key: "a", delay: 0) { runs += 1; clock += 0.003; return true }
        clock += 1
        require(gate.runSlice() && runs >= 1, "gate: a job runs once nothing interacts")
        // A token holds it shut; closing it waits out the quiet period.
        let before = runs
        let token = gate.beginInteraction("touch")
        clock += 1
        require(!gate.runSlice() && runs == before, "gate: an open interaction runs nothing")
        gate.endInteraction(token)
        require(!gate.runSlice() && runs == before, "gate: nothing runs inside the quiet period")
        clock += 1
        _ = gate.runSlice()
        require(runs > before, "gate: it runs again after the quiet period")
        gate.cancel(key: "a")
        // A polled condition (the busy signal) closes it too.
        final class Owner {}
        let owner = Owner()
        var busy = true
        gate.addCondition("busy", owner: owner) { busy }
        gate.schedule(key: "b", delay: 0) { runs += 10; clock += 0.003; return false }
        clock += 1
        let at = runs
        require(!gate.runSlice() && runs == at, "gate: a busy condition (a finger, a coast) runs nothing")
        busy = false
        clock += 1
        _ = gate.runSlice()
        clock += 1
        _ = gate.runSlice()
        require(runs >= at + 10, "gate: the job runs when the condition clears")
        // Resubmitting a key replaces the job and restarts its delay (the debounce).
        gate.cancel(key: "b")
        var which = ""
        gate.schedule(key: "c", delay: 5) { which = "first"; return false }
        gate.schedule(key: "c", delay: 0) { which = "second"; return false }
        clock += 1
        _ = gate.runSlice()
        clock += 1
        _ = gate.runSlice()
        require(which == "second", "gate: resubmitting a key replaces the job")
        exit(failures == 0 ? 0 : 1)
    }
}
'''
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'gate.swift').write_text(gate_checks)
    out = tmp / 'gate'
    build = subprocess.run([SWIFTC, '-parse-as-library', '-o', str(out), str(app / 'DeferredMainWork.swift'), str(tmp / 'gate.swift')],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stdout + build.stderr)
        require(False, 'the deferred-work gate compiles on the host')
    else:
        run = subprocess.run([str(out)], capture_output=True, text=True)
        print(run.stdout, end='')
        if run.returncode != 0:
            failures += 1

# ------------------------------------------------------------------ plumbing
frame_rate = (app / 'InteractionFrameRate.swift').read_text()
require('else { self.detachObserver() }' in frame_rate
        and 'private func detachObserver() {' in between(frame_rate, 'private func detachObserver()', 'private func detach()' )
        and 'defaultsObserver' not in between(frame_rate, 'private func detachObserver()', 'private func detach()'),
        'touch frame rate: switching the setting off keeps the defaults observer, so switching it on re-attaches')

cover_cache = (app / 'LibraryCoverCache.swift').read_text()
require('.modificationDate' in cover_cache and '"file-\\(leaf)-\\(' in cover_cache
        and 'LibraryCoverCache.Source.coverFile(named: name).key' in host,
        'covers: a chosen cover file is keyed by name and modification time, in the cache and in the grid (a re-picked cover is a new key)')
require('Self(key: key, file: file, urls: steamID.map { steam($0).urls } ?? [])' in cover_cache,
        'covers: a chosen cover whose file cannot be read falls back to the store match\'s candidates')

require('accessibilityTraits = .adjustable' in host and 'override func accessibilityIncrement() { host?.stepCardSize(-1) }' in host
        and 'view.accessibilityElements = [size, collection]' in host and 'func stepCardSize(_ steps: Int)' in host,
        'accessibility: an adjustable "Card size" element steps the level without a pinch (the card-size menu items stay out)')

off_write = between(library, 'if !LibraryGridArm.enabled {\n            LibraryFileWriter.drain()', 'if wait {')
require('try LibraryFileWriter.encode(next, to: file)' in off_write
        and 'static func encode(_ entries: [LibraryEntry], to file: URL) throws {' in library
        and 'encoder.encode(Document(version: 1, entries: entries)).write(to: file, options: .atomic)' in library
        and 'static func drain()' in library and 'if used { shared.queue.sync {} }' in library,
        'writes: with the setting off the library is written as upstream writes it, after a queued write lands')

require('static func dismantleUIViewController(_ controller: LibraryGridHostController, coordinator: ()) { controller.tearDown() }' in host
        and 'zoom?.teardown()' in between(host, 'func tearDown() {', '/// A page update that waited')
        and 'discardZoomStart()' in between(host, 'func tearDown() {', '/// A page update that waited'),
        'host: dismantling the grid stops the zoom session\'s and the start driver\'s display links')

require('metadataMovesCards = i.sort == "size" || i.sort == "added"' in page,
        'page: a metadata change that can create an entry takes the full build under sort by added, as under size')

require('glowModeObserver = NotificationCenter.default.addObserver(forName: AmbientGlowSettings.changed' in host
        and 'removeObserver(glowModeObserver)' in host, 'host: the glow-mode observer\'s token is kept and removed with the host')

glow = (app / 'LibraryGridGlow.swift').read_text()
require('LibraryGridArm.releaseMemory' in glow and 'UIApplication.didReceiveMemoryWarningNotification' in glow
        and 'if window == nil { releaseResources() } else { restoreDrawables() }' in glow
        and 'NotificationCenter.default.post(name: LibraryGridArm.releaseMemory' in library,
        'memory: the glow\'s textures go on a memory warning and a game start, the drawables when the library is off screen')
require('static let diskCap = 300 * 1024 * 1024' in cover_cache and 'static func trimDisk(cap: Int)' in cover_cache
        and 'setAttributes([.modificationDate: Date()]' in cover_cache and 'func releaseMemory()' in cover_cache,
        'memory: the cover files on disk are capped at 300 MB (least recently used first); a game start frees the decoded bitmaps')

print('check-library-zoom: ' + ('PASS' if failures == 0 else f'FAIL ({failures})'))
sys.exit(0 if failures == 0 else 1)
