// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  The player's half of Get Help from Claude's one file (ClaudeHelp.swift):
//  device and build, the session summary, the game's settings and the log
//  lines that explain a problem, instead of the whole log.
//
//  A session log is 1 to 20 MB. Shared whole, it fills a free Claude plan's
//  chat after one message, or the chat app refuses it. Nearly all of it is
//  periodic diagnostics ([xp], [valloc], [thread-stacks], fixme: lines and
//  the like). Over the 122 logs players posted in Discord from Oct 30 to
//  Nov 5, 2026, the lines below came to 20 to 34 KB per log, and they keep
//  what those reports turned on: the [build] and [device] lines, settings
//  that applied, JIT pool trouble, missing DLLs, Windows error codes,
//  "unimplemented function", Madeira Dock's results and how the game ended.
//
//  Key lines: every line with one of `keyTags`, a repeat (numbers and
//  addresses aside) counted as "(xN)" instead of written again. Tail: the
//  last lines before Wine exited, or before the log ended when it didn't.
//  Everything goes through PrivacyScrub before it is shared.
//

import Foundation

enum HelpReport {
    /// Lines worth keeping (matched lower-cased): the tags of the guide's
    /// section 6 "Reading the log", plus plain error words.
    static let keyTags: [String] = [
        "[build]", "[device]", "[library]", "[game-cfg]", "[madeira-env]", "[will-it-run]", "[session-log]",
        "jit pool", "[jit-pool] exhausted", "small jit", "[pool-split]",
        "[dll-missing]", "[dock-", "[steam-env]", "[steam-host]", "[wineproc] target exe", "[wineproc] the main",
        "[wineproc] wine exited", "child exited", "[exit-report]", "unhandled", "unimplemented", "not implemented",
        "c000001d", "c0000005", "c0000017", "c0000018", "c0000135", "c0000409", "c000007b",
        "[wow-window]", "[exec-recover]", "[x64-image]", "[wow-rwx]", "[redeliv]", "[swap]", "[thermal",
        "[bg-run]", "[wine-mono]", "[wine-gecko]", "[hard-error]", "[map-fail]", "[freeze] gap",
        "[err]", " error", "error:", "failed", "fatal", "abort", "crash", "exception",
    ]

    /// Periodic diagnostics: never key lines and never in the tail.
    static let noiseTags: [String] = [
        "[xp]", "[xp-t]", "[xp-api", "[xp-names]", ":fixme:", "[thread-stacks]", "[valloc]", "[vfree]", "[evt-",
        "[srv-stuck]", "[srv-own]", "[srv-queues]", "[mach-deliver]", "[mach_exc]", "[waiters]", "[winios",
        "[placed]", "[thread-sample]", "[xlate-exec]", "[alert-ring]", "[footprint]", "[freeze] alive",
        "[ios_audio]", "[hwinput]", "[bigres-use]", "[draw-dump]", "[fdtrace]", "[x18-", "[cs-life]",
        "[mem-census]", "[span-census]", "[bc-census]", "[rip-profile]",
    ]

    /// Wine ended: the tail is taken here, so idle lines after the game don't push the end out.
    static let endMarkers = ["[wineproc] wine exited", "[wineproc] the main process exited"]

    static let maxKeyLines = 200
    static let keptFromStart = 50
    static let maxKeyBytes = 30_000
    static let tailCount = 150
    static let maxTailBytes = 18_000
    static let lineWidth = 220

    struct LogPart {
        var name = ""
        var key: [String] = []
        var tail: [String] = []
        var tailEndsAtExit = false
        var lines = 0
        var noise = 0
        var keyFound = 0
        var facts = LogSummary.Facts()
    }

    private static let numbers = try! NSRegularExpression(
        pattern: #"0x[0-9A-Fa-f]+|\b(?=[0-9A-Fa-f]*[0-9])[0-9A-Fa-f]{4,}\b|[0-9]+"#)

    /// A line with its time stamp, thread id, numbers and addresses taken out:
    /// repeats of one message differ only in those.
    static func normalized(_ line: String) -> String {
        var s = Substring(line)
        if s.hasPrefix("["), let close = s.firstIndex(of: "]"), s.distance(from: s.startIndex, to: close) <= 14 {
            s = s[s.index(after: close)...].drop { $0 == " " }
        }
        let text = String(s)
        return numbers.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "#")
    }

    static func clipped(_ line: String) -> String {
        line.count > lineWidth ? String(line.prefix(lineWidth)) + " ..." : line
    }

    /// One pass over the log: key lines, the tail and LogSummary's facts.
    static func read(_ url: URL) -> LogPart {
        var part = LogPart(name: url.lastPathComponent)
        var reader = LogSummary.Reader()
        var entries: [(text: String, count: Int)] = []
        var index: [String: Int] = [:]
        var ring: [String] = []
        ring.reserveCapacity(tailCount)
        var ringStart = 0
        var atExit: [String]?
        let harmless = LogSummary.harmlessDLLs

        LogLines.forEach(in: url) { line in
            part.lines += 1
            reader.feed(line)
            let lower = line.lowercased()
            if noiseTags.contains(where: { lower.contains($0) }) { part.noise += 1; return }

            if ring.count < tailCount { ring.append(clipped(line)) } else { ring[ringStart] = clipped(line); ringStart = (ringStart + 1) % tailCount }
            if endMarkers.contains(where: { lower.contains($0) }) {
                atExit = Array(ring[ringStart...] + ring[..<ringStart])
            }

            guard keyTags.contains(where: { lower.contains($0) }) else { return }
            if lower.contains("[dll-missing]"), harmless.contains(where: { lower.contains($0) }) { return }
            part.keyFound += 1
            let key = normalized(line)
            if let i = index[key] {
                entries[i].count += 1
            } else if entries.count < 50_000 {
                index[key] = entries.count
                entries.append((clipped(line), 1))
            }
        }

        var key = entries.map { $0.count > 1 ? "\($0.text) (x\($0.count))" : $0.text }
        if key.count > maxKeyLines {
            let skipped = key.count - maxKeyLines
            key = Array(key.prefix(keptFromStart)) + ["... \(skipped) more key lines left out here ..."]
                + Array(key.suffix(maxKeyLines - keptFromStart))
        }
        // Over the byte budget: drop from the middle, keeping the start (device,
        // settings) and the end (how it failed).
        var bytes = key.reduce(0) { $0 + $1.utf8.count + 1 }
        var dropped = 0
        while bytes > maxKeyBytes, key.count > keptFromStart + 2 {
            bytes -= key[keptFromStart + 1].utf8.count + 1
            key.remove(at: keptFromStart + 1)
            dropped += 1
        }
        if dropped > 0 { key.insert("... \(dropped) more key lines left out here ...", at: keptFromStart + 1) }
        part.key = key

        var tail = atExit ?? Array(ring[ringStart...] + ring[..<ringStart])
        var tailBytes = tail.reduce(0) { $0 + $1.utf8.count + 1 }
        while tailBytes > maxTailBytes, !tail.isEmpty { tailBytes -= tail.removeFirst().utf8.count + 1 }
        part.tail = tail
        part.tailEndsAtExit = atExit != nil
        part.facts = reader.facts
        return part
    }

    /// (log-fixes) "The Escapists 2 (TheEscapists2.exe)"; without a game program in the log, says so.
    static func gameLine(title: String, program: String?, hasLog: Bool) -> String {
        if let program { return "\(title) (\(program))" }
        return title + (hasLog ? " (its program did not start in this log)" : " (no log yet)")
    }

    /// madeira.cfg without comments and blank lines.
    static func settingLines(_ cfg: String) -> String {
        let lines = cfg.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix(";") }
        return lines.isEmpty ? "(no settings: all defaults)" : lines.joined(separator: "\n")
    }

    /// The player's report, scrubbed. `game` is the game's settings text (ClaudeHelp.gameText).
    /// `title` (log-fixes): the Library game the player asked about, named in the header even when
    /// its program never started (the log then only has Madeira's start steps or a helper program).
    static func text(build: String, device: String, log: LogPart?, game: String?, cfg: String?, title: String? = nil) -> String {
        var out: [String] = [
            "==========================================================================",
            "PLAYER'S REPORT",
            "==========================================================================",
            "Madeira build: \(build)",
            "Device: \(device)",
        ]
        if let title, !title.isEmpty {
            out.append("Game in this report: " + gameLine(title: PrivacyScrub.text(title), program: log?.facts.game, hasLog: log != nil))
            if let log { out.append("Log: \(log.name), \(log.lines) lines. Only the lines that usually explain a problem are below.") }
        } else if let log {
            out.append("Game in this report: \(log.facts.game ?? "none (this log has no game in it)")")
            out.append("Log: \(log.name), \(log.lines) lines. Only the lines that usually explain a problem are below.")
        } else {
            out.append("Game in this report: none (no log yet)")
        }
        out.append("Personal details were replaced with <user>, <email>, <ip>, <steam-id>, <hidden> and similar markers.")
        out.append("")
        if let log, log.facts.sawSession {
            out.append("## Session summary")
            out.append(LogSummary.text(log.facts, source: log.name).trimmingCharacters(in: .newlines))
            out.append("")
        }
        if let game {
            out.append(game.trimmingCharacters(in: .newlines))
            out.append("")
        }
        out.append("## madeira.cfg (global settings; comments left out)")
        out.append(cfg.map(settingLines) ?? "(no madeira.cfg)")
        out.append("")
        if let log {
            out.append("## Key log lines (\(log.keyFound) found, repeats counted as xN; \(log.noise) periodic diagnostic lines skipped)")
            out += log.key.isEmpty ? ["(none)"] : log.key
            out.append("")
            out.append(log.tailEndsAtExit ? "## Last lines before Wine exited" : "## Last lines of the log")
            out += log.tail
        }
        return PrivacyScrub.text(out.joined(separator: "\n")) + "\n"
    }
}
