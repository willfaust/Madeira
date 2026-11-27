// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Removes personal data from log text before it leaves the device.
/// Deterministic and idempotent: no model is involved, and scrubbing scrubbed text changes nothing.
/// Engine messages stay readable; only the identifying part of a line is replaced by a <placeholder>.
enum LogScrubber {
    private struct Rule {
        let regex: NSRegularExpression
        let template: String
        let accept: ((String) -> Bool)?
    }

    private static func rule(_ pattern: String, _ template: String, accept: ((String) -> Bool)? = nil) -> Rule {
        // Patterns are literals in this file; a bad one is a programming error caught by the tests.
        Rule(regex: try! NSRegularExpression(pattern: pattern), template: template, accept: accept)
    }

    private static func isGuestOrLoopbackIPv4(_ s: String) -> Bool {
        s.hasPrefix("10.0.2.") || s.hasPrefix("127.") || s == "0.0.0.0"
    }

    private static func validIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { $0 <= 255 } ?? false }
    }

    private static func looksLikeBase64Secret(_ s: String) -> Bool {
        let hasDigit = s.contains { $0.isNumber }
        let hasUpper = s.contains { $0.isUppercase }
        let hasLower = s.contains { $0.isLowercase }
        return hasDigit && hasUpper && hasLower
    }

    private static let rules: [Rule] = [
        // Credentials first so later rules never see half of a token.
        rule(#"\b(?:gh[opusr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#, "<redacted-token>"),
        rule(#"\b(Bearer\s+)(?!<redacted-token>)[^\s"']+"#, "$1<redacted-token>"),
        rule(#"(?i)(-{1,2}password\s+)(?!<redacted-token>)[^\s"']+"#, "$1<redacted-token>"),
        rule(#"(?i)(?<!\w)(--AUTH_PASSWORD|--AUTH_TOKEN|token|access_token|refresh_token|password|passwd|secret|api[_-]?key|authorization|cookie)(\s*[=:]\s*)(?!<redacted-token>|Bearer\b)[^\s"'&;,]+"#,
             "$1$2<redacted-token>"),
        // Identity.
        rule(#"(?i)\b(apple\s?id|icloud\s?account)(\s*[=:]\s*)(?!<apple-id>)[^\s"',;]+"#, "$1$2<apple-id>"),
        rule(#"\b[A-Za-z0-9._-]+@(?=\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b)"#, "<user>@"),
        rule(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        rule(#"(?i)\b(serial(?:\s?(?:number|no\.?))?|udid|ecid|imei|meid|hw\.serialnumber)(\s*[=:]\s*)(?!<serial>)[A-Za-z0-9-]{6,}"#,
             "$1$2<serial>"),
        rule(#"(?i)\b(udid|ecid)(\s+)(?!<serial>)(?:0x)?[A-Fa-f0-9-]{8,}"#, "$1$2<serial>"),
        rule(#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b"#, "<serial>"),
        // Paths.
        rule(#"/(?:private/)?var/mobile/Containers/(Data/Application|Shared/AppGroup|Data/PluginKitPlugin)/[0-9A-Fa-f-]{36}"#,
             "/var/mobile/Containers/$1/<app-uuid>"),
        rule(#"/Users/(?!Shared(?:/|\b))[^/\s"'<]+"#, "/Users/<user>"),
        rule(#"/home/[^/\s"'<]+"#, "/home/<user>"),
        rule(#"(?i)\b([A-Z]:\\Users\\)(?!Public\b|Default\b|steamuser\b|crossover\b|<)[^\\"\s]+"#, "$1<win-user>"),
        // UUIDs (container paths are already handled above).
        rule(#"\b[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\b"#, "<uuid>"),
        // Network.
        rule(#"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{2}[\-:]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:])"#, "<mac>"),
        rule(#"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.]*\d)"#, "<ip>",
             accept: { validIPv4($0) && !isGuestOrLoopbackIPv4($0) }),
        rule(#"(?<![\w:])(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,6}:(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,5})?)(?![\w:])"#,
             "<ip>", accept: { $0 != "::1" }),
        // Anything long and random that is left.
        rule(#"(?<![0-9A-Za-z])[0-9A-Fa-f]{32,}(?![0-9A-Za-z])"#, "<hex>"),
        rule(#"(?<![0-9A-Za-z+/_=-])[A-Za-z0-9+/_-]{40,}={0,2}(?![0-9A-Za-z+/_=-])"#, "<redacted-key>",
             accept: { looksLikeBase64Secret($0) }),
    ]

    static func scrub(_ text: String) -> String {
        var out = text
        for r in rules { out = apply(r, to: out) }
        return out
    }

    private static func apply(_ r: Rule, to s: String) -> String {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let accept = r.accept else {
            return r.regex.stringByReplacingMatches(in: s, range: full, withTemplate: r.template)
        }
        var result = ""
        var last = 0
        for m in r.regex.matches(in: s, range: full) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hit = ns.substring(with: m.range)
            result += accept(hit) ? r.regex.replacementString(for: m, in: s, offset: 0, template: r.template) : hit
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
