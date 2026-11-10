// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  madeira-get-help-files: Get Help looks closer by itself. The player only taps Get
//  Help (Cameron, Nov 8: "I don't want the user to have to do anything except click
//  Get Help"). The first request says which of these files the app can collect
//  (can_send); when the report alone can't settle it, the server's answer names up to
//  two (need). The app then reads them, takes personal details out (PrivacyScrub), and
//  asks once more with them (follow_up + files) while the screen says it is looking
//  closer. That second answer is the one shown; if it fails, the first one is.
//
//  Foundation only (the readers take folders, not app state), so the host check can
//  compile it on Linux. GetHelpSheet finds the folders (places(for:title:)).
//
//  steam_libraries  the Dock Steam client's config/ and steamapps/libraryfolders.vdf
//  steam_logs       the end of its logs/service_log.txt, bootstrap_log.txt, content_log.txt
//  game_folder      the game's folder: file names and sizes, 3 levels, at most 400
//  game_settings    the game's own small .ini/.cfg/.json/.xml files near it (6 at most)
//  full_log         the end of the game's last run, every line
//

import Foundation

enum GetHelpFiles {
    static let kinds = ["steam_libraries", "steam_logs", "game_folder", "game_settings", "full_log"]
    /// The server takes each file up to 24,000 characters and all of them up to 48,000.
    static let maxFile = 23_000

    /// Where the files are. runLog is a function: finding the game's last run reads the logs.
    struct Places {
        var steamRoot: URL?
        var gameFolder: URL?
        var runLog: () -> URL?
        var hasRun: Bool
    }

    /// The kinds this device can send now (the first request's can_send).
    static func available(_ places: Places) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        if let root = places.steamRoot, fm.fileExists(atPath: root.path) { out += ["steam_libraries", "steam_logs"] }
        if let folder = places.gameFolder, fm.fileExists(atPath: folder.path) { out += ["game_folder", "game_settings"] }
        if places.hasRun { out.append("full_log") }
        return out
    }

    /// The asked-for files that could be read, scrubbed. Reads files, so off the main thread.
    static func collect(_ need: [String], at places: Places, scrub: (String) -> String) -> [GetHelpCore.ExtraFile] {
        var out: [GetHelpCore.ExtraFile] = []
        for kind in need.prefix(2) where kinds.contains(kind) && !out.contains(where: { $0.kind == kind }) {
            var text: String?
            switch kind {
            case "steam_libraries": text = places.steamRoot.flatMap(steamLibraries)
            case "steam_logs": text = places.steamRoot.flatMap(steamLogs)
            case "game_folder": text = places.gameFolder.flatMap(gameFolder)
            case "game_settings": text = places.gameFolder.flatMap(gameSettings)
            case "full_log": text = places.runLog().flatMap { tail($0, max: maxFile) }
            default: break
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            out.append(GetHelpCore.ExtraFile(kind: kind, text: cut(scrub(text))))
        }
        return out
    }

    // MARK: Readers

    static func steamLibraries(_ root: URL) -> String? {
        let parts = ["config", "steamapps"].compactMap { sub -> String? in
            guard let dir = child(root, sub), let vdf = child(dir, "libraryfolders.vdf"),
                  let text = tail(vdf, max: 8_000) else { return nil }
            return "### \(sub)/libraryfolders.vdf\n" + text
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    static func steamLogs(_ root: URL) -> String? {
        guard let logs = child(root, "logs") else { return nil }
        let parts = ["service_log.txt", "bootstrap_log.txt", "content_log.txt"].compactMap { name -> String? in
            guard let file = child(logs, name), let text = tail(file, max: 7_000) else { return nil }
            return "### logs/\(name) (end)\n" + text
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    static func gameFolder(_ folder: URL) -> String? {
        var lines: [String] = []
        var total = 0
        walk(folder, depth: 3) { relative, size, isDir in
            total += 1
            if lines.count < 400 { lines.append(isDir ? relative + "/" : "\(relative)  \(bytes(size))") }
        }
        guard !lines.isEmpty else { return nil }
        if total > lines.count { lines.append("... \(total - lines.count) more not listed") }
        return "### \(folder.lastPathComponent)/\n" + lines.joined(separator: "\n")
    }

    static let settingsExtensions: Set<String> = ["ini", "cfg", "json", "xml"]

    static func gameSettings(_ folder: URL) -> String? {
        var found: [(String, URL)] = []
        walk(folder, depth: 4) { relative, size, isDir in
            guard !isDir, found.count < 6, size > 0, size <= 8_000 else { return }
            let url = folder.appendingPathComponent(relative)
            guard settingsExtensions.contains(url.pathExtension.lowercased()) else { return }
            found.append((relative, url))
        }
        let parts = found.compactMap { relative, url -> String? in
            guard let data = try? Data(contentsOf: url), !data.contains(0) else { return nil }   // text files only
            return "### \(relative)\n" + String(decoding: data, as: UTF8.self)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: Helpers

    /// The last `max` bytes of a file, from the start of a line.
    static func tail(_ url: URL, max: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(max) ? size - UInt64(max) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return text
    }

    /// A file's end when it is too long (the end says how it failed).
    static func cut(_ text: String) -> String {
        guard text.count > maxFile else { return text }
        return "... start left out ...\n" + String(text.suffix(maxFile - 30))
    }

    /// `name` in `dir`, any letter case (Windows names).
    static func child(_ dir: URL, _ name: String) -> URL? {
        let exact = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              let match = names.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return dir.appendingPathComponent(match)
    }

    /// Every entry under `folder` up to `depth` levels, sorted, not following links out.
    static func walk(_ folder: URL, depth: Int, _ visit: (String, Int, Bool) -> Void) {
        let fm = FileManager.default
        var seen = 0
        func go(_ dir: URL, _ prefix: String, _ level: Int) {
            guard level < depth, seen < 5_000, let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where !name.hasPrefix(".") {
                seen += 1
                if seen >= 5_000 { return }
                let url = dir.appendingPathComponent(name)
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                let isDir = values?.isDirectory == true
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                visit(relative, values?.fileSize ?? 0, isDir)
                if isDir, values?.isSymbolicLink != true { go(url, relative, level + 1) }
            }
        }
        go(folder, "", 0)
    }

    static func bytes(_ n: Int) -> String {
        if n >= 1 << 30 { return String(format: "%.1f GB", Double(n) / Double(1 << 30)) }
        if n >= 1 << 20 { return String(format: "%.1f MB", Double(n) / Double(1 << 20)) }
        if n >= 1 << 10 { return String(format: "%.0f KB", Double(n) / Double(1 << 10)) }
        return "\(n) B"
    }

    /// The game's folder from its program path (relative to drive_c): the Steam game's own
    /// folder under steamapps/common when it is in one, otherwise the program's folder.
    static func gameFolder(drive: URL, relativePath: String) -> URL? {
        let parts = relativePath.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts.contains("..") else { return nil }
        if let i = parts.firstIndex(where: { $0.caseInsensitiveCompare("common") == .orderedSame }),
           i > 0, parts[i - 1].caseInsensitiveCompare("steamapps") == .orderedSame, i + 1 < parts.count - 1 {
            return parts[...(i + 1)].reduce(drive) { $0.appendingPathComponent($1) }
        }
        return parts.dropLast().reduce(drive) { $0.appendingPathComponent($1) }
    }
}
