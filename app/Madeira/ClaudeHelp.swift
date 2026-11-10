// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Get Help from Claude: one text file for a fresh Claude chat on anyone's
//  phone. At the top, a short guide to every known Madeira fix and setting
//  (Give-to-Claude-with-log-and-cfg.txt, bundled with the app); below it the
//  player's report (HelpReport.swift): device and build, the session summary,
//  the game's config and the log lines that usually explain a problem.
//
//  It used to share six files, two of them whole logs of 1 to 20 MB, which
//  filled a free plan's chat after one message. The report is about 30 KB and
//  has personal details taken out (PrivacyScrub.swift).
//
//  The guide is copied into Documents at every start, beside madeira-log.txt,
//  so it can also be shared from the Files app. Game details and Settings ›
//  Diagnostics share the file through the system share sheet. The report is
//  never sent anywhere by Madeira itself.
//
//  The newest guide: when the button makes its file, Madeira first asks the Get
//  Help server for the newest guide (GET /guide, waits at most 4 s). The server's
//  copy is made from the team's fixes index each time the server is updated, so it
//  doesn't wait for a new build. It is kept in Application Support and used when
//  its "Updated" date is the same as or newer than the bundled guide's; offline,
//  or with Get Help off (env.MADEIRA_GET_HELP = 0), the bundled guide is used.
//  Nothing about the player goes with that request.
//
//  The guide's cfg keys are checked against the code by
//  tests/host/check-claude-help-guide.py.
//

import Foundation
import SwiftUI

enum ClaudeHelp {
    static let fileName = "Give-to-Claude-with-log-and-cfg.txt"

    static var documents: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }
    static var bundled: URL? {
        Bundle.main.url(forResource: "Give-to-Claude-with-log-and-cfg", withExtension: "txt")
    }

    /// Documents/Give-to-Claude-with-log-and-cfg.txt: the newest guide (bundled or
    /// from the server, see bestGuide); written again whenever it differs.
    static func install() {
        DispatchQueue.global(qos: .utility).async { installNow() }
    }

    /// install(), on the calling thread.
    static func installNow() {
        guard let docs = ClaudeHelp.documents else { return }
        let text = bestGuide()
        guard !text.isEmpty else { return }
        let data = Data(text.utf8)
        let target = docs.appendingPathComponent(ClaudeHelp.fileName)
        if (try? Data(contentsOf: target)) == data { return }
        do {
            try data.write(to: target, options: .atomic)
            LogStore.shared.log("[claude-help] guide written to Documents/\(ClaudeHelp.fileName) (\(data.count) bytes, updated \(updatedDate(text) ?? "?"))")
        } catch {
            LogStore.shared.log("[claude-help] could not write the guide: \(error.localizedDescription)", level: .error)
        }
    }

    /// Entry fields left out of the game's settings file: pictures, sizes and
    /// control layouts say nothing about why a game fails, and layouts are long.
    static let skippedEntryKeys: Set<String> = [
        "id", "coverFile", "folderBytes", "metadataChecked", "metadataRevision", "steamMetadataInstall",
        "controls", "zones", "controlLayout", "controllerBinds", "config",
    ]

    /// The one file to share: the guide, then the player's report. Reads a log
    /// of up to tens of MB, so it is called off the main thread; `game` and
    /// `device` are read on the main thread first (gameText, deviceLine).
    static func files(for entry: LibraryEntry?, game: String?, device: String) -> [URL] {
        fetchNewest()
        installNow()
        let fm = FileManager.default
        guard let docs = documents else { return [] }
        let folder = fm.temporaryDirectory.appendingPathComponent("ClaudeHelp", isDirectory: true)
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let guide = bestGuide()
        let log = logFor(title: entry?.title, in: docs).map(HelpReport.read)
        let cfg = try? String(contentsOf: docs.appendingPathComponent(MadeiraConfig.fileName), encoding: .utf8)
        let report = HelpReport.text(build: BuildStamp.text, device: device, log: log,
                                     game: game, cfg: cfg, title: entry?.title)
        let header = """
        Get Help from Claude: give this whole file to Claude and say what went wrong.
        Part 1 is the help guide (for Claude). Part 2, at the end, is the player's report.


        """
        let name = (entry.map { safeName($0.title) } ?? "Madeira") + " - Get Help from Claude.txt"
        let file = folder.appendingPathComponent(name)
        guard (try? (header + guide + "\n\n" + report).write(to: file, atomically: true, encoding: .utf8)) != nil else { return [] }
        LogStore.shared.log("[claude-help] share: \(name) (\(log?.name ?? "no log"), \(log?.lines ?? 0) lines -> "
                            + "\((try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0) bytes)")
        return [file]
    }

    /// (game-log-pick) The log for `title`: its newest run in this app run's log, the previous
    /// app run's or the last game log (newest file first), cut from its [run-start] to its
    /// [run-end] and written to a small file HelpReport reads. A run that reached Wine wins over
    /// a newer one that never started (held for a restart). nil when no log has the game, so
    /// Get Help never sends another game's log.
    static func gameRunLog(title: String, in docs: URL) -> URL? {
        let fm = FileManager.default
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        // (get-help-earlier-run) then Documents/logs, where each game launch keeps its app run's
        // log: a game played a few Madeira launches ago is still found.
        let files = (["madeira-log.txt", "madeira-log.prev.txt", LogSummary.gameLogName]
            .map { docs.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
            .sorted { modified($0) > modified($1) }) + sessionLogs(in: docs)
        var fallback: (url: URL, lines: [Substring])?
        for url in files {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            guard let run = lastRun(of: title, in: text.split(separator: "\n", omittingEmptySubsequences: false)) else { continue }
            if run.started {
                return writeRun(run.lines, title: title, from: url)
            }
            if fallback == nil { fallback = (url, run.lines) }
        }
        return fallback.flatMap { writeRun($0.lines, title: title, from: $0.url) }
    }

    /// (get-help-earlier-run) Documents/logs, newest first: one hard link per game launch to that
    /// app run's whole log (LogStore.startSessionLog, ntdll's Steam session log; 40 kept).
    static func sessionLogs(in docs: URL) -> [URL] {
        let folder = docs.appendingPathComponent("logs", isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let all = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return [] }
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        return all.filter { $0.pathExtension == "txt" }.sorted { modified($0) > modified($1) }
    }

    /// (get-help-earlier-run) `title`'s run before the one Get Help reports: an earlier run that
    /// reached Wine, from Documents/logs or the main logs, so the team can compare a run that
    /// worked (or failed differently) with this one. Several names can be one file (hard links),
    /// so the run whose lines equal `current`'s is skipped wherever it is found.
    /// nil when there is none. Only this game's runs are ever sent.
    static func earlierRunLog(title: String, current: URL?, in docs: URL) -> URL? {
        let fm = FileManager.default
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        let now = current.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let files = (["madeira-log.txt", "madeira-log.prev.txt"].map { docs.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) } + sessionLogs(in: docs))
            .sorted { modified($0) > modified($1) }
        for url in files.prefix(40) {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for run in runs(of: title, in: text.split(separator: "\n", omittingEmptySubsequences: false)) where run.started {
                let body = run.lines.joined(separator: "\n") + "\n"
                guard body != now else { continue }
                let folder = fm.temporaryDirectory.appendingPathComponent("GetHelpRun", isDirectory: true)
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("\(safeName(title))'s earlier run.txt")
                guard (try? body.write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
                LogStore.shared.log("[get-help] earlier run: \(title) from \(url.lastPathComponent) (\(run.lines.count) lines)")
                return file
            }
        }
        return nil
    }

    /// Every run of `title` in a log's lines, newest first (see lastRun).
    static func runs(of title: String, in lines: [Substring]) -> [(lines: [Substring], started: Bool)] {
        var out: [(lines: [Substring], started: Bool)] = []
        var upTo = lines.count
        while upTo > 0, let run = lastRun(of: title, in: Array(lines[..<upTo])) {
            out.append(run)
            guard let start = lines[..<upTo].lastIndex(where: { $0 == run.lines.first! }) else { break }
            upTo = start
        }
        return out
    }

    /// `title`'s last run in a log's lines: [run-start] #N <title> to [run-end] #N (or the end),
    /// and whether it reached Wine. Host-tested in Python (check-get-help.py mirrors it).
    static func lastRun(of title: String, in lines: [Substring]) -> (lines: [Substring], started: Bool)? {
        let want = title.trimmingCharacters(in: .whitespaces)
        for i in lines.indices.reversed() {
            guard let r = lines[i].range(of: "[run-start] #") else { continue }
            let rest = lines[i][r.upperBound...]
            let number = rest.prefix { $0.isNumber }
            guard !number.isEmpty, rest.dropFirst(number.count + 1).trimmingCharacters(in: .whitespaces) == want else { continue }
            let endMarker = "[run-end] #\(number)"
            var end = lines.count - 1
            for j in (i + 1)..<max(i + 1, lines.count) where lines[j].contains(endMarker) { end = j; break }
            let run = Array(lines[i...end])
            let started = run.contains { $0.contains("Running full Wine sequence") || $0.contains("[WineProc] Target exe: ") }
            return (run, started)
        }
        return nil
    }

    private static func writeRun(_ lines: [Substring], title: String, from url: URL) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GetHelpRun", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(url.lastPathComponent), \(safeName(title))'s last run.txt")
        guard (try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
        LogStore.shared.log("[get-help] log: \(title)'s last run from \(url.lastPathComponent) (\(lines.count) lines)")
        return file
    }

    /// The log to read: `title`'s own last run when a game is named (nil when no log has it),
    /// otherwise chosenLog (Settings, no game).
    static func logFor(title: String?, in docs: URL) -> URL? {
        guard let title, !title.isEmpty else { return chosenLog(in: docs) }
        return gameRunLog(title: title, in: docs)
    }

    /// This run's log while it has a game in it (a session running, or just
    /// ended); otherwise the last log that had one (madeira-log.txt is often a
    /// run with no game, after Madeira was opened again).
    static func chosenLog(in docs: URL) -> URL? {
        let fm = FileManager.default
        let current = docs.appendingPathComponent("madeira-log.txt")
        let game = docs.appendingPathComponent(LogSummary.gameLogName)
        let hasGame = fm.fileExists(atPath: game.path)
        guard fm.fileExists(atPath: current.path) else { return hasGame ? game : nil }
        guard hasGame else { return current }
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        if modified(current) > modified(game).addingTimeInterval(5), hasSession(current) { return current }
        return game
    }

    /// Whether a log started Wine: the markers LogSummary.Reader takes as a session.
    static func hasSession(_ url: URL) -> Bool {
        LogLines.contains(in: url) { $0.contains("Running full Wine sequence") || $0.contains("[WineProc] Target exe: ") }
    }

    /// The game's own config, then its Game details settings, as plain text.
    static func gameText(_ entry: LibraryEntry) -> String {
        var lines = [
            "## \(entry.title): this game's config and settings",
            "# Program: \(entry.windowsPath)",
            "# Bits: \(entry.bits)",
        ]
        if let appID = entry.steamAppID { lines.append("# Steam App ID: \(appID)") }
        lines.append("")
        lines.append("## This game's config (Game details > Advanced > This game's config)")
        let config = GameProfile(windowsPath: entry.windowsPath).text
        lines.append(config.isEmpty ? "# (empty: only madeira.cfg and the defaults apply)" : config)
        lines.append("")
        lines.append("## Game details switches")
        let switches = LibraryPrefs.sharedSwitches(entry.windowsPath)
        lines.append(json(switches) ?? "(none)")
        lines.append("")
        lines.append("## Library entry (display, launch, Steam and controller fields)")
        if let encoded = try? JSONEncoder().encode(entry),
           let fields = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
            lines.append(json(fields.filter { !skippedEntryKeys.contains($0.key) }) ?? "(could not be read)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func json(_ value: [String: Any]) -> String? {
        guard !value.isEmpty, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A file name from a game title: no slashes or colons, at most 60 characters.
    static func safeName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Game" : String(cleaned.prefix(60))
    }
}

/// The share sheet's items, for `.sheet(item:)`.
struct ClaudeHelpFiles: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// "Get Help from Claude": a button and its share sheet. The file is made in
/// the background (it reads the log), with a spinner meanwhile.
struct ClaudeHelpButton: View {
    let entry: LibraryEntry?
    @State private var files: ClaudeHelpFiles?
    @State private var preparing = false
    var body: some View {
        Button {
            guard !preparing else { return }
            preparing = true
            let entry = entry
            let game = entry.map(ClaudeHelp.gameText)
            let device = ClaudeHelp.deviceLine()
            DispatchQueue.global(qos: .userInitiated).async {
                let urls = ClaudeHelp.files(for: entry, game: game, device: device)
                DispatchQueue.main.async {
                    preparing = false
                    if !urls.isEmpty { files = ClaudeHelpFiles(urls: urls) }
                }
            }
        } label: {
            HStack {
                Label("Get Help from Claude", systemImage: "questionmark.bubble")
                if preparing { Spacer(); ProgressView() }
            }
        }
        .disabled(preparing)
        .sheet(item: $files) { ActivitySheet(items: $0.urls) }
    }
}

extension ClaudeHelp {
    /// Model, system and memory: what the guide's fixes depend on. No names or identifiers.
    static func deviceLine() -> String {
        let process = ProcessInfo.processInfo
        return "\(DeviceDiagnostics.machine()), \(UIDevice.current.systemName) \(process.operatingSystemVersionString), "
            + "\(process.physicalMemory >> 20) MB RAM"
    }
}

// MARK: The newest guide from the Get Help server

extension ClaudeHelp {
    /// The server's newest guide, kept between runs (not in Documents: the Documents copy is the one to share).
    static let downloadedName = "claude-guide-newest.txt"
    static var downloaded: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(downloadedName)
    }
    /// How long the button waits for the server before using the guide it has.
    static let guideTimeout: TimeInterval = 4
    /// The server's guide is about 48 KB; anything far bigger is not a guide.
    static let guideMaxBytes = 200_000

    /// "Updated 2026-11-07." near the top -> "2026-11-07".
    static func updatedDate(_ text: String) -> String? {
        guard let r = text.range(of: #"Updated \d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return nil }
        return String(text[r].dropFirst("Updated ".count))
    }

    /// The text of a server reply when it really is a filled-in guide.
    static func validGuide(_ data: Data) -> String? {
        guard data.count >= 1_000, data.count <= guideMaxBytes,
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("MADEIRA HELP GUIDE FOR CLAUDE"), updatedDate(text) != nil,
              !text.contains("{{") else { return nil }
        return text
    }

    /// The newer guide by its "Updated" date; the server's on a tie (it is made from the newer index).
    static func newer(bundled: String?, downloaded: String?) -> String? {
        guard let d = downloaded, let dd = updatedDate(d) else { return bundled }
        guard let b = bundled, let bd = updatedDate(b) else { return d }
        return dd >= bd ? d : b
    }

    /// The guide to use: the bundled one, or the server's when it is as new or newer.
    static func bestGuide() -> String {
        let b = bundled.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let d = downloaded.flatMap { try? Data(contentsOf: $0) }.flatMap(validGuide)
        return newer(bundled: b, downloaded: d) ?? ""
    }

    private final class Reply: @unchecked Sendable {
        var data: Data?
        var status = 0
    }

    /// Asks the Get Help server for its newest guide and keeps it when it is one.
    /// Waits at most guideTimeout seconds, so call it off the main thread only.
    static func fetchNewest() {
        guard GetHelp.enabled, let key = GetHelp.key, let target = downloaded else { return }
        var request = URLRequest(url: GetHelpCore.server.appendingPathComponent("guide"), timeoutInterval: guideTimeout)
        request.setValue(key, forHTTPHeaderField: "x-madeira-key")
        let reply = Reply()
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            reply.data = data
            reply.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + guideTimeout + 1) == .timedOut {
            task.cancel()
            LogStore.shared.log("[claude-help] newest guide: no answer in \(Int(guideTimeout)) s, using the one we have")
            return
        }
        guard reply.status == 200, let data = reply.data, let text = validGuide(data) else {
            LogStore.shared.log("[claude-help] newest guide: not used (status \(reply.status), \(reply.data?.count ?? 0) bytes)")
            return
        }
        if (try? Data(contentsOf: target)) == data { return }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            LogStore.shared.log("[claude-help] newest guide: kept, updated \(updatedDate(text) ?? "?") (\(data.count) bytes)")
        } catch {
            LogStore.shared.log("[claude-help] newest guide: could not keep it: \(error.localizedDescription)", level: .error)
        }
    }
}
