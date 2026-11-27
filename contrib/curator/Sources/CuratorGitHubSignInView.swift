// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct CuratorGitHubSignInView: View {
    @Environment(\.dismiss) private var dismiss
    let reporter: GitHubReporter
    @State private var code: GitHubReporter.DeviceCode?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let message = failure {
                    Text(message).foregroundStyle(TriptychPalette.warn)
                    Button("Try again") {
                        failure = nil
                        code = nil
                        attempt += 1
                    }
                } else if let code {
                    Text("Enter this code on GitHub to authorize Triptych.")
                    Text(code.userCode)
                        .font(.title.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("curator-device-code")
                    Link("Open github.com/login/device", destination: code.verificationURI)
                    ProgressView("Waiting for GitHub…")
                } else {
                    ProgressView("Requesting a GitHub code…")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { TriptychBackdrop() }
            .navigationTitle("Sign in with GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task(id: attempt) {
            do {
                let requested = try await reporter.startDeviceFlow()
                try Task.checkCancellation()
                code = requested
                try await reporter.pollForToken(requested)
                dismiss()
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}
