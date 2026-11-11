// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Installing winget packages. Madeira runs one program per session, so an install is a library
/// entry: the verified installer, run silently by Play. What it did is read afterwards from the
/// prefix's registry (new Uninstall keys), once that entry has been played and the session is over.
@MainActor final class WingetInstalls: ObservableObject {
    static let shared = WingetInstalls()

    struct Record: Codable, Equatable {
        var id: String, name: String, version: String
        /// The program's folder (Windows path) when its Uninstall key named one.
        var location = ""
        var uninstall = ""
        var keys: [String] = []
        /// drive_c-relative folder of a portable package.
        var folder: String?
        var installedAt = Date()
    }
    struct Pending: Codable, Equatable {
        enum Kind: String, Codable { case install, uninstall }
        var kind: Kind
        var id: String, name: String, version: String
        var entry: UUID
        var before: [String]
        var folder: String?
        var started = Date()
    }
    private struct Saved: Codable { var records: [String: Record] = [:]; var pending: Pending? }

    @Published private(set) var records: [String: Record] = [:]
    @Published private(set) var pending: Pending?
    /// What happened last, per package id.
    @Published private(set) var messages: [String: String] = [:]

    private static var file: URL { LibraryModel.documents.appendingPathComponent("madeira-winget.json") }
    private nonisolated static var prefix: URL { LibraryModel.documents.appendingPathComponent("wine", isDirectory: true) }

    init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            records = saved.records; pending = saved.pending
        }
    }
    private func persist() {
        try? JSONEncoder().encode(Saved(records: records, pending: pending)).write(to: Self.file, options: .atomic)
    }

    // MARK: Install

    /// Downloads and checks the package's installer and makes the library entry that runs it.
    /// The caller saves the entry and opens its page: Play runs the install.
    func prepare(_ manifest: WingetManifest) async throws -> LibraryEntry {
        let (installer, step) = try WingetPlan.choose(manifest.installers).get()
        guard let url = URL(string: installer.url), url.scheme == "https" else { throw WingetError.network("not https") }
        guard installer.sha256.count == 64 else { throw WingetError.mismatch("installer (no hash)") }
        let folder = Self.downloads.appendingPathComponent(WingetPlan.folderName(manifest.id), isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(WingetPlan.fileName(for: installer))
        LogStore.shared.log("[winget] download \(manifest.id) \(manifest.version) \(installer.type) \(installer.architecture)")
        let (temporary, response) = try await URLSession.shared.download(from: url)
        defer { try? fm.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WingetError.network("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        guard await Task.detached(priority: .utility, operation: { WingetPlan.sha256Hex(ofFile: temporary) }).value == installer.sha256 else {
            LogStore.shared.log("[winget] installer hash mismatch for \(manifest.id)", level: .error)
            throw WingetError.mismatch("installer")
        }
        try fm.moveItem(at: temporary, to: file)

        var entry = try await entry(for: step, file: file, folder: folder, manifest: manifest)
        entry.title = step == .portable ? manifest.name : String(format: L("Install %@"), manifest.name)
        if case .portable = step {
            // A portable package is its program: nothing to run first.
            records[manifest.id] = Record(id: manifest.id, name: manifest.name, version: manifest.version,
                                          folder: LibraryModel.relativeToDrive(file.deletingLastPathComponent()))
            messages[manifest.id] = nil; persist()
            return entry
        }
        pending = Pending(kind: .install, id: manifest.id, name: manifest.name, version: manifest.version,
                          entry: entry.id, before: Array(Self.uninstallKeys().keys))
        messages[manifest.id] = L("Play the installer's page to install it.")
        persist()
        return entry
    }

    private func entry(for step: WingetStep, file: URL, folder: URL, manifest: WingetManifest) async throws -> LibraryEntry {
        switch step {
        case .installer(let arguments):
            var e = try LibraryModel.inspect(file); e.arguments = arguments; return e
        case .msi(let arguments):
            guard let rel = LibraryModel.relativeToDrive(file) else { throw WingetError.unsupported("path") }
            var e = LibraryEntry(title: manifest.name, relativePath: "windows/system32/msiexec.exe", bits: 64)
            e.arguments = "/i \"C:\\" + rel.replacingOccurrences(of: "/", with: "\\") + "\" " + arguments
            return e
        case .portable:
            return try LibraryModel.inspect(file)
        case .archive(let nested, let inner):
            let target = folder.appendingPathComponent("package", isDirectory: true)
            guard try await Task.detached(priority: .userInitiated, operation: { try ItchArchive.unpackAny(file, to: target) }).value != nil else {
                throw WingetError.unsupported("archive")
            }
            // The manifest's path stays inside the archive.
            guard !nested.hasPrefix("/"), !nested.contains("..") else { throw WingetError.unsupported("path") }
            let inside = target.appendingPathComponent(nested.replacingOccurrences(of: "\\", with: "/"))
            guard FileManager.default.fileExists(atPath: inside.path) else { throw WingetError.unsupported("nested file") }
            return try await entry(for: inner, file: inside, folder: folder, manifest: manifest)
        }
    }

    // MARK: Uninstall

    /// The library entry that runs the package's own uninstaller.
    func prepareUninstall(_ id: String) throws -> LibraryEntry {
        guard let record = records[id] else { throw WingetError.unsupported("not installed") }
        guard let (program, arguments) = WingetRegistry.splitCommand(record.uninstall) else { throw WingetError.unsupported("no uninstaller") }
        var entry: LibraryEntry
        if program.lowercased().hasSuffix("msiexec.exe") || program.lowercased() == "msiexec" {
            entry = LibraryEntry(title: record.name, relativePath: "windows/system32/msiexec.exe", bits: 64)
        } else if let rel = WingetRegistry.driveCRelative(program) {
            entry = try LibraryModel.inspect(LibraryModel.drive.appendingPathComponent(rel))
        } else { throw WingetError.unsupported("uninstaller path") }
        entry.arguments = arguments
        entry.title = String(format: L("Uninstall %@"), record.name)
        pending = Pending(kind: .uninstall, id: id, name: record.name, version: record.version, entry: entry.id,
                          before: Array(Self.uninstallKeys().keys))
        persist()
        return entry
    }

    // MARK: After the session

    /// Once the install (or uninstall) entry has been played and no session runs: what changed in the registry.
    func reconcile() {
        guard let p = pending, LibraryModel.shared.current == nil else { return }
        guard let entry = LibraryModel.shared.entries.first(where: { $0.id == p.entry }) else {
            pending = nil; persist(); return
        }
        guard let played = entry.lastPlayed, played >= p.started else {
            if Date().timeIntervalSince(p.started) > 7 * 86400 { pending = nil; persist() }
            return
        }
        let now = Self.uninstallKeys()
        switch p.kind {
        case .install:
            let added = WingetRegistry.added(before: Set(p.before), after: now, name: p.name)
            if let top = added.first {
                records[p.id] = Record(id: p.id, name: p.name, version: top.version.isEmpty ? p.version : top.version,
                                       location: top.location, uninstall: top.uninstall, keys: added.map(\.key))
                messages[p.id] = nil
                LogStore.shared.log("[winget] installed \(p.id) keys=\(added.count)")
            } else {
                messages[p.id] = L("Madeira did not see anything new installed. The installer may have failed: try again.")
                LogStore.shared.log("[winget] nothing new after the installer for \(p.id)", level: .error)
            }
        case .uninstall:
            if let record = records[p.id], record.keys.allSatisfy({ now[$0] == nil }) {
                records[p.id] = nil; messages[p.id] = nil
                LogStore.shared.log("[winget] uninstalled \(p.id)")
            } else { messages[p.id] = L("The program is still listed as installed.") }
        }
        // The installer's library entry has done its job.
        LibraryModel.shared.remove(p.entry)
        pending = nil; persist()
    }

    /// drive_c-relative programs a finished install left in its folder, best first.
    func programs(for id: String) -> [URL] {
        guard let r = records[id] else { return [] }
        let rel = r.folder ?? WingetRegistry.driveCRelative(r.location)
        guard let rel else { return [] }
        let folder = LibraryModel.drive.appendingPathComponent(rel)
        return GameCandidate.ranked(GameCandidate.programs(in: folder), in: folder)
    }

    // MARK: Files

    private static var downloads: URL { LibraryModel.drive.appendingPathComponent("users/Public/Downloads/winget", isDirectory: true) }

    /// The Uninstall keys of the prefix's registry (system.reg: machine, user.reg: user).
    nonisolated static func uninstallKeys() -> [String: WingetUninstallEntry] {
        var all: [String: WingetUninstallEntry] = [:]
        for (file, hive) in [("system.reg", "M"), ("user.reg", "U")] {
            guard let text = try? String(contentsOf: prefix.appendingPathComponent(file), encoding: .utf8) else { continue }
            for (key, value) in WingetRegistry.uninstallEntries(text) {
                var v = value; v.key = hive + key; all[hive + key] = v
            }
        }
        return all
    }
}
