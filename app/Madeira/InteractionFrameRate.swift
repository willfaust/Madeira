// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit

/// What the busy signal needs to know about a finger, read from the touch's OWN phase.
@MainActor protocol LiveTouch: AnyObject {
    /// False once the finger lifted or the system cancelled it.
    var isDown: Bool { get }
    var hostView: UIView? { get }
}

extension UITouch: LiveTouch {
    var isDown: Bool { phase != .ended && phase != .cancelled }
    var hostView: UIView? { view }
}

/// Asks the display for 120 Hz, explicitly, while the user's finger is on the app and for a short grace afterwards (and as long as a
/// scroll view under the finger still drags or coasts). App-wide: every list, sheet and the library grid. It runs only while the
/// "New library grid" setting is on.
///
/// Why: on a ProMotion iPhone a UIScrollView coast runs at 80 Hz after a short, quick flick (iOS's own frame-rate policy). A
/// CADisplayLink whose `preferredFrameRateRange` is 80...120 preferring 120 is the supported way to say "this motion wants the full rate".
///
/// Never while a game runs: `ProMotionIntent` owns the panel then (the FPS caps are multiples of the rate it chooses), and a touch on
/// the game's controls must not move the cap grid. A link that exists when a game starts is ended. Cost: one counter update per touch
/// begin/end (a window gesture recognizer that never recognizes), nothing while idle. It never asks above the panel's maximum, and
/// stays off in Low Power Mode and in the background.
@MainActor final class InteractionFrameRate: NSObject {
    static let shared = InteractionFrameRate()
    nonisolated static let grace: CFTimeInterval = 0.6

    /// On with the "New library grid" setting; off, nothing in this file runs (no touch recognizer is installed).
    static var switchedOn: Bool { LibraryGridArm.enabled }

    static var gameRunning: Bool { LibraryModel.shared.current != nil || wine_process_is_running() != 0 }

    nonisolated static func shouldStop(now: CFTimeInterval, lastTouchUp: CFTimeInterval, touchesDown: Int, scrollLive: Bool) -> Bool {
        touchesDown == 0 && !scrollLive && now - lastTouchUp >= grace
    }

    private var link: CADisplayLink?
    /// Fingers down are derived, never counted: a running counter drifted (a began with no end that reached the recognizer) and then the
    /// busy signal and the 120 Hz link were stuck. These are the touches' own phases, read when asked; a touch gone from memory is a finger that is up.
    private var tracked: [WeakTouch] = []
    /// The app's touch event (UIKit reuses one), whose `allTouches` also holds fingers the observer was never handed.
    private weak var lastEvent: UIEvent?
    private var lastTouchUp: CFTimeInterval = 0
    private var scrolls: [WeakScroll] = []
    private var observers: [NSObjectProtocol] = []
    private struct WeakScroll { weak var view: UIScrollView? }
    private struct WeakTouch { weak var touch: (any LiveTouch)? }

    var touchesDownCount: Int {
        settle()
        let live = tracked.compactMap(\.touch).filter(\.isDown)
        let eventLive = (lastEvent?.allTouches ?? []).filter { $0.isDown }.filter { t in !live.contains { $0 === t } }
        return live.count + eventLive.count
    }

    /// Forgets the touches that are up (or gone) and stamps the moment the last finger was seen up.
    private func settle() {
        let before = tracked.count
        tracked.removeAll { $0.touch?.isDown != true }
        if before > 0, tracked.isEmpty { lastTouchUp = CACurrentMediaTime() }
    }

    private var allowed: Bool { Self.switchedOn && !Self.gameRunning && !ProcessInfo.processInfo.isLowPowerModeEnabled }

    func touchesBegan(_ touches: [any LiveTouch], event: UIEvent? = nil) {
        if let event { lastEvent = event }
        settle()
        for touch in touches where touch.isDown {
            tracked.append(WeakTouch(touch: touch))
            // Tracked at touch-down, link or no link: the deferred-work gate reads the same scrolls.
            var v = touch.hostView
            while let current = v {
                if let s = current as? UIScrollView, !scrolls.contains(where: { $0.view === s }) { scrolls.append(WeakScroll(view: s)) }
                v = current.superview
            }
        }
        scrolls.removeAll { $0.view == nil }
        startLinkIfWanted()
    }

    private func startLinkIfWanted() {
        guard link == nil, allowed else { return }
        let panel = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.maximumFramesPerSecond ?? 60
        guard panel > 60 else { return }   // a 60 Hz panel has nothing to ask for
        let top = Float(min(panel, 120))
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, top), maximum: top, preferred: top)
        l.add(to: .main, forMode: .common)
        link = l
        installObservers()
    }

    func end() {
        link?.invalidate(); link = nil
        tracked.removeAll()
        scrolls.removeAll()
    }

    private static func isLive(_ view: UIScrollView?) -> Bool { (view?.isDecelerating ?? false) || (view?.isDragging ?? false) }

    /// Is the user busy right now: a finger down, or a scroll view under the last finger still dragging or coasting (nested ones included).
    /// The app-wide answer; `DeferredMainWork` reads it (`publishToDeferredWork`).
    var isUserBusy: Bool { touchesDownCount > 0 || scrolls.contains { Self.isLive($0.view) } }

    /// Hands this state to the deferred-main-work gate as its touch signal (idempotent).
    func publishToDeferredWork() {
        DeferredMainWork.shared.addCondition("touch", owner: self) { [weak self] in self?.isUserBusy ?? false }
    }

    @objc private func tick() {
        if Self.gameRunning || !Self.switchedOn { end(); return }
        let down = touchesDownCount
        scrolls.removeAll { $0.view == nil || (down == 0 && !Self.isLive($0.view)) }
        if Self.shouldStop(now: CACurrentMediaTime(), lastTouchUp: lastTouchUp, touchesDown: down,
                           scrollLive: scrolls.contains { Self.isLive($0.view) }) { end() }
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let stop: (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.end() } }
        observers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main, using: stop),
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: stop),
            center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main, using: stop),
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: stop),
        ]
    }
}

/// Never recognizes anything: it reports a touch-down to `InteractionFrameRate` and FAILS AT ONCE. A recognizer that stays `.possible`
/// for a touch sequence has bookkeeping that can go wrong, and a stuck one is felt as dead scroll and swipe-back; this one has none
/// (touch-ups are read from the touches' own phases by the singleton) and is out of every other recognizer's way before the first
/// frame. Every touch goes through untouched (the game's touch controls included).
final class WindowTouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let all = Array(touches)
        MainActor.assumeIsolated { InteractionFrameRate.shared.touchesBegan(all, event: event) }
        state = .failed
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
}

/// Zero-size background view that attaches the observer to the window it lives in.
struct InteractionFrameRateInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ view: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        private var observer: WindowTouchObserver?
        private weak var host: UIWindow?
        private var defaultsObserver: NSObjectProtocol?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard window != nil else { return }
            attachIfWanted()
            defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if InteractionFrameRate.switchedOn { self.attachIfWanted() } else { self.detachObserver() }
                }
            }
        }
        private func attachIfWanted() {
            guard observer == nil, InteractionFrameRate.switchedOn, let window else { return }
            let o = WindowTouchObserver()
            window.addGestureRecognizer(o)
            MainActor.assumeIsolated { InteractionFrameRate.shared.publishToDeferredWork() }
            observer = o; host = window
        }
        /// Removes the touch recognizer and ends the link. The defaults observer stays, so turning the setting back on re-attaches.
        private func detachObserver() {
            if let observer, let host { host.removeGestureRecognizer(observer) }
            observer = nil; host = nil
            MainActor.assumeIsolated { InteractionFrameRate.shared.end() }
        }
        /// Full teardown, when the view leaves its window.
        private func detach() {
            if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
            defaultsObserver = nil
            detachObserver()
        }
    }
}
