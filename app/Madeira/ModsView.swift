// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Game details › Mods: the page. The installed mods, each with a switch and Remove,
//  and Add a Mod (a file or a folder, both copied in by the picker). Adding opens a
//  sheet that shows each step as it happens and cannot be swiped away while it
//  works (the old Mods sheet flashed shut): copying, unpacking, a FOMOD installer's
//  pages, "Installs into:", then installing. It closes only with its own buttons.
//  The work itself is ModsArchive.swift and ModsCore.swift.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ModsPage: View {
    let game: ModGame
    @State private var mods: [ModRecord] = []
    @State private var picker: ModPicker?
    @State private var picked: (URL, Bool)?
    @State private var installing: ModInstallRequest?
    @State private var removing: ModRecord?
    @State private var working: String?
    @State private var problem: Error?
    @State private var iniNote = false

    private var store: URL { ModInstaller.store(game.id) }
    private var removingName: String { removing?.name ?? "" }
    /// A game right in drive_c has no folder of its own to put mods in.
    private var hasFolder: Bool {
        game.gameFolder.standardizedFileURL.path != game.drive.standardizedFileURL.path
    }

    var body: some View {
        Section {
            if mods.isEmpty {
                Text("Mods add to or change a game's files. Add one below; you can turn it off or remove it at any time, and the game's own files come back.")
                    .foregroundStyle(.secondary)
            }
            ForEach(mods) { mod in row(mod) }
        } header: {
            Text("Installed")
        } footer: {
            if mods.count > 1 { Text("When two mods change the same file, the one added later wins.") }
        }
        .navigationTitle("Mods")
        .onAppear(perform: reload)
        Section {
            Button { picker = .file } label: { Label("Choose a File", systemImage: "doc.zipper") }
            Button { picker = .folder } label: { Label("Choose a Folder", systemImage: "folder") }
        } header: {
            Text("Add a Mod")
        } footer: {
            Text("A .zip, .7z, .rar or .fomod file, or a folder with the mod's files in it.")
        }
        .disabled(!hasFolder || working != nil)
        .sheet(item: $picker, onDismiss: {
            // The install sheet opens once the picker has gone.
            if let pick = picked { picked = nil; installing = ModInstallRequest(source: pick.0, folder: pick.1) }
        }) { kind in
            ModDocumentPicker(folder: kind == .folder) { url in
                if let url { picked = (url, kind == .folder) }
                picker = nil
            }
            .ignoresSafeArea()
        }
        .sheet(item: $installing, onDismiss: reload) { request in
            ModInstallSheet(request: request, game: game, store: store) { notes in
                if notes.contains("ini-missing") { iniNote = true }
            }
        }
        .confirmationDialog(Text("Remove \(removingName)?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { mod in
            Button("Remove", role: .destructive) { change(mod) { store in try store.remove(mod.id) } }
        } message: { _ in
            Text("Its files come out of the game and the game's own files come back.")
        }
        if !hasFolder {
            Section { Text("This game has no folder of its own, so mods can't be added to it.").foregroundStyle(.secondary) }
        }
        if let problem {
            Section { ModErrorText(error: problem).foregroundStyle(.red) }
        }
        if iniNote {
            Section {
                Text("Play the game once so it makes its settings file, then turn this mod off and on again. Until then the game may not show the mod's loose files.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func row(_ mod: ModRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: mod.name).lineLimit(2)
                if working == mod.id, mod.enabled {
                    Text("Turning off…").font(.caption).foregroundStyle(.secondary)
                } else if working == mod.id {
                    Text("Turning on…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Installs into: \(folderName(mod.target))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if working == mod.id { ProgressView() }
            Toggle(isOn: Binding(get: { mod.enabled }, set: { on in
                change(mod) { store in if on { try store.enable(mod.id) } else { try store.disable(mod.id) } }
            })) { Text(verbatim: mod.name) }
            .labelsHidden()
            Button { removing = mod } label: { Image(systemName: "trash").foregroundStyle(.red) }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Remove"))
        }
        .disabled(working != nil)
    }

    /// "Data" or the game's folder, by name.
    private func folderName(_ target: String) -> String {
        target.isEmpty ? game.gameFolder.lastPathComponent : game.gameFolder.lastPathComponent + " › " + target
    }

    private func reload() {
        mods = ModStore(folder: store, game: game).mods
    }

    /// Turns a mod on or off, or removes it, away from the main thread; the row says what is happening.
    private func change(_ mod: ModRecord, _ work: @escaping (ModStore) throws -> Void) {
        working = mod.id
        problem = nil
        let folder = store, game = game
        Task.detached {
            let store = ModStore(folder: folder, game: game)
            var failure: Error?
            do { try work(store) } catch { failure = error }
            let notes = store.notes, failed = failure
            await MainActor.run {
                working = nil
                problem = failed
                if notes.contains("ini-missing") { iniNote = true }
                reload()
            }
        }
    }
}

enum ModPicker: String, Identifiable {
    case file, folder
    var id: String { rawValue }
}

struct ModInstallRequest: Identifiable {
    let id = UUID()
    let source: URL
    let folder: Bool
}

/// The Files picker, copying what is chosen into the app (asCopy) so nothing is read
/// from a folder the app may lose access to halfway.
struct ModDocumentPicker: UIViewControllerRepresentable {
    let folder: Bool
    let done: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = folder ? [.folder]
            : [.zip, .archive, .data] + ["7z", "rar", "fomod"].compactMap { UTType(filenameExtension: $0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: (URL?) -> Void
        init(_ done: @escaping (URL?) -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done(nil) }
    }
}

// MARK: The install sheet

@MainActor
final class ModInstallModel: ObservableObject {
    enum Stage {
        case working(ModInstaller.Phase)
        case choosing(Int)
        case confirm
        case done
        case failed(Error)
    }

    @Published var stage: Stage = .working(.copying)
    @Published var choices: FomodChoices?
    private(set) var prepared: ModPrepared?
    private var task: Task<Void, Never>?
    private var installing = false
    let game: ModGame
    let store: URL
    var notes: [String] = []

    init(game: ModGame, store: URL) {
        self.game = game
        self.store = store
    }

    var busy: Bool { if case .working = stage { return true } else { return false } }
    /// Unpacking can stop; installing (files going into the game) is never left half done.
    var canCancel: Bool { !installing }

    /// Progress from the work: shown only while the sheet is still on a working step.
    private func report(_ phase: ModInstaller.Phase) {
        if busy { stage = .working(phase) }
    }

    private var started = false

    func start(_ source: URL) {
        guard !started else { return }
        started = true
        stage = .working(.copying)
        let store = store
        let progress: (ModInstaller.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in self?.report(phase) }
        }
        task = Task.detached {
            do {
                let prepared = try ModInstaller.prepare(source, store: store, progress: progress)
                // A folder copy cannot stop halfway: what it made goes once it is done.
                if Task.isCancelled { ModInstaller.discard(prepared, store: store); throw CancellationError() }
                await MainActor.run { self.ready(prepared) }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self.stage = .failed(error) }
            }
            // The picker's copy is not needed any more; only ever a copy in the app's own temporary folder.
            if ModInstaller.isPickerCopy(source) { try? FileManager.default.removeItem(at: source) }
        }
    }

    private func ready(_ prepared: ModPrepared) {
        self.prepared = prepared
        if let config = prepared.config, !config.steps.isEmpty {
            var choices = FomodChoices(config, fileState: fileState)
            if let first = choices.next(after: -1) {
                choices.prepare(first)
                self.choices = choices
                stage = .choosing(first)
                return
            }
            self.choices = choices
        } else if let config = prepared.config {
            choices = FomodChoices(config, fileState: fileState)
        }
        stage = .confirm
    }

    /// A FOMOD's file conditions: a plugin is "active" when the game's Data folder has it.
    private var fileState: (String) -> String {
        let data = ModPath.child("Data", of: game.gameFolder) ?? game.gameFolder
        return { name in
            guard let clean = ModPath.clean(name) else { return "missing" }
            return FileManager.default.fileExists(atPath: data.appendingPathComponent(ModPath.existing(clean, under: data)).path) ? "active" : "missing"
        }
    }

    func next(from step: Int) {
        guard var choices else { return }
        if let next = choices.next(after: step) {
            choices.prepare(next)
            self.choices = choices
            stage = .choosing(next)
        } else {
            stage = .confirm
        }
    }

    func back(from step: Int?) {
        guard let choices else { return }
        let current = step ?? choices.config.steps.count
        if let previous = choices.previous(before: current) { stage = .choosing(previous) }
    }

    var target: String {
        guard let prepared else { return "" }
        let into = ModInstaller.target(prepared, game: game)
        return into.isEmpty ? game.gameFolder.lastPathComponent : game.gameFolder.lastPathComponent + " › " + into
    }

    func install() {
        guard let prepared else { return }
        installing = true
        stage = .working(.installing(0, 0))
        let game = game, store = store, picks = prepared.config == nil ? nil : choices
        let progress: (ModInstaller.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in self?.report(phase) }
        }
        task = Task.detached {
            do {
                let (_, notes) = try ModInstaller.install(prepared, choices: picks, game: game, store: store, progress: progress)
                await MainActor.run { self.notes = notes; self.installing = false; self.stage = .done }
            } catch {
                await MainActor.run { self.installing = false; self.stage = .failed(error) }
            }
        }
    }

    /// Cancel or a failure: an unpacked mod that was not installed goes.
    func discard() {
        task?.cancel()
        if let prepared, !installing { ModInstaller.discard(prepared, store: store) }
    }
}

struct ModInstallSheet: View {
    let request: ModInstallRequest
    let finished: ([String]) -> Void
    @StateObject private var model: ModInstallModel
    @Environment(\.dismiss) private var dismiss

    init(request: ModInstallRequest, game: ModGame, store: URL, finished: @escaping ([String]) -> Void) {
        self.request = request
        self.finished = finished
        _model = StateObject(wrappedValue: ModInstallModel(game: game, store: store))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add a Mod").navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        // Never swiped away: it closes with its own buttons only.
        .interactiveDismissDisabled(true)
        .onAppear { model.start(request.source) }
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .working(let phase):
            VStack(spacing: 16) {
                switch phase {
                case .copying:
                    ProgressView()
                    Text("Copying the mod…")
                case .unpacking(let done, let total):
                    if total > 0 {
                        ProgressView(value: Double(min(done, total)), total: Double(total))
                    } else {
                        ProgressView()
                    }
                    Text("Unpacking…")
                    if done > 0 {
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(done), countStyle: .file)).font(.footnote).foregroundStyle(.secondary)
                    }
                case .reading:
                    ProgressView()
                    Text("Looking inside the mod…")
                case .installing(let done, let total):
                    if total > 0 { ProgressView(value: Double(min(done, total)), total: Double(total)) } else { ProgressView() }
                    Text("Installing…")
                    Text("Keep Madeira open until this finishes.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .choosing(let step):
            if let choices = model.choices { FomodStepView(model: model, choices: choices, step: step) }
        case .confirm:
            Form {
                Section {
                    Text(verbatim: model.prepared?.name ?? "").font(.headline)
                    Text("Installs into: \(model.target)")
                } footer: {
                    Text("Files the mod replaces are kept, and come back when you turn the mod off or remove it.")
                }
            }
        case .done:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                Text("Installed and turned on.").font(.headline)
                Text("Installs into: \(model.target)").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
                Text("The mod was not added.").font(.headline)
                ModErrorText(error: error).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { leftButton }
        ToolbarItem(placement: .confirmationAction) { rightButton }
    }

    @ViewBuilder private var leftButton: some View {
        switch model.stage {
        case .working: Button("Cancel") { model.discard(); dismiss() }.disabled(!model.canCancel)
        case .choosing, .confirm: Button("Cancel") { model.discard(); dismiss() }
        case .done, .failed: EmptyView()
        }
    }

    @ViewBuilder private var rightButton: some View {
        switch model.stage {
        case .working: EmptyView()
        case .choosing(let step): Button("Next") { model.next(from: step) }
        case .confirm: Button("Install") { model.install() }.bold()
        case .done: Button("Done") { finished(model.notes); dismiss() }
        case .failed: Button("OK") { model.discard(); dismiss() }
        }
    }
}

/// One page of a FOMOD installer: its groups, each a list of round buttons (one
/// choice) or check boxes (several), with Back below.
struct FomodStepView: View {
    @ObservedObject var model: ModInstallModel
    let choices: FomodChoices
    let step: Int

    var body: some View {
        let page = choices.config.steps[step]
        Form {
            Section {
                if !choices.config.moduleName.isEmpty { Text(verbatim: choices.config.moduleName).font(.headline) }
                if !page.name.isEmpty { Text(verbatim: page.name).foregroundStyle(.secondary) }
            }
            ForEach(Array(page.groups.enumerated()), id: \.offset) { g, group in
                Section {
                    ForEach(Array(group.plugins.enumerated()), id: \.offset) { p, plugin in
                        option(g, p, plugin, single: group.kind.single)
                    }
                } header: {
                    Text(verbatim: group.name)
                } footer: {
                    switch group.kind {
                    case .exactlyOne: Text("Pick one.")
                    case .atMostOne: Text("Pick one, or none.")
                    case .atLeastOne: Text("Pick one or more.")
                    case .any: Text("Pick any you want.")
                    case .all: Text("All of these are installed.")
                    }
                }
            }
            if choices.previous(before: step) != nil {
                Section { Button("Back") { model.back(from: step) } }
            }
        }
    }

    private func option(_ g: Int, _ p: Int, _ plugin: FomodPlugin, single: Bool) -> some View {
        let on = choices.selected[step][g].contains(p)
        let locked = choices.locked(step, g, p)
        let kind = choices.kind(step, g, p)
        return Button {
            var updated = choices
            updated.toggle(step, g, p)
            model.choices = updated
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: single ? (on ? "largecircle.fill.circle" : "circle") : (on ? "checkmark.square.fill" : "square"))
                    .foregroundStyle(locked ? Color.secondary : Color.accentColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: plugin.name).foregroundStyle(kind == .notUsable ? .secondary : .primary)
                    if kind == .notUsable { Text("Can't be used with this game.").font(.caption).foregroundStyle(.secondary) }
                    else if kind == .recommended { Text("Recommended").font(.caption).foregroundStyle(.green) }
                    if !plugin.description.isEmpty {
                        Text(verbatim: plugin.description).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let image = image(plugin) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }

    private func image(_ plugin: FomodPlugin) -> UIImage? {
        guard let path = plugin.image.flatMap(ModPath.clean), let root = model.prepared?.root else { return nil }
        return UIImage(contentsOfFile: root.appendingPathComponent(ModPath.existing(path, under: root)).path)
    }
}

/// A Mods error in plain words, in the device's language.
struct ModErrorText: View {
    let error: Error

    var body: some View {
        if let mod = error as? ModError {
            switch mod {
            case .valveFile(let name): Text("This mod tries to replace \(name), a Steam file Madeira never changes. Nothing was changed.")
            case .gameProgram(let name): Text("This mod tries to replace the game's program (\(name)). Madeira never changes it, so nothing was changed.")
            case .outside(let name): Text("This mod has a file that would land outside the game's folder (\(name)). Nothing was changed.")
            case .link(let name): Text("This mod has a shortcut file Madeira will not copy (\(name)). Nothing was changed.")
            case .noFiles: Text("There are no files in this mod.")
            case .badInstaller(let why): Text("This mod's installer could not be read (\(why)).")
            case .missingSource(let name): Text("This mod's installer names a file the mod does not have (\(name)).")
            case .unknownFile(let name): Text("Madeira can't open \(name). Choose a .zip, .7z, .rar or .fomod file, or a folder.")
            case .rar: Text("This .rar file can't be opened on this device. Unpack it on a computer and choose the folder, or get the mod as a .zip or .7z.")
            case .encrypted: Text("This archive has a password. Madeira can't open it.")
            }
        } else if let archive = error as? ItchArchiveError {
            switch archive {
            case .notZip, .damaged: Text("This file is damaged. Get it again and try once more.")
            case .unsupported(let what): Text("Madeira can't open this archive (\(what)).")
            case .unsafeName(let name): Text("This archive has a file Madeira will not unpack (\(name)).")
            }
        } else if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileWriteOutOfSpaceError {
            Text("There isn't enough free space on this device for this mod.")
        } else {
            Text(verbatim: error.localizedDescription)
        }
    }
}
