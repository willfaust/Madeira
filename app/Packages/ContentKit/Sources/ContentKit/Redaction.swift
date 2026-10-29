// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A value that must never reach a log, error or transcript: refresh and access
/// tokens (Steam's, GOG's, Epic's), the QR challenge URL, login and exchange
/// codes, machine secrets, depot keys, CDN tokens, Steam's encrypted app tickets
/// and Epic's ownership tokens.
/// `description` and `debugDescription` both print a fixed placeholder, so a
/// stray `print(secret)` or string interpolation cannot leak it.
public struct Secret<Value: Sendable>: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: Value
    public init(_ value: Value) { self.value = value }
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}

extension Secret: Equatable where Value: Equatable {}

/// Last-line scrubber for every diagnostic line the client emits. Secrets are
/// kept in `Secret` and never interpolated, but anything that does reach a log
/// (a server error string, a URL) passes through here first.
public enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            // Epic's ownership token (`egoc1~<JWT>`, decision 0059), before the JWT rule takes its tail.
            (#"egoc1~[A-Za-z0-9._~+/=\-]+"#, "<ovt:redacted>"),
            // JWTs (Steam refresh and access tokens are eyJ... three-part JWTs).
            (#"eyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]*"#, "<jwt:redacted>"),
            // QR challenge URLs: https://s.team/q/<version>/<client id>.
            (#"https?://s\.team/q/[^\s"']+"#, "<qr-challenge:redacted>"),
            // Query strings and bearer-bearing URL tails.
            (#"(https?://[^\s"'?]+)\?[^\s"']*"#, "$1?<query:redacted>"),
            (#"(?i)(bearer\s+)[^\s"']+"#, "$1<redacted>"),
            // Epic's eg1 tokens (decision 0058), wherever they appear.
            (#"eg1~[A-Za-z0-9._~+/=\-]+"#, "<eg1:redacted>"),
            (#"(?i)((?:access|refresh)_?token|token|authorization|cdn_?auth)(["']?\s*[:=]\s*["']?)[^\s"',&}]+"#, "$1$2<redacted>"),
            // Steam's encrypted app ticket as gbe_fork's ini line holds it, `ticket=<base64>` (decision 0017).
            (#"(?i)(\bticket\s*=\s*|["']ticket["']\s*:\s*["'])[A-Za-z0-9+/_\-]+=*"#, "$1<redacted>"),
            // A signed-in Epic launch's arguments (decision 0059): the exchange code, the account
            // ID, and the display name (quoted, or words up to the next argument).
            (#"(?i)(-AUTH_PASSWORD=|-epicuserid=)[^\s"']+"#, "$1<redacted>"),
            (#"(?i)(-epicusername=)(?:"[^"]*"|[^\s"]+(?:\s+[^\s"\-][^\s"]*)*)"#, "$1<redacted>"),
            // OAuth codes and session IDs: GOG's and Epic's login codes, Epic's exchange codes,
            // a device sign-in's user code (decision 0064).
            (#"(?i)((?:authorization|exchange|user)_?code|session_?id|client_?secret)(["']?\s*[:=]\s*["']?)[^\s"',&}]+"#, "$1$2<redacted>"),
            (#"(?i)(["']code["']\s*:\s*["']|\bcode=)[^\s"',&}]+"#, "$1<redacted>"),
            // Home directories.
            (#"/(?:home|Users)/[^/\s"']+"#, "/<home>"),
        ]
        return patterns.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    }()

    public static func scrub(_ line: String) -> String {
        var out = line
        for (re, template) in rules {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return out
    }

    /// A Keychain access group with its team prefix masked. The group is
    /// `<team>.<bundle id>`, and a free-team bundle ID (`XTL-<team>.…`) carries
    /// the team again, so every occurrence of the prefix becomes `<team>`:
    /// `<team>.XTL-<team>.com.example.app`. The team ID is an identifier the
    /// redaction checklist keeps out of committed records; the rest of the group
    /// still shows which app's group the item is in.
    public static func maskTeam(accessGroup group: String) -> String {
        guard let dot = group.firstIndex(of: "."), dot > group.startIndex else {
            return group == "?" ? group : "<group:redacted>"
        }
        let team = String(group[..<dot])
        return "<team>" + group[dot...].replacingOccurrences(of: team, with: "<team>")
    }

    /// A short, non-reversible tag for correlating one identifier across a
    /// transcript without revealing it (for example, "acct#3f2a").
    public static func tag(_ label: String, _ raw: String) -> String {
        let digest = SHA1.hash(Array(raw.utf8))
        return "\(label)#" + digest.prefix(2).map { String(format: "%02x", $0) }.joined()
    }
}

/// Diagnostics sink. Every line is scrubbed and timestamped; the CLI writes
/// them to stderr, which the evidence transcript records.
public struct Logger: Sendable {
    public enum Level: String, Sendable { case debug, info, warn, error }
    private let sink: @Sendable (String) -> Void
    public let verbose: Bool

    public init(verbose: Bool = false, sink: @escaping @Sendable (String) -> Void) {
        self.verbose = verbose
        self.sink = sink
    }

    public static let silent = Logger { _ in }

    public static func stderr(verbose: Bool = false) -> Logger {
        Logger(verbose: verbose) { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    public func log(_ level: Level, _ category: String, _ message: @autoclosure () -> String) {
        if level == .debug && !verbose { return }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt,
                                                formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        sink(Redactor.scrub("\(stamp) \(level.rawValue.uppercased()) [\(category)] \(message())"))
    }

    public func debug(_ c: String, _ m: @autoclosure () -> String) { log(.debug, c, m()) }
    public func info(_ c: String, _ m: @autoclosure () -> String) { log(.info, c, m()) }
    public func warn(_ c: String, _ m: @autoclosure () -> String) { log(.warn, c, m()) }
    public func error(_ c: String, _ m: @autoclosure () -> String) { log(.error, c, m()) }
}
