// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Takes personal details out of text before Madeira hands it to someone
//  else: Get Help from Claude's report (ClaudeHelp.swift) and the logs a
//  player shares from Settings. Players post these files in public Discord
//  channels, and the logs carry more than they look like they do: Epic's
//  one-time sign-in code and account name on the game's command line
//  (-AUTH_PASSWORD=, -epicusername=), Steam IDs inside save paths, the
//  Windows user folder of a prefix copied from a Mac, and the app's
//  container path, which is unique to one install.
//
//  Each rule is a pattern and what replaces it. A rule runs on a line only
//  when the line holds one of its hints (lower-cased), so most lines of a
//  30 MB log cost one lower-casing and a few substring checks.
//  tests/host/check-privacy-scrub.py runs every pattern on sample lines.
//
//  What is kept on purpose: loopback, LAN and VPN addresses (127.x, 10.x,
//  172.16-31.x, 192.168.x: they say nothing about who someone is and
//  LocalDevVPN's 10.7.x.x matters for JIT), version numbers that look
//  like addresses (v1.9.7.17, 6.0.0.0, EOSSDK-Win64-Shipping-1.17.1.3.dll),
//  Wine's generic user names (mobile, steamuser), COM GUIDs, memory
//  addresses, shader and symbol names, and values Madeira already wrote as
//  <redacted>.
//

import Foundation

enum PrivacyScrub {
    struct Rule {
        let name: String
        /// The rule runs only on a line that holds one of these (lower-cased);
        /// empty runs it on every line.
        let hints: [String]
        let regex: NSRegularExpression
        let template: String
        /// The shortest text the pattern can match (UTF-8 bytes): a shorter line skips it.
        let minLength: Int

        init(_ name: String, hints: [String], _ pattern: String, _ template: String, caseInsensitive: Bool = false,
             minLength: Int = 0) {
            self.name = name
            self.hints = hints
            self.minLength = minLength
            // The patterns are fixed and checked by the host test, so a bad one is a bug.
            self.regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
            self.template = template
        }
    }

    /// Windows user names that belong to Wine, not to a person.
    static let genericUsers = "mobile|steamuser|crossover|wineuser|public|default|default user|all users"

    /// In order: a container path before the home-folder rule, a URL login
    /// before the e-mail rule (both have an @), field values before long ids.
    static let rules: [Rule] = [
        // RULE container
        Rule("container", hints: ["/containers/"],
             #"(?:/private)?/var/mobile/Containers/(?:Data|Shared/AppGroup|Bundle)/(?:Application/|PluginKitPlugin/)?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
             "<app>", caseInsensitive: true),
        // RULE unix-home
        Rule("unix-home", hints: ["/users/", "/home/"],
             #"(/(?:Users|home)/)(?!(?:mobile|steamuser|crossover|wineuser|Shared|Public|Default)(?=[/"'\s]|$))[^/\\\s"':]+"#,
             "$1<user>", caseInsensitive: true),
        // RULE windows-user
        Rule("windows-user", hints: ["users\\"],
             #"([A-Za-z]:\\+users\\+)(?!(?:mobile|steamuser|crossover|wineuser|public|default user|default|all users)(?=[\\"'\s]|$))[^\\/\s"':]+"#,
             "$1<user>", caseInsensitive: true),
        // RULE url-login
        Rule("url-login", hints: ["://"],
             #"(://)[^/\s:@"']+:[^/\s@"']+@"#,
             "$1<login>@"),
        // RULE email
        Rule("email", hints: ["@"],
             #"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(?![A-Za-z0-9])"#,
             "<email>"),
        // RULE bearer
        Rule("bearer", hints: ["bearer"],
             #"(Bearer\s+)[A-Za-z0-9._~+/=-]+"#,
             "$1<token>", caseInsensitive: true),
        // RULE jwt
        Rule("jwt", hints: ["eyj"],
             #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+"#,
             "<token>"),
        // RULE secret-field: key=value, key: value, "key": "value", "key" "value" (Steam's .vdf files), -key=value
        Rule("secret-field", hints: ["pass", "token", "secret", "user", "account", "persona", "display", "steamid", "steam_id",
                                     "appleid", "apple_id", "email", "cookie", "session", "ticket", "apikey", "api_key",
                                     "authorization", "exchange", "refresh"],
             #"((?:^|[^A-Za-z0-9])"?[A-Za-z_-]*(?:password|passwd|token|secret|username|user_name|userid|user_id|accountid|account_id|accountname|account_name|personaname|persona_name|displayname|display_name|steamid|steam_id|appleid|apple_id|email|cookie|sessionid|session_id|ticket|apikey|api_key|authorization|exchangecode|exchange_code)"?(?:\s*[=:]\s*"?|"\s+"))(?!(?:\d{1,4}|true|false|yes|no|none|null|nil|ok|unused|empty|<[a-z-]+>)(?=[\s"&,;)]|$))(?:(?<=")[^"\r\n]+|[^\s"&,;)]+)"#,
             "$1<hidden>", caseInsensitive: true),
        // RULE steam-login
        Rule("steam-login", hints: ["logging in user", "logged in as", "signed in as"],
             #"((?:Logging in user|logged in as|signed in as)\s+'?)[^'\s,;]+"#,
             "$1<user>", caseInsensitive: true),
        // RULE steam-id64
        Rule("steam-id64", hints: ["7656119"],
             #"(?<![0-9])7656119[0-9]{10}(?![0-9])"#,
             "<steam-id>"),
        // RULE steam-id3
        Rule("steam-id3", hints: ["u:1:"],
             #"\[U:1:[0-9]+\]"#,
             "[U:1:<steam-id>]", caseInsensitive: true),
        // RULE steam-id2
        Rule("steam-id2", hints: ["steam_"],
             #"\bSTEAM_[0-5]:[01]:[0-9]+\b"#,
             "<steam-id>"),
        // RULE ipv4: public addresses only; not after a v or "version", not ending in .0
        Rule("ipv4", hints: ["."],
             #"(?<![0-9.A-Za-z_-])(?<!version )(?<!Version )(?!(?:0|10|127|169\.254|192\.168|172\.(?:1[6-9]|2[0-9]|3[01])|22[4-9]|2[3-5][0-9])\.)(?:(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?)(?!\.?[0-9]|\.[A-Za-z])"#,
             "<ip>", minLength: 7),
        // RULE ipv6-full
        Rule("ipv6-full", hints: [":"],
             #"(?<![0-9A-Za-z:])(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}(?![0-9A-Za-z:])"#,
             "<ip>", minLength: 15),
        // RULE ipv6-short: has "::", a digit, and is not loopback or link-local
        Rule("ipv6-short", hints: ["::"],
             #"(?<![0-9A-Za-z:])(?=[0-9A-Fa-f:]*[0-9])(?!fe80:)(?:[0-9A-Fa-f]{1,4}:){1,6}:(?:[0-9A-Fa-f]{1,4}:){0,5}[0-9A-Fa-f]{1,4}(?![0-9A-Za-z:])"#,
             "<ip>", caseInsensitive: true),
        // RULE mac
        Rule("mac", hints: [":", "-"],
             #"(?<![0-9A-Fa-f:-])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])"#,
             "<mac>", minLength: 17),
        // RULE long-hex: 48+ random-looking hex digits (session tickets; addresses and
        // hashes are shorter, and memory dumps have runs of zeros)
        Rule("long-hex", hints: [],
             #"(?<![0-9A-Fa-f])(?![0-9A-Fa-f]*0000)[0-9A-Fa-f]{48,}(?![0-9A-Fa-f])"#,
             "<long-id>", minLength: 48),
    ]

    /// One line, scrubbed.
    static func line(_ text: String) -> String {
        var out = text
        var lower = text.lowercased()
        let length = text.utf8.count
        // The ipv4, ipv6, mac and long-hex hints (".", ":", "-", none) are on most lines,
        // so the length check is what spares a short line those patterns.
        for rule in rules where length >= rule.minLength
            && (rule.hints.isEmpty || rule.hints.contains(where: { lower.contains($0) })) {
            let range = NSRange(out.startIndex..., in: out)
            let replaced = rule.regex.stringByReplacingMatches(in: out, range: range, withTemplate: rule.template)
            if replaced != out { out = replaced; lower = out.lowercased() }
        }
        return out
    }

    /// Several lines, scrubbed one by one.
    static func text(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line(String($0)) }.joined(separator: "\n")
    }

    /// Writes a scrubbed copy of `source` to `target`, line by line (a log can be tens of MB).
    /// `fromByte` skips the start of the file: the copy then begins at the next whole line.
    @discardableResult
    static func copy(from source: URL, to target: URL, fromByte: UInt64 = 0) throws -> Int {
        let fm = FileManager.default
        try? fm.removeItem(at: target)
        guard fm.createFile(atPath: target.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
        let out = try FileHandle(forWritingTo: target)
        defer { try? out.close() }
        var buffer = Data()
        var changed = 0
        LogLines.forEach(in: source, fromByte: fromByte) { raw in
            let clean = line(raw)
            if clean != raw { changed += 1 }
            buffer.append(contentsOf: clean.utf8)
            buffer.append(0x0A)
            if buffer.count >= 1 << 20 { out.write(buffer); buffer.removeAll(keepingCapacity: true) }
        }
        if !buffer.isEmpty { out.write(buffer) }
        return changed
    }
}

/// Reads a log a line at a time in 1 MB chunks, the way LogSummary does: logs
/// are too big to load whole, and a line longer than 1 MB is dropped.
enum LogLines {
    static func forEach(in url: URL, fromByte: UInt64 = 0, _ body: (String) -> Void) {
        scan(in: url, fromByte: fromByte) { body($0); return true }
    }

    /// Whether any line matches; stops reading at the first one.
    static func contains(in url: URL, where match: (String) -> Bool) -> Bool {
        var found = false
        scan(in: url) { line in
            if match(line) { found = true; return false }
            return true
        }
        return found
    }

    /// Calls `body` for each line until it returns false.
    static func scan(in url: URL, fromByte: UInt64 = 0, _ body: (String) -> Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var skipPartial = false
        if fromByte > 0 {
            if (try? handle.seek(toOffset: fromByte)) == nil { return }
            skipPartial = true
        }
        var carry = Data()
        var droppingLongLine = false
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            carry.append(chunk)
            var start = carry.startIndex
            while let nl = carry[start...].firstIndex(of: 0x0A) {
                if skipPartial {
                    skipPartial = false
                } else if !droppingLongLine {
                    var line = String(decoding: carry[start..<nl], as: UTF8.self)
                    if line.hasSuffix("\r") { line.removeLast() }
                    if !body(line) { return }
                }
                droppingLongLine = false
                start = carry.index(after: nl)
            }
            carry = Data(carry[start...])
            if carry.count > 1 << 20 { carry.removeAll(keepingCapacity: true); droppingLongLine = true; skipPartial = false }
        }
        if !skipPartial, !droppingLongLine, !carry.isEmpty { _ = body(String(decoding: carry, as: UTF8.self)) }
    }
}
