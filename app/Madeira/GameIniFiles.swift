// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Game details › Settings files: a game's own .ini files (Documents/My Games,
//  the game's folder), added per game and edited in the app, section by section,
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

/// An .ini file's text, its settings found by line. Setting a value rewrites
/// that line only; every other byte stays as it was.
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

    init(text: String) {
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
        var section = ""
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                section = String(line[line.index(after: line.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let parts = Self.split(raw) else { continue }
            settings.append(Setting(line: i, section: section, key: parts.key, value: parts.value))
        }
    }

    /// "  iSize W = 1280 " -> key "iSize W", value "1280", and where the value starts.
    private static func split(_ raw: String) -> (key: String, value: String, valueStart: String.Index)? {
        guard let eq = raw.firstIndex(of: "=") else { return nil }
        let key = raw[..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        var start = raw.index(after: eq)
        while start < raw.endIndex, raw[start] == " " || raw[start] == "\t" { start = raw.index(after: start) }
        var value = String(raw[start...])
        while let last = value.last, last == " " || last == "\t" { value.removeLast() }
        return (key, value, start)
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

    /// Sets the setting on `line` to `value`; the text before the value is kept.
    mutating func set(line: Int, to value: String) {
        guard let i = settings.firstIndex(where: { $0.line == line }), let parts = Self.split(lines[line]) else { return }
        let raw = lines[line]
        var tail = ""
        if let last = raw.last, last == " " || last == "\t" {
            tail = String(raw.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
        }
        lines[line] = String(raw[..<parts.valueStart]) + value + (value.isEmpty ? "" : tail)
        settings[i].value = value
    }

    /// The value of `key` in `section` (case-insensitive), the first one in the file.
    func value(section: String, key: String) -> String? {
        settings.first { $0.section.caseInsensitiveCompare(section) == .orderedSame && $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    var text: String { lines.joined(separator: newline) + (endsWithNewline ? newline : "") }
}

/// A file's bytes as text, and back in the same encoding (UTF-16 LE with its
/// byte order mark, UTF-8 with or without one, else Windows Latin 1, which
/// every byte decodes as).
struct IniFileText: Equatable {
    var text: String
    let bom: Bool
    let utf8: Bool
    let utf16: Bool

    init?(data: Data) {
        // FF FE is what Windows calls "Unicode"; WritePrivateProfileStringW keeps writing such a file as UTF-16 LE.
        if data.starts(with: [0xFF, 0xFE]) {
            guard let s = String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian) else { return nil }
            text = s; bom = true; utf8 = false; utf16 = true
            return
        }
        utf16 = false
        let marker = Data([0xEF, 0xBB, 0xBF])
        bom = data.starts(with: marker)
        let body = bom ? data.dropFirst(3) : data[...]
        if let s = String(data: Data(body), encoding: .utf8) { text = s; utf8 = true }
        else if let s = String(data: Data(body), encoding: .windowsCP1252) ?? String(data: Data(body), encoding: .isoLatin1) { text = s; utf8 = false }
        else { return nil }
    }

    func data(_ text: String) -> Data? {
        if utf16 { return text.data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 } }
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
        if let i = parts.firstIndex(where: { $0.caseInsensitiveCompare("My Games") == .orderedSame }) {
            return parts[i...].joined(separator: "\\")
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

    /// The .ini files a game is likely to use, under drive_c: its own folder (five
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
                guard url.pathExtension.lowercased() == "ini" else { continue }
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(drive.path + "/") else { continue }
                let relative = String(path.dropFirst(drive.path.count + 1))
                if seen.insert(relative.lowercased()).inserted { found.append(relative) }
            }
        }
        let users = drive.appendingPathComponent("users", isDirectory: true)
        for user in ((try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []).sorted() {
            let games = users.appendingPathComponent(user).appendingPathComponent("Documents/My Games", isDirectory: true)
            if FileManager.default.fileExists(atPath: games.path) { scan(games, depth: 3) }
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

/// What a setting in a Bethesda game's .ini file does, for the ⓘ next to it. Known
/// settings have a sentence; any other gets what its name's first letter says about
/// its value (bName a switch, iName a whole number, and so on), or nothing.
enum IniSettingHelp {
    static func describe(key: String) -> String? {
        let name = key.trimmingCharacters(in: .whitespaces)
        if let known = known[name.lowercased()] { return known }
        return kind(name)
    }

    /// The Bethesda naming habit: one lower- or upper-case letter for the type, then the name.
    static func kind(_ key: String) -> String? {
        let chars = Array(key)
        guard chars.count > 1, chars[1].isUppercase else { return nil }
        switch chars[0] {
        case "b": return "A switch: 1 is on, 0 is off."
        case "i": return "A whole number."
        case "u": return "A whole number, 0 or more."
        case "f": return "A number that can have a decimal point."
        case "s", "S": return "Text."
        default: return nil
        }
    }

    /// Keys in lower case. Shared by Fallout 3, New Vegas, Oblivion and Skyrim unless a sentence says otherwise.
    static let known: [String: String] = [
        // [Display]
        "isize w": "The game's width in pixels. Madeira's display size is set per game in Display; keep them the same.",
        "isize h": "The game's height in pixels. Madeira's display size is set per game in Display; keep them the same.",
        "bfull screen": "Full screen (1) or a window (0).",
        "imultisample": "Anti-aliasing: smooths jagged edges. 0 is off and fastest; 2, 4 or 8 look smoother but cost a lot of speed.",
        "imaxanisotropy": "Texture sharpness at an angle (anisotropic filtering), from 0 to 16. Higher looks sharper and costs a little speed.",
        "ipresentinterval": "V-sync: 1 waits for the screen and stops tearing, 0 does not.",
        "itexmipmapskip": "Texture quality: 0 is full, 1 is half size, 2 is a quarter. Higher saves memory and speed.",
        "ishadowmapresolution": "The size of shadow textures. Lower (512 or 1024) is faster and blurrier.",
        "iactorshadowcountext": "How many characters cast shadows outdoors. Lower is faster.",
        "iactorshadowcountint": "How many characters cast shadows indoors. Lower is faster.",
        "bshadowsongrass": "Grass gets shadows. Off is faster.",
        "bdodepthoffield": "Blurs the background (depth of field). Off is faster and sharper.",
        "busewaterreflections": "Water reflects the world. Off is faster.",
        "flodfadeoutmultobjects": "How far away objects stay visible. Lower is faster.",
        "flodfadeoutmultitems": "How far away small items stay visible. Lower is faster.",
        "flodfadeoutmultactors": "How far away characters stay visible. Lower is faster.",
        "fdefaultfov": "Field of view in degrees: how wide the camera sees.",
        "sd3ddevice": "The graphics card the game last saw. Madeira keeps it in step with the Older NVIDIA card setting; changing it by hand makes the game reopen its launcher.",
        // [Grass]
        "fgrassstartfadedistance": "How far away grass is drawn. Lower is faster.",
        "imingrasssize": "Grass spacing: higher means less grass and more speed.",
        // [General]
        "ugridstoload": "How many cells (blocks of world) around you load in full detail. 5 is normal; higher is much slower and can crash.",
        "ugriddistanttreerange": "How many cells away distant trees are drawn.",
        "ugriddistantcount": "How many cells away the distant landscape and buildings are drawn.",
        "uinterior cell buffer": "How many indoor areas stay in memory after you leave them.",
        "uexterior cell buffer": "How many outdoor cells stay in memory after you leave them.",
        "ipreloadsizelimit": "Memory, in bytes, set aside for loading things ahead of time.",
        "bpreemptivelyunloadcells": "Frees areas from memory as soon as you leave them. Can lower memory use.",
        "inumhwthreads": "How many processor threads the game plans for.",
        "busethreadedai": "Runs characters' AI on its own thread.",
        "isavegamebackupcount": "How many backup copies of a save are kept when you save over it.",
        "ballowscriptedautosave": "Lets quests save the game automatically.",
        "bdisplaymissingcontentdialogue": "Warns when a save needs a mod or add-on that is missing.",
        "ssavegamesafecellid": "Where the game puts you if a save cannot load your spot. Leave it as it is.",
        "slanguage": "The language the game's text is in.",
        "sintrosequence": "The videos played at start. Empty skips them.",
        "bloadfacegenheadegtfiles": "New Vegas: loads the files that colour characters' faces. On fixes faces that do not match their necks; it uses more memory.",
        // [Controls]
        "busejoystick": "Controller support: 1 on, 0 off.",
        "binvertyvalues": "Inverts looking up and down.",
    ]
}

// MARK: Views

/// Game details › Settings files: the game's added .ini files, and "Add .ini file".
struct GameIniFilesSection: View {
    let windowsPath: String
    let gameFolder: String
    @State private var files: [String] = []

    var body: some View {
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
                Label("Add .ini file", systemImage: "plus")
            }
        } footer: {
            Text("A game's own settings files, like Fallout.ini or FalloutPrefs.ini. Changes are saved into the file; close the game first. Swipe left to take a file off this list (the file stays).")
        }
        .onAppear { files = GameIniFiles.files(windowsPath) }
    }
}

/// The .ini files under the game's folder and Documents/My Games, to add one.
struct IniFilePicker: View {
    let gameFolder: String
    let added: Set<String>
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var found: [String]?
    @State private var query = ""

    var body: some View {
        List {
            if let found {
                let shown = query.isEmpty ? found : found.filter { $0.localizedCaseInsensitiveContains(query) }
                if shown.isEmpty {
                    Text(found.isEmpty ? "No .ini files in the game's folder or Documents › My Games yet. A game often writes its files the first time it runs." : "No file matches.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown, id: \.self) { file in
                    Button {
                        pick(file); dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((file as NSString).lastPathComponent).foregroundStyle(.primary)
                                Text(GameIniFiles.label(file, gameFolder: gameFolder)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if added.contains(file.lowercased()) { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(added.contains(file.lowercased()))
                }
            } else {
                HStack { ProgressView(); Text("Looking for .ini files").foregroundStyle(.secondary) }
            }
        }
        .searchable(text: $query, prompt: "File name")
        .navigationTitle("Add .ini file").navigationBarTitleDisplayMode(.inline)
        .task {
            guard found == nil else { return }
            let folder = gameFolder, drive = LibraryModel.drive
            let list = await Task.detached(priority: .userInitiated) { GameIniFiles.candidates(drive: drive, gameFolder: folder) }.value
            found = list
        }
    }
}

/// One .ini file, section by section: each setting's value can be changed;
/// Save writes only the changed lines.
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

    private var url: URL { LibraryModel.drive.appendingPathComponent(file) }

    var body: some View {
        Form {
            if let note { Section { Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if let document {
                if document.settings.isEmpty { Section { Text("This file has no settings (key = value lines).").foregroundStyle(.secondary) } }
                ForEach(document.sections, id: \.name) { group in
                    let rows = query.isEmpty ? group.settings : group.settings.filter { $0.key.localizedCaseInsensitiveContains(query) || group.name.localizedCaseInsensitiveContains(query) }
                    if !rows.isEmpty {
                        Section(group.name.isEmpty ? "Settings" : "[\(group.name)]") {
                            ForEach(rows) { setting in row(setting) }
                        }
                    }
                }
            } else if error == nil {
                ProgressView()
            }
        }
        .searchable(text: $query, prompt: "Setting or section")
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!changed) }
        }
        .onAppear { if document == nil { load() } }
        .alert(info?.key ?? "", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } }), presenting: info) { _ in
            Button("OK") {}
        } message: { setting in
            let section = setting.section.isEmpty ? "" : "In [\(setting.section)]. "
            Text(section + (IniSettingHelp.describe(key: setting.key) ?? "No description for this setting yet."))
        }
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
            } label: {
                label(setting)
            }
        }
    }

    /// The key, and a blue ⓘ that shows its full name and what it does.
    private func label(_ setting: IniDocument.Setting) -> some View {
        HStack(spacing: 6) {
            Text(setting.key).font(.callout.monospaced())
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

    private func load() {
        guard let data = try? Data(contentsOf: url), let decoded = IniFileText(data: data) else {
            error = "This file could not be read. It may have been moved or deleted."
            return
        }
        original = data; encoding = decoded
        document = IniDocument(text: decoded.text)
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
