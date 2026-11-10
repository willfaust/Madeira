// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Madeira Dock: "Steam starts" (Game details › Steam). Madeira can start only one
/// 32-bit program per session, so a game whose 32-bit launcher starts the game
/// (Fallout: New Vegas's FalloutNVLauncher.exe) ends the session at the launcher's
/// Play: the game's code is never made executable. With a program chosen here, the
/// program Steam's launch entry names is kept beside it as "<name>.madeira-launcher"
/// and a copy of the chosen program takes its name, so Valve's client (which still
/// starts the game and checks ownership) starts the game itself. Without a choice
/// the kept launcher is put back. Both happen at a Dock start, while no session runs.
///
/// A Unity game finds its data by its own file name ("7DaysToDie.exe" reads
/// "7DaysToDie_Data"), so its copy under the launcher's name ("7dLauncher.exe") would
/// look for "7dLauncher_Data" and stop with "Data folder not found". For a chosen
/// program with a "<name>_Data" folder beside it, the swap adds a link named after the
/// launcher that points at that folder (relative, so it survives the app container
/// moving). Only a link Madeira made is ever removed; a real folder is never touched.
/// Switch: env.MADEIRA_DOCK_START_UNITY_DATA = 0 (no link).
enum DockStartProgram {
    /// The launcher's file while a copy of the chosen program has its name. Not an
    /// .exe, so the Program picker does not list it.
    static let keptSuffix = ".madeira-launcher"
    private static let key = "MadeiraDockStartProgram"

    /// The program (relative to the install folder, "FalloutNV.exe") Steam's launch
    /// entry is swapped for; nil: Steam's own.
    static func chosen(_ appID: Int, defaults: UserDefaults = .standard) -> String? {
        let all = defaults.dictionary(forKey: key) as? [String: String]
        return all?[String(appID)]
    }

    static func setChosen(_ appID: Int, _ program: String?, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        all[String(appID)] = program
        defaults.set(all, forKey: key)
    }

    enum Outcome: Equatable {
        /// Nothing to do: no choice and nothing kept, or the copy is already in place.
        case unchanged
        /// The launcher was kept and the chosen program copied in its place.
        case swapped
        /// The same, for a Unity program: plus a link to its data folder under the
        /// launcher's name (the text names the link and where it points).
        case swappedUnity(String)
        /// The kept launcher was put back.
        case restored
        case failed(String)
    }

    /// Puts the chosen program (nil: none) in place of `launcher`, the program Steam's
    /// launch entry names; both are relative to `folder`, the game's install folder.
    static func apply(launcher: String, program: String?, folder: URL, unityData: Bool = true,
                      files: FileManager = .default) -> Outcome {
        guard safe(launcher) else { return .failed("Steam's launch entry \(launcher) is outside the game's folder") }
        let target = folder.appendingPathComponent(launcher)
        let kept = URL(fileURLWithPath: target.path + keptSuffix)
        let swapping = program.map { $0.lowercased() != launcher.lowercased() } ?? false
        do {
            guard swapping, let program else {
                // No choice (or Steam's own program): the kept launcher goes back, and a
                // data link Madeira made for a Unity copy goes with it.
                let unlinked = try removeDataLink(for: target, files: files)
                guard files.fileExists(atPath: kept.path) else { return unlinked ? .restored : .unchanged }
                if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
                try files.moveItem(at: kept, to: target)
                return .restored
            }
            guard safe(program) else { return .failed("\(program) is outside the game's folder") }
            let source = folder.appendingPathComponent(program)
            guard files.fileExists(atPath: source.path) else { return .failed("\(program) is not in the game's folder") }
            var copied = true
            if files.fileExists(atPath: target.path) {
                if files.fileExists(atPath: kept.path) {
                    // Already swapped: a copy of this program, or of an earlier choice.
                    if files.contentsEqual(atPath: target.path, andPath: source.path) {
                        copied = false
                    } else {
                        try files.removeItem(at: target)
                    }
                } else {
                    try files.moveItem(at: target, to: kept)
                }
            }
            if copied { try files.copyItem(at: source, to: target) }
            switch try linkData(of: source, for: target, enabled: unityData, files: files) {
            case .linked(let note): return .swappedUnity(note)
            case .removed: return .swapped
            case .none: return copied ? .swapped : .unchanged
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private enum DataLink { case none, removed, linked(String) }

    /// "<name>_Data" beside a program ("bin/7DaysToDie.exe" -> "bin/7DaysToDie_Data").
    static func dataFolder(of program: URL) -> URL {
        program.deletingLastPathComponent()
            .appendingPathComponent(program.deletingPathExtension().lastPathComponent + "_Data")
    }

    private static func isLink(_ url: URL, files: FileManager) -> Bool {
        (try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Takes out the data link next to `target` when Madeira made it (a link, never a folder).
    private static func removeDataLink(for target: URL, files: FileManager) throws -> Bool {
        let link = dataFolder(of: target)
        guard isLink(link, files: files) else { return false }
        try files.removeItem(at: link)
        return true
    }

    /// Makes "<launcher>_Data" a link to the chosen program's Unity data folder, or takes
    /// out a link left from an earlier choice when this program has none (or with the
    /// switch off). A real "<launcher>_Data" folder is left as it is.
    private static func linkData(of source: URL, for target: URL, enabled: Bool, files: FileManager) throws -> DataLink {
        let data = dataFolder(of: source)
        let link = dataFolder(of: target)
        var isDirectory: ObjCBool = false
        guard enabled, files.fileExists(atPath: data.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return try removeDataLink(for: target, files: files) ? .removed : .none
        }
        let destination = relativePath(from: link.deletingLastPathComponent(), to: data)
        let name = link.lastPathComponent
        if isLink(link, files: files) {
            if (try? files.destinationOfSymbolicLink(atPath: link.path)) == destination {
                return .linked("\(name) -> \(destination) kept")
            }
            try files.removeItem(at: link)
        } else if files.fileExists(atPath: link.path) {
            // The launcher has a data folder of its own (a Unity launcher): not ours to change.
            return .linked("\(name) is a real folder, left as it is")
        }
        try files.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
        return .linked("\(name) -> \(destination)")
    }

    /// `to` relative to the folder `from` ("7DaysToDie_Data", "../bin/Game_Data").
    static func relativePath(from: URL, to: URL) -> String {
        let a = from.standardizedFileURL.pathComponents
        let b = to.standardizedFileURL.pathComponents
        var shared = 0
        while shared < a.count, shared < b.count, a[shared] == b[shared] { shared += 1 }
        let ups = Array(repeating: "..", count: a.count - shared)
        return (ups + b[shared...]).joined(separator: "/")
    }

    /// A relative path that stays inside the folder.
    private static func safe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}
