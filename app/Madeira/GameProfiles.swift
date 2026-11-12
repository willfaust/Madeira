//
//  GameProfiles.swift
//  Madeira
//
//  madeira-bcd: a game's own settings file -- Winlator's per-shortcut
//  overrides, in this app's terms.
//
//  Same syntax as Documents/madeira.cfg (key = value, env.NAME = value, # for
//  comments). The launch exports its path as MADEIRA_CFG_GAME; the native
//  reader (build/madeira_cfg.h) lets a key set here win over madeira.cfg, and
//  WineProcessBridge exports its env.* lines after madeira.cfg's. So any
//  runtime switch -- a D3D12 experiment, a FEX option, a DXMT setting -- can be
//  set for one game without touching the others, and without a new build.
//
//  Game details › This game's config edits the file.
//

import Foundation

struct GameProfile {
    let windowsPath: String

    static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("GameConfigs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var url: URL? {
        GameProfile.directory?.appendingPathComponent(
            String(format: "%016llx.cfg", LibraryPrefs.stableHash(windowsPath.lowercased())))
    }

    /// The whole file ("" when there is none). Setting "" deletes it.
    var text: String {
        get {
            guard let u = url, let t = try? String(contentsOf: u, encoding: .utf8) else { return "" }
            return t
        }
        nonmutating set {
            guard let u = url else { return }
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? FileManager.default.removeItem(at: u)
            } else {
                try? (newValue.hasSuffix("\n") ? newValue : newValue + "\n").write(to: u, atomically: true, encoding: .utf8)
            }
        }
    }

    /// key -> value, the last line winning, as the native reader does.
    var values: [String: String] { GameProfile.parse(text) }

    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    /// True when the file sets anything at all.
    var hasSettings: Bool { !values.isEmpty }
}

// (debug-logging) Game details › Advanced › Debug logging: a test-bundle-only switch that writes a
// ready-made set of logging lines into THIS game's own config (never madeira.cfg). The lines are the
// game's ordinary `env.NAME = value` lines, with no comment and no marker: the level is read back
// from which of these exact lines are present, and changing the level (or Off) removes exactly these
// lines and nothing else. They are written last, so they win over an earlier line for the same key.
enum DebugLogging {
    /// Only this bundle shows the setting; a release build never does.
    static let testBundleID = "com.willfaust.madeora.test"
    static var available: Bool { Bundle.main.bundleIdentifier == testBundleID }

    enum Level: Int, CaseIterable, Identifiable {
        case off, low, medium, high
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .off: return "Off"
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            }
        }

        var summary: String {
            switch self {
            case .off: return "Adds nothing: this game logs as usual."
            case .low: return "Copies every guest text-log line (up to 3000) into the log."
            case .medium: return "Low, plus reports of code patches the emulated copy misses and of image-protection patches."
            case .high: return "Medium, plus file open/query and Social Club pipe traces. Can slow the game and make big logs."
            }
        }

        /// The lines this level adds on its own, on top of the level below.
        fileprivate var own: [(key: String, value: String)] {
            switch self {
            case .off: return []
            case .low: return [("env.MADEIRA_GUEST_LOG", "all"), ("env.MADEIRA_GUEST_LOG_LIMIT", "3000")]
            case .medium: return [("env.MADEIRA_EC_HOOK_TRACE", "1"), ("env.MADEIRA_IMAGE_PATCH_TRACE", "1")]
            case .high: return [("env.MADEIRA_PIPE_TRACE", "1"), ("env.MADEIRA_PIPE_TRACE_LIMIT", "5000"),
                                ("env.MADEIRA_FILE_TRACE", "1"), ("env.MADEIRA_FILE_TRACE_LIMIT", "20000")]
            }
        }

        /// Every line of this level, lower levels first.
        var lines: [(key: String, value: String)] {
            Level.allCases.filter { $0.rawValue >= 1 && $0.rawValue <= rawValue }.flatMap { $0.own }
        }
    }

    private static func pair(_ line: String) -> (key: String, value: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        let k = t[..<eq].trimmingCharacters(in: .whitespaces)
        let v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return k.isEmpty ? nil : (k, v)
    }

    private static func lineSet(_ level: Level) -> Set<String> { Set(level.lines.map { "\($0.key) = \($0.value)" }) }

    /// The highest level whose lines are all in `text` (Off when none, or only part of Low).
    static func level(of text: String) -> Level {
        let present = Set(text.split(whereSeparator: \.isNewline).compactMap { pair(String($0)) }.map { "\($0.key) = \($0.value)" })
        return Level.allCases.reversed().first { $0 == .off || lineSet($0).isSubset(of: present) } ?? .off
    }

    /// `text` with every line this setting writes removed, then `level`'s lines added at the end.
    /// All other lines (and comments) stay as they were.
    static func apply(_ level: Level, to text: String) -> String {
        let managed = lineSet(.high)
        var kept = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init).filter { line in
            guard let p = pair(line) else { return true }
            return !managed.contains("\(p.key) = \(p.value)")
        }
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }
        kept += level.lines.map { "\($0.key) = \($0.value)" }
        return kept.joined(separator: "\n")
    }

    /// A short fingerprint of the game's config text, so two logs can say they ran the same config.
    static func configHash(_ text: String) -> String {
        let normalized = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return String(format: "%08x", UInt32(truncatingIfNeeded: LibraryPrefs.stableHash(normalized)))
    }

    static func lineCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline).filter { pair(String($0)) != nil }.count
    }

    /// The stamp for a run's log: nil unless this is the test bundle and Debug logging is not Off.
    static func stamp(windowsPath: String) -> String? {
        guard available else { return nil }
        let text = GameProfile(windowsPath: windowsPath).text
        let level = level(of: text)
        guard level != .off else { return nil }
        return "Debug logging \(level.title) · game config \(configHash(text)) (\(lineCount(text)) lines)"
    }

    /// The Copy debug info text: game, build, level and the game's own config.
    static func debugInfo(title: String, windowsPath: String, recommended: String? = nil) -> String {
        let text = GameProfile(windowsPath: windowsPath).text
        let info = Bundle.main.infoDictionary ?? [:]
        let number = info["CFBundleVersion"] as? String ?? "?"
        return """
        Game: \(title)
        Build: \(BuildStamp.text) (build \(number), \(Bundle.main.bundleIdentifier ?? "?"))
        Debug logging: \(level(of: text).title)
        Game config: \(configHash(text)) (\(lineCount(text)) lines)
        --- Differences from Madeira's Recommended settings ---
        \(diffText(config: text, recommended: recommended))
        --- This game's config ---
        \(text.isEmpty ? "(empty)" : text)
        """
    }

    // MARK: Config diff against Madeira's Recommended settings (Copy debug info)

    /// The effective `key = value` pairs (the last line for a key wins, as the config reader does), in first-seen order.
    private static func effective(_ text: String) -> [(key: String, value: String)] {
        var order: [String] = [], values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let p = pair(String(raw)) else { continue }
            if values[p.key] == nil { order.append(p.key) }
            values[p.key] = p.value
        }
        return order.map { ($0, values[$0] ?? "") }
    }

    /// The config lines that differ from the recommended list: a different value, a line the list doesn't have
    /// (marked when Debug logging wrote it), and a recommended line this config lacks.
    static func configDiff(config: String, recommended: String) -> [String] {
        let mine = effective(config), rec = effective(recommended)
        let mineValues = Dictionary(mine.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        let recValues = Dictionary(rec.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        let managed = lineSet(.high)
        var out: [String] = []
        for (k, v) in mine {
            if let r = recValues[k] {
                if r != v { out.append("changed: \(k) = \(v)   (recommended: \(r))") }
            } else {
                out.append("added:   \(k) = \(v)" + (managed.contains("\(k) = \(v)") ? "   (Debug logging)" : "   (not in the recommended list)"))
            }
        }
        for (k, r) in rec where mineValues[k] == nil { out.append("missing: \(k)   (recommended: \(k) = \(r))") }
        return out
    }

    /// The section's body: nil `recommended` means Madeira has no list for this game.
    static func diffText(config: String, recommended: String?) -> String {
        guard let recommended else { return "(Madeira has no recommended list for this game)" }
        let diff = configDiff(config: config, recommended: recommended)
        return diff.isEmpty ? "(none: the config matches the recommended list)" : diff.joined(separator: "\n")
    }

    // MARK: Reset to clean state

    /// `text` without the Debug logging lines and without the lines Get Help added (`getHelpAdded`, what Get Help's
    /// own record holds, taken out by Get Help's own undo). Every other line and comment stays.
    static func cleaned(_ text: String, getHelpAdded: [String]) -> String {
        apply(.off, to: getHelpAdded.isEmpty ? text : GetHelpCore.undo(getHelpAdded, from: text))
    }

    /// How many setting lines Reset to clean state would take out: (Debug logging, Get Help).
    static func cleanCounts(windowsPath: String) -> (debug: Int, getHelp: Int) {
        let text = GameProfile(windowsPath: windowsPath).text
        let added = GetHelp.record(windowsPath)?.added ?? []
        let afterHelp = added.isEmpty ? text : GetHelpCore.undo(added, from: text)
        return (lineCount(afterHelp) - lineCount(apply(.off, to: afterHelp)), lineCount(text) - lineCount(afterHelp))
    }

    /// Takes Get Help's added lines out through Get Help's own Undo (so its record goes the same way), then the
    /// Debug logging lines, in this game's own config only. Returns what was removed.
    @discardableResult
    static func resetToClean(windowsPath: String, title: String) -> (debug: Int, getHelp: Int) {
        let counts = cleanCounts(windowsPath: windowsPath)
        if GetHelp.record(windowsPath) != nil { GetHelp.undo(windowsPath: windowsPath, title: title) }
        let file = GameProfile(windowsPath: windowsPath)
        let before = file.text
        let after = apply(.off, to: before)
        if after != before { file.text = after }
        LogStore.shared.log("[debug-log] reset \(title) to a clean state: \(counts.debug) Debug logging line(s) and \(counts.getHelp) Get Help line(s) taken out of its config")
        return counts
    }

    // MARK: Share this game's logs

    /// One .zip of this game's last run (scrubbed) and its own config (scrubbed). Off the main thread.
    static func shareZip(title: String, windowsPath: String) -> URL? {
        let run = LogRuns.lastRunText(game: title, maxBytes: 1_500_000)
        let config = GameProfile(windowsPath: windowsPath).text
        let safe = String(title.map { "/\\:?*\"<>|".contains($0) ? "-" : $0 }.prefix(60)).trimmingCharacters(in: .whitespaces)
        let url = LogFiles.shareFolder.appendingPathComponent((safe.isEmpty ? "Game" : safe) + " logs.zip")
        try? FileManager.default.removeItem(at: url)
        do {
            let zip = try LogZip(url: url)
            try zip.add(name: "game-run.txt", data: Data(PrivacyScrub.text(run ?? "(No run of \(title) found in Madeira's logs.)").utf8))
            try zip.add(name: "game-config.txt", data: Data(PrivacyScrub.text(config.isEmpty ? "(empty)" : config).utf8))
            try zip.finish()
        } catch {
            LogStore.shared.log("[debug-log] could not write \(url.lastPathComponent): \(error)", level: .error)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        LogStore.shared.log("[debug-log] share \(url.lastPathComponent): game-run.txt (\(run?.utf8.count ?? 0) bytes) + game-config.txt, scrubbed")
        return url
    }
}
