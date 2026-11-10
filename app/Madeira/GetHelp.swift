// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  madeira-get-help: the Get Help button's talk with Madeira's help server, and
//  what Apply and Undo do to a game's own config. Foundation only, so the host
//  check (tests/host/check-get-help.py) compiles this file with swiftc on Linux.
//  The screens are in GetHelpView.swift.
//
//  A player taps Get Help on a game's page, or on the offer Madeira makes after
//  a game stopped by itself. Madeira sends the same scrubbed report that Get
//  Help from Claude shares (HelpReport.swift, PrivacyScrub.swift) to the server
//  (get-help-server/ in the project files: a Cloudflare Worker that asks Claude
//  Haiku with every known fix in its prompt). The server answers in plain words,
//  with up to four steps and, sometimes, setting lines for that game. Each line
//  was checked there against the per-game settings the app knows.
//
//  Apply adds the lines at the end of the game's own config (Game details ›
//  Advanced › This game's config), under a comment that says Get Help added
//  them; the last line wins, so they take over from earlier ones with the same
//  key. Nothing in madeira.cfg changes. Undo takes exactly those lines out again.
//
//  POST /help     {install_id, game, app_version, reason, report, keep_report, keep_policy}
//                 -> {ok, request_id, kind, answer, steps, config: {lines, text} | null, confidence}
//                 or {ok: false, error, message}: message is plain words, shown as is.
//                 (get-help-files) can_send: the files the app can collect by itself; the answer's
//                 need names up to 2, and the app asks again with follow_up + files (GetHelpFiles.swift).
//  POST /feedback {request_id, helped}
//  POST /upload   (sentry-full-log) a .zip of the full scrubbed logs, header x-request-id
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum GetHelpCore {
    static let server = URL(string: "https://madeira-get-help.camhocnote4.workers.dev")!
    /// The server takes reports up to 64 KB; this leaves room for the rest of the request.
    static let maxReport = 60_000
    /// Haiku answers in about 3 seconds; the server retries twice when the API is busy.
    static let timeout: TimeInterval = 60

    struct Request: Encodable {
        var install_id: String
        var game: String
        var app_version: String
        var reason: String   // "crash" (after a game stopped by itself) or "player" (the game page)
        var report: String
        var keep_report: Bool
        /// 2: the screen says reports are kept 30 days unless the player opts out (keep_report
        /// false); the server keeps older apps' reports only when ticked, for 7 days.
        var keep_policy: Int = 2
        /// (get-help-files) Round 1: the kinds GetHelpFiles can collect on this device.
        var can_send: [String]? = nil
        /// Round 2: round 1's request id and the files its answer asked for.
        var follow_up: String? = nil
        var files: [ExtraFile]? = nil
        /// (sentry-full-log) The app sends the full logs to POST /upload after a kept answer, so the
        /// server waits for them before sending the report to Sentry.
        var upload: Bool = true
    }

    struct ExtraFile: Codable, Equatable {
        var kind: String
        var text: String
    }

    struct ConfigLine: Codable, Hashable {
        var key: String
        var value: String
        var plain: String
        var line: String { "\(key) = \(value)" }
    }

    struct Answer: Decodable, Equatable {
        struct Config: Decodable, Equatable { var lines: [ConfigLine]; var text: String? }
        var ok: Bool
        var request_id: String?
        var kind: String?
        var answer: String?
        var steps: [String]?
        var config: Config?
        var confidence: String?
        /// (get-help-files) The files that would settle it; the app collects them and asks again.
        var need: [String]?
        var error: String?
        var message: String?
    }

    enum Outcome: Equatable {
        case answer(Answer)
        case failed(String)
    }

    // Plain words for what the server can't say itself.
    static let offlineMessage = "Get Help needs the internet. Check your Wi-Fi or mobile data and try again, or tap Save copy for Discord."
    static let slowMessage = "Get Help took too long to answer. Try again in a minute, or tap Save copy for Discord."
    static let notSetUpMessage = "Get Help isn't set up in this copy of Madeira. Tap Save copy for Discord instead."
    static let badAnswerMessage = "Something went wrong reading the answer. Try again, or tap Save copy for Discord."
    static let notMadeiraAnswer = "I can only help with games in Madeira."

    /// The report cut to `max` UTF-16 units (the server measures it in JavaScript):
    /// the start (device, settings, session summary) and the end (how it failed) stay,
    /// the middle of the key lines goes.
    static func clip(_ report: String, max: Int = maxReport) -> String {
        guard report.utf16.count > max else { return report }
        let note = "\n... part of the report left out here to keep it small ...\n"
        let room = max - note.utf16.count
        let headCount = room * 2 / 5
        let head = prefix(report, utf16: headCount)
        let tail = suffix(report, utf16: room - headCount)
        return head + note + tail
    }

    private static func prefix(_ s: String, utf16 count: Int) -> String {
        var used = 0, end = s.startIndex
        for c in s {
            let n = String(c).utf16.count
            if used + n > count { break }
            used += n; end = s.index(after: end)
        }
        return String(s[..<end])
    }

    private static func suffix(_ s: String, utf16 count: Int) -> String {
        var used = 0, start = s.endIndex
        for c in s.reversed() {
            let n = String(c).utf16.count
            if used + n > count { break }
            used += n; start = s.index(before: start)
        }
        return String(s[start...])
    }

    static func body(_ request: Request) -> Data {
        var r = request
        r.report = clip(r.report)
        r.game = String(r.game.prefix(120))
        r.app_version = String(r.app_version.prefix(40))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(r)) ?? Data()
    }

    static func urlRequest(_ path: String, key: String, body: Data) -> URLRequest {
        var request = URLRequest(url: server.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-madeira-key")
        request.httpBody = body
        return request
    }

    /// What to show for a reply (or a failure to get one).
    static func outcome(data: Data?, status: Int?, error: Error?) -> Outcome {
        if let error = error as? URLError, error.code == .timedOut { return .failed(slowMessage) }
        if error != nil { return .failed(offlineMessage) }
        guard let data, let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            return .failed(badAnswerMessage)
        }
        guard answer.ok else {
            let message = answer.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failed(message.isEmpty ? badAnswerMessage : message)
        }
        let text = answer.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return .failed(badAnswerMessage) }
        var shown = answer
        shown.answer = text
        shown.steps = (answer.steps ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // A line the app can't write safely is dropped here too.
        let lines = (answer.config?.lines ?? []).filter(safe)
        shown.config = lines.isEmpty ? nil : Answer.Config(lines: lines, text: lines.map(\.line).joined(separator: "\n"))
        return .answer(shown)
    }

    /// One `key = value` line: no line breaks, no comment marks, a key with no spaces.
    static func safe(_ line: ConfigLine) -> Bool {
        let key = line.key.trimmingCharacters(in: .whitespaces)
        let value = line.value.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty, key.count <= 80, value.count <= 300 else { return false }
        if key.contains(where: { $0.isWhitespace || $0 == "=" || $0 == "#" }) { return false }
        if value.contains(where: { $0.isNewline }) { return false }
        return !key.hasPrefix(";")
    }

    // MARK: Apply and Undo

    /// The comment Apply writes above its lines.
    static func header(date: String) -> String {
        "# Get Help added these on \(date). Undo: Game details > Advanced > Undo Get Help"
    }

    /// The game's config with `lines` added at the end, and the lines that were added
    /// (to take out again with `undo`). A line the config already ends up with (same key,
    /// same value) is not added again; nil when nothing would change.
    static func apply(_ lines: [ConfigLine], to text: String, date: String) -> (text: String, added: [String])? {
        let current = values(text)
        let new = lines.filter { safe($0) && current[$0.key.trimmingCharacters(in: .whitespaces)] != $0.value.trimmingCharacters(in: .whitespaces) }
        guard !new.isEmpty else { return nil }
        var added = [header(date: date)]
        for line in new {
            let plain = line.plain.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if !plain.isEmpty { added.append("# " + plain) }
            added.append("\(line.key.trimmingCharacters(in: .whitespaces)) = \(line.value.trimmingCharacters(in: .whitespaces))")
        }
        var out = text
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out += "\n" }
        out += added.joined(separator: "\n") + "\n"
        return (out, added)
    }

    /// The config with the lines Apply added taken out (each once, from the end), and
    /// the blank line Apply put before them. Lines the player changed since stay.
    static func undo(_ added: [String], from text: String) -> String {
        var rows = text.components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }
        for line in added.reversed() {
            guard let i = rows.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == line }) else { continue }
            rows.remove(at: i)
            // The blank line Apply put before its comment goes with it.
            if line.hasPrefix("# Get Help added these"), i > 0, rows[i - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                rows.remove(at: i - 1)
            }
        }
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty { rows.removeLast() }
        let out = rows.joined(separator: "\n")
        return out.isEmpty ? "" : out + "\n"
    }

    /// key -> value, the last line winning, as GameProfile.parse and the native reader do.
    static func values(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    /// What Undo needs later (beside the game's config file).
    struct Record: Codable, Equatable {
        var game: String
        var date: String
        var added: [String]
    }
}
