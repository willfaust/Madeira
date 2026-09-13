import Foundation
import Combine

/// The settings screen's live model.
///
/// `UserDefaults` is the durable copy; the `madeira-*.txt` files in Documents
/// are the *contract* with the engine, rewritten on every change. Both exist on
/// purpose: the files are what the launch sequence already reads (and what the
/// Files app can still edit by hand), and defaults are what survives a
/// reinstall of the app bundle.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private static let defaultsKey = "madeira.settings.v1"
    private static let ownedKey = "madeira.settings.ownedFiles"

    @Published var settings: MadeiraSettings = .empty {
        didSet {
            guard settings != oldValue else { return }
            persist()
            syncOverrideFiles()
        }
    }

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(MadeiraSettings.self, from: data) else { return }
        settings = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// Restore every knob to the engine's own default: the files are removed,
    /// not written with a guessed value. The sync is explicit because setting
    /// the value back to `.empty` from `.empty` is not a change.
    func reset() {
        settings = .empty
        syncOverrideFiles()
    }

    /// Write (or delete) the override files this configuration implies.
    ///
    /// Deleting rather than writing a default matters: the engine's defaults
    /// include device-derived values, so a written number would pin the device
    /// to whatever this screen happened to know about.
    ///
    /// Removal is limited to files this store wrote. The Files-app channel is
    /// still supported, and a hand-written `madeira-wx.txt` must not disappear
    /// because someone opened Settings and toggled an unrelated switch.
    ///
    /// Returns the file names that changed, without their contents: the remote
    /// token would otherwise be echoed into the on-screen log.
    @discardableResult
    func syncOverrideFiles() -> [String] {
        guard let dir = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask).first else { return [] }
        var owned = Set(UserDefaults.standard.stringArray(forKey: Self.ownedKey) ?? [])
        var touched: [String] = []
        for file in settings.overrideFiles {
            let url = dir.appendingPathComponent(file.name)
            if let body = file.body {
                try? body.write(to: url, atomically: true, encoding: .utf8)
                owned.insert(file.name)
                touched.append(file.name)
            } else if owned.contains(file.name) {
                try? FileManager.default.removeItem(at: url)
                owned.remove(file.name)
                touched.append("\(file.name) (default)")
            }
        }
        UserDefaults.standard.set(Array(owned), forKey: Self.ownedKey)
        return touched
    }

    /// Apply what is not expressible as a file. The frame-rate request lives in
    /// the engine's own state, so it is pushed directly — and only when the user
    /// actually chose one.
    func applyNonFileSettings() {
        guard let mode = settings.frameRate else { return }
        madeira_set_vsync_locked(Int32(mode.rawValue))
        ProMotionIntent.shared.setActive(mode != .sixty)
    }
}

/// What the home screen shows about the current run.
///
/// The launch sequence used to report a failed JIT pool by calling `exit(0)`
/// after a ten-second countdown, which reads to a user as "the app closed
/// itself". It now records the failure here instead, so the app stays up and
/// the same button that started the run can start it again.
final class RunStatus: ObservableObject {
    static let shared = RunStatus()

    enum Phase: Equatable {
        case idle
        case preparing
        case running
        case failed(String)

        var isBusy: Bool { self == .preparing || self == .running }
    }

    @Published var phase: Phase = .idle
    /// The pool that was actually allocated, in MB. Zero until a run starts.
    @Published var poolMB: Int = 0

    /// Polls `wine_process_is_running()`, which is the only honest answer to
    /// "is a session on screen?".
    ///
    /// `phase` used to be written only by the launch sequence, which meant
    /// `.running` lasted until the app was relaunched: for a game the sequence
    /// deliberately returns while Wine is still going, and nothing else ever
    /// cleared it. Two visible consequences — the home screen kept saying
    /// "Running" and kept its launch buttons disabled, and the on-screen pad
    /// (which keys off the same flag) stayed up over the tooling screens. Wine
    /// exiting is the real end of a session, so watch for it.
    private var watcher: Timer?
    private var sawWine = false
    private var watchingSince: CFAbsoluteTime = 0

    /// How long to wait for the Wine thread to appear before calling the launch
    /// a failure. `g_wine_running` flips as soon as the thread is created, so
    /// this only has to cover wineserver coming up plus the sequence's own 2s
    /// settle; 90s is slack for a cold prefix, and well under the 1200s cap.
    private static let startTimeout: CFAbsoluteTime = 90

    private init() {}

    func begin(preparing: Bool) {
        onMain {
            self.phase = preparing ? .preparing : .running
            self.watchingSince = CFAbsoluteTimeGetCurrent()
            self.sawWine = false
            self.startWatching()
        }
    }

    func succeed(poolMB: Int) {
        onMain {
            self.poolMB = poolMB
            self.phase = .running
        }
    }

    func fail(_ message: String) {
        onMain {
            self.phase = .failed(message)
            self.stopWatching()
        }
    }

    func reset() {
        onMain {
            self.phase = .idle
            self.poolMB = 0
            self.stopWatching()
        }
    }

    /// The session ended. `poolMB` deliberately survives: the chip that shows
    /// it is describing the pool this process still has mapped, not the run.
    private func end() {
        stopWatching()
        sawWine = false
        phase = .idle
        LogStore.shared.log("Wine exited — session over.", level: .info)
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    private func startWatching() {
        guard watcher == nil else { return }
        if watchingSince == 0 { watchingSince = CFAbsoluteTimeGetCurrent() }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.watch() }
        RunLoop.main.add(t, forMode: .common)
        watcher = t
    }

    private func stopWatching() {
        watcher?.invalidate()
        watcher = nil
    }

    private func watch() {
        if wine_process_is_running() != 0 {
            if !sawWine {
                sawWine = true
                LogStore.shared.log("Wine is running — session live.", level: .success)
            }
            if phase != .running { phase = .running }
            return
        }
        if sawWine {
            end()
            return
        }
        if watchingSince > 0, CFAbsoluteTimeGetCurrent() - watchingSince > Self.startTimeout {
            stopWatching()
            phase = .failed("Wine never started. Check the log, then launch again.")
        }
    }
}
