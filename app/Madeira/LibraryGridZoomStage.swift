// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit

// What a zoom draws (docs/zoomable-grid.md, section 3). Per card and level a
// cover view (the artwork, its placeholder and the not-downloaded and
// download overlays) that scales, and a label that does not; per page element (Desktop button, headers, notices) a stand-in. All
// are built and inserted at the begin, hidden; a frame only moves, scales and fades them inside one CATransaction with actions
// off, and never asks the collection view for a layout. The real cells are hidden for the zoom and come back at the landing.

/// A card's artwork, as the card draws it: the zoom's stand-in, and the cover of the
/// zoomable grid's UIKit card cell (LibraryGridCardCell), so the two cannot differ.
final class LibraryGridZoomCover: UIView {
    enum Overlay: Equatable { case none, notDownloaded, queued, active(Double), paused, failed }

    let art = CALayer()
    private let glyph = UIImageView()
    private let dim = UIView()
    private let mark = UIImageView()
    private(set) var exact = false
    private(set) var restArt: CGSize
    private(set) var overlay: Overlay

    init(artSize: CGSize, overlay: Overlay, traits: UITraitCollection?) {
        restArt = artSize
        self.overlay = overlay
        super.init(frame: CGRect(origin: .zero, size: artSize))
        isUserInteractionEnabled = false
        // Rounded without an offscreen pass: the corners are on each layer that draws, and none clips its sublayers.
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.masksToBounds = false
        dim.layer.cornerRadius = 12
        dim.layer.cornerCurve = .continuous
        art.cornerRadius = 12
        art.cornerCurve = .continuous
        backgroundColor = .secondarySystemFill
        let config = UIImage.SymbolConfiguration(textStyle: .largeTitle)
        glyph.image = UIImage(systemName: "gamecontroller.fill", withConfiguration: config)
        glyph.tintColor = .secondaryLabel
        glyph.sizeToFit()
        addSubview(glyph)
        art.contentsGravity = .resizeAspectFill
        art.masksToBounds = true
        layer.addSublayer(art)
        addSubview(dim)
        mark.tintColor = .white
        dim.addSubview(mark)
        apply(overlay)
        layoutArt()
        if let traits { traitOverrides.userInterfaceStyle = traits.userInterfaceStyle }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The placeholder fill, opaque: the secondary fill composited over the page's background, in each appearance. A translucent
    /// fill would let the outgoing art of a crossfade show through it.
    static var placeholderFill: UIColor {
        return UIColor { traits in
            let ground = UIColor.systemGroupedBackground.resolvedColor(with: traits)
            let fill = UIColor.secondarySystemFill.resolvedColor(with: traits)
            var g: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            var f: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            ground.getRed(&g.0, green: &g.1, blue: &g.2, alpha: &g.3)
            fill.getRed(&f.0, green: &f.1, blue: &f.2, alpha: &f.3)
            return UIColor(red: g.0 + (f.0 - g.0) * f.3, green: g.1 + (f.1 - g.1) * f.3,
                           blue: g.2 + (f.2 - g.2) * f.3, alpha: 1)
        }
    }

    /// What lies under the art is drawn only while there is no art: with an image the placeholder fill and glyph would be per-card
    /// overdraw for the render server.
    private func refreshBase() {
        let hasArt = art.contents != nil
        backgroundColor = hasArt ? nil : Self.placeholderFill
        glyph.isHidden = hasArt || overlay == .notDownloaded
    }

    /// `fadeIn`: art that arrives on a card showing its placeholder comes in over it (a short dissolve, never from a previous game's cover).
    func setImage(_ image: UIImage?, exact: Bool, fadeIn: Bool = false) {
        let arriving = fadeIn && image != nil && art.contents == nil
        art.removeAnimation(forKey: "arrive")
        self.exact = exact
        // `art` is a plain sublayer: set with actions on, its contents cross-dissolve from the previous image (a reused cell's old game).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.contents = image?.cgImage
        CATransaction.commit()
        refreshBase()
        if arriving {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.15
            art.add(fade, forKey: "arrive")
        }
    }

    func resize(to artSize: CGSize) {
        guard artSize != restArt else { return }
        restArt = artSize
        bounds.size = artSize
        layoutArt()
    }

    private func layoutArt() {
        let b = CGRect(origin: .zero, size: restArt)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.frame = b
        CATransaction.commit()
        dim.frame = b
        glyph.center = CGPoint(x: b.midX, y: b.midY)
        mark.center = glyph.center
    }

    func setOverlay(_ overlay: Overlay) {
        guard overlay != self.overlay else { return }
        self.overlay = overlay
        apply(overlay)
    }

    private func apply(_ overlay: Overlay) {
        let config = UIImage.SymbolConfiguration(textStyle: .largeTitle)
        refreshBase()
        dim.isHidden = overlay == .none
        mark.tintColor = .white
        mark.alpha = 1
        switch overlay {
        case .none:
            mark.image = nil
        case .notDownloaded:
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            mark.image = UIImage(systemName: "icloud.and.arrow.down", withConfiguration: config.applying(UIImage.SymbolConfiguration(weight: .medium)))
            mark.alpha = 0.5
        case .queued:
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            mark.image = UIImage(systemName: "clock", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title2))
        case .paused:
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            mark.image = UIImage(systemName: "pause.circle.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title1))
        case .failed:
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            mark.image = UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title2))
            mark.tintColor = .systemYellow
        case .active(let fraction):
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            mark.image = Self.ring(fraction)
        }
        mark.sizeToFit()
        mark.center = glyph.center
    }

    private static func ring(_ fraction: Double) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22), format: libraryStandardRangeFormat()).image { _ in
            let rect = CGRect(x: 2, y: 2, width: 18, height: 18)
            UIColor.white.withAlphaComponent(0.3).setStroke()
            let track = UIBezierPath(ovalIn: rect); track.lineWidth = 3; track.stroke()
            UIColor.white.setStroke()
            let arc = UIBezierPath(arcCenter: CGPoint(x: 11, y: 11), radius: 9, startAngle: -.pi / 2,
                                   endAngle: -.pi / 2 + 2 * .pi * max(0.02, min(1, fraction)), clockwise: true)
            arc.lineWidth = 3; arc.lineCapStyle = .round; arc.stroke()
        }
    }
}

final class LibraryGridZoomCell {
    let cover: LibraryGridZoomCover
    let label: UIView
    let labelImage: UIImageView?
    let restWidth: CGFloat
    let labelSize: CGSize
    var labelReady: Bool
    var shownArt = CGRect.zero
    var views: [UIView] { [cover, label] }

    init(cover: LibraryGridZoomCover, label: UIView, labelImage: UIImageView?, restWidth: CGFloat, labelSize: CGSize, labelReady: Bool) {
        self.cover = cover
        self.label = label
        self.labelImage = labelImage
        self.restWidth = restWidth
        self.labelSize = labelSize
        self.labelReady = labelReady
    }
}

@MainActor
final class LibraryGridZoomStage {
    unowned let session: LibraryGridZoomSession
    weak var collection: UICollectionView?
    private let container = UIView()
    private(set) var cells: [[Int: LibraryGridZoomCell]]
    private var shown: [ObjectIdentifier: LibraryGridZoomCell] = [:]
    struct Element {
        let view: UIView
        let ys: [CGFloat]
        let rowsAbove: [Int]
        /// The section it leads (a header, a notice) or, trailing, the last one it follows; per level its rest distance from that section (`GridZoomScene.elementY`). Nil: no section.
        let section: Int?
        let trailing: Bool
        let rest: [CGFloat]
    }
    private(set) var elements: [Element] = []
    private var labelImages: [[Int: UIImage]]
    private var lastCoverCheck: CFTimeInterval = 0
    private let traits: UITraitCollection
    private let scale: CGFloat
    private var labelWork: LabelWork?

    init(session: LibraryGridZoomSession, collection: UICollectionView) {
        self.session = session
        self.collection = collection
        cells = Array(repeating: [:], count: session.levels.count)
        labelImages = Array(repeating: [:], count: session.levels.count)
        traits = collection.traitCollection
        scale = collection.traitCollection.displayScale
        container.isUserInteractionEnabled = false
        container.accessibilityElementsHidden = true
    }

    // MARK: Building

    /// The stage in two halves: the cells are adopted ahead of a pinch, one at a time, hidden, in a container not in the hierarchy
    /// yet; `present()` is all that is left for the pinch's begin: the container goes in, the real cells go, the stand-ins are made.
    private(set) var presented = false

    @discardableResult
    func adopt(level: Int, slot: Int) -> Bool {
        guard cells[level][slot] == nil, let host else { return false }
        return buildCell(level: level, slot: slot, host: host) != nil
    }

    func adoptAll() {
        let start = session.startLevel
        for level in session.levels.indices.sorted(by: { abs($0 - start) < abs($1 - start) }) {
            for slot in session.needed[level].sorted() { adopt(level: level, slot: slot) }
        }
    }

    /// The labels of the cells a first frame draws are drawn now when the background has not got to them (never a blank band).
    private func ensureStartLabels() {
        guard let host else { return }
        let start = session.startLevel
        let viewport = CGRect(origin: .zero, size: session.viewport)
        let fonts = LibraryCardLabel.Fonts.current(traits)
        for (slot, cell) in cells[start] where !cell.labelReady {
            let frame = session.scene.levels[start].frames[slot]
            guard frame.width > 0, frame.offsetBy(dx: 0, dy: -session.scene.offsets[start]).intersects(viewport),
                  case .card(let card) = host.items[session.slots[slot]], let label = host.labels[card] else { continue }
            let image = label.image(size: cell.labelSize, fonts: fonts, traits: traits)
            labelImages[start][slot] = image
            cell.labelImage?.image = image
            cell.labelReady = true
        }
    }

    func present() {
        guard let collection, let host, !presented else { return }
        presented = true
        func mark(_ name: String) {}
        finishPendingFixed()
        if cells.allSatisfy({ $0.isEmpty }) { adoptAll() }   // nothing was prepared
        mark("adopt")
        park()   // a stage prepared at rest is parked already; this is then a no-op
        container.isHidden = false
        container.frame = CGRect(x: 0, y: 0, width: collection.bounds.width, height: 0)
        mark("attach")
        ensureStartLabels()
        mark("labels")
        // The page's other elements: a snapshot of the real view, else the same SwiftUI view. The real cells go.
        var liveFixed: [Int: UIView] = [:]
        let start = session.startLevel
        let startPage = session.levels[start].page.result
        let slotSet = Set(session.slots)
        for path in collection.indexPathsForVisibleItems where !slotSet.contains(path.item) {
            if let cell = collection.cellForItem(at: path), let snapshot = cell.snapshotView(afterScreenUpdates: false) {
                liveFixed[path.item] = snapshot
            }
        }
        for (item, ready) in prebuiltFixed where liveFixed[item] != nil { ready.removeFromSuperview() }   // on screen now: its snapshot is used
        mark("snap")
        for cell in collection.visibleCells { Self.hold(cell, true) }
        hideGlows(true)
        mark("hide")
        for item in session.fixedItems {
            let frame = startPage.frames[item]
            let view: UIView
            var hosted = false
            if let snapshot = liveFixed[item] {
                view = snapshot
            } else if let ready = prebuiltFixed[item] {
                view = ready
            } else if let built = hostFixed(item, frame: frame) {
                view = built
                hosted = true
            } else { continue }
            view.frame = frame
            view.isUserInteractionEnabled = false
            container.addSubview(view)
            // A hosted view built off screen draws nothing until it is laid out in a window: one that slid on screen mid-zoom would be blank or late.
            if hosted { Self.renderInWindow(view) }
            let block = startPage.ranges.firstIndex { $0.contains(item) } ?? 0
            // Kept to its section: an element before a grid leads the next section, one after the last grid trails it, so a header
            // rides with its rows in every layer, which can drift from the rule-based place by the label bands' glide.
            let grids = host.blocks.indices.filter { if case .grid = host.blocks[$0].kind { return true } else { return false } }
            let lead = grids.filter { $0 < block }.count
            let trailing = lead >= grids.count
            let section = grids.isEmpty ? nil : (trailing ? grids.count - 1 : lead)
            var rest: [CGFloat] = []
            for level in session.levels.indices {
                let y = session.levels[level].page.result.frames[item].minY
                rest.append(section.flatMap { session.scene.restOffset(ofElementAt: y, section: $0, trailing: trailing, level: level) } ?? .nan)
            }
            elements.append(Element(view: view, ys: session.levels.map { $0.page.result.frames[item].minY },
                                    rowsAbove: session.levels.map { $0.page.result.rowsAbove[block] },
                                    section: rest.allSatisfy({ !$0.isNaN }) ? section : nil, trailing: trailing, rest: rest))
        }
        mark("fixed")
        renderLabels(preferring: session.levels.indices.sorted { abs($0 - start) < abs($1 - start) })
        mark("labelJob")
    }

    /// The page's other elements that are not on screen, as SwiftUI views: creating and laying out a hosting controller is slow inside a pinch's first frame, so a prepared stage makes them at rest.
    private var prebuiltFixed: [Int: UIView] = [:]

    private func hostFixed(_ item: Int, frame: CGRect) -> UIView? {
        makeHosting(item, frame: frame)?()
    }

    /// A stand-in in two halves: this makes the hosting controller and returns what loads and sets up the view, so the halves can run in different steps.
    private func makeHosting(_ item: Int, frame: CGRect) -> (() -> UIView)? {
        guard let host, let props = host.props, case .fixed(let id) = host.items[item], let fixed = host.fixedByID[id] else { return nil }
        let hosting = UIHostingController(rootView: props.fixed(fixed).frame(width: frame.width, height: frame.height, alignment: .topLeading))
        return {
            hosting.view.backgroundColor = .clear
            hosting.safeAreaRegions = []
            return hosting.view
        }
    }

    /// Called at rest once the container is parked: every off-screen fixed element is built and laid out in it, one piece per call
    /// (controller made; view loaded and inserted; laid out), so no call holds a frame. True while more remains.
    func stepFixedAhead() -> Bool {
        guard let collection, !presented, container.superview != nil else { return false }
        if let loading = fixedAwaitingView {
            fixedAwaitingView = nil
            fixedAwaitingLayout = insert(loading)
            return true
        }
        if let waiting = fixedAwaitingLayout {
            fixedAwaitingLayout = nil
            Self.renderInWindow(waiting.view)
            prebuiltFixed[waiting.item] = waiting.view
            return true
        }
        if fixedAheadQueue == nil {
            let visible = Set(collection.indexPathsForVisibleItems.map(\.item))
            fixedAheadQueue = session.fixedItems.filter { !visible.contains($0) && prebuiltFixed[$0] == nil }
        }
        while let item = fixedAheadQueue?.first {
            fixedAheadQueue?.removeFirst()
            let frame = session.levels[session.startLevel].page.result.frames[item]
            guard let load = makeHosting(item, frame: frame) else { continue }
            fixedAwaitingView = (item, frame, load)
            return true
        }
        return false
    }

    private func insert(_ made: (item: Int, frame: CGRect, load: () -> UIView)) -> (item: Int, view: UIView) {
        let view = made.load()
        view.frame = made.frame
        view.isUserInteractionEnabled = false
        container.addSubview(view)
        return (made.item, view)
    }

    private var fixedAheadQueue: [Int]?
    private var fixedAwaitingView: (item: Int, frame: CGRect, load: () -> UIView)?
    private var fixedAwaitingLayout: (item: Int, view: UIView)?

    /// The piece a begin cannot leave half done: a stand-in made but not yet laid out is laid out now.
    private func finishPendingFixed() {
        if let loading = fixedAwaitingView {
            fixedAwaitingView = nil
            fixedAwaitingLayout = insert(loading)
        }
        guard let waiting = fixedAwaitingLayout else { return }
        fixedAwaitingLayout = nil
        Self.renderInWindow(waiting.view)
        prebuiltFixed[waiting.item] = waiting.view
    }

    /// Parked: the container sits in the collection view, hidden, behind UIKit's scroll-edge view, so the first insertion of dozens of never-shown views is paid at rest.
    func park() {
        guard let collection, container.superview == nil else { return }
        container.isHidden = true
        if let edge = collection.subviews.first(where: { NSStringFromClass(type(of: $0)).hasPrefix("_UITouchPassthrough") }) {
            collection.insertSubview(container, belowSubview: edge)
        } else {
            // No edge view (the simulator): at the back, never in front of anything UIKit adds later.
            collection.insertSubview(container, at: 0)
        }
        container.frame = CGRect(x: 0, y: 0, width: collection.bounds.width, height: 0)
    }

    func parkIfNeeded() -> Bool {
        guard container.superview == nil, collection != nil else { return false }
        park()
        return true
    }

    func drawLabelsAhead() {
        renderLabels(preferring: session.levels.indices.sorted { abs($0 - session.startLevel) < abs($1 - session.startLevel) })
    }

    func discard() {
        guard !presented else { return }
        labelWork?.cancelled = true
        host?.zoomCells.keep(cells: cells, session: session)
        cells = Array(repeating: [:], count: session.levels.count)
        container.removeFromSuperview()
    }

    @discardableResult
    private func buildCell(level: Int, slot: Int, host: LibraryGridHostController) -> LibraryGridZoomCell? {
        if let made = cells[level][slot] { return made }
        let item = session.slots[slot]
        let frame = session.levels[level].page.result.frames[item]
        let w = frame.width
        let band = CGSize(width: w, height: max(1, frame.height - LibraryGridGeometry.coverHeight(cardWidth: w)))
        let cell: LibraryGridZoomCell
        if case .card(let card) = host.items[item], let kept = host.zoomCells.take(card: card, width: w, level: level, slot: slot) {
            cell = kept
            cell.cover.setOverlay(host.page.overlay(for: host.items[item]))
            // A kept cover may predate a better one now cached; shown stale it pops on the first tick.
            if !cell.cover.exact, let source = LibraryGridHostController.coverSource(card, page: host.page),
               let found = LibraryCoverCache.shared.image(for: source, pixelWidth: Int((cell.cover.restArt.width * scale).rounded(.up))) {
                cell.cover.setImage(found.image, exact: found.exact)
            }
            if let image = cell.labelImage?.image { labelImages[level][slot] = image }
        } else {
            let art = LibraryGridGeometry.artworkRect(cardWidth: w).size
            let cover = LibraryGridZoomCover(artSize: art, overlay: host.page.overlay(for: host.items[item]), traits: traits)
            if case .card(let card) = host.items[item], let source = LibraryGridHostController.coverSource(card, page: host.page) {
                let found = LibraryCoverCache.shared.image(for: source, pixelWidth: Int((art.width * scale).rounded(.up)))
                cover.setImage(found?.image, exact: found?.exact ?? false)
            }
            let image = UIImageView(frame: CGRect(origin: .zero, size: band))
            image.contentMode = .scaleAspectFit
            cell = LibraryGridZoomCell(cover: cover, label: image, labelImage: image, restWidth: w, labelSize: band, labelReady: false)
        }
        for view in cell.views {
            view.isHidden = true
            view.layer.zPosition = 0.5 + CGFloat(level) * 0.01
            container.addSubview(view)
        }
        cells[level][slot] = cell
        return cell
    }

    /// The other levels' labels, drawn off the main thread (one image each), the level `preferring` first and what is on screen
    /// first; until one is drawn the nearest level's is shown. A band is never drawn at the begin.
    private func renderLabels(preferring preferred: [Int]) {
        guard let host else { return }
        let labels = host.labels
        let fonts = LibraryCardLabel.Fonts.current(traits)
        let s = session
        let viewport = CGRect(origin: .zero, size: s.viewport)
        func rank(_ level: Int, _ slot: Int) -> Int {
            let frame = s.scene.levels[level].frames[slot]
            let onScreen = frame.width > 0 && frame.offsetBy(dx: 0, dy: -s.scene.offsets[level]).intersects(viewport)
            return (onScreen ? 0 : 100) + (preferred.firstIndex(of: level) ?? preferred.count)
        }
        var jobs: [(level: Int, slot: Int, label: LibraryCardLabel, size: CGSize, rank: Int)] = []
        for level in cells.indices {
            for (slot, cell) in cells[level] where !cell.labelReady {
                guard case .card(let card) = host.items[s.slots[slot]], let label = labels[card] else { continue }
                jobs.append((level, slot, label, cell.labelSize, rank(level, slot)))
            }
        }
        let anchor = s.anchor
        jobs.sort { ($0.rank, abs($0.slot - anchor)) < ($1.rank, abs($1.slot - anchor)) }
        let traits = self.traits
        let token = LabelWork()
        labelWork?.cancelled = true
        labelWork = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var batch: [(Int, Int, UIImage)] = []
            for job in jobs {
                if token.cancelled { return }
                batch.append((job.level, job.slot, job.label.image(size: job.size, fonts: fonts, traits: traits)))
                if batch.count == 12 {
                    let done = batch; batch = []
                    DispatchQueue.main.async { if !token.cancelled { self?.labelsDrawn(done) } }
                }
            }
            let done = batch
            DispatchQueue.main.async { if !token.cancelled { self?.labelsDrawn(done) } }
        }
    }

    /// A settle began: the landing level's bands are drawn first (the pass in flight is stopped and started again over what is left).
    func prioritizeLabels(landing level: Int) {
        let others = cells.indices.filter { $0 != level }.sorted { abs($0 - level) < abs($1 - level) }
        renderLabels(preferring: [level] + others)
    }

    private final class LabelWork { var cancelled = false }

    private var host: LibraryGridHostController? { session.host }

    private func labelsDrawn(_ drawn: [(Int, Int, UIImage)]) {
        for (level, slot, image) in drawn {
            labelImages[level][slot] = image
            if let cell = cells[level][slot], let view = cell.labelImage {
                view.image = image
                cell.labelReady = true
            }
        }
    }

    private func fallbackLabel(level: Int, slot: Int) -> UIImage? {
        for d in 1..<max(2, cells.count) {
            for l in [level - d, level + d] where cells.indices.contains(l) {
                if let image = labelImages[l][slot] { return image }
                if let cell = cells[l][slot], cell.labelImage == nil, cell.labelReady {
                    // The live band, as a bitmap: once per card (the next level asks the cache).
                    let image = UIGraphicsImageRenderer(bounds: cell.label.bounds, format: libraryStandardRangeFormat()).image { _ in
                        cell.label.drawHierarchy(in: cell.label.bounds, afterScreenUpdates: false)
                    }
                    labelImages[l][slot] = image
                    return image
                }
            }
        }
        return nil
    }

    // MARK: Glows and real views

    private func hideGlows(_ hidden: Bool) {
        host?.glow?.setSuspended(hidden)
    }


    // MARK: Covers

    func upgradeCovers() {
        let now = CACurrentMediaTime()
        guard now - lastCoverCheck > 0.1, let host else { return }
        lastCoverCheck = now
        for level in cells.indices {
            for (slot, cell) in cells[level] where !cell.cover.exact {
                guard case .card(let card) = host.items[session.slots[slot]],
                      let source = LibraryGridHostController.coverSource(card, page: host.page) else { continue }
                let px = Int((cell.cover.restArt.width * scale).rounded(.up))
                if let found = LibraryCoverCache.shared.image(for: source, pixelWidth: px) { cell.cover.setImage(found.image, exact: found.exact, fadeIn: true) }
            }
        }
    }

    func prefetch(level: Int) {
        guard let host else { return }
        let px = Int((LibraryGridGeometry.artworkRect(cardWidth: session.levels[level].cardWidth).width * scale).rounded(.up))
        let items = cells[level].keys.sorted { abs($0 - session.anchor) < abs($1 - session.anchor) }.prefix(48).compactMap { slot -> (LibraryCoverCache.Source, Int)? in
            guard case .card(let card) = host.items[session.slots[slot]],
                  let source = LibraryGridHostController.coverSource(card, page: host.page) else { return nil }
            return (source, px)
        }
        for (source, px) in items { _ = LibraryCoverCache.shared.image(for: source, pixelWidth: px) }
    }

    // MARK: Frames

    private struct SpansKey: Hashable { let a: Int, b: Int, blend: CGFloat }
    private var keep: [ObjectIdentifier: LibraryGridZoomCell] = [:]
    private var lit: [Int: (art: CGRect, alpha: CGFloat, level: Int)] = [:]
    private var rows: [Int: GridZoomScene.Placed] = [:]
    private var spansMemo: [SpansKey: GridZoomScene.Spans] = [:]

    func render() {
        guard let collection else { return }
        let s = session
        let width = GridZoomTransition.width(at: s.t, widths: s.widths)
        // Two blends a frame: the opacities follow the timed crossfade (leavers bounded), the positions the pinch's coordinate itself.
        let blend = s.frameBlend()
        let stacked = !blend.overlays.isEmpty
        let from = blend.lower, to = blend.upper
        let geometry = s.frameGeometry()
        // The real scroll follows the zoom, clamped to the blended page; the page top is a floor (placedFrameShift).
        let pageTop = s.pageOffset(geometry, width: width)
        let (placer, shift) = s.placedFrameShift(geometry, width: width, pageTop: pageTop)
        s.shownShift = shift
        let base = s.realOffset(pageTop: pageTop - s.clampShift, blend: geometry, width: width, in: collection)
        let wanted = s.wantedRealOffset(base: base, shift: shift, in: collection)
        s.shownOffset = wanted
        if abs(collection.contentOffset.y - wanted) > 0.01 {
            collection.contentOffset = CGPoint(x: collection.contentOffset.x, y: wanted)
        }
        let dy = collection.contentOffset.y + shift
        keep.removeAll(keepingCapacity: true)
        lit.removeAll(keepingCapacity: true)
        rows.removeAll(keepingCapacity: true)
        spansMemo.removeAll(keepingCapacity: true)
        // While the light fades out it follows its cards: where each one's artwork is in this frame, and how opaque. A card is in two
        // levels at once and the light follows ONE of them for the whole zoom: the cell of the level the zoom began at, or for a card that
        // level does not show the nearest level that does. It never hands over to the cell the cover crossfades into.
        let followed = host?.glow?.following == true
        let origin = s.startLevel
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        func put(_ level: Int, _ slot: Int, _ placed: GridZoomScene.Placed, _ coverAlpha: CGFloat, _ labelAlpha: CGFloat, _ z: CGFloat? = nil) {
            if let cell = place(level: level, slot: slot, placed: placed, dy: dy, coverAlpha: coverAlpha, labelAlpha: labelAlpha,
                                z: z ?? 0.5 + CGFloat(level) * 0.01) {
                keep[ObjectIdentifier(cell)] = cell
                if followed, Self.followsSooner(level, than: lit[slot]?.level, origin: origin) { lit[slot] = (cell.shownArt, coverAlpha, level) }
            }
        }
        // Every cell the blend draws, at its alpha (the pair's, each overlay over it), the edge columns handed over with the fade,
        // placed on the geometry's rows. A pair keeps its levels' own z; a stacked frame orders the levels as the blend does.
        var alphas = s.frameAlphas(blend)
        s.handOverEdges(&alphas, blend: blend)
        let ranks = Dictionary(blend.levels.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let pinched = s.scene.anchorSection
        for (key, alpha) in alphas where max(alpha.cover, alpha.label) > 0.001 {
            guard let placed = placer.position(key.level, key.index) else { continue }
            put(key.level, key.index, placed, alpha.cover, alpha.label,
                stacked ? LibraryGridZoomSession.stackZ(rank: ranks[key.level] ?? blend.levels.count) : nil)
            let layout = s.scene.levels[key.level]
            if layout.sectionOf.indices.contains(key.index), layout.sectionOf[key.index] == pinched,
               layout.rowOf.indices.contains(s.anchor), layout.rowOf[s.anchor] >= 0 {
                rows[layout.rowOf[key.index] - layout.rowOf[s.anchor]] = placed
            }
        }
        drawEdgeCells(from: from, to: to, overlays: blend.overlays.map(\.level), width: width, rows: rows) { put($0, $1, $2, 1, 1) }
        for (id, cell) in shown where keep[id] == nil { cell.views.forEach { $0.isHidden = true } }
        swap(&shown, &keep)
        // The page's other elements, kept to their sections on the geometry blend; one with no section keeps the cumulative rule.
        let ch2 = LibraryGridGeometry.coverHeight(cardWidth:)
        func spans(_ a: Int, _ b: Int, _ w: CGFloat) -> GridZoomScene.Spans {
            let key = SpansKey(a: a, b: b, blend: w)
            if let known = spansMemo[key] { return known }
            let made = s.scene.spans(a, b, blend: w, coverHeight: ch2(width))
            spansMemo[key] = made
            return made
        }
        for element in elements {
            func y(_ a: Int, _ b: Int, _ w: CGFloat) -> CGFloat {
                if let section = element.section,
                   let placed = s.scene.elementY(a, b, spans: spans(a, b, w), blend: w, section: section,
                                                 trailing: element.trailing, rest: element.rest) {
                    return placed
                }
                return s.scene.virtualY(a, b, ys: element.ys, rowsAbove: element.rowsAbove, width: width, blend: w, coverHeight: ch2)
                    - pageTop
            }
            let screen = geometry.mix(pair: y, level: { y($0, $0, 0) })
            element.view.frame.origin.y = screen + dy
        }
        CATransaction.commit()
        if followed, let host {
            var placed: [(key: String, art: CGRect, alpha: CGFloat)] = []
            placed.reserveCapacity(lit.count)
            for (slot, shown) in lit where s.slots.indices.contains(slot) && host.items.indices.contains(s.slots[slot]) {
                if case .card(let card) = host.items[s.slots[slot]] { placed.append((card.key, shown.art, shown.alpha)) }
            }
            host.glow?.follow(placed)
        }
    }

    static func followsSooner(_ level: Int, than other: Int?, origin: Int) -> Bool {
        guard let other else { return true }
        let (a, b) = (abs(level - origin), abs(other - origin))
        return a < b || (a == b && level < other)
    }

    private func place(level: Int, slot: Int, placed: GridZoomScene.Placed, dy: CGFloat, coverAlpha: CGFloat,
                       labelAlpha: CGFloat, z: CGFloat) -> LibraryGridZoomCell? {
        guard max(coverAlpha, labelAlpha) > 0.001, placed.cover.width > 0 else { return nil }
        // A cell no plan foresaw (a rubber band past the plans' widths): made now, never a hole.
        guard let cell = cells[level][slot] ?? host.flatMap({ buildCell(level: level, slot: slot, host: $0) }) else { return nil }
        let rect = placed.cover.offsetBy(dx: 0, dy: dy)
        let art = LibraryGridGeometry.artworkRect(cardWidth: rect.width).offsetBy(dx: rect.minX, dy: rect.minY)
        cell.shownArt = art
        let scale = art.width / max(1, cell.cover.restArt.width)
        for view in cell.views where view.layer.zPosition != z { view.layer.zPosition = z }
        cell.cover.isHidden = coverAlpha <= 0.001
        cell.cover.alpha = coverAlpha
        cell.cover.center = CGPoint(x: art.midX, y: art.midY)
        cell.cover.transform = CGAffineTransform(scaleX: scale, y: scale)
        if !cell.labelReady, let image = cell.labelImage, image.image == nil {
            image.image = fallbackLabel(level: level, slot: slot)
        }
        cell.label.isHidden = labelAlpha <= 0.001
        cell.label.alpha = labelAlpha
        cell.label.center = CGPoint(x: rect.midX, y: rect.maxY + cell.labelSize.height / 2)
        return cell
    }

    /// Edge cells of the level the pinch is at while the fades lag it: they take their row's in-flight top and band.
    private func drawEdgeCells(from: Int, to: Int, overlays: [Int], width: CGFloat, rows: [Int: GridZoomScene.Placed]?,
                               put: (_ level: Int, _ slot: Int, _ placed: GridZoomScene.Placed) -> Void) {
        let s = session
        guard s.coordCount >= 2 else { return }
        let aroundCoordinate = min(s.coordCount - 2, max(0, Int(s.t.rounded(.down))))
        let around = s.steps[aroundCoordinate]
        let aroundNext = s.steps[aroundCoordinate + 1]
        let drawn = { (level: Int) in (level >= min(from, to) && level <= max(from, to)) || overlays.contains(level) }
        guard !drawn(around) || !drawn(aroundNext), let edge = s.plan(from: around, to: aroundNext) else { return }
        let placement = s.scene.place(around, aroundNext, width: width, blend: from > around ? 1 : 0,
                                      coverHeight: LibraryGridGeometry.coverHeight(cardWidth:))
        for (lowerSide, level) in [(true, around), (false, aroundNext)] where !drawn(level) {
            let candidates = lowerSide ? edge.fromCandidates : edge.toCandidates
            let fades = lowerSide ? edge.fromFades : edge.toFades
            let placed = lowerSide ? placement.a : placement.b
            let layout = s.scene.levels[level]
            let base = layout.rowOf.indices.contains(s.anchor) ? layout.rowOf[s.anchor] : 0
            for i in candidates where !fades[i] {
                var p = placed[i]
                // A row moves as one: an edge cell takes the top and band of ITS ROW as the drawn pair has it.
                if let rows, layout.sectionOf[i] == s.scene.anchorSection, let row = rows[layout.rowOf[i] - base] {
                    p.cover.origin.y = row.cover.minY
                    p.band = row.band
                }
                put(level, i, p)
            }
        }
    }

    static func renderInWindow(_ view: UIView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        for sub in view.subviews { renderInWindow(sub) }
    }

    static func hold(_ view: UIView, _ held: Bool) {
        if let cell = view as? LibraryGridHeldCell { cell.heldHiddenByZoom = held; if !held { cell.isHidden = false } } else { view.isHidden = held }
    }

    // MARK: Teardown

    func teardown() {
        labelWork?.cancelled = true
        container.removeFromSuperview()
        if presented {
            // The cells go to the rest-time cache (a pinch right after this one finds them), hidden.
            for level in cells { for cell in level.values { cell.views.forEach { $0.isHidden = true } } }
            host?.zoomCells.keep(cells: cells, session: session)
        }
        cells = []
        shown = [:]
        elements = []
        guard presented else { return }
        if let collection {
            for cell in collection.visibleCells { Self.hold(cell, false); (cell as? LibraryGridCardCell)?.releaseHeldWork() }
            for view in collection.subviews where view is UICollectionViewCell { Self.hold(view, false) }
        }
        hideGlows(false)
    }
}

func libraryStandardRangeFormat() -> UIGraphicsImageRendererFormat {
    let format = UIGraphicsImageRendererFormat.default()
    format.preferredRange = .standard
    return format
}
