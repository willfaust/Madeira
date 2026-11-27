// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum Triage {
    enum Lever: Equatable {
        case smallerCodeCache
        case enableJITAtLaunch
        case restart(EngineKind)
        case reportOnly

        var instruction: String {
            switch self {
            case .smallerCodeCache:
                return "Set the code cache to 512 MB. Quit and reopen Triptych with JIT to use it."
            case .enableJITAtLaunch:
                return "Turn on JIT when Triptych opens using the paired helper. If you use LiveContainer, select Triptych’s JIT script there."
            case .restart(let kind):
                return "Restart Triptych into \(kind.title). Save your work in any running system first."
            case .reportOnly:
                return "Use Report if the failure keeps happening."
            }
        }
    }

    enum Confidence: String {
        case high = "High confidence"
        case medium = "Medium confidence"
    }

    struct Finding: Identifiable {
        let signature: String
        let title: String
        let explanation: String
        let lever: Lever
        let confidence: Confidence
        let system: EngineKind?
        let fromPreviousRun: Bool

        var id: String { "\(signature):\(system?.rawValue ?? "")" }
    }

    struct Result {
        let findings: [Finding]
        let unmatchedExcerpt: String
        let filesRead: Int
    }

    private struct Rule {
        let id: String
        let pattern: NSRegularExpression
        let title: String
        let explanation: String
        let lever: Lever
        let confidence: Confidence
        let system: EngineKind?

        init(_ id: String, _ pattern: String, _ title: String, _ explanation: String,
             _ lever: Lever, _ confidence: Confidence, system: EngineKind? = nil) {
            self.id = id
            self.pattern = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            self.title = title
            self.explanation = explanation
            self.lever = lever
            self.confidence = confidence
            self.system = system
        }
    }

    private static let rules: [Rule] = [
        Rule("jit-region", #"\b(?:JIT region|prewarm\s+FAILED)\b.*\babove 0x7000000000\b"#, "JIT memory was placed too high",
             "iOS placed Triptych’s code cache at an address where translated code cannot run. A smaller cache can fit in a lower address range.",
             .smallerCodeCache, .high),
        Rule("jit-prewarm", #"\bprewarm\s+FAILED\b(?!\s*--\s*StikDebug)"#, "JIT memory could not be prepared",
             "Triptych could not reserve executable memory at launch. Reopen with JIT enabled and check that your JIT helper uses Triptych’s script.",
             .reportOnly, .high),
        Rule("jit-debugger-idle", #"\bprewarm\s+FAILED\s*--\s*StikDebug is not servicing traps\b"#, "The JIT helper did not answer",
             "StikDebug was attached but never handled Triptych’s memory request. Make sure LocalDevVPN is connected and StikDebug is running, then reopen Triptych with JIT.",
             .enableJITAtLaunch, .high),
        Rule("windows-driver-load", #"\bDriverEntry failed\s+0x[0-9a-f]+\s+for driver\b"#, "A Windows driver would not load",
             "Windows started but one of its drivers refused to initialize in the virtual PC. The driver name and error code can help diagnose why.",
             .reportOnly, .medium, system: .winpc),
        Rule("firmware-boot-timeout", #"\bBdsDxe:\s*failed to start\b.*\bCD-ROM\b.*\bTime out\b"#, "The install disc did not start",
             "The PC firmware found the install disc but its boot attempt timed out. Retry the boot and report it if it recurs.",
             .reportOnly, .medium),
        Rule("firmware-no-boot-disk", #"\bBdsDxe:\s*failed to load\b.*\bNVMe\b.*\bNot Found\b"#, "No bootable disk found",
             "The PC firmware found no boot loader on the virtual disk. This is expected before Windows is installed; otherwise the install may not have finished.",
             .reportOnly, .medium),
        Rule("jit-required", #"\bTurn on JIT first\b"#, "JIT is off",
             "This system needs JIT to run translated code. Turn on JIT in Easel or enable it for the next launch.",
             .enableJITAtLaunch, .high),
        Rule("linux-start", #"\[linux\]\s+start failed:\s+tp_linux_start returned -1\b|\bStart failed \(-1\)|\bposix_openpt\b.*(?:\bEPERM\b|operation not permitted|errno\s*=\s*1\b)"#,
             "Linux could not start", "iOS may have denied Linux’s request for a terminal. Retry with a Triptych build that includes the Linux console fallback.",
             .reportOnly, .medium, system: .linux),
        Rule("mac-signature", #"\bdlopen\b(?=.*\berrno\s*=\s*1\b)(?=.*(?:code sign|codeBlobOffset))"#,
             "iOS rejected a Mac app’s code signature", "iOS refused to load the imported Mac app. This loader needs an update to run the app on a device.",
             .reportOnly, .high, system: .macapps),
        Rule("edk2-exception", #"\bSynchronous Exception at\s+0x[0-9a-f]+"#, "PC firmware stopped during startup",
             "The virtual PC’s UEFI firmware encountered a CPU exception. Retry with an updated Triptych build and report it if it recurs.",
             .reportOnly, .high),
        Rule("windows-bugcheck", #"\bhenge:\s*bugcheck\b"#, "Windows hit a stop error",
             "Windows stopped inside the virtual PC. The stop code and boot stage can help diagnose why.",
             .reportOnly, .high, system: .winpc),
        Rule("shared-launch", #"\bcan['’]t share this launch\b(?: with\b)?"#, "These systems need separate launches",
             "The two systems need process resources they cannot share. A fresh launch lets you switch systems.",
             .reportOnly, .high),
    ]

    private static let interestingLine = try! NSRegularExpression(
        pattern: #"\b(error|failed|failure|fault|panic|denied|exception|fatal|unsupported|timeout|timed out|crash)\b"#,
        options: .caseInsensitive
    )
    private static let chunkBytes = 64 << 10
    private static let lineBytes = 16 << 10

    /// Provenance returns files newest first. Current logs take precedence over rotated copies of the same finding.
    static func check(_ files: [(url: URL, name: String)]) -> Result {
        var findings: [Finding] = []
        var excerpts: [String] = []
        var excerptSet: Set<String> = []
        var excerptBytes = 0
        var bytesLeft = LogExport.maxTotalBytes
        var filesRead = 0
        for (url, name) in files where bytesLeft > 0 {
            let lowerName = name.lowercased()
            guard !lowerName.hasSuffix("-env.txt"), !lowerName.hasSuffix("give-to-claude-with-log-and-cfg.txt"),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let rotated = lowerName.contains("-prev.")
            let limit = min(bytesLeft, LogExport.maxFileBytes)
            let read = readLines(url, limit: limit) { line in
                let previous = rotated || line.contains("][prev]")
                let matches = match(line, source: lowerName, previous: previous)
                for finding in matches {
                    if let index = findings.firstIndex(where: { $0.id == finding.id }) {
                        if findings[index].fromPreviousRun && !finding.fromPreviousRun {
                            findings[index] = finding
                        }
                    } else {
                        findings.append(finding)
                    }
                }
                if matches.isEmpty, excerptBytes < 1_600,
                   interestingLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    let excerpt = String(decoding: line.utf8.prefix(min(240, 1_600 - excerptBytes)), as: UTF8.self)
                    if excerptSet.insert(excerpt).inserted {
                        excerpts.append(excerpt)
                        excerptBytes += excerpt.utf8.count + 1
                    }
                }
            }
            bytesLeft -= read
            if read > 0 { filesRead += 1 }
        }
        let current = findings.filter { !$0.fromPreviousRun }
        let previous = findings.filter(\.fromPreviousRun)
        return Result(findings: current + previous, unmatchedExcerpt: excerpts.joined(separator: "\n"), filesRead: filesRead)
    }

    private static func match(_ line: String, source: String, previous: Bool) -> [Finding] {
        let range = NSRange(line.startIndex..., in: line)
        return rules.compactMap { rule in
            guard let match = rule.pattern.firstMatch(in: line, range: range),
                  let matchRange = Range(match.range, in: line) else { return nil }
            var system = rule.system
            var lever = rule.lever
            if rule.id == "shared-launch" {
                // The log puts the requested system first. The message shown on screen puts it last.
                let target = line.localizedCaseInsensitiveContains(": offering a restart")
                    ? line[..<matchRange.lowerBound]
                    : line[matchRange.upperBound...]
                system = EngineKind.allCases.first { target.localizedCaseInsensitiveContains($0.title) }
                if let system { lever = .restart(system) }
            } else if rule.id == "edk2-exception" || rule.id.hasPrefix("firmware-") {
                if source.contains("__windowspc__") { system = .winpc }
                if source.contains("__x86pc__") { system = .x86pc }
            } else if rule.id == "jit-required", line.contains("[macapps]") {
                system = .macapps
            }
            return Finding(signature: rule.id, title: rule.title, explanation: rule.explanation,
                           lever: lever, confidence: rule.confidence, system: system, fromPreviousRun: previous)
        }
    }

    /// Read the same bounded tail as Provenance. Keep long lines bounded even across chunk boundaries.
    private static func readLines(_ url: URL, limit: Int, consume: (String) -> Void) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return 0 }
        let length = min(Int(clamping: end), limit)
        let start = end - UInt64(length)
        var skipPartialLine = false
        do {
            if start > 0 {
                try handle.seek(toOffset: start - 1)
                skipPartialLine = try handle.read(upToCount: 1)?.first != 10
            } else {
                try handle.seek(toOffset: 0)
            }
        } catch { return 0 }

        var remaining = length
        var line = Data()
        while remaining > 0, let chunk = try? handle.read(upToCount: min(remaining, chunkBytes)), !chunk.isEmpty {
            remaining -= chunk.count
            var startIndex = chunk.startIndex
            while let endIndex = chunk[startIndex...].firstIndex(of: 10) {
                if !skipPartialLine {
                    line.append(contentsOf: chunk[startIndex..<endIndex].prefix(lineBytes - line.count))
                    if !line.isEmpty { consume(String(decoding: line, as: UTF8.self)) }
                }
                line.removeAll(keepingCapacity: true)
                skipPartialLine = false
                startIndex = endIndex + 1
            }
            if !skipPartialLine {
                line.append(contentsOf: chunk[startIndex...].prefix(lineBytes - line.count))
            }
        }
        if !line.isEmpty { consume(String(decoding: line, as: UTF8.self)) }
        return length - remaining
    }
}
