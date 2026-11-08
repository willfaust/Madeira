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
//  Diagnostics share the file through the system share sheet. Nothing is sent
//  anywhere by Madeira itself.
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

    /// Documents/Give-to-Claude-with-log-and-cfg.txt, the bundled guide; written
    /// again whenever it differs (a new build brings a newer guide).
    static func install() {
        DispatchQueue.global(qos: .utility).async {
            guard let source = ClaudeHelp.bundled, let docs = ClaudeHelp.documents,
                  let data = try? Data(contentsOf: source) else { return }
            let target = docs.appendingPathComponent(ClaudeHelp.fileName)
            if (try? Data(contentsOf: target)) == data { return }
            do {
                try data.write(to: target, options: .atomic)
                LogStore.shared.log("[claude-help] guide written to Documents/\(ClaudeHelp.fileName) (\(data.count) bytes)")
            } catch {
                LogStore.shared.log("[claude-help] could not write the guide: \(error.localizedDescription)", level: .error)
            }
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
        install()
        let fm = FileManager.default
        guard let docs = documents else { return [] }
        let folder = fm.temporaryDirectory.appendingPathComponent("ClaudeHelp", isDirectory: true)
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let guideFile = docs.appendingPathComponent(fileName)
        let guide = (try? String(contentsOf: guideFile, encoding: .utf8))
            ?? bundled.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let log = chosenLog(in: docs).map(HelpReport.read)
        let cfg = try? String(contentsOf: docs.appendingPathComponent(MadeiraConfig.fileName), encoding: .utf8)
        let report = HelpReport.text(build: BuildStamp.text, device: device, log: log,
                                     game: game, cfg: cfg)
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
