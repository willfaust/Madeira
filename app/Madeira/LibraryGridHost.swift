// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Combine
import SwiftUI
import UIKit
import os

// The zoomable library page's UIKit side (docs/zoomable-grid.md): one UICollectionView for the whole page, laid out by
// LibraryGridLayoutModel. Card cells are UIKit cells (LibraryGridCardCell), the fixed elements host Madeira's own SwiftUI
// views, the ambient light is one Metal layer behind the cells (LibraryGridGlow.swift), and the pinch is LibraryGridZoom.swift.

/// The page inside SwiftUI. Answers `sizeThatFits` with the proposal, so SwiftUI never measures the collection view.
struct LibraryGridHostView: UIViewControllerRepresentable {
    let build: () -> LibraryGridPageModel
    /// What the page is built from besides the library document, and the count of the other models' publications:
    /// equal to the last applied pair, a metadata-only library change may take the delta (metadataDelta).
    let inputsKey: LibraryGridInputsKey
    let otherRevision: Int
    let layout: String
    let position: Double
    let focused: UUID?
    let fixed: (LibraryGridFixed) -> AnyView
    let open: (LibraryGridCard, LibraryGridPageModel) -> Void
    let landed: (Double, CGFloat) -> Void

    func makeUIViewController(context: Context) -> LibraryGridHostController { LibraryGridHostController() }
    static func dismantleUIViewController(_ controller: LibraryGridHostController, coordinator: ()) { controller.tearDown() }
    func updateUIViewController(_ controller: LibraryGridHostController, context: Context) {
        controller.update(self)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: LibraryGridHostController, context: Context) -> CGSize? {
        return proposal.replacingUnspecifiedDimensions(by: CGSize(width: 390, height: 844))
    }
}

/// An item of the collection view: a fixed element (by its id) or a card.
enum LibraryGridItem: Hashable {
    case fixed(String)
    case card(LibraryGridCard)
}

/// One level's whole page: what the live layout shows, and what the zoom reads for every level.
struct LibraryGridLevelPage {
    let columns: Int
    let result: LibraryGridLayoutModel.Result
    /// The cards (item indices) whose bands at this width are not measured yet: each takes the band of the nearest measured
    /// width, else an estimate. The live page shows none within a viewport of the screen (`measuringWindow`).
    var estimated = IndexSet()
    var exact: Bool { estimated.isEmpty }
}

final class LibraryGridHostController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    private(set) var collectionView: UICollectionView!
    private(set) var glow: LibraryGlowView?
    private let layoutObject = LibraryGridCollectionLayout()
    private var dataSource: UICollectionViewDiffableDataSource<Int, LibraryGridItem>!
    private(set) var props: LibraryGridHostView?
    private(set) var page = LibraryGridPageModel() { didSet { coverKeyMemo = [:]; sourceMemo = [:]; aheadY = nil } }
    private(set) var labels: [LibraryGridCard: LibraryCardLabel] = [:]
    private(set) var items: [LibraryGridItem] = []
    private(set) var blocks: [LibraryGridBlock] = []
    private var indexOf: [LibraryGridItem: Int] = [:]
    private(set) var fixedByID: [String: LibraryGridFixed] = [:]
    private(set) var columns = 0
    private(set) var live: LibraryGridLevelPage? { didSet { glow?.framesMoved() } }
    private var lastLayout = CGSize.zero
    private var lastFocused: UUID?
    var zoom: LibraryGridZoomSession?
    /// The position a pinch landed on, until the stored setting says the same (an update in between must not take the grid back).
    var landedPosition: Double?
    var multiTouch = false
    /// The zoom's start state (LibraryGridZoomStart.swift): the kept base, the build in preparation, the bridge.
    let zoomStart = GridZoomStartState()
    /// Moves whenever the page a zoom is made of moves (data, widths, bands, landings): a prepared start or kept base made
    /// against an older value is not used. `zoomContentStamp` also moves when the cards' own content did (the cell cache).
    var zoomStamp = 0
    var zoomContentStamp = 0
    var zoomCellStorage: LibraryGridZoomCellCache?
    private var pending = false
    private var coverUpdates: AnyCancellable?
    private var glowModeObserver: NSObjectProtocol?
    private(set) var applyCount = 0
    private let refresh = UIRefreshControl()
    private var sizing = UIHostingController(rootView: AnyView(EmptyView()))
    private var fixedHeights: [LibraryGridFixed: (width: CGFloat, height: CGFloat)] = [:]
    private var bandMemo: [LibraryCardLabel: [CGFloat: CGFloat]] = [:]
    private var fonts = LibraryCardLabel.Fonts.current()
    /// The fonts' generation, bumped by a Dynamic Type change: background measuring with the old fonts stops and is dropped.
    private var fontsGeneration = 0
    private let measuringGeneration = OSAllocatedUnfairLock(initialState: 0)

    // MARK: Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        // The click generators are created now, off the first pinch's path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { GridZoomHapticPlayer.shared.prepare() }
        view.backgroundColor = .clear
        layoutObject.host = self
        let collection = UICollectionView(frame: view.bounds, collectionViewLayout: layoutObject)
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collection.backgroundColor = .clear
        collection.alwaysBounceVertical = true
        collection.contentInsetAdjustmentBehavior = .automatic
        collection.delegate = self
        collection.prefetchDataSource = self
        collection.accessibilityIdentifier = "library.grid"
        view.addSubview(collection)
        collectionView = collection
        // The card size is a pinch; this element gives VoiceOver, Switch Control and Voice Control the same choice.
        let size = LibraryGridSizeElement(accessibilityContainer: view)
        size.host = self
        sizeElement = size
        view.accessibilityElements = [size, collection]
        // The ambient light is Metal layers in the page's coordinates, first in the collection view so the cells draw over it.
        if let glow = LibraryGlowView.make() {
            glow.host = self
            glow.isHidden = AmbientGlowSettings.shared.mode != .new
            collection.insertSubview(glow, at: 0)
            self.glow = glow
        }

        let cardRegistration = UICollectionView.CellRegistration<LibraryGridCardCell, LibraryGridCard> { [weak self] cell, _, card in
            guard let self, self.props != nil else { return }
            if cell.onPress == nil {
                cell.onPress = { [weak self] key, down in
                    self?.glow?.setPressed(key, down)
                }
            }
            cell.configure(card: card, content: self.page.content(for: card, label: self.labels[card], focused: self.props?.focused),
                           work: self.page.work(for: card))
        }
        let fixedRegistration = UICollectionView.CellRegistration<LibraryGridHeldCell, String> { [weak self] cell, _, id in
            guard let self, let props = self.props, let fixed = self.fixedByID[id] else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                props.fixed(fixed).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.margins(.all, 0)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collection) { collection, path, item in
            switch item {
            case .card(let card): return collection.dequeueConfiguredReusableCell(using: cardRegistration, for: path, item: card)
            case .fixed(let id): return collection.dequeueConfiguredReusableCell(using: fixedRegistration, for: path, item: id)
            }
        }
        refresh.addTarget(self, action: #selector(pulled), for: .valueChanged)
        collection.refreshControl = refresh
        installPinch()
        installZoomIdleSignals()
        // The glow mode (Original / New / Off) switched live: the glows come or go.
        glowModeObserver = NotificationCenter.default.addObserver(forName: AmbientGlowSettings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.layoutObject.invalidateLayout()
            self?.glow?.modeChanged()
        }
        // Covers landed: the cards showing them take them, one pass for everything that landed since the last frame.
        coverUpdates = LibraryCoverCache.shared.batches.sink { [weak self] keys in
            guard let self else { return }
            for case let cell as LibraryGridCardCell in self.collectionView.visibleCells {
                if let key = cell.coverSourceKey, keys.contains(key) { cell.refreshCover() }
            }
        }
        // Dynamic Type: the trait (the system setting, and any override above the page).
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _: UITraitCollection) in
            self.contentSizeChanged()
        }
        // Light / dark: the stage's covers carry the style they were built for.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.modelDidChange()
        }
    }

    @objc private func pulled() {
        Task { @MainActor in
            await SteamGamesSection.refresh()
            // Never mid-zoom: ending changes the top inset the zoom's begin captured, and the zoom's offset writes
            // would cancel UIKit's return to the top.
            if zoom != nil { refreshEndPending = true } else { refresh.endRefreshing() }
        }
    }
    private var refreshEndPending = false
    private var sizeElement: LibraryGridSizeElement?

    // MARK: Card size without a pinch

    var cardSizeDescription: String {
        let stops = self.stops
        let shown = landedPosition.map { stops[LibraryGridGeometry.stopIndex(position: $0, count: stops.count)] } ?? columns
        return "\(shown) across"
    }

    /// One level toward more columns (`steps` 1) or bigger cards (-1): stored like a landed pinch, laid out without
    /// animation.
    func stepCardSize(_ steps: Int) {
        let stops = self.stops
        guard zoom == nil, zoomStart.bridge == nil, let props,
              let index = stops.firstIndex(of: landedPosition.map { stops[LibraryGridGeometry.stopIndex(position: $0, count: stops.count)] } ?? columns),
              stops.indices.contains(index + steps) else { return }
        let position = LibraryGridGeometry.position(index: index + steps, count: stops.count)
        landedPosition = position
        props.landed(position, LibraryGridGeometry.cardWidth(content: contentWidth, columns: stops[index + steps]))
    }

    func contentSizeChanged() {
        fonts = .current(traitCollection)
        fontsGeneration += 1
        LibraryCardLabel.warmGlyphs(fonts: fonts)
        passGeneration += 1
        let generation = passGeneration
        measuringGeneration.withLock { $0 = generation }   // a pass with the old fonts stops
        bandMemo = [:]
        fixedHeights = [:]
        levelCache = [:]
        modelDidChange()
        applyAgain = true
        if let props { update(props) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeElement?.accessibilityFrameInContainerSpace = CGRect(x: 0, y: 0, width: view.bounds.width, height: 24)
        glow?.viewportChanged(collectionView.bounds.size)
        if let glow, collectionView.subviews.first !== glow { collectionView.sendSubviewToBack(glow) }   // the light stays under the cells
        glow?.syncDraw()   // frames that moved in this pass: the light is drawn for them in the same commit
        // A change of the page's width or left edge (rotation, Stage Manager, a landscape notch) lays the page out again.
        if layoutKey != lastLayout, let props {
            lastLayout = layoutKey
            // A width change during a zoom lands it first (rotation, Stage Manager).
            zoom?.abandon()
            dropBridgeIfLive()
            applyAgain = true
            update(props)
        }
    }

    // MARK: Updates

    func update(_ props: LibraryGridHostView) {
        self.props = props
        guard isViewLoaded else { return }
        if zoom != nil || zoomStart.bridge != nil { pending = true; return }
        // Never rebuild the page under a finger or a coast; the newest props are applied when the scroll ends.
        if DeferredMainWork.shared.scrollActive { scrollPending = true; return }
        scrollPending = false
        apply(props, animated: !items.isEmpty)
    }

    deinit { if let glowModeObserver { NotificationCenter.default.removeObserver(glowModeObserver) } }

    func tearDown() {
        pending = false
        zoom?.teardown()
        zoom = nil
        dropBridgeIfLive()
        discardZoomStart()
    }

    /// A page update that waited for a zoom or its bridge is applied now (the pinch is over or was dropped).
    func flushPendingUpdate() {
        guard zoom == nil, zoomStart.bridge == nil, pending, let props else { return }
        pending = false
        apply(props, animated: false)
    }

    func zoomEnded() {
        if pending, let props { pending = false; apply(props, animated: false) }
        if refreshEndPending { refreshEndPending = false; refresh.endRefreshing() }
        // A landing on a level whose bands were still being measured: exact once they are.
        if live?.exact == false { levelsMeasured() }
        LibraryCoverCache.shared.paused = false
        schedulePrefetch()
    }

    /// The width inside the horizontal safe area (a landscape iPhone's notch side): the
    /// SwiftUI page's ScrollView keeps its content inside it.
    var layoutWidth: CGFloat {
        max(1, collectionView.bounds.width - collectionView.safeAreaInsets.left - collectionView.safeAreaInsets.right)
    }
    var layoutKey: CGSize { CGSize(width: layoutWidth.rounded(), height: collectionView.safeAreaInsets.left.rounded()) }
    var contentWidth: CGFloat { LibraryGridGeometry.contentWidth(viewport: layoutWidth) }
    var originX: CGFloat { collectionView.safeAreaInsets.left + (layoutWidth - contentWidth) / 2 }

    var stops: [Int] { LibraryGridGeometry.stops(content: contentWidth) }

    private var appliedRevision = -1
    private var appliedKey: LibraryGridInputsKey?
    private var appliedOther = -1

    /// The ids of the changed entries when everything since the last apply was the library's metadata
    /// (LibraryPublication.metadata) and nothing else the page reads changed. Any doubt is nil: the full build.
    private func metadataDelta(_ props: LibraryGridHostView, _ model: LibraryModel) -> Set<UUID>? {
        guard appliedKey == props.inputsKey, appliedOther == props.otherRevision, !props.inputsKey.metadataMovesCards,
              let log = model.publications(since: appliedRevision), !log.isEmpty, log.allSatisfy({ $0.kind == .metadata }) else { return nil }
        return log.reduce(into: Set<UUID>()) { $0.formUnion($1.ids) }
    }

    /// Set by a change the inputs do not show (the type size, the width): the next apply runs in full.
    private var applyAgain = false

    /// Whether `props` would rebuild the page already on screen: the same inputs, no publication from the library or the Steam
    /// models since, the same focus and column count. A landing writes the new size back to the stored state and that update
    /// arrives here with nothing changed.
    private func showsAlready(_ props: LibraryGridHostView) -> Bool {
        guard !applyAgain, !items.isEmpty, appliedKey == props.inputsKey, appliedOther == props.otherRevision,
              appliedRevision == LibraryModel.shared.revision, lastFocused == props.focused else { return false }
        var position = props.position
        if let landed = landedPosition {
            if abs(landed - position) < 1e-6 { landedPosition = nil } else { position = landed }
        }
        return LibraryGridSize.columns(layout: props.layout, position: position, content: contentWidth) == columns
    }

    private func apply(_ props: LibraryGridHostView, animated: Bool) {
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        if showsAlready(props) { return }
        applyAgain = false
        let model = LibraryModel.shared
        let revision = model.revision
        let anchor = props.inputsKey == appliedKey ? captureAnchor() : nil
        let page: LibraryGridPageModel
        if let ids = metadataDelta(props, model) {
            var kept = self.page
            labels = kept.applyMetadata(ids: ids, labels: labels)
            page = kept
        } else {
            page = props.build()
            labels = page.labels()
        }
        appliedRevision = revision; appliedKey = props.inputsKey; appliedOther = props.otherRevision
        applyCount += 1
        self.page = page
        levelCache = [:]
        modelDidChange()
        var newItems: [LibraryGridItem] = []
        var newFixed: [String: LibraryGridFixed] = [:]
        for block in page.blocks {
            switch block.kind {
            case .fixed(let fixed):
                newItems.append(.fixed(fixed.id))
                newFixed[fixed.id] = fixed
            case .grid(_, let cards):
                newItems += cards.map { .card($0) }
            }
        }
        let changedFixed = newFixed.filter { fixedByID[$0.key] != nil && fixedByID[$0.key] != $0.value }.map { LibraryGridItem.fixed($0.key) }
        fixedByID = newFixed
        blocks = page.blocks
        // The items first: the live page's measuring reads them.
        let itemsChanged = newItems != items
        let big = abs(newItems.count - items.count) > 400 || items.isEmpty
        if itemsChanged {
            items = newItems
            indexOf = Dictionary(newItems.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        }
        var position = props.position
        if let landed = landedPosition {
            if abs(landed - position) < 1e-6 { landedPosition = nil } else { position = landed }
        }
        columns = LibraryGridSize.columns(layout: props.layout, position: position, content: contentWidth)
        // Only the cards that can be on screen soon are measured here; the rest off the main thread.
        let offset = collectionView.contentOffset.y
        live = measuringWindow(levelPage(columns: columns)) { _ in offset }
        layoutObject.result = live?.result
        // The first card on screen stays where it is: the offset follows the height that changed above it.
        var anchored: CGFloat = 0
        if let anchor, let shift = anchorShift(anchor) { anchored = shift }
        if abs(anchored) > 0.01 { moveOffset(by: anchored) }

        if itemsChanged {
            var snapshot = NSDiffableDataSourceSnapshot<Int, LibraryGridItem>()
            snapshot.appendSections([0])
            snapshot.appendItems(newItems)
            dataSource.apply(snapshot, animatingDifferences: animated && !big && !UIAccessibility.isReduceMotionEnabled && abs(anchored) < 0.01)
        } else {
            layoutObject.invalidateLayout()
        }
        // The hosted views read the page's state through their closures: the visible ones are configured again.
        var snapshot = dataSource.snapshot()
        let visible = collectionView.indexPathsForVisibleItems.compactMap { $0.item < items.count ? items[$0.item] : nil }
        let again = Array(Set(visible + changedFixed)).filter { snapshot.indexOfItem($0) != nil }
        if !again.isEmpty {
            snapshot.reconfigureItems(again)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        if props.focused != lastFocused {
            lastFocused = props.focused
            scrollToFocus(props.focused)
        }
        // The cards' new frames and the corrected offset are final: the light is drawn for them in this same commit.
        glow?.syncDraw()
        // Every other level's bands are measured off the main thread now, so a pinch soon after a data change finds them.
        prewarmBands()
        schedulePrefetch()
        if applyCount == 1 { LibraryCardLabel.warmGlyphs(fonts: fonts) }
    }


    // MARK: Anchor

    /// Anchor-preserving updates: a data change that moves the cards above the viewport (a label that grew, a card
    /// that arrived) moves the offset by the same amount, in the same pass, so what is on screen does not move.

    private struct Anchor { let item: LibraryGridItem; let minY: CGFloat; let offset: CGFloat }

    /// The first item on screen, with where it sat in the page. Nil at the top (the page stays at the top).
    private func captureAnchor() -> Anchor? {
        guard let frames = live?.result.frames, !frames.isEmpty, !items.isEmpty else { return nil }
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        guard top > 1 else { return nil }
        let count = min(frames.count, items.count)
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].maxY > top { hi = mid } else { lo = mid + 1 }
        }
        guard lo < count else { return nil }
        return Anchor(item: items[lo], minY: frames[lo].minY, offset: collectionView.contentOffset.y)
    }

    private func anchorShift(_ anchor: Anchor) -> CGFloat? {
        guard let frames = live?.result.frames, let i = indexOf[anchor.item], i < frames.count else { return nil }
        return frames[i].minY - anchor.minY
    }

    /// Offset moved without animation, inside the bounds of the new page (a fling is not at an end here: updates wait for rest).
    private func moveOffset(by delta: CGFloat) {
        let insets = collectionView.adjustedContentInset
        let height = live?.result.contentHeight ?? collectionView.contentSize.height
        let bottom = max(-insets.top, height + insets.bottom - collectionView.bounds.height)
        let y = min(bottom, max(-insets.top, collectionView.contentOffset.y + delta))
        guard abs(y - collectionView.contentOffset.y) > 0.01 else { return }
        UIView.performWithoutAnimation {
            collectionView.layoutIfNeeded()
            collectionView.contentOffset.y = y
        }
    }


    /// The neighbour levels' covers, and the next pinch's start, once the page has been still for a moment: a
    /// job on the deferred-work gate (LibraryGridZoomIdle.swift), restarted by every call.
    func schedulePrefetch() { scheduleZoomWarm() }

    func commitColumns(_ columns: Int, page: LibraryGridLevelPage) {
        self.columns = columns
        live = page
        aheadY = nil
        layoutObject.result = page.result
        modelDidChange(content: false)
    }

    private func scrollToFocus(_ id: UUID?) {
        guard let id else { return }
        if id == LibraryEntry.desktopID {
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true)
        } else if let index = indexOf[.card(.entry(id))] {
            collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: true)
        }
    }

    // MARK: Levels

    /// The page at `columns` columns: fixed heights measured once per width, card bands per card width (a row takes its
    /// tallest card, as LazyVGrid does). It never measures a label: a band not measured yet takes the nearest measured width's,
    /// else an estimate, and the page lists those cards (`estimated`).
    func levelPage(columns: Int) -> LibraryGridLevelPage {
        if let kept = levelCache[columns], kept.layout == layoutKey { return kept.page }
        let made = makeLevelPage(columns: columns)
        levelCache[columns] = (layoutKey, made)
        return made
    }

    private var levelCache: [Int: (layout: CGSize, page: LibraryGridLevelPage)] = [:]

    private func makeLevelPage(columns: Int) -> LibraryGridLevelPage {
        let content = contentWidth
        let w = LibraryGridGeometry.cardWidth(content: content, columns: columns)
        let labels = self.labels
        var specs: [LibraryGridLayoutModel.Block] = []
        var estimated = IndexSet()
        var item = 0
        for block in blocks {
            switch block.kind {
            case .fixed(let fixed):
                specs.append(.fixed(height: fixedHeight(fixed, width: content), spacing: block.spacing))
                item += 1
            case .grid(_, let cards):
                var bands: [CGFloat] = []
                bands.reserveCapacity(cards.count)
                for card in cards {
                    let (value, measured) = knownBand(labels[card], cardWidth: w)
                    if !measured { estimated.insert(item) }
                    bands.append(value)
                    item += 1
                }
                specs.append(.grid(bands: bands, spacing: block.spacing))
            }
        }
        let result = LibraryGridLayoutModel.layout(specs, columns: columns, content: content, originX: originX)
        return LibraryGridLevelPage(columns: columns, result: result, estimated: estimated)
    }

    /// `page` with every card within a viewport of the screen measured (on the main thread). `offset` is where the page will
    /// be scrolled to with a given layout; measuring moves the rows, so it repeats until the window holds no estimate.
    func measuringWindow(_ page: LibraryGridLevelPage, offset: (LibraryGridLevelPage) -> CGFloat) -> LibraryGridLevelPage {
        var page = page
        let h = max(collectionView.bounds.height, 1)
        let w = page.result.cardWidth
        for _ in 0..<4 {
            guard !page.exact else { break }
            let y = offset(page)
            let range = Self.items(of: page.result.frames, between: y - h, and: y + 2 * h)
            let missing = page.estimated.filter { range.contains($0) }
            guard !missing.isEmpty else { break }
            for i in missing { if case .card(let card) = items[i] { _ = band(labels[card], cardWidth: w) } }
            page = makeLevelPage(columns: page.columns)
            levelCache[page.columns] = (layoutKey, page)
        }
        return page
    }

    /// The items whose frames reach into `low ... high` (the frames are in page order:
    /// tops and bottoms never decrease).
    static func items(of frames: [CGRect], between low: CGFloat, and high: CGFloat) -> Range<Int> {
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].maxY < low { lo = mid + 1 } else { hi = mid }
        }
        var end = lo
        while end < frames.count, frames[end].minY <= high { end += 1 }
        return lo..<end
    }

    static func bandKey(_ w: CGFloat) -> CGFloat { (w * 2).rounded() / 2 }

    func band(_ label: LibraryCardLabel?, cardWidth w: CGFloat) -> CGFloat {
        guard let label else { return 40 }
        let key = Self.bandKey(w)
        let shape = label.heightKey
        if let hit = bandMemo[shape]?[key] { return hit }
        let value = ceil(label.bandHeight(cardWidth: w, fonts: fonts))
        bandMemo[shape, default: [:]][key] = value
        return value
    }

    /// The band without measuring: the measured one, else the nearest measured width's,
    /// else an estimate from the text's length. `measured`: exact.
    private func knownBand(_ label: LibraryCardLabel?, cardWidth w: CGFloat) -> (CGFloat, measured: Bool) {
        guard let label else { return (40, true) }
        let key = Self.bandKey(w)
        guard let known = bandMemo[label.heightKey] else { return (label.estimatedBandHeight(cardWidth: w, fonts: fonts), false) }
        if let hit = known[key] { return (hit, true) }
        let nearest = known.min { abs($0.key - key) < abs($1.key - key) }
        return (nearest?.value ?? label.estimatedBandHeight(cardWidth: w, fonts: fonts), false)
    }

    /// Every level's bands for the applied labels, measured off the main thread (CoreText is thread-safe) at utility priority
    /// right after a data change: the live width first (its page is then exact), then the others, each handed to the main
    /// thread as it is done. A new data change or a Dynamic Type change (a new generation) stops the pass; a Dynamic Type
    /// change also drops what it measured.
    private var prewarming = false
    private var prewarmAgain = false
    private var passGeneration = 0
    private func prewarmBands() {
        passGeneration += 1
        let generation = passGeneration
        measuringGeneration.withLock { $0 = generation }
        guard !prewarming else { prewarmAgain = true; return }
        let labels = Array(Set(self.labels.values.map(\.heightKey)))
        // Forget the heights of labels no card has any more (a tag, a title or a size that changed).
        let current = Set(labels)
        bandMemo = bandMemo.filter { current.contains($0.key) }
        let liveWidth = Self.bandKey(LibraryGridGeometry.cardWidth(content: contentWidth, columns: columns))
        let widths = [liveWidth] + stops.map { Self.bandKey(LibraryGridGeometry.cardWidth(content: contentWidth, columns: $0)) }
            .filter { $0 != liveWidth }
        let memo = bandMemo
        let fonts = self.fonts
        let fontsGeneration = self.fontsGeneration
        let generationLock = measuringGeneration
        prewarming = true
        prewarmAgain = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var count = 0
            var stopped = false
            for w in widths {
                var measured: [LibraryCardLabel: CGFloat] = [:]
                for (i, label) in labels.enumerated() {
                    if i % 64 == 0, generationLock.withLock({ $0 }) != generation { stopped = true; break }
                    guard memo[label]?[w] == nil else { continue }
                    measured[label] = ceil(label.bandHeight(cardWidth: w, fonts: fonts))
                }
                count += measured.count
                DispatchQueue.main.async {
                    guard let self, fontsGeneration == self.fontsGeneration, !measured.isEmpty else { return }
                    for (label, value) in measured { self.bandMemo[label, default: [:]][w] = value }
                    self.bandsLanded()
                }
                if stopped { break }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.prewarming = false
                if self.prewarmAgain || fontsGeneration != self.fontsGeneration || stopped { self.prewarmAgain = false; self.prewarmBands(); return }
                _ = count
            }
        }
    }

    /// Some bands landed: the level pages laid out from estimates are laid out again
    /// (cheap: no measuring), and the live page with them, nothing on screen moving.
    private func bandsLanded() {
        levelCache = levelCache.filter { $0.value.page.exact }
        modelDidChange(content: false)
        levelsMeasured()
    }

    func levelsMeasured() {
        guard zoom == nil, collectionView.bounds.width > 0, let live, !live.exact else { return }
        let offset = collectionView.contentOffset.y
        let page = measuringWindow(levelPage(columns: columns)) { _ in offset }
        guard page.result != live.result || page.estimated != live.estimated else { return }
        replaceLive(page)
    }

    /// Scrolled at rest: cards within a viewport of the screen whose bands are still
    /// estimates are measured now, before they can come on screen.
    private var measuringScroll = false
    private func measureAhead() {
        guard zoom == nil, !measuringScroll, let live, !live.exact else { return }
        let h = collectionView.bounds.height, y = collectionView.contentOffset.y
        let range = Self.items(of: live.result.frames, between: y - h, and: y + 2 * h)
        guard live.estimated.intersects(integersIn: range) else { return }
        measuringScroll = true
        defer { measuringScroll = false }
        replaceLive(measuringWindow(live) { _ in y })
    }

    private func replaceLive(_ page: LibraryGridLevelPage) {
        guard let old = live?.result.frames else { return }
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let first = old.indices.first { old[$0].maxY > top && $0 < page.result.frames.count }
        live = page
        layoutObject.result = page.result
        modelDidChange(content: false)
        var y = collectionView.contentOffset.y
        if let first { y += page.result.frames[first].minY - old[first].minY }
        // Inside the new page (an end reached on estimated rows can be past the measured
        // end): clamped now, in the same frame, never later by UIKit in a frame of its own.
        let insets = collectionView.adjustedContentInset
        let bottom = max(-insets.top, page.result.contentHeight + insets.bottom - collectionView.bounds.height)
        if !collectionView.isDragging, !collectionView.isDecelerating { y = min(bottom, max(-insets.top, y)) }
        if abs(y - collectionView.contentOffset.y) > 0.5 {
            UIView.performWithoutAnimation {
                collectionView.layoutIfNeeded()
                collectionView.contentOffset.y = y
            }
        }
        glow?.syncDraw()   // the new frames and the corrected offset are final: the light follows in this commit
    }

    private func fixedHeight(_ fixed: LibraryGridFixed, width: CGFloat) -> CGFloat {
        if let known = fixedHeights[fixed], abs(known.width - width) < 0.5 { return known.height }
        guard let props else { return 44 }
        // Off-window, the sizing controller does not follow the page's Dynamic Type: it is
        // handed the page's size (else a notice kept its old height and truncated).
        var typeSize = DynamicTypeSize.large
        if let category = DynamicTypeSize(traitCollection.preferredContentSizeCategory) { typeSize = category }
        sizing.rootView = AnyView(props.fixed(fixed).environment(\.dynamicTypeSize, typeSize).frame(width: width, alignment: .leading))
        let size = sizing.sizeThatFits(in: CGSize(width: width, height: 10_000))
        let height = ceil(max(1, size.height))
        fixedHeights[fixed] = (width, height)
        return height
    }

    // MARK: Covers

    /// The neighbour levels' covers of the cards near the screen, asked for while the
    /// page is idle (LibraryCoverCache pauses them while it scrolls or zooms).
    func prefetchNeighbours() {
        guard let live, zoom == nil, !DeferredMainWork.shared.scrollActive else { return }
        coversAhead(idle: true)   // the screens above and below, once the page is still
        let stops = self.stops
        guard let at = stops.firstIndex(of: columns) else { return }
        let scale = traitCollection.displayScale
        let visible = collectionView.bounds.insetBy(dx: 0, dy: -collectionView.bounds.height)
        var wanted: [(LibraryCoverCache.Source, Int)] = []
        for neighbour in [at - 1, at + 1] where stops.indices.contains(neighbour) {
            let w = LibraryGridGeometry.cardWidth(content: contentWidth, columns: stops[neighbour])
            let px = LibraryGridGeometry.coverPixels(cardWidth: w, scale: scale)
            for (i, frame) in live.result.frames.enumerated() where frame.intersects(visible) {
                if case .card(let card) = items[i], let source = Self.coverSource(card, page: page) {
                    wanted.append((source, px))
                }
            }
        }
        LibraryCoverCache.shared.prefetch(wanted)
    }

    @MainActor static func coverSource(_ card: LibraryGridCard, page: LibraryGridPageModel?) -> LibraryCoverCache.Source? {
        switch card {
        case .steam(let id):
            // A not-downloaded game's cover carries the blur spot (LibraryCoverSpot), as the original grid draws it.
            var source = LibraryCoverCache.Source.steam(id)
            source.spot = page?.dimmed(card) ?? false
            return source
        case .entry(let id):
            guard let entry = page?.entries[id] ?? LibraryModel.shared.entries.first(where: { $0.id == id }) else { return nil }
            return .entry(entry)
        }
    }

    @MainActor static func coverKey(_ card: LibraryGridCard, page: LibraryGridPageModel?) -> String? {
        switch card {
        case .steam(let id): return "steam-\(id)"
        case .entry(let id):
            guard let entry = page?.entries[id] ?? LibraryModel.shared.entries.first(where: { $0.id == id }) else { return nil }
            if let name = entry.coverFile { return LibraryCoverCache.Source.coverFile(named: name).key }
            if let id = entry.steamID ?? entry.steamAppID { return "steam-\(id)" }
            return nil
        }
    }

    // MARK: Covers ahead

// A screen or two of covers ahead of the scroll, at the bucket the cards will ask for, so a card scrolling in finds its art
// resident. The main-thread work per call is small (a binary search over the frames, a dictionary lookup per card in the
// window); downloads, decodes and disk reads are LibraryCoverCache's, off main. Runs after the offset moved a fifth of a
// screen, and once more when the page goes still.
    private var aheadY: CGFloat?
    /// The page's speed in points per second (signed, smoothed over the last few offsets), 0 at rest.
    private var scrollSpeed: CGFloat = 0
    private var speedSample: (y: CGFloat, t: CFTimeInterval)?
    private var aheadKeys = Set<String>()
    private var aheadPixels = 0
    private var aheadSizedFor = ""

    private func coverSourceMemo(_ card: LibraryGridCard) -> LibraryCoverCache.Source? {
        if let known = sourceMemo[card] { return known }
        let source = Self.coverSource(card, page: page)
        sourceMemo[card] = .some(source)
        return source
    }

    private func coversAhead(idle: Bool) {
        guard zoom == nil, let live, props != nil else { return }
        let bounds = collectionView.bounds
        let h = bounds.height, y = bounds.origin.y
        guard h > 0 else { return }
        if !idle, let last = aheadY, abs(y - last) < h * 0.2 { return }
        let down = idle ? true : y >= (aheadY ?? y)
        aheadY = y
        let scale = traitCollection.displayScale
        let frames = live.result.frames
        let width = live.result.cardWidth
        let pixels = LibraryGridGeometry.coverPixels(cardWidth: width, scale: scale)
        guard pixels > 0 else { return }
        if pixels != aheadPixels { aheadPixels = pixels; aheadKeys = [] }
        var wanted = Set<String>()
        let sizing = "\(columns) \(Int(width)) \(Int(h))"
        if sizing != aheadSizedFor {
            aheadSizedFor = sizing
            let rows = Int((h / max(1, LibraryGridGeometry.coverHeight(cardWidth: width) + 44)).rounded(.up)) + 1
            LibraryCoverCache.shared.sizeBudget(cardsPerScreen: rows * max(1, columns), pixelWidth: pixels, screens: 5)
        }
        // The window: in the direction of travel as far as the page gets in about half a second (two screens at least), a quarter
        // of a screen behind; both ways when the page went still. The faster the page, the further ahead the requests go.
        let lead = min(5 * h, max(2 * h, abs(scrollSpeed) * 0.5))
        let low = idle ? y - h : (down ? y - h * 0.25 : y - lead)
        let high = idle ? y + 2 * h : (down ? y + lead : y + h * 1.25)
        let range = Self.items(of: frames, between: low, and: high)
        guard !range.isEmpty else { return }
        var order: [(score: CGFloat, index: Int)] = []
        order.reserveCapacity(range.count)
        for i in range where i < items.count {
            let frame = frames[i]
            if frame.maxY > y && frame.minY < y + h {
                // On screen: the cell asks for it. A request already made for it stays (cancelling it would throw away a download under way).
                if case .card(let card) = items[i], let key = glowCoverKey(card) { wanted.insert(key) }
                continue
            }
            // Distance beyond the edge the scroll is heading for; a card behind the view goes last.
            let below = frame.minY >= y + h
            let beyond = below ? frame.minY - (y + h) : y - frame.maxY
            order.append((idle || below == down ? beyond : 1_000_000 + beyond, i))
        }
        order.sort { $0.score < $1.score }
        var requests: [(LibraryCoverCache.Source, Int)] = []
        for (_, i) in order {
            guard case .card(let card) = items[i], let key = glowCoverKey(card) else { continue }
            wanted.insert(key)
            if aheadKeys.contains(key) { continue }
            if let source = coverSourceMemo(card) { requests.append((source, LibraryGridGeometry.coverPixels(cardWidth: frames[i].width, scale: scale))) }
        }
        let stale = aheadKeys.subtracting(wanted)
        aheadKeys = wanted
        if !stale.isEmpty { LibraryCoverCache.shared.cancelAhead(keys: stale) }
        LibraryCoverCache.shared.prefetchAhead(requests)
    }

    private func sampleSpeed() {
        let y = collectionView.contentOffset.y, t = CACurrentMediaTime()
        if let last = speedSample, t > last.t { scrollSpeed = scrollSpeed * 0.5 + (y - last.y) / CGFloat(t - last.t) * 0.5 }
        speedSample = (y, t)
    }

    /// UIKit's own look-ahead (a few items): the same requests, nearest first.
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt paths: [IndexPath]) {
        guard zoom == nil, let live else { return }
        let scale = traitCollection.displayScale
        var requests: [(LibraryCoverCache.Source, Int)] = []
        for path in paths where path.item < items.count && path.item < live.result.frames.count {
            guard case .card(let card) = items[path.item], let source = coverSourceMemo(card) else { continue }
            requests.append((source, LibraryGridGeometry.coverPixels(cardWidth: live.result.frames[path.item].width, scale: scale)))
        }
        LibraryCoverCache.shared.prefetchAhead(requests)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt paths: [IndexPath]) {
        var keys: [String] = []
        for path in paths where path.item < items.count {
            if case .card(let card) = items[path.item], let key = glowCoverKey(card), !aheadKeys.contains(key) { keys.append(key) }
        }
        if !keys.isEmpty { LibraryCoverCache.shared.cancelAhead(keys: keys) }
    }

    // MARK: The glow

    /// The cards whose light reaches the page range `low...high`, in page order, in the page's coordinates
    /// (the glow draws these).
    func glowCards(between low: CGFloat, and high: CGFloat) -> [LibraryGlowCard] {
        guard zoom == nil, let live else { return [] }
        // Light reaches a little past the card (0.29 of its art, more for a small card: `LibraryGlowView.scale`).
        let reach = max(live.result.cardWidth * 0.3, glow?.lightReach(cardWidth: live.result.cardWidth) ?? 0)
        let range = Self.items(of: live.result.frames, between: low - reach, and: high + reach)
        var out: [LibraryGlowCard] = []
        out.reserveCapacity(range.count)
        for i in range where i < items.count {
            guard case .card(let card) = items[i] else { continue }
            out.append(LibraryGlowCard(key: card.key, frame: live.result.frames[i], seed: Self.glowSeed(card), dimmed: page.dimmed(card),
                                       sourceKey: glowCoverKey(card), card: card))
        }
        return out
    }

    /// `coverKey` memoised per page (it builds a URL for a cover file, which asks for the working directory).
    private func glowCoverKey(_ card: LibraryGridCard) -> String? {
        if let known = coverKeyMemo[card] { return known }
        let key = Self.coverKey(card, page: page)
        coverKeyMemo[card] = .some(key)
        return key
    }
    private var coverKeyMemo: [LibraryGridCard: String?] = [:]
    private var sourceMemo: [LibraryGridCard: LibraryCoverCache.Source?] = [:]

    static func glowSeed(_ card: LibraryGridCard) -> Int {
        switch card {
        case .entry(let id): return id.hashValue
        case .steam(let id): return id
        }
    }

    // MARK: Scrolling

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        DeferredMainWork.shared.beginScroll()
        // Covers keep loading while the page scrolls; only the idle neighbour-level requests step aside.
        LibraryCoverCache.shared.dropIdle()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        scrollEnded()
        LibraryCoverCache.shared.paused = false; schedulePrefetch()
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollEnded()
        LibraryCoverCache.shared.paused = false; schedulePrefetch()
    }
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { scrollEnded() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { scrollEnded() }
    private func scrollEnded() {
        DeferredMainWork.shared.endScroll()
        scrollSpeed = 0; speedSample = nil
        if scrollPending, zoom == nil, let props { scrollPending = false; apply(props, animated: false) }
    }
    private var scrollPending = false
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if let zoom { zoom.realScrolled() } else { measureAhead(); glow?.scrolled(); sampleSpeed(); coversAhead(idle: false); noteScrollMoved() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scrollEnded()
        holdIdleWork(during: transitionCoordinator)
        suspendZoomIdleWork()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        holdIdleWork(during: transitionCoordinator)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        resumeZoomIdleWork()
    }

    // A card opens from the collection view's selection (on lift), not from a SwiftUI tap inside it: the multi-touch gate
    // (below) refuses it from the second finger's landing until every finger is up, so a pinch whose fingers land on
    // different cards can never open any of them.

    private func card(at path: IndexPath) -> LibraryGridCard? {
        guard case .card(let card)? = dataSource.itemIdentifier(for: path) else { return nil }
        return card
    }
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt path: IndexPath) -> Bool {
        card(at: path) != nil && !multiTouch && zoom == nil
    }
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt path: IndexPath) -> Bool {
        card(at: path) != nil && !multiTouch && zoom == nil
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt path: IndexPath) {
        collectionView.deselectItem(at: path, animated: false)
        guard let card = card(at: path), !multiTouch, zoom == nil, let props else { return }
        // The push is applied a runloop turn later: idle jobs stop now and the gate stays shut for the open.
        suspendZoomIdleWork()
        DeferredMainWork.shared.interact(for: 0.6, "book-open")
        props.open(card, page)
        // An open that never leaves this screen (no push) must not leave the idle work suspended.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if let self, self.isViewLoaded, self.view.window != nil, !self.zoomStart.pageActive { self.resumeZoomIdleWork() }
        }
    }

        /// A view UIKit realises during a zoom (the real offset moved) stays hidden: the
    /// stage draws the page until the landing.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // Held, not just hidden: a later un-hide by UIKit during the zoom is undone in the same call.
        if let held = cell as? LibraryGridHeldCell { held.heldHiddenByZoom = zoom != nil; if zoom == nil { held.isHidden = false } } else { cell.isHidden = zoom != nil }
        (cell as? LibraryGridCardCell)?.displayStarted(holdWork: zoom != nil)
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? LibraryGridCardCell)?.displayEnded()
    }
}

// MARK: - Layout

/// The collection view's layout: the frames LibraryGridLayoutModel gives the live
/// level (binary-searched per query).
final class LibraryGridCollectionLayout: UICollectionViewLayout {
    weak var host: LibraryGridHostController?
    var result: LibraryGridLayoutModel.Result? { didSet { if result != oldValue { invalidateLayout() } } }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: result?.contentHeight ?? 0)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        abs(newBounds.width - (collectionView?.bounds.width ?? 0)) > 0.5
    }

    private var itemCount: Int { min(result?.frames.count ?? 0, collectionView?.numberOfItems(inSection: 0) ?? 0) }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let frames = result?.frames else { return [] }
        let count = itemCount
        // The frames are in page order: tops and bottoms never decrease.
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].maxY + 60 < rect.minY { lo = mid + 1 } else { hi = mid }
        }
        var out: [UICollectionViewLayoutAttributes] = []
        var i = lo
        while i < count, frames[i].minY - 60 <= rect.maxY {
            let path = IndexPath(item: i, section: 0)
            if let a = layoutAttributesForItem(at: path), a.frame.intersects(rect) { out.append(a) }
            i += 1
        }
        return out
    }

    override func layoutAttributesForItem(at path: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let frames = result?.frames, path.item < frames.count else { return nil }
        let a = UICollectionViewLayoutAttributes(forCellWith: path)
        a.frame = frames[path.item]
        return a
    }

}

// MARK: - Cells


/// The adjustable "Card size" element of the grid for assistive technologies: increment is bigger cards.
final class LibraryGridSizeElement: UIAccessibilityElement {
    weak var host: LibraryGridHostController?
    override init(accessibilityContainer container: Any) {
        super.init(accessibilityContainer: container)
        accessibilityLabel = "Card size"
        accessibilityTraits = .adjustable
    }
    override var accessibilityValue: String? { get { host?.cardSizeDescription } set {} }
    override func accessibilityIncrement() { host?.stepCardSize(-1) }
    override func accessibilityDecrement() { host?.stepCardSize(1) }
}
