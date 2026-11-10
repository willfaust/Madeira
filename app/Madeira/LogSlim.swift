// LogSlim (log-fixes, Cameron Nov 10): makes the logs in Get Help's upload zip smaller
// without losing what explains a problem. The log on the device keeps every line.
//
// The Sentry check (Nov 9, 18 zips) found 2-7 MB per run, most of it a few lines repeated
// thousands of times (FEX's unaligned-atomic line was 41% of an Escapists 2 log), and the
// game's run sent twice (game-run.txt and again inside madeira-log.txt).
//  * A line that differs from an earlier one only in numbers and addresses is kept the first
//    `keepFirst` times, then once every `every` times with its count; the end of the file lists
//    the most repeated lines and how many were left out.
//  * Madeira's own lines that tell the story (start, steps, end, errors) are always kept.
//  * A run whose first line is in `skipStarts` (it is in the zip as its own file) becomes one line.
// Foundation only, so tests/host/check-log-slim.py can compile and run it.

import Foundation

final class LogSlim {
    static let keepFirst = 50
    static let every = 1000
    static let topListed = 15

    private let skipStarts: Set<String>
    private var seen: [String: Int] = [:]
    private var dropped: [String: Int] = [:]
    private var droppedTotal = 0
    private var skipEnd: String?
    private var skipped = 0

    init(skipStarts: Set<String> = []) { self.skipStarts = skipStarts }

    /// The lines to write for one raw log line (none, the line, or a note).
    func take(_ line: String) -> [String] {
        if let end = skipEnd {
            skipped += 1
            guard line.contains(end) else { return [] }
            skipEnd = nil
            return [Self.skipNote(skipped)]
        }
        if skipStarts.contains(line), let r = line.range(of: "[run-start] #") {
            let number = line[r.upperBound...].prefix { $0.isNumber }
            if !number.isEmpty { skipEnd = "[run-end] #\(number)"; skipped = 1; return [] }
        }
        if Self.keeps(line) { return [line] }
        let shape = Self.shape(line)
        let n = (seen[shape] ?? 0) + 1
        seen[shape] = n
        if n <= Self.keepFirst { return [line] }
        if n % Self.every == 0 { return [line + "  [log-slim: line like this #\(n)]"] }
        dropped[shape, default: 0] += 1
        droppedTotal += 1
        return []
    }

    /// The closing lines: a run left open, and the list of repeated lines left out.
    func finish() -> [String] {
        var out: [String] = []
        if skipEnd != nil { out.append(Self.skipNote(skipped)); skipEnd = nil }
        guard droppedTotal > 0 else { return out }
        out.append("[log-slim] \(droppedTotal) repeated lines were left out of this upload (the log on the device has them all). Most repeated (numbers shown as N):")
        for (shape, count) in dropped.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(Self.topListed) {
            out.append("  \(count) x " + (shape.count > 160 ? String(shape.prefix(160)) + "…" : shape))
        }
        return out
    }

    static func skipNote(_ lines: Int) -> String {
        "[log-slim] \(lines) lines of this game's run left out here: the same run is in game-run.txt or earlier-run.txt"
    }

    /// Madeira's own lines that tell what happened: always kept.
    static let keptTags = [" [ERR] ", " [WARN] ", "[run-start]", "[run-end]", "[game-start]", "[game-end]", "[step]",
                           "[last-run]", "[get-help]", "[app]", "[frontend]", "[WineProc]", "[time]", "[log-repeat]"]
    static func keeps(_ line: String) -> Bool { keptTags.contains { line.contains($0) } }

    private static let numbers = try! NSRegularExpression(
        pattern: #"0x[0-9A-Fa-f]+|\b(?=[0-9A-Fa-f]*[0-9])[0-9A-Fa-f]{4,}\b|[0-9]+"#)
    private static let clock = try! NSRegularExpression(pattern: #"^\[[0-9:.]+\] "#)

    /// The line without its time and with every number as N: lines with the same shape are repeats.
    static func shape(_ line: String) -> String {
        var s = line
        let all = NSRange(s.startIndex..., in: s)
        if let m = clock.firstMatch(in: s, range: all), let r = Range(m.range, in: s) { s.removeSubrange(r) }
        return numbers.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "N")
    }
}
