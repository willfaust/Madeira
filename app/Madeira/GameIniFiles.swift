// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Game details › Settings files: a game's own .ini and .cfg files (and Unity's
//  boot.config) from its folder, AppData and Documents, added per game and edited in the app, section by section,
//  without the Files app. A file keeps its line endings, encoding, comments and
//  order: only the values that change are rewritten. A game that rewrote its
//  file since it was saved here (New Vegas rewrites sD3DDevice after a crash) is
//  noted when the file opens.
//
//  Everything above "MARK: Views" is Foundation only:
//  tests/host/check-ini-editor.py compiles it with a test harness.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// An .ini or .cfg file's text, its settings found by line. Setting a value
/// rewrites that value only; every other byte stays as it was. A .cfg file
/// (`cfgLines`) can also have Source and id Tech lines: `name value`,
/// `name "value"`, `seta name "value"`, with // comments. An XML settings file
/// (`xml`: GTA V's settings.xml, RDR2's system.xml) has one setting per line,
/// `<Name value="1" />` or `<name>kSettingLevel_High</name>`, its sections the
/// elements around them.
struct IniDocument: Equatable {
    struct Setting: Equatable, Identifiable {
        let line: Int
        let section: String
        let key: String
        var value: String
        var id: Int { line }
    }

    private(set) var lines: [String]
    private(set) var settings: [Setting]
    /// "\r\n" or "\n", as the file had it.
    let newline: String
    let endsWithNewline: Bool
    let cfgLines: Bool
    let xml: Bool

    init(text: String, cfgLines: Bool = false, xml: Bool = false) {
        self.cfgLines = cfgLines
        self.xml = xml
        // Swift reads "\r\n" as one Character, so the ends are checked by scalar.
        newline = text.range(of: "\r\n") != nil ? "\r\n" : "\n"
        let scalars = text.unicodeScalars
        endsWithNewline = scalars.last == "\n"
        var body = text
        if endsWithNewline {
            let crlf = scalars.count >= 2 && scalars[scalars.index(scalars.endIndex, offsetBy: -2)] == "\r"
            body = String(String.UnicodeScalarView(scalars.dropLast(newline == "\r\n" && crlf ? 2 : 1)))
        }
        lines = body.isEmpty && endsWithNewline ? [] : body.components(separatedBy: newline)
        settings = []
        if xml { readXML(); return }
        var section = ""
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if cfgLines, line.hasPrefix("//") || line.hasPrefix("--") { continue }
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                section = String(line[line.index(after: line.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let parts = Self.split(raw, cfgLines: cfgLines) else { continue }
            settings.append(Setting(line: i, section: section, key: parts.key, value: parts.value))
        }
    }

    /// One element per line: a setting is `<Name value="X" />` or `<Name>X</Name>`;
    /// an element opened alone on its line is a section until it closes. The root
    /// element is not part of a section's name ("graphics", "video › hdr").
    private mutating func readXML() {
        var open: [String] = []
        var comment = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if comment { if line.contains("-->") { comment = false }; continue }
            if line.hasPrefix("<!--") { comment = !line.contains("-->"); continue }
            guard line.hasPrefix("<"), !line.hasPrefix("<?"), !line.hasPrefix("<!") else { continue }
            if let parts = Self.splitXML(raw) {
                settings.append(Setting(line: i, section: open.dropFirst().joined(separator: " › "), key: parts.key, value: parts.value))
            } else if line.hasPrefix("</") {
                if !open.isEmpty { open.removeLast() }
            } else if !line.hasSuffix("/>"), !line.contains("</"), let name = Self.xmlName(line) {
                open.append(name)
            }
        }
    }

    /// "<graphics>" or "<Settings version=\"2\">" -> the element's name.
    private static func xmlName(_ line: String) -> String? {
        guard line.hasPrefix("<") else { return nil }
        let name = line.dropFirst().prefix { !" \t/>".contains($0) }
        return name.isEmpty ? nil : String(name)
    }

    /// `<ScreenWidth value="1920" />` or `<textureQuality>kSettingLevel_High</textureQuality>`.
    static func splitXML(_ raw: String) -> Parts? {
        guard let lt = raw.firstIndex(of: "<"), raw[lt...].dropFirst().first.map({ $0 != "/" && $0 != "?" && $0 != "!" }) == true,
              let name = xmlName(String(raw[lt...])) else { return nil }
        let rest = raw[lt...]
        if let close = rest.range(of: "/>"), let attr = rest.range(of: " value=\""), attr.upperBound <= close.lowerBound,
           let end = rest[attr.upperBound...].firstIndex(of: "\""), end < close.lowerBound {
            let range = attr.upperBound..<end
            return Parts(key: name, value: xmlUnescape(String(raw[range])), range: range, quoted: true, spaced: false, command: "")
        }
        guard let gt = rest.firstIndex(of: ">"), raw[raw.index(before: gt)] != "/",
              let closing = rest.range(of: "</" + name + ">"), gt < closing.lowerBound else { return nil }
        let range = raw.index(after: gt)..<closing.lowerBound
        guard !raw[range].contains("<") else { return nil }
        return Parts(key: name, value: xmlUnescape(String(raw[range])), range: range, quoted: false, spaced: false, command: "")
    }

    static func xmlUnescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Where a line's value is. `range` leaves out quotes around the whole value.
    struct Parts {
        let key: String
        let value: String
        let range: Range<String.Index>
        let quoted: Bool
        /// A `name value` line (no =), and the command before the name ("seta ").
        let spaced: Bool
        let command: String
    }

    /// .cfg commands that are not settings (several words, or actions).
    static let cfgCommands: Set<String> = ["bind", "unbind", "unbindall", "bindtoggle", "alias", "exec", "echo", "say", "say_team",
                                           "connect", "toggle", "incrementvar", "host_writeconfig", "wait", "clear", "vstr"]

    /// "  iSize W = 1280 " -> key "iSize W", value "1280". With `cfgLines` also
    /// `fps_max 300`, `sensitivity "2.5" // comment` and `seta r_mode "4"`.
    static func split(_ raw: String, cfgLines: Bool = false) -> Parts? {
        let blank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        if let eq = raw.firstIndex(of: "="), raw.firstIndex(of: "\"").map({ eq < $0 }) ?? true {
            let key = raw[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            var start = raw.index(after: eq)
            while start < raw.endIndex, blank(raw[start]) { start = raw.index(after: start) }
            var end = cfgLines ? commentStart(raw, from: start) : raw.endIndex
            while end > start, blank(raw[raw.index(before: end)]) { end = raw.index(before: end) }
            return parts(raw, key: key, start: start, end: end, spaced: false, command: "")
        }
        guard cfgLines else { return nil }
        var i = raw.startIndex
        guard var key = token(raw, &i) else { return nil }
        var command = ""
        if ["seta", "set", "sets", "setu", "setr"].contains(key.lowercased()) {
            command = key + " "
            guard let name = token(raw, &i) else { return nil }
            key = name
        }
        guard !key.isEmpty, !cfgCommands.contains(key.lowercased()), !key.hasPrefix("+"), !key.hasPrefix("-") else { return nil }
        var start = i
        while start < raw.endIndex, blank(raw[start]) { start = raw.index(after: start) }
        var end = commentStart(raw, from: start)
        while end > start, blank(raw[raw.index(before: end)]) { end = raw.index(before: end) }
        guard start < end else { return nil }
        return parts(raw, key: key, start: start, end: end, spaced: true, command: command)
    }

    private static func parts(_ raw: String, key: String, start: String.Index, end: String.Index, spaced: Bool, command: String) -> Parts {
        let text = raw[start..<end]
        if text.count >= 2, text.first == "\"", text.last == "\"" {
            let range = raw.index(after: start)..<raw.index(before: end)
            return Parts(key: key, value: String(raw[range]), range: range, quoted: true, spaced: spaced, command: command)
        }
        return Parts(key: key, value: String(text), range: start..<end, quoted: false, spaced: spaced, command: command)
    }

    /// One word, or a "quoted" one, from `i`; `i` moves past it.
    private static func token(_ raw: String, _ i: inout String.Index) -> String? {
        while i < raw.endIndex, raw[i] == " " || raw[i] == "\t" { i = raw.index(after: i) }
        guard i < raw.endIndex else { return nil }
        if raw[i] == "\"" {
            let start = raw.index(after: i)
            guard let close = raw[start...].firstIndex(of: "\"") else { return nil }
            i = raw.index(after: close)
            return String(raw[start..<close])
        }
        let start = i
        while i < raw.endIndex, raw[i] != " ", raw[i] != "\t" { i = raw.index(after: i) }
        return String(raw[start..<i])
    }

    /// Where a // comment starts after `from` (outside quotes), or the line's end.
    private static func commentStart(_ raw: String, from: String.Index) -> String.Index {
        var inQuotes = false
        var i = from
        while i < raw.endIndex {
            let c = raw[i]
            if c == "\"" { inQuotes.toggle() }
            let next = raw.index(after: i)
            if !inQuotes, c == "/", next < raw.endIndex, raw[next] == "/" { return i }
            i = next
        }
        return raw.endIndex
    }

    /// The sections in file order, each with its settings.
    var sections: [(name: String, settings: [Setting])] {
        var order: [String] = []
        var grouped: [String: [Setting]] = [:]
        for s in settings {
            if grouped[s.section] == nil { order.append(s.section) }
            grouped[s.section, default: []].append(s)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    /// Sets the setting on `line` to `value`; the rest of the line is kept (an
    /// emptied value drops the spaces after it). A `name value` line gets quotes
    /// when the new value has a space.
    mutating func set(line: Int, to value: String) {
        guard let i = settings.firstIndex(where: { $0.line == line }),
              let parts = xml ? Self.splitXML(lines[line]) : Self.split(lines[line], cfgLines: cfgLines) else { return }
        var raw = lines[line]
        let written = xml ? Self.xmlEscape(value) : parts.spaced && !parts.quoted && value.contains(" ") ? "\"" + value + "\"" : value
        raw.replaceSubrange(parts.range, with: written)
        if value.isEmpty && !parts.quoted && !xml {
            while let last = raw.last, last == " " || last == "\t" { raw.removeLast() }
        }
        lines[line] = raw
        settings[i].value = value
    }

    /// The value of `key` in `section` (case-insensitive), the first one in the file.
    func value(section: String, key: String) -> String? {
        settings.first { $0.section.caseInsensitiveCompare(section) == .orderedSame && $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// Adds `key` with `value` at the end of `section`'s settings, or under its
    /// header when it has none; a section the file lacks is made at the end. ""
    /// is the top of the file, before any [section]. Written the way the file's
    /// first setting is ("a=1" or "a = 1"). A key the section already has gets
    /// the new value instead. Returns the setting's line; -1 for an XML file,
    /// where settings are not added.
    @discardableResult
    mutating func add(section: String, key: String, value: String) -> Int {
        guard !xml else { return -1 }
        let section = section.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
        let wasEmpty = lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        if wasEmpty { lines = [] }
        let key = key.trimmingCharacters(in: .whitespaces)
        if let same = settings.first(where: { $0.section.caseInsensitiveCompare(section) == .orderedSame &&
                                              $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
            set(line: same.line, to: value)
            return same.line
        }
        var entry = key + "=" + value
        if let first = settings.first, let style = Self.split(lines[first.line], cfgLines: cfgLines) {
            if style.spaced {
                entry = style.command + key + " " + (style.quoted || value.contains(" ") ? "\"" + value + "\"" : value)
            } else if lines[first.line].contains(" = ") {
                entry = key + " = " + value
            }
        }
        var at: Int
        if let last = settings.last(where: { $0.section.caseInsensitiveCompare(section) == .orderedSame }) {
            at = last.line + 1
        } else if section.isEmpty {
            at = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            while at > 0, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
        } else if let header = lines.firstIndex(where: { Self.header($0)?.caseInsensitiveCompare(section) == .orderedSame }) {
            at = header + 1
        } else {
            if let end = lines.last, !end.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append("[\(section)]")
            at = lines.count
        }
        lines.insert(entry, at: at)
        let made = IniDocument(text: lines.joined(separator: newline) + (endsWithNewline || wasEmpty ? newline : ""), cfgLines: cfgLines)
        self = made
        return at
    }

    /// "[Display]" -> "Display"; nil for any other line.
    static func header(_ raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        return String(line[line.index(after: line.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
    }

    var text: String { lines.joined(separator: newline) + (endsWithNewline ? newline : "") }
}

/// A file's bytes as text, and back in the same encoding (UTF-8, with or
/// without a byte order mark, else Windows Latin 1, which every byte decodes as).
struct IniFileText: Equatable {
    var text: String
    let bom: Bool
    let utf8: Bool

    init?(data: Data) {
        let marker = Data([0xEF, 0xBB, 0xBF])
        bom = data.starts(with: marker)
        let body = bom ? data.dropFirst(3) : data[...]
        if let s = String(data: Data(body), encoding: .utf8) { text = s; utf8 = true }
        else if let s = String(data: Data(body), encoding: .windowsCP1252) ?? String(data: Data(body), encoding: .isoLatin1) { text = s; utf8 = false }
        else { return nil }
    }

    func data(_ text: String) -> Data? {
        guard let body = text.data(using: utf8 ? .utf8 : .windowsCP1252) ?? text.data(using: .isoLatin1) else { return nil }
        return (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + body
    }
}

/// The .ini files each game has added, by the game's Windows path, as paths
/// under drive_c ("users/steamuser/Documents/My Games/FalloutNV/Fallout.ini").
enum GameIniFiles {
    static let listKey = "madeira.library.iniFiles"
    static let savedKey = "madeira.library.iniSaved"

    static func files(_ windowsPath: String, defaults: UserDefaults = .standard) -> [String] {
        (defaults.dictionary(forKey: listKey) as? [String: [String]])?[windowsPath.lowercased()] ?? []
    }

    static func setFiles(_ files: [String], for windowsPath: String, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: listKey) as? [String: [String]]) ?? [:]
        all[windowsPath.lowercased()] = files.isEmpty ? nil : files
        defaults.set(all, forKey: listKey)
    }

    static func add(_ file: String, for windowsPath: String, defaults: UserDefaults = .standard) {
        var list = files(windowsPath, defaults: defaults)
        guard !list.contains(where: { $0.caseInsensitiveCompare(file) == .orderedSame }) else { return }
        list.append(file)
        setFiles(list, for: windowsPath, defaults: defaults)
    }

    static func remove(_ file: String, for windowsPath: String, defaults: UserDefaults = .standard) {
        setFiles(files(windowsPath, defaults: defaults).filter { $0 != file }, for: windowsPath, defaults: defaults)
    }

    /// A short name for a file: from "My Games" on, or from the game's folder on.
    static func label(_ file: String, gameFolder: String?) -> String {
        let parts = file.split(separator: "/").map(String.init)
        for anchor in ["My Games", "AppData", "Documents"] {
            if let i = parts.firstIndex(where: { $0.caseInsensitiveCompare(anchor) == .orderedSame }) {
                return parts[i...].joined(separator: "\\")
            }
        }
        if let folder = gameFolder?.trimmingCharacters(in: CharacterSet(charactersIn: "/")), !folder.isEmpty,
           file.lowercased().hasPrefix(folder.lowercased() + "/") {
            let name = folder.split(separator: "/").last.map(String.init) ?? folder
            return name + "\\" + file.dropFirst(folder.count + 1).replacingOccurrences(of: "/", with: "\\")
        }
        return file.replacingOccurrences(of: "/", with: "\\")
    }

    /// The game's folder under drive_c: a Steam game's install folder, else the
    /// program's folder. `relativePath` is LibraryEntry.relativePath.
    static func gameFolder(relativePath: String, isDirectory: Bool) -> String {
        if isDirectory { return relativePath }
        return relativePath.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// A file the editor opens: .ini, .cfg (Source, id Tech, CryEngine, Godot's
    /// override.cfg), Unity's boot.config, and an .xml named like a settings file
    /// (GTA V's settings.xml, RDR2's system.xml). `anyXML`: every .xml, for a file
    /// the list of where games keep their settings points to.
    static func isSettingsFile(_ name: String, anyXML: Bool = false) -> Bool {
        let lower = (name as NSString).lastPathComponent.lowercased()
        if lower.hasSuffix(".xml") {
            return anyXML || lower == "system.xml" || ["setting", "config", "option", "prefs"].contains { lower.contains($0) }
        }
        return lower.hasSuffix(".ini") || lower.hasSuffix(".cfg") || lower == "boot.config"
    }

    /// .cfg files may have `name value` lines.
    static func isCfg(_ name: String) -> Bool { name.lowercased().hasSuffix(".cfg") }

    static func isXML(_ name: String) -> Bool { name.lowercased().hasSuffix(".xml") }

    /// The settings files a game is likely to use, under drive_c: its own folder (five
    /// levels down) and every user's Documents/My Games. At most `limit`.
    static func candidates(drive: URL, gameFolder: String, limit: Int = 400) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func scan(_ folder: URL, depth: Int) {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
            for case let url as URL in walker {
                if found.count >= limit { return }
                if walker.level > depth { walker.skipDescendants(); continue }
                guard isSettingsFile(url.lastPathComponent) else { continue }
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(drive.path + "/") else { continue }
                let relative = String(path.dropFirst(drive.path.count + 1))
                if seen.insert(relative.lowercased()).inserted { found.append(relative) }
            }
        }
        let users = drive.appendingPathComponent("users", isDirectory: true)
        for user in ((try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []).sorted() {
            for place in ["Documents/My Games", "Documents/Rockstar Games"] {
                let games = users.appendingPathComponent(user).appendingPathComponent(place, isDirectory: true)
                if FileManager.default.fileExists(atPath: games.path) { scan(games, depth: 3) }
            }
        }
        if !gameFolder.isEmpty { scan(drive.appendingPathComponent(gameFolder, isDirectory: true), depth: 5) }
        return found
    }

    /// A short fingerprint of a file's bytes (FNV-1a), to notice a game rewriting it.
    static func fingerprint(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    static func savedFingerprint(_ file: String, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: savedKey) as? [String: String])?[file.lowercased()]
    }

    static func setSavedFingerprint(_ value: String, for file: String, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: savedKey) as? [String: String]) ?? [:]
        all[file.lowercased()] = value
        defaults.set(all, forKey: savedKey)
    }

    /// Is this a 0/1 switch? Bethesda's names say so: bUseWaterShader.
    static func isSwitch(key: String, value: String) -> Bool {
        guard value == "0" || value == "1", key.count > 1, key.first == "b" else { return false }
        return key.dropFirst().first?.isUppercase == true
    }
}

/// Where games keep their settings files, from the Ludusavi list
/// (game-config-folders.txt, made by build/tools/gen-game-config-folders.py; its
/// paths come from PCGamingWiki), found by the game's folder name. An Unreal game
/// the list lacks is found by its project folder (<Project>/Binaries next to the
/// exe, settings in AppData/Local/<Project>/Saved/Config).
enum GameConfigFolders {
    /// Lower-case game folder name or title -> the list's paths, placeholders and all.
    static func table(_ text: String) -> [String: [String]] {
        var all: [String: [String]] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count > 1 else { continue }
            for name in fields[0].split(separator: "|") { all[String(name), default: []] += fields.dropFirst() }
        }
        return all
    }

    /// The list in the app, read the first time it is needed.
    static let bundled: [String: [String]] = {
        guard let url = Bundle.main.url(forResource: "game-config-folders", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return table(text)
    }()

    /// Folder names that say nothing about which game it is.
    private static let plainFolders: Set<String> = ["win64", "win32", "x64", "x86", "bin", "bin64", "bin32", "binaries",
                                                     "system", "game", "games", "program", "data", "release", "retail"]

    /// The list's paths for the game in `gameFolder` (the install folder, or the exe's
    /// folder), and the folder name they matched. Up to three folders up are tried.
    static func patterns(gameFolder: String, table: [String: [String]]) -> (name: String, paths: [String])? {
        let parts = gameFolder.split(separator: "/").map(String.init)
        for name in parts.reversed().prefix(3) where !plainFolders.contains(name.lowercased()) {
            if let paths = table[name.lowercased()] { return (name, paths) }
        }
        return nil
    }

    /// A list path as a path under drive_c, with * where any name fits
    /// (users/*/AppData/Local/Subnautica2/Saved/Config/Windows).
    static func expand(_ path: String, gameFolder: String, name: String) -> String {
        let folder = gameFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let root = folder.split(separator: "/").dropLast().joined(separator: "/")
        let places: [(String, String)] = [
            ("<base>", folder), ("<root>", root), ("<game>", name),
            ("<winLocalAppDataLow>", "users/*/AppData/LocalLow"), ("<winLocalAppData>", "users/*/AppData/Local"),
            ("<winAppData>", "users/*/AppData/Roaming"), ("<winDocuments>", "users/*/Documents"),
            ("<winPublic>", "users/Public"), ("<winProgramData>", "ProgramData"), ("<winDir>", "windows"),
            ("<home>", "users/*"), ("<storeUserId>", "*"), ("<storeGameId>", "*"), ("<osUserName>", "*"),
        ]
        var out = path
        for (mark, place) in places { out = out.replacingOccurrences(of: mark, with: place) }
        return out.split(separator: "/").filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// The paths to look in for the game: the list's, then its Unreal project's.
    static func places(drive: URL, gameFolder: String, table: [String: [String]]) -> [String] {
        var out: [String] = []
        let folder = gameFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let hit = patterns(gameFolder: folder, table: table) {
            out += hit.paths.map { expand($0, gameFolder: folder, name: hit.name) }
        }
        for project in unrealProjects(drive: drive, gameFolder: folder) {
            out.append("users/*/AppData/Local/\(project)/Saved/Config")
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Unreal project names: a folder in the game's folder with Binaries in it, or
    /// the folder above Binaries when the game's folder is the exe's.
    static func unrealProjects(drive: URL, gameFolder: String) -> [String] {
        let fm = FileManager.default
        let parts = gameFolder.split(separator: "/").map(String.init)
        var names: [String] = []
        if let i = parts.lastIndex(where: { $0.caseInsensitiveCompare("Binaries") == .orderedSame }), i > 0 { names.append(parts[i - 1]) }
        let base = drive.appendingPathComponent(gameFolder, isDirectory: true)
        for child in ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).sorted() where child.lowercased() != "engine" {
            let inside = (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent(child).path)) ?? []
            if inside.contains(where: { $0.caseInsensitiveCompare("Binaries") == .orderedSame }) { names.append(child) }
        }
        return names.filter { $0.lowercased() != "engine" }
    }

    /// Paths under `drive` that fit `pattern` (* and ? within a name, any case).
    static func matches(_ pattern: String, drive: URL, limit: Int = 200) -> [String] {
        var current = [""]
        for part in pattern.split(separator: "/").map(String.init) {
            var next: [String] = []
            for path in current {
                let dir = path.isEmpty ? drive : drive.appendingPathComponent(path, isDirectory: true)
                for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where fits(part, name) {
                    next.append(path.isEmpty ? name : path + "/" + name)
                    if next.count >= limit { break }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    static func fits(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern.lowercased()), n = Array(name.lowercased())
        var pi = 0, ni = 0, star = -1, mark = 0
        while ni < n.count {
            if pi < p.count, p[pi] == "?" || p[pi] == n[ni] { pi += 1; ni += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = ni; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ni = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// The game's settings files (.ini, .cfg, boot.config) the list or its Unreal project points to.
    static func files(drive: URL, gameFolder: String, table: [String: [String]] = bundled, limit: Int = 200) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            if found.count < limit, seen.insert(path.lowercased()).inserted { found.append(path) }
        }
        let fm = FileManager.default
        for place in places(drive: drive, gameFolder: gameFolder, table: table) {
            for path in matches(place, drive: drive) {
                var isDirectory: ObjCBool = false
                let full = drive.appendingPathComponent(path).path
                guard fm.fileExists(atPath: full, isDirectory: &isDirectory) else { continue }
                if !isDirectory.boolValue {
                    if GameIniFiles.isSettingsFile(path, anyXML: true) { add(path) }
                    continue
                }
                guard let walker = fm.enumerator(atPath: full) else { continue }
                var inis: [String] = []
                while let inside = walker.nextObject() as? String {
                    if inside.split(separator: "/").count > 3 { walker.skipDescendants(); continue }
                    if GameIniFiles.isSettingsFile(inside, anyXML: inside.split(separator: "/").count == 1) { inis.append(inside) }
                }
                for inside in inis.sorted(by: { $0.lowercased() < $1.lowercased() }) { add(path + "/" + inside) }
            }
        }
        return found
    }

    /// Folders an imported file can go in: the list's (the ones that exist, else
    /// each Wine user's, made when a file is put there), then the game's folder.
    static func folders(drive: URL, gameFolder: String, table: [String: [String]] = bundled) -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        let users = ((try? fm.contentsOfDirectory(atPath: drive.appendingPathComponent("users").path)) ?? [])
            .filter { $0.caseInsensitiveCompare("Public") != .orderedSame && !$0.hasPrefix(".") }.sorted()
        for place in places(drive: drive, gameFolder: gameFolder, table: table) {
            var parts = place.split(separator: "/").map(String.init)
            // A file, or names with a * in the last part: its folder.
            if let last = parts.last, last.contains("*") || !(last as NSString).pathExtension.isEmpty { parts.removeLast() }
            let folder = parts.joined(separator: "/")
            guard !folder.isEmpty else { continue }
            let existing = matches(folder, drive: drive).filter {
                var isDirectory: ObjCBool = false
                return fm.fileExists(atPath: drive.appendingPathComponent($0).path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            if !existing.isEmpty { out += existing; continue }
            // Not made yet (the game has not run): only where the one * is the user.
            if folder.hasPrefix("users/*/"), !folder.dropFirst(8).contains("*") {
                let rest = String(folder.dropFirst(8))
                out += users.map { "users/\($0)/" + rest }
            }
        }
        let game = gameFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !game.isEmpty { out.append(game) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Copies `source` into `folder` (under drive_c, made if missing). A file with
    /// the same name there (any case) is renamed NAME.before-import first, and the
    /// copy takes its spelling. Returns the copy's path and the backup's, under drive_c.
    static func importFile(_ source: URL, into folder: String, drive: URL) throws -> (file: String, backup: String?) {
        let fm = FileManager.default
        let data = try Data(contentsOf: source)
        let dir = drive.appendingPathComponent(folder, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = source.lastPathComponent
        var backup: String?
        if let existing = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            var kept = existing + ".before-import", n = 2
            while fm.fileExists(atPath: dir.appendingPathComponent(kept).path) { kept = existing + ".before-import-\(n)"; n += 1 }
            try fm.moveItem(at: dir.appendingPathComponent(existing), to: dir.appendingPathComponent(kept))
            backup = folder + "/" + kept
            name = existing
        }
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return (folder + "/" + name, backup)
    }
}

// MARK: Views

/// Game details › Settings files: the game's added settings files, "Add settings
/// file" and "Import settings file".
struct GameIniFilesSection: View {
    let windowsPath: String
    let gameFolder: String
    @State private var files: [String] = []
    @State private var unity = false

    var body: some View {
        if unity {
            Section {
                NavigationLink {
                    UnityOptionsPage(gameFolder: gameFolder)
                } label: {
                    Label("Unity game options", systemImage: "slider.horizontal.3")
                }
            } footer: {
                Text("Resolution, window mode, quality and the game's own options, which Unity games keep in the registry instead of a file.")
            }
        }
        Section {
            ForEach(files, id: \.self) { file in
                NavigationLink {
                    IniFileEditor(file: file, title: (file as NSString).lastPathComponent)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((file as NSString).lastPathComponent)
                        Text(GameIniFiles.label(file, gameFolder: gameFolder)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets { GameIniFiles.remove(files[i], for: windowsPath) }
                files = GameIniFiles.files(windowsPath)
            }
            // Pushed, not a sheet: a sheet hung on a row of this Form closed by itself
            // when the page redrew (Cameron, iPhone, 2026-10-26).
            NavigationLink {
                IniFilePicker(gameFolder: gameFolder, added: Set(files.map { $0.lowercased() })) { file in
                    GameIniFiles.add(file, for: windowsPath)
                    files = GameIniFiles.files(windowsPath)
                }
            } label: {
                Label("Add settings file", systemImage: "plus")
            }
            NavigationLink {
                IniFileImport(gameFolder: gameFolder) { file in
                    GameIniFiles.add(file, for: windowsPath)
                    files = GameIniFiles.files(windowsPath)
                }
            } label: {
                Label("Import settings file", systemImage: "square.and.arrow.down")
            }
        } footer: {
            Text("A game's own settings files, like Fallout.ini, Engine.ini, autoexec.cfg or settings.xml. Changes are saved into the file; close the game first. Swipe left to take a file off this list (the file stays).")
        }
        .onAppear { files = GameIniFiles.files(windowsPath) }
        // (ini-editor-async) A folder check on the drive: not on the main thread.
        .task {
            guard !gameFolder.isEmpty else { return }
            let folder = LibraryModel.drive.appendingPathComponent(gameFolder, isDirectory: true)
            let started = Date()
            unity = await Task.detached(priority: .userInitiated) { UnityPlayerPrefs.isUnity(gameFolder: folder) }.value
            LogStore.shared.log("[ini] Unity check \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(unity)")
        }
    }
}

/// The game's own settings files (from the list of where games keep them), then
/// the other settings files under its folder and Documents/My Games, to add one.
struct IniFilePicker: View {
    let gameFolder: String
    let added: Set<String>
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mine: [String] = []
    @State private var found: [String]?
    @State private var query = ""

    var body: some View {
        List {
            if let found {
                let shownMine = query.isEmpty ? mine : mine.filter { $0.localizedCaseInsensitiveContains(query) }
                let shown = query.isEmpty ? found : found.filter { $0.localizedCaseInsensitiveContains(query) }
                if shown.isEmpty && shownMine.isEmpty {
                    Text(found.isEmpty && mine.isEmpty ? "No settings files (.ini or .cfg) in the game's folders yet. A game often writes its files the first time it runs." : "No file matches.")
                        .foregroundStyle(.secondary)
                }
                if !shownMine.isEmpty {
                    Section {
                        ForEach(shownMine, id: \.self) { file in row(file) }
                    } header: {
                        Text("This game's settings files")
                    } footer: {
                        Text("Settings folders for many games come from PCGamingWiki, through the Ludusavi list.")
                    }
                }
                if !shown.isEmpty {
                    Section {
                        ForEach(shown, id: \.self) { file in row(file) }
                    } header: {
                        if !shownMine.isEmpty { Text("Other settings files") }
                    }
                }
            } else {
                HStack { ProgressView(); Text("Looking for settings files").foregroundStyle(.secondary) }
            }
        }
        .searchable(text: $query, prompt: "File name")
        .navigationTitle("Add settings file").navigationBarTitleDisplayMode(.inline)
        .task {
            guard found == nil else { return }
            let folder = gameFolder, drive = LibraryModel.drive
            let started = Date()
            let lists = await Task.detached(priority: .userInitiated) {
                (GameConfigFolders.files(drive: drive, gameFolder: folder), GameIniFiles.candidates(drive: drive, gameFolder: folder))
            }.value
            LogStore.shared.log("[ini] Add settings file: \(lists.0.count) known, \(lists.1.count) found in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            let own = Set(lists.0.map { $0.lowercased() })
            mine = lists.0
            found = lists.1.filter { !own.contains($0.lowercased()) }
        }
    }

    private func row(_ file: String) -> some View {
        Button {
            pick(file); dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text((file as NSString).lastPathComponent).foregroundStyle(.primary)
                    Text(GameIniFiles.label(file, gameFolder: gameFolder)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer()
                if added.contains(file.lowercased()) { Image(systemName: "checkmark").foregroundStyle(.secondary) }
            }
        }
        .disabled(added.contains(file.lowercased()))
    }
}

/// Import settings file: a file from the Files app, copied into one of the game's
/// settings folders (or its own folder). A file of the same name there is kept
/// as NAME.before-import. Pushed, so the file chooser hangs on this page.
struct IniFileImport: View {
    let gameFolder: String
    let imported: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var source: URL?
    @State private var folders: [String]?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Button { choosing = true } label: {
                    if let source { Label(source.lastPathComponent, systemImage: "doc") } else { Label("Choose a file", systemImage: "doc") }
                }
            } footer: {
                Text("Pick a file from Files, then where it goes. A file with the same name there is kept as a backup (.before-import).")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if source != nil {
                Section("Put it in") {
                    if let folders {
                        ForEach(folders, id: \.self) { folder in
                            Button { put(folder) } label: {
                                Text(GameIniFiles.label(folder, gameFolder: gameFolder)).font(.callout).foregroundStyle(.primary)
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .navigationTitle("Import settings file").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { source = url; error = nil }
        }
        .task {
            let folder = gameFolder, drive = LibraryModel.drive
            folders = await Task.detached(priority: .userInitiated) { GameConfigFolders.folders(drive: drive, gameFolder: folder) }.value
        }
    }

    private func put(_ folder: String) {
        guard let source else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let done = try GameConfigFolders.importFile(source, into: folder, drive: LibraryModel.drive)
            LogStore.shared.log("[ini-editor] imported \(done.file)" + (done.backup.map { ", kept the old one as \($0)" } ?? ""))
            imported(done.file)
            dismiss()
        } catch {
            self.error = "Not imported: \(error.localizedDescription)"
        }
    }
}

/// Add setting: a name (known ones are offered as you type, with what they do),
/// a value and the [section] it goes in.
struct IniSettingAdd: View {
    let sections: [String]
    let add: (_ section: String, _ key: String, _ value: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var value = ""
    @State private var section: String

    init(sections: [String], fileName: String, add: @escaping (_ section: String, _ key: String, _ value: String) -> Void) {
        self.sections = sections
        self.add = add
        // An Unreal Engine.ini's tweaks go in [SystemSettings].
        let unreal = fileName.caseInsensitiveCompare("Engine.ini") == .orderedSame
        _section = State(initialValue: unreal ? "SystemSettings" : (sections.first(where: { !$0.isEmpty }) ?? ""))
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $key).font(.callout.monospaced())
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Value", text: $value).font(.callout.monospaced())
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                HStack {
                    TextField("Section", text: $section).font(.callout.monospaced())
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    if !sections.filter({ !$0.isEmpty }).isEmpty {
                        Menu {
                            ForEach(sections.filter { !$0.isEmpty }, id: \.self) { name in
                                Button(name) { section = name }
                            }
                        } label: { Image(systemName: "chevron.up.chevron.down") }
                    }
                }
            } footer: {
                Text("Leave Section empty to add it at the top of the file, before any [section]. A section the file does not have yet is made at the end.")
            }
            let found = IniSettingHelp.suggestions(key)
            if !found.isEmpty && !found.contains(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
                Section("Known settings") {
                    ForEach(found, id: \.key) { entry in
                        Button {
                            key = entry.name
                            if entry.key.hasPrefix("["), let close = entry.key.firstIndex(of: "]") {
                                section = String(entry.key[entry.key.index(after: entry.key.startIndex)..<close])
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).foregroundStyle(.primary)
                                Text(IniSettingHelp.breakable(entry.name)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(entry.text).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if !key.isEmpty {
                Section { Text(IniSettingHelp.info(key: key, section: section).text).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Add setting").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    add(section, key, value)
                    dismiss()
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || key.contains("=") || key.contains("["))
            }
        }
    }
}

/// One settings file, section by section: each setting's value can be changed and
/// settings added; Save writes only the changed and added lines.
struct IniFileEditor: View {
    let file: String
    let title: String
    @State private var original: Data?
    @State private var encoding: IniFileText?
    @State private var document: IniDocument?
    @State private var changed = false
    @State private var query = ""
    @State private var note: String?
    @State private var error: String?
    @State private var info: IniDocument.Setting?
    /// The setting whose value is being typed. A tap anywhere on a row puts the
    /// cursor in its value: the field alone is one line of text high, so most taps
    /// on a row missed it (Cameron, iPad, Wave 16).
    @FocusState private var focused: Int?

    private var url: URL { LibraryModel.drive.appendingPathComponent(file) }

    var body: some View {
        Form {
            if let note { Section { Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if let document {
                if document.settings.isEmpty { Section { Text("This file has no settings (key = value lines).").foregroundStyle(.secondary) } }
                if document.xml, document.settings.contains(where: { $0.value.hasPrefix("kSettingLevel_") }) {
                    Section { Text("A value like kSettingLevel_High is a level: kSettingLevel_Low, kSettingLevel_Medium, kSettingLevel_High or kSettingLevel_Ultra. Type it exactly, or the game may reset the file.").font(.caption).foregroundStyle(.secondary) }
                }
                // (ini-editor-async) A file with thousands of entries (Mono's browscap.ini) made the page
                // freeze: draw at most maxRows at a time; searching reaches the rest.
                let shown = visible(document)
                ForEach(shown.groups, id: \.name) { group in
                    Section(group.name.isEmpty ? "Settings" : document.xml ? group.name : "[\(group.name)]") {
                        ForEach(group.rows) { setting in row(setting) }
                    }
                }
                if shown.hidden > 0 {
                    Section {
                        Label("\(shown.hidden) more settings are not shown. Use the search box to find one.", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                    }
                }
                if !document.xml { Section {
                    NavigationLink {
                        IniSettingAdd(sections: document.sections.map { $0.name }, fileName: title) { section, key, value in
                            self.document?.add(section: section, key: key, value: value)
                            changed = true
                        }
                    } label: {
                        Label("Add setting", systemImage: "plus")
                    }
                } }
            } else if error == nil {
                ProgressView()
            }
        }
        .searchable(text: $query, prompt: "Setting or section")
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!changed) }
        }
        // The game page is a sheet: a drag down while typing or scrolling closed it,
        // edits and all (Cameron, Wave 16: "you can slide out of it really easy").
        .interactiveDismissDisabled(changed || focused != nil)
        .task { if document == nil { await load() } }
        .alert(info.map { IniSettingHelp.info(key: $0.key, section: $0.section).title ?? $0.key } ?? "",
               isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } }), presenting: info) { _ in
            Button("OK") {}
        } message: { setting in
            let help = IniSettingHelp.info(key: setting.key, section: setting.section, value: setting.value)
            let place = setting.key + (setting.section.isEmpty ? "" : GameIniFiles.isXML(file) ? " in \(setting.section)" : " in [\(setting.section)]")
            Text(help.text + "\n\n" + place)
        }
    }

    /// The search finds a setting by its key, its plain name or its section.
    /// The sections and rows to draw: all that match the search, but at most maxRows rows in all.
    static let maxRows = 300
    private func visible(_ document: IniDocument) -> (groups: [(name: String, rows: [IniDocument.Setting])], hidden: Int) {
        var left = Self.maxRows, hidden = 0
        var out: [(name: String, rows: [IniDocument.Setting])] = []
        for group in document.sections {
            let rows = query.isEmpty ? group.settings : group.settings.filter { matches($0, group.name) }
            if rows.isEmpty { continue }
            let take = min(left, rows.count)
            hidden += rows.count - take
            left -= take
            if take > 0 { out.append((group.name, Array(rows.prefix(take)))) }
        }
        return (out, hidden)
    }

    private func matches(_ setting: IniDocument.Setting, _ section: String) -> Bool {
        setting.key.localizedCaseInsensitiveContains(query) || section.localizedCaseInsensitiveContains(query) ||
            (IniSettingHelp.known[IniSettingHelp.plainKey(setting.key).lowercased()]?.title.localizedCaseInsensitiveContains(query) ?? false)
    }

    @ViewBuilder private func row(_ setting: IniDocument.Setting) -> some View {
        if GameIniFiles.isSwitch(key: setting.key, value: setting.value) {
            Toggle(isOn: Binding(get: { setting.value == "1" }, set: { update(setting.line, $0 ? "1" : "0") })) {
                label(setting)
            }
        } else {
            LabeledContent {
                TextField("", text: Binding(get: { setting.value }, set: { update(setting.line, $0) }))
                    .multilineTextAlignment(.trailing).font(.callout.monospaced())
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .focused($focused, equals: setting.line)
                    .frame(minWidth: 56, maxWidth: 150)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { focused = setting.line })
            } label: {
                label(setting)
                    .contentShape(Rectangle())
                    .onTapGesture { focused = setting.line }
            }
        }
    }

    /// The setting's plain name when the list knows it, and its full key (which
    /// wraps instead of ending in "…"), with a blue ⓘ that says what it does.
    private func label(_ setting: IniDocument.Setting) -> some View {
        let title = IniSettingHelp.known["[\(setting.section.lowercased())]" + IniSettingHelp.plainKey(setting.key).lowercased()]?.title
            ?? IniSettingHelp.known[IniSettingHelp.plainKey(setting.key).lowercased()]?.title
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title).font(.callout)
                    Text(IniSettingHelp.breakable(setting.key)).font(.caption.monospaced()).foregroundStyle(.secondary)
                } else {
                    Text(IniSettingHelp.breakable(setting.key)).font(.callout.monospaced())
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Button { info = setting } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).foregroundStyle(.blue)
                .accessibilityLabel("About \(setting.key)")
        }
    }

    private func update(_ line: Int, _ value: String) {
        guard document?.settings.first(where: { $0.line == line })?.value != value else { return }
        document?.set(line: line, to: value)
        changed = true
    }

    /// (ini-editor-async, Cameron Nov 8: tapping a file froze the screen) Reads and parses in the
    /// background; the page shows a spinner meanwhile and the log says how long each step took.
    private func load() async {
        let url = url, file = file
        let started = Date()
        let result = await Task.detached(priority: .userInitiated) { () -> (Data, IniFileText, IniDocument, Double, Double)? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let read = Date().timeIntervalSince(started)
            guard let decoded = IniFileText(data: data) else { return nil }
            let doc = IniDocument(text: decoded.text, cfgLines: GameIniFiles.isCfg(file), xml: GameIniFiles.isXML(file))
            return (data, decoded, doc, read, Date().timeIntervalSince(started))
        }.value
        guard let (data, decoded, doc, read, total) = result else {
            error = "This file could not be read. It may have been moved or deleted."
            return
        }
        LogStore.shared.log("[ini] opened \((file as NSString).lastPathComponent): \(data.count) bytes, read \(Int(read * 1000)) ms, parsed \(doc.settings.count) settings, total \(Int(total * 1000)) ms")
        original = data; encoding = decoded
        document = doc
        changed = false
        if let saved = GameIniFiles.savedFingerprint(file), saved != GameIniFiles.fingerprint(data) {
            note = "The game changed this file after it was last saved here. Check your changes are still set."
        }
    }

    private func save() {
        guard let document, let encoding, let out = encoding.data(document.text) else { return }
        // A game running (or another app) may have written it since it opened here.
        if let now = try? Data(contentsOf: url), now != original {
            error = "The file changed while it was open here, so nothing was saved. Go back and open it again."
            return
        }
        do {
            try out.write(to: url, options: .atomic)
            original = out; changed = false; error = nil; note = nil
            GameIniFiles.setSavedFingerprint(GameIniFiles.fingerprint(out), for: file)
            LogStore.shared.log("[ini-editor] saved \(file)")
        } catch {
            self.error = "Not saved: \(error.localizedDescription)"
        }
    }
}
