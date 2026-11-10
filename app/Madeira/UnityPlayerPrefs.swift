// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Game details › Settings files › Unity game options: the options a Unity game
//  keeps in the registry (PlayerPrefs, HKCU\Software\<Company>\<Product>), read
//  from and written to the prefix's user.reg. Unity games have no settings file
//  for resolution, window mode or quality: they are these values.
//
//  Each value keeps the type Wine wrote it with: dword: (a whole number),
//  hex(4): with 8 bytes (Unity's decimal numbers, a double in a DWORD value),
//  hex: ending in a 0 byte (Unity's text) and "..." (plain text). Anything else is
//  shown and not changed. Only the changed value lines are rewritten.
//
//  Everything above "MARK: Views" is Foundation only:
//  tests/host/check-ini-editor.py compiles it with a test harness.
//

import Foundation
import SwiftUI

enum UnityPlayerPrefs {
    /// A Unity game: UnityPlayer.dll in its folder, or a <Name>_Data folder with
    /// Unity's files (app.info, Managed/UnityEngine.dll, globalgamemanagers).
    static func isUnity(gameFolder: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: gameFolder.appendingPathComponent("UnityPlayer.dll").path) { return true }
        return dataFolders(gameFolder).contains { data in
            ["app.info", "Managed/UnityEngine.dll", "globalgamemanagers"].contains { fm.fileExists(atPath: data.appendingPathComponent($0).path) }
        }
    }

    private static func dataFolders(_ gameFolder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: gameFolder.path)) ?? []
        return names.filter { $0.hasSuffix("_Data") }.sorted().map { gameFolder.appendingPathComponent($0, isDirectory: true) }
    }

    /// The company and product from <Name>_Data/app.info (two lines), which name
    /// the game's registry key.
    static func appInfo(gameFolder: URL) -> (company: String, product: String)? {
        for data in dataFolders(gameFolder) {
            guard let text = try? String(contentsOf: data.appendingPathComponent("app.info"), encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if lines.count >= 2 { return (lines[0], lines[1]) }
        }
        return nil
    }

    /// "Software\Company\Product" as user.reg writes a key name.
    static func keyName(company: String, product: String) -> String {
        ["Software", company, product].map(escapeKey).joined(separator: "\\\\")
    }

    private static func escapeKey(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }

    /// "[Software\\Company\\Product] 1730000000" -> "Software\\Company\\Product".
    static func header(_ line: String) -> String? {
        guard line.hasPrefix("[") else { return nil }
        var i = line.index(after: line.startIndex)
        var escaped = false
        while i < line.endIndex {
            let c = line[i]
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "]" {
                return String(line[line.index(after: line.startIndex)..<i])
            }
            i = line.index(after: i)
        }
        return nil
    }

    /// Keys under Software\<Company>\<Product> holding Unity's own values
    /// (Screenmanager..., UnityGraphicsQuality), for a game without app.info.
    static func unityKeys(in text: String) -> [String] {
        var found: [String] = []
        var current: String?
        for line in text.components(separatedBy: "\n") {
            if let key = header(line) { current = key; continue }
            guard let key = current, line.hasPrefix("\"Screenmanager") || line.hasPrefix("\"UnityGraphicsQuality") else { continue }
            if key.lowercased().hasPrefix("software\\\\"), key.components(separatedBy: "\\\\").count == 3, !found.contains(key) { found.append(key) }
        }
        return found
    }

    enum Kind: Equatable {
        case number(Int32)
        case decimal(Double)
        case text(String, binary: Bool)
        case other(String)
    }

    struct Value: Equatable, Identifiable {
        /// The value's lines in user.reg (more than one when its data goes on with "\").
        let lines: Range<Int>
        let name: String
        let kind: Kind
        var id: Int { lines.lowerBound }

        /// Unity adds "_h" and a number to each name; this leaves it out.
        var title: String {
            guard let range = name.range(of: "_h", options: .backwards),
                  !name[range.upperBound...].isEmpty, name[range.upperBound...].allSatisfy(\.isNumber) else { return name }
            return String(name[..<range.lowerBound])
        }

        var shown: String {
            switch kind {
            case .number(let n): return String(n)
            case .decimal(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
            case .text(let s, _): return s
            case .other(let raw): return raw
            }
        }

        var editable: Bool { if case .other = kind { return false }; return true }
        var isText: Bool { if case .text = kind { return true }; return false }
    }

    /// The values of `key` (as user.reg names it, case-insensitive). nil when the
    /// key is not there (the game has not saved its options yet).
    static func values(in text: String, key: String) -> [Value]? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { header($0)?.caseInsensitiveCompare(key) == .orderedSame }) else { return nil }
        var out: [Value] = []
        var i = start + 1
        while i < lines.count {
            let line = lines[i]
            if header(line) != nil { break }
            var end = i + 1
            var joined = line.hasSuffix("\r") ? String(line.dropLast()) : line
            while joined.hasSuffix("\\"), end < lines.count {
                var next = lines[end]
                if next.hasSuffix("\r") { next.removeLast() }
                joined = String(joined.dropLast()) + next.trimmingCharacters(in: .whitespaces)
                end += 1
            }
            if joined.hasPrefix("\""), let parts = split(joined) {
                out.append(Value(lines: i..<end, name: parts.name, kind: kind(parts.data)))
            }
            i = end
        }
        return out
    }

    /// "\"name\"=data" -> name (unescaped), data.
    private static func split(_ line: String) -> (name: String, data: String)? {
        var name = ""
        var i = line.index(after: line.startIndex)
        while i < line.endIndex {
            let c = line[i]
            if c == "\\" {
                let next = line.index(after: i)
                guard next < line.endIndex else { return nil }
                if line[next] == "x" {   // \x1234: a character Wine wrote as hex
                    let digits = line[line.index(after: next)...].prefix { $0.isHexDigit }.prefix(4)
                    if let code = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(code) { name.unicodeScalars.append(scalar) }
                    i = line.index(next, offsetBy: digits.count + 1)
                    continue
                }
                name.append(line[next] == "n" ? "\n" : line[next])
                i = line.index(after: next)
                continue
            }
            if c == "\"" {
                let rest = line[line.index(after: i)...]
                guard rest.hasPrefix("=") else { return nil }
                return (name, String(rest.dropFirst()))
            }
            name.append(c)
            i = line.index(after: i)
        }
        return nil
    }

    static func kind(_ data: String) -> Kind {
        let lower = data.lowercased()
        if lower.hasPrefix("dword:"), let n = UInt32(data.dropFirst(6), radix: 16) { return .number(Int32(bitPattern: n)) }
        if lower.hasPrefix("hex(4):"), let bytes = hexBytes(data.dropFirst(7)), bytes.count == 8 {
            let bits = bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
            return .decimal(Double(bitPattern: bits))
        }
        if lower.hasPrefix("hex:"), let bytes = hexBytes(data.dropFirst(4)), bytes.last == 0,
           let s = String(bytes: bytes.dropLast(), encoding: .utf8), !s.contains(where: { $0.isASCII && $0.asciiValue! < 32 }) {
            return .text(s, binary: true)
        }
        if data.hasPrefix("\""), data.hasSuffix("\""), data.count >= 2 {
            return .text(unescape(String(data.dropFirst().dropLast())), binary: false)
        }
        return .other(data)
    }

    private static func hexBytes<S: StringProtocol>(_ s: S) -> [UInt8]? {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty { return [] }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        return bytes.count == parts.count ? bytes : nil
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The data part for `value` set to `input`, in the value's own type. nil when
    /// `input` does not fit (a word in a number).
    static func data(for value: Value, _ input: String) -> String? {
        let typed = input.trimmingCharacters(in: .whitespaces)
        switch value.kind {
        case .number:
            guard let n = Int32(typed) ?? (typed.lowercased() == "true" ? 1 : typed.lowercased() == "false" ? 0 : nil) else { return nil }
            return "dword:" + String(format: "%08x", UInt32(bitPattern: n))
        case .decimal:
            guard let d = Double(typed), d.isFinite else { return nil }
            var bits = d.bitPattern
            let bytes = (0..<8).map { _ -> UInt8 in defer { bits >>= 8 }; return UInt8(bits & 0xff) }
            return "hex(4):" + bytes.map { String(format: "%02x", $0) }.joined(separator: ",")
        case .text(_, let binary):
            guard binary else { return "\"" + escape(input) + "\"" }
            return "hex:" + (Array(input.utf8) + [0]).map { String(format: "%02x", $0) }.joined(separator: ",")
        case .other:
            return nil
        }
    }

    /// The value written the way Wine writes it: "name"=data, long data going on
    /// to the next lines after "\" (each line at most 80 characters).
    static func lines(name: String, data: String) -> [String] {
        let first = "\"" + escape(name) + "\"=" + data
        guard first.count > 80, let comma = data.firstIndex(of: ":"), data[data.index(after: comma)...].contains(",") else { return [first] }
        var out: [String] = []
        var line = "\"" + escape(name) + "\"=" + data[...comma]
        let bytes = data[data.index(after: comma)...].split(separator: ",")
        for (i, byte) in bytes.enumerated() {
            let piece = byte + (i == bytes.count - 1 ? "" : ",")
            if line.count + piece.count > 79, line != "  " { out.append(line + "\\"); line = "  " }
            line += piece
        }
        out.append(line)
        return out
    }

    /// user.reg's text with each changed value (by its first line) rewritten.
    /// nil when a new value does not fit its type.
    static func apply(_ changes: [Int: String], to text: String, key: String) -> String? {
        guard let found = Self.values(in: text, key: key) else { return nil }
        let crlf = text.contains("\r\n")
        var lines = text.components(separatedBy: "\n")
        for value in found.sorted(by: { $0.lines.lowerBound > $1.lines.lowerBound }) {
            guard let input = changes[value.lines.lowerBound] else { continue }
            guard let written = Self.data(for: value, input) else { return nil }
            lines.replaceSubrange(value.lines, with: Self.lines(name: value.name, data: written).map { crlf ? $0 + "\r" : $0 })
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: Views

/// A Unity game's registry options, each in its own type. Saved into user.reg
/// only while no game runs: Wine keeps the registry in memory and writes over
/// the file when it stops.
struct UnityOptionsPage: View {
    let gameFolder: String
    @State private var key: String?
    @State private var keys: [String] = []
    @State private var values: [UnityPlayerPrefs.Value] = []
    @State private var edits: [Int: String] = [:]
    @State private var original: Data?
    @State private var missing = false
    @State private var error: String?
    @State private var saved = false
    @State private var info: UnityPlayerPrefs.Value?
    /// A tap anywhere on a row puts the cursor in its value (see IniFileEditor).
    @FocusState private var focused: Int?

    private var registry: URL { LibraryModel.drive.deletingLastPathComponent().appendingPathComponent("user.reg") }

    var body: some View {
        Form {
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if saved { Section { Label("Saved. The game uses it the next time it starts.", systemImage: "checkmark.circle").foregroundStyle(.green) } }
            if missing {
                Section { Text("This game has not saved any options yet. Start it once, change a setting in its menu, quit, and come back.").foregroundStyle(.secondary) }
            }
            if keys.count > 1 {
                Section {
                    Picker("Game", selection: Binding(get: { key ?? "" }, set: { key = $0; read() })) {
                        ForEach(keys, id: \.self) { Text($0.components(separatedBy: "\\\\").dropFirst().joined(separator: " › ")).tag($0) }
                    }
                }
            }
            if !values.isEmpty {
                Section {
                    ForEach(values) { value in row(value) }
                } header: {
                    Text(key.map { $0.components(separatedBy: "\\\\").dropFirst().joined(separator: " › ") } ?? "")
                } footer: {
                    Text("Unity keeps these in the registry instead of a file. Close the game before saving.")
                }
            } else if original == nil && error == nil && !missing {
                ProgressView()
            }
        }
        .navigationTitle("Unity game options").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(edits.isEmpty) } }
        .interactiveDismissDisabled(!edits.isEmpty || focused != nil)   // see IniFileEditor
        .task { if original == nil { await load() } }
        .alert(info.map { IniSettingHelp.info(key: $0.title).title ?? $0.title } ?? "",
               isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } }), presenting: info) { _ in
            Button("OK") {}
        } message: { value in
            Text(IniSettingHelp.info(key: value.title, value: value.shown).text + "\n\n" + value.name)
        }
    }

    @ViewBuilder private func row(_ value: UnityPlayerPrefs.Value) -> some View {
        let text = Binding(get: { edits[value.id] ?? value.shown },
                           set: { edits[value.id] = $0 == value.shown ? nil : $0; saved = false })
        LabeledContent {
            if value.editable {
                TextField("", text: text)
                    .multilineTextAlignment(.trailing).font(.callout.monospaced())
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .keyboardType(value.isText ? .default : .numbersAndPunctuation)
                    .focused($focused, equals: value.id)
                    .frame(minWidth: 56, maxWidth: 150)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { focused = value.id })
            } else {
                Text(value.shown).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = IniSettingHelp.known[value.title.lowercased()]?.title {
                        Text(title).font(.callout)
                        Text(IniSettingHelp.breakable(value.title)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    } else {
                        Text(IniSettingHelp.breakable(value.title)).font(.callout.monospaced())
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Button { info = value } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless).foregroundStyle(.blue)
                    .accessibilityLabel("About \(value.title)")
            }
            .contentShape(Rectangle())
            .onTapGesture { if value.editable { focused = value.id } }
        }
    }

    /// (ini-editor-async) The registry and the game folder are read in the background.
    private func load() async {
        let registry = registry
        let folder = LibraryModel.drive.appendingPathComponent(gameFolder, isDirectory: true)
        let started = Date()
        let result = await Task.detached(priority: .userInitiated) { () -> (Data, [String], String?)? in
            guard let data = try? Data(contentsOf: registry) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            let keys: [String]
            if let app = UnityPlayerPrefs.appInfo(gameFolder: folder) {
                keys = [UnityPlayerPrefs.keyName(company: app.company, product: app.product)]
            } else {
                keys = UnityPlayerPrefs.unityKeys(in: text)
            }
            return (data, keys, keys.first(where: { UnityPlayerPrefs.values(in: text, key: $0) != nil }) ?? keys.first)
        }.value
        guard let (data, found, chosen) = result else {
            error = "The Wine registry (user.reg) could not be read. Start any game once, then come back."
            return
        }
        LogStore.shared.log("[ini] Unity options: registry \(data.count) bytes, \(found.count) key(s) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        original = data
        keys = found
        key = chosen
        read()
    }

    private func read() {
        edits = [:]
        guard let original, let key, let found = UnityPlayerPrefs.values(in: String(decoding: original, as: UTF8.self), key: key) else {
            values = []; missing = true; return
        }
        missing = found.isEmpty
        values = found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func save() {
        guard let original, let key else { return }
        if EpicLibrary.shared.sessionRunning {
            error = "Close the game first. Wine keeps these options in memory while a game runs and would write over the change."
            return
        }
        guard let now = try? Data(contentsOf: registry), now == original else {
            error = "The registry changed while this page was open, so nothing was saved. Go back and open it again."
            return
        }
        guard let text = UnityPlayerPrefs.apply(edits, to: String(decoding: original, as: UTF8.self), key: key) else {
            error = "A value does not fit its kind (a number needs digits only). Nothing was saved."
            return
        }
        let backup = registry.appendingPathExtension("madeira-bak")
        if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: registry, to: backup) }
        do {
            let out = Data(text.utf8)
            try out.write(to: registry, options: .atomic)
            LogStore.shared.log("[unity-options] saved \(edits.count) value(s) in \(key)")
            self.original = out; error = nil; saved = true
            read()
        } catch {
            self.error = "Not saved: \(error.localizedDescription)"
        }
    }
}
