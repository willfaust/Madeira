// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// A setup program run from Add a game: it is a library entry like any program, and once it has been
/// played and no session runs, what it added to drive_c is compared with what was there before. One new
/// game becomes a library entry of its own and the installer's entry goes; none or several stay for
/// Add a game › Found on this device.
@MainActor enum InstallerWatch {
    private struct Pending: Codable { var entry: UUID; var before: [String]; var started: Date }
    private static let key = "madeira.installerWatch"
    private static var pending: Pending? {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: key) }
    }

    /// The best program of every game folder now on drive_c and the connected drives.
    private nonisolated static func games() -> [URL] {
        var best: [URL] = []
        for root in [LibraryModel.drive] + ExternalDrives.shared.roots.map({ URL(fileURLWithPath: $0.path) }) {
            let byFolder = Dictionary(grouping: ExternalGameScan.scan(root)) { $0.deletingLastPathComponent() }
            for (folder, exes) in byFolder { if let top = GameCandidate.ranked(exes, in: folder).first { best.append(top) } }
        }
        return best
    }

    /// Notes what is on the drive before `entry` (an installer) is played.
    static func begin(_ entry: UUID) async {
        let before = await Task.detached(priority: .utility) { games().map(\.path) }.value
        pending = Pending(entry: entry, before: before, started: Date())
    }

    static func reconcile() {
        guard let p = pending, LibraryModel.shared.current == nil else { return }
        let library = LibraryModel.shared
        guard let installer = library.entries.first(where: { $0.id == p.entry }) else { pending = nil; return }
        guard let played = installer.lastPlayed, played >= p.started else {
            if Date().timeIntervalSince(p.started) > 7 * 86400 { pending = nil }
            return
        }
        pending = nil
        Task {
            let before = Set(p.before)
            let added = await Task.detached(priority: .utility) { games().filter { !before.contains($0.path) } }.value
            LogStore.shared.log("[installer] \(added.count) new game folder(s) after \(installer.title)")
            guard added.count == 1, var entry = try? LibraryModel.inspect(added[0]) else { return }
            entry.title = GameCandidate.title(added[0].deletingLastPathComponent().lastPathComponent)
            entry = await GameMetadata.apply(entry)
            library.save(entry)
            library.remove(p.entry)
            library.showDetail = entry.id
        }
    }
}
