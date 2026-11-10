// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import UIKit
import SwiftUI
import GameController
import os

// madeira-log-trail: what the player did and what Madeira did, in a few hundred short lines.
//
// A session log is mostly Wine, FEX and DXMT, and it never said which button was pressed,
// what had the focus, which screen was open or how long each start step took (Cameron, Nov 7:
// the Wave 10 game card bug left only "[menu-pad] open ready:steam:632360" behind). These
// lines fill that in. Each kind has a cap per app run, so a long session stays small:
//
//   [pad]        a controller press while Madeira's menus own the pad, and where the ring went
//   [focus]      iOS's own focus moving (a controller or keyboard can drive it beside Madeira's)
//   [screen]     a named page or sheet opening or closing, and any alert or sheet on top
//   [tap]        a tap in Madeira's menus: what was under the finger, and on which screen
//   [app]        Madeira going to the background, coming back, and iOS memory warnings
//   [step]       each start and quit step of a game, in seconds since Play
//   [game-start] the state a game started in: config, memory, JIT, controller
//   [game-end]   how it ended: the reason, the exit code, memory, the steps in one line
//   [last-run]   at the next start: the previous run ended while a game was running
//
// An [ERR] line that Madeira writes itself also says what was going on ("during: ...").
// env.MADEIRA_LOG_TRAIL = 0 turns all of this off.
enum LogTrail {
    static let enabled = MadeiraConfig.flag("MADEIRA_LOG_TRAIL")

    enum Kind: String { case pad, focus, screen, tap, app, step }
    /// Lines per kind per app run. A run of a few games stays at a few hundred lines.
    private static let caps: [Kind: Int] = [.pad: 250, .focus: 120, .screen: 150, .tap: 120, .app: 60, .step: 160]
    private static let lock = NSLock()
    private static var used: [Kind: Int] = [:]
    private static var capped = Set<Kind>()

    /// Writes one trail line, unless its kind has used up its lines for this run.
    static func write(_ kind: Kind, _ message: String) {
        guard enabled else { return }
        lock.lock()
        let count = used[kind, default: 0], cap = caps[kind] ?? 100
        if count >= cap {
            let first = capped.insert(kind).inserted
            lock.unlock()
            if first { LogStore.shared.log("[log-trail] no more [\(kind.rawValue)] lines this run (\(cap) written; the log stays small)") }
            return
        }
        used[kind] = count + 1
        lock.unlock()
        LogStore.shared.log(message)
    }

    // MARK: Start

    private static var installed = false
    /// From the app's first appearance (MadeiraApp), on the main thread.
    @MainActor static func install() {
        guard enabled, !installed else { return }
        installed = true
        let device = UIDevice.current
        LogRuns.device = "\(device.model) \(device.systemName) \(device.systemVersion)"
        LogRuns.writeHeader()
        reportLastRun()
        let center = NotificationCenter.default
        center.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { note in
            let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            MainActor.assumeIsolated { focusMoved(context) }
        }
        center.addObserver(forName: UIFocusSystem.movementDidFailNotification, object: nil, queue: .main) { note in
            let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            let heading = context.map { headingName($0.focusHeading) } ?? "?"
            MainActor.assumeIsolated {
                write(.focus, "[focus] system focus could not move \(heading) from \(describe(context?.previouslyFocusedItem)) on \(screen)")
            }
        }
        let lifecycle: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "inactive (Control Center, a notification, the app switcher or a lock)"),
            (UIApplication.didEnterBackgroundNotification, "in the background"),
            (UIApplication.willEnterForegroundNotification, "back in the foreground"),
            (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.willTerminateNotification, "closing (iOS asked it to end)"),
        ]
        for (name, words) in lifecycle {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { appState(name, words) }
            }
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            lock.lock(); warnings += 1; let n = warnings; lock.unlock()
            write(.app, "[app] iOS memory warning #\(n): \(Memory.footprintMB) MB in use, \(Memory.availableMB) MB left before iOS ends Madeira" + during())
        }
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
            let pad = note.object as? GCController
            write(.pad, "[pad] controller connected: \(pad?.vendorName ?? "?") (\(pad?.productCategory ?? "?"))")
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { note in
            let pad = note.object as? GCController
            write(.pad, "[pad] controller disconnected: \(pad?.vendorName ?? "?")" + during())
        }
        watchWindow()
        // What is on top (alerts, sheets): looked at twice a second, logged when it changes.
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { checkOnTop() } }
        RunLoop.main.add(timer, forMode: .common)
        LogStore.shared.log("[log-trail] on: [pad] [focus] [screen] [tap] [app] [step] [game-start] [game-end] lines (env.MADEIRA_LOG_TRAIL = 0 turns them off)")
    }

    @MainActor private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
    }

    @MainActor private static var watchedWindow: UIWindow?
    /// The tap watch goes on the key window; tried again when Madeira becomes active.
    @MainActor private static func watchWindow() {
        guard let window = keyWindow, window !== watchedWindow else { return }
        watchedWindow = window
        window.addGestureRecognizer(LogTrailTapWatch(target: nil, action: nil))
    }

    @MainActor private static func appState(_ name: Notification.Name, _ words: String) {
        if name == UIApplication.didBecomeActiveNotification { watchWindow() }
        if name == UIApplication.didEnterBackgroundNotification { session.note(background: Date()) }
        if name == UIApplication.willEnterForegroundNotification { session.note(background: nil) }
        write(.app, "[app] Madeira is \(words)" + (session.title.map { " (\($0) running)" } ?? ""))
    }

    // MARK: Focus

    @MainActor private static func focusMoved(_ context: UIFocusUpdateContext?) {
        guard let context else { return }
        write(.focus, "[focus] system focus -> \(describe(context.nextFocusedItem)) (from \(describe(context.previouslyFocusedItem)), "
              + "\(headingName(context.focusHeading))) on \(screen)")
    }

    static func headingName(_ heading: UIFocusHeading) -> String {
        var parts: [String] = []
        if heading.contains(.up) { parts.append("up") }
        if heading.contains(.down) { parts.append("down") }
        if heading.contains(.left) { parts.append("left") }
        if heading.contains(.right) { parts.append("right") }
        if heading.contains(.next) { parts.append("next") }
        if heading.contains(.previous) { parts.append("previous") }
        return parts.isEmpty ? "no direction" : parts.joined(separator: "+")
    }

    /// "UIButton \"Play\" at 120,400 70x44 in PresentationHostingController": the item's type, the
    /// nearest label, where it is in the window and the page that holds it.
    @MainActor static func describe(_ item: UIFocusItem?) -> String {
        guard let item else { return "nothing" }
        var text = shortType(item)
        let view = item as? UIView
        if let label = label(of: item as? NSObject, view: view) { text += " \"\(label)\"" }
        if let view, let window = view.window {
            let r = view.convert(view.bounds, to: window)
            text += " at \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
        } else {
            let r = item.frame
            text += " frame \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
        }
        if let page = owner(of: view) { text += " in \(page)" }
        return text
    }

    /// The first accessibility label on the item or the views around it (UIKit's, at no cost:
    /// SwiftUI's own accessibility tree is never asked for, so it is never built).
    @MainActor static func label(of object: NSObject?, view: UIView?) -> String? {
        if let own = object?.accessibilityLabel, !own.isEmpty { return clip(own) }
        var next = view?.superview, hops = 0
        while let current = next, hops < 6 {
            if let found = current.accessibilityLabel, !found.isEmpty { return clip(found) }
            next = current.superview; hops += 1
        }
        return nil
    }

    /// The view controller a view is in, by its short type name.
    @MainActor static func owner(of view: UIView?) -> String? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController { return controllerName(controller) }
            responder = current.next
        }
        return nil
    }

    static func shortType(_ value: Any) -> String {
        let name = String(describing: type(of: value))
        return String(name.prefix { $0 != "<" })
    }

    static func clip(_ text: String, _ length: Int = 48) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > length ? String(flat.prefix(length)) + "…" : flat
    }

    // MARK: Screens

    /// Named pages and sheets that are open (logScreen), the newest last.
    @MainActor private static var screens: [String] = []
    /// The page in front: the newest named one, else the library.
    @MainActor static var screen: String { screens.last ?? (session.title != nil ? "the game" : "the library") }

    @MainActor static func opened(_ name: String) {
        screens.append(name)
        write(.screen, "[screen] open \(name)")
    }
    @MainActor static func closed(_ name: String) {
        if let index = screens.lastIndex(of: name) { screens.remove(at: index) }
        write(.screen, "[screen] close \(name) (now \(screen))")
    }

    @MainActor private static var lastOnTop = ""
    /// Alerts and sheets over the app's root, as one line when the set changes.
    @MainActor private static func checkOnTop() {
        guard let root = keyWindow?.rootViewController else { return }
        var chain: [String] = []
        var next = root.presentedViewController
        while let controller = next, chain.count < 6 {
            chain.append(controllerName(controller))
            next = controller.presentedViewController
        }
        let text = chain.joined(separator: " > ")
        guard text != lastOnTop else { return }
        let was = lastOnTop
        lastOnTop = text
        if text.isEmpty { write(.screen, "[screen] on top: nothing now (was \(was))") }
        else { write(.screen, "[screen] on top: \(text)") }
    }

    /// A view controller in words: an alert with its title, message and buttons; a SwiftUI sheet
    /// as "sheet"; anything else by its type.
    @MainActor static func controllerName(_ controller: UIViewController) -> String {
        if let alert = controller as? UIAlertController {
            var text = alert.preferredStyle == .actionSheet ? "menu" : "alert"
            if let title = alert.title, !title.isEmpty { text += " \"\(clip(title, 60))\"" }
            if let message = alert.message, !message.isEmpty { text += " \"\(clip(message, 90))\"" }
            let buttons = alert.actions.compactMap(\.title)
            if !buttons.isEmpty { text += " [\(buttons.joined(separator: " | "))]" }
            return text
        }
        let type = shortType(controller)
        if type.contains("HostingController") { return type.hasPrefix("Presentation") ? "sheet" : "page" }
        if controller is UIActivityViewController { return "share sheet" }
        if controller is UIDocumentPickerViewController { return "file picker" }
        return type
    }

    // MARK: Taps

    @MainActor static func tapped(at point: CGPoint, in window: UIWindow) {
        guard session.title == nil || session.inMenu else { return }   // a game's own touches are not menus
        let hit = window.hitTest(point, with: nil)
        var text = "[tap]"
        if let label = label(of: hit, view: hit) { text += " \"\(label)\"" }
        if let hit { text += " " + shortType(hit) }
        let size = window.bounds.size
        text += " at \(Int(point.x)),\(Int(point.y))"
        if size.width > 0, size.height > 0 {
            text += " (\(Int(point.x / size.width * 100))%,\(Int(point.y / size.height * 100))%)"
        }
        text += " on \(screen)"
        if !lastOnTop.isEmpty { text += ", over \(lastOnTop)" }
        write(.tap, text)
    }

    // MARK: Controller

    /// The ring's place now, for a press's before and after.
    @MainActor static var ring: String {
        if PadHighlight.enabled {
            let pad = PadHighlight.shared
            guard let focus = pad.focus else { return pad.shown ? "on nothing" : "hidden" }
            return (pad.shown ? focus : "hidden (was \(focus))") + (pad.layerName == PadLayer.root ? "" : " in \(pad.layerName)")
        }
        let pad = MenuPad.shared
        guard let focus = pad.focus else { return pad.ring ? "on nothing" : "hidden" }
        return pad.ring ? focus : "hidden (was \(focus))"
    }

    static let buttonNames: [String: String] = [
        "up": "up", "down": "down", "left": "left", "right": "right", "accept": "A", "back": "B", "add": "Y", "play": "X",
        "menu": "Menu", "search": "View", "previous": "L1", "next": "R1", "pageUp": "L2", "pageDown": "R2",
    ]

    /// A press that became a command (LibraryController): logged after the command ran, with the
    /// ring before and after it.
    @MainActor static func pressed(_ command: String, ownsMenus: Bool, before: String) {
        guard enabled else { return }
        let button = ownsMenus ? (buttonNames[command] ?? command) : "View+Menu"
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let after = ring
                let moved = after == before ? "ring \(before)" : "ring \(before) -> \(after)"
                let sheets = MenuPad.shared.sheets
                write(.pad, "[pad] \(button) (\(command)): \(moved) on \(screen)" + (sheets > 0 ? ", \(sheets) sheet(s) open" : ""))
            }
        }
    }

    /// Buttons that are no command in the menus (X, the stick clicks), so a press that did
    /// nothing still shows.
    static func pressedUnused(_ pressed: UInt32) {
        let names: [(UInt32, String)] = [(0x4000, "X"), (0x40, "L3"), (0x80, "R3")]
        for (mask, name) in names where pressed & mask != 0 {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { write(.pad, "[pad] \(name): no menu command on \(screen)") }
            }
        }
    }

    // MARK: A game's start and end

    /// One game from Play to Wine's end. The steps are also kept in a small file, so a run
    /// that ends in a crash still has them at the next start ([last-run]).
    final class Session {
        var title: String?
        /// (get-help) The game's Windows path: its own config, for Get Help's offer.
        var windowsPath: String?
        var started = Date()
        var steps: [(String, Double)] = []
        var reason: String?
        var exitDetail: String?
        var lastError: String?
        var crash: String?
        var dockResult: String?
        var inMenu = false
        var backAt: Date?
        var background: Date?
        var warningsAtStart = 0
        /// The session itself began (LibraryModel.begin), not only Play: only then is a run
        /// that ends early a game that was running.
        var began = false

        func note(background date: Date?) { LogTrail.lock.lock(); background = date; LogTrail.lock.unlock(); saveMarker() }

        /// Documents/madeira-trail-open.txt while a game runs.
        static var markerURL: URL? {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("madeira-trail-open.txt")
        }
        func stepsLine() -> String {
            steps.map { "\($0.0) \(String(format: "%.1f", $0.1))" }.joined(separator: " · ")
        }
        func saveMarker() {
            LogTrail.lock.lock()
            guard let title, began, backAt == nil else { LogTrail.lock.unlock(); return }
            var lines = ["game=\(title)", "started=\(LogTrail.clock(started))", "steps=\(stepsLine())"]
            if let windowsPath { lines.append("path=\(windowsPath)") }
            if let background { lines.append("background=\(LogTrail.clock(background))") }
            if let lastError { lines.append("last-error=\(lastError)") }
            LogTrail.lock.unlock()
            guard let url = Self.markerURL else { return }
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        static func clearMarker() { if let url = markerURL { try? FileManager.default.removeItem(at: url) } }
    }
    static let session = Session()
    /// (log-fixes) Whether `title` is still running (its Wine not finished): Get Help's upload
    /// waits for the end of the run before it sends the logs.
    static func isRunning(_ title: String) -> Bool { lock.lock(); defer { lock.unlock() }; return session.title == title }
    private static var warnings = 0

    static func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: date)
    }

    /// The last run ended while a game ran: say so, with the steps it got to.
    private static func reportLastRun() {
        guard let url = Session.markerURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        Session.clearMarker()
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        var words = "[last-run] Madeira closed while \(fields["game"] ?? "a game") was running (started \(fields["started"] ?? "?"))"
        words += fields["background"].map { ", in the background since \($0): iOS ended it there, or it was swiped away" }
            ?? ": a crash or iOS ending it for memory (it never got back to the library)"
        if let steps = fields["steps"], !steps.isEmpty { words += "; steps: \(steps)" }
        if let error = fields["last-error"] { words += "; last error: \(error)" }
        LogStore.shared.log(words, level: .error)
        // (get-help) Not after the background: iOS ending it there, or a swipe, is no game problem.
        if fields["background"] == nil, let game = fields["game"] {
            GetHelpCenter.stopped(title: game, windowsPath: fields["path"], why: "Madeira closed while it ran")
        }
        LogRuns.previousRun(String(words.dropFirst("[last-run] ".count)))
    }

    /// Play in the library (ContentView.launchLibraryEntry): the clock starts.
    static func play(_ entry: LibraryEntry) {
        guard enabled else { return }
        lock.lock()
        session.title = entry.title; session.windowsPath = entry.windowsPath; session.started = Date(); session.steps = [("play", 0)]
        session.reason = nil; session.exitDetail = nil; session.lastError = nil; session.crash = nil
        session.dockResult = nil; session.inMenu = false; session.backAt = nil; session.background = nil
        session.warningsAtStart = warnings; session.began = false
        lock.unlock()
        var store = "a game you added"
        if let id = entry.steamAppID { store = "Steam \(id)" }
        else if let id = entry.epicAppName { store = "Epic \(id)" }
        else if let id = entry.gogProductID { store = "GOG \(id)" }
        else if let id = entry.itchGameID { store = "itch \(id)" }
        else if let id = entry.eaOfferID { store = "EA \(id)" }
        write(.step, "[step] \(entry.title): play (\(store), \(entry.windowsPath))")
        LogRuns.start(title: entry.title, store: store, windowsPath: entry.windowsPath)
    }

    /// The session begins (LibraryModel.begin): the state it starts in.
    static func began(_ entry: LibraryEntry, dock: Bool) {
        guard enabled else { return }
        lock.lock()
        // A start that did not come through Play (a Dock start, a shortcut's held game) starts the clock here.
        let fresh = session.title != entry.title || Date().timeIntervalSince(session.started) > 180
        if fresh {
            session.title = entry.title; session.windowsPath = entry.windowsPath; session.started = Date(); session.steps = []
            session.reason = nil; session.exitDetail = nil; session.lastError = nil; session.crash = nil
            session.dockResult = nil; session.backAt = nil; session.background = nil
            session.warningsAtStart = warnings
        }
        session.inMenu = false; session.began = true
        lock.unlock()
        if !LogRuns.began(title: entry.title) {   // a start without Play: its run starts here
            LogRuns.start(title: entry.title, store: dock ? "Madeira Dock" : "", windowsPath: entry.windowsPath)
            LogRuns.began(title: entry.title)
        }
        step("session")
        let config = GameProfile(windowsPath: entry.windowsPath).values
        let configWords = config.isEmpty ? "no game config" : "game config \(config.count) line(s): "
            + config.keys.sorted().prefix(12).joined(separator: ", ")
        let pads = GCController.controllers().map { $0.vendorName ?? "?" }
        let process = ProcessInfo.processInfo
        let jit = SigningStatus.current.debugged ? "on" : "off"
        LogStore.shared.log("[game-start] \(entry.title)\(dock ? " (Madeira Dock)" : ""): \(configWords) | "
            + "memory \(Memory.footprintMB) MB in use, \(Memory.availableMB) MB left | JIT \(jit) | "
            + "thermal \(DeviceLoadDiagnostics.thermalName(process.thermalState)), low power \(process.isLowPowerModeEnabled ? 1 : 0) | "
            + "controller \(pads.isEmpty ? "none" : pads.joined(separator: ", ")), touch controls \(entry.touchControls ? "on" : "off") | "
            + "resolution \(entry.resolution), fps mode \(entry.fpsMode)")
    }

    /// One start or quit step, in seconds since Play.
    static func step(_ name: String, at date: Date = Date()) {
        guard enabled else { return }
        lock.lock()
        guard let title = session.title else { lock.unlock(); return }
        let seconds = max(0, date.timeIntervalSince(session.started))
        if session.steps.count >= 40 || session.steps.contains(where: { $0.0 == name }) { lock.unlock(); return }
        session.steps.append((name, seconds))
        lock.unlock()
        write(.step, "[step] \(title) +\(String(format: "%.2f", seconds))s \(name)")
        session.saveMarker()
        LogRuns.stepped(name, seconds: seconds)
    }

    /// Why the game is ending, when Madeira knows (Quit game, Stop, a failed start).
    static func ending(_ reason: String) {
        lock.lock()
        let first = session.reason == nil
        if first { session.reason = reason }
        lock.unlock()
        if first { step("asked to end") }
    }

    /// The in-game menu opened or closed: taps there are menus again.
    static func inGameMenu(_ open: Bool) { lock.lock(); session.inMenu = open; lock.unlock() }

    /// Back in the library (LibraryModel.finish). The end line waits for Wine to finish, at
    /// most 90 s, so it can carry the exit code.
    @MainActor static func backInLibrary() {
        guard enabled else { return }
        lock.lock()
        guard session.title != nil, session.backAt == nil else { lock.unlock(); return }
        session.backAt = Date()
        lock.unlock()
        Session.clearMarker()   // back in the library: whatever happens next is no crash in a game
        step("library")
        let since = Date()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            let done = wine_process_is_running() == 0 && wineserver_is_running() == 0
            guard done || Date().timeIntervalSince(since) > 90 else { return }
            timer.invalidate()
            if done { step("wine ended") }
            finished(wineDone: done)
        }
    }

    private static func finished(wineDone: Bool) {
        lock.lock()
        guard let title = session.title else { lock.unlock(); return }
        let reason = session.reason, crash = session.crash, dock = session.dockResult, error = session.lastError
        let steps = session.stepsLine(), total = Date().timeIntervalSince(session.started)
        let newWarnings = warnings - session.warningsAtStart
        let shown = session.steps.first { $0.0.hasPrefix("game shown") || $0.0 == "Steam screen ended (game-window)" }
        let windowsPath = session.windowsPath
        session.title = nil; session.inMenu = false
        lock.unlock()
        Session.clearMarker()
        var why: String
        if let reason { why = reason }
        else if shown == nil { why = "it stopped before its window showed" }
        else { why = "it closed by itself" }
        var code = "exit code not reported"
        var status: UInt32 = 0
        if wine_crash_exit_status(&status) != 0 { code = String(format: "Windows error 0x%08X", status) }
        else if wine_launched_exit_code(&status) != 0 { code = "exit code \(status)" + (status == 0 ? " (normal)" : "") }
        var line = "[game-end] \(title): \(why); \(code)"
        if let dock { line += "; Madeira Dock result \(dock)" }
        if let crash { line += "; Wine: \(crash)" }
        if !wineDone { line += "; Wine still running 90 s after the library came back" }
        let pool = JITPoolMeter.current
        line += " | memory \(Memory.footprintMB) MB now, peak \(Memory.peakMB) MB, \(newWarnings) iOS memory warning(s)"
        if let mb = pool.sizeMB { line += " | JIT pool \(mb) MB, \(pool.used >> 20) MB used" + (pool.exhausted > 0 ? ", ran out \(pool.exhausted)x" : "") }
        line += " | \(String(format: "%.0f", total)) s in all: \(steps)"
        if let error { line += " | last error: \(error)" }
        LogStore.shared.log(line, level: why == "it closed by itself" && code.hasPrefix("exit code 0") ? .info : .error)
        // (get-help) The game stopped by itself: a Windows error, an exit code other than 0, or no
        // window at all. Not when the player quit or stopped it (reason).
        if reason == nil, code.hasPrefix("Windows error") || (code.hasPrefix("exit code ") && !code.hasPrefix("exit code 0"))
            || why == "it stopped before its window showed" {
            GetHelpCenter.stopped(title: title, windowsPath: windowsPath, why: "\(why); \(code)")
        }
        // (fix-check) A run since Get Help's Apply: ask whether the fix worked (GetHelpView.swift).
        let stoppedByItself = reason == nil && (code.hasPrefix("Windows error") || (code.hasPrefix("exit code ") && !code.hasPrefix("exit code 0"))
            || why == "it stopped before its window showed")
        GetHelpCenter.gameFinished(windowsPath: windowsPath, started: Date().addingTimeInterval(-total), seconds: total,
                                   ended: stoppedByItself ? "crash" : (reason != nil ? "quit" : "normal"))
        LogRuns.ended(why + ", " + code + (dock.map { ", Madeira Dock result \($0)" } ?? "") + (crash.map { ", Wine: \($0)" } ?? ""), seconds: total)
    }

    // MARK: Reading the log

    /// Every line of madeira-log.txt passes here (LogTail, a background queue): Wine's and the
    /// app's start lines become steps. One `contains` per pattern, only while a game runs.
    static func see(_ line: String) {
        guard enabled else { return }
        lock.lock(); let running = session.title != nil; lock.unlock()
        guard running else { return }
        // The trail's own lines quote the patterns below.
        if line.contains("[step] ") || line.contains("[game-") || line.contains("[log-trail]") || line.contains("[last-run]") { return }
        if let r = line.range(of: "] [ERR] ") {
            let text = clip(String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces), 160)
            lock.lock(); session.lastError = text; lock.unlock()
        }
        if let r = line.range(of: "wine: Unhandled ") {
            lock.lock(); if session.crash == nil { session.crash = clip("Unhandled " + line[r.upperBound...], 140) }; lock.unlock()
        }
        if let r = line.range(of: "[dock-status] host-ended result=") {
            let result = String(line[r.upperBound...].prefix { $0 != " " })
            lock.lock(); session.dockResult = result; lock.unlock()
        }
        for (pattern, name) in steps where line.contains(pattern) {
            var label = name
            if name.hasSuffix("(") {   // the reason follows "reason=" in the line
                let reason = line.range(of: "reason=").map { String(line[$0.upperBound...].prefix { $0 != " " }) } ?? "?"
                label = name + reason + ")"
            }
            step(label, at: time(of: line) ?? Date())
        }
    }

    /// Lines that mark a step (the code that writes them: tests/host/check-log-trail.py).
    static let steps: [(String, String)] = [
        ("[jit-on-play] JIT is on", "JIT on"),
        ("[madeira-dock] starting the host", "Dock host"),
        ("Running full Wine sequence", "Wine sequence"),
        ("JIT pool ready", "JIT pool ready"),
        ("JIT pool allocation FAILED", "JIT pool FAILED"),
        ("[launch] wineserver ready", "wineserver ready"),
        ("Wine process thread launched", "Wine started"),
        ("[launch-view] dismissed reason=", "game shown ("),
        ("[steam-launch-view] end reason=", "Steam screen ended ("),
        ("[frontend] graceful close requested", "close asked (Alt+F4)"),
        ("[dock-status] host-ended", "Dock ended"),
        ("Wine finished after", "Wine finished"),
    ]

    /// "[00:10:48.331] ..." as a date today (yesterday, for a line from before midnight).
    static func time(of line: String) -> Date? {
        guard line.hasPrefix("["), line.count > 13 else { return nil }
        let t = line.dropFirst().prefix(12)
        let parts = t.split(whereSeparator: { $0 == ":" || $0 == "." }).compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        let now = Date()
        var c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        c.hour = parts[0]; c.minute = parts[1]; c.second = parts[2]; c.nanosecond = parts[3] * 1_000_000
        guard var date = Calendar.current.date(from: c) else { return nil }
        if date.timeIntervalSince(now) > 3600 { date.addTimeInterval(-86400) }
        return date
    }

    // MARK: Context for errors

    /// " (during: Stardew Valley, after JIT pool ready +4.3 s)", or the screen in the library.
    static func during() -> String {
        lock.lock(); defer { lock.unlock() }
        if let title = session.title {
            if let last = session.steps.last {
                return " (during: \(title), after \(last.0) +\(String(format: "%.1f", last.1)) s)"
            }
            return " (during: \(title))"
        }
        return ""
    }
}

/// Memory as iOS counts it for Madeira.
enum Memory {
    static var footprintMB: Int { Int(vmInfo()?.phys_footprint ?? 0) >> 20 }
    static var peakMB: Int { Int(vmInfo()?.ledger_phys_footprint_peak ?? 0) >> 20 }
    static var availableMB: Int { Int(os_proc_available_memory()) >> 20 }
    private static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
    }
}

/// Sees each tap on the window and never takes it: taps, scrolls and buttons work as before.
final class LogTrailTapWatch: UIGestureRecognizer {
    private var start: CGPoint?
    private var startTime = Date()
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first, let view else { state = .failed; return }
        start = touch.location(in: view); startTime = Date()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start, let touch = touches.first, let view else { return }
        let p = touch.location(in: view)
        if abs(p.x - start.x) > 12 || abs(p.y - start.y) > 12 { state = .failed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let start, let window = view as? UIWindow, Date().timeIntervalSince(startTime) < 1 {
            MainActor.assumeIsolated { LogTrail.tapped(at: start, in: window) }
        }
        state = .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func reset() { super.reset(); start = nil }
}

/// A named page or sheet for the log ([screen] open / close).
struct LogScreen: ViewModifier {
    let name: String
    func body(content: Content) -> some View {
        content
            .onAppear { LogTrail.opened(name) }
            .onDisappear { LogTrail.closed(name) }
    }
}

extension View {
    /// Names this page or sheet in the log: "[screen] open game page: Stardew Valley".
    func logScreen(_ name: String) -> some View { modifier(LogScreen(name: name)) }
}

// madeira-log-summary: the top of madeira-log.txt says what happened, before the full log.
//
// A fixed-size block (LogRuns.headerBytes) is the first thing in the file: the build, the
// device, madeira.cfg, and one line per game run (game, how long it ran, how it ended), each
// with the game's own config. It is rewritten in place as games start, step and end; Wine and
// the app keep appending below it (O_APPEND), so nothing else in the file moves. The block has
// no [tag] lines, so nothing that reads the log mistakes it for a log line.
//
// LogRuns.lastRunText(game:) is one game's last run, cut from the log for Get Help: the block,
// then that run's Madeira lines, Wine's error lines and the run's last lines. Each run is
// marked in the log by [run-start] #N <game> and [run-end] #N.
enum LogRuns {
    static let enabled = LogTrail.enabled && MadeiraConfig.flag("MADEIRA_LOG_SUMMARY")
    static let headerBytes = 4096
    static let firstLine = "=== Madeira log summary: what happened, then the full log below ==="
    static let lastLine = "=== end of summary ==="

    struct Run {
        var number: Int
        var title: String
        var store: String
        var config: String
        /// (debug-logging) "Debug logging Medium · game config 3fa81c2e (14 lines)", test bundle with a level only.
        var debug: String?
        var started: Date
        var began = false
        var lastStep: String?
        var ended: String?
        var seconds: Double?
    }
    private static let lock = NSLock()
    private static var runs: [Run] = []
    private static var previous: String?
    private static var count = 0
    private static let started = Date()
    /// "iPad iPadOS 27.0.1", set on the main thread at the app's first appearance (LogTrail.install).
    static var device = "device not read yet"

    /// "pool = 896; env.DOTNET_X = 0" from the game's own config file, or "none".
    static func configText(_ windowsPath: String) -> String {
        let values = GameProfile(windowsPath: windowsPath).values
        return values.isEmpty ? "none" : values.keys.sorted().map { "\($0) = \(values[$0] ?? "")" }.joined(separator: "; ")
    }

    /// A run starts (Play, or a session that began without Play). Returns its number.
    static func start(title: String, store: String, windowsPath: String) {
        guard enabled else { return }
        let config = configText(windowsPath)
        lock.lock()
        // A Play that never began a session (held for a restart, an error before the start).
        if let last = runs.indices.last, runs[last].ended == nil, !runs[last].began {
            runs[last].ended = "did not start (held, or stopped before the session)"
        }
        count += 1
        let number = count
        let debug = DebugLogging.stamp(windowsPath: windowsPath)
        runs.append(Run(number: number, title: title, store: store, config: config, debug: debug, started: Date()))
        lock.unlock()
        LogStore.shared.log("[run-start] #\(number) \(title)")
        if let debug { LogStore.shared.log("[debug-log] #\(number) \(debug)") }
        writeHeader()
    }

    /// The session itself began for the newest run of `title`; true when there was one.
    @discardableResult static func began(title: String) -> Bool {
        guard enabled else { return false }
        lock.lock()
        guard let i = runs.lastIndex(where: { $0.title == title && $0.ended == nil }) else { lock.unlock(); return false }
        runs[i].began = true
        lock.unlock()
        writeHeader()
        return true
    }

    static func stepped(_ name: String, seconds: Double) {
        guard enabled else { return }
        lock.lock()
        guard let i = runs.indices.last, runs[i].ended == nil else { lock.unlock(); return }
        runs[i].lastStep = "\(name) +\(String(format: "%.1f", seconds)) s"
        lock.unlock()
        writeHeader()
    }

    static func ended(_ words: String, seconds: Double) {
        guard enabled else { return }
        lock.lock()
        guard let i = runs.indices.last, runs[i].ended == nil else { lock.unlock(); return }
        runs[i].ended = words; runs[i].seconds = seconds
        let number = runs[i].number
        lock.unlock()
        LogStore.shared.log("[run-end] #\(number)")
        writeHeader()
    }

    /// The previous app run ended in a game ([last-run]).
    static func previousRun(_ words: String) {
        guard enabled else { return }
        lock.lock(); previous = words; lock.unlock()
        writeHeader()
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 90 ? "\(Int(seconds.rounded())) s" : seconds < 5400 ? "\(Int((seconds / 60).rounded())) min"
            : String(format: "%.1f h", seconds / 3600)
    }

    /// The block's text, padded to `headerBytes` (the oldest runs leave first when it is full).
    static func headerText() -> String {
        lock.lock()
        let runs = self.runs, previous = self.previous
        lock.unlock()
        let cfg = MadeiraConfig.all().sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "; ")
        var top = [firstLine,
                   "Build: \(BuildStamp.text) · \(device) · Madeira opened \(LogTrail.clock(started))",
                   "madeira.cfg: " + LogTrail.clip(cfg.isEmpty ? "none" : cfg, 600)]
        if let previous { top.append("Previous run: " + LogTrail.clip(previous, 400)) }
        top.append(runs.isEmpty ? "Game runs: none yet" : "Game runs (\(runs.count)):")
        var lines: [String] = []
        for run in runs {
            var line = "  \(run.number). \(run.title)" + (run.store.isEmpty ? "" : " (\(run.store))") + ", started \(LogTrail.clock(run.started)): "
            if let ended = run.ended {
                line += (run.seconds.map { "ran \(duration($0)), " } ?? "") + ended
            } else {
                line += "running" + (run.lastStep.map { ", last step \($0)" } ?? "")
            }
            lines.append(LogTrail.clip(line, 400))
            lines.append("     its config: " + LogTrail.clip(run.config, 400))
            if let debug = run.debug { lines.append("     " + LogTrail.clip(debug, 200)) }
        }
        let end = [lastLine, "(The full log follows.)"]
        func joined(_ body: [String]) -> String { (top + body + end).joined(separator: "\n") + "\n" }
        var body = lines
        while joined(body).utf8.count > headerBytes - 2, body.count >= 2 { body.removeFirst(2) }
        var text = joined(body)
        while text.utf8.count > headerBytes - 2 { text.removeLast(); }
        let pad = headerBytes - 1 - text.utf8.count
        return text + String(repeating: " ", count: max(0, pad)) + "\n"
    }

    private static let fileLock = NSLock()
    /// The block alone, as the log file's first bytes (LogStore.init and clear()).
    static func initialHeader() -> String { enabled ? headerText() : "" }

    /// Rewrites the block in place, only while the file still starts with it (a cleared or
    /// replaced log is left alone, so no log line is ever written over).
    static func writeHeader() {
        guard enabled else { return }
        let text = headerText()
        guard let data = text.data(using: .utf8), data.count == headerBytes else { return }
        let url = LogStore.shared.logURL
        fileLock.lock(); defer { fileLock.unlock() }
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: firstLine.utf8.count),
              String(decoding: head, as: UTF8.self) == firstLine,
              ((try? handle.seekToEnd()) ?? 0) >= UInt64(headerBytes) else { return }
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: data)
    }

    // MARK: One run, for Get Help

    /// One game's last run, small enough to send: the summary block, then from that run's
    /// [run-start] to its [run-end] (or the end of the file): every line Madeira wrote, Wine's
    /// error lines (at most `wineErrors`), and the run's last `tailLines` lines; cut in the
    /// middle past `maxBytes`. `game` nil: the last run of any game. Looks in this run's log,
    /// then the previous app run's, then the last log that had a game. Reads files of tens
    /// of MB: call it off the main thread. nil when no run is found.
    static func lastRunText(game: String? = nil, maxBytes: Int = 200_000, tailLines: Int = 200, wineErrors: Int = 300) -> String? {
        let docs = LogStore.shared.logURL.deletingLastPathComponent()
        for name in ["madeira-log.txt", "madeira-log.prev.txt", LogSummary.gameLogName] {
            if let text = lastRun(in: docs.appendingPathComponent(name), game: game, maxBytes: maxBytes,
                                  tailLines: tailLines, wineErrors: wineErrors) {
                return text
            }
        }
        return nil
    }

    static func lastRun(in url: URL, game: String?, maxBytes: Int, tailLines: Int, wineErrors: Int) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return slice(text.split(separator: "\n", omittingEmptySubsequences: false), game: game,
                     maxBytes: maxBytes, tailLines: tailLines, wineErrors: wineErrors)
    }

    /// The cutting itself, on the log's lines (host-tested in Python: check-log-trail.py mirrors it).
    static func slice(_ lines: [Substring], game: String?, maxBytes: Int, tailLines: Int, wineErrors: Int) -> String? {
        // The summary block: the file's first lines up to its last line.
        var header: [Substring] = []
        if lines.first.map({ $0.hasPrefix(firstLine) }) == true, let end = lines.firstIndex(where: { $0.hasPrefix(lastLine) }) {
            header = Array(lines[...end])
        }
        // The last [run-start] (of `game`).
        var startIndex: Int?, number: String?
        for i in lines.indices.reversed() {
            guard let r = lines[i].range(of: "[run-start] #") else { continue }
            let rest = lines[i][r.upperBound...]
            let n = rest.prefix { $0.isNumber }
            let title = rest.dropFirst(n.count + 1)
            if let game, title.trimmingCharacters(in: .whitespaces) != game { continue }
            startIndex = i; number = String(n); break
        }
        guard let startIndex, let number else { return nil }
        let endMarker = "[run-end] #\(number)"
        var endIndex = lines.count - 1
        for i in startIndex..<lines.count where lines[i].contains(endMarker) { endIndex = i; break }
        let run = lines[startIndex...endIndex]
        let tailStart = max(startIndex, endIndex - tailLines + 1)
        var out: [Substring] = header
        if !header.isEmpty { out.append("") }
        out.append("--- One game run: Madeira's lines, Wine's errors, and its last \(tailLines) lines ---")
        var errors = 0
        for i in run.indices {
            let line = lines[i]
            let madeira = line.hasPrefix("[") && line.dropFirst().prefix(12).filter({ $0 == ":" }).count == 2
            let wineError = line.contains(":err:") || line.contains("wine: ") || line.contains("Unhandled ")
            if i >= tailStart || madeira { out.append(line) }
            else if wineError, errors < wineErrors { out.append(line); errors += 1 }
        }
        var result = out.joined(separator: "\n") + "\n"
        if result.utf8.count > maxBytes {
            let keep = maxBytes / 2
            let head = String(result.prefix(keep))
            let tail = String(result.suffix(keep))
            result = head + "\n--- (cut here: the run's lines were over \(maxBytes / 1000) KB) ---\n" + tail
        }
        return result
    }
}
