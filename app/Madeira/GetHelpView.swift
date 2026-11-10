// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  madeira-get-help: the Get Help screens. The talk with the server and what
//  Apply and Undo write are in GetHelp.swift.
//
//  Where it shows:
//  - Game details: a Get Help row under the pages (the controller's ring reaches it).
//  - The library, after a game stopped by itself ([game-end] with a Windows error,
//    a non-zero exit code or no window), or after Madeira itself closed while a game
//    ran ([last-run]): "<game> stopped. Get Help?" once, which opens the same sheet.
//  - Game details › Advanced: Undo Get Help, while lines Get Help added are there.
//  - (fix-check) After Apply, the next time the player ends that game themselves: "Did the
//    fix work for <game>?" Yes / No / Not Sure, once. No opens Get Help for the next step.
//    The answer, with how long the game ran and how it ended, goes to the server's results
//    log (POST /result: the answer's id, nothing else). A crash sends that without asking,
//    since the "<game> Stopped" offer follows anyway.
//  - (get-help-auto) By itself, a second after a launch error: "Madeira Dock stopped" on the
//    starting screen (which also gets a Get Help button), a Windows error when a game
//    stops, or a start that failed. Closing it over the starting screen goes back to the
//    library. The answer is a walkthrough: one short step per screen, an Apply screen,
//    and a last screen with Play Again and Save copy for Discord (a plain .txt).
//
//  The sheet answers at once: the report is made while the first screen shows,
//  a spinner with words says what is going on, and every failure has plain words,
//  Try Again and Save copy for Discord. The first time it says what is sent and lets
//  the player read it; after that it sends straight away.
//
//  env.MADEIRA_GET_HELP = 0 hides all of it; env.MADEIRA_GET_HELP_OFFER = 0 only
//  the offer after a game stopped and the sheet opening by itself after a launch error. The server's key comes from the build (Info.plist
//  MadeiraGetHelpKey, written by the build like MadeiraBuild); without it the sheet
//  says Get Help isn't set up and offers Save copy for Discord.
//

import SwiftUI
import UIKit

enum GetHelp {
    /// Get Help on a game's page and after a game stopped: sends the scrubbed report to Madeira's help
    /// server and shows its answer, with Apply and Undo for setting lines. 0 hides it.
    static let enabled = MadeiraConfig.flag("MADEIRA_GET_HELP")
    /// The "<game> Stopped. Get Help?" offer in the library after a game stopped by itself or Madeira
    /// closed while it ran. 0 hides only the offer.
    static let offers = MadeiraConfig.flag("MADEIRA_GET_HELP_OFFER")

    /// The key the server asks for, from the build's Info.plist; nil when the build has none.
    static var key: String? {
        guard let key = (Bundle.main.infoDictionary?["MadeiraGetHelpKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              key.count >= 16, !key.hasPrefix("$(") else { return nil }
        return key
    }

    private static let defaults = UserDefaults.standard
    /// A random id for the server's daily limit (it keeps only a salted hash of it).
    static var installID: String {
        if let id = defaults.string(forKey: "get-help-install-id"), id.count == 36 { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "get-help-install-id")
        return id
    }
    /// The player has seen what Get Help sends, and that reports are kept (keep-reports-30:
    /// a new key, so players who agreed to the old "only if ticked" screen see it once more).
    static var consented: Bool {
        get { defaults.bool(forKey: "get-help-consented-2") }
        set { defaults.set(newValue, forKey: "get-help-consented-2") }
    }

    // MARK: The report

    /// The same player's report as Get Help from Claude (HelpReport.swift), scrubbed.
    /// Reads the log, so it runs off the main thread; `game` and `device` are read on
    /// the main thread first (ClaudeHelp.gameText, ClaudeHelp.deviceLine).
    /// `shown` (get-help-auto): what Madeira showed the player (a launch error's words), first.
    /// `title` (game-log-pick): only that game's last run is read; with no run of it in any
    /// log, the report says there is no log (and `foundRun` tells the sheet).
    static func report(game: String?, title: String?, device: String, shown: String? = nil) -> String {
        reportAndRun(game: game, title: title, device: device, shown: shown).text
    }

    static func reportAndRun(game: String?, title: String?, device: String, shown: String? = nil) -> (text: String, foundRun: Bool) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return ("", false) }
        let log = ClaudeHelp.logFor(title: title, in: docs).map(HelpReport.read)
        let cfg = try? String(contentsOf: docs.appendingPathComponent(MadeiraConfig.fileName), encoding: .utf8)
        var text = HelpReport.text(build: BuildStamp.text, device: device, log: log, game: game, cfg: cfg, title: title)
        if let shown, !shown.isEmpty {
            text = "## What Madeira showed the player\n" + PrivacyScrub.text(shown) + "\n\n" + text
        }
        return (GetHelpCore.clip(text), log != nil)
    }

    /// (get-help-files) Where GetHelpFiles finds this game's files: the Dock Steam client, the
    /// game's folder and its last run. Read on the main thread (the library), cheap.
    static func places(for entry: LibraryEntry?, title: String, hasRun: Bool) -> GetHelpFiles.Places {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return GetHelpFiles.Places(
            steamRoot: MadeiraDock.clientRoot,
            gameFolder: entry.flatMap { GetHelpFiles.gameFolder(drive: LibraryModel.drive, relativePath: $0.relativePath) },
            runLog: { docs.flatMap { ClaudeHelp.gameRunLog(title: title, in: $0) } },
            hasRun: hasRun)
    }

    /// (game-log-pick) No log has this game's run: play it first.
    static let noRunMessage = "We couldn't find a log of this game. Play it once until it goes wrong, then tap Get Help again."

    // MARK: The server

    static func send(_ request: GetHelpCore.Request, done: @escaping (GetHelpCore.Outcome, Int) -> Void) -> URLSessionDataTask? {
        guard let key else {
            LogStore.shared.log("[get-help] not set up: this build has no MadeiraGetHelpKey", level: .error)
            done(.failed(L(GetHelpCore.notSetUpMessage)), 0)
            return nil
        }
        let body = GetHelpCore.body(request)
        let started = Date()
        LogStore.shared.log("[get-help] sent: \(request.game) (\(request.reason), \(body.count) bytes, keep \(request.keep_report ? 1 : 0))")
        let task = URLSession.shared.dataTask(with: GetHelpCore.urlRequest("help", key: key, body: body)) { data, response, error in
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if let error = error as? URLError, error.code == .cancelled { return }
            let outcome = GetHelpCore.outcome(data: data, status: (response as? HTTPURLResponse)?.statusCode, error: error)
            switch outcome {
            case .answer(let answer):
                LogStore.shared.log("[get-help] answer: \(answer.kind ?? "?"), confidence \(answer.confidence ?? "?"), "
                                    + "\(answer.steps?.count ?? 0) step(s), \(answer.config?.lines.count ?? 0) setting line(s), \(ms) ms")
            case .failed:
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let code = (try? JSONDecoder().decode(GetHelpCore.Answer.self, from: data ?? Data()))?.error ?? "-"
                LogStore.shared.log("[get-help] failed: HTTP \(status), \(code), \(error.map { String(describing: $0) } ?? "no network error"), \(ms) ms", level: .error)
            }
            DispatchQueue.main.async { done(outcome, ms) }
        }
        task.resume()
        return task
    }

    /// Thumbs up or down; nothing is shown if it fails.
    static func feedback(requestID: String, helped: Bool) {
        guard let key, let body = try? JSONSerialization.data(withJSONObject: ["request_id": requestID, "helped": helped]) else { return }
        URLSession.shared.dataTask(with: GetHelpCore.urlRequest("feedback", key: key, body: body)) { _, _, _ in }.resume()
        LogStore.shared.log("[get-help] feedback: \(helped ? "helped" : "did not help")")
    }

    // MARK: Did the fix work? (fix-check, the server's results log)

    /// An Apply waiting for the next play of that game.
    struct FixCheck: Codable, Equatable, Identifiable {
        var requestID: String
        var title: String
        var windowsPath: String
        var appliedAt: Date
        var id: String { requestID }
    }

    private static let fixChecksKey = "get-help-fix-checks"
    /// Windows path -> the last Apply for that game, waiting for its next play.
    static var fixChecks: [String: FixCheck] {
        get { defaults.data(forKey: fixChecksKey).flatMap { try? JSONDecoder().decode([String: FixCheck].self, from: $0) } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: fixChecksKey) }
    }

    /// After Apply: ask about it after the next play.
    static func watchFix(requestID: String, windowsPath: String, title: String) {
        var all = fixChecks
        all[windowsPath] = FixCheck(requestID: requestID, title: title, windowsPath: windowsPath, appliedAt: Date())
        fixChecks = all
        LogStore.shared.log("[get-help] fix-check: will ask about \(title) after its next play")
    }

    static func stopWatching(_ windowsPath: String) {
        var all = fixChecks
        guard all.removeValue(forKey: windowsPath) != nil else { return }
        fixChecks = all
    }

    // MARK: Works now (a game that had a Get Help report and runs well afterwards)

    /// A game this player sent a Get Help report for, until they answer "Does it work now?" once.
    struct Reported: Codable, Equatable, Identifiable {
        var title: String
        var windowsPath: String
        var at: Date
        var asked: Bool
        var id: String { windowsPath }
    }

    private static let reportedKey = "get-help-reported"
    /// Windows path -> the game's last report from this player.
    static var reported: [String: Reported] {
        get { defaults.data(forKey: reportedKey).flatMap { try? JSONDecoder().decode([String: Reported].self, from: $0) } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: reportedKey) }
    }

    /// A report was sent for this game: ask "Does it work now?" after a good play (once).
    static func noteReport(title: String, windowsPath: String) {
        var all = reported
        all[windowsPath] = Reported(title: title, windowsPath: windowsPath, at: Date(), asked: false)
        reported = all
    }

    /// The question was answered (or its logs sent): stop asking until the next report.
    static func closeReport(_ windowsPath: String) {
        var all = reported
        guard all.removeValue(forKey: windowsPath) != nil else { return }
        reported = all
    }

    /// The game's logs, sent as a run that works, and the question closed when they got there.
    @MainActor static func sendWorks(_ report: Reported, done: @escaping (Bool) -> Void) {
        let entry = LibraryModel.shared.entries.first { $0.windowsPath == report.windowsPath }
        GetHelpUpload.sendWorks(title: report.title, windowsPath: report.windowsPath, gameText: entry.map(ClaudeHelp.gameText)) { ok in
            if ok { closeReport(report.windowsPath) }
            done(ok)
        }
    }

    /// POST /result: worked is the player's Yes / No (nil: Not Sure, or not asked after a crash).
    static func sendResult(_ check: FixCheck, worked: Bool?, seconds: Double, ended: String) {
        stopWatching(check.windowsPath)
        guard let key else { return }
        let body: [String: Any] = ["request_id": check.requestID, "worked": worked.map { $0 as Any } ?? NSNull(),
                                   "ran_seconds": Int(max(0, seconds)), "ended": ended]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        URLSession.shared.dataTask(with: GetHelpCore.urlRequest("result", key: key, body: data)) { _, _, _ in }.resume()
        LogStore.shared.log("[get-help] fix-check: \(check.title): \(worked.map { $0 ? "worked" : "did not work" } ?? "not answered"), ran \(Int(seconds)) s, ended \(ended)")
    }

    // MARK: Apply and Undo

    /// Beside the game's own config: <hash>.get-help.json, what Undo takes out.
    static func recordURL(_ windowsPath: String) -> URL? {
        GameProfile(windowsPath: windowsPath).url?.deletingPathExtension().appendingPathExtension("get-help.json")
    }

    static func record(_ windowsPath: String) -> GetHelpCore.Record? {
        guard let url = recordURL(windowsPath), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GetHelpCore.Record.self, from: data)
    }

    private static func save(_ record: GetHelpCore.Record?, _ windowsPath: String) {
        guard let url = recordURL(windowsPath) else { return }
        if let record, let data = try? JSONEncoder().encode(record) { try? data.write(to: url, options: .atomic) }
        else { try? FileManager.default.removeItem(at: url) }
    }

    enum Applied { case added(Int), already, failed }

    /// Adds the lines to the game's own config and keeps what Undo needs.
    static func apply(_ lines: [GetHelpCore.ConfigLine], windowsPath: String, title: String) -> Applied {
        let file = GameProfile(windowsPath: windowsPath)
        let date = Date().formatted(date: .abbreviated, time: .shortened)
        let before = file.text
        guard let change = GetHelpCore.apply(lines, to: before, date: date) else {
            LogStore.shared.log("[get-help] apply: \(title) already has these setting(s)")
            return .already
        }
        file.text = change.text
        guard file.text == change.text else {
            LogStore.shared.log("[get-help] apply: could not write \(title)'s config", level: .error)
            return .failed
        }
        var record = Self.record(windowsPath) ?? GetHelpCore.Record(game: title, date: date, added: [])
        record.added += change.added
        record.date = date
        save(record, windowsPath)
        let keys = change.added.filter { !$0.hasPrefix("#") }
        LogStore.shared.log("[get-help] applied \(keys.count) line(s) to \(title)'s config: \(keys.joined(separator: "; "))")
        return .added(keys.count)
    }

    /// Takes the lines Get Help added out of the game's config again.
    @discardableResult
    static func undo(windowsPath: String, title: String) -> Bool {
        guard let record = record(windowsPath) else { return false }
        let file = GameProfile(windowsPath: windowsPath)
        let after = GetHelpCore.undo(record.added, from: file.text)
        file.text = after
        save(nil, windowsPath)
        stopWatching(windowsPath)
        LogStore.shared.log("[get-help] undo: took \(record.added.filter { !$0.hasPrefix("#") }.count) line(s) out of \(title)'s config")
        return true
    }
}

/// What the sheet is about: a game, by its Windows path (its config's name).
struct GetHelpTarget: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var windowsPath: String
    /// "crash" after a game stopped by itself or a start failed, "player" from the game's page.
    var reason: String
    /// (get-help-auto) What Madeira showed the player (the starting screen's or the alert's
    /// words): the sheet's red line, and the first part of the report.
    var error: String? = nil
    /// (get-help-auto) Opened over the starting screen: closing it goes back to the library.
    var onStartScreen = false
}

/// The offer after a game stopped by itself, the sheet that opens by itself after a launch
/// error, and Play Again.
@MainActor final class GetHelpCenter: ObservableObject {
    static let shared = GetHelpCenter()
    @Published var offer: GetHelpTarget?
    /// The sheet over the library (LibraryView, GetHelpOffer).
    @Published var open: GetHelpTarget?
    /// (get-help-auto) The sheet over the starting screen (LibraryHUD, GetHelpStartScreen).
    @Published var startOpen: GetHelpTarget?
    /// (get-help-auto) Play Again in the sheet: the library starts this game once it shows.
    @Published var playAgain: UUID?
    /// (get-help-auto) The last game Get Help opened for by itself, so the "<game> Stopped"
    /// offer that follows the same failure ([game-end]) does not ask again.
    private var lastShown: (title: String, at: Date)?
    private func shownJustNow(_ title: String) -> Bool {
        guard let lastShown else { return false }
        return lastShown.title == title && Date().timeIntervalSince(lastShown.at) < 300
    }

    /// From LogTrail: a game ended by itself (`why` says how), or Madeira closed while it ran.
    nonisolated static func stopped(title: String, windowsPath: String?, why: String) {
        guard GetHelp.enabled, GetHelp.offers else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if shared.shownJustNow(title) {
                    LogStore.shared.log("[get-help] offer: \(title) (\(why)): Get Help already opened for this")
                    return
                }
                LogStore.shared.log("[get-help] offer: \(title) (\(why))")
                shared.offer = GetHelpTarget(title: title, windowsPath: windowsPath ?? "", reason: "crash")
            }
        }
    }

    /// (get-help-auto) A launch error: the Dock stopped on the starting screen, a Windows
    /// error, or a start that failed. Get Help opens by itself a second later, with the
    /// error's words; false when it is off (env.MADEIRA_GET_HELP or _OFFER = 0), and the
    /// caller shows its own alert.
    @discardableResult
    nonisolated static func launchError(title: String, windowsPath: String, error: String, onStartScreen: Bool) -> Bool {
        guard GetHelp.enabled, GetHelp.offers else { return false }
        // At once: the "<game> Stopped" offer for the same failure ([game-end]) stays away.
        DispatchQueue.main.async { MainActor.assumeIsolated { shared.lastShown = (title, Date()); shared.offer = nil } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                guard shared.open == nil, shared.startOpen == nil else { return }
                if onStartScreen, !LibraryModel.shared.startingScreen { return }   // the player closed it already
                shared.offer = nil
                LogStore.shared.log("[get-help] auto-open: \(title) (\(LogTrail.clip(error, 120)))\(onStartScreen ? " on the starting screen" : "")")
                let target = GetHelpTarget(title: title, windowsPath: windowsPath, reason: "crash", error: error, onStartScreen: onStartScreen)
                if onStartScreen { shared.startOpen = target } else { shared.open = target }
            }
        }
        return true
    }

    /// (fix-check) "Did the fix work for <game>?", after the player ended a game played
    /// since Apply.
    @Published var fixAsk: FixAsk?
    /// (works-now) "Does <game> work now?" after a good play of a game with a report.
    @Published var worksAsk: GetHelp.Reported?
    struct FixAsk: Identifiable, Equatable {
        var check: GetHelp.FixCheck
        var seconds: Double
        var ended: String
        var id: String { check.requestID }
    }

    /// (fix-check) From LogTrail's [game-end]: a game run that started after an Apply ended.
    /// ended: "crash" (stopped by itself), "quit" (the player ended it) or "normal".
    nonisolated static func gameFinished(windowsPath: String?, started: Date, seconds: Double, ended: String) {
        guard GetHelp.enabled, let windowsPath else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let check = GetHelp.fixChecks[windowsPath], started > check.appliedAt else {
                    // (works-now) A game with an unanswered report ran 3 minutes and ended normally: ask once.
                    if ended != "crash", seconds >= 180, let report = GetHelp.reported[windowsPath], !report.asked, started > report.at {
                        shared.worksAsk = report
                    }
                    return
                }
                if ended == "crash" {
                    GetHelp.sendResult(check, worked: nil, seconds: seconds, ended: ended)   // the "<game> Stopped" offer follows
                } else {
                    shared.fixAsk = FixAsk(check: check, seconds: seconds, ended: ended)
                }
            }
        }
    }

    /// (get-help-auto) The starting screen's Get Help button.
    func openOnStartScreen(_ entry: LibraryEntry, error: String?) {
        lastShown = (entry.title, Date())
        startOpen = GetHelpTarget(title: entry.title, windowsPath: entry.windowsPath, reason: "crash", error: error, onStartScreen: true)
    }
}

/// The library's offer: an alert once the library shows, then the sheet; and Play Again.
struct GetHelpOffer: ViewModifier {
    /// LibraryView.play: Play Again in the sheet starts the game through the usual Play.
    var play: (LibraryEntry) -> Void = { _ in }
    @ObservedObject private var center = GetHelpCenter.shared
    @ObservedObject private var model = LibraryModel.shared
    func body(content: Content) -> some View {
        content
            // On a view of its own, so it does not take the place of the library's other alerts.
            .background {
                Color.clear
                    .alert(String(format: L("%@ Stopped"), center.offer?.title ?? ""),
                           isPresented: Binding(get: { center.offer != nil && model.error == nil && model.current == nil && center.open == nil },
                                                set: { if !$0 { center.offer = nil } })) {
                        Button("Get Help") {
                            center.open = center.offer
                            center.offer = nil
                        }
                        Button("Not Now", role: .cancel) {
                            LogStore.shared.log("[get-help] offer: not now")
                            center.offer = nil
                        }
                    } message: {
                        Text("It closed unexpectedly. Get Help looks at what happened and tells you what to try. It takes a few seconds.")
                    }
            }
            // (fix-check) "Did the fix work?" after the next play since Apply.
            .background {
                Color.clear
                    .alert(String(format: L("Did the fix work for %@?"), center.fixAsk?.check.title ?? ""),
                           isPresented: Binding(get: { center.fixAsk != nil && center.offer == nil && model.error == nil && model.current == nil && center.open == nil },
                                                set: { if !$0 { center.fixAsk = nil } })) {
                        Button("Yes") { answerFix(true) }
                        Button("No") { answerFix(false) }
                        Button("Not Sure", role: .cancel) { answerFix(nil) }
                    } message: {
                        Text("Get Help changed this game's settings last time. Your answer helps us give the next player the right fix.")
                    }
            }
            // (works-now) "Does it work now?": Yes sends that run's logs.
            .background {
                Color.clear
                    .alert(String(format: L("Does %@ work now?"), center.worksAsk?.title ?? ""),
                           isPresented: Binding(get: { center.worksAsk != nil && center.fixAsk == nil && center.offer == nil && model.error == nil && model.current == nil && center.open == nil },
                                                set: { if !$0 { endWorksAsk() } })) {
                        Button("Yes") { answerWorks(true) }
                        Button("No") { answerWorks(false) }
                        Button("Not Sure", role: .cancel) { answerWorks(nil) }
                    } message: {
                        Text("Get Help looked at this game before. If it runs well now, Yes sends its last run's logs, with personal details taken out, so the team can see what fixed it.")
                    }
            }
            .sheet(item: $center.open, onDismiss: startPlayAgain) { target in
                GetHelpSheet(target: target)
                    .modifier(ClaimGamepadEvents())
                    .logScreen("get help: \(target.title)")
            }
            // (get-help-auto) Play Again from the starting screen's sheet or the game page's: the
            // library shows again (the session ended), then the game starts.
            .onAppear(perform: startPlayAgain)
            .onChange(of: center.playAgain) { _, _ in if center.open == nil { startPlayAgain() } }
    }

    /// (fix-check) Yes / No / Not Sure. No opens Get Help again for the next step.
    private func answerFix(_ worked: Bool?) {
        guard let ask = center.fixAsk else { return }
        center.fixAsk = nil
        GetHelp.sendResult(ask.check, worked: worked, seconds: ask.seconds, ended: ask.ended)
        if worked == false {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    center.open = GetHelpTarget(title: ask.check.title, windowsPath: ask.check.windowsPath, reason: "player")
                }
            }
        }
    }

    /// (works-now) Yes sends the logs; No opens Get Help again; Not Sure just ends the question.
    private func answerWorks(_ worked: Bool?) {
        guard let ask = center.worksAsk else { return }
        center.worksAsk = nil
        if worked == true {
            GetHelp.sendWorks(ask) { _ in }
        } else {
            var all = GetHelp.reported
            all[ask.windowsPath]?.asked = true
            GetHelp.reported = all
        }
        if worked == false {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    center.open = GetHelpTarget(title: ask.title, windowsPath: ask.windowsPath, reason: "player")
                }
            }
        }
    }

    /// The alert went away some other way: counts as asked, so it does not come back.
    private func endWorksAsk() {
        guard let ask = center.worksAsk else { return }
        center.worksAsk = nil
        var all = GetHelp.reported
        all[ask.windowsPath]?.asked = true
        GetHelp.reported = all
    }

    private func startPlayAgain() {
        guard let id = center.playAgain else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                guard center.playAgain == id, model.current == nil, center.open == nil else { return }
                center.playAgain = nil
                guard let entry = model.entries.first(where: { $0.id == id }) else { return }
                LogStore.shared.log("[get-help] play again: \(entry.title)")
                play(entry)
            }
        }
    }
}

/// (get-help-auto) The starting screen's sheet (LibraryHUD): it opens by itself a second after
/// "Madeira Dock stopped", or from the screen's Get Help button. Closing it closes the
/// starting screen too, back to the library, so the player never hunts for Stop.
struct GetHelpStartScreen: ViewModifier {
    @ObservedObject private var center = GetHelpCenter.shared
    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var dockStart = DockStartScreen.shared
    func body(content: Content) -> some View {
        content
            .sheet(item: $center.startOpen, onDismiss: closed) { target in
                GetHelpSheet(target: target)
                    .modifier(ClaimGamepadEvents())
                    .logScreen("get help: \(target.title)")
            }
            .onChange(of: dockStart.failure) { _, failure in
                guard let failure, let entry = model.startingEntry else { return }
                GetHelpCenter.launchError(title: entry.title, windowsPath: entry.windowsPath, error: failure, onStartScreen: true)
            }
    }

    private func closed() {
        guard model.current != nil, model.startingScreen else { return }
        LogStore.shared.log("[get-help] closed on the starting screen: back to the library")
        model.stopStartToLibrary()
    }
}

/// Game details: the Get Help row. LibraryDetail presents the sheet (getHelpSheet).
struct GetHelpRow: View {
    var open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Label { Text("Get Help").foregroundStyle(.primary) } icon: { Image(systemName: "lifepreserver").foregroundStyle(Color.accentColor) }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
    }
}

extension View {
    /// The Get Help sheet for one game (Game details); `closed` runs when it goes away.
    func getHelpSheet(_ open: Binding<Bool>, entry: LibraryEntry, closed: @escaping () -> Void) -> some View {
        sheet(isPresented: open, onDismiss: closed) {
            GetHelpSheet(target: GetHelpTarget(title: entry.title, windowsPath: entry.windowsPath, reason: "player"))
                .modifier(ClaimGamepadEvents())
                // The new look: the sheet takes the controller itself (B closes, A its main button).
                .padLayer("get-help", back: nil)
                .logScreen("get help: \(entry.title)")
        }
    }
}

/// Game details › Advanced: Undo Get Help, while its lines are in the game's config.
struct GetHelpUndoSection: View {
    let windowsPath: String
    let title: String
    var undone: () -> Void
    /// Bumped by Undo, so the section reads the record again and goes.
    @State private var undoCount = 0
    var body: some View {
        let _ = undoCount
        if let record = GetHelp.record(windowsPath) {
            Section {
                Button("Undo Get Help", systemImage: "arrow.uturn.backward") {
                    GetHelp.undo(windowsPath: windowsPath, title: title)
                    undoCount += 1
                    undone()
                }
            } footer: {
                Text(String(format: L("Takes out the settings Get Help added to this game on %@."), record.date))
            }
        }
    }
}

/// (works-now) Game details › Advanced: for a game that had a problem and runs well now. Sends its last
/// run's scrubbed logs to the Madeira team (POST /works), so what fixed it can be seen next to the old reports.
struct GetHelpWorksSection: View {
    let entry: LibraryEntry
    /// 0 ready, 1 sending, 2 sent, 3 failed (tap again to retry).
    @State private var state = 0
    var body: some View {
        Section {
            Button {
                state = 1
                GetHelpUpload.sendWorks(title: entry.title, windowsPath: entry.windowsPath,
                                        gameText: ClaudeHelp.gameText(entry)) { ok in
                                            if ok { GetHelp.closeReport(entry.windowsPath) }
                                            state = ok ? 2 : 3
                                        }
            } label: {
                switch state {
                case 1: Label("Sending…", systemImage: "arrow.up.circle")
                case 2: Label("Sent. Thank you!", systemImage: "checkmark.circle")
                case 3: Label("Couldn't send. Tap to try again", systemImage: "exclamationmark.circle")
                default: Label("This game works now: send its logs", systemImage: "checkmark.seal")
                }
            }
            .disabled(state == 1 || state == 2)
        } footer: {
            Text("For a game that had a problem and runs well now. Its last run's logs, with personal details taken out, go to the Madeira team so they can see what fixed it.")
        }
    }
}

/// (get-help-auto) "Save copy for Discord": the same short, scrubbed report Get Help sends, then
/// (discord-full-log, Cameron Nov 8: "the full big megabyte file ... under 5 megabytes") the whole
/// log it came from, scrubbed line by line, as one plain "<game> log.txt". A log bigger than the
/// 5 MB cap keeps its newest part. Discord shows a .txt; its bot deletes a .zip.
/// Also Settings › Logs and Game details › Advanced (ShareLogsButton, LogsView.swift).
enum DiscordLog {
    /// The whole file stays under this (Discord's own limit is higher).
    static let maxBytes = 5 * 1024 * 1024
    /// Most of the 5 MB kept back for madeira-log.txt after the game's log.
    static let madeiraShare = 2 * 1024 * 1024

    /// Writes the report and the full log to a temporary "<game> log.txt". Off the main thread.
    static func file(title: String?, report: String) -> URL? {
        let safe = (title ?? "Madeira").map { "/\\:?*\"<>|".contains($0) ? "-" : $0 }
        let name = String(String(safe).prefix(60)).trimmingCharacters(in: .whitespaces) + " log.txt"
        let url = LogFiles.shareFolder.appendingPathComponent(name)
        do { try report.write(to: url, atomically: true, encoding: .utf8) } catch {
            LogStore.shared.log("[logs] could not write \(name): \(error)", level: .error)
            return nil
        }
        // The same log the report was made from: this game's last run, or the chosen log (Settings).
        let log = ClaudeHelp.documents.flatMap { ClaudeHelp.logFor(title: title, in: $0) }
        // (discord-madeira-log) Then madeira-log.txt, Madeira's own log, when it isn't the log above:
        // up to 2 MB of its newest part is kept back for it, so the whole file stays under 5 MB.
        let docs = ClaudeHelp.documents
        let madeira = docs?.appendingPathComponent("madeira-log.txt")
        let madeiraSize = madeira.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
        let wantMadeira = madeira != nil && madeiraSize > 0 && madeira?.standardizedFileURL != log?.standardizedFileURL
        let reserve = wantMadeira ? min(madeiraSize, madeiraShare) : 0
        let added = log.map { appendFullLog($0, to: url, after: report.utf8.count, limit: maxBytes - reserve) } ?? 0
        var addedMadeira = 0
        if wantMadeira, let madeira {
            addedMadeira = appendFullLog(madeira, to: url, after: report.utf8.count + added, limit: maxBytes)
        }
        LogStore.shared.log("[logs] share \(name) (\(report.utf8.count) bytes report + \(added) bytes full log + \(addedMadeira) bytes madeira-log.txt, scrubbed)")
        return url
    }

    /// Appends "## Full log" and the scrubbed log, newest part only when it would pass maxBytes.
    /// Returns the bytes added; 0 when the file can't be opened (the report alone still shares).
    static func appendFullLog(_ log: URL, to url: URL, after used: Int, limit: Int = maxBytes) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64) ?? 0
        // Room left, with 64 KB spare for scrubbed lines that come out a little longer.
        let room = UInt64(max(0, limit - used - 64 * 1024))
        let from = size > room ? size - room : 0
        guard let out = try? FileHandle(forWritingTo: url) else { return 0 }
        defer { try? out.close() }
        _ = try? out.seekToEnd()
        var head = "\n\n## Full log (\(log.lastPathComponent), personal details taken out)\n"
        if from > 0 { head += "(The start was cut to keep this file under 5 MB; the newest part is below.)\n" }
        var buffer = Data(head.utf8)
        var total = 0
        var first = from > 0 // a cut lands mid-line: drop that half line
        LogLines.forEach(in: log, fromByte: from) { raw in
            if first { first = false; return }
            let clean = PrivacyScrub.line(raw)
            guard used + total + buffer.count + clean.utf8.count + 1 < limit else { return }
            buffer.append(contentsOf: clean.utf8)
            buffer.append(0x0A)
            if buffer.count >= 1 << 20 { out.write(buffer); total += buffer.count; buffer.removeAll(keepingCapacity: true) }
        }
        if !buffer.isEmpty { out.write(buffer); total += buffer.count }
        return total
    }
}

/// (sentry-full-log, Cameron Nov 8: "the max upload for Sentry as our limit, i like the zips")
/// After a kept Get Help answer: one .zip to the server (POST /upload), which sends it to Sentry
/// with the report. The player never sees this zip. Everything in it is scrubbed:
/// report.txt (what Get Help read), game-run.txt (the game's whole last run), madeira-log.txt,
/// madeira.cfg.txt, game-config.txt (that game's config and switches), device.txt and
/// files.txt (the game folder's file names and sizes, for missing DLLs or a wrong exe).
enum GetHelpUpload {
    /// Sentry takes at most 40 MB per compressed upload; this leaves room for the report.
    static let maxZip = 38 * 1024 * 1024
    /// How much of one log goes in before zipping (text packs about 10:1); halved if the zip is too big.
    static let firstLogCap: UInt64 = 64 * 1024 * 1024
    static let maxFiles = 5000
    /// (log-fixes) Seconds the upload waits for a game that is still running to end.
    static let waitForEnd = 120

    /// Called on the main thread right after the answer; the rest runs in the background.
    static func send(requestID: String, title: String, windowsPath: String, report: String, gameText: String?) {
        guard let key = GetHelp.key else { return }
        let device = ClaudeHelp.deviceLine() + "\nMadeira " + BuildStamp.text
        DispatchQueue.global(qos: .utility).async {
            // (log-fixes) A log taken while Wine still runs (Get Help right after Quit, or a frozen
            // game) has no end: wait for it, up to waitForEnd seconds; still running then, say so.
            var waited = 0
            while LogTrail.isRunning(title), waited < waitForEnd { Thread.sleep(forTimeInterval: 5); waited += 5 }
            let running = LogTrail.isRunning(title)
            if waited > 0 { LogStore.shared.log("[get-help] upload waited \(waited) s for \(title)'s end\(running ? "; still running" : "")") }
            let zip = make(title: title, windowsPath: windowsPath, report: report, gameText: gameText, device: device,
                           stillRunning: running)
            var request = URLRequest(url: GetHelpCore.server.appendingPathComponent("upload"), timeoutInterval: 300)
            request.httpMethod = "POST"
            request.setValue(key, forHTTPHeaderField: "x-madeira-key")
            request.setValue(requestID, forHTTPHeaderField: "x-request-id")
            request.setValue("application/zip", forHTTPHeaderField: "content-type")
            let size = zip.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
            // No zip (it failed): an empty upload still sends the report to Sentry.
            let done: (Data?, URLResponse?, Error?) -> Void = { _, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                LogStore.shared.log("[get-help] upload: \(size) bytes, HTTP \(status)\(error.map { ", \($0)" } ?? "")",
                                    level: status == 200 ? .info : .error)
                if let zip { try? FileManager.default.removeItem(at: zip) }
            }
            if let zip { URLSession.shared.uploadTask(with: request, fromFile: zip, completionHandler: done).resume() }
            else { URLSession.shared.uploadTask(with: request, from: Data(), completionHandler: done).resume() }
        }
    }

    /// (works-now) "This game works now": the same scrubbed zip, for a run that went well, sent to POST /works
    /// so it sits in Sentry beside the reports from when the game didn't. `done(true)` on HTTP 200.
    /// Call on the main thread (it reads the game's config); the rest runs in the background.
    static func sendWorks(title: String, windowsPath: String, gameText: String?, done: @escaping (Bool) -> Void) {
        guard let key = GetHelp.key else { done(false); return }
        let deviceLine = ClaudeHelp.deviceLine()
        let device = deviceLine + "\nMadeira " + BuildStamp.text
        DispatchQueue.global(qos: .utility).async {
            let report = GetHelp.report(game: gameText, title: title, device: deviceLine)
            let zip = make(title: title, windowsPath: windowsPath, report: report, gameText: gameText, device: device)
            var request = URLRequest(url: GetHelpCore.server.appendingPathComponent("works"), timeoutInterval: 300)
            request.httpMethod = "POST"
            request.setValue(key, forHTTPHeaderField: "x-madeira-key")
            request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "x-request-id")
            request.setValue(title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "", forHTTPHeaderField: "x-game")
            request.setValue(BuildStamp.text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "", forHTTPHeaderField: "x-app-version")
            request.setValue("application/zip", forHTTPHeaderField: "content-type")
            let finish: (Data?, URLResponse?, Error?) -> Void = { _, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                LogStore.shared.log("[get-help] works-now: \(title), HTTP \(status)\(error.map { ", \($0)" } ?? "")",
                                    level: status == 200 ? .info : .error)
                if let zip { try? FileManager.default.removeItem(at: zip) }
                DispatchQueue.main.async { done(status == 200) }
            }
            if let zip { URLSession.shared.uploadTask(with: request, fromFile: zip, completionHandler: finish).resume() }
            else { URLSession.shared.uploadTask(with: request, from: Data(), completionHandler: finish).resume() }
        }
    }

    /// The zip, under maxZip: tries with less of each log until it fits. nil if it can't be written.
    static func make(title: String, windowsPath: String, report: String, gameText: String?, device: String,
                     stillRunning: Bool = false) -> URL? {
        guard let docs = ClaudeHelp.documents else { return nil }
        let run = ClaudeHelp.logFor(title: title, in: docs)
        // (get-help-earlier-run) this game's run before this one, to compare with.
        let earlier = ClaudeHelp.earlierRunLog(title: title, current: run, in: docs)
        let logs: [(String, URL?)] = [("game-run.txt", run), ("earlier-run.txt", earlier),
                                       ("madeira-log.txt", docs.appendingPathComponent("madeira-log.txt"))]
        var texts: [(String, String)] = [("report.txt", report), ("device.txt", device)]
        if let gameText { texts.append(("game-config.txt", PrivacyScrub.text(gameText))) }
        if let cfg = try? String(contentsOf: docs.appendingPathComponent(MadeiraConfig.fileName), encoding: .utf8) {
            texts.append(("madeira.cfg.txt", PrivacyScrub.text(cfg)))
        }
        texts.append(("files.txt", fileList(windowsPath)))
        // Its own name per upload: a second look starts another upload while the first is still
        // writing (a shared name cut the first zip short, Wave 21).
        let url = LogFiles.shareFolder.appendingPathComponent("get-help-upload-\(UUID().uuidString).zip")
        // (log-fixes) madeira-log.txt leaves out the runs that are in the zip as their own file.
        let sentRuns = Set([run, earlier].compactMap { $0.flatMap(firstRunStart) })
        let runningNote = stillRunning
            ? "(The game was still running when these logs were taken, \(waitForEnd) s after Get Help: this run has no end yet.)\n" : nil
        var cap = firstLogCap
        for _ in 0..<6 {
            try? FileManager.default.removeItem(at: url)
            do {
                let zip = try LogZip(url: url)
                for (name, text) in texts { try zip.add(name: name, data: Data(text.utf8)) }
                for (name, log) in logs {
                    guard let log, FileManager.default.fileExists(atPath: log.path) else { continue }
                    let slim = slimLogs ? LogSlim(skipStarts: name == "madeira-log.txt" ? sentRuns : []) : nil
                    try zip.add(name: name, data: scrubbedTail(log, cap: cap, slim: slim,
                                                                note: name == "game-run.txt" ? runningNote : nil))
                }
                try zip.finish()
            } catch {
                LogStore.shared.log("[get-help] upload zip failed: \(error)", level: .error)
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? Int.max
            if size <= maxZip { return url }
            cap /= 2
        }
        try? FileManager.default.removeItem(at: url)
        return nil
    }

    /// (log-fixes) env.MADEIRA_UPLOAD_SLIM = 0 sends every line of each log (LogSlim.swift).
    static let slimLogs = MadeiraConfig.flag("MADEIRA_UPLOAD_SLIM")

    /// A run file's first "[run-start] #N" line (ClaudeHelp copies runs line for line).
    static func firstRunStart(_ url: URL) -> String? {
        var found: String?
        _ = LogLines.contains(in: url) { line in
            guard line.contains("[run-start] #") else { return false }
            found = line
            return true
        }
        return found
    }

    /// The log's newest `cap` bytes, scrubbed line by line (a cut start drops its half line).
    /// `slim` (log-fixes) leaves out repeats; `note` goes first.
    static func scrubbedTail(_ log: URL, cap: UInt64, slim: LogSlim? = nil, note: String? = nil) -> Data {
        let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64) ?? 0
        let from = size > cap ? size - cap : 0
        var out = Data()
        if let note { out.append(Data(note.utf8)) }
        if from > 0 { out.append(Data("(The start of this log was cut to fit Sentry's upload limit.)\n".utf8)) }
        var first = from > 0
        func write(_ line: String) {
            out.append(contentsOf: PrivacyScrub.line(line).utf8)
            out.append(0x0A)
        }
        LogLines.forEach(in: log, fromByte: from) { raw in
            if first { first = false; return }
            if let slim { slim.take(raw).forEach(write) } else { write(raw) }
        }
        slim?.finish().forEach(write)
        return out
    }

    /// The game folder (the exe's folder) a few levels deep: "size  path" per file, at most maxFiles.
    static func fileList(_ windowsPath: String) -> String {
        guard let exe = LibraryEntry.hostURL(ofWindowsPath: windowsPath) else { return "(no game folder: \(windowsPath))" }
        let folder = exe.deletingLastPathComponent()
        var lines = ["# \(PrivacyScrub.text(windowsPath)) - files in its folder (bytes, path)"]
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return lines[0] + "\n(the folder can't be read)"
        }
        let base = folder.standardizedFileURL.path
        for case let file as URL in walker {
            if walker.level > 4 { walker.skipDescendants(); continue }
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            let path = String(file.standardizedFileURL.path.dropFirst(base.count + 1))
            lines.append("\(values?.fileSize ?? 0)  \(PrivacyScrub.text(path))")
            if lines.count > maxFiles { lines.append("(more files left out)"); break }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// (get-help-auto) The button that makes and shares DiscordLog's file. `report` is the one the sheet
/// already made; without it the button makes its own.
struct DiscordLogButton: View {
    let entry: LibraryEntry?
    var report: String? = nil
    var shown: String? = nil
    var big = false
    var title = "Save copy for Discord"
    /// A plain row in a Settings list (Settings > Diagnostics), not a bordered button.
    var row = false
    @State private var file: DiscordLogFile?
    @State private var busy = false
    var body: some View {
        Group {
            if row {
                Button(action: make) {
                    HStack {
                        Label(L(title), systemImage: "doc.text")
                        if busy { Spacer(); ProgressView() }
                    }
                }
            } else {
                Button(action: make) {
                    HStack(spacing: 8) {
                        if busy { ProgressView() } else { Image(systemName: "doc.text") }
                        Text(L(title)).fontWeight(big ? .bold : .semibold)
                    }
                    .frame(maxWidth: big ? .infinity : nil, minHeight: big ? 52 : nil)
                }
                .modifier(GetHelpButtonStyle(prominent: big))
            }
        }
        .disabled(busy)
        .sheet(item: $file) { ActivitySheet(items: [$0.url]) }
    }
    private func make() {
        guard !busy else { return }
        busy = true
        let entry = entry, made = report, shown = shown
        let game = entry.map(ClaudeHelp.gameText)
        let device = ClaudeHelp.deviceLine()
        DispatchQueue.global(qos: .userInitiated).async {
            let text = made ?? GetHelp.report(game: game, title: entry?.title, device: device, shown: shown)
            let url = DiscordLog.file(title: entry?.title, report: text)
            DispatchQueue.main.async {
                busy = false
                if let url { file = DiscordLogFile(url: url) }
            }
        }
    }
}

private struct DiscordLogFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Big filled buttons for the sheet's main action, grey ones for the rest.
struct GetHelpButtonStyle: ViewModifier {
    var prominent: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 14)) }
        else { content.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14)) }
    }
}

/// The sheet: what is sent (the first time), then the answer as a walkthrough: one short
/// step per screen in big type, an Apply screen for setting lines, and a last screen with
/// Play Again and Save copy for Discord. Players barely read, so each screen says one thing.
struct GetHelpSheet: View {
    let target: GetHelpTarget
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = LibraryModel.shared

    enum Phase: Equatable { case consent, sending, answer(GetHelpCore.Answer), failed(String) }
    /// One screen of the walkthrough.
    enum Page: Equatable { case step(String), apply([GetHelpCore.ConfigLine]), last }
    @State private var phase: Phase = GetHelp.consented ? .sending : .consent
    @State private var report: String?
    /// (game-log-pick) No log has this game: no Try Again or Discord log (they would send no log).
    @State private var noRun = false
    @State private var task: URLSessionDataTask?
    @State private var sentAt = Date()
    @State private var applied: GetHelp.Applied?
    @State private var helped: Bool?
    @State private var copied = false
    @State private var page = 0
    @State private var seeReport = false
    /// (get-help-files) The files this device can send, and whether the second round is running.
    @State private var places: GetHelpFiles.Places?
    @State private var lookingCloser = false

    private var entry: LibraryEntry? {
        model.entries.first { $0.windowsPath.lowercased() == target.windowsPath.lowercased() && !target.windowsPath.isEmpty }
            ?? model.entries.first { $0.title == target.title }
    }
    private var windowsPath: String { target.windowsPath.isEmpty ? (entry?.windowsPath ?? "") : target.windowsPath }

    var body: some View {
        NavigationStack {
            screen
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Get Help").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(phase == .consent ? L("Cancel") : L("Close")) { close() } }
                }
                .navigationDestination(isPresented: $seeReport) { reportPage }
        }
        .onAppear(perform: prepare)
        .onDisappear { task?.cancel() }
        // The sheet claims the controller (ClaimGamepadEvents): B closes (or goes back a step), A does the big button.
        .onReceive(LibraryController.shared.commands) { command in
            if command == "back" { if case .answer = phase, page > 0 { page -= 1 } else { close() } }
            if command == "accept" { primary() }
        }
    }

    @ViewBuilder private var screen: some View {
        switch phase {
        case .consent: consent
        case .sending: sending
        case .answer(let answer): walkthrough(answer)
        case .failed(let message): failed(message)
        }
    }

    /// The parts every screen has: the text at the top, the buttons at the bottom.
    private func layout<Top: View, Bottom: View>(@ViewBuilder top: () -> Top, @ViewBuilder bottom: () -> Bottom) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { top() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 24)
            }
            VStack(spacing: 10) { bottom() }
                .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 8)
        }
    }

    /// The red line: what went wrong, when Madeira showed an error.
    @ViewBuilder private var errorLine: some View {
        if let error = target.error {
            Text(String(format: L("%@ didn't start"), target.title) + (error.isEmpty ? "" : ": " + shortError(error)))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    /// The error's first sentence, without "Export the diagnostic log" (Get Help does that now).
    private func shortError(_ error: String) -> String {
        let first = error.components(separatedBy: ". ").first ?? error
        return first.hasSuffix(".") ? first : first + "."
    }

    private func bigButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).fontWeight(.bold).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .modifier(GetHelpButtonStyle(prominent: true))
    }
    private func greyButton(_ title: String, _ symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
        }
        .modifier(GetHelpButtonStyle(prominent: false))
    }

    /// (works-now) "Not what you saw?": what the player picked (sent in English), and the report before it.
    @State private var saw: String?
    @State private var firstReport: String?
    static let sawChoices = ["It froze", "It crashed", "Black screen", "No sound", "It's slow"]

    /// Sends the report again with one line on top saying what the player saw; the server reads it first.
    private func lookAgain(_ choice: String) {
        guard saw == nil, let base = firstReport ?? report else { return }
        firstReport = base
        saw = choice
        report = "What the player saw: " + choice + "\n\n" + base
        LogStore.shared.log("[get-help] not what you saw: \(choice)")
        send()
    }

    /// (works-now) First screen: a game with an unanswered report asks if it works now.
    @State private var worksState = 0   // 0 ask, 1 sending, 2 sent
    @ViewBuilder private var worksCard: some View {
        if worksState == 2 {
            Label("Thanks. Your logs were sent so the team can see what fixed it.", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.secondary)
        } else if let report = GetHelp.reported[target.windowsPath] {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(format: L("Does %@ work now?"), target.title)).font(.headline)
                Text("If it runs well now, Yes sends its last run's logs, with personal details taken out, so the team can see what fixed it.")
                    .font(.footnote).foregroundStyle(.secondary)
                greyButton(worksState == 1 ? L("Sending…") : L("Yes, it works now"), "checkmark.circle") {
                    guard worksState == 0 else { return }
                    worksState = 1
                    GetHelp.sendWorks(report) { ok in worksState = ok ? 2 : 0 }
                }
            }
            .padding(14)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: Phases

    @ViewBuilder private var consent: some View {
        layout {
            errorLine
            worksCard
            Text("Let's find out why").font(.largeTitle.bold())
            Text("Madeira sends a short report about this game and gets you an answer in a few seconds.")
                .font(.title3).foregroundStyle(.secondary)
            Text("Your name, accounts and other personal details are taken out first. Madeira's helper uses Claude by Anthropic.")
                .font(.body).foregroundStyle(.secondary)
        } bottom: {
            Button(action: send) {
                HStack(spacing: 8) {
                    if report == nil { ProgressView(); Text("Getting the report ready…") }
                    else { Text("Send Report").fontWeight(.bold) }
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .modifier(GetHelpButtonStyle(prominent: true))
            .disabled(report == nil)
            Button("See What's Sent") { seeReport = true }.disabled(report == nil)
            Text("Your logs go to Sentry, with all personal details taken out.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var sending: some View {
        layout {
            TimelineView(.periodic(from: sentAt, by: 1)) { context in
                VStack(spacing: 18) {
                    ProgressView().controlSize(.large).padding(.top, 80)
                    Text(report == nil ? "Reading the game's log…" : (lookingCloser ? "Looking closer at your game…" : "Looking at what happened…")).font(.title2.bold())
                    Text(context.date.timeIntervalSince(sentAt) > 12 ? "Still working. Almost there." : "This usually takes about 5 seconds.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
        } bottom: {
            greyButton(L("Cancel")) { close() }
        }
    }

    /// The answer's screens: the server's steps, an Apply screen when it sent setting lines
    /// (and the game's config is known), and the last screen.
    private func pages(_ answer: GetHelpCore.Answer) -> [Page] {
        var out = (answer.steps ?? []).prefix(3).map { Page.step($0) }
        if let lines = answer.config?.lines, !lines.isEmpty { out.append(.apply(lines)) }
        out.append(.last)
        return out
    }

    @ViewBuilder private func walkthrough(_ answer: GetHelpCore.Answer) -> some View {
        let all = pages(answer)
        let index = min(page, all.count - 1)
        layout {
            if index == 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What happened").font(.subheadline.weight(.semibold))
                    Text(answer.answer ?? "").font(.body)
                    if answer.confidence == "low" {
                        Text("This is our best guess.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                .padding(.bottom, answer.request_id == nil ? 12 : 6)
                // (works-now) The report is already with the team: nothing more to send.
                if answer.request_id != nil {
                    Label("Sent to the Madeira team. You don't need to send anything else.", systemImage: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.bottom, 12)
                }
                // (works-now) "Not what you saw?": one tap asks again with what the player saw (once per Get Help).
                if answer.request_id != nil, saw == nil, report != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Not what you saw?").font(.subheadline.weight(.semibold))
                        Text("Tap what happened and Get Help looks again.").font(.footnote).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Self.sawChoices, id: \.self) { choice in
                                    Button(L(choice)) { lookAgain(choice) }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            Text(String(format: L("Step %d of %d"), index + 1, all.count).uppercased())
                .font(.subheadline.weight(.bold)).foregroundStyle(Color.accentColor)
            pageText(all[index])
            dots(all.count, index)
        } bottom: {
            pageButtons(all[index], answer: answer, last: index == all.count - 1)
            if index > 0 { greyButton(L("Back")) { page = index - 1 } }
        }
        .animation(.easeOut(duration: 0.2), value: page)
    }

    @ViewBuilder private func pageText(_ page: Page) -> some View {
        switch page {
        case .step(let text):
            Text(text).font(.title.bold()).fixedSize(horizontal: false, vertical: true)
        case .apply(let lines):
            Text(windowsPath.isEmpty ? L("Copy the fix into this game's config.") : L("Apply the fix to this game.")).font(.title.bold())
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    if !line.plain.isEmpty { Text(line.plain).font(.body) }
                    Text(line.line).font(.callout.monospaced()).foregroundStyle(.green)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            Text(windowsPath.isEmpty
                 ? L("Game details > Advanced > This game's config.")
                 : String(format: L("Only %@ changes. You can undo it any time."), target.title))
                .font(.subheadline).foregroundStyle(.secondary)
            appliedLine
        case .last:
            Text(entry == nil ? L("Close Get Help and play the game again.") : L("Close Get Help and tap Play again."))
                .font(.title.bold())
            appliedLine
            rating
        }
    }

    /// "Applied to <game> · Undo", once Apply ran.
    @ViewBuilder private var appliedLine: some View {
        switch applied {
        case .added?:
            HStack(spacing: 6) {
                Label(String(format: L("Applied to %@"), target.title), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(verbatim: "·").foregroundStyle(.secondary)
                Button("Undo") {
                    GetHelp.undo(windowsPath: windowsPath, title: target.title)
                    applied = nil
                }
            }
            .font(.subheadline)
        case .already?:
            Label("This game already has these settings.", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.green)
        case .failed?:
            Label("Madeira couldn't save the settings. Try again.", systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var rating: some View {
        if case .answer(let answer) = phase, let id = answer.request_id {
            if let helped {
                Label(helped ? L("Thanks! Glad it helped.") : L("Thanks for telling us."),
                      systemImage: helped ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Did this help?").font(.subheadline).foregroundStyle(.secondary)
                    Button { rate(id, true) } label: { Image(systemName: "hand.thumbsup") }.buttonStyle(.bordered)
                    Button { rate(id, false) } label: { Image(systemName: "hand.thumbsdown") }.buttonStyle(.bordered)
                }
                .padding(.top, 8)
            }
        }
    }

    private func dots(_ count: Int, _ index: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(i == index ? Color.primary : Color.secondary.opacity(0.35)).frame(width: 9, height: 9)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 18)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func pageButtons(_ page: Page, answer: GetHelpCore.Answer, last: Bool) -> some View {
        switch page {
        case .step:
            bigButton(L("Next")) { next() }
        case .apply(let lines):
            if windowsPath.isEmpty {
                bigButton(copied ? L("Copied") : L("Copy Settings")) {
                    UIPasteboard.general.string = lines.map(\.line).joined(separator: "\n")
                    copied = true
                }
                greyButton(L("Next")) { next() }
            } else if applied == nil || applied == .failed {
                bigButton(String(format: L("Apply to %@"), target.title)) { if apply(lines) != .failed { next() } }
                greyButton(L("Skip")) { next() }
            } else {
                bigButton(L("Next")) { next() }
            }
        case .last:
            if entry != nil { bigButton(L("Play Again")) { playAgain() } } else { bigButton(L("Done")) { close() } }
            DiscordLogButton(entry: entry, report: report, title: "Want to talk about it? Save copy for Discord")
            Text("Only if you want to chat in the Madeira Discord. The team already has your logs.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private func failed(_ message: String) -> some View {
        layout {
            errorLine
            Text("Get Help can't answer right now").font(.largeTitle.bold())
            Text(message).font(.title3).foregroundStyle(.secondary)
            Text("Do this instead".uppercased()).font(.subheadline.weight(.bold)).foregroundStyle(Color.accentColor).padding(.top, 24)
            Text("Tap Save copy for Discord and post the file in the Madeira Discord.").font(.title2.bold())
        } bottom: {
            if !noRun {
                DiscordLogButton(entry: entry, report: report, shown: target.error, big: true)
                if GetHelp.key != nil { greyButton(L("Try Again"), "arrow.clockwise", action: send) }
            }
        }
    }

    private var reportPage: some View {
        ScrollView {
            Text(report ?? "")
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("What's Sent").navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Actions

    /// The report is made at once, in the background (it reads the log).
    private func prepare() {
        guard report == nil else { return }
        sentAt = Date()
        let game = entry.map(ClaudeHelp.gameText)
        let device = ClaudeHelp.deviceLine()
        let shown = target.error
        let title = target.title
        let entryNow = entry
        let sendWhenReady = phase == .sending
        DispatchQueue.global(qos: .userInitiated).async {
            let made = GetHelp.reportAndRun(game: game, title: title, device: device, shown: shown)
            DispatchQueue.main.async {
                report = made.text
                places = GetHelp.places(for: entryNow, title: title, hasRun: made.foundRun)
                // (game-log-pick) No run of this game in any log: say so instead of sending another game's log.
                if !made.foundRun {
                    LogStore.shared.log("[get-help] log: no run of \(title) in any log")
                    noRun = true
                    phase = .failed(L(GetHelp.noRunMessage))
                    return
                }
                if sendWhenReady { send() }
            }
        }
    }

    private func send() {
        guard let report else { phase = .sending; return }
        GetHelp.consented = true
        phase = .sending
        sentAt = Date()
        applied = nil; helped = nil; page = 0
        lookingCloser = false
        var request = GetHelpCore.Request(install_id: GetHelp.installID, game: target.title, app_version: BuildStamp.text,
                                          reason: target.reason, report: report, keep_report: true)
        if let places { request.can_send = GetHelpFiles.available(places) }
        task?.cancel()
        task = GetHelp.send(request) { outcome, _ in
            switch outcome {
            case .answer(let answer):
                if let need = answer.need, !need.isEmpty, let id = answer.request_id, let places {
                    lookClose(request, need: need, followUp: id, places: places, fallback: answer)
                } else {
                    show(answer)
                }
            case .failed(let message):
                phase = .failed(L(message))   // the app's own messages are translated; the server's stay as sent
            }
        }
    }

    private func show(_ answer: GetHelpCore.Answer) {
        lookingCloser = false
        // (sentry-full-log) The answer shown (round 2's, or round 1's when there was none) sends the
        // full logs to Sentry with that request's kept report, in the background.
        if let id = answer.request_id, let report {
            GetHelpUpload.send(requestID: id, title: target.title, windowsPath: windowsPath, report: report,
                               gameText: entry.map(ClaudeHelp.gameText))
            GetHelp.noteReport(title: target.title, windowsPath: windowsPath)
        }
        if answer.kind == "not_madeira" {
            var shown = answer; shown.answer = L(GetHelpCore.notMadeiraAnswer); shown.config = nil; shown.steps = []
            phase = .answer(shown)
        } else {
            phase = .answer(answer)
        }
    }

    /// (get-help-files) The answer asked for files: read them in the background and ask once more,
    /// with nothing for the player to do. Any failure shows the first answer instead.
    private func lookClose(_ first: GetHelpCore.Request, need: [String], followUp: String,
                           places: GetHelpFiles.Places, fallback: GetHelpCore.Answer) {
        lookingCloser = true
        DispatchQueue.global(qos: .userInitiated).async {
            let files = GetHelpFiles.collect(need, at: places, scrub: PrivacyScrub.text)
            LogStore.shared.log("[get-help] looking closer: asked \(need.joined(separator: ",")), sending "
                                + "\(files.map { "\($0.kind) \($0.text.utf8.count) B" }.joined(separator: ", "))")
            DispatchQueue.main.async {
                guard phase == .sending, lookingCloser else { return }   // closed or tried again meanwhile
                guard !files.isEmpty else { show(fallback); return }
                var again = first
                again.can_send = nil
                again.follow_up = followUp
                again.files = files
                task = GetHelp.send(again) { outcome, _ in
                    if case .answer(let answer) = outcome { show(answer) } else { show(fallback) }
                }
            }
        }
    }

    private func next() {
        guard case .answer(let answer) = phase else { return }
        page = min(page + 1, pages(answer).count - 1)
    }

    @discardableResult
    private func apply(_ lines: [GetHelpCore.ConfigLine]) -> GetHelp.Applied {
        let result = GetHelp.apply(lines, windowsPath: windowsPath, title: target.title)
        applied = result
        // (fix-check) Ask after the next play whether it worked.
        if case .added = result, case .answer(let answer) = phase, let id = answer.request_id {
            GetHelp.watchFix(requestID: id, windowsPath: windowsPath, title: target.title)
        }
        return result
    }

    private func rate(_ id: String, _ value: Bool) {
        helped = value
        GetHelp.feedback(requestID: id, helped: value)
    }

    /// Play Again: the sheet closes (over the starting screen, the session closes too), and
    /// the library starts the game again through the usual Play (GetHelpOffer).
    private func playAgain() {
        guard let entry else { close(); return }
        GetHelpCenter.shared.playAgain = entry.id
        close()
    }

    /// What A does: the screen's big button.
    private func primary() {
        switch phase {
        case .consent: if report != nil { send() }
        case .answer(let answer):
            let all = pages(answer)
            switch all[min(page, all.count - 1)] {
            case .step: next()
            case .apply(let lines):
                if windowsPath.isEmpty || (applied != nil && applied != .failed) || apply(lines) != .failed { next() }
            case .last: playAgain()
            }
        case .failed: if GetHelp.key != nil { send() } else { close() }
        case .sending: break
        }
    }

    private func close() {
        task?.cancel()
        dismiss()
    }
}

extension GetHelp.Applied: Equatable {}
