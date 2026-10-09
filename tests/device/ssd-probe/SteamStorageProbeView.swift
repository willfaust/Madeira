// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 David Brookes
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SteamStorageProbeView: View {
    @State private var library: SteamStorageLibrary?
    @State private var choosing = false
    @State private var busy = false
    @State private var largeFile = false
    @State private var status = "Choose a dedicated folder on the attached SSD. This prototype tests data access, not game execution."

    nonisolated private static var record: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("external-library-prototype.json")
    }

    var body: some View {
        Form {
            Section("External storage prototype") {
                Text(library?.name ?? "No registered folder")
                Button(library == nil ? "Select SSD test folder" : "Reauthorise the same folder") { choosing = true }
                    .disabled(busy)
                Button("Reopen bookmark and test") { run() }.disabled(busy || library == nil)
                Toggle("Test a file larger than 4 GiB", isOn: $largeFile).disabled(busy)
                Text("The large-file test may allocate over 4 GiB on the SSD. Tests create and remove a unique scratch folder; registration leaves a small identity marker.")
                    .font(.footnote)
            }
            Section("Result") {
                if busy { ProgressView() }
                Text(status).textSelection(.enabled)
            }
            Section {
                Text("After a pass, close this app, unplug and reconnect the SSD, reopen the app, and tap Reopen bookmark and test. Revoked access and a missing drive must report a failure. No Steam credentials or game files are used.")
            }
        }
        .navigationTitle("SSD access probe")
        .task {
            do {
                let data = try Data(contentsOf: Self.record)
                library = try JSONDecoder().decode(SteamStorageLibrary.self, from: data)
                status = "Registration restored. Reopen the bookmark to test access."
            } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError { }
            catch { status = "Saved registration could not be read. No files were changed." }
        }
        .sheet(isPresented: $choosing) {
            SteamStorageFolderPicker { url in
                choosing = false
                if let url { register(url) }
            }
        }
    }

    private func register(_ url: URL) {
        busy = true
        let current = library
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let registered = try SteamExternalAccess.register(url, replacing: current)
                    try Self.save(registered)
                    return registered
                }.value
                library = result
                status = "Folder registered. Tap Reopen bookmark and test."
            } catch { status = Self.failure(error) }
            busy = false
        }
    }

    private func run() {
        guard let library else { return }
        busy = true
        let large = largeFile
        Task {
            do {
                let (report, updated) = try await Task.detached(priority: .userInitiated) {
                    let result = try SteamExternalAccess.withLibrary(library, write: true) {
                        try SteamStorageProbe.run(root: $0, largeFile: large)
                    }
                    try Self.save(result.1)
                    return result
                }.value
                self.library = updated
                status = report
            } catch { status = Self.failure(error) }
            busy = false
        }
    }

    nonisolated private static func save(_ library: SteamStorageLibrary) throws {
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(library).write(to: record, options: .atomic)
    }

    nonisolated private static func failure(_ error: Error) -> String {
        let e = error as NSError
        // Do not publish provider paths or bookmark bytes in diagnostics.
        return "FAIL: \(SteamExternalAccess.availability(for: error).rawValue) (\(e.domain), \(e.code)). Reconnect the SSD or reauthorise the same folder."
    }
}

private struct SteamStorageFolderPicker: UIViewControllerRepresentable {
    var picked: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(picked) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let picked: (URL?) -> Void
        init(_ picked: @escaping (URL?) -> Void) { self.picked = picked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { picked(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { picked(nil) }
    }
}
