// SPDX-License-Identifier: GPL-3.0-or-later
import Compression
import CryptoKit
import Foundation

struct IssueDraft {
    var title: String
    var body: String
    var labels: [String]
    var logZipURL: URL?
    var crashSignature: CrashSignature? = nil
}

struct CrashSignature: Encodable {
    let engine: String
    let targetExe: String
    let canonicalCrashLine: String
}

/// The one door Curator's UI uses to file a report. Every text is scrubbed here, so nothing downstream can forget to.
enum CuratorUploadBridge {
    static var reporter = GitHubReporter.shared
    static let maxLogCharacters = 800_000

    /// Signed in with a stored token: the report is filed as the user. Otherwise it goes anonymously and no token is ever attached.
    static var signedIn: Bool { reporter.isSignedIn }

    /// Exactly the text `submit` sends, so the review sheet previews what leaves the device.
    static func scrubbed(_ d: IssueDraft) -> IssueDraft {
        IssueDraft(title: String(LogScrubber.scrub(d.title).replacingOccurrences(of: "\n", with: " ").prefix(256)),
                   body: LogScrubber.scrub(d.body),
                   labels: d.labels.map { LogScrubber.scrub($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                   logZipURL: d.logZipURL)
    }

    static func submit(_ d: IssueDraft, anonymous: Bool) async throws -> URL {
        let clean = scrubbed(d)
        let (title, body, labels) = (clean.title, clean.body, clean.labels)
        let log = d.logZipURL.flatMap { logText(from: $0) }
        let reporter = self.reporter
        if anonymous {
            let challenge = try await reporter.relayChallenge()
            let worker = Task.detached(priority: .userInitiated) {
                try solveHashcash(challenge)
            }
            let nonce = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            let signature = d.crashSignature.map {
                CrashSignature(engine: LogScrubber.scrub($0.engine), targetExe: LogScrubber.scrub($0.targetExe),
                               canonicalCrashLine: LogScrubber.scrub($0.canonicalCrashLine))
            }
            return try await reporter.submitAnonymously(title: title, body: body, labels: labels, logText: log,
                                                        signature: signature, challenge: challenge, nonce: nonce)
        }
        return try await reporter.createIssue(title: title, body: body, labels: labels, logText: log)
    }

    static func solveHashcash(_ challenge: String) throws -> String {
        var input = Array((challenge + ":" + String(repeating: "0", count: 16)).utf8)
        let hex = Array("0123456789abcdef".utf8)
        let end = input.count
        let deadline = ContinuousClock.now.advanced(by: .seconds(240))
        for nonce in UInt64(0)...UInt64.max {
            if nonce & 4095 == 0 {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw GitHubReporter.ReporterError.relayChallengeExpired }
            }
            var digits = nonce
            for index in (end - 16..<end).reversed() {
                input[index] = hex[Int(digits & 15)]
                digits >>= 4
            }
            let prefix = SHA256.hash(data: input).prefix(3)
            var bytes = prefix.makeIterator()
            if bytes.next() == 0, bytes.next() == 0, let third = bytes.next(), third < 16 {
                return String(decoding: input.suffix(16), as: UTF8.self)
            }
        }
        throw GitHubReporter.ReporterError.relayChallengeExpired
    }

    /// Scrubbed text of a log file, or of every .log/.txt/.cfg/.ips entry of a zip (newest content wins when over the cap).
    static func logText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var parts: [String] = []
        if url.pathExtension.lowercased() == "zip" || data.prefix(2) == Data([0x50, 0x4B]) {
            for (name, content) in ZipText.entries(in: data) {
                parts.append("===== \(LogScrubber.scrub(name)) =====\n" + LogScrubber.scrub(content))
            }
        } else if let s = String(data: data, encoding: .utf8) {
            parts.append(LogScrubber.scrub(s))
        }
        guard !parts.isEmpty else { return nil }
        let text = parts.joined(separator: "\n\n")
        return text.count > maxLogCharacters ? String(text.suffix(maxLogCharacters)) : text
    }
}

/// Minimal zip reader (stored and deflate entries) for the text logs Triptych exports; no third-party code.
enum ZipText {
    static let allowed: Set<String> = ["log", "txt", "cfg", "ips"]
    static let maxEntryBytes = 8 << 20

    static func entries(in zip: Data) -> [(String, String)] {
        let d = [UInt8](zip)
        func u16(_ o: Int) -> Int { o + 2 <= d.count ? Int(d[o]) | Int(d[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 4 <= d.count ? u16(o) | u16(o + 2) << 16 : 0 }
        guard d.count >= 22 else { return [] }
        var eocd = -1
        var i = d.count - 22
        while i >= max(0, d.count - 22 - 65_535) {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return [] }
        var p = u32(eocd + 16)
        var out: [(String, String)] = []
        for _ in 0..<u16(eocd + 10) {
            guard p + 46 <= d.count, u32(p) == 0x0201_4B50 else { break }
            let method = u16(p + 10), csize = u32(p + 20), usize = u32(p + 24)
            let nlen = u16(p + 28), elen = u16(p + 30), clen = u16(p + 32), local = u32(p + 42)
            guard p + 46 + nlen <= d.count else { break }
            let name = String(decoding: d[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            p += 46 + nlen + elen + clen
            let ext = (name as NSString).pathExtension.lowercased()
            guard allowed.contains(ext), usize <= maxEntryBytes, local + 30 <= d.count, u32(local) == 0x0403_4B50 else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + csize <= d.count else { continue }
            let raw = Array(d[start..<(start + csize)])
            var bytes: [UInt8]?
            if method == 0 { bytes = raw }
            else if method == 8 {
                var buf = [UInt8](repeating: 0, count: max(usize, 1))
                let n = compression_decode_buffer(&buf, buf.count, raw, raw.count, nil, COMPRESSION_ZLIB)
                bytes = n > 0 ? Array(buf[0..<n]) : nil
            }
            if let bytes { out.append((name, String(decoding: bytes, as: UTF8.self))) }
        }
        return out
    }
}
