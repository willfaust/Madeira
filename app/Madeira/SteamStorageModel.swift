// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 David Brookes
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Owns only internal metadata. Native SSD paths are obtained for an operation
/// and are never serialized. Failure to load the catalog disables mutations.
@MainActor final class SteamStorageModel: ObservableObject {
    static let shared = SteamStorageModel()
    @Published private(set) var catalog = SteamStorageCatalog()
    @Published private(set) var availability: SteamStorageAvailability = .disconnected
    @Published private(set) var problem: String?
    @Published private(set) var checking = false
    private var loadFailure: Error?
    private weak var liveAccess: SteamExternalLease?
    private var opening: Task<SteamExternalLease, Error>?
    private(set) var sessionAccess: SteamExternalLease?
    private var sessionTimer: Timer?
    private var sawSession = false

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Madeira/steam-storage.json")
    }

    private init() {
        do { catalog = try SteamStorageCatalog.load(from: Self.file) }
        catch { loadFailure = error; problem = "The storage catalog could not be read. Existing files have been kept." }
    }

    var libraries: [SteamStorageLibrary] { [.internalLibrary] + [catalog.external].compactMap { $0 } }
    func library(_ id: String) throws -> SteamStorageLibrary {
        if let loadFailure { throw loadFailure }
        return try catalog.library(id)
    }

    func register(_ url: URL) async throws {
        if let loadFailure { throw loadFailure }
        let previous = catalog.external
        let registration = try await Task.detached(priority: .utility) {
            try SteamExternalAccess.register(url, replacing: previous)
        }.value
        try catalog.transaction(file: Self.file) { try $0.register(registration) }
        liveAccess = nil
        availability = .available
        problem = nil
        SteamOwnedLibrary.shared.storageReconnected(registration.id)
    }

    /// Always ask this before queueing or resuming. An existing assignment wins;
    /// the supplied choice is only meaningful for an app with no existing files.
    func assign(appID: Int, name: String, folder: String, libraryID: String,
                existing: SteamStorageAssignment? = nil) throws -> SteamStorageAssignment {
        if let loadFailure { throw loadFailure }
        if var assigned = catalog.assignments[appID] {
            assigned.pending = true
            try catalog.transaction(file: Self.file) { try $0.assign(assigned) }
            return assigned
        }
        let selected = try library(existing?.location.libraryID ?? libraryID)
        let relative = selected.id == SteamStorageLibrary.internalID ? SteamInstallPaths.libraryRelative : "steamapps"
        var value = try existing ?? SteamStorageAssignment(appID: appID,
            location: SteamStorageLocation(libraryID: selected.id, relativePath: relative + "/common/" + folder),
            name: name, installed: false)
        value.pending = true
        try catalog.transaction(file: Self.file) { try $0.assign(value) }
        return value
    }

    func record(_ value: SteamStorageAssignment) throws {
        if let loadFailure { throw loadFailure }
        try catalog.transaction(file: Self.file) { try $0.assign(value) }
    }

    func removed(appID: Int) throws {
        if let loadFailure { throw loadFailure }
        try catalog.transaction(file: Self.file) { next in
            let location = next.assignments[appID]?.location
            let shared = next.assignments.values.filter { $0.appID == appID || (location != nil && $0.location == location) }.map(\.appID)
            for id in shared { next.remove(appID: id) }
        }
    }

    /// No filesystem work here: unavailable installations remain visible from
    /// their stable identities, including when their volume has disappeared.
    var rememberedGames: [DockGame] {
        catalog.assignments.values.filter { $0.location.libraryID != SteamStorageLibrary.internalID }.compactMap { record in
            let parts = record.location.relativePath.split(separator: "/")
            guard parts.count >= 3, parts[parts.count - 2] == "common" else { return nil }
            return DockGame(id: record.appID, name: record.name, installDir: String(parts.last!),
                library: parts.dropLast(2).joined(separator: "/"), installed: record.installed,
                customExecutables: false, storageID: record.location.libraryID, storageAvailable: false)
        }
    }

    /// Discovery returns values, never scoped native URLs. Failed scans retain
    /// the snapshots and never turn unavailable games into uninstalled games.
    func externalGames() async -> (games: [DockGame], builds: [Int: Int]) {
        guard let external = catalog.external else { return ([], [:]) }
        do {
            let records = try await perform(libraryID: external.id, write: false) { root -> [(DockGame, Int?, Int64?)] in
                let apps = try SteamStoragePath.native("steamapps", root: root)
                return try MadeiraDock.games(library: external, root: root).map { game in
                    (game, SteamInstallFiles.buildID(appID: game.id, steamApps: apps),
                     SteamInstallFiles.sizeOnDisk(appID: game.id, steamApps: apps))
                }
            }
            var builds: [Int: Int] = [:]
            for (game, build, bytes) in records {
                let location = try SteamStorageLocation(libraryID: game.storageID,
                                                       relativePath: game.library + "/common/" + game.installDir)
                // The first version has one installation per app. A duplicate
                // external record must not steal an existing internal identity.
                if let assigned = catalog.assignments[game.id], assigned.location != location { continue }
                try record(SteamStorageAssignment(appID: game.id, location: location, name: game.name,
                                                   installed: game.installed, buildID: build, bytes: bytes))
                if let build { builds[game.id] = build }
            }
            let found = records.map(\.0).filter { game in
                catalog.assignments[game.id]?.location.libraryID == game.storageID
            }
            let partial = rememberedGames.filter { old in !found.contains { $0.id == old.id } }.map { old in
                DockGame(id: old.id, name: old.name, installDir: old.installDir, library: old.library,
                         installed: false, customExecutables: false, storageID: old.storageID)
            }
            return (found + partial, builds)
        } catch { return (rememberedGames, [:]) }
    }

    func perform<Value: Sendable>(libraryID: String, write: Bool,
                                 _ operation: @escaping @Sendable (URL) async throws -> Value) async throws -> Value {
        _ = try library(libraryID)
        if libraryID == SteamStorageLibrary.internalID { return try await operation(MadeiraDock.drive) }
        guard let access = try await accessForOperation(libraryID: libraryID, write: write) else { throw SteamStorageError.invalidRecord }
        defer { access.keepAlive() }
        return try await SteamStorageOperation.run({ try await operation(access.root) }) {
            // Only a failed volume check changes library availability. Keep the
            // original download error when the selected volume is still present.
            do {
                try await Task.detached(priority: .utility) { try access.validate() }.value
                availability = access.writable ? .available : .readOnly
                problem = access.writable ? nil : SteamStorageError.unavailable(.readOnly).localizedDescription
            } catch {
                liveAccess = nil
                availability = SteamExternalAccess.availability(for: error)
                problem = SteamStorageError.unavailable(availability).localizedDescription
                throw SteamStorageError.unavailable(availability)
            }
        }
    }

    private func acquire(libraryID: String, write: Bool) async throws -> SteamExternalLease {
        let registration = try library(libraryID)
        let access: SteamExternalLease
        if let current = liveAccess {
            access = current
        } else {
            if opening == nil { opening = Task { try await SteamExternalLease.open(registration) } }
            do {
                access = try await opening!.value
                liveAccess = access
                opening = nil
            } catch { opening = nil; throw error }
        }
        guard access.library.id == libraryID else { throw SteamStorageError.unavailable(.identityMismatch) }
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) {
            try access.validate()
            if write {
                let readOnly = try access.root.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly
                guard access.writable, readOnly != true else { throw SteamStorageError.unavailable(.readOnly) }
            }
        }.value
        try Task.checkCancellation()
        if access.library != catalog.external { try catalog.transaction(file: Self.file) { try $0.register(access.library) } }
        return access
    }

    func accessForOperation(libraryID: String, write: Bool) async throws -> SteamExternalLease? {
        _ = try library(libraryID)
        if libraryID == SteamStorageLibrary.internalID { return nil }
        do {
            let access = try await acquire(libraryID: libraryID, write: write)
            availability = access.writable ? .available : .readOnly
            problem = nil
            return access
        } catch {
            if error is CancellationError { throw error }
            liveAccess = nil
            availability = SteamExternalAccess.availability(for: error)
            problem = SteamStorageError.unavailable(availability).localizedDescription
            throw SteamStorageError.unavailable(availability)
        }
    }

    /// Acquired before any E: mapping or launch validation, held until all Wine
    /// processes stop. Save operations during gameplay share this same accessor.
    func holdSession(libraryID: String) async throws {
        if libraryID == SteamStorageLibrary.internalID { return }
        sessionAccess = try await acquire(libraryID: libraryID, write: true)
        if sessionTimer == nil {
            sawSession = false
            sessionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if wine_process_is_running() != 0 || wineserver_is_running() != 0 { self.sawSession = true }
                    else if self.sawSession { self.releaseSession() }
                }
            }
        }
    }

    func prepareSession(libraryID: String) async throws {
        guard libraryID != SteamStorageLibrary.internalID else { return }
        guard wine_process_is_running() == 0, wineserver_is_running() == 0 else {
            throw SteamFileError.invalid("Close the running session before changing its storage mapping.")
        }
        try await holdSession(libraryID: libraryID)
        do {
            guard let access = sessionAccess else { throw SteamStorageError.invalidRecord }
            try access.validate()
            let fm = FileManager.default, prefix = MadeiraDock.prefix
            madeira_seed_prefix_if_needed(prefix.path)
            let owner = try SteamStoragePath.native("madeira-external-owner", root: prefix)
            let recordedOwner = try? String(contentsOf: owner, encoding: .utf8)
            let devices = try SteamStoragePath.native("dosdevices", root: prefix)
            try fm.createDirectory(at: devices, withIntermediateDirectories: true)
            try SteamStorageMapping.replace(devices.appendingPathComponent("e:"), root: access.root,
                                            libraryID: libraryID, ownerID: recordedOwner)
            // Valve's client rejects E: as unmounted on the tested iPad runtime.
            // Register the same scoped directory beneath C:, without copying it.
            try SteamStorageMapping.replace(MadeiraDock.drive.appendingPathComponent(SteamStoragePath.externalAlias),
                                            root: access.root, libraryID: libraryID, ownerID: recordedOwner)
            let apps = Dictionary(uniqueKeysWithValues: catalog.assignments.values.filter {
                $0.location.libraryID == libraryID && $0.installed
            }.map { ($0.appID, $0.bytes ?? 0) })
            try SteamLibraryFolders.register(externalID: libraryID, name: access.library.name, apps: apps,
                                             drive: MadeiraDock.drive, verifiedAliasOwnerID: recordedOwner)
            try Data(libraryID.utf8).write(to: owner, options: .atomic)
            setenv("MADEIRA_EXTERNAL_LIBRARY_ID", libraryID, 1)
        } catch {
            releaseSession()
            throw error
        }
    }

    func releaseSession() {
        guard wine_process_is_running() == 0, wineserver_is_running() == 0 else { return }
        sessionAccess = nil
        sessionTimer?.invalidate(); sessionTimer = nil
        unsetenv("MADEIRA_EXTERNAL_LIBRARY_ID")
    }

    /// Visible foreground cards must notice removal even when a paused transfer
    /// performs no I/O. Scope each check; an idle card must not hold a coordinated
    /// writer open while a folder picker tries to reauthorize the same library.
    /// Downloads/sessions retain their own leases. Reconnection is explicit.
    func monitorAvailability(libraryID: String) async {
        guard libraryID != SteamStorageLibrary.internalID else { return }
        while !Task.isCancelled, catalog.external?.id == libraryID {
            if availability == .available || availability == .readOnly {
                do {
                    let access = try await accessForOperation(libraryID: libraryID, write: false)
                    access?.keepAlive()
                } catch { }
            }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { return }
        }
    }

    func check() async {
        guard !checking, let external = catalog.external else { return }
        checking = true
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            checking = false
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            SteamLog.event("[steam-storage] check state=\(availability.rawValue) elapsed-ms=\(elapsed)")
        }
        do {
            _ = try await perform(libraryID: external.id, write: true) { _ in true }
            SteamOwnedLibrary.shared.storageReconnected(external.id)
            SteamGamesModel.shared.refresh()
        }
        catch { }
    }
}

private struct SteamStorageVisibilityMonitor: ViewModifier {
    let libraryID: String
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: libraryID + String(describing: scenePhase)) {
            guard scenePhase == .active else { return }
            await SteamStorageModel.shared.monitorAvailability(libraryID: libraryID)
        }
    }
}

extension View {
    func monitorSteamStorage(libraryID: String) -> some View {
        modifier(SteamStorageVisibilityMonitor(libraryID: libraryID))
    }
}

struct SteamStorageSettings: View {
    @ObservedObject private var storage = SteamStorageModel.shared
    @State private var picking = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Game libraries") {
                Label("iPad", systemImage: "ipad")
                if let external = storage.catalog.external {
                    Label(external.name, systemImage: "externaldrive")
                    Text(storage.problem ?? (storage.availability == .available ? "Connected" : "Reconnect the SSD to use this library."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { Task { await storage.check() } } label: {
                        HStack {
                            if storage.checking { ProgressView() }
                            Text(storage.checking ? "Checking SSD…" : "Check SSD connection")
                        }
                    }.disabled(busy || storage.checking)
                }
                Button(storage.catalog.external == nil ? "Choose SSD library folder" : "Select library folder again") { picking = true }
                    .disabled(busy)
            }
            Section {
                Text("Choose a dedicated folder on a locally attached SSD. Game files, download progress and depot caches stay there. Windows and Steam client files stay on the iPad.")
                Text("Existing installations remain in their current library.")
                if storage.catalog.external != nil {
                    Text("If checking the connection does not restore access, select the original library folder again. Choosing a different folder will not reconnect these games.")
                }
            }.font(.footnote)
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Game storage")
        .sheet(isPresented: $picking) {
            SteamLibraryFolderPicker { result in
                picking = false
                switch result {
                case .success(let url):
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await storage.register(url); error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                case .failure(let failure): if !(failure is CancellationError) { error = failure.localizedDescription }
                }
            }
        }
        .task { await storage.check() }
    }
}

/// In-place selection. Only the selected directory receives scoped access.
struct SteamLibraryFolderPicker: UIViewControllerRepresentable {
    let completion: (Result<URL, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<URL, Error>) -> Void
        init(_ completion: @escaping (Result<URL, Error>) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { completion(.success(url)) }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(.failure(CancellationError()))
        }
    }
}
