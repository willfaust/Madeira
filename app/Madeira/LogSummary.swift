// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// A short "what went wrong" report for one session, written to
/// Documents/madeira-summary.txt beside madeira-log.txt.
///
/// A session log runs to tens of MB and the lines that explain a failure are
/// buried in it: CS2 at the Valve logo (2026-10-25) was a JIT pool shrunk to
/// 560 MB at launch, `[jit-pool] EXHAUSTED` for v8.dll 15,000 lines later and
/// cs2.exe ending with exit code 1, between thousands of `[xp]` and
/// `[dll-missing]` lines, most of which are harmless. The summary reads the log
/// once, line by line, and keeps only those facts: the programs started, how
/// they ended, missing DLLs that may matter, the JIT pool and Madeira Dock's
/// result in words.
///
/// It is written when a session returns to the library (LibraryModel.finish)
/// and, for a session that never got there (a crash, Force close), at the next
/// app launch from madeira-log.prev.txt. Reading the log changes nothing.
enum LogSummary {
    static let fileName = "madeira-summary.txt"

    /// DLLs a session looks for and runs fine without (docs: the plan's "harmless
    /// warnings" list): Wine's other display drivers, Windows' sign-in packages,
    /// Steam's optional modules, and debugging tools games probe for.
    static let harmlessDLLs: Set<String> = [
        "winemac.drv", "winex11.drv", "winewayland.drv",
        "kerberos.dll", "msv1_0.dll",
        "video64.dll", "steamservice.dll", "sdl3.dll",
        "windisc.dll", "wow64cpu.dll",
        "renderdoc.dll", "dbgcore.dll",
    ]

    /// Helper programs Steam and Wine start around a game; the game is the
    /// program `[session-log]` names, else the last program started that is not one of these.
    static let helperPrograms: Set<String> = [
        "explorer.exe", "dockhost.exe", "conhost.exe", "services.exe", "winedevice.exe",
        "plugplay.exe", "rpcss.exe", "svchost.exe", "steam.exe", "steamwebhelper.exe",
        "steamerrorreporter.exe", "steamerrorreporter64.exe", "steamservice.exe",
        "vulkandriverquery.exe", "vulkandriverquery64.exe", "gldriverquery.exe",
        "gldriverquery64.exe", "crs-handler.exe", "rundll32.exe", "start.exe",
        // (log-fixes) crash reporters and anti-cheat services: never the game (Sentry, Nov 9:
        // 10 of 97 reports named one of these instead of the game).
        "unitycrashhandler64.exe", "unitycrashhandler32.exe", "pnkbstra.exe", "pnkbstrb.exe",
        "crashreportclient.exe", "crashpad_handler.exe", "werfault.exe",
    ]

    struct Process {
        var image: String
        var pid: String?
        var exitCode: UInt32?
        var endedAt: String?
    }

    struct Missing {
        var name: String
        var status: String
        var program: String?
    }

    struct Crash: Equatable {
        var what: String      // "page fault on write access to 00000000"
        var address: String   // "00B57AA9"
        var program: String?
    }

    /// Everything the summary says, gathered in one pass over the log.
    struct Facts {
        var sawSession = false
        var firstTime: String?
        var lastTime: String?
        var target: String?
        var steamGame: String?
        var processes: [Process] = []
        var missing: [Missing] = []
        var harmlessMissing = 0
        var unhandled: [String] = []
        /// Wine's "Unhandled page fault ..." lines: where a program crashed.
        var crashes: [Crash] = []
        /// iPadOS refused to make a program's code executable (mprotect errno 13) and
        /// Madeira ended the process it could not recover.
        var execRefused = false
        /// Madeira Dock's "Steam starts" could not put the chosen program in place.
        var startProgramFailed: String?
        var madeiraEnded = false
        var exitReport: String?
        var quitAsked: String?
        var handedToSteam = false
        var forceClosed = false
        var poolWantedMB: Int?
        var poolMB: Int?
        var smallPool = false
        var poolAllocationFailed = false
        var guestWindowFailed = false
        var poolPeak: UInt64 = 0
        var poolTotal: UInt64 = 0
        var exhausted = 0
        var exhaustedWant: UInt64 = 0
        var tailGrants: [UInt64] = []
        var dock: [String: String] = [:]

        var game: String? {
            if let steamGame { return steamGame }
            let names = processes.map(\.image)
            return names.last { !LogSummary.helperPrograms.contains($0.lowercased()) }
                ?? target.flatMap { LogSummary.helperPrograms.contains($0.lowercased()) ? nil : $0 }
        }
    }

    // MARK: Reading

    /// Reads `url` in 1 MB chunks (a log can be larger than is sensible to load at once).
    static func facts(fromFileAt url: URL) -> Facts? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var reader = Reader()
        var carry = Data()
        var droppingLongLine = false
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            carry.append(chunk)
            var start = carry.startIndex
            while let nl = carry[start...].firstIndex(of: 0x0A) {
                if !droppingLongLine { reader.feed(String(decoding: carry[start..<nl], as: UTF8.self)) }
                droppingLongLine = false
                start = carry.index(after: nl)
            }
            carry = Data(carry[start...])
            if carry.count > 1 << 20 { carry.removeAll(keepingCapacity: true); droppingLongLine = true }
        }
        if !droppingLongLine && !carry.isEmpty { reader.feed(String(decoding: carry, as: UTF8.self)) }
        return reader.facts
    }

    static func facts<S: Sequence>(lines: S) -> Facts where S.Element: StringProtocol {
        var reader = Reader()
        for line in lines { reader.feed(String(line)) }
        return reader.facts
    }

    /// One pass over the log. Wine's lines start with the calling thread's id
    /// ("00ac:err:..."); the wineserver's `[srv-own] new_thread` lines tie a thread
    /// to its process, and a new process's first thread is created by the thread
    /// that called NtCreateUserProcess, which is how an exit is tied to a program.
    struct Reader {
        var facts = Facts()
        private var threadPid: [String: String] = [:]
        private var pidProcess: [String: Int] = [:]
        private var pendingSpawn: [String: Int] = [:]   // requester thread -> process index
        private var harmlessSeen = Set<String>()

        mutating func feed(_ raw: String) {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let time = LogSummary.timestamp(line) {
                if facts.firstTime == nil { facts.firstTime = time }
                facts.lastTime = time
            }
            if line.contains("Running full Wine sequence") { facts.sawSession = true }
            if let r = line.range(of: "[WineProc] Target exe: ") {
                facts.sawSession = true
                // "C:\Program Files\...\Game.exe (bundle=...)": the path has spaces, so the
                // name is the last path part before the bundle note.
                var path = line[r.upperBound...]
                if let note = path.range(of: " (bundle=") { path = path[..<note.lowerBound] }
                facts.target = String(path.split(separator: "\\").last ?? path)
            }
            if let r = line.range(of: "[session-log] Steam game ") {
                facts.steamGame = String(line[r.upperBound...].prefix { $0 != ":" })
            }
            if line.contains(":err:process:NtCreateUserProcess "), let image = LogSummary.quoted(line, after: "image=L\"") {
                facts.sawSession = true
                facts.processes.append(Process(image: LogSummary.baseName(image)))
                if let tid = LogSummary.threadID(line) { pendingSpawn[tid] = facts.processes.count - 1 }
            }
            if let r = line.range(of: "[srv-own] new_thread ") {
                let fields = LogSummary.fields(String(line[r.upperBound...]))
                if let tid = fields["tid"], let pid = fields["pid"] {
                    threadPid[tid] = pid
                    if let requester = fields["requester"], let index = pendingSpawn[requester],
                       pidProcess[pid] == nil, threadPid[requester] != pid {
                        pidProcess[pid] = index
                        facts.processes[index].pid = pid
                        pendingSpawn[requester] = nil
                    }
                }
            }
            if line.contains(":err:process:NtTerminateProcess "), line.contains("handle=0xffffffffffffffff"),
               let tid = LogSummary.threadID(line), let r = line.range(of: "exit_code=0x") {
                let hex = line[r.upperBound...].prefix { $0.isHexDigit }
                if let code = UInt32(hex, radix: 16), let pid = threadPid[tid], let index = pidProcess[pid],
                   facts.processes[index].exitCode == nil {
                    facts.processes[index].exitCode = code
                    facts.processes[index].endedAt = facts.lastTime
                }
            }
            if line.contains("[dll-missing]"), let path = LogSummary.quoted(line, after: "L\"") {
                let name = LogSummary.baseName(path).lowercased()
                let status = line.range(of: "status=").map { String(line[$0.upperBound...].prefix { $0.isHexDigit }) } ?? ""
                if LogSummary.harmlessDLLs.contains(name) && status != "c0000017" {
                    if harmlessSeen.insert(name).inserted { facts.harmlessMissing += 1 }
                } else if !facts.missing.contains(where: { $0.name == name && $0.status == status }) {
                    let program = LogSummary.threadID(line).flatMap { threadPid[$0] }.flatMap { pidProcess[$0] }
                        .map { facts.processes[$0].image }
                    facts.missing.append(Missing(name: name, status: status, program: program))
                }
            }
            if let r = line.range(of: "wine: Unhandled "), let at = line.range(of: " at address ", range: r.upperBound..<line.endIndex) {
                // "wine: Unhandled page fault on write access to 00000000 at address 00B57AA9 (thread 0108), ..."
                let address = String(line[at.upperBound...].prefix { $0.isHexDigit })
                let program = line.range(of: "(thread ").flatMap { t -> String? in
                    let tid = String(line[t.upperBound...].prefix { $0.isHexDigit })
                    return threadPid[tid].flatMap { pidProcess[$0] }.map { facts.processes[$0].image }
                }
                let crash = Crash(what: String(line[r.upperBound..<at.lowerBound]).lowercased(), address: address, program: program)
                if facts.crashes.count < 3, !facts.crashes.contains(crash) { facts.crashes.append(crash) }
            } else if line.contains("Unhandled "), !line.contains(":fixme:"), facts.unhandled.count < 3 {
                // Wine's "fixme: ... Unhandled flags" notes are not exceptions.
                facts.unhandled.append(String(line.prefix(200)))
            }
            if line.hasPrefix("[exec-recover] "), line.contains("mprotect_rx=-1(errno=13)") { facts.execRefused = true }
            if line.hasPrefix("[redeliv] terminating process") { facts.madeiraEnded = true }
            if let r = line.range(of: "[dock-start-program] "), let f = line.range(of: " failed: ", range: r.upperBound..<line.endIndex) {
                facts.startProgramFailed = String(line[f.upperBound...].prefix(160))
            }
            if let r = line.range(of: "[exit-report] status=") { facts.exitReport = String(line[r.upperBound...]) }
            if line.contains("[frontend] graceful close requested"), facts.quitAsked == nil {
                facts.quitAsked = facts.lastTime ?? "?"
            }
            if line.contains("[frontend] force close") { facts.forceClosed = true }
            if line.contains("[WineProc] the main process exited while"), line.contains("(steam.exe)") { facts.handedToSteam = true }
            if line.contains("JIT pool allocation FAILED — not starting Wine.") {
                facts.sawSession = true
                facts.poolAllocationFailed = true
            }
            if line.contains("[wow-window] main-process reserve FAILED ")
                || line.contains("[wow-window] refused: map too small") {
                facts.sawSession = true
                facts.guestWindowFailed = true
            }
            if let r = line.range(of: "no hole fits a ") {
                facts.poolWantedMB = Int(line[r.upperBound...].prefix { $0.isNumber })
                facts.smallPool = true
            }
            if line.contains("SMALL JIT POOL") { facts.smallPool = true }
            if let r = line.range(of: "JIT pool: RX="), let s = line[r.upperBound...].range(of: "size=") {
                facts.poolMB = Int(line[s.upperBound...].prefix { $0.isNumber })
            }
            if line.hasPrefix("[jit-pool] ") {
                if let used = LogSummary.hexPair(line, after: "used=0x") ?? LogSummary.hexPair(line, after: "bump=0x") {
                    facts.poolPeak = max(facts.poolPeak, used.0)
                    if used.1 > 0 { facts.poolTotal = used.1 }
                }
                if line.contains("EXHAUSTED") {
                    facts.exhausted += 1
                    if let r = line.range(of: "want=0x"), let want = UInt64(line[r.upperBound...].prefix { $0.isHexDigit }, radix: 16) {
                        facts.exhaustedWant = max(facts.exhaustedWant, want)
                    }
                }
                if let r = line.range(of: "tail BIG: granting 0x"),
                   let size = UInt64(line[r.upperBound...].prefix { $0.isHexDigit }, radix: 16) {
                    facts.tailGrants.append(size)
                }
            }
            if let r = line.range(of: "[dock-report] ") {
                let pair = line[r.upperBound...]
                if let eq = pair.firstIndex(of: "=") {
                    facts.dock[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
                }
            }
        }
    }

    // MARK: Writing

    static func text(_ f: Facts, source: String) -> String {
        var out = ["=== Madeira session summary ===",
                   "From \(source)" + (f.firstTime.map { ", \($0)" } ?? "") + (f.lastTime.map { " to \($0)" } ?? "")
                   + ". The full log has the details; this lists what usually explains a problem.", ""]
        if let game = f.game { out.append("Program: \(game)" + (f.dock.isEmpty ? "" : " (Steam, through Madeira Dock)")) }
        if !f.processes.isEmpty {
            var counts: [(String, Int)] = []
            for p in f.processes {
                if let i = counts.firstIndex(where: { $0.0 == p.image }) { counts[i].1 += 1 } else { counts.append((p.image, 1)) }
            }
            out.append("Programs started: " + counts.map { $0.1 > 1 ? "\($0.0) (\($0.1)x)" : $0.0 }.joined(separator: ", "))
        }

        var problems: [String] = []
        if f.poolAllocationFailed {
            problems.append("The JIT pool could not be allocated, so Wine was not started. See the JIT pool lines in the full log for the reason.")
        }
        if f.guestWindowFailed {
            problems.append("A 32-bit program could not reserve its 4 GB guest-memory window. See the [wow-window] lines in the full log for the reservation failure.")
        }
        if f.smallPool, let mb = f.poolMB {
            problems.append("The JIT pool (the memory games' code runs from) got \(mb) MB"
                + (f.poolWantedMB.map { " instead of \($0) MB" } ?? "")
                + ": iPadOS had no larger free space at launch. Big games may run out of it."
                + " Relaunching Madeira can give a bigger one; `pool-split = 1` in the game's config lets Madeira join two free spaces.")
        }
        if f.exhausted > 0 {
            problems.append("The JIT pool ran out \(f.exhausted)x" + (f.exhaustedWant > 0 ? " (largest request \(mb(f.exhaustedWant)) MB)" : "")
                + ": a DLL could not be loaded, and the program usually stops right after.")
        }
        for m in f.missing where m.status == "c0000017" {
            problems.append("\(m.name) could not be loaded: out of memory" + (m.program.map { " (in \($0))" } ?? "") + ".")
        }
        if let report = f.exitReport { problems.append("The program stopped with Windows error \(report).") }
        if f.handedToSteam, f.dock.isEmpty {
            problems.append("The game started Steam and closed itself: it only runs when Steam starts it. Start it with Madeira Dock (Game details > Steam > Start with).")
        }
        for crash in f.crashes {
            problems.append("\(crash.program ?? "A program") crashed: \(crash.what) at address \(crash.address)."
                            + " Searching the address with the game's name often finds a known fix.")
        }
        if f.madeiraEnded, f.execRefused {
            let started = f.processes.last.map { " The last program started was \($0.image)." } ?? ""
            problems.append("Madeira closed: iPadOS refused to run a program's code. Madeira can start only one 32-bit program"
                            + " per session, so this usually means a launcher started the game.\(started)"
                            + " For a Steam game, pick the game's own program in Game details > Steam > Steam starts.")
        }
        if let why = f.startProgramFailed {
            problems.append("Steam starts: the chosen program was not put in place (\(why)), so Steam started its own.")
        }
        problems += f.unhandled.map { "Unhandled exception: \($0)" }
        if let words = dockWords(f.dock) { problems.append("Madeira Dock: \(words)") }
        out.append("")
        out.append(problems.isEmpty ? "Problems found: none of the known signs." : "Problems found:")
        out += problems.map { "  ! " + $0 }

        let ends = f.processes.filter { $0.exitCode != nil }
        if !ends.isEmpty || f.quitAsked != nil || f.forceClosed {
            out.append("")
            out.append("How it ended:")
            for p in ends {
                let code = p.exitCode!
                let words = code == 0 ? "exit code 0 (normal)" : code >= 0xC0000000
                    ? String(format: "Windows error 0x%08X", code) + (LogSummary.errorMeanings[code].map { " (\($0))" } ?? "")
                    : "exit code \(code)"
                out.append("  \(p.image) ended itself with \(words)" + (p.endedAt.map { " around \($0)" } ?? ""))
            }
            if let asked = f.quitAsked { out.append("  Quit game was pressed at \(asked)") }
            if f.forceClosed { out.append("  Madeira was force-closed") }
        }

        let other = f.missing.filter { $0.status != "c0000017" }
        out.append("")
        if other.isEmpty {
            out.append("Missing DLLs: none that matter" + (f.harmlessMissing > 0 ? " (\(f.harmlessMissing) known harmless ones skipped)." : "."))
        } else {
            out.append("Missing DLLs (may be harmless: programs often look for optional ones; \(f.harmlessMissing) known harmless ones skipped):")
            out += other.prefix(20).map {
                "  \($0.name)" + ($0.status == "c000007b" ? " (wrong architecture)" : "") + ($0.program.map { " - \($0)" } ?? "")
            }
            if other.count > 20 { out.append("  ... and \(other.count - 20) more") }
        }

        if f.poolMB != nil || f.poolPeak > 0 {
            out.append("")
            var pool = "JIT pool: " + (f.poolMB.map { "\($0) MB" } ?? "size not logged")
            if f.poolPeak > 0 { pool += ", peak use \(mb(f.poolPeak)) MB" + (f.poolTotal > 0 ? " of \(mb(f.poolTotal)) MB" : "") }
            if let tail = f.tailGrants.max() { pool += ", largest code cache \(mb(tail)) MB" }
            out.append(pool)
        }
        if let launch = f.dock["launch-client-error"] {
            out.append("Steam launch: " + (launch == "0" ? "accepted" : "refused, error \(launch)")
                + (f.dock["probe-result"].map { ", Madeira Dock result \($0)" } ?? ""))
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func dockWords(_ fields: [String: String]) -> String? {
        if fields["probe-result"] != nil { return MadeiraDock.Report(fields: fields).failure }
        // No result yet (the log ended first): Steam's refusal is still worth naming.
        if let error = fields["launch-client-error"].flatMap(Int.init), error != 0 {
            return MadeiraDock.Report.launchRefusal(error, waited: false)
        }
        return nil
    }

    /// Summarizes `log` into Documents/madeira-summary.txt. A log with no session
    /// in it (the app was opened and closed) leaves the last summary in place.
    @discardableResult
    static func write(from log: URL, source: String) -> Bool {
        guard let f = facts(fromFileAt: log), f.sawSession else { return false }
        let out = log.deletingLastPathComponent().appendingPathComponent(fileName)
        do {
            try text(f, source: source).write(to: out, atomically: true, encoding: .utf8)
            keepGameLog(log)
            return true
        } catch {
            fputs("[log-summary] could not write \(fileName): \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    /// Documents/madeira-last-game-log.txt: a copy of the last log that had a game
    /// session in it, which Get Help from Claude shares (ClaudeHelp.swift). Without
    /// it, opening Madeira twice after a game leaves only logs with no game in them.
    static let gameLogName = "madeira-last-game-log.txt"
    static func keepGameLog(_ log: URL) {
        guard log.lastPathComponent != gameLogName else { return }
        let fm = FileManager.default
        let target = log.deletingLastPathComponent().appendingPathComponent(gameLogName)
        let temp = log.deletingLastPathComponent().appendingPathComponent(gameLogName + ".part")
        try? fm.removeItem(at: temp)
        guard (try? fm.copyItem(at: log, to: temp)) != nil else { return }
        // The copy is complete before it takes the old one's place.
        try? fm.removeItem(at: target)
        if (try? fm.moveItem(at: temp, to: target)) == nil { try? fm.removeItem(at: temp) }
    }

    /// In the background: logs never block the UI.
    static func writeLater(from log: URL, source: String) {
        DispatchQueue.global(qos: .utility).async {
            if write(from: log, source: source) { fputs("[log-summary] wrote \(fileName) from \(source)\n", stderr) }
        }
    }

    // MARK: Helpers

    /// What the common Windows error codes mean, in plain words.
    static let errorMeanings: [UInt32: String] = [
        0xC0000005: "a crash: the program used memory it may not",
        0xC000001D: "an instruction this CPU lacks: try Game details > Compatibility > AVX and AVX2",
        0xC0000135: "a DLL it needs is missing: see Missing DLLs",
        0xC0000142: "a DLL failed to start",
        0xC0000409: "the program stopped itself after finding damaged memory",
        0xC0000374: "damaged memory (heap corruption)",
        0xC00000FD: "a stack overflow",
        0xC0000017: "out of memory",
        0xC000041D: "a crash inside a window callback",
    ]

    static func mb(_ bytes: UInt64) -> UInt64 { (bytes >> 20) + (bytes & ((1 << 20) - 1) >= 1 << 19 ? 1 : 0) }

    /// "[22:02:40.902] ..." -> "22:02:40"
    static func timestamp(_ line: String) -> String? {
        guard line.hasPrefix("["), line.count > 10 else { return nil }
        let t = line.dropFirst().prefix(8)
        guard t.count == 8, t.allSatisfy({ $0.isNumber || $0 == ":" }), t.filter({ $0 == ":" }).count == 2 else { return nil }
        return String(t)
    }

    /// Wine's "00ac:err:..." thread id.
    static func threadID(_ line: String) -> String? {
        let id = line.prefix(4)
        guard id.count == 4, id.allSatisfy(\.isHexDigit), line.dropFirst(4).hasPrefix(":") else { return nil }
        return String(id)
    }

    /// The text between `marker` and the next unescaped quote, with Wine's `\\` undone.
    static func quoted(_ line: String, after marker: String) -> String? {
        guard let r = line.range(of: marker) else { return nil }
        var out = "", escaped = false
        for c in line[r.upperBound...] {
            if escaped { out.append(c); escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { return out } else { out.append(c) }
        }
        return out
    }

    static func baseName(_ path: String) -> String {
        String(path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? Substring(path))
    }

    /// "tid=00ac pid=00a8 requester=008c rev=ml586" -> fields
    static func fields(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for word in text.split(separator: " ") {
            guard let eq = word.firstIndex(of: "=") else { continue }
            out[String(word[..<eq])] = String(word[word.index(after: eq)...])
        }
        return out
    }

    /// "used=0x78000/0x23000000" -> (0x78000, 0x23000000)
    static func hexPair(_ line: String, after marker: String) -> (UInt64, UInt64)? {
        guard let r = line.range(of: marker) else { return nil }
        let rest = line[r.upperBound...]
        let a = rest.prefix { $0.isHexDigit }
        guard let used = UInt64(a, radix: 16) else { return nil }
        let after = rest.dropFirst(a.count)
        guard after.hasPrefix("/0x") else { return (used, 0) }
        return (used, UInt64(after.dropFirst(3).prefix { $0.isHexDigit }, radix: 16) ?? 0)
    }
}
