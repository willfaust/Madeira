// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Game details › Share Setup and Apply Shared Setup: everything a game was set
//  up with, as one file (<title>.madeirasetup) or one line of text for a chat,
//  and back in one tap on another device. GameHub and GameNative trade control
//  layouts and container settings this way; Madeira players were pasting
//  madeira.cfg lines into Discord by hand.
//
//  A setup holds:
//    - the library entry's own fields (resolution, FPS limit, display, x87,
//      fastsync, MetalFX, touch controls and gesture zones, controller mode and
//      bindings, gyro ...), as LibraryEntry encodes them, less the fields that
//      name this device's copy of the game (GameSetup.localKeys);
//    - the game's own config file (GameProfiles.swift) and its launch switches
//      (LibraryPrefs: AVX, NVIDIA, GPU card, Wine's C++ runtime ...);
//    - the .ini files added on its Settings files page, each by its path under
//      the game's folder ("game/...") or under drive_c.
//  Applying one replaces the game's settings with the setup's: an option the
//  sharer left at its default goes back to its default here too.
//
//  A setup also opens from the Files app or a chat (Open in Madeira), or as a
//  madeira://setup?d=... link: the library then asks which game gets it.
//
//  Everything above "MARK: Views" is Foundation only:
//  tests/host/check-game-setup-share.py compiles it with a test harness.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A shared setup, as JSON values (JSONSerialization's types).
struct GameSetup {
    static let format = "madeira-setup"
    static let version = 1
    /// The text form's prefix: "madeira-setup:1:" then "z" (zlib) or "j" (plain JSON), then base64.
    static let textPrefix = "madeira-setup:1:"
    static let fileExtension = "madeirasetup"
    /// Settings files larger than this are left out of a setup.
    static let iniLimit = 256 * 1024

    var title: String
    var steamAppID: Int?
    /// The program's file name, lowercased ("falloutnv.exe"; for a Steam game, its install folder's name).
    var program: String?
    var made: Date?
    var appVersion: String?
    /// LibraryEntry's shared fields (sharedFields), as JSONEncoder wrote them.
    var entry: [String: Any]
    /// The game's own config file.
    var config: String
    /// LibraryPrefs' switches (LibraryPrefs.sharedSwitches).
    var switches: [String: Any]
    struct IniFile: Equatable { var path: String; var data: Data }
    var iniFiles: [IniFile]

    /// Entry fields that name this device's copy of the game, its history or its
    /// store, or that GameProfiles and LibraryPrefs now keep (config, avx, reportNVIDIA).
    static let localKeys: Set<String> = [
        "id", "title", "relativePath", "bits", "coverFile", "steamID", "lastPlayed", "graphicsAPI",
        "folderBytes", "metadataChecked", "metadataRevision", "desktop", "steamAppID",
        "steamMetadataInstall", "gogProductID", "itchGameID", "epicAppName", "eaOfferID",
        "config", "avx", "reportNVIDIA", "controlLayout", "workingDirectory", "liveLogs",
    ]
    /// Fields that only mean something for the same Steam game: its chosen program.
    static let sameGameKeys: Set<String> = [
        "steamStart", "steamProgram", "steamProgramArguments", "steamProgramFolder", "steamProgramSource",
    ]
    /// Fields "Touch controls and controller" stands for in Apply Shared Setup.
    static let controlKeys: Set<String> = [
        "touchControls", "controls", "zones", "controlOpacity", "controlSize", "controllerMode",
        "controllerBinds", "padMouseVertical", "padAssist",
    ]

    /// An entry's fields for a setup: everything but localKeys.
    static func sharedFields(_ entryJSON: [String: Any]) -> [String: Any] {
        entryJSON.filter { !localKeys.contains($0.key) }
    }

    /// The target entry's fields with the setup's put in. The fields a setup can
    /// carry that it does not (an option the sharer left unset) are dropped, so they
    /// decode as unset; `controls: false` keeps the target's touch and controller
    /// fields, `sameGame: false` its Steam program choice.
    static func merge(_ shared: [String: Any], into target: [String: Any], controls: Bool, sameGame: Bool) -> [String: Any] {
        var out = target
        func takes(_ key: String) -> Bool {
            !localKeys.contains(key) && (controls || !controlKeys.contains(key)) && (sameGame || !sameGameKeys.contains(key))
        }
        for key in target.keys where takes(key) && shared[key] == nil { out.removeValue(forKey: key) }
        for (key, value) in shared where takes(key) { out[key] = value }
        return out
    }

    /// The same merge without dropping anything: for an entry type whose required
    /// field the setup lacks (a setup from an older Madeira).
    static func overlay(_ shared: [String: Any], into target: [String: Any], controls: Bool, sameGame: Bool) -> [String: Any] {
        var out = target
        for (key, value) in shared where !localKeys.contains(key) && (controls || !controlKeys.contains(key))
            && (sameGame || !sameGameKeys.contains(key)) { out[key] = value }
        return out
    }

    /// A settings file's path in a setup: "game/<path in the game's folder>" when it
    /// is in the game's folder, else "drive/<path under drive_c>".
    static func sharedIniPath(_ file: String, gameFolder: String) -> String {
        let folder = gameFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !folder.isEmpty, file.lowercased().hasPrefix(folder.lowercased() + "/") {
            return "game/" + file.dropFirst(folder.count + 1)
        }
        return "drive/" + file
    }

    /// A setup's settings-file path as a path under this device's drive_c, nil for
    /// one that leaves drive_c ("..") or names nothing.
    static func localIniPath(_ shared: String, gameFolder: String) -> String? {
        let parts: [Substring]
        if shared.hasPrefix("game/") {
            let folder = gameFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !folder.isEmpty else { return nil }
            parts = folder.split(separator: "/") + shared.dropFirst(5).split(separator: "/")
        } else if shared.hasPrefix("drive/") {
            parts = shared.dropFirst(6).split(separator: "/")
        } else {
            return nil
        }
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }),
              parts.last?.lowercased().hasSuffix(".ini") == true else { return nil }
        return parts.joined(separator: "/")
    }

    // MARK: Encoding

    var json: [String: Any] {
        var out: [String: Any] = [
            "format": Self.format, "version": Self.version, "title": title,
            "entry": entry, "config": config, "switches": switches,
            "iniFiles": iniFiles.map { ["path": $0.path, "data": $0.data.base64EncodedString()] },
        ]
        if let steamAppID { out["steamAppID"] = steamAppID }
        if let program { out["program"] = program }
        if let made { out["made"] = ISO8601DateFormatter().string(from: made) }
        if let appVersion { out["appVersion"] = appVersion }
        return out
    }

    func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    init(title: String, steamAppID: Int? = nil, program: String? = nil, made: Date? = nil, appVersion: String? = nil,
         entry: [String: Any], config: String, switches: [String: Any], iniFiles: [IniFile]) {
        self.title = title; self.steamAppID = steamAppID; self.program = program; self.made = made
        self.appVersion = appVersion; self.entry = entry; self.config = config; self.switches = switches
        self.iniFiles = iniFiles
    }

    enum ReadError: LocalizedError {
        case notASetup, newerVersion(Int)
        var errorDescription: String? {
            switch self {
            case .notASetup: return "This isn't a Madeira setup."
            case .newerVersion: return "This setup was made by a newer Madeira. Update Madeira to apply it."
            }
        }
    }

    init(data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == Self.format else { throw ReadError.notASetup }
        let version = (object["version"] as? NSNumber)?.intValue ?? 0
        guard version >= 1 else { throw ReadError.notASetup }
        guard version <= Self.version else { throw ReadError.newerVersion(version) }
        title = object["title"] as? String ?? "Game"
        steamAppID = (object["steamAppID"] as? NSNumber)?.intValue
        program = object["program"] as? String
        made = (object["made"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        appVersion = object["appVersion"] as? String
        entry = object["entry"] as? [String: Any] ?? [:]
        config = object["config"] as? String ?? ""
        switches = object["switches"] as? [String: Any] ?? [:]
        iniFiles = (object["iniFiles"] as? [[String: Any]] ?? []).compactMap { item in
            guard let path = item["path"] as? String, let text = item["data"] as? String,
                  let bytes = Data(base64Encoded: text) else { return nil }
            return IniFile(path: path, data: bytes)
        }
    }

    /// One line for a chat: textPrefix, then the JSON, compressed where the system can.
    func text() throws -> String {
        let body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        #if canImport(Darwin)
        if let packed = try? (body as NSData).compressed(using: .zlib) as Data {
            return Self.textPrefix + "z" + packed.base64EncodedString()
        }
        #endif
        return Self.textPrefix + "j" + body.base64EncodedString()
    }

    /// A setup from text that holds one somewhere (a pasted chat message), or from a
    /// madeira://setup?d=... link.
    init(text: String) throws {
        var token = ""
        if let range = text.range(of: Self.textPrefix) {
            token = String(text[range.upperBound...].prefix { $0.isLetter || $0.isNumber || "+/=-_".contains($0) })
        } else if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "madeira",
                  url.host == "setup",
                  let d = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "d" })?.value {
            token = d
        }
        guard let kind = token.first else { throw ReadError.notASetup }
        var base64 = String(token.dropFirst()).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let bytes = Data(base64Encoded: base64) else { throw ReadError.notASetup }
        switch kind {
        case "j": try self.init(data: bytes)
        case "z":
            #if canImport(Darwin)
            guard let body = try? (bytes as NSData).decompressed(using: .zlib) as Data else { throw ReadError.notASetup }
            try self.init(data: body)
            #else
            throw ReadError.notASetup
            #endif
        default: throw ReadError.notASetup
        }
    }

    /// What the setup changes, for Apply Shared Setup's list.
    var contents: [String] {
        var out: [String] = []
        let fields = entry.keys.filter { !Self.controlKeys.contains($0) && !Self.sameGameKeys.contains($0) }.count
        if fields > 0 { out.append(fields == 1 ? "1 game setting" : "\(fields) game settings") }
        let lines = configLines.count
        if lines > 0 { out.append(lines == 1 ? "1 config line" : "\(lines) config lines") }
        let on = switches.filter { ($0.value as? Bool) == true || (($0.value as? String).map { !$0.isEmpty } ?? false) }.count
        if on > 0 { out.append(on == 1 ? "1 launch switch" : "\(on) launch switches") }
        if hasControls { out.append("touch controls and controller") }
        if !iniFiles.isEmpty { out.append(iniFiles.count == 1 ? "1 settings file" : "\(iniFiles.count) settings files") }
        return out
    }

    /// The config lines a setup writes, comments left out, for the apply sheet to show.
    var configLines: [String] {
        config.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Where each settings file goes, as the player reads it: in the game's folder or on C:.
    var iniPlaces: [String] {
        iniFiles.map { file in
            if file.path.hasPrefix("game/") { return "Game folder/" + file.path.dropFirst(5) }
            if file.path.hasPrefix("drive/") { return "C:\\" + file.path.dropFirst(6).replacingOccurrences(of: "/", with: "\\") }
            return file.path
        }
    }

    var hasControls: Bool { entry.keys.contains { Self.controlKeys.contains($0) && $0 != "touchControls" } }

    /// The file name for a setup: the title without characters file systems refuse.
    var fileName: String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let clean = title.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        return (clean.isEmpty ? "Game" : String(clean.prefix(80))) + "." + Self.fileExtension
    }

    /// How well this setup fits a game: 2 for the same Steam game or program, 0 for none.
    func match(steamAppID other: Int?, program otherProgram: String?) -> Int {
        if let steamAppID, let other, steamAppID == other { return 2 }
        if let program, let otherProgram, program == otherProgram.lowercased() { return 2 }
        return 0
    }
}

// MARK: Views

extension GameSetup {
    static let contentType = UTType(exportedAs: "app.madeira.setup", conformingTo: .json)

    /// The program's file name a setup names its game by.
    static func programName(_ entry: LibraryEntry) -> String {
        (entry.relativePath.split(separator: "/").last.map(String.init) ?? entry.relativePath).lowercased()
    }

    static func gameFolder(_ entry: LibraryEntry) -> String {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: LibraryModel.drive.appendingPathComponent(entry.relativePath).path,
                                                    isDirectory: &isDirectory)
        return GameIniFiles.gameFolder(relativePath: entry.relativePath, isDirectory: exists && isDirectory.boolValue)
    }

    /// A game's setup as it is now.
    init(entry: LibraryEntry) throws {
        let encoded = try JSONEncoder().encode(entry)
        let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        let path = entry.windowsPath
        let folder = Self.gameFolder(entry)
        var files: [IniFile] = []
        for file in GameIniFiles.files(path) {
            let url = LibraryModel.drive.appendingPathComponent(file)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.iniLimit,
                  let bytes = try? Data(contentsOf: url) else { continue }
            files.append(IniFile(path: Self.sharedIniPath(file, gameFolder: folder), data: bytes))
        }
        self.init(title: entry.title, steamAppID: entry.steamAppID, program: Self.programName(entry), made: Date(),
                  appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                  entry: Self.sharedFields(fields), config: GameProfile(windowsPath: path).text,
                  switches: LibraryPrefs.sharedSwitches(path), iniFiles: files)
    }

    /// Puts the setup into a game: its fields into `entry` (the caller saves it), its
    /// config file and switches at once, and its settings files when `iniFiles`.
    func apply(to entry: inout LibraryEntry, controls: Bool, iniFiles applyIni: Bool) throws {
        let sameGame = steamAppID != nil && steamAppID == entry.steamAppID
        let encoded = try JSONEncoder().encode(entry)
        let target = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        var updated: LibraryEntry
        do {
            let merged = Self.merge(self.entry, into: target, controls: controls, sameGame: sameGame)
            updated = try JSONDecoder().decode(LibraryEntry.self, from: JSONSerialization.data(withJSONObject: merged))
        } catch {
            let merged = Self.overlay(self.entry, into: target, controls: controls, sameGame: sameGame)
            updated = try JSONDecoder().decode(LibraryEntry.self, from: JSONSerialization.data(withJSONObject: merged))
        }
        if !controls { updated.controlLayout = entry.controlLayout }
        else if updated.controls != nil { updated.controlLayout = nil }   // a layout of this device's would take the edits
        try updated.validate()
        let path = entry.windowsPath
        let profile = GameProfile(windowsPath: path)
        profile.text = config
        LibraryPrefs.applySharedSwitches(switches, for: path)
        var written = 0
        if applyIni {
            let folder = Self.gameFolder(entry)
            for file in iniFiles {
                guard let local = Self.localIniPath(file.path, gameFolder: folder) else { continue }
                let url = LibraryModel.drive.appendingPathComponent(local)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: url, options: .atomic)
                GameIniFiles.add(local, for: path)
                GameIniFiles.setSavedFingerprint(GameIniFiles.fingerprint(file.data), for: local)
                written += 1
            }
        }
        entry = updated
        LogStore.shared.log("[setup-share] applied \"\(title)\" to \(entry.title): \(self.entry.count) fields, "
                            + "controls=\(controls), \(written) settings files")
    }

    /// A temporary <title>.madeirasetup for the share sheet.
    func temporaryFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("setups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try data().write(to: url, options: .atomic)
        return url
    }

    static func read(file url: URL) throws -> GameSetup {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= 8 * 1024 * 1024 else { throw ReadError.notASetup }
        let bytes = try Data(contentsOf: url)
        if let setup = try? GameSetup(data: bytes) { return setup }
        return try GameSetup(text: String(decoding: bytes, as: UTF8.self))
    }
}

/// A setup opened from outside the library (Files, a chat, a madeira://setup link),
/// waiting for the library to ask which game gets it.
final class GameSetupInbox: ObservableObject {
    static let shared = GameSetupInbox()
    struct Pending: Identifiable { let id = UUID(); let setup: GameSetup }
    @Published var pending: Pending?
    @Published var error: String?

    /// True when the URL was a setup (a file or a madeira://setup link).
    @discardableResult
    func handle(_ url: URL) -> Bool {
        let isFile = url.isFileURL && url.pathExtension.lowercased() == GameSetup.fileExtension
        let isLink = url.scheme?.lowercased() == "madeira" && url.host?.lowercased() == "setup"
        guard isFile || isLink else { return false }
        do {
            let setup = try (isFile ? GameSetup.read(file: url) : GameSetup(text: url.absoluteString))
            LogStore.shared.log("[setup-share] opened a setup for \(setup.title)")
            DispatchQueue.main.async { self.pending = Pending(setup: setup) }
        } catch {
            DispatchQueue.main.async { self.error = error.localizedDescription }
        }
        return true
    }
}

/// Game details › Share Setup: the file for the share sheet, or the text for a chat.
struct GameSetupShareSheet: View {
    let entry: LibraryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var setup: GameSetup?
    @State private var file: URL?
    @State private var text: String?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                } else if let setup {
                    Section {
                        ForEach(setup.contents.isEmpty ? ["Default settings only"] : setup.contents, id: \.self) {
                            Label($0, systemImage: "checkmark.circle")
                        }
                    } header: {
                        Text("Included")
                    } footer: {
                        Text("Your saves, game files and sign-ins are never included.")
                    }
                    Section {
                        if let file {
                            ShareLink(item: file) { Label("Share as a File", systemImage: "square.and.arrow.up") }
                        }
                        Button {
                            UIPasteboard.general.string = text
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy as Text", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .disabled(text == nil)
                    } footer: {
                        Text("Send the file, or paste the text in a chat. On the other device, open the file with Madeira, or open the game's details and tap Apply Shared Setup.")
                    }
                }
            }
            .navigationTitle("Share Setup").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                do {
                    let made = try GameSetup(entry: entry)
                    setup = made
                    file = try made.temporaryFile()
                    text = "\(made.title) setup for Madeira: " + (try made.text())
                } catch {
                    self.error = "This game's setup could not be saved: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// Apply Shared Setup: what the setup holds, then Apply. `apply` writes it into the game.
struct GameSetupApplySheet: View {
    let setup: GameSetup
    let gameTitle: String
    /// The setup names another game than this one.
    let otherGame: Bool
    let apply: (_ controls: Bool, _ iniFiles: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var controls = true
    @State private var iniFiles = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(setup.contents.isEmpty ? ["Default settings"] : setup.contents, id: \.self) {
                        Label($0, systemImage: "checkmark.circle")
                    }
                } header: {
                    Text("\(setup.title) setup")
                } footer: {
                    if otherGame {
                        Text("This setup was made for \(setup.title). It may not suit \(gameTitle).")
                            .foregroundStyle(.orange)
                    }
                }
                if !setup.configLines.isEmpty || !setup.iniFiles.isEmpty {
                    Section {
                        if !setup.configLines.isEmpty {
                            DisclosureGroup("Config lines") {
                                ForEach(Array(setup.configLines.enumerated()), id: \.offset) {
                                    Text($0.element).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                        if !setup.iniFiles.isEmpty {
                            DisclosureGroup("Settings files") {
                                ForEach(Array(setup.iniPlaces.enumerated()), id: \.offset) {
                                    Text($0.element).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                    } header: {
                        Text("What it changes")
                    } footer: {
                        Text("Check these before applying a setup from someone you don't know.")
                    }
                }
                Section {
                    if setup.hasControls { Toggle("Touch controls and controller", isOn: $controls) }
                    if !setup.iniFiles.isEmpty { Toggle("Settings files", isOn: $iniFiles) }
                } footer: {
                    Text("Applying replaces \(gameTitle)'s settings with this setup's. Your saves and game files stay as they are.")
                }
                Section {
                    Button("Apply to \(gameTitle)", systemImage: "square.and.arrow.down") {
                        apply(controls && setup.hasControls, iniFiles && !setup.iniFiles.isEmpty)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Apply Shared Setup").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// A setup opened from outside: which game gets it, the best matches first.
struct GameSetupInboxSheet: View {
    let setup: GameSetup
    @ObservedObject private var model = LibraryModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: LibraryEntry?
    @State private var error: String?

    private var games: [LibraryEntry] {
        model.entries.filter { $0.desktop != true }.sorted {
            let a = setup.match(steamAppID: $0.steamAppID, program: GameSetup.programName($0))
            let b = setup.match(steamAppID: $1.steamAppID, program: GameSetup.programName($1))
            if a != b { return a > b }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    ForEach(games) { game in
                        Button {
                            chosen = game
                        } label: {
                            HStack {
                                Text(game.title).foregroundStyle(.primary)
                                Spacer()
                                if setup.match(steamAppID: game.steamAppID, program: GameSetup.programName(game)) > 0 {
                                    Text("Made for this game").font(.caption).foregroundStyle(.green)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Apply \(setup.title) setup to")
                } footer: {
                    if games.isEmpty { Text("Add the game to your library first, then open the setup again.") }
                }
            }
            .navigationTitle("Shared Setup").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: $chosen) { game in
                GameSetupApplySheet(setup: setup, gameTitle: game.title,
                                    otherGame: setup.match(steamAppID: game.steamAppID, program: GameSetup.programName(game)) == 0) { controls, ini in
                    var entry = game
                    do {
                        try setup.apply(to: &entry, controls: controls, iniFiles: ini)
                        model.save(entry)
                        dismiss()
                    } catch {
                        self.error = "This setup could not be applied: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

/// On the library: the game picker for a setup GameSetupInbox received, and its errors.
struct GameSetupInboxPresenter: ViewModifier {
    @ObservedObject private var inbox = GameSetupInbox.shared
    func body(content: Content) -> some View {
        content
            .sheet(item: $inbox.pending) { GameSetupInboxSheet(setup: $0.setup) }
            .alert("Shared setup", isPresented: Binding(get: { inbox.error != nil }, set: { if !$0 { inbox.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(inbox.error ?? "") }
    }
}
