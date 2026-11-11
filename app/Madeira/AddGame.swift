// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UniformTypeIdentifiers

/// Copies or unpacks something the user picked in Files into drive_c/Games/<name>.
enum GameImporter {
    /// A folder is copied, a .zip or .7z unpacked, a lone .exe copied into a folder of its own.
    /// Returns the new folder. Runs on the caller's thread: call it off the main one.
    static func importItem(_ source: URL) throws -> URL {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let games = LibraryModel.drive.appendingPathComponent("Games", isDirectory: true)
        try fm.createDirectory(at: games, withIntermediateDirectories: true)
        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        var dest = games.appendingPathComponent(GameCandidate.slug(isFolder ? source.lastPathComponent
                                                                            : source.deletingPathExtension().lastPathComponent), isDirectory: true)
        var n = 2
        let base = dest
        while fm.fileExists(atPath: dest.path) { dest = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + " \(n)", isDirectory: true); n += 1 }
        if isFolder { try fm.copyItem(at: source, to: dest); return dest }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            if source.pathExtension.lowercased() == "exe" { try fm.copyItem(at: source, to: dest.appendingPathComponent(source.lastPathComponent)) }
            else if try ItchArchive.unpackAny(source, to: dest) == nil { throw LibraryError.message(L("Choose a folder, a .zip or .7z, or an .exe.")) }
        } catch { try? fm.removeItem(at: dest); throw error }
        return dest
    }
}

/// What a program says about itself, used when it is added: its product name as the title and its
/// icon, on a poster, as the first cover (a Steam match or a picked image replaces it).
enum GameMetadata {
    static func apply(_ entry: LibraryEntry) async -> LibraryEntry {
        guard let program = try? ExternalDrives.nativeURL(entry.relativePath) else { return entry }
        var e = entry
        let found = await Task.detached(priority: .utility) { () -> (String?, Data?) in
            let r = PEResources(url: program)
            return (r?.productName, r?.icon)
        }.value
        if let name = found.0, !generic(name) { e.title = name }
        if e.coverFile == nil, let ico = found.1, let jpeg = poster(ico) {
            let dir = LibraryModel.documents.appendingPathComponent("madeira-art", isDirectory: true)
            let file = e.id.uuidString + ".jpg"
            if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
               (try? jpeg.write(to: dir.appendingPathComponent(file), options: .atomic)) != nil { e.coverFile = file }
        }
        return e
    }

    /// A product name that says nothing about the game (Windows' own, an engine's, an installer's).
    static func generic(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.count < 2 || ["microsoft", "windows", "wine", "unity", "unreal", "setup", "install"].contains { n.hasPrefix($0) }
    }

    /// The icon centred on a 2:3 poster: a square icon would be cropped by a cover's shape.
    private static func poster(_ ico: Data) -> Data? {
        guard let icon = UIImage(data: ico) else { return nil }
        let size = CGSize(width: 600, height: 900)
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.9) { ctx in
            let colors = [UIColor(white: 0.20, alpha: 1).cgColor, UIColor(white: 0.11, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            let side: CGFloat = 340
            let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2 - 30, width: side, height: side)
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            icon.draw(in: rect)
        }
    }
}

extension LibraryModel {
    /// The library entry that already runs this program, if any.
    func entry(running url: URL) -> LibraryEntry? {
        guard let relative = Self.relativeToDrive(url) else { return nil }
        return entries.first { $0.relativePath.caseInsensitiveCompare(relative) == .orderedSame }
    }
}

/// The Add a game sheet: import from Files, games already on this device, or pick a program.
struct AddGameSheet: View {
    var select: (LibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var working = false
    @State private var error: String?
    @State private var imported: URL?

    private static let types: [UTType] = [.folder, .zip, UTType(filenameExtension: "7z"), UTType(filenameExtension: "exe")].compactMap { $0 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { picking = true } label: { Label("Import from Files", systemImage: "square.and.arrow.down") }
                        .disabled(working)
                    NavigationLink { FoundGamesView(select: select) } label: { Label("Found on this device", systemImage: "magnifyingglass") }
                    NavigationLink { ExecutableBrowser(folder: LibraryModel.drive, select: select) } label: { Label("Choose an executable", systemImage: "app.dashed") }
                } footer: {
                    Text("Import a game's folder, a .zip or .7z, or an .exe. Madeira copies it into drive_c › Games.")
                }
                if working { HStack { ProgressView(); Text("Importing") } }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Add a game")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(item: $imported) { folder in GameCandidateView(folder: folder, select: select) }
            .fileImporter(isPresented: $picking, allowedContentTypes: Self.types) { result in
                switch result {
                case .failure(let failure): error = failure.localizedDescription
                case .success(let url):
                    error = nil; working = true
                    Task {
                        do { imported = try await Task.detached(priority: .userInitiated) { try GameImporter.importItem(url) }.value }
                        catch { self.error = error.localizedDescription }
                        working = false
                    }
                }
            }
        }
    }
}

/// The programs in one folder, best guess first.
struct GameCandidateView: View {
    let folder: URL
    var select: (LibraryEntry) -> Void
    @ObservedObject private var library = LibraryModel.shared
    @State private var programs: [URL]?
    @State private var error: String?
    /// A setup-looking program picked: run it as an installer, or add it as a game anyway.
    @State private var installer: URL?

    var body: some View {
        List {
            if let programs {
                if programs.isEmpty { Text("No programs found in this folder.").foregroundStyle(.secondary) }
                ForEach(Array(programs.enumerated()), id: \.element) { index, url in
                    Button { add(url) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(url.lastPathComponent)
                                Spacer()
                                if library.entry(running: url) != nil { Text("Added").foregroundStyle(.secondary) }
                                else if GameCandidate.isInstaller(url.lastPathComponent) { Text("Installer").foregroundStyle(.orange) }
                                else if index == 0 { Text("Best match").foregroundStyle(.secondary) }
                            }
                            Text(String(url.path.dropFirst(folder.path.count + 1))).font(.caption).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            } else { HStack { ProgressView(); Text("Looking for programs") } }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(GameCandidate.title(folder.lastPathComponent))
        .confirmationDialog(L("This looks like an installer"), isPresented: Binding(get: { installer != nil }, set: { if !$0 { installer = nil } }),
                            titleVisibility: .visible, presenting: installer) { url in
            Button(L("Run installer")) { runInstaller(url) }
            Button(L("Add as a game")) { addGame(url) }
            Button(L("Cancel"), role: .cancel) {}
        } message: { _ in Text("Run it to install the game. Madeira then looks for what it added.") }
        .task {
            let folder = folder
            programs = await Task.detached(priority: .userInitiated) { GameCandidate.ranked(GameCandidate.programs(in: folder), in: folder) }.value
        }
    }

    private func add(_ url: URL) {
        if let existing = library.entry(running: url) { select(existing); return }
        if GameCandidate.isInstaller(url.lastPathComponent) { installer = url; return }
        addGame(url)
    }

    private func addGame(_ url: URL) {
        do {
            var entry = try LibraryModel.inspect(url)
            entry.title = GameCandidate.title(folder.lastPathComponent)
            select(entry)
        } catch { self.error = error.localizedDescription }
    }

    /// The setup program as a library entry, watched: when it has been played, the game it added is found.
    private func runInstaller(_ url: URL) {
        do {
            var entry = try LibraryModel.inspect(url)
            entry.title = String(format: L("Install %@"), GameCandidate.title(folder.lastPathComponent))
            Task { await InstallerWatch.begin(entry.id); select(entry) }
        } catch { self.error = error.localizedDescription }
    }
}

/// Games found under drive_c and on connected drives: the best program of each folder.
struct FoundGamesView: View {
    var select: (LibraryEntry) -> Void
    @ObservedObject private var library = LibraryModel.shared
    @State private var found: [URL]?

    /// The program's own name is often generic: a game in its own folder takes the folder's.
    private func open(_ url: URL) {
        if let existing = library.entry(running: url) { select(existing); return }
        guard var entry = try? LibraryModel.inspect(url) else { return }
        let parent = url.deletingLastPathComponent()
        if parent.path != LibraryModel.drive.path { entry.title = GameCandidate.title(parent.lastPathComponent) }
        select(entry)
    }

    var body: some View {
        List {
            if let found {
                if found.isEmpty { Text("No games found. Import one, or copy it into Madeira › wine › drive_c with Files.").foregroundStyle(.secondary) }
                ForEach(found, id: \.self) { url in
                    let added = library.entry(running: url) != nil
                    Button { open(url) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(GameCandidate.title(url.deletingLastPathComponent().lastPathComponent))
                                Text(LibraryModel.relativeToDrive(url) ?? url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if added { Text("Added").foregroundStyle(.secondary) }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            } else { HStack { ProgressView(); Text("Looking for games") } }
        }
        .navigationTitle("Found on this device")
        .task {
            let roots = [LibraryModel.drive] + ExternalDrives.shared.roots.map { URL(fileURLWithPath: $0.path) }
            found = await Task.detached(priority: .userInitiated) {
                var best: [URL] = []
                for root in roots {
                    let byFolder = Dictionary(grouping: ExternalGameScan.scan(root)) { $0.deletingLastPathComponent() }
                    for (folder, exes) in byFolder.sorted(by: { $0.key.path < $1.key.path }) {
                        if let top = GameCandidate.ranked(exes, in: folder).first { best.append(top) }
                    }
                }
                return best
            }.value
        }
    }
}
