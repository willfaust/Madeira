// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Combine
import UniformTypeIdentifiers
import ContentKit
import GameImportKit

@MainActor final class GameImports: ObservableObject {
    struct Job: Codable, Identifiable, Sendable {
        var id = UUID()
        var name: String
        var bookmark: Data
        var destination: String
        var folder: String
        var state = "Waiting"
    }
    static let shared = GameImports()
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var fraction = 0.0
    @Published var error: String?
    private var worker: Task<Void, Never>?
    @Published private var active: UUID?
    private var watching: AnyCancellable?
    private var readable = true
    private static var file: URL { LibraryModel.documents.appendingPathComponent("madeira-imports.json") }

    private init() {
        do {
            if FileManager.default.fileExists(atPath: Self.file.path) {
                jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: Self.file))
                for i in jobs.indices where jobs[i].state != "Done" { jobs[i].state = "Paused" }
            }
        } catch { readable = false; self.error = "The saved import queue could not be read. It has not been overwritten." }
        watching = LibraryModel.shared.$current.receive(on: DispatchQueue.main).sink { [weak self] current in
            guard let self else { return }
            if current != nil { self.gameStarted() }
            else {
                for i in self.jobs.indices where self.jobs[i].state == "Waiting for game" { self.jobs[i].state = "Waiting" }
                self.startNext()
            }
        }
    }

    func add(_ source: URL, destination: String) {
        guard readable else { error = "The saved import queue could not be read. It has not been overwritten."; return }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let previous = jobs
        do {
            let root = try Self.destination(destination)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            let bookmark = try source.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let folder = GameImporter.uniqueFolder((source.pathExtension.lowercased() == "zip" ? source.deletingPathExtension().lastPathComponent : source.lastPathComponent), existing: names,
                taken: jobs.filter { $0.destination == destination }.map(\.folder))
            jobs.append(Job(name: source.lastPathComponent, bookmark: bookmark, destination: destination, folder: folder))
            try save()
            startNext()
        } catch { jobs = previous; self.error = "The game could not be queued: \(error.localizedDescription)" }
    }

    func resume(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != "Done" else { return }
        jobs[i].state = "Waiting"
        do { try save(); startNext() } catch { setState(id, "Paused"); self.error = error.localizedDescription }
    }

    func pause(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = "Paused"
        if id == active { worker?.cancel() }
        do { try save() } catch { self.error = error.localizedDescription }
    }

    func moveNext(_ id: UUID) {
        guard id != active, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let item = jobs.remove(at: i)
        jobs.insert(item, at: active == nil ? 0 : min(1, jobs.count))
        do { try save(); startNext() } catch { self.error = error.localizedDescription }
    }

    private func save() throws {
        guard readable else { throw LibraryError.message("The saved import queue could not be read.") }
        try JSONEncoder().encode(jobs).write(to: Self.file, options: .atomic)
    }

    private func startNext() {
        guard worker == nil, LibraryModel.shared.current == nil,
              wine_process_is_running() == 0, let job = jobs.first(where: { $0.state == "Waiting" }) else { return }
        setState(job.id, "Importing")
        do { try save() } catch { setState(job.id, "Paused"); self.error = error.localizedDescription; return }
        active = job.id
        fraction = 0
        worker = Task {
            do {
                var stale = false
                let source = try URL(resolvingBookmarkData: job.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale else { throw LibraryError.message("Pick the source again. Its saved permission has expired.") }
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                let root = try Self.destination(job.destination)
                let state = LibraryModel.documents.appendingPathComponent("Import State/\(job.id.uuidString)", isDirectory: true)
                let staging = root.appendingPathComponent(".madeira-imports/" + job.id.uuidString, isDirectory: true)
                let layout = InstallLayout(stagingRoot: staging, gamesRoot: root, stateRoot: state)
                let task = Task.detached(priority: .utility) {
                    let picked: ImportSource = source.pathExtension.lowercased() == "zip" ? .zip(source) : .folder(source)
                    let plan = try GameImporter.plan(picked)
                    var importer = GameImporter(layout: layout)
                    importer.validateDestination = { _ = try Self.destination(job.destination) }
                    return try await importer.run(plan, folder: job.folder) { progress in
                        Task { @MainActor in
                            guard self.active == job.id else { return }
                            self.fraction = progress.bytesTotal == 0 ? 0 : Double(progress.bytesDone) / Double(progress.bytesTotal)
                        }
                    }
                }
                _ = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                let final = root.appendingPathComponent(job.folder)
                let scan = Task.detached { ExternalGameScan.scan(final) }
                let programs = await scan.value
                for program in programs {
                    if let entry = try? LibraryModel.inspect(program) { LibraryModel.shared.save(entry) }
                }
                setState(job.id, "Done")
            } catch is CancellationError {
                if jobs.first(where: { $0.id == job.id })?.state != "Waiting for game" { setState(job.id, "Paused") }
            } catch {
                setState(job.id, "Paused")
                self.error = "Import stopped: \(error.localizedDescription)"
            }
            do { try save() } catch { self.error = error.localizedDescription }
            worker = nil
            active = nil
            startNext()
        }
    }

    private func setState(_ id: UUID, _ state: String) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = state }
    }

    private nonisolated static func destination(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard relative == "Games" || (parts.count == 3 && parts[0] == "External" && parts[2] == "Games" && parts[1] != "." && parts[1] != "..") else {
            throw LibraryError.message("This is not a game import destination.")
        }
        return try ExternalDrives.nativeURL(relative, write: true)
    }

    func gameStarted() {
        guard let active, jobs.first(where: { $0.id == active })?.state == "Importing" else { return }
        setState(active, "Waiting for game")
        worker?.cancel()
        do { try save() } catch { self.error = error.localizedDescription }
    }
}

struct GameImportsView: View {
    @ObservedObject private var imports = GameImports.shared
    @ObservedObject private var drives = ExternalDrives.shared
    @ObservedObject private var library = LibraryModel.shared
    @State private var picking = false
    @State private var destination = "Games"

    var body: some View {
        List {
            Section {
                Picker("Install on", selection: $destination) {
                    Text("This device").tag("Games")
                    ForEach(drives.folders) { drive in
                        Text("\(drive.letter): \(drive.name)").tag("External/\(drive.name)/Games")
                    }
                }
                Button("Choose game folder or ZIP") { picking = true }
                    .disabled(library.current != nil)
            } footer: { Text("Import a complete game folder or ZIP. The source stays in place. Installers are not run.") }
            ForEach(imports.jobs) { job in
                Section(job.name) {
                    Text(job.state)
                    if job.state == "Importing" {
                        ProgressView(value: imports.fraction)
                        Button("Pause") { imports.pause(job.id) }
                    } else if job.state == "Waiting" {
                        Button("Import next") { imports.moveNext(job.id) }
                        Button("Pause") { imports.pause(job.id) }
                    } else if job.state != "Done" {
                        Button("Resume") { imports.resume(job.id) }.disabled(library.current != nil)
                    }
                }
            }
        }
        .navigationTitle("Import games")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, .zip]) { result in
            switch result {
            case .success(let url): imports.add(url, destination: destination)
            case .failure(let error): imports.error = error.localizedDescription
            }
        }
        .onChange(of: library.current) { _, current in if current != nil { imports.gameStarted() } }
        .alert("Import games", isPresented: Binding(get: { imports.error != nil }, set: { if !$0 { imports.error = nil } })) {
            Button("OK", role: .cancel) { imports.error = nil }
        } message: { Text(imports.error ?? "") }
    }
}
