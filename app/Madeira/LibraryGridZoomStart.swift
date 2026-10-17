// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit

// A zoom's start, made ahead of the pinch (docs/zoomable-grid.md, "Instant start"). The rule: the critical path never
// depends on background readiness. The session is made in small pieces, none of them the critical path:
//
// A zoom start is made of: (1) `GridZoomBase`, what a zoom is made OF that does not depend on where the fingers land (the
// levels, the slots), kept between zooms while its key holds; (2) `GridZoomAim`, where the fingers landed (the pinched card,
// the lattice line, the coordinate's steps); (3) the plans (`GridZoomPlanSet`), pure maths on a background task; (4) the cells,
// adopted hidden into the stage one at a time from the rest-time cell cache (`LibraryGridZoomCellCache`) or made.
//
// `GridZoomStartBuild` walks them in steps of well under 2 ms, from a `DeferredMainWork` job at rest (the prepared session) or
// from a display link when two fingers touch down (the head start). A pinch that begins finds the session ready (begin =
// present), or the bridge carries it (the live cells placed by the session's own rule) until the build lands. Nothing slow (a
// Core Haptics engine, a layout probe) is created on main between touch-down and the first tracking frame.

// MARK: - The base

/// What a zoom is made of that does not depend on the fingers.
struct GridZoomBase {
    struct Key: Equatable {
        let stamp: Int
        let columns: Int
        let layout: CGSize
    }
    let key: Key
    let levels: [LibraryGridZoomSession.Level]
    let startLevel: Int
    let slots: [Int]
    let fixedItems: [Int]
}

/// The base, in steps: the slots in chunks, then one level's page a step (usually a lookup in the host's level cache).
@MainActor
final class GridZoomBaseBuilder {
    enum Outcome {
        case more
        case done(GridZoomBase)
        case failed
    }

    private var stamp: Int?
    private var columns: [Int] = []
    private var cursor = 0
    private var slots: [Int] = []
    private var fixed: [Int] = []
    private var levels: [LibraryGridZoomSession.Level] = []
    private var step = 0
    static let slotChunk = 1500

    func advance(host: LibraryGridHostController) -> Outcome {
        guard host.isViewLoaded, host.view.window != nil, let collection = host.collectionView, collection.bounds.height > 0,
              host.live != nil else { return .failed }
        if let stamp, stamp != host.zoomStamp { return .failed }
        stamp = host.zoomStamp
        if columns.isEmpty {
            let stops = host.stops
            guard stops.count >= 2, stops.contains(host.columns) else { return .failed }
            columns = stops.sorted(by: >)   // narrowest card first: most columns first
        }
        if cursor < host.items.count {
            let end = min(host.items.count, cursor + Self.slotChunk)
            for i in cursor..<end { if case .card = host.items[i] { slots.append(i) } else { fixed.append(i) } }
            cursor = end
            return .more
        }
        guard !slots.isEmpty else { return .failed }
        if step < columns.count {
            let n = columns[step]
            let page = n == host.columns ? host.live! : host.levelPage(columns: n)
            levels.append(.init(columns: n, cardWidth: page.result.cardWidth, page: page))
            step += 1
            return .more
        }
        guard let start = levels.firstIndex(where: { $0.columns == host.columns }) else { return .failed }
        return .done(GridZoomBase(key: .init(stamp: host.zoomStamp, columns: host.columns, layout: host.layoutKey),
                                  levels: levels, startLevel: start, slots: slots, fixedItems: fixed))
    }
}

// MARK: - The aim

/// Where the fingers landed: the pinched card (nearest the centroid) and its top on screen, the lattice line the gesture is
/// anchored to and the side a centre pinch falls back to, and the levels the coordinate runs over. Equal aims make equal sessions.
struct GridZoomAim: Equatable {
    var anchor: Int
    var anchorTop: CGFloat
    var line: GridZoomScene.Anchor
    var side: GridZoomScene.Anchor
    var steps: [Int]

    /// `point` is in the visible bounds (nil: the visible centre). `centreSteps`: a pinch (the middle zone zooms from the centre,
    /// two columns at a time); the picker's step and the warm pass false.
    @MainActor
    static func pick(base: GridZoomBase, host: LibraryGridHostController, point: CGPoint?, centreSteps: Bool) -> GridZoomAim {
        let collection = host.collectionView!
        let bounds = collection.bounds
        let origin = point ?? CGPoint(x: bounds.width / 2, y: bounds.height * 0.45)
        let picked = GridZoomCentre.anchor(startX: origin.x, width: bounds.width, centreZone: GridZoomFeel.centreZone)
        let counts = GridZoomCentre.columnCounts(coverWidths: base.levels.map(\.cardWidth), row: host.contentWidth,
                                                 gap: LibraryGridGeometry.columnGap)
        var line = picked.anchor
        // The line decides the coordinate's levels; a centre pinch with no 2-step (or not a pinch) is the
        // plain zoom, on the side of the centre.
        let wanted = centreSteps || line != .centre
        let steps = wanted ? GridZoomCentre.steps(anchor: line, columns: counts, start: base.startLevel) : nil
        if steps == nil { line = picked.side }
        let frames = base.levels[base.startLevel].page.result.frames
        let offset = collection.contentOffset.y
        let point = CGPoint(x: origin.x, y: origin.y + offset)
        let screen = CGRect(x: 0, y: offset, width: bounds.width, height: bounds.height)
        var best: (slot: Int, distance: CGFloat)?
        for (slot, item) in base.slots.enumerated() where frames[item].intersects(screen) {
            let frame = frames[item]
            let distance = frame.contains(point) ? 0 : hypot(frame.midX - point.x, frame.midY - point.y)
            if best == nil || distance < best!.distance { best = (slot, distance) }
        }
        if best == nil {   // no card on screen: the nearest one
            for (slot, item) in base.slots.enumerated() {
                let distance = abs(frames[item].midY - point.y)
                if best == nil || distance < best!.distance { best = (slot, distance) }
            }
        }
        let anchor = best?.slot ?? 0
        return GridZoomAim(anchor: anchor, anchorTop: frames[base.slots[anchor]].minY - offset, line: line, side: picked.side,
                           steps: steps ?? Array(base.levels.indices))
    }
}

/// Everything outside the base a prepared start depends on: the scroll position and insets, the size, the traits the cells are
/// built for. A prepared start whose environment differs from now is not used.
struct GridZoomStartEnvironment: Equatable {
    var offset: CGFloat
    var insetTop: CGFloat
    var insetBottom: CGFloat
    var size: CGSize
    var category: UIContentSizeCategory
    var style: UIUserInterfaceStyle
}

// MARK: - The build

/// One zoom start, made in steps (see the file comment). `advance(budget:)` does the next piece(s) and says whether more
/// remains; a piece that waits for the background (the plans) is "more" that costs main nothing. `ready` holds a session whose
/// plans are in and whose cells are adopted hidden; the pinch's begin only has to show it.
@MainActor
final class GridZoomStartBuild {
    enum Phase: String { case base, layouts, session, planning, adopting, fixed, ready, failed }

    private(set) var phase: Phase
    private(set) var base: GridZoomBase?
    private(set) var aim: GridZoomAim?
    private(set) var session: LibraryGridZoomSession?
    private(set) var environment: GridZoomStartEnvironment?
    let point: CGPoint?
    let centreSteps: Bool
    /// Wanted for a pinch that is starting (two fingers down), not a rest-time preparation: a scroll's callbacks do not discard it.
    var urgent = false
    private weak var host: LibraryGridHostController?
    private let builder = GridZoomBaseBuilder()
    private var planTask: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?
    private var layouts: [GridZoomLevelLayout]?
    private var adoptList: [(level: Int, slot: Int)] = []
    private var adoptNext = 0
    private var consumed = false

    /// The first symbol image of a process loads the symbol catalogs (milliseconds): made once off main ahead of the first cover.
    private static let symbolsWarmed: Void = {
        _ = Task.detached(priority: .utility) {
            _ = UIImage(systemName: "gamecontroller.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: .largeTitle))
        }
    }()

    init(host: LibraryGridHostController, point: CGPoint?, centreSteps: Bool) {
        Self.symbolsWarmed
        self.host = host
        self.point = point
        self.centreSteps = centreSteps
        if let base = host.currentZoomBase() {
            self.base = base
            phase = .layouts
        } else {
            phase = .base
        }
    }

    var isSettled: Bool { phase == .ready || phase == .failed }

    func matches(point other: CGPoint?, centreSteps other2: Bool, host: LibraryGridHostController) -> Bool {
        guard centreSteps == other2 else { return false }
        if let aim, let base { return aim == GridZoomAim.pick(base: base, host: host, point: other, centreSteps: other2) }
        return point == other
    }

    func isCurrent(in host: LibraryGridHostController) -> Bool {
        guard phase == .ready, let base, let current = host.currentZoomBase(), current.key == base.key else { return false }
        return environment == host.zoomStartEnvironment()
    }

    @discardableResult
    func advance(budget: CFTimeInterval) -> Bool {
        let start = CACurrentMediaTime()
        repeat {
            guard let host else { fail(); return false }
            switch phase {
            case .base: stepBase(host)
            case .layouts:
                stepLayouts()
                if phase == .layouts { return true }   // the background has it; nothing for main to do
            case .session: stepSession(host)
            case .planning: return true   // the background has it; nothing for main to do
            case .adopting: stepAdopt()
            case .fixed: stepFixed()
            case .ready, .failed: return false
            }
        } while CACurrentMediaTime() - start < budget && !isSettled
        return !isSettled
    }

    private func stepBase(_ host: LibraryGridHostController) {
        switch builder.advance(host: host) {
        case .more: break
        case .failed: fail()
        case .done(let made):
            host.zoomStart.base = made
            base = made
            phase = .layouts
        }
    }

    /// The levels' layouts (pure maths over the base) are made on a background task; the result is taken on main by the next step.
    private func stepLayouts() {
        guard layoutTask == nil, let base else { return }
        let levels = base.levels
        let slots = base.slots
        let ordinals = LibraryGridZoomSession.gridOrdinals(of: host)
        layoutTask = Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) {
                LibraryGridZoomSession.makeLayouts(levels: levels, slots: slots, gridOrdinal: ordinals)
            }.value
            self?.layoutsArrived(made)
        }
    }

    private func layoutsArrived(_ made: [GridZoomLevelLayout]) {
        guard phase == .layouts else { return }
        layoutTask = nil
        layouts = made
        phase = .session
    }

    private func finishLayoutsNow() {
        guard phase == .layouts, let base else { return }
        layoutTask?.cancel()
        layoutTask = nil
        layouts = LibraryGridZoomSession.makeLayouts(levels: base.levels, slots: base.slots,
                                                     gridOrdinal: LibraryGridZoomSession.gridOrdinals(of: host))
        phase = .session
    }

    func makeShell() {
        finishLayoutsNow()
        if phase == .session, let host { stepSession(host) }
    }

    private func stepSession(_ host: LibraryGridHostController) {
        guard let base else { return fail() }
        environment = host.zoomStartEnvironment()
        let aim = GridZoomAim.pick(base: base, host: host, point: point, centreSteps: centreSteps)
        self.aim = aim
        let made = LibraryGridZoomSession(host: host, base: base, aim: aim, layouts: layouts)
        session = made
        made.stage = LibraryGridZoomStage(session: made, collection: host.collectionView)
        let inputs = made.planInputs()
        let scene = made.scene!
        let viewport = made.viewport
        phase = .planning
        planTask = Task { [weak self] in
            let set = await Task.detached(priority: .userInitiated) {
                GridZoomPlanSet.compute(scene: scene, viewport: viewport, extraWidths: inputs.widths, shifts: inputs.shifts,
                                        coverHeight: LibraryGridGeometry.coverHeight(cardWidth:))
            }.value
            self?.plansArrived(set)
        }
    }

    private func plansArrived(_ set: GridZoomPlanSet) {
        guard phase == .planning, let session else { return }
        planTask = nil
        take(plans: set, into: session)
    }

    private func take(plans set: GridZoomPlanSet, into session: LibraryGridZoomSession) {
        session.apply(plans: set)
        session.host?.zoomCells.retain(session: session)
        // Nearest the start level first: those are on screen first as the zoom runs; on-screen cells first.
        adoptList = []
        let anchor = session.anchor
        for level in session.levels.indices.sorted(by: { abs($0 - session.startLevel) < abs($1 - session.startLevel) }) {
            for slot in session.needed[level].sorted(by: { abs($0 - anchor) < abs($1 - anchor) }) { adoptList.append((level, slot)) }
        }
        adoptNext = 0
        phase = .adopting
    }

    /// The most main one adopt step spends (cells are taken one at a time until it is used up; a step is never empty).
    private static let adoptSlice: CFTimeInterval = 0.0004

    private func stepAdopt() {
        guard let session, let stage = session.stage else { return fail() }
        // The (still empty) container goes into the hierarchy first, in a step of its own, and the cells are added to it a slice
        // at a time: inserting a container with all its cells at once was several milliseconds.
        if stage.parkIfNeeded() { return }
        let began = CACurrentMediaTime()
        repeat {
            guard adoptNext < adoptList.count else { break }
            let entry = adoptList[adoptNext]
            adoptNext += 1
            stage.adopt(level: entry.level, slot: entry.slot)
        } while CACurrentMediaTime() - began < Self.adoptSlice
        if adoptNext >= adoptList.count {
            phase = .fixed
            stage.drawLabelsAhead()   // off main; the pinch's first frame finds them drawn
        }
    }

    private func stepFixed() {
        guard let stage = session?.stage else { return fail() }
        if stage.parkIfNeeded() { return }
        if !stage.stepFixedAhead() { phase = .ready }
    }

    /// Finish it now, on main (a release before the background landed, the picker, a test): the plans inline, every cell adopted.
    func completeNow() {
        while !isSettled {
            guard let host else { return fail() }
            switch phase {
            case .base: stepBase(host)
            case .layouts: finishLayoutsNow()
            case .session: stepSession(host)
            case .planning:
                planTask?.cancel()
                planTask = nil
                if let session {
                    let inputs = session.planInputs()
                    take(plans: GridZoomPlanSet.compute(scene: session.scene, viewport: session.viewport, extraWidths: inputs.widths,
                                                        shifts: inputs.shifts, coverHeight: LibraryGridGeometry.coverHeight(cardWidth:)),
                         into: session)
                } else {
                    fail()
                }
            case .adopting: stepAdopt()
            case .fixed: stepFixed()
            case .ready, .failed: break
            }
        }
    }

    private func fail() {
        planTask?.cancel()
        planTask = nil
        layoutTask?.cancel()
        layoutTask = nil
        phase = .failed
    }

    func consume() -> LibraryGridZoomSession? {
        guard phase == .ready, !consumed else { return nil }
        consumed = true
        return session
    }

    func discard() {
        planTask?.cancel()
        planTask = nil
        layoutTask?.cancel()
        layoutTask = nil
        if !consumed, let session { session.stage?.discard() }
        session = nil
        consumed = true
        if !isSettled { phase = .failed }
    }
}

// MARK: - The host's state

@MainActor
final class GridZoomStartState {
    var base: GridZoomBase?
    var build: GridZoomStartBuild?
    var driver: GridZoomStartDriver?
    var bridge: GridZoomBridge?
    var scrollToken: DeferredMainWork.Token?
    var scrollIdleTask: Task<Void, Never>?
    var lastScrollAt: CFTimeInterval = 0
    var pageActive = true
}


/// Frame-driven stepping for a build that is wanted now (two fingers down): the deferred-work gate is shut while a
/// touch is active, so this is its own clock, a small budget a frame.
@MainActor
final class GridZoomStartDriver {
    private var link: CADisplayLink?
    private var proxy: LibraryGridLinkProxy?
    private weak var host: LibraryGridHostController?
    init(host: LibraryGridHostController) { self.host = host }

    func start() {
        guard link == nil else { return }
        let proxy = LibraryGridLinkProxy { [weak self] in MainActor.assumeIsolated { self?.host?.zoomStartTick() } }
        let link = CADisplayLink(target: proxy, selector: #selector(LibraryGridLinkProxy.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        self.proxy = proxy
    }

    func stop() {
        link?.invalidate()
        link = nil
        proxy = nil
    }
}

// MARK: - The pinch's bridge

/// The pinch the bridge is carrying.
@MainActor
final class GridZoomBridge {
    var scale: CGFloat = 1
    let point: CGPoint
    let began: CFTimeInterval
    var restarts = 0
    var end: (velocity: CGFloat, cancelled: Bool)?
    var firstFrame: CFTimeInterval?
    init(point: CGPoint, began: CFTimeInterval) {
        self.point = point
        self.began = began
    }
}

// MARK: - The rest-time cells

/// The rest-time cell cache: the stage cells (a cover and a label image each) of the cards a pinch from here can show, at the
/// levels' widths, kept hidden between zooms. A prepared session grows it, a discarded one hands its cells back, a landing keeps
/// the zoom's own; a begin takes from it, so building a cell is a view move. Valid for the content it was built from
/// (`zoomContentStamp`), bounded, and emptied by a memory warning.
@MainActor
final class LibraryGridZoomCellCache {
    struct Key: Hashable {
        let card: String
        let width: Int
    }
    private(set) var stamp: Int
    private var cells: [Key: LibraryGridZoomCell] = [:]
    private var order: [Key] = []
    static let capacity = 160
    private var observer: NSObjectProtocol?

    init(stamp: Int) {
        self.stamp = stamp
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAll() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var count: Int { cells.count }

    static func key(_ card: LibraryGridCard, width: CGFloat) -> Key { Key(card: card.key, width: Int((width * 2).rounded())) }

    func take(card: LibraryGridCard, width: CGFloat, level: Int, slot: Int) -> LibraryGridZoomCell? {
        let key = Self.key(card, width: width)
        guard let cell = cells.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        return cell
    }

    func keep(cells kept: [[Int: LibraryGridZoomCell]], session: LibraryGridZoomSession) {
        guard let host = session.host, stamp == host.zoomContentStamp else { return }
        for (level, bySlot) in kept.enumerated() {
            for (slot, cell) in bySlot {
                guard case .card(let card) = host.items[session.slots[slot]] else { continue }
                let key = Self.key(card, width: session.levels[level].cardWidth)
                if cells[key] == nil { order.append(key) }
                cells[key] = cell
            }
        }
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            cells[oldest] = nil
        }
    }

    /// Keeps only what the next pinch from here can show: a cell for a scroll position or level it can no longer reach is dropped.
    func retain(session: LibraryGridZoomSession) {
        guard let host = session.host, stamp == host.zoomContentStamp else { return }
        var wanted = Set<Key>()
        for level in session.levels.indices {
            for slot in session.needed[level] {
                if case .card(let card) = host.items[session.slots[slot]] { wanted.insert(Self.key(card, width: session.levels[level].cardWidth)) }
            }
        }
        for key in cells.keys where !wanted.contains(key) { cells[key] = nil }
        order.removeAll { !wanted.contains($0) }
    }

    func removeAll() {
        cells = [:]
        order = []
    }
}

// MARK: - The host's side

extension LibraryGridHostController {

    var zoomCells: LibraryGridZoomCellCache {
        if zoomCellStorage == nil || zoomCellStorage!.stamp != zoomContentStamp { zoomCellStorage = LibraryGridZoomCellCache(stamp: zoomContentStamp) }
        return zoomCellStorage!
    }

    /// The page moved (new data, a layout at another width, a landing, bands measured): every stamp keyed on it
    /// moves, and a start made for the old page goes. `content`: the cells' own content changed too.
    func modelDidChange(content: Bool = true) {
        zoomStamp &+= 1
        if content { zoomContentStamp &+= 1 }
        // A start made for the old page goes. A bridge carrying a pinch is NOT dropped: it finds its build gone and
        // asks for a new one (twice), then makes the session inline (`completeBridge`).
        if zoomStart.build != nil { discardZoomStart() }
    }

    // MARK: The base

    func currentZoomBase() -> GridZoomBase? {
        guard let base = zoomStart.base, isViewLoaded, collectionView != nil else { return nil }
        return base.key == GridZoomBase.Key(stamp: zoomStamp, columns: columns, layout: layoutKey) ? base : nil
    }

    func zoomStartBaseNow() -> GridZoomBase? {
        if let base = currentZoomBase() { return base }
        let builder = GridZoomBaseBuilder()
        while true {
            switch builder.advance(host: self) {
            case .more: continue
            case .failed: return nil
            case .done(let base):
                zoomStart.base = base
                return base
            }
        }
    }

    func zoomStartEnvironment() -> GridZoomStartEnvironment {
        let collection = collectionView!
        return GridZoomStartEnvironment(offset: collection.contentOffset.y, insetTop: collection.adjustedContentInset.top,
                                        insetBottom: collection.adjustedContentInset.bottom, size: collection.bounds.size,
                                        category: collection.traitCollection.preferredContentSizeCategory,
                                        style: collection.traitCollection.userInterfaceStyle)
    }

    // MARK: The build

    /// A start for these fingers, wanted now: kept if the one in hand is for them, else replaced; stepped by a display link.
    func prepareZoomStart(at point: CGPoint?, centreSteps: Bool) {
        let state = zoomStart
        guard zoom == nil, state.pageActive, isViewLoaded else { return }
        cancelZoomPrebuild()
        if let existing = state.build, existing.phase != .failed {
            let stale = existing.phase == .ready && !existing.isCurrent(in: self)
            if !stale, existing.matches(point: point, centreSteps: centreSteps, host: self) {
                existing.urgent = true
                startZoomStartDriver()
                return
            }
        }
        discardZoomStart()
        let build = GridZoomStartBuild(host: self, point: point, centreSteps: centreSteps)
        build.urgent = true
        state.build = build
        startZoomStartDriver()
    }

    private func startZoomStartDriver() {
        let state = zoomStart
        guard let build = state.build, !build.isSettled else { return }
        let driver = state.driver ?? GridZoomStartDriver(host: self)
        state.driver = driver
        driver.start()
    }

    func zoomStartTick() {
        let state = zoomStart
        guard let build = state.build else {
            state.driver?.stop()
            if state.bridge == nil { return }
            completeBridge(force: false)
            return
        }
        if !build.isSettled { build.advance(budget: Self.zoomStartFrameBudget) } else { state.driver?.stop() }
        completeBridge(force: false)
    }

    static let zoomStartFrameBudget: CFTimeInterval = 0.0025

    func discardZoomStart() {
        let state = zoomStart
        state.driver?.stop()
        if let build = state.build {
            state.build = nil
            build.discard()
        }
    }

    /// The ready start for these fingers, taken out of the host (it is the caller's session now); nil when none is ready, current and aimed the same.
    func takeReadyZoomStart(at point: CGPoint?, centreSteps: Bool) -> LibraryGridZoomSession? {
        let state = zoomStart
        guard let build = state.build, build.isCurrent(in: self), let base = currentZoomBase(), build.centreSteps == centreSteps,
              build.aim == GridZoomAim.pick(base: base, host: self, point: point, centreSteps: centreSteps) else { return nil }
        state.build = nil
        state.driver?.stop()
        return build.consume()
    }

    // MARK: The head start

    /// Two fingers are on the grid and no pinch has begun: the start for them is made now, in the tens of ms the
    /// recognizer waits for the fingers to move.
    func noteTwoFingersDown(at location: CGPoint) {
        guard zoom == nil, zoomStart.bridge == nil, zoomStart.pageActive else { return }
        let visible = CGPoint(x: location.x - collectionView.contentOffset.x, y: location.y - collectionView.contentOffset.y)
        prepareZoomStart(at: visible, centreSteps: true)
    }

    // MARK: The pinch (what the recognizer calls)

    private var canBeginZoom: Bool {
        isViewLoaded && view.window != nil && collectionView.bounds.height > 0 && zoom == nil && live != nil && stops.count >= 2
    }

    @discardableResult
    func pinchBegan(at visible: CGPoint) -> Bool {
        let began = CACurrentMediaTime()
        if zoom != nil {
            guard beginZoom(at: visible) != nil else { return false }
            zoom?.pinch(scale: 1)
            return true
        }
        guard canBeginZoom else { return false }
        if let ready = takeReadyZoomStart(at: visible, centreSteps: true) {
            attachZoom(ready)
            zoom?.pinch(scale: 1)
            return true
        }
        startBridge(at: visible, began: began)
        return true
    }

    func pinchChanged(scale: CGFloat, at visible: CGPoint) {
        if let bridge = zoomStart.bridge {
            bridge.scale = scale
            applyBridgeTransform(bridge)
            completeBridge(force: false)
            return
        }
        guard let zoom, !zoom.settling else { return }
        zoom.pinch(scale: scale)
    }

    func pinchEnded(velocity: CGFloat, cancelled: Bool) {
        if let bridge = zoomStart.bridge {
            bridge.end = (velocity, cancelled)
            completeBridge(force: true)
            return
        }
        guard let zoom, !zoom.settling else { return }
        zoom.release(velocity: velocity, cancelled: cancelled)
    }

    // MARK: The bridge

    private func startBridge(at visible: CGPoint, began: CFTimeInterval) {
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
        collectionView.panGestureRecognizer.isEnabled = false
        cancelZoomIdleWork()
        let bridge = GridZoomBridge(point: visible, began: began)
        zoomStart.bridge = bridge
        prepareZoomStart(at: visible, centreSteps: true)
        applyBridgeTransform(bridge)
        bridge.firstFrame = CACurrentMediaTime()
    }

    /// The live grid's cards placed by the session's own rule (`LibraryGridZoomSession.bridgeFrame`): a transform per view, no
    /// layout, no new views; the page's other views stay where they are. The scene needs only the levels' layouts, so it is taken
    /// from the build as soon as the build has made it; until then the cells wait where they are.
    private func applyBridgeTransform(_ bridge: GridZoomBridge) {
        guard let session = bridgeShell() else { return }
        let (placer, shift) = session.bridgeFrame(scale: bridge.scale)
        let offset = collectionView.contentOffset.y
        var lit: [(key: String, art: CGRect, alpha: CGFloat)] = []
        UIView.performWithoutAnimation {
            for case let cell as LibraryGridCardCell in collectionView.visibleCells {
                guard let item = collectionView.indexPath(for: cell)?.item, let slot = session.slot(ofItem: item),
                      let placed = placer.position(session.startLevel, slot) else { cell.clearZoomPlacement(); continue }
                let rect = placed.cover.offsetBy(dx: 0, dy: shift + offset)
                cell.applyZoomPlacement(rect)
                lit.append((cell.key, LibraryGridGeometry.artworkRect(cardWidth: rect.width).offsetBy(dx: rect.minX, dy: rect.minY), 1))
            }
        }
        glow?.followBridge(lit)
    }

    private func bridgeShell() -> LibraryGridZoomSession? {
        guard let build = zoomStart.build, build.phase != .failed else { return nil }
        if build.phase == .layouts || build.phase == .session { build.makeShell() }
        return build.session
    }

    private func clearBridgeTransform() {
        UIView.performWithoutAnimation {
            for case let cell as LibraryGridCardCell in collectionView.visibleCells { cell.clearZoomPlacement() }
        }
    }

    func completeBridge(force: Bool) {
        let state = zoomStart
        guard let bridge = state.bridge else { return }
        var session = takeReadyZoomStart(at: bridge.point, centreSteps: true)
        if session == nil {
            if let build = state.build, build.phase == .failed { return cancelBridge() }
            // Nothing in preparation for these fingers, or a ready one that no longer fits: once more or twice, then inline.
            let lost = state.build == nil || state.build?.phase == .ready
            if lost, !force {
                bridge.restarts += 1
                if bridge.restarts <= 2, state.pageActive {
                    prepareZoomStart(at: bridge.point, centreSteps: true)
                    return
                }
            } else if !force {
                return   // still on its way
            }
            if let build = state.build, !build.isSettled, build.matches(point: bridge.point, centreSteps: true, host: self) {
                build.completeNow()
                session = takeReadyZoomStart(at: bridge.point, centreSteps: true)
            }
            if session == nil {
                discardZoomStart()
                session = LibraryGridZoomSession.make(host: self, at: bridge.point, centreSteps: true)
            }
        }
        guard let session else { return cancelBridge() }
        state.bridge = nil
        clearBridgeTransform()
        session.seedPinch(scale: bridge.scale)
        attachZoom(session)
        if let end = bridge.end { zoom?.release(velocity: end.velocity, cancelled: end.cancelled) }
    }

    /// There is nothing to zoom (a page of placeholders, one level), or the host is going: the pinch is dropped
    /// and **the grid's own pan is back** (a bridge can never leak it: every exit of a bridge comes through here).
    func cancelBridge() {
        zoomStart.bridge = nil
        clearBridgeTransform()
        glow?.setSuspended(false)   // the light left rest for the bridge's frames
        collectionView.panGestureRecognizer.isEnabled = true
        discardZoomStart()
        flushPendingUpdate()
    }

    /// A bridge still carrying a pinch when its host is going away (or its page was replaced) has switched the
    /// grid's own pan off and may never be told the fingers lifted: it is cancelled, which puts the pan back.
    func dropBridgeIfLive() {
        if zoomStart.bridge != nil { cancelBridge() }
    }

    /// The last finger is up: a bridge that was never told (its recognizer cancelled without an end) lands or
    /// goes now, and one that has outlived any pinch is dropped.
    func fingersAllUp() {
        guard let bridge = zoomStart.bridge else { return }
        if bridge.end == nil { bridge.end = (0, true) }
        completeBridge(force: true)
    }

    // MARK: Recording

}
