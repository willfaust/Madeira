// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// MARK: - Steam install scripts

/// One "Run Process" entry of a game's Steam install script (installscript.vdf).
/// Valve's desktop client runs the entry's programs (typically runtime
/// redistributables) before a start unless the registry value `name` under `key`
/// is at least `value`, and records it once they have run (Steamworks, "Creating
/// and using InstallScripts").
struct SteamInstallRun: Equatable, Hashable, Sendable, Codable {
    enum Hive: String, Sendable, Codable { case machine, user }
    var name: String
    var hive: Hive
    var key: String      // under the hive, e.g. Software\Valve\Steam\Apps\<appid>
    var value: UInt32    // MinimumHasRunValue, else 1
}

/// One program of a "Run Process" entry, resolved to a Windows path.
struct SteamInstallProcess: Equatable, Sendable {
    var run: SteamInstallRun
    var executable: String      // C:\...
    var arguments: String
}

/// Reading install scripts and recording runs in the prefix's registry files.
/// The .reg files are only written while no session runs: the wineserver keeps
/// the registry in memory and writes it back when it stops.
enum SteamInstallScripts {
    static let maxScriptBytes = 1 << 20

    /// "HKEY_LOCAL_MACHINE\Software\..." -> (.machine, "Software\...").
    static func hive(_ path: String) -> (SteamInstallRun.Hive, String)? {
        let parts = path.replacingOccurrences(of: "/", with: "\\").split(separator: "\\").map(String.init)
        guard let first = parts.first?.uppercased() else { return nil }
        let rest = parts.dropFirst().joined(separator: "\\")
        switch first {
        case "HKEY_LOCAL_MACHINE", "HKLM": return (.machine, rest)
        case "HKEY_CURRENT_USER", "HKCU": return (.user, rest)
        default: return nil
        }
    }

    /// The keys a run is recorded under. A 32-bit reader sees HKLM\Software through
    /// Wow6432Node in a 64-bit prefix; the plain key covers a 64-bit reader.
    static func keys(_ run: SteamInstallRun) -> [String] {
        let lower = run.key.lowercased()
        guard run.hive == .machine, lower.hasPrefix("software\\"), !lower.hasPrefix("software\\wow6432node\\") else { return [run.key] }
        return [run.key, "Software\\Wow6432Node\\" + run.key.dropFirst("software\\".count)]
    }

    /// Install scripts: .vdf files with a "Run Process" section in `folder` and up to
    /// `depth` levels below it. Symbolic links are not followed.
    static func scripts(folder: URL, depth: Int = 1) -> [URL] {
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        for item in items.sorted(by: { $0.path < $1.path }).prefix(500) {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                if depth > 0 { found += scripts(folder: item, depth: depth - 1) }
            } else if item.pathExtension.lowercased() == "vdf", (values.fileSize ?? .max) <= maxScriptBytes,
                      let contents = try? Data(contentsOf: item),
                      String(decoding: contents, as: UTF8.self).range(of: "run process", options: .caseInsensitive) != nil {
                found.append(item)
            }
        }
        return found
    }

    /// Where Valve's client records an entry that names no "HasRunKey": a DWORD named
    /// after the entry (lowercase, as its script parser keys it) under the app's own key.
    static func defaultRunKey(appID: Int) -> String { "Software\\Valve\\Steam\\Apps\\\(appID)" }

    /// The "HasRunKey" of an entry's fields, else (with a valid `appID` and a program to
    /// run) the per-app default key in full-path form.
    static func runKey(_ fields: [String: String], appID: Int?) -> String? {
        if let key = fields["hasrunkey"] { return key }
        guard let appID, appID > 0, appID < 1 << 31, fields.keys.contains(where: { $0.hasPrefix("process ") }) else { return nil }
        return "HKEY_LOCAL_MACHINE\\" + defaultRunKey(appID: appID)
    }

    /// Every "Run Process" entry with its fields (lowercased keys), read straight from the
    /// text. Scripts repeat the "Run Process" key, one section per installer, so a
    /// key-value reader that keeps the last copy of a repeated key would miss entries.
    static func entries(script: Data, appID: Int? = nil) -> [(SteamInstallRun, [String: String])] {
        var bytes = Array(script.prefix(maxScriptBytes))
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        var position = 0
        func token() -> (text: String, quoted: Bool)? {
            while position < bytes.count {
                if bytes[position] <= 32 { position += 1; continue }
                if bytes[position] == 47, position + 1 < bytes.count, bytes[position + 1] == 47 {
                    while position < bytes.count, bytes[position] != 10 { position += 1 }
                    continue
                }
                break
            }
            guard position < bytes.count else { return nil }
            let first = bytes[position]; position += 1
            if first == 123 { return ("{", false) }
            if first == 125 { return ("}", false) }
            var value: [UInt8] = []
            if first == 34 {
                while position < bytes.count {
                    let byte = bytes[position]; position += 1
                    if byte == 34 { break }
                    if byte == 92, position < bytes.count, bytes[position] == 34 || bytes[position] == 92 { value.append(bytes[position]); position += 1 }
                    else { value.append(byte) }
                }
                return (String(decoding: value, as: UTF8.self), true)
            }
            value.append(first)
            while position < bytes.count, bytes[position] > 32, bytes[position] != 123, bytes[position] != 125 { value.append(bytes[position]); position += 1 }
            return (String(decoding: value, as: UTF8.self), true)
        }
        var result: [(SteamInstallRun, [String: String])] = []
        var path: [String] = []          // keys of the open sections, lowercased
        var pending: String?             // a key waiting for its value or section
        var fields: [String: String] = [:]
        var tokens = 0
        while let (text, quoted) = token() {
            tokens += 1
            if tokens > 200_000 || path.count > 32 { break }
            if !quoted && text == "{" {
                path.append(pending?.lowercased() ?? ""); pending = nil
                if path.count >= 2, path[path.count - 2] == "run process" { fields = [:] }
            } else if !quoted && text == "}" {
                // An entry section closes: path is [..., "run process", <entry>].
                if path.count >= 2, path[path.count - 2] == "run process", let name = path.last,
                   let key = runKey(fields, appID: appID), let (hive, sub) = hive(key), !sub.isEmpty {
                    let minimum = fields["minimumhasrunvalue"].flatMap { UInt32($0.trimmingCharacters(in: .whitespaces)) } ?? 1
                    let run = SteamInstallRun(name: name, hive: hive, key: sub, value: max(1, minimum))
                    if !result.contains(where: { $0.0 == run }) { result.append((run, fields)) }
                }
                if !path.isEmpty { path.removeLast() }
                pending = nil
            } else if let key = pending {
                if path.count >= 2, path[path.count - 2] == "run process" { fields[key.lowercased()] = text }
                pending = nil
            } else {
                pending = text
            }
        }
        return result
    }

    /// The .reg text with every run's value at least its minimum, and how many values changed.
    /// Wine's format: "[Key\\Sub] <time>" section headers, then "\"name\"=dword:00000001" lines.
    static func mark(_ runs: [SteamInstallRun], in text: String, now: Int) -> (text: String, changed: Int) {
        var lines = text.components(separatedBy: "\n")
        var changed = 0
        for run in runs {
            let valueName = "\"" + escape(run.name) + "\"="
            let valueLine = valueName + String(format: "dword:%08x", run.value)
            for key in keys(run) {
                let header = "[" + escape(key) + "]"
                if let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(header.lowercased()) }) {
                    var end = start + 1
                    while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
                    if let index = (start + 1..<end).first(where: { lines[$0].lowercased().hasPrefix(valueName.lowercased()) }) {
                        if let current = dword(lines[index]), current >= run.value { continue }
                        lines[index] = valueLine
                    } else {
                        var at = end
                        while at > start + 1, lines[at - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { at -= 1 }
                        lines.insert(valueLine, at: at)
                    }
                } else {
                    while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.removeLast() }
                    lines += ["", header + " \(now)", valueLine, ""]
                }
                changed += 1
            }
        }
        return (lines.joined(separator: "\n"), changed)
    }

    /// The .reg text without the runs' values (both views), and how many lines were removed.
    /// Only the value named after each entry goes; the key and its other values stay.
    static func unmark(_ runs: [SteamInstallRun], in text: String) -> (text: String, removed: Int) {
        var lines = text.components(separatedBy: "\n")
        var removed = 0
        for run in runs {
            let valueName = ("\"" + escape(run.name) + "\"=").lowercased()
            for key in keys(run) {
                let header = ("[" + escape(key) + "]").lowercased()
                guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(header) }) else { continue }
                var index = start + 1
                while index < lines.count, !lines[index].hasPrefix("[") {
                    if lines[index].lowercased().hasPrefix(valueName) { lines.remove(at: index); removed += 1 } else { index += 1 }
                }
            }
        }
        return (lines.joined(separator: "\n"), removed)
    }

    /// Records the runs in the prefix's system.reg and user.reg (a .madeira-bak copy is kept
    /// once). Returns the number of values written. Only while no session runs.
    @discardableResult
    static func mark(_ runs: [SteamInstallRun], prefix: URL) throws -> Int {
        let now = Int(Date().timeIntervalSince1970)
        return try rewrite(runs, prefix: prefix) { selected, text in
            let result = mark(selected, in: text, now: now)
            return (result.text, result.changed)
        }
    }

    /// Removes the runs' records from the prefix's system.reg and user.reg (the same
    /// .madeira-bak copy is kept once). Returns the number of values removed. Only while no
    /// session runs.
    @discardableResult
    static func unmark(_ runs: [SteamInstallRun], prefix: URL) throws -> Int {
        try rewrite(runs, prefix: prefix) { selected, text in
            let result = unmark(selected, in: text)
            return (result.text, result.removed)
        }
    }

    /// Applies `change` (new text, values changed) to each hive file that holds some of the
    /// runs and writes the files it changed. Returns the total of values changed.
    private static func rewrite(_ runs: [SteamInstallRun], prefix: URL,
                                _ change: ([SteamInstallRun], String) -> (String, Int)) throws -> Int {
        var total = 0
        for (hive, file) in [(SteamInstallRun.Hive.machine, "system.reg"), (.user, "user.reg")] {
            let selected = runs.filter { $0.hive == hive }
            guard !selected.isEmpty else { continue }
            let registry = prefix.appendingPathComponent(file)
            guard let contents = try? Data(contentsOf: registry), !contents.isEmpty else { continue }   // a prefix not seeded yet
            let (updated, changed) = change(selected, String(decoding: contents, as: UTF8.self))
            guard changed > 0 else { continue }
            let backup = registry.appendingPathExtension("madeira-bak")
            if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: registry, to: backup) }
            try Data(updated.utf8).write(to: registry, options: .atomic)
            total += changed
        }
        return total
    }

    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    private static func dword(_ line: String) -> UInt32? {
        guard let range = line.range(of: "=dword:", options: .caseInsensitive) else { return nil }
        return UInt32(line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines), radix: 16)
    }
}

// MARK: - Planning, the batch and its results

/// What a Dock start does with one install-script program.
enum DockInstallStatus: String, Sendable {
    case done          // already recorded in the prefix's registry
    case missing       // the program is not on disk
    case unsupported   // this build cannot run it (see DockInstallers.runnable)
    case pending       // runs in the session before the host
    case limit         // over the per-start limit; runs at a later start
}

struct DockInstallPlanItem: Equatable, Sendable {
    var process: SteamInstallProcess
    var status: DockInstallStatus
    var reason: String? = nil     // why an unsupported program cannot run
}

/// The batch's service-manager step: `.start` runs the Dock executable with
/// `--start-services` before the first installer; `.off` only records "services off".
enum DockInstallServices: Equatable, Sendable {
    case off
    case start(String)
}

/// Valve's client runs a game's install scripts as part of its own launch tasks,
/// before the step Madeira Dock asks it for (LaunchApp), so on the Dock route
/// nothing runs them. Madeira does: every program not yet recorded runs once in
/// the Dock session before the host, from a batch that reports each exit status.
/// Every program is treated alike; nothing is decided by program name.
enum DockInstallScripts {
    /// The programs of one install script. `installDir` replaces %INSTALLDIR% (a Windows
    /// path). `appID` records entries without a "HasRunKey" under Steam's per-app key.
    static func processes(script: Data, installDir: String, appID: Int? = nil) -> [SteamInstallProcess] {
        var result: [SteamInstallProcess] = []
        for (run, fields) in SteamInstallScripts.entries(script: script, appID: appID) {
            let numbers = fields.keys.compactMap { key -> Int? in
                guard key.hasPrefix("process ") else { return nil }
                return Int(key.dropFirst("process ".count).trimmingCharacters(in: .whitespaces))
            }.sorted()
            for number in numbers.prefix(8) {
                guard let raw = fields["process \(number)"], !raw.isEmpty, raw.utf8.count <= 1024 else { continue }
                let exe = expand(raw, installDir: installDir)
                let lower = exe.lowercased()
                guard exe.count > 3, exe.hasPrefix("C:\\"), !exe.contains("%"), !exe.contains("\""),
                      !exe.contains(".."), lower.hasSuffix(".exe") || lower.hasSuffix(".msi") else { continue }
                let args = expand(fields["command \(number)"] ?? "", installDir: installDir, path: false)
                    .trimmingCharacters(in: .whitespaces)
                // No cmd.exe metacharacters: the arguments go into a batch line as they are.
                guard args.utf8.count <= 1024, !args.contains("\r"), !args.contains("\n"), !args.contains("&"),
                      !args.contains("|"), !args.contains(">"), !args.contains("<"), !args.contains("^"),
                      !args.contains("%") else { continue }
                let process = SteamInstallProcess(run: run, executable: exe, arguments: args)
                if !result.contains(process) { result.append(process) }
            }
        }
        return result
    }

    /// A program path gets Windows separators; an argument list keeps its "/switches".
    static func expand(_ text: String, installDir: String, path: Bool = true) -> String {
        var value = path ? text.replacingOccurrences(of: "/", with: "\\") : text
        value = value.replacingOccurrences(of: "%INSTALLDIR%", with: installDir, options: .caseInsensitive)
        if path { while value.contains("\\\\") { value = value.replacingOccurrences(of: "\\\\", with: "\\") } }
        return value
    }

    /// The value a run has in a Wine .reg text (highest of both views), nil when absent.
    static func recorded(_ run: SteamInstallRun, in text: String) -> UInt32? {
        let lines = text.components(separatedBy: "\n")
        let valueName = ("\"" + SteamInstallScripts.escape(run.name) + "\"=").lowercased()
        var best: UInt32?
        for key in SteamInstallScripts.keys(run) {
            let header = ("[" + SteamInstallScripts.escape(key) + "]").lowercased()
            guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(header) }) else { continue }
            var index = start + 1
            while index < lines.count, !lines[index].hasPrefix("[") {
                let line = lines[index].lowercased()
                if line.hasPrefix(valueName), let range = line.range(of: "=dword:"),
                   let value = UInt32(line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) {
                    best = max(best ?? 0, value)
                }
                index += 1
            }
        }
        return best
    }

    /// Whether a run is recorded done (value at least its minimum in either view).
    static func marked(_ run: SteamInstallRun, in text: String) -> Bool {
        (recorded(run, in: text) ?? 0) >= run.value
    }

    /// Every program's fate at this start: done first, then whether the program exists,
    /// then whether this build can run it (`runnable` returns the reason it cannot);
    /// at most `limit` programs run per start.
    static func plan(_ found: [SteamInstallProcess], limit: Int = 8,
                     done: (SteamInstallRun) -> Bool, exists: (String) -> Bool,
                     runnable: (SteamInstallProcess) -> String? = { _ in nil }) -> [DockInstallPlanItem] {
        var result: [DockInstallPlanItem] = []
        var queued = 0
        for process in found {
            if done(process.run) { result.append(DockInstallPlanItem(process: process, status: .done)); continue }
            if !exists(process.executable) { result.append(DockInstallPlanItem(process: process, status: .missing)); continue }
            if let reason = runnable(process) {
                result.append(DockInstallPlanItem(process: process, status: .unsupported, reason: reason)); continue
            }
            if queued < limit { queued += 1; result.append(DockInstallPlanItem(process: process, status: .pending)) }
            else { result.append(DockInstallPlanItem(process: process, status: .limit)) }
        }
        return result
    }

    /// The Dock sheet's line about the plan, or nil when every program is already done.
    static func note(_ items: [DockInstallPlanItem]) -> String? {
        func names(_ status: DockInstallStatus) -> String {
            var seen: [String] = []
            for item in items where item.status == status {
                var text = label(item.process.run)
                if let reason = item.reason { text += " (" + reason + ")" }
                if !seen.contains(text) { seen.append(text) }
            }
            return seen.joined(separator: ", ")
        }
        guard items.contains(where: { $0.status != .done }) else { return nil }
        var parts: [String] = []
        if !names(.pending).isEmpty { parts.append("Runs first: " + names(.pending)) }
        if !names(.done).isEmpty { parts.append("Already done: " + names(.done)) }
        if !names(.missing).isEmpty { parts.append("Installer file missing: " + names(.missing)) }
        if !names(.unsupported).isEmpty { parts.append("Cannot run in this build: " + names(.unsupported)) }
        if !names(.limit).isEmpty { parts.append("Next start: " + names(.limit)) }
        return "One-time installs. " + parts.joined(separator: ". ") + "."
    }

    /// A program's label for logs, the batch and the sheet: the entry name, reduced to
    /// safe characters.
    static func label(_ run: SteamInstallRun) -> String {
        String(run.name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "." || $0 == "-" || $0 == "_" }.prefix(64))
    }

    /// The batch the Dock session runs before the host. Each program's start and exit
    /// status are appended to `resultFile` ("start <i> <label>", "exit <i> <status>"; every
    /// redirection follows a space, so a status digit is never read as a handle number).
    /// The batch records nothing in the registry itself: Madeira records the programs that
    /// exited with 0, 3010 or 1641 (installed, restart requested) at the next Dock start,
    /// when no session runs (DockInstallers.absorbResults).
    ///
    /// `services` first makes Wine's service manager reachable (`dockhost.exe
    /// --start-services` prints "services <outcome>" into the result file; "services failed"
    /// when it could not run) or records "services off".
    static func batch(_ processes: [SteamInstallProcess], resultFile: String, services: DockInstallServices) -> String {
        let result = " >>\"" + resultFile.replacingOccurrences(of: "\"", with: "") + "\""
        var lines = ["@echo off", "rem Madeira Dock: a game's one-time installs, before the host starts the game",
                     "echo begin \(processes.count)" + result.replacingOccurrences(of: " >>", with: " >")]
        switch services {
        case .off: lines.append("echo services off" + result)
        case .start(let executable):
            lines.append("\"" + executable.replacingOccurrences(of: "\"", with: "") + "\" --start-services" + result)
            lines.append("if not \"%ERRORLEVEL%\"==\"0\" echo services failed" + result)
        }
        for (offset, process) in processes.enumerated() {
            let index = offset + 1
            let quoted = "\"" + process.executable + "\""
            let command = process.executable.lowercased().hasSuffix(".msi")
                ? "C:\\windows\\system32\\msiexec.exe /i " + quoted + (process.arguments.isEmpty ? "" : " " + process.arguments)
                : "call " + quoted + (process.arguments.isEmpty ? "" : " " + process.arguments)
            let text = label(process.run)
            lines.append("echo [dock-installers] running \(index)/\(processes.count) " + text)
            lines.append("echo start \(index) " + text + result)
            lines.append(command)
            lines.append("echo exit \(index) %ERRORLEVEL%" + result)
        }
        lines.append("echo end" + result)
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// A result file read back: programs in the batch, which started (index -> label),
    /// which exited (index -> status), the service step's outcome and whether the batch ended.
    struct Results: Equatable, Sendable {
        var total = 0
        var started: [Int: String] = [:]
        var exits: [Int: Int] = [:]
        var ended = false
        var services: String?
        var running: Int? { started.keys.filter { exits[$0] == nil }.max() }
        static func succeeded(_ status: Int) -> Bool { status == 0 || status == 3010 || status == 1641 }
    }

    static func results(_ text: String) -> Results {
        var results = Results()
        // cmd.exe writes CRLF; "\r\n" is one Character, so split on any newline Character.
        for raw in text.split(whereSeparator: { $0.isNewline }).prefix(200) {
            let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
            guard let verb = parts.first else { continue }
            switch verb {
            case "begin":
                results.total = parts.count > 1 ? min(Int(parts[1]) ?? 0, 64) : 0
            case "start":
                if parts.count > 1, let index = Int(parts[1]), (1...64).contains(index) {
                    results.started[index] = parts.count > 2 ? String(parts[2].prefix(64)) : ""
                }
            case "exit":
                if parts.count > 2, let index = Int(parts[1]), (1...64).contains(index),
                   let status = Int(parts[2].trimmingCharacters(in: .whitespaces)) { results.exits[index] = status }
            case "services":
                let word = parts.count > 1 ? String(parts[1].filter { $0.isLetter }.prefix(16)) : ""
                if !word.isEmpty { results.services = word }
            case "end":
                results.ended = true
            default:
                continue
            }
        }
        return results
    }
}

/// A request for one game's one-time installs, saved from the app at any time and applied
/// at that game's next Dock start, while no session runs (the registry is on disk then).
enum DockInstallRequest: String, Sendable {
    /// Record the game's own install-script programs as done: for an installer that did its
    /// work but never closed, so its batch never saw an exit status.
    case record
    /// Forget the game's own recorded programs and choose Run at next start, so they run
    /// again (for a clean reinstall). madeira-bcd: what the installers put into the prefix
    /// moves into a backup first (DockReset.swift; MADEIRA_DOCK_RESET_CLEAN=0: files stay).
    case reset
    /// madeira-bcd: `reset`, and the Rockstar launcher's and Social Club's sign-in data goes too.
    case resetSignOut = "reset-signout"
}

/// Kept next to the prefix's registry files, one small JSON file: the programs the last
/// batch runs, in its order (result lines refer to them by index), and each game's
/// One-time installs choice.
struct DockInstallLedger: Codable, Equatable, Sendable {
    static let fileName = "madeira-dock-installs.json"
    var session: [SteamInstallRun] = []
    var sessionApp: Int = 0
    /// App ID -> false: the game's next Dock start skips its one-time installs (Skip).
    /// Absent or true: the next start runs the pending ones ("Run at next start").
    var runNext: [String: Bool] = [:]
    /// App ID -> entry names the game's last batch started but never saw exit (an installer
    /// window that stayed open, a session ended early). Optional, like `requests`, so files
    /// written before these fields existed still load.
    var unfinished: [String: [String]]? = nil
    /// App ID -> the request its next Dock start applies (DockInstallers.applyRequest), by raw
    /// value: a value this build does not know reads as no request instead of a damaged file.
    var requests: [String: String]? = nil

    static func load(prefix: URL) -> DockInstallLedger {
        let file = prefix.appendingPathComponent(fileName)
        guard let contents = try? Data(contentsOf: file), contents.count <= 1 << 20,
              let ledger = try? JSONDecoder().decode(DockInstallLedger.self, from: contents) else { return DockInstallLedger() }
        return ledger
    }
    func save(prefix: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: prefix.appendingPathComponent(Self.fileName), options: .atomic)
    }
    func runsNext(_ appID: Int) -> Bool { runNext[String(appID)] != false }
    func request(_ appID: Int) -> DockInstallRequest? {
        guard let raw = requests?[String(appID)] else { return nil }
        return DockInstallRequest(rawValue: raw)
    }
    func unfinishedRuns(_ appID: Int) -> [String] { unfinished?[String(appID)] ?? [] }

    /// Sets or clears a game's request; an empty map is stored as absent.
    mutating func setRequest(_ appID: Int, _ request: DockInstallRequest?) {
        var map = requests ?? [:]
        map[String(appID)] = request?.rawValue
        requests = map.isEmpty ? nil : map
    }

    /// Sets or clears a game's unfinished entries; an empty map is stored as absent.
    mutating func setUnfinished(_ appID: Int, _ names: [String]) {
        var map = unfinished ?? [:]
        map[String(appID)] = names.isEmpty ? nil : names
        unfinished = map.isEmpty ? nil : map
    }
}

// MARK: - A Dock start's one-time installs

/// The app side: plan the game's programs before a Dock start, write the batch the
/// session runs before the host, report progress, and record results at the next start.
///
/// Switches (`env.NAME` in madeira.cfg; "0" turns one off):
/// - `MADEIRA_DOCK_INSTALLERS`: the whole feature.
/// - `MADEIRA_INSTALL_DEFAULT_KEY`: entries without a "HasRunKey" use Steam's per-app key
///   (off: such entries are ignored).
/// - `MADEIRA_DOCK_INSTALL_CHOICE`: the per-game One-time installs choice (off: every start
///   runs whatever is pending).
/// - `MADEIRA_DOCK_INSTALL_SCM`: the service-manager step before the first installer.
/// - `MADEIRA_DOCK_INSTALL_SERVER_SYNC`: a start that runs installers turns madsync off for
///   its session (off: madsync stays and the service-manager step is left out).
/// - `MADEIRA_DOTNET_FUSION`: place Wine's fusion.dll in the .NET 2.0 folder when missing.
/// - `MADEIRA_INSTALL_SKIP_DOTNET`: .NET Framework 2.0-4.x setups are left out (Wine's own
///   .NET answers for them; off: they run like any other program).
/// - `MADEIRA_DOCK_INSTALL_SEPARATE` (madeira-bcd): a start that runs installers runs only
///   them; the game starts after Madeira is restarted (off: the host follows in the same session).
/// - `MADEIRA_DOCK_RESET_CLEAN` (madeira-bcd): Reset also moves what the installers put into
///   the prefix into a backup (DockReset.swift; off: only the records are forgotten).
@MainActor
enum DockInstallers {
    static let scriptName = "madeira-dock-installers.cmd"
    static let resultName = "madeira-dock-installers.result"

    /// The batch this start runs before the host (a C:\ path), nil when none runs.
    private(set) static var script: String?
    /// madeira-bcd: this start's session runs only the installers, not the host. In one session
    /// the installers' copies in the JIT pool left Red Dead Redemption 2 too little room at its
    /// start, and it stopped while loading (log 2026-10-12 08:13: "[jit-pool] EXHAUSTED"); a
    /// session of their own also leaves madsync on for the game. One session runs per app run,
    /// so the game starts after a restart of Madeira.
    private(set) static var installsOnly = false
    /// ml2020: the game's install-script programs recorded (or about to run) under a registry key
    /// that is not Microsoft's: a publisher's launcher, runtime or anti-cheat, which may register
    /// and start a Windows service of its own (DockGameSession.isMicrosoftKey; the game session's
    /// service manager decision reads this).
    private(set) static var thirdPartyInstalls = 0
    nonisolated static let restartWords = "To start the game, restart Madeira: swipe it away in the app switcher, open it again and start the game."
    /// What the starting screen says once the installs ended, until the session has closed (the
    /// wineserver writes the registry to disk as it stops; Madeira asks for the restart then).
    nonisolated static let closingWords = "This session now closes. Madeira asks you to restart it when it has; wait for that."
    /// madeira-bcd: the game's lines a session of one-time installs runs without. Social Club's
    /// layout 2 (env.MADEIRA_SC_PA_POOLS) and RDR2's hold (env.MADEIRA_RDR2_VA_HOLD) take the
    /// 4 GB slots 32-bit programs run in, so the Visual C++ setups' second 32-bit process could
    /// not start ([wow-window] REJECTED, BOOT FAILED 'guest-window-reserve', exit 0x8007054f; logs
    /// 2026-10-03 16:00 and 2026-10-12 10:00). Both serve the game's Social Club only; the game's
    /// other lines stay (the Rockstar Service install needs env.MADEIRA_EXECREQ_LEAVE).
    nonisolated static let installSessionDroppedKeys: Set<String> = ["env.MADEIRA_SC_PA_POOLS", "env.MADEIRA_RDR2_VA_HOLD"]

    /// madeira-bcd: for a session of one-time installs (the app sets MADEIRA_DOCK_INSTALLS_SESSION),
    /// the game's config file (MADEIRA_CFG_GAME) is replaced by a copy without
    /// `installSessionDroppedKeys`. Returns the keys left out. MADEIRA_DOCK_INSTALL_LAYOUT=0 keeps
    /// every line.
    nonisolated static func applyInstallSessionConfig(directory: URL? = MadeiraConfig.gameURL?.deletingLastPathComponent()) -> [String] {
        guard ProcessInfo.processInfo.environment["MADEIRA_DOCK_INSTALLS_SESSION"] == "1",
              flag("MADEIRA_DOCK_INSTALL_LAYOUT"),   // 0: a session of one-time installs keeps the game's layout lines
              let path = ProcessInfo.processInfo.environment["MADEIRA_CFG_GAME"], !path.isEmpty,
              let text = try? String(contentsOfFile: path, encoding: .utf8), let directory else { return [] }
        var dropped: [String] = []
        let kept = text.components(separatedBy: "\n").filter { line in
            let key = line.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard installSessionDroppedKeys.contains(key) else { return true }
            dropped.append(key)
            return false
        }
        guard !dropped.isEmpty else { return [] }
        let copy = directory.appendingPathComponent("madeira-game-installs.cfg")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try kept.joined(separator: "\n").write(to: copy, atomically: true, encoding: .utf8)
        } catch {
            return []
        }
        setenv("MADEIRA_CFG_GAME", copy.path, 1)
        return dropped
    }
    /// This start runs installers and turns madsync off for its session.
    private(set) static var serverSync = false
    /// This start's plan in words (the Dock sheet's status), nil when there is nothing to say.
    private(set) static var note: String?
    /// When poll first read the batch's end: the host starts next. nil before, and
    /// for a start without installs.
    private(set) static var finishedAt: Date?
    private static var logged: Set<String> = []
    /// The program poll last saw running and when it first saw it (the stall notice).
    private static var runningSince: (index: Int, at: Date)?
    /// After this long on one program, poll logs a notice and the status names the
    /// minutes. Nothing is stopped: an installer may legitimately take long.
    static let stallSeconds = 600

    nonisolated static func flag(_ name: String) -> Bool { SteamSignIn.flag(name, default: true) }
    nonisolated static var enabled: Bool { flag("MADEIRA_DOCK_INSTALLERS") }   // 0: Dock starts run no install-script programs
    nonisolated static var choiceEnabled: Bool { enabled && flag("MADEIRA_DOCK_INSTALL_CHOICE") }   // 0: no per-game choice, every start runs what is pending

    /// Whether madeira.cfg selects madsync, as the engine reads it (madeira_cfg_sync_engine
    /// in build/madeira_cfg.h): only inproc-sync set to 1/on/true/yes; unset is fastsync,
    /// the default engine.
    static var madsyncConfigured: Bool {
        guard let value = MadeiraConfig.get("inproc-sync") else { return false }
        return ["1", "on", "true", "yes"].contains(value)
    }

    // MARK: Finding programs

    /// The install scripts' programs of a game: its own folder (one level down) and the
    /// shared redistributables Steam keeps next to it, and how many scripts were read.
    nonisolated static func found(_ game: DockGame, drive: URL,
                                  defaultKey: Bool = DockInstallers.flag("MADEIRA_INSTALL_DEFAULT_KEY")) -> (processes: [SteamInstallProcess], scripts: Int) {
        let common = game.library + "/common"
        let shared = common + "/Steamworks Shared"
        func windows(_ relative: String) -> String { "C:\\" + relative.replacingOccurrences(of: "/", with: "\\") }
        let roots: [(URL, Int, String, Int?)] = [
            (drive.appendingPathComponent(common + "/" + game.installDir, isDirectory: true), 1, game.windowsInstallPath,
             defaultKey ? game.id : nil),
            (drive.appendingPathComponent(shared + "/_CommonRedist", isDirectory: true), 3, windows(shared), nil),
        ]
        var result: [SteamInstallProcess] = []
        var scripts = 0
        for (root, depth, installDir, owner) in roots {
            guard inside(root, drive: drive) else { continue }
            for file in SteamInstallScripts.scripts(folder: root, depth: depth) {
                guard let contents = try? Data(contentsOf: file) else { continue }
                scripts += 1
                for process in DockInstallScripts.processes(script: contents, installDir: installDir, appID: owner)
                where !result.contains(process) {
                    result.append(process)
                }
            }
        }
        return (result, scripts)
    }

    /// The number of install-script programs a game has (the Dock sheet's list).
    nonisolated static func programCount(_ game: DockGame, drive: URL) -> Int {
        enabled ? found(game, drive: drive).processes.count : 0
    }

    nonisolated static func inside(_ url: URL, drive: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(drive.resolvingSymlinksInPath().standardizedFileURL.path + "/")
    }

    /// A C:\ path resolved on disk the way Wine resolves it (case-insensitive), staying
    /// inside drive_c; nil when it does not exist.
    nonisolated static func resolve(_ windowsPath: String, drive: URL) -> URL? {
        guard windowsPath.uppercased().hasPrefix("C:\\"), windowsPath.utf8.count < 1024 else { return nil }
        let parts = windowsPath.dropFirst(3).split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("/") }) else { return nil }
        var current = drive
        for part in parts {
            let exact = current.appendingPathComponent(part)
            if FileManager.default.fileExists(atPath: exact.path) { current = exact }
            else {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                      let match = names.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) else { return nil }
                current.appendPathComponent(match)
            }
            guard inside(current, drive: drive) else { return nil }
        }
        return current
    }

    /// The PE machine of an executable (0x14c: 32-bit x86, 0x8664: x64), nil when unreadable.
    nonisolated static func machine(_ file: URL) -> UInt16? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let dos = try? handle.read(upToCount: 64), dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { return nil }
        let offset = (0..<4).reduce(UInt64(0)) { $0 | UInt64(dos[60 + $1]) << ($1 * 8) }
        guard offset >= 64, offset <= 1 << 20, (try? handle.seek(toOffset: offset)) != nil,
              let header = try? handle.read(upToCount: 6), header.count == 6, header.starts(with: [0x50, 0x45, 0, 0]) else { return nil }
        return UInt16(header[4]) | UInt16(header[5]) << 8
    }

    /// Why this build cannot run a program, nil when it can. Decided by what the program is
    /// (a Windows Installer package, a 32-bit executable) and what the bundle has, never by
    /// its name: a package needs msiexec.exe, a 32-bit executable needs 32-bit support.
    ///
    /// The one exception, with `skipDotNet`: Microsoft's .NET Framework setups (2.0 to 4.x).
    /// Wine answers for the .NET Framework with its own Mono, and these setups do not finish
    /// under it: Batman: Arkham City GOTY's .NET 3.5 setup ("/web /q") sat invisible on
    /// "Extracting Files" and held the game's start (log 2026-10-31 23:22). They are left out,
    /// as GameNative (Wine on Android) does. Newer .NET (Core, 5+) setups still run.
    nonisolated static func runnable(_ process: SteamInstallProcess, drive: URL, has32Bit: Bool, hasMsiexec: Bool,
                                     skipDotNet: Bool = false) -> String? {
        if skipDotNet && isDotNetFramework(process) { return "Wine's own .NET is used" }
        if process.executable.lowercased().hasSuffix(".msi") { return hasMsiexec ? nil : "Windows Installer package" }
        guard let file = resolve(process.executable, drive: drive), let machine = machine(file) else { return nil }
        return machine == 0x14c && !has32Bit ? "32-bit installer" : nil
    }

    /// A .NET Framework 2.0-4.x setup: its file name (as Microsoft and
    /// Steam's _CommonRedist\DotNet ship them) or the Framework's own setup key as the
    /// entry's HasRunKey.
    nonisolated static func isDotNetFramework(_ process: SteamInstallProcess) -> Bool {
        let file = process.executable.split(separator: "\\").last.map { $0.lowercased() } ?? ""
        if file.hasPrefix("dotnetfx") || (file.hasPrefix("ndp") && file.hasSuffix(".exe")) { return true }
        let key = process.run.key.lowercased()
        return key.contains("\\net framework setup\\ndp") || key.contains("\\commonredist\\dotnet\\")
    }

    nonisolated static var bundleHas32Bit: Bool { bundled("i386-windows") }
    nonisolated static var bundleHasMsiexec: Bool {
        ["aarch64-windows", "arm64ec-windows", "i386-windows"].contains { bundled($0 + "/msiexec.exe") }
    }
    nonisolated private static func bundled(_ relative: String) -> Bool {
        guard let root = Bundle.main.resourceURL else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
    }

    // MARK: The choice

    nonisolated static func runsNext(_ appID: Int, prefix: URL) -> Bool { DockInstallLedger.load(prefix: prefix).runsNext(appID) }

    static func setRunsNext(_ appID: Int, _ run: Bool, prefix: URL) {
        var ledger = DockInstallLedger.load(prefix: prefix)
        ledger.runNext[String(appID)] = run ? nil : false
        do { try ledger.save(prefix: prefix) }
        catch { LogStore.shared.log("[dock-installers] app=\(appID) choice not saved: \(error.localizedDescription)", level: .error); return }
        LogStore.shared.log("[dock-installers] app=\(appID) choice=\(run ? "run" : "skip")")
    }

    /// Saves (or with nil cancels) a game's Record as done / Reset request. Nothing changes in
    /// the prefix now: the game's next Dock start applies it before planning (applyRequest).
    static func setRequest(_ appID: Int, _ request: DockInstallRequest?, prefix: URL) {
        var ledger = DockInstallLedger.load(prefix: prefix)
        ledger.setRequest(appID, request)
        do { try ledger.save(prefix: prefix) }
        catch { LogStore.shared.log("[dock-installers] app=\(appID) request not saved: \(error.localizedDescription)", level: .error); return }
        LogStore.shared.log("[dock-installers] app=\(appID) request=\(request?.rawValue ?? "none"); applied at the next Dock start")
    }

    /// The runs of the game's own install-script programs (under its install folder): what
    /// Record as done and Reset act on. Shared Steamworks redistributables serve every game
    /// and are left as they are.
    nonisolated static func own(_ found: [SteamInstallProcess], game: DockGame) -> [SteamInstallRun] {
        let folder = game.windowsInstallPath.lowercased() + "\\"
        var runs: [SteamInstallRun] = []
        for process in found where process.executable.lowercased().hasPrefix(folder) && !runs.contains(process.run) {
            runs.append(process.run)
        }
        return runs
    }

    /// Applies the game's saved request, if any, while no session runs: `.record` writes the
    /// own programs' records (as a finished run would), `.reset` removes them and sets the
    /// choice to Run at next start. The request is cleared either way, and with it the game's
    /// unfinished entries. Returns the request applied.
    /// madeira-bcd: a reset first moves what the installers put into the prefix into a backup
    /// (DockReset.clean; `.resetSignOut` takes the Rockstar sign-in data too). Those are shared:
    /// the games in `others` that record under the same keys or run the same installers get
    /// Run at next start as well (shareReset), so each installs them again.
    @discardableResult
    static func applyRequest(_ game: DockGame, found: [SteamInstallProcess], prefix: URL,
                             drive: URL? = nil, others: [DockGame] = []) -> DockInstallRequest? {
        var ledger = DockInstallLedger.load(prefix: prefix)
        let app = game.id
        guard ledger.requests?[String(app)] != nil else { return nil }
        let request = ledger.request(app)
        ledger.setRequest(app, nil)
        let runs = own(found, game: game)
        let names = runs.map { DockInstallScripts.label($0) }.joined(separator: ",")
        let shared = Set(found.map(\.run)).subtracting(runs).count
        let drive = drive ?? prefix.appendingPathComponent("drive_c", isDirectory: true)
        var changed = 0
        var failure: String?
        var cleaned: DockReset.Summary?
        var alsoRun: [String] = []
        switch request {
        case .record?:
            do { changed = try SteamInstallScripts.mark(runs, prefix: prefix) } catch { failure = error.localizedDescription }
        case .reset?, .resetSignOut?:
            if flag("MADEIRA_DOCK_RESET_CLEAN") {   // 0: Reset only forgets the records; installed files stay
                cleaned = DockReset.clean(drive: drive, prefix: prefix, documents: prefix.deletingLastPathComponent(),
                                          appID: app, signOut: request == .resetSignOut, baseline: DockReset.baselineProvider())
            }
            do { changed = try SteamInstallScripts.unmark(runs, prefix: prefix) } catch { failure = error.localizedDescription }
            if failure == nil {
                ledger.runNext[String(app)] = nil
                if cleaned != nil {
                    alsoRun = shareReset(app, runs: runs, found: found, others: others, drive: drive, prefix: prefix, ledger: &ledger)
                }
            }
        case nil:
            failure = "unknown request"
        }
        if failure == nil { ledger.setUnfinished(app, []) }
        do { try ledger.save(prefix: prefix) }
        catch { LogStore.shared.log("[dock-installers] app=\(app) ledger not saved: \(error.localizedDescription)", level: .error) }
        let tag = request == .record ? "[dock-installers]" : "[dock-reset]"
        let what = request == .record ? "record-as-done: records written"
            : cleaned != nil ? "reset: installed components moved to the backup, records removed, choice=run"
                             : "reset: records removed, choice=run; installed files left in place"
        if let cleaned {
            let failed = cleaned.failures.isEmpty ? "" : " failures=\(cleaned.failures.count)"
            LogStore.shared.log("[dock-reset] app=\(app) clean sign-out=\(request == .resetSignOut ? 1 : 0) moved=\(cleaned.moved.count) " +
                                "entries=\(cleaned.entries.count) keys=\(cleaned.keys) values=\(cleaned.values) " +
                                "template-keys=\(cleaned.restored) backup=Documents/\(cleaned.backup)" + failed,
                                level: cleaned.failures.isEmpty ? .info : .error)
            for path in cleaned.moved { LogStore.shared.log("[dock-reset]   moved C:\\" + path.replacingOccurrences(of: "/", with: "\\")) }
            for entry in cleaned.entries { LogStore.shared.log("[dock-reset]   uninstall entry removed: " + entry) }
            for problem in cleaned.failures { LogStore.shared.log("[dock-reset]   failed: " + problem, level: .error) }
            for other in alsoRun {
                LogStore.shared.log("[dock-reset] app=\(app) also \(other): records removed, choice=run; they share these installs")
            }
        }
        if let failure {
            LogStore.shared.log("\(tag) app=\(app) request=\(request?.rawValue ?? "?") failed: \(failure)", level: .error)
        } else {
            LogStore.shared.log("\(tag) app=\(app) \(what) programs=\(names.isEmpty ? "-" : names) values=\(changed) shared-kept=\(shared)")
        }
        return failure == nil ? request : nil
    }

    /// madeira-bcd: what a reset removed (DockReset.clean) belongs to the prefix, not to one
    /// game. Another installed game whose own programs record under one of the same keys, or
    /// run a program of the same file name (its own copy of the same installer), loses those
    /// records and gets Run at next start, so its next start installs them again. Returns
    /// "app=<id> programs=<labels> values=<removed>" for each such game, for the log.
    static func shareReset(_ app: Int, runs: [SteamInstallRun], found: [SteamInstallProcess], others: [DockGame],
                           drive: URL, prefix: URL, ledger: inout DockInstallLedger) -> [String] {
        func file(_ path: String) -> String { path.split(separator: "\\").last.map { $0.lowercased() } ?? "" }
        func key(_ run: SteamInstallRun) -> String { run.hive.rawValue + "|" + run.key.lowercased() }
        let keys = Set(runs.map { key($0) })
        let files = Set(found.filter { runs.contains($0.run) }.map { file($0.executable) })
        var result: [String] = []
        for other in others where other.id != app && other.installed {
            let theirs = Self.found(other, drive: drive).processes
            let ownRuns = own(theirs, game: other)
            var shared: [SteamInstallRun] = []
            for process in theirs where ownRuns.contains(process.run) && !shared.contains(process.run) {
                if keys.contains(key(process.run)) || files.contains(file(process.executable)) { shared.append(process.run) }
            }
            guard !shared.isEmpty else { continue }
            let removed: Int
            do { removed = try SteamInstallScripts.unmark(shared, prefix: prefix) }
            catch {
                LogStore.shared.log("[dock-reset] app=\(other.id) shared records not removed: \(error.localizedDescription)", level: .error)
                continue
            }
            ledger.runNext[String(other.id)] = nil
            result.append("app=\(other.id) programs=\(shared.map { DockInstallScripts.label($0) }.joined(separator: ",")) values=\(removed)")
        }
        return result
    }

    // MARK: A start

    /// Called right before a Dock start, while no session runs (the registry is on disk).
    /// Records the previous batch's results, plans the game's programs and writes the batch.
    /// `others`: the prefix's other Dock games (a reset's shared installs, applyRequest).
    static func prepare(_ game: DockGame, drive: URL, prefix: URL, others: [DockGame] = [],
                        has32Bit: Bool = DockInstallers.bundleHas32Bit, hasMsiexec: Bool = DockInstallers.bundleHasMsiexec,
                        fusionSource: URL? = Bundle.main.resourceURL?.appendingPathComponent("i386-windows/fusion.dll")) {
        script = nil; serverSync = false; note = nil; finishedAt = nil; logged = []; runningSince = nil; installsOnly = false
        allSucceeded = false; thirdPartyInstalls = 0
        let app = game.id
        let batchFile = drive.appendingPathComponent(scriptName)
        try? FileManager.default.removeItem(at: batchFile)
        absorbResults(reason: "next-start", drive: drive, prefix: prefix)
        try? FileManager.default.removeItem(at: drive.appendingPathComponent(resultName))
        // madeira-bcd: a Vulkan loader an installer wrote into system32 goes back out, so the
        // session links Madeira's stand-in (DockReset.restoreStandIn).
        if flag("MADEIRA_DOCK_VULKAN_STANDIN"),   // 0: a Vulkan loader an installer wrote stays in system32
           let moved = DockReset.restoreStandIn(drive: drive, documents: prefix.deletingLastPathComponent(),
                                                standIn: Bundle.main.resourceURL?.appendingPathComponent("arm64ec-windows/vulkan-1.dll")) {
            LogStore.shared.log("[dock-installers] C:\\" + moved.replacingOccurrences(of: "/", with: "\\") +
                                " (an installer's Vulkan loader) moved to Documents/madeira-reset-backup; this session links Madeira's stand-in")
        }
        guard enabled else {
            LogStore.shared.log("[dock-installers] app=\(app) off (MADEIRA_DOCK_INSTALLERS=0)"); return
        }
        let defaultKey = flag("MADEIRA_INSTALL_DEFAULT_KEY")
        let skipDotNet = flag("MADEIRA_INSTALL_SKIP_DOTNET")   // 0: .NET Framework setups run too
        let (found, scripts) = Self.found(game, drive: drive, defaultKey: defaultKey)
        // A Record as done / Reset request saved since the last start, before the plan reads
        // the registry.
        applyRequest(game, found: found, prefix: prefix, drive: drive, others: others)
        guard !found.isEmpty else {
            LogStore.shared.log("[dock-installers] app=\(app) scripts=\(scripts) programs=0"); return
        }
        let registry = [SteamInstallRun.Hive.machine: "system.reg", .user: "user.reg"].mapValues {
            (try? String(contentsOf: prefix.appendingPathComponent($0), encoding: .utf8)) ?? ""
        }
        let items = DockInstallScripts.plan(found,
                                            done: { DockInstallScripts.marked($0, in: registry[$0.hive] ?? "") },
                                            exists: { resolve($0, drive: drive) != nil },
                                            runnable: { runnable($0, drive: drive, has32Bit: has32Bit, hasMsiexec: hasMsiexec,
                                                                 skipDotNet: skipDotNet) })
        // ml2020: a publisher's program the script installed (or installs now), by its record's
        // key: the game session's service-manager decision (DockGameSession) reads the count.
        thirdPartyInstalls = items.filter { [.done, .pending, .limit].contains($0.status)
                                            && !DockGameSession.isMicrosoftKey($0.process.run.key) }.count
        var pending = items.filter { $0.status == .pending }.map(\.process)
        var ledger = DockInstallLedger.load(prefix: prefix)
        // Programs the game's last batch started but never saw exit (absorbResults).
        let unfinished = Set(ledger.unfinishedRuns(app))
        // The game's One-time installs choice: absent or "Run at next start" runs the pending
        // programs at this start, after which the choice becomes Skip (unless some wait for a
        // later start); Skip starts the game without them. MADEIRA_DOCK_INSTALL_CHOICE=0 ignores it.
        let choiceOn = flag("MADEIRA_DOCK_INSTALL_CHOICE")
        let skipped = choiceOn && !ledger.runsNext(app) && !pending.isEmpty
        if skipped {
            LogStore.shared.log("[dock-installers] app=\(app) choice=skip pending=\(pending.count)")
            pending = []
        } else if choiceOn && !pending.isEmpty && !items.contains(where: { $0.status == .limit }) {
            ledger.runNext[String(app)] = false
            LogStore.shared.log("[dock-installers] app=\(app) choice=run pending=\(pending.count); the next start skips them")
        }
        // Installers expect a service manager, and a Dock session starts none before the
        // host. With madsync, Wine's services.exe never answered its RPC clients in the
        // fork's device runs, so the service step and then every installer waited; msiexec's
        // custom actions use the same RPC server. A start that runs installers therefore
        // turns madsync off for its whole session (MADEIRA_MADSYNC_SESSION=0, set by the
        // caller); later sessions use the configured engine again.
        // MADEIRA_DOCK_INSTALL_SERVER_SYNC=0 keeps madsync and leaves the service step out.
        let sessionOff = !pending.isEmpty && flag("MADEIRA_DOCK_INSTALL_SERVER_SYNC")
        let services: DockInstallServices = flag("MADEIRA_DOCK_INSTALL_SCM") && (sessionOff || !madsyncConfigured)
            ? .start(MadeiraDock.executable) : .off
        if !pending.isEmpty {
            do {
                let text = DockInstallScripts.batch(pending, resultFile: "C:\\" + resultName, services: services)
                try Data(text.utf8).write(to: batchFile, options: .atomic)
                script = "C:\\" + scriptName
                serverSync = sessionOff
                installsOnly = flag("MADEIRA_DOCK_INSTALL_SEPARATE")   // 0: the host follows the installers in the same session
            } catch {
                LogStore.shared.log("[dock-installers] app=\(app) batch not written: \(error.localizedDescription)", level: .error)
            }
        }
        ledger.session = script != nil ? pending.map(\.run) : []
        ledger.sessionApp = ledger.session.isEmpty ? 0 : app
        do { try ledger.save(prefix: prefix) }
        catch { LogStore.shared.log("[dock-installers] app=\(app) ledger not saved: \(error.localizedDescription)", level: .error) }
        for item in items {
            let run = item.process.run
            let recorded = DockInstallScripts.recorded(run, in: registry[run.hive] ?? "").map { String($0) } ?? "-"
            let file = item.process.executable.split(separator: "\\").last.map(String.init) ?? ""
            let lastRun: String = item.status != .done && unfinished.contains(run.name) ? " last-run=unfinished" : ""
            LogStore.shared.log("[dock-installers] app=\(app) program=\(DockInstallScripts.label(run)) file=\(file) " +
                                "status=\(item.status.rawValue)\(item.reason.map { " reason=" + $0.replacingOccurrences(of: " ", with: "-") } ?? "") " +
                                "key=\(run.hive == .machine ? "HKLM" : "HKCU")\\\(run.key) recorded=\(recorded) minimum=\(run.value)\(lastRun)")
        }
        if skipped {
            note = "One-time installs skipped. To run them, choose Run at next start under One-time installs."
        } else {
            note = DockInstallScripts.note(items)
            if installsOnly {
                note = (note.map { $0 + " " } ?? "") + "This start runs only them; afterwards restart Madeira and start the game again."
            } else if serverSync && madsyncConfigured {
                note = (note.map { $0 + " " } ?? "") + "This start uses Wine's standard synchronization instead of madsync; the next start uses madsync again."
            }
        }
        // Those still not recorded and not run again now are named in the note, so an
        // installer that did its work but never closed can be recorded with Record as done.
        let stillUnfinished = items.filter { item in
            item.status != .done && unfinished.contains(item.process.run.name) && !pending.contains(item.process)
        }.map { DockInstallScripts.label($0.process.run) }
        if !stillUnfinished.isEmpty {
            let names = stillUnfinished.joined(separator: ", ")
            let words = "Last run did not finish: \(names) (its installer never closed). If it installed, choose Record as done under One-time installs."
            note = (note.map { $0 + " " } ?? "") + words
            LogStore.shared.log("[dock-installers] app=\(app) unfinished=\(stillUnfinished.joined(separator: ",")): the last batch started it and saw no exit status")
        }
        if script != nil && flag("MADEIRA_DOTNET_FUSION") {
            LogStore.shared.log("[dock-installers] app=\(app) dotnet-fusion=\(placeDotNetFusion(drive: drive, source: fusionSource))")
        }
        LogStore.shared.log("[dock-installers] app=\(app) scripts=\(scripts) programs=\(found.count) pending=\(pending.count) " +
                            "done=\(items.filter { $0.status == .done }.count) missing=\(items.filter { $0.status == .missing }.count) " +
                            "third-party=\(thirdPartyInstalls) " +
                            "unsupported=\(items.filter { $0.status == .unsupported }.count) default-key=\(defaultKey ? 1 : 0) " +
                            "services-step=\(script == nil ? "-" : services == .off ? "off" : "start") session-madsync-off=\(serverSync ? 1 : 0) " +
                            "installs-only=\(installsOnly ? 1 : 0)")
        if installsOnly {
            LogStore.shared.log("[dock-installers] app=\(app) this session runs only the one-time installs; the game starts after Madeira is restarted (MADEIRA_DOCK_INSTALL_SEPARATE=0: in the same session)")
        }
    }

    /// An installer with a managed step (DirectX setup's is one) loads fusion.dll from the
    /// .NET 2.0 framework folder through mscoree. Wine normally gets that file from its Mono
    /// package, which Madeira does not ship, and such a setup ended with -9 in the fork's
    /// device runs. Before a start that runs installers, Wine's own builtin 32-bit fusion.dll
    /// is placed there, only when missing. Returns "placed", "present", "no-source" or "failed".
    static func placeDotNetFusion(drive: URL, source: URL?) -> String {
        let fm = FileManager.default
        let folder = drive.appendingPathComponent("windows/Microsoft.NET/Framework/v2.0.50727", isDirectory: true)
        let target = folder.appendingPathComponent("fusion.dll")
        if fm.fileExists(atPath: target.path) { return "present" }
        guard let source, fm.fileExists(atPath: source.path) else { return "no-source" }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
            return "placed"
        } catch { return "failed" }
    }

    /// The previous batch's exit statuses, read at the next Dock start (no session runs, so
    /// the registry is on disk): programs that succeeded are recorded done, one summary line
    /// is logged, and the result file and session list are cleared.
    static func absorbResults(reason: String, drive: URL, prefix: URL) {
        var ledger = DockInstallLedger.load(prefix: prefix)
        guard !ledger.session.isEmpty else { return }
        let app = ledger.sessionApp
        let file = drive.appendingPathComponent(resultName)
        if let contents = try? Data(contentsOf: file), contents.count <= 16384 {
            let results = DockInstallScripts.results(String(decoding: contents, as: UTF8.self))
            var succeeded: [SteamInstallRun] = []
            var statuses: [String] = []
            var unfinished: [String] = []
            for (offset, run) in ledger.session.enumerated() {
                let index = offset + 1, text = DockInstallScripts.label(run)
                if let status = results.exits[index] {
                    if DockInstallScripts.Results.succeeded(status) { succeeded.append(run) }
                    statuses.append("\(text)=\(status)")
                } else {
                    if results.started[index] != nil { unfinished.append(run.name) }
                    statuses.append("\(text)=\(results.started[index] != nil ? "unfinished" : "not-started")")
                }
            }
            // Kept until the game's next batch or request: the Dock note names them, and
            // Record as done can record one whose installer did its work but never closed.
            ledger.setUnfinished(app, unfinished)
            var written = 0
            do { written = try SteamInstallScripts.mark(succeeded, prefix: prefix) }
            catch { LogStore.shared.log("[dock-installers] app=\(app) results not recorded: \(error.localizedDescription)", level: .error) }
            let failed = ledger.session.count - succeeded.count
            LogStore.shared.log("[dock-installers] app=\(app) results reason=\(reason) succeeded=\(succeeded.count) failed=\(failed) " +
                                "recorded-values=\(written) services=\(results.services ?? "-") ended=\(results.ended ? 1 : 0) " +
                                "statuses=\(statuses.joined(separator: ","))", level: failed > 0 ? .error : .info)
        } else {
            LogStore.shared.log("[dock-installers] app=\(app) results reason=\(reason) none: the batch did not start", level: .error)
        }
        try? FileManager.default.removeItem(at: file)
        ledger.session = []; ledger.sessionApp = 0
        try? ledger.save(prefix: prefix)
    }

    /// The batch's progress from its result file, for the Dock sheet and the starting
    /// screen. New start and exit lines, and the end, are logged once; the text names the
    /// program running now and any that failed, and at the end how many succeeded. A program
    /// that runs `stallSeconds` or longer (counted from when poll first saw it) gets its
    /// minutes in the text and one log line; nothing is stopped.
    static func poll(drive: URL, now: Date = Date()) -> String? {
        guard script != nil else { return nil }
        let file = drive.appendingPathComponent(resultName)
        guard let contents = try? Data(contentsOf: file), contents.count <= 16384 else { return "Starting this game's one-time installs…" }
        let results = DockInstallScripts.results(String(decoding: contents, as: UTF8.self))
        if let services = results.services, logged.insert("services").inserted {
            LogStore.shared.log("[dock-installers] services=\(services)", level: services == "failed" || services == "timeout" ? .error : .info)
        }
        for (index, program) in results.started.sorted(by: { $0.key < $1.key }) where logged.insert("s\(index)").inserted {
            LogStore.shared.log("[dock-installers] start \(index)/\(results.total) program=\(program)")
        }
        var failed: [String] = []
        for (index, status) in results.exits.sorted(by: { $0.key < $1.key }) {
            let ok = DockInstallScripts.Results.succeeded(status)
            if !ok { failed.append("\(results.started[index] ?? "#\(index)") (exit \(status))") }
            guard logged.insert("e\(index)").inserted else { continue }
            LogStore.shared.log("[dock-installers] exit \(index)/\(results.total) program=\(results.started[index] ?? "") status=\(status) " +
                                (ok ? "succeeded; recorded at the next start" : "failed; not recorded"), level: ok ? .info : .error)
        }
        let failures = failed.isEmpty ? "" : "\nFailed: " + failed.joined(separator: ", ")
        if let running = results.running {
            if runningSince?.index != running { runningSince = (running, now) }
            let seconds = max(0, Int(now.timeIntervalSince(runningSince?.at ?? now)))
            let program = results.started[running] ?? ""
            var text = "Running one-time install \(running) of \(max(results.total, running)): \(program)…"
            if seconds >= stallSeconds {
                let hint = "If its window no longer changes, it may have finished without closing. Ending the session leaves it unrecorded; Record as done under One-time installs records it."
                text += " (\(seconds / 60) min)\n" + hint
                if logged.insert("stall\(running)").inserted {
                    let line = "[dock-installers] still running \(running)/\(results.total) program=\(program) after \(seconds) s; the host waits for it (an installer window that never closes keeps the batch here)"
                    LogStore.shared.log(line, level: .error)
                }
            }
            return text + failures
        }
        guard results.ended else { return "Running this game's one-time installs…" + failures }
        let total = max(results.total, results.exits.count), succeeded = results.exits.count - failed.count
        if logged.insert("end").inserted {
            finishedAt = Date()
            LogStore.shared.log("[dock-installers] end succeeded=\(succeeded) failed=\(failed.count) of=\(total); " +
                                (installsOnly ? "the session ends, the game starts after a restart" : "the host starts next"))
        }
        allSucceeded = total > 0 && succeeded == total
        return "One-time installs finished: \(succeeded) of \(total) succeeded." + failures
    }

    /// madeira-bcd: the batch ended and every program in it succeeded (poll).
    private(set) static var allSucceeded = false

    /// madeira-bcd: the "Restart Madeira" alert after a session of one-time installs, in the
    /// owner's words (2026-10-12): all succeeded, or the count and the failed programs. `ended`
    /// is poll's text, nil when the batch never ended.
    static func restartNotice(_ ended: String?) -> String {
        if allSucceeded { return "One-time installs completed successfully. Close Madeira and open it again to play the game." }
        return (ended ?? "One-time installs ended.") + "\nClose Madeira and open it again to play the game."
    }
}
