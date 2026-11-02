import SwiftUI
import UniformTypeIdentifiers
import BackgroundTasks

/// Folders the user picked outside the app, usually on a USB or SSD drive.
///
/// iOS only lets the app reach them through the folder picker. The picked URL
/// is kept as a bookmark in Documents/madeira-external.json, and on every launch
/// (before the wineserver starts) each one is opened again and linked into the
/// prefix twice: as drive_c/External/<name>, so the library and the executable
/// browser work unchanged, and as dosdevices/<letter>:, so Windows lists it as a
/// drive. A folder whose drive is not plugged in is left out until next time.
struct ExternalFolder: Codable, Identifiable {
    var id = UUID()
    var name: String
    var letter: String
    var bookmark: Data
    /// Madeira's Steam downloads go to <folder>/SteamLibrary on this drive.
    var steamInstalls: Bool? = nil
    var libraryID: String? = nil
}

final class ExternalDrives: ObservableObject {
    static let shared = ExternalDrives()
    @Published private(set) var folders: [ExternalFolder] = []
    /// Folders opened this launch, by id, with the path they resolved to.
    @Published private(set) var mounted: [UUID: URL] = [:]

    private static var store: URL { LibraryModel.documents.appendingPathComponent("madeira-external.json") }
    static var linkRoot: URL { MadeiraDock.drive.appendingPathComponent("External", isDirectory: true) }
    private static var dosdevices: URL { MadeiraDock.prefix.appendingPathComponent("dosdevices", isDirectory: true) }

    /// Steam libraries (drive_c-relative steamapps folders) on the drives opened
    /// this launch, and the one Steam downloads go to. Read from any thread
    /// (MadeiraDock.games runs off the main thread), so kept behind a lock.
    private static let lock = NSLock()
    private static var libraries: [String] = []
    private static var installTarget: String?
    private static var installMissing: String?
    private static var opened: [String: (root: URL, identity: String?)] = [:]
    private var loadFailure: Error?
    static var steamLibraries: [String] { lock.lock(); defer { lock.unlock() }; return libraries }
    /// The library Madeira's Steam downloads go to, or nil for drive_c's own.
    static var steamInstallLibrary: String? { lock.lock(); defer { lock.unlock() }; return installTarget }
    /// The name of the drive Steam downloads go to when it is not connected.
    static var steamInstallMissing: String? { lock.lock(); defer { lock.unlock() }; return installMissing }
    /// Where Steam libraries are looked for inside a picked folder.
    private static let libraryFolders = ["", "SteamLibrary", "Steam", "Program Files (x86)/Steam", "Program Files/Steam"]

    private init() {
        do {
            let data = try Data(contentsOf: Self.store)
            guard data.count <= 32 << 20 else { throw ExternalStorageError.invalidRecord }
            let list = try JSONDecoder().decode([ExternalFolder].self, from: data)
            try Self.validate(list)
            folders = list
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { }
        catch { loadFailure = error; LogStore.shared.log("[external] saved registrations could not be read; files kept") }
    }

    private static func validate(_ list: [ExternalFolder]) throws {
        guard list.count <= 22, Set(list.map(\.id)).count == list.count,
              list.filter({ $0.steamInstalls == true }).count <= 1,
              Set(list.map { $0.name.lowercased() }).count == list.count,
              Set(list.map(\.letter)).count == list.count else { throw ExternalStorageError.invalidRecord }
        for folder in list {
            guard try ExternalStoragePath.components(folder.name) == [folder.name],
                  folder.letter.count == 1, "defghijklmnopqrstuvwxy".contains(folder.letter),
                  !folder.bookmark.isEmpty, folder.bookmark.count <= 1 << 20,
                  folder.libraryID == nil || UUID(uuidString: folder.libraryID!) != nil else { throw ExternalStorageError.invalidRecord }
        }
    }

    private func save(_ list: [ExternalFolder]) throws {
        if let loadFailure { throw loadFailure }
        try Self.validate(list)
        try JSONEncoder().encode(list).write(to: Self.store, options: .atomic)
        folders = list
    }

    private func publishOpened() {
        let next = Dictionary(uniqueKeysWithValues: folders.compactMap { folder in
            mounted[folder.id].map { (folder.name, (root: $0, identity: folder.libraryID)) }
        })
        Self.lock.lock(); Self.opened = next; Self.lock.unlock()
    }

    static func externalRoot(for relative: String) throws -> (root: URL, identity: String?)? {
        guard let name = driveName(library: relative) else { return nil }
        lock.lock(); let folder = opened[name]; lock.unlock()
        guard let folder else { throw ExternalStorageError.unavailable }
        try validateRoot(folder.root, identity: folder.identity)
        return folder
    }

    private static func validateRoot(_ root: URL, identity: String?) throws {
        guard try root.checkResourceIsReachable(),
              try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ExternalStorageError.unavailable }
        if let identity { try ExternalStorageIdentity.verify(identity, root: root) }
    }

    static func nativeURL(_ relative: String, write: Bool = false) throws -> URL {
        _ = try ExternalStoragePath.components(relative)
        guard let external = try externalRoot(for: relative) else { return MadeiraDock.drive.appendingPathComponent(relative) }
        if write, try external.root.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly == true {
            throw CocoaError(.fileWriteVolumeReadOnly)
        }
        let parts = try ExternalStoragePath.components(relative)
        return parts.count == 2 ? external.root : try ExternalStoragePath.native(parts.dropFirst(2).joined(separator: "/"), root: external.root)
    }

    /// Opens every saved folder and refreshes the links. Safe to call again; it
    /// must run before the wineserver starts for Windows to list the drives.
    @MainActor func mountAll() {
        guard loadFailure == nil, wine_process_is_running() == 0 else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.linkRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.dosdevices, withIntermediateDirectories: true)
        var next = folders
        for i in folders.indices {
            let folder = folders[i]
            if let root = mounted[folder.id], (try? Self.validateRoot(root, identity: folder.libraryID)) != nil { continue }
            mounted.removeValue(forKey: folder.id)?.stopAccessingSecurityScopedResource()
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: folder.bookmark, bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { throw ExternalStorageError.unavailable }
                do {
                    try Self.validateRoot(url, identity: folder.libraryID)
                    try link(folder, to: url, owned: true)
                    if stale { next[i].bookmark = try url.bookmarkData() }
                    mounted[folder.id] = url
                } catch { url.stopAccessingSecurityScopedResource(); throw error }
            } catch {
                LogStore.shared.log("[external] \(folder.name) unavailable: \(error.localizedDescription)")
                unlink(folder)
            }
        }
        do { try save(next) } catch { LogStore.shared.log("[external] bookmark refresh could not be saved") }
        publishOpened()
        refreshSteam()
        SteamOwnedLibrary.shared.externalStorageReconnected()
    }

    /// Finds the Steam libraries on the opened drives, makes the chosen download
    /// folder, and lists them all in the Steam client's libraryfolders.vdf so
    /// Valve's client (started by Madeira Dock) can start their games.
    func refreshSteam() {
        let fm = FileManager.default
        var found: [String] = [], target: String?, missing: String?
        for folder in folders {
            if folder.steamInstalls == true { target = "External/\(folder.name)/SteamLibrary/steamapps" }
            guard mounted[folder.id] != nil, Self.isConnected(folder.name) else {
                if folder.steamInstalls == true { missing = folder.name }
                continue
            }
            if folder.steamInstalls == true {
                do {
                    let common = try Self.nativeURL("External/\(folder.name)/SteamLibrary/steamapps/common", write: true)
                    try fm.createDirectory(at: common, withIntermediateDirectories: true)
                } catch { missing = folder.name }
            }
            for sub in Self.libraryFolders {
                let apps = sub.isEmpty ? "steamapps" : sub + "/steamapps"
                var isDir: ObjCBool = false
                if let appsURL = try? Self.nativeURL("External/\(folder.name)/" + apps),
                   fm.fileExists(atPath: appsURL.path, isDirectory: &isDir), isDir.boolValue {
                    found.append("External/\(folder.name)/" + apps)
                }
            }
        }
        // What each drive library holds, to tell a moved game's state from the log.
        for library in found {
            let apps = MadeiraDock.drive.appendingPathComponent(library)
            let records = ((try? fm.contentsOfDirectory(atPath: apps.path)) ?? []).filter { $0.hasPrefix("appmanifest_") }
            let folders = (try? fm.contentsOfDirectory(atPath: apps.appendingPathComponent("common").path)) ?? []
            LogStore.shared.log("[external] \(library) records=\(records.count) folders=\(folders.sorted().joined(separator: "|"))")
        }
        Self.lock.lock(); Self.libraries = found; Self.installTarget = target; Self.installMissing = missing; Self.lock.unlock()
        Self.listInSteamClient(found.map { String($0.dropLast("/steamapps".count)) })
        LogStore.shared.log("[external] steam libraries=\(found.count) install=\(target ?? "drive_c")")
    }

    /// Adds `C:\<folder>` entries for the libraries Valve's client does not list yet.
    private static func listInSteamClient(_ relative: [String]) {
        guard !relative.isEmpty else { return }
        let vdf = MadeiraDock.drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot + "/steamapps/libraryfolders.vdf")
        do {
            let existing: Data?
            do { existing = try Data(contentsOf: vdf) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { existing = nil }
            let paths = [SteamRuntimeFiles.relativeRoot] + relative
            let data = try ExternalSteamLibraries.add(paths: paths, to: existing)
            guard data != existing else { return }
            try FileManager.default.createDirectory(at: vdf.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: vdf, options: .atomic)
        } catch { LogStore.shared.log("[external] Steam library metadata was kept: \(error.localizedDescription)") }
    }

    /// "External/<name>/..." -> "<name>", or nil for drive_c.
    static func driveName(library: String) -> String? {
        let parts = library.split(separator: "/", maxSplits: 2).map(String.init)
        return parts.count >= 2 && parts[0] == "External" ? parts[1] : nil
    }
    static func isConnected(_ name: String) -> Bool {
        (try? externalRoot(for: "External/" + name)) != nil
    }
    /// Places a Steam game can be installed or moved to: this device's own
    /// library and <folder>/SteamLibrary on each connected drive.
    var steamTargets: [(name: String, library: String)] {
        [("This iPhone", SteamInstallPaths.libraryRelative)] + folders.filter { mounted[$0.id] != nil }
            .map { ($0.name, "External/\($0.name)/SteamLibrary/steamapps") }
    }
    /// Places a non-Steam game can be moved to: drive_c/Games, or <folder>/Games.
    var gameTargets: [(name: String, root: String)] {
        [("This iPhone", "Games")] + folders.filter { mounted[$0.id] != nil }.map { ($0.name, "External/\($0.name)/Games") }
    }

    /// Sends Madeira's Steam downloads to this folder (nil: back to drive_c).
    func setSteamInstalls(_ id: UUID?) {
        var next = folders
        for i in next.indices { next[i].steamInstalls = next[i].id == id ? true : nil }
        do { try save(next); refreshSteam() }
        catch { LogStore.shared.log("[external] install target was not changed: \(error.localizedDescription)") }
    }

    /// Adds a folder picked with the folder picker and links it right away.
    func add(_ url: URL) throws {
        if let loadFailure { throw loadFailure }
        guard wine_process_is_running() == 0 else { throw LibraryError.message("Close the running game before adding a drive.") }
        guard url.startAccessingSecurityScopedResource() else { throw LibraryError.message("Madeira could not open that folder.") }
        let bookmark: Data
        do { bookmark = try url.bookmarkData() } catch { url.stopAccessingSecurityScopedResource(); throw error }
        let used = Set(folders.map(\.letter))
        guard let letter = "defghijklmnopqrstuvwxy".map(String.init).first(where: {
            !used.contains($0) && (try? FileManager.default.attributesOfItem(atPath: Self.dosdevices.appendingPathComponent($0 + ":").path)) == nil
        }) else {
            url.stopAccessingSecurityScopedResource()
            throw LibraryError.message("No free drive letters.")
        }
        var name = url.lastPathComponent.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined()
        if name.isEmpty { name = "Drive" }
        let base = name; var n = 2
        while folders.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { name = "\(base) \(n)"; n += 1 }
        var folder = ExternalFolder(name: name, letter: letter, bookmark: bookmark)
        do {
            guard !mounted.values.contains(where: { $0.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) else {
                throw LibraryError.message("That folder is already registered.")
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey, .volumeIsLocalKey, .volumeIsReadOnlyKey])
            guard values.isDirectory == true, values.isUbiquitousItem != true, values.volumeIsLocal == true else {
                throw LibraryError.message("Choose a folder on a local USB or SSD drive.")
            }
            if values.volumeIsReadOnly != true { folder.libraryID = try ExternalStorageIdentity.register(root: url) }
            try Self.validate(folders + [folder])
            try link(folder, to: url, owned: false)
            do { try save(folders + [folder]) } catch { unlink(folder); throw error }
            mounted[folder.id] = url
        } catch { url.stopAccessingSecurityScopedResource(); throw error }
        publishOpened()
        refreshSteam()
        LogStore.shared.log("[external] added \(letter.uppercased()): \(name) -> \(url.path)")
    }

    /// Forgets a folder. Its files stay on the drive; the library entries that
    /// start programs on it (and its Steam games' entries) are removed.
    @MainActor func remove(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        guard wine_process_is_running() == 0, GameMover.shared.moving == nil,
              !SteamOwnedLibrary.shared.hasStorageWork else {
            LogStore.shared.log("[external] drive kept while a game, download or cloud operation uses storage")
            return
        }
        do { try save(folders.filter { $0.id != id }) }
        catch { LogStore.shared.log("[external] drive registration could not be removed"); return }
        let prefix = "External/\(folder.name)/"
        let library = LibraryModel.shared
        for entry in library.entries where entry.relativePath.hasPrefix(prefix) {
            if let appID = entry.steamAppID { library.removeSteam(appID: appID) } else { library.remove(entry.id) }
        }
        unlink(folder)
        mounted.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        publishOpened()
        refreshSteam()
        Task { @MainActor in SteamGamesModel.shared.refresh() }
        LogStore.shared.log("[external] removed \(folder.name)")
    }

    private func link(_ folder: ExternalFolder, to url: URL, owned: Bool) throws {
        let fm = FileManager.default
        for container in [Self.linkRoot, Self.dosdevices] {
            try fm.createDirectory(at: container, withIntermediateDirectories: true)
            guard try fm.attributesOfItem(atPath: container.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ExternalStorageError.mappingConflict
            }
        }
        let links = [Self.linkRoot.appendingPathComponent(folder.name), Self.dosdevices.appendingPathComponent(folder.letter + ":")]
        for path in links { try ExternalStorageMapping.validate(path, root: url, owned: owned) }
        for path in links { try ExternalStorageMapping.replace(path, root: url, owned: owned) }
    }

    private func unlink(_ folder: ExternalFolder) {
        // Only links are removed, never what they point at.
        for path in [Self.linkRoot.appendingPathComponent(folder.name).path,
                     Self.dosdevices.appendingPathComponent(folder.letter + ":").path] {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    /// The real roots of the folders opened this launch.
    var roots: [(name: String, path: String)] {
        folders.compactMap { f in mounted[f.id].map { (f.name, $0.resolvingSymlinksInPath().path) } }
    }
}

/// Games already on an external folder: the programs that look like a game's
/// own executable, a few folders deep. Steam libraries are left to Steam.
enum ExternalGameScan {
    private static let skipNames = ["unins", "setup", "install", "redist", "vcredist", "vc_redist", "dxsetup", "directx",
                                    "dotnet", "crash", "report", "update", "patch", "launcherhelper", "helper", "cef",
                                    "touchup", "easyanticheat", "battleye", "ue4prereq", "prereq", "config", "settings"]
    private static let skipFolders: Set<String> = ["steamapps", "_commonredist", "commonredist", "redist",
                                                   "redistributables", "directx", "dotnet", "vcredist", "__installer", "windows", "system32",
                                                   "$recycle.bin", "system volume information", "engine", "node_modules"]

    /// Every subfolder is searched, within a budget of folders and time so a
    /// huge drive still returns.
    static func scan(_ root: URL) -> [URL] {
        var found: [URL] = [], budget = Budget()
        walk(root, depth: 40, into: &found, budget: &budget)
        return found
    }

    private struct Budget { var folders = 0; let deadline = Date().addingTimeInterval(20) }

    private static func walk(_ folder: URL, depth: Int, into found: inout [URL], budget: inout Budget) {
        budget.folders += 1
        guard found.count < 1000, budget.folders < 50_000, Date() < budget.deadline, let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else { return }
        for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = item.lastPathComponent.lowercased()
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if depth > 0, !skipFolders.contains(name), !item.isSymlink { walk(item, depth: depth - 1, into: &found, budget: &budget) }
            } else if item.pathExtension.lowercased() == "exe", !skipNames.contains(where: { name.hasPrefix($0) || name.contains("_" + $0) || name.contains("-" + $0) }) {
                found.append(item)
            }
        }
    }
}

private extension URL {
    var isSymlink: Bool { (try? resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
}

/// Lists the games found on one external folder and adds the chosen ones.
struct ExternalGamesSheet: View {
    let folder: ExternalFolder
    let root: URL
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = LibraryModel.shared
    @State private var found: [URL]?
    @State private var chosen: Set<URL> = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let found {
                    if found.isEmpty { Text("No games found. Steam games on this drive show up in the Steam section.").foregroundStyle(.secondary) }
                    ForEach(found, id: \.self) { url in
                        let added = isAdded(url)
                        Button { if chosen.contains(url) { chosen.remove(url) } else { chosen.insert(url) } } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                    Text(String(url.path.dropFirst(root.path.count + 1))).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if added { Text("Added").foregroundStyle(.secondary) }
                                else if chosen.contains(url) { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(added)
                    }
                } else {
                    HStack { ProgressView(); Text("Looking for games") }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(folder.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add \(chosen.count)") { add() }.disabled(chosen.isEmpty) }
            }
        }
        .task {
            let root = root
            found = await Task.detached(priority: .userInitiated) { ExternalGameScan.scan(root) }.value
        }
    }

    private func isAdded(_ url: URL) -> Bool {
        guard let relative = LibraryModel.relativeToDrive(url) else { return false }
        return library.entries.contains { $0.relativePath.caseInsensitiveCompare(relative) == .orderedSame }
    }

    private func add() {
        var failed: [String] = []
        for url in chosen.sorted(by: { $0.path < $1.path }) {
            do {
                var entry = try LibraryModel.inspect(url)
                // A program's own name is often generic: use its folder's.
                let parent = url.deletingLastPathComponent()
                if parent.path != root.path { entry.title = parent.lastPathComponent }
                library.save(entry)
            } catch { failed.append(url.lastPathComponent + ": " + error.localizedDescription) }
        }
        LogStore.shared.log("[external] added games=\(chosen.count - failed.count) from \(folder.name)")
        if failed.isEmpty { dismiss() } else { error = failed.joined(separator: "\n"); chosen = [] }
    }
}

/// Settings › External drives.
struct ExternalDrivesSection: View {
    @ObservedObject private var drives = ExternalDrives.shared
    @State private var picking = false
    @State private var error: String?
    @State private var scanning: ExternalFolder?
    @State private var removing: ExternalFolder?

    var body: some View {
        Section {
            ForEach(drives.folders) { folder in
                HStack {
                    Text(folder.letter.uppercased() + ":").font(.body.monospaced())
                    Text(folder.name)
                    Spacer()
                    Text(drives.mounted[folder.id] == nil ? "Not connected" : "Connected").foregroundStyle(.secondary)
                }
                .swipeActions { Button("Remove", role: .destructive) { removing = folder } }
                if drives.mounted[folder.id] != nil {
                    Button("Find games on \(folder.name)") { scanning = folder }
                }
            }
            Button("Add drive or folder") { picking = true }
            if !drives.folders.isEmpty {
                Picker("Install Steam games on", selection: Binding(
                    get: { drives.folders.first { $0.steamInstalls == true }?.id },
                    set: { drives.setSteamInstalls($0) })) {
                    Text("This iPhone").tag(UUID?.none)
                    ForEach(drives.folders) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        } header: { Text("External drives") } footer: {
            Text("Pick a folder on a USB or SSD drive, or a whole drive that already has games on it. Windows sees it as a drive letter and as C:\\External\\<name>. Find games adds the games on it to the library; Steam libraries on it (steamapps or SteamLibrary) show up in the Steam section. Install Steam games on picks where new Steam downloads go by default (each install can still pick another place); on a drive they go into <name>\\SteamLibrary. Unplugging the drive while a game runs will close it. Restart Madeira after adding a folder for Windows to list the new drive.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            do {
                try drives.add(try result.get()); error = nil
                SteamGamesModel.shared.refresh()
                // Offer the games already on it.
                scanning = drives.folders.last
            } catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { folder in
            Button("Remove", role: .destructive) { drives.remove(folder.id) }
        } message: { _ in
            Text("Madeira forgets this drive and removes its games from the library. The files on the drive are kept.")
        }
        .sheet(item: $scanning) { folder in
            if let root = drives.mounted[folder.id] { ExternalGamesSheet(folder: folder, root: root.resolvingSymlinksInPath()) }
        }
    }
}

/// Moves an installed game between this device and external drives: copies
/// it, checks the copy, then deletes the original. A failed or cancelled move
/// removes the partial copy and leaves the original as it was.
@MainActor final class GameMover: ObservableObject {
    static let shared = GameMover()
    /// The entry being moved, and how far along (0...1).
    @Published private(set) var moving: UUID?
    @Published private(set) var progress = 0.0

    struct Failure: LocalizedError { let errorDescription: String? }

    /// What a non-Steam entry's move takes along: the program's folder, or the
    /// folder above it when the program sits in a bin/Win64-style subfolder.
    static func gameFolder(_ relativePath: String) -> String {
        var parts = relativePath.split(separator: "/").map(String.init).dropLast()
        let inner: Set<String> = ["bin", "bin32", "bin64", "binaries", "win32", "win64", "x86", "x64", "x86_64", "system", "game", "release", "shipping"]
        while parts.count > 1, inner.contains(parts.last!.lowercased()) { parts = parts.dropLast() }
        // Never a top-level container such as "Games" or "External/<name>" itself.
        return parts.joined(separator: "/")
    }

    /// Where a library entry is now (a drive name, or "This iPhone").
    static func place(_ relativePath: String) -> String {
        ExternalDrives.driveName(library: relativePath) ?? "This iPhone"
    }

    func move(_ entry: LibraryEntry, toSteamLibrary target: String? = nil, toRoot root: String? = nil) async throws -> LibraryEntry {
        guard moving == nil else { throw Failure(errorDescription: "Another game is being moved.") }
        guard wine_process_is_running() == 0 else { throw Failure(errorDescription: "Close the running game first.") }
        guard !SteamOwnedLibrary.shared.hasStorageWork else { throw Failure(errorDescription: "Wait for downloads and cloud operations to finish.") }
        var entry = entry
        var items: [(from: URL, to: URL)] = []
        var newPath: String
        if let appID = entry.steamAppID {
            guard SteamOwnedLibrary.shared.downloads[appID] == nil else { throw Failure(errorDescription: "Wait for the download to finish or cancel it first.") }
            guard let target, let game = SteamGamesModel.shared.games.first(where: { $0.id == appID }) else {
                throw Failure(errorDescription: "Steam does not list this game as installed.")
            }
            guard game.library.caseInsensitiveCompare(target) != .orderedSame else { return entry }
            guard SteamInstallPaths.isManaged(library: target) else { throw ExternalStorageError.invalidRecord }
            let fromGame = try ExternalDrives.nativeURL(game.library + "/common/" + game.installDir, write: true)
            let toGame = try ExternalDrives.nativeURL(target + "/common/" + game.installDir, write: true)
            items.append((fromGame, toGame))
            let manifest = "/appmanifest_\(appID).acf"
            items.append((try ExternalDrives.nativeURL(game.library + manifest, write: true),
                          try ExternalDrives.nativeURL(target + manifest, write: true)))
            let journal = "downloading/\(appID)"
            let fromJournal = try ExternalDrives.nativeURL(game.library + "/" + journal, write: true)
            if FileManager.default.fileExists(atPath: fromJournal.path) {
                items.append((fromJournal, try ExternalDrives.nativeURL(target + "/" + journal, write: true)))
            }
            newPath = target + "/common/" + game.installDir
        } else {
            guard let root else { throw Failure(errorDescription: "Choose where to move the game.") }
            let folder = Self.gameFolder(entry.relativePath)
            let name = (folder as NSString).lastPathComponent
            guard !folder.isEmpty, !["games", "external"].contains(folder.lowercased()), folder.split(separator: "/").count >= (folder.hasPrefix("External/") ? 3 : 1)
            else { throw Failure(errorDescription: "This game's folder cannot be moved.") }
            let dest = root + "/" + name
            guard dest.caseInsensitiveCompare(folder) != .orderedSame else { return entry }
            items.append((try ExternalDrives.nativeURL(folder, write: true), try ExternalDrives.nativeURL(dest, write: true)))
            newPath = dest + entry.relativePath.dropFirst(folder.count)
        }
        if let name = ExternalDrives.driveName(library: newPath), !ExternalDrives.isConnected(name) {
            throw Failure(errorDescription: "\(name) is not connected.")
        }
        let copy = items.map { (from: $0.from.resolvingSymlinksInPath(), to: $0.to) }

        moving = entry.id; progress = 0
        MoveBackground.shared.started(entry.title)
        defer { moving = nil; MoveBackground.shared.ended() }
        LogStore.shared.log("[move] \(entry.title): \(entry.relativePath) -> \(newPath)")
        try await Task.detached(priority: .userInitiated) {
            try Self.copyVerifyDelete(copy) { fraction in
                Task { @MainActor in GameMover.shared.progress = fraction; MoveBackground.shared.progress(fraction) }
            }
        }.value
        entry.relativePath = newPath
        LibraryModel.shared.save(entry)
        if let appID = entry.steamAppID, let target {
            SteamOwnedLibrary.shared.installMoved(appID, to: target)
            if newPath.hasPrefix("External/") { ExternalDrives.shared.refreshSteam() }
            SteamGamesModel.shared.refresh()
        }
        LogStore.shared.log("[move] done \(entry.title)")
        return entry
    }

    /// Copies one file in 8 MB pieces, reporting each piece, so a large file
    /// moves the progress bar too.
    nonisolated private static func copyFile(_ from: URL, to: URL, copied: (Int64) -> Void) throws {
        guard FileManager.default.createFile(atPath: to.path, contents: nil) else {
            throw Failure(errorDescription: "Could not write \(to.lastPathComponent).")
        }
        let input = try FileHandle(forReadingFrom: from), output = try FileHandle(forWritingTo: to)
        defer { try? input.close(); try? output.close() }
        while true {
            let chunk = try autoreleasepool { try input.read(upToCount: 8 << 20) } ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            copied(Int64(chunk.count))
        }
        try output.synchronize()
    }

    nonisolated private static func copyVerifyDelete(_ items: [(from: URL, to: URL)], progress: @escaping (Double) -> Void) throws {
        let fm = FileManager.default
        func files(_ url: URL) -> [(URL, Int64)] {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
            if !isDir.boolValue { return [(url, Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))] }
            // Any folder that cannot be read fails the move: a skipped folder
            // would be missing from the copy and then deleted with the original.
            var out: [(URL, Int64)] = [], unreadable: URL?
            let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) { failed, _ in
                unreadable = failed; return false
            }
            while let item = walker?.nextObject() as? URL {
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                if values?.isRegularFile == true { out.append((item, Int64(values?.fileSize ?? 0))) }
                else if values?.isDirectory != true { unreadable = item; break }
            }
            if let unreadable { failure = "Could not read \(unreadable.lastPathComponent)." }
            return out
        }
        var failure: String?
        let sources = items.map { files($0.from) }
        if let failure { throw Failure(errorDescription: failure) }
        let total = sources.flatMap { $0 }.reduce(Int64(0)) { $0 + $1.1 }
        guard !sources.isEmpty, !(sources.first?.isEmpty ?? true) else { throw Failure(errorDescription: "The game's files were not found.") }
        for item in items where fm.fileExists(atPath: item.to.path) {
            throw Failure(errorDescription: "\(item.to.lastPathComponent) already exists there.")
        }
        if let parent = items.first?.to.deletingLastPathComponent() {
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            // FAT32 holds no file of 4 GB or more.
            let largest = sources.flatMap { $0 }.map(\.1).max() ?? 0
            if let type = parent.fileSystemType?.lowercased(), ["msdos", "fat", "fat32", "vfat"].contains(type), largest >= 1 << 32 {
                throw Failure(errorDescription: "This drive is formatted FAT32, which cannot hold this game's files over 4 GB. Use an exFAT or APFS drive.")
            }
            if let free = parent.freeSpace, free < total + 256 << 20 {
                throw Failure(errorDescription: "Not enough free space: \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) needed.")
            }
        }
        var done: Int64 = 0, lastReport = Date.distantPast
        do {
            for (index, item) in items.enumerated() {
                let base = item.from.path
                for (file, size) in sources[index] {
                    let relative = file.path == base ? "" : String(file.path.dropFirst(base.count + 1))
                    let dest = relative.isEmpty ? item.to : item.to.appendingPathComponent(relative)
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try copyFile(file, to: dest) { bytes in
                        done += bytes
                        if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); progress(total > 0 ? Double(done) / Double(total) : 1) }
                    }
                    let copied = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
                    guard copied == size else { throw Failure(errorDescription: "The copy of \(file.lastPathComponent) does not match.") }
                }
            }
            // Check the whole copy before anything is deleted.
            for (index, item) in items.enumerated() {
                func listing(_ list: [(URL, Int64)], base: URL) -> [String: Int64] {
                    Dictionary(list.map { (String($0.0.path.dropFirst(base.path.count)), $0.1) }, uniquingKeysWith: { a, _ in a })
                }
                let copied = listing(files(item.to), base: item.to)
                // The original is listed again, in case it changed or was only partly read.
                let original = listing(files(item.from), base: item.from)
                guard failure == nil, copied == original, original == listing(sources[index], base: item.from) else {
                    throw Failure(errorDescription: "The copy is incomplete (\(copied.count) of \(original.count) files).")
                }
            }
        } catch {
            for item in items { try? fm.removeItem(at: item.to) }
            throw error
        }
        progress(1)
        LogStore.shared.log("[move] copied and checked files=\(sources.reduce(0) { $0 + $1.count }) bytes=\(total)")
        // The copy is already checked, so the move stands; a source that cannot be
        // removed (read-only or busy files) is logged rather than left unexplained,
        // because it keeps using the old drive's space.
        for item in items {
            do { try fm.removeItem(at: item.from) }
            catch { LogStore.shared.log("[move] copied, but the original \(item.from.lastPathComponent) could not be removed: \(error.localizedDescription)") }
        }
    }
}

/// Game details › Location: where the game is and Move to.
struct GameMoveSection: View {
    @Binding var entry: LibraryEntry
    @ObservedObject private var mover = GameMover.shared
    @ObservedObject private var drives = ExternalDrives.shared
    @State private var error: String?
    /// "120 GB free of 500 GB" for each place, by its library or root.
    @State private var sizes: [String: String] = [:]

    var body: some View {
        let here = GameMover.place(entry.relativePath)
        let steam = entry.steamAppID != nil
        let targets: [(name: String, value: String)] = steam ? drives.steamTargets.map { ($0.name, $0.library) } : drives.gameTargets.map { ($0.name, $0.root) }
        Section {
            LabeledContent("Installed on", value: here)
            if mover.moving == entry.id {
                ProgressView(value: mover.progress) { Text("Moving") } currentValueLabel: { Text("\(Int(mover.progress * 100))%") }
            } else if targets.count > 1 {
                Menu("Move to") {
                    ForEach(targets.filter { $0.name != here }, id: \.value) { target in
                        Button { start(target.value, steam: steam) } label: {
                            Text(target.name)
                            if let size = sizes[target.value] { Text(size) }
                        }
                    }
                }
                .disabled(mover.moving != nil)
            }
            if let error { Text(error).foregroundStyle(.red) }
        } header: { Text("Install Location") } footer: {
            Text("Moving copies the game, checks the copy, then deletes the original. Keep the drive connected until it finishes.")
        }
        .task(id: targets.map(\.value).joined()) {
            let drive = LibraryModel.drive
            var next: [String: String] = [:]
            for target in targets {
                let url = drive.appendingPathComponent(target.value)
                let free = url.freeSpace
                let total = url.volumeTotal
                let f = ByteCountFormatter.string(fromByteCount: free ?? 0, countStyle: .file)
                next[target.value] = switch (free, total) {
                case let (_?, total?): "\(f) free of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
                case (_?, nil): "\(f) free"
                default: nil
                }
            }
            sizes = next
        }
    }

    private func start(_ value: String, steam: Bool) {
        error = nil
        Task {
            do { entry = try await GameMover.shared.move(entry, toSteamLibrary: steam ? value : nil, toRoot: steam ? nil : value) }
            catch { self.error = error.localizedDescription }
        }
    }
}

extension URL {
    /// The volume's file system ("exfat", "msdos", "apfs", ...), or nil.
    var fileSystemType: String? {
        var url = resolvingSymlinksInPath()
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: info.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
    /// Total bytes of the volume holding this path (statfs), or nil.
    var volumeTotal: Int64? {
        var url = resolvingSymlinksInPath()
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        if let total = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity, total > 0 { return Int64(total) }
        var info = statfs()
        if statfs(url.path, &info) == 0, info.f_blocks > 0 { return Int64(info.f_blocks) * Int64(info.f_bsize) }
        return nil
    }
}

/// A move shown by iOS like a Steam download (SteamDownloadBackground.swift):
/// on iOS 26 and later a continued-processing task with the move's progress,
/// which also keeps Madeira running if it leaves the foreground. Its
/// identifier "<bundle id>.download.move" is covered by Info.plist's
/// `.download.*` entry.
@MainActor final class MoveBackground {
    static let shared = MoveBackground()
    private var task: AnyObject?
    private var registered = false
    private var title = ""
    private var fraction = 0.0

    private var identifier: String? {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        return permitted.first { $0.hasSuffix(".download.*") }.map { String($0.dropLast()) + "move" }
    }

    func started(_ name: String) {
        title = "Moving \(name)"; fraction = 0
        guard #available(iOS 26.0, *), let identifier else { return }
        if !registered {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                MainActor.assumeIsolated { self?.attach(task) }
            }
            guard registered else { LogStore.shared.log("[move] background task refused"); return }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Madeira")
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch { LogStore.shared.log("[move] background task not submitted") }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        guard GameMover.shared.moving != nil else { task.setTaskCompleted(success: true); return }
        self.task = task
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(fraction * 1000)
        task.updateTitle(title, subtitle: "Madeira")
        task.expirationHandler = { LogStore.shared.log("[move] background time ended") }
    }

    func progress(_ value: Double) {
        fraction = value
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64(min(1, value) * 1000)
            task.updateTitle(title, subtitle: "\(Int(min(1, value) * 100))% · Madeira")
        }
    }

    func ended() {
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask { task.setTaskCompleted(success: true) }
        task = nil
    }
}
