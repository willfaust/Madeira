// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Get Help from Claude: a short guide to every known Madeira fix and setting
//  (Give-to-Claude-with-log-and-cfg.txt, bundled with the app), handed to a
//  chat together with the session log, the summary and the game's config, so
//  a fresh Claude chat on anyone's phone can troubleshoot their game.
//
//  The guide is copied into Documents at every start, beside madeira-log.txt,
//  so it can also be shared from the Files app. Game details and Settings ›
//  Diagnostics share it with the log files through the system share sheet.
//  Nothing is sent anywhere by Madeira itself.
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

    /// What to share: the guide, the summary, the logs, madeira.cfg and, for a
    /// game, a text file with its config and Game details settings.
    static func files(for entry: LibraryEntry?) -> [URL] {
        install()
        let fm = FileManager.default
        guard let docs = documents else { return [] }
        let folder = fm.temporaryDirectory.appendingPathComponent("ClaudeHelp", isDirectory: true)
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var out: [URL] = []
        let guide = docs.appendingPathComponent(fileName)
        if fm.fileExists(atPath: guide.path) { out.append(guide) } else if let copy = bundled { out.append(copy) }

        if let entry {
            let name = safeName(entry.title) + " - game cfg and settings.txt"
            let file = folder.appendingPathComponent(name)
            if (try? gameText(entry).write(to: file, atomically: true, encoding: .utf8)) != nil { out.append(file) }
        }
        // Chats take .txt files more readily than .cfg ones.
        let cfg = docs.appendingPathComponent(MadeiraConfig.fileName)
        let cfgCopy = folder.appendingPathComponent("madeira.cfg.txt")
        if let text = try? String(contentsOf: cfg, encoding: .utf8),
           (try? ("# Documents/madeira.cfg (global settings)\n" + text).write(to: cfgCopy, atomically: true, encoding: .utf8)) != nil {
            out.append(cfgCopy)
        }
        // The logs are shared where they are: they can be tens of MB.
        for log in [LogSummary.fileName, "madeira-log.txt", "madeira-log.prev.txt"] {
            let url = docs.appendingPathComponent(log)
            if fm.fileExists(atPath: url.path) { out.append(url) }
        }
        LogStore.shared.log("[claude-help] share: \(out.map(\.lastPathComponent).joined(separator: ", "))")
        return out
    }

    /// The game's own config, then its Game details settings, as plain text.
    static func gameText(_ entry: LibraryEntry) -> String {
        var lines = [
            "# \(entry.title): this game's config and settings, for Claude",
            "# Program: \(entry.windowsPath)",
            "# Bits: \(entry.bits)",
        ]
        if let appID = entry.steamAppID { lines.append("# Steam App ID: \(appID)") }
        lines.append("# Madeira build: \(BuildStamp.text)")
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

/// "Get Help from Claude": a button and its share sheet.
struct ClaudeHelpButton: View {
    let entry: LibraryEntry?
    @State private var files: ClaudeHelpFiles?
    var body: some View {
        Button("Get Help from Claude", systemImage: "questionmark.bubble") {
            files = ClaudeHelpFiles(urls: ClaudeHelp.files(for: entry))
        }
        .sheet(item: $files) { ActivitySheet(items: $0.urls) }
    }
}
