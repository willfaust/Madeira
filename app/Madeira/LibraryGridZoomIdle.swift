// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import UIKit

// **The zoom's pre-warm** (docs/zoomable-grid.md, "Pre-warm"). Main-thread work that is not needed this frame -
// warming the neighbour levels' covers, preparing the next pinch's session and its cells - waits on
// `DeferredMainWork`, the one gate that knows whether the user is interacting: a finger down or a scroller
// coasting (`InteractionFrameRate`'s app-wide busy signal), a pinch or its settle, a page transition. It runs in slices of about 2 ms
// and stops the instant something is.
//
// - Every scroll stop warms, however it stopped: the scroll's first callback opens an interaction token; the one watcher that runs
//   while the grid moves closes it when no callback has come for `scrollIdleAfter` and no finger is dragging. A scroll stopped by a tap
//   reaches neither `scrollViewDidEndDecelerating` nor `didEndDragging`, so the watcher is the only thing that sees it stop.
// - The warm is a job on the gate; a landing's keeps a longer delay (rapid zooms want a quiet grid), a scroll's stop does not.
// - The prebuild prepares the start for the middle of the screen (a `GridZoomStartBuild`): its cells are what the cell cache keeps.

extension LibraryGridHostController {

    private static let zoomWarmDelay: TimeInterval = 0.35
    private static let zoomWarmDelayAfterScroll: TimeInterval = 0.1
    private static let scrollIdleAfter: CFTimeInterval = 0.08
    private static let prebuildSlice: CFTimeInterval = 0.0008

    var zoomWarmKey: String { "grid-zoom.warm.\(ObjectIdentifier(self).hashValue)" }
    var zoomPrebuildKey: String { "grid-zoom.prebuild.\(ObjectIdentifier(self).hashValue)" }

    var zoomJobsHaveAScreen: Bool { zoomStart.pageActive && isViewLoaded && view.window != nil }

    func installZoomIdleSignals() {
        DeferredMainWork.shared.addCondition("grid-zoom", owner: self) { [weak self] in
            guard let self else { return false }
            return self.zoom != nil || self.zoomStart.bridge != nil
        }
        InteractionFrameRate.shared.publishToDeferredWork()
    }

    /// The warm is a job on `DeferredMainWork`: every scroll end and zoom landing calls this; resubmitting restarts the delay (the
    /// debounce), and the gate runs it only when nothing is interacting, after its quiet period.
    func scheduleZoomWarm(afterScroll: Bool = false) {
        guard zoomStart.pageActive else { return }
        let delay = afterScroll ? Self.zoomWarmDelayAfterScroll : Self.zoomWarmDelay
        DeferredMainWork.shared.schedule(key: zoomWarmKey, priority: .normal, delay: delay) { [weak self] in
            guard let self, self.zoomJobsHaveAScreen, self.zoom == nil else { return false }
            self.collectionView.isPrefetchingEnabled = true
            self.prefetchNeighbours()
            self.scheduleZoomPrebuild(afterScroll: afterScroll)
            return false
        }
    }

    /// The next pinch's start, prepared at rest in units of the gate: the session for the middle of the screen made in small steps (the
    /// plans on a background task), then its cells adopted hidden. A guard that fails ends it; the next rest schedules a fresh one.
    func scheduleZoomPrebuild(afterScroll: Bool = false) {
        guard zoomStart.pageActive else { return }
        DeferredMainWork.shared.schedule(key: zoomPrebuildKey, priority: .low, delay: afterScroll ? 0.06 : 0.4) { [weak self] in
            self?.prebuildStep() ?? false
        }
    }

    private func prebuildStep() -> Bool {
        guard zoomJobsHaveAScreen, zoom == nil, zoomStart.bridge == nil, !collectionView.isDragging, !collectionView.isDecelerating,
              !DeferredMainWork.shared.scrollActive else { return false }
        let state = zoomStart
        if let kept = state.build {
            // A current prepared start (or one still being made for the page as it is) is not the prebuild's to redo.
            if kept.phase == .ready { return !kept.isCurrent(in: self) ? restartPrebuild() : false }
            if kept.phase == .failed { state.build = nil; return restartPrebuild() }
        } else {
            let made = GridZoomStartBuild(host: self, point: nil, centreSteps: true)
            state.build = made
        }
        guard let build = state.build else { return false }
        build.advance(budget: Self.prebuildSlice)
        return !build.isSettled
    }

    private func restartPrebuild() -> Bool {
        discardZoomStart()
        zoomStart.build = GridZoomStartBuild(host: self, point: nil, centreSteps: true)
        return true
    }

    func cancelZoomPrebuild() { DeferredMainWork.shared.cancel(key: zoomPrebuildKey) }

    func cancelZoomIdleWork() {
        DeferredMainWork.shared.cancel(key: zoomWarmKey)
        zoomStart.scrollIdleTask?.cancel()
        zoomStart.scrollIdleTask = nil
        endScrollInteraction()
        cancelZoomPrebuild()
        collectionView.isPrefetchingEnabled = false   // no cell prefetch from a pinch's begin until the grid has been at rest
    }

    func suspendZoomIdleWork() {
        zoomStart.pageActive = false
        DeferredMainWork.shared.cancel(key: zoomWarmKey)
        zoomStart.scrollIdleTask?.cancel()
        zoomStart.scrollIdleTask = nil
        endScrollInteraction()
        cancelZoomPrebuild()
        dropBridgeIfLive()
        discardZoomStart()
        zoomCells.removeAll()
    }

    func holdIdleWork(during coordinator: UIViewControllerTransitionCoordinator?) {
        let gate = DeferredMainWork.shared
        if let coordinator {
            let token = gate.beginInteraction("page-transition")
            coordinator.animate(alongsideTransition: nil, completion: { _ in gate.endInteraction(token) })
        } else {
            gate.interact(for: 0.5, "page-transition")
        }
    }

    func resumeZoomIdleWork() {
        zoomStart.pageActive = true
        scheduleZoomWarm()
    }

    // MARK: Scroll stops

    func noteScrollMoved() {
        guard zoom == nil else { return }
        zoomStart.lastScrollAt = CACurrentMediaTime()
        // The prepared start was made for the position the grid just left; one wanted for a pinch that is starting is kept.
        if let build = zoomStart.build, !build.urgent { discardZoomStart() }
        if zoomStart.scrollToken == nil { zoomStart.scrollToken = DeferredMainWork.shared.beginInteraction("scroll") }
        guard zoomStart.scrollIdleTask == nil else { return }
        zoomStart.scrollIdleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, !Task.isCancelled else { return }
                if self.zoom != nil {
                    self.zoomStart.scrollIdleTask = nil
                    self.endScrollInteraction()
                    return
                }
                let quiet = CACurrentMediaTime() - self.zoomStart.lastScrollAt
                if quiet >= Self.scrollIdleAfter, !self.collectionView.isDragging, !self.collectionView.isDecelerating {
                    self.zoomStart.scrollIdleTask = nil
                    self.endScrollInteraction()
                    self.scheduleZoomWarm(afterScroll: true)
                    return
                }
            }
        }
    }

    func endScrollInteraction() {
        if let token = zoomStart.scrollToken {
            zoomStart.scrollToken = nil
            DeferredMainWork.shared.endInteraction(token)
        }
    }
}
