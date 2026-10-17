// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 LiamTheAppDev
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// The one place deferred main-thread work waits for the user to be still: warming covers, prebuilding views,
/// upgrading a cover. Work scheduled here waits for scrolls, pinches and page transitions alike. Foundation only.
///
/// Signals: a token (``beginInteraction(_:)`` ... ``endInteraction(_:)``: a navigation transition, a pinch), a timed token
/// (``interact(for:_:)``) or a polled condition (``addCondition(_:owner:_:)``: state that already lives elsewhere, a scroll view's
/// `isDragging`, a touch tracker's count; read only while work waits).
///
/// Work: ``schedule(key:priority:delay:unit:)`` registers a job under a key (resubmitting replaces it and restarts the delay: the
/// debounce) and a `unit` that does ONE small piece of work and returns whether more remains. The gate runs units only while no
/// signal is open and the quiet period has passed, for at most ``sliceBudget`` of main per turn, highest priority first, then
/// yields for a turn (``turnGap``). A unit already running finishes: it is the job's duty to make a unit small.
///
/// Nothing here may mutate the library or touch a store: it schedules, it does not own work.
@MainActor
final class DeferredMainWork {
    static let shared = DeferredMainWork()

    enum Priority: Int, Sendable, Comparable {
        case low = 0
        case normal = 1
        case high = 2
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    struct Token: Hashable, Sendable { fileprivate let id: Int }

    var quietPeriod: TimeInterval = 0.12
    var sliceBudget: TimeInterval = 0.002
    /// A job whose last unit ran for `c` waits `c * quietPerUnitCost` of stillness (between `quietPeriod` and `maxQuiet`) before its next unit:
    /// the gate cannot split a unit, so a heavy one is only started when the user has been still long enough to cover it.
    var quietPerUnitCost: Double = 3
    var maxQuiet: TimeInterval = 0.4
    /// The pause between slices (lets a frame commit; a gate that yielded 0 would still starve a display link).
    var turnGap: Duration = .milliseconds(2)
    var pollInterval: Duration = .milliseconds(30)
    /// Injectable for tests.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private struct Job {
        let key: String
        let priority: Priority
        var notBefore: TimeInterval
        let sequence: Int
        let unit: @MainActor () -> Bool
    }
    private struct Condition {
        let name: String
        weak var owner: AnyObject?
        let isOpen: @MainActor () -> Bool
    }

    private var jobs: [String: Job] = [:]
    private var tokens: [Token: String] = [:]
    private var timed: [(until: TimeInterval, reason: String)] = []
    private var conditions: [Condition] = []
    private var unitCost: [String: TimeInterval] = [:]
    private var nextID = 0
    private var lastBusyAt: TimeInterval = 0
    private var pump: Task<Void, Never>?

    init() {}

    // MARK: - Signals

    @discardableResult
    func beginInteraction(_ reason: String) -> Token {
        nextID += 1
        let token = Token(id: nextID)
        tokens[token] = reason
        return token
    }

    func endInteraction(_ token: Token) {
        guard tokens.removeValue(forKey: token) != nil else { return }
        lastBusyAt = now()
    }

    /// Interacting for the next `seconds` (extends, never shortens, a window already open for the reason).
    func interact(for seconds: TimeInterval, _ reason: String) {
        let until = now() + seconds
        timed.removeAll { $0.reason == reason && $0.until <= until }
        timed.append((until, reason))
    }

    /// A state-backed signal. It is open while `isOpen()` is true; it is dropped when `owner` deallocates. Adding one under an `(owner, name)` already registered replaces it.
    func addCondition(
        _ name: String, owner: AnyObject, _ isOpen: @escaping @MainActor () -> Bool
    ) {
        conditions.removeAll { $0.owner === owner && $0.name == name }
        conditions.append(Condition(name: name, owner: owner, isOpen: isOpen))
    }

    var openReasons: [String] {
        let t = now()
        timed.removeAll { $0.until <= t }
        conditions.removeAll { $0.owner == nil }
        var reasons = Array(tokens.values) + timed.map(\.reason)
        for condition in conditions where condition.isOpen() { reasons.append(condition.name) }
        return reasons
    }

    var isInteracting: Bool { !openReasons.isEmpty }

    // MARK: - Work

    /// Registers (or replaces) the job under `key`. `delay` is the least wait from now, on top of the quiet period.
    func schedule(
        key: String, priority: Priority = .normal, delay: TimeInterval = 0,
        unit: @escaping @MainActor () -> Bool
    ) {
        nextID += 1
        jobs[key] = Job(
            key: key, priority: priority, notBefore: now() + delay, sequence: nextID, unit: unit)
        startPump()
    }

    func cancel(key: String) {
        jobs[key] = nil
        unitCost[key] = nil
    }

    // MARK: - The gate

    /// Runs at most one slice now if the gate is open; returns true when a unit ran. The pump calls this;
    /// tests call it with an injected clock.
    @discardableResult
    func runSlice() -> Bool {
        let start = now()
        guard !jobs.isEmpty else { return false }
        if isInteracting {
            lastBusyAt = start
            return false
        }
        var ran = false
        while let job = nextRunnable(at: now()) {
            let wait = max(quietPeriod, min(maxQuiet, (unitCost[job.key] ?? 0) * quietPerUnitCost))
            guard now() - lastBusyAt >= wait else { break }
            let began = now()
            let more = job.unit()
            unitCost[job.key] = now() - began
            ran = true
            if jobs[job.key]?.sequence == job.sequence {
                if !more { jobs[job.key] = nil }
            }
            if now() - start >= sliceBudget || isInteracting { break }
        }
        return ran
    }

    // MARK: - Scroll activity

    /// Whether the user is scrolling the library grid (finger down through the end of the deceleration), and main-thread work that
    /// must wait for it to stop. Separate from the gate above: not a signal the gate reads, and its work runs at once when nothing
    /// scrolls. A Steam metadata result that lands mid-scroll republishes the library and rebuilds the page on main in the middle of a
    /// coast; ``whenScrollIdle(_:_:)`` runs its work at the end of the scroll (a short beat after, so the landing frame is not the one
    /// that pays). A later call with the same key replaces the earlier work, so a burst of results is one update.
    private(set) var scrollActive = false
    private var scrollWork: [(key: String, work: () -> Void)] = []
    private var scrollFlush: Task<Void, Never>?
    private var scrollObserver: NSObjectProtocol?

    func beginScroll() {
        scrollActive = true
        scrollFlush?.cancel(); scrollFlush = nil
        if scrollObserver == nil {
            // A scroll the app lost to the background never reports its end (UIApplication.willResignActiveNotification).
            let stop: (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.endScroll() } }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("UIApplicationWillResignActiveNotification"), object: nil, queue: .main, using: stop)
        }
    }

    func endScroll() {
        guard scrollActive else { return }
        scrollActive = false
        guard !scrollWork.isEmpty else { return }
        scrollFlush?.cancel()
        scrollFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self, !self.scrollActive else { return }
            let work = self.scrollWork; self.scrollWork = []
            for item in work { item.work() }
        }
    }

    func whenScrollIdle(_ key: String, _ work: @escaping () -> Void) {
        guard scrollActive else { work(); return }
        if let i = scrollWork.firstIndex(where: { $0.key == key }) { scrollWork[i].work = work } else { scrollWork.append((key, work)) }
    }

    private func nextRunnable(at time: TimeInterval) -> Job? {
        jobs.values.filter { $0.notBefore <= time }
            .max { ($0.priority, -$0.sequence) < ($1.priority, -$1.sequence) }
    }

    private func startPump() {
        guard pump == nil else { return }
        pump = Task { @MainActor [weak self] in
            while let self, !self.jobs.isEmpty, !Task.isCancelled {
                let ran = self.runSlice()
                try? await Task.sleep(for: ran ? self.turnGap : self.pollInterval)
            }
            self?.pump = nil
        }
    }
}
