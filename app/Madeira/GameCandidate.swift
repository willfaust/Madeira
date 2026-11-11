// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// What a folder of Windows files offers as a game: its programs ranked by how likely each is the
/// game's own executable, a title, and whether the best one looks like an installer. Foundation
/// only, so the host checks compile it (tests/host/check-game-candidate.py). Used by the Add a game
/// sheet and the external-drive scan, which share one skip list.
enum GameCandidate {
    /// Programs that are never the game: installers, redistributables, helpers, anti-cheat.
    static let skipNames = ["unins", "setup", "install", "redist", "vcredist", "vc_redist", "dxsetup", "directx",
                            "dotnet", "crash", "report", "update", "patch", "launcherhelper", "helper", "cef",
                            "touchup", "easyanticheat", "battleye", "ue4prereq", "prereq", "config", "settings"]
    /// Folders a scan does not enter.
    static let skipFolders: Set<String> = ["steamapps", "_commonredist", "commonredist", "redist",
                                           "redistributables", "directx", "dotnet", "vcredist", "__installer", "windows", "system32",
                                           "$recycle.bin", "system volume information", "engine", "node_modules"]
    /// What looks like an installer (a subset of `skipNames`): offered as an installer, not a game.
    private static let installerNames = ["setup", "install", "unins"]

    static func isSkipped(_ name: String) -> Bool {
        let name = name.lowercased()
        return skipNames.contains { name.hasPrefix($0) || name.contains("_" + $0) || name.contains("-" + $0) }
    }

    static func isInstaller(_ name: String) -> Bool {
        let name = name.lowercased()
        return installerNames.contains { name.hasPrefix($0) || name.contains("_" + $0) || name.contains("-" + $0) }
    }

    /// A folder's or file's name as a title: underscores to spaces, no extension.
    static func title(_ name: String) -> String {
        (name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
    }

    /// A name safe for one folder under drive_c/Games.
    static func slug(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let clean = name.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return clean.isEmpty ? "Game" : String(clean.prefix(80))
    }

    /// The .exe files under `folder`, at most `depth` folders down, skipping `skipFolders`.
    static func programs(in folder: URL, depth: Int = 3) -> [URL] {
        var found: [URL] = []
        func walk(_ dir: URL, _ left: Int) {
            guard found.count < 200, let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else { return }
            for item in items {
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if left > 0, !skipFolders.contains(item.lastPathComponent.lowercased()) { walk(item, left - 1) }
                } else if item.pathExtension.lowercased() == "exe" { found.append(item) }
            }
        }
        walk(folder, depth)
        return found
    }

    /// `programs`, best first: not skipped, name close to the folder's, big, shallow.
    static func ranked(_ programs: [URL], in folder: URL) -> [URL] {
        let folderName = normalise(folder.lastPathComponent)
        func score(_ url: URL) -> Double {
            var s = 0.0
            let name = normalise(url.deletingPathExtension().lastPathComponent)
            if isSkipped(url.lastPathComponent) { s -= 100 }
            if !folderName.isEmpty, !name.isEmpty {
                if name == folderName { s += 50 } else if name.contains(folderName) || folderName.contains(name) { s += 25 }
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            s += min(Double(size) / 1_000_000, 40)
            s -= Double(max(0, url.pathComponents.count - folder.pathComponents.count - 1)) * 5
            return s
        }
        return programs.map { ($0, score($0)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path < $1.0.path }
            .map(\.0)
    }

    private static func normalise(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
