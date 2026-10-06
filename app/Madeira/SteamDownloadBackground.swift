// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import UIKit
import BackgroundTasks
import UserNotifications

// Steam downloads keep going when Madeira leaves the foreground
// (docs/STEAM_LIBRARY.md, "Downloads in the background").
//
// iOS 26 and later: a BGContinuedProcessingTask, submitted when a download
// starts, lets Madeira keep running in the background for the whole queue; iOS
// shows its own progress UI for it (title, game, percentage, a cancel control),
// fed from the downloader's byte counts. Its identifier is
// "<bundle id>.download.queue", permitted by the `$(PRODUCT_BUNDLE_IDENTIFIER).download.*`
// entry of BGTaskSchedulerPermittedIdentifiers in Info.plist.
//
// Earlier iOS, or when iOS refuses the request (for example a re-signed bundle
// whose identifier no longer matches the permitted one): the usual short
// background grace period, then the download pauses cleanly (every finished
// chunk is journaled) and continues when Madeira is active again. A local
// notification says so, and reports a download that finished or failed while
// Madeira was in the background; the permission is asked for when the first
// download starts.
//
// `env.MADEIRA_BACKGROUND_DOWNLOADS = 0`: no continued-processing task (the
// grace period and the clean pause remain). `env.MADEIRA_DOWNLOAD_NOTIFICATIONS
// = 0`: no notifications and no permission request.
// Log tag: [bg-download] (counts and states only).
@MainActor final class SteamDownloadBackground {
    static let shared = SteamDownloadBackground()
    /// On iOS 26 and later, Steam downloads continue in the background as a continued-processing task that iOS shows with its progress. 0: only the short grace period, then a clean pause until Madeira is active again.
    static var continuedEnabled: Bool { SteamSignIn.flag("MADEIRA_BACKGROUND_DOWNLOADS", default: true) }
    /// Local notifications when a Steam download finishes, fails or pauses while Madeira is in the background (permission asked at the first download). 0: none, and no permission request.
    static var notificationsEnabled: Bool { SteamSignIn.flag("MADEIRA_DOWNLOAD_NOTIFICATIONS", default: true) }

    private let source: String
    private let suffix: String
    private var activeDownload: (() -> Bool)?
    private var pauseDownloads: (() -> Void)?
    private var resumeDownloads: (() -> Void)?
    private weak var library: SteamOwnedLibrary?

    // Separate identifiers let Epic and Steam continue independently in the background.
    init(source: String = "Steam", suffix: String = "queue") {
        self.source = source; self.suffix = suffix
    }
    private var graceTask: UIBackgroundTaskIdentifier = .invalid
    private var continued: AnyObject?            // BGContinuedProcessingTask (iOS 26+)
    private var continuedPending = false
    private var registered: String?
    private var observing = false
    private var askedNotifications = false
    private var logged = 0
    private var currentName = ""

    private func log(_ line: String) {
        guard logged < 48 else { return }
        logged += 1
        SteamLog.event("[bg-download] " + line)
    }

    private var isBackground: Bool { UIApplication.shared.applicationState != .active }

    /// The permitted "<bundle id>.download.*" identifier from Info.plist, made concrete.
    private var taskIdentifier: String? {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard let wildcard = permitted.first(where: { $0.hasSuffix(".download.*") }) else { return nil }
        return String(wildcard.dropLast()) + suffix
    }

    /// Called once, when the library model starts.
    func attach(_ library: SteamOwnedLibrary) {
        self.library = library
        attach(active: { [weak library] in library?.hasActiveDownload == true },
               pause: { [weak library] in library?.pauseForBackground() },
               resume: { [weak library] in library?.resumeAfterBackground(); library?.reconcileSession() })
    }

    func attach(active: @escaping () -> Bool, pause: @escaping () -> Void, resume: @escaping () -> Void) {
        activeDownload = active; pauseDownloads = pause; resumeDownloads = resume
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginGrace() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endGrace()
                self?.resumeDownloads?()
            }
        }
    }

    /// A download became active (always a user action or its queue).
    func downloadStarted(appID: Int, name: String) {
        currentName = name
        requestNotificationPermission()
        if #available(iOS 26.0, *), Self.continuedEnabled { submitContinued() }
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.updateTitle("Downloading \(name)", subtitle: "\(source) download in Madeira")
        }
        if isBackground { beginGrace() }
    }

    func progress(_ progress: SteamDownloadProgress) {
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            let total = Int64(clamping: max(progress.totalBytes, 1))
            if task.progress.totalUnitCount != total { task.progress.totalUnitCount = total }
            task.progress.completedUnitCount = Int64(clamping: min(progress.doneBytes, progress.totalBytes))
        }
    }

    enum Outcome { case completed, failed(String), paused }

    /// One download ended. `queueEmpty`: nothing else is waiting.
    func downloadEnded(appID: Int, name: String, outcome: Outcome, queueEmpty: Bool) {
        if isBackground {
            switch outcome {
            case .completed: notify("\(name) is ready to play", body: "The \(source) download finished.")
            case .failed(let reason): notify("\(name) download stopped", body: reason)
            case .paused: break
            }
        }
        guard queueEmpty else { return }
        finishContinued(success: { if case .completed = outcome { return true }; return false }())
        endGrace()
    }

    // MARK: iOS 26 continued processing

    @available(iOS 26.0, *)
    private func submitContinued() {
        guard continued == nil, !continuedPending, let identifier = taskIdentifier else { return }
        if registered != identifier {
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                MainActor.assumeIsolated { self?.attach(task) }
            }
            guard ok else { log("register refused id-suffix=queue"); return }
            registered = identifier
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Downloading \(currentName)",
                                                       subtitle: "\(source) download in Madeira")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            continuedPending = true
            log("continued-processing submitted")
        } catch {
            log("continued-processing refused")
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        continuedPending = false
        continued = task
        task.progress.totalUnitCount = 1
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.log("continued-processing expired; pausing downloads")
                self?.pauseDownloads?()
                self?.notify("Download paused", body: "Open Madeira to continue downloading.")
                self?.finishContinued(success: false)
            }
        }
        log("continued-processing running")
        if activeDownload?() != true { finishContinued(success: true) }
    }

    private func finishContinued(success: Bool) {
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
            log("continued-processing completed success=\(success ? 1 : 0)")
        }
        continued = nil
    }

    // MARK: Short grace period (all iOS versions)

    private func beginGrace() {
        guard graceTask == .invalid, continued == nil, activeDownload?() == true else { return }
        graceTask = UIApplication.shared.beginBackgroundTask(withName: "Madeira \(source) download") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Continued processing keeps the app running; only pause without it.
                if self.continued == nil {
                    self.log("background time over; pausing downloads")
                    self.pauseDownloads?()
                    self.notify("Download paused", body: "Open Madeira to continue downloading.")
                }
                self.endGrace()
            }
        }
        log("background grace begun continued=\(continued == nil ? 0 : 1)")
    }

    private func endGrace() {
        guard graceTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(graceTask)
        graceTask = .invalid
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        guard !askedNotifications, Self.notificationsEnabled else { return }
        askedNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { SteamDownloadBackground.shared.log("notifications granted=\(granted ? 1 : 0)") }
        }
    }

    private func notify(_ title: String, body: String) {
        guard Self.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "madeira.download.\(UUID().uuidString)",
                                                                     content: content, trigger: nil))
    }
}
