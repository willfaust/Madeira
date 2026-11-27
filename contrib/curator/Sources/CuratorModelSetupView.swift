// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct CuratorModelSetupView: View {
    @ObservedObject private var download = CuratorDownloadState.shared
    @State private var confirmRemoval = false

    var body: some View {
        if !CuratorModel.appleAvailable || download.installed || download.task != nil {
            TriptychSectionHeader(title: "Curator Offline Model", detail: "Optional", accent: TriptychPalette.linuxLight)
            TriptychPanelCard(accent: TriptychPalette.linuxLight) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Qwen3-0.6B · 397 MB")
                        .font(.headline)
                    Text("Summarizes diagnostics on this device when Apple Intelligence is unavailable. It needs 1.25 GB of free app memory and works before you start a system.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let task = download.task {
                        ProgressView("Downloading and verifying model…")
                        Button("Cancel Download") { task.cancel() }
                    } else if download.installed {
                        Label("Ready to use", systemImage: "checkmark.circle")
                        Button("Remove Download", role: .destructive) { confirmRemoval = true }
                    } else {
                        Button("Download Model") { download.start() }
                    }
                    if let error = download.error {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .confirmationDialog("Remove the Curator model?", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("Remove Download", role: .destructive) { download.remove() }
            }
        }
    }
}

@MainActor
private final class CuratorDownloadState: ObservableObject {
    static let shared = CuratorDownloadState()

    @Published private(set) var installed = CuratorFallbackModel.installed
    @Published private(set) var task: Task<Void, Never>?
    @Published private(set) var error: String?

    func start() {
        guard task == nil, !installed else { return }
        error = nil
        task = Task {
            defer {
                installed = CuratorFallbackModel.installed
                task = nil
            }
            do {
                try await CuratorFallbackModel.download()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func remove() {
        error = nil
        do {
            try CuratorFallbackModel.removeDownload()
        } catch {
            self.error = error.localizedDescription
        }
        installed = CuratorFallbackModel.installed
    }
}
