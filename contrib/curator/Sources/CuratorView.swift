// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct CuratorButton: View {
    var compact = false
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            if compact {
                Image(systemName: "stethoscope").accessibilityLabel("Curator")
            } else {
                Label("Curator", systemImage: "stethoscope")
            }
        }
        .accessibilityIdentifier("open-curator")
        .fullScreenCover(isPresented: $presented) { CuratorView() }
    }
}

struct CuratorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var result: Triage.Result?
    @State private var modelSummary: CuratorModel.Summary?
    @State private var applied: Set<String> = []
    @State private var pack = CuratorFixPack.bundled()
    @State private var working = false
    @State private var drafting = false
    @State private var summarizing = false
    @State private var work: Task<Void, Never>?
    @State private var restart: Triage.Finding?
    @State private var report: CuratorReport?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Button(action: check) {
                        Label(working ? "Checking logs…" : "Check my logs", systemImage: "stethoscope")
                    }
                    .buttonStyle(TriptychPrimaryButtonStyle(enabled: !working && !drafting))
                    .disabled(working || drafting)
                    .accessibilityIdentifier("curator-check")

                    if let result {
                        TriptychSectionHeader(title: "Findings", accent: TriptychPalette.macLight)
                        ForEach(result.findings) { finding in
                            findingCard(finding)
                        }
                        if summarizing {
                            TriptychPanelCard {
                                ProgressView("Reading the other errors on this device…")
                                    .accessibilityIdentifier("curator-summarizing")
                            }
                        }
                        if result.findings.isEmpty, modelSummary == nil, !working, !summarizing {
                            TriptychPanelCard {
                                Text(result.filesRead == 0 ? "No logs were available to check." : "No known failure matched the logs.")
                            }
                        }
                        if let modelSummary {
                            modelCard(modelSummary)
                        } else if result.findings.isEmpty, !working, !summarizing, result.filesRead > 0 {
                            reportButton(for: nil)
                        }
                    }
                }
                .padding(16)
                .triptychColumn()
            }
            .background { TriptychBackdrop() }
            .navigationTitle("Curator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Curator", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
            .confirmationDialog("Restart Triptych?", isPresented: Binding(get: { restart != nil }, set: { if !$0 { restart = nil } }),
                                titleVisibility: .visible, presenting: restart) { finding in
                Button("Restart", role: .destructive) { apply(finding) }
            } message: { finding in
                Text(finding.lever.instruction)
            }
            .fullScreenCover(item: $report) { item in
                CuratorReportView(report: item)
                    .onDisappear { item.removeAttachment() }
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { work?.cancel() }
    }

    private func findingCard(_ finding: Triage.Finding) -> some View {
        TriptychPanelCard(accent: finding.system?.panel.accent) {
            VStack(alignment: .leading, spacing: 8) {
                Text(finding.title).font(.headline)
                    .accessibilityIdentifier("curator-finding-\(finding.signature)")
                Text(finding.fromPreviousRun ? "\(finding.confidence.rawValue) · Previous run" : finding.confidence.rawValue)
                    .font(.caption).foregroundStyle(TriptychPalette.textSecondary)
                Text(finding.explanation)
                let fix = CuratorFixPack.fix(for: finding.signature, in: pack)
                if let fix {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fix: \(fix.title)").font(.subheadline.weight(.semibold))
                        Text(fix.summary).foregroundStyle(TriptychPalette.textSecondary)
                        Text(fix.changes.map { "\($0.key) → \($0.value.description)" }.joined(separator: "\n"))
                            .font(.caption.monospaced()).foregroundStyle(TriptychPalette.textSecondary)
                    }
                    .accessibilityIdentifier("curator-fix-\(fix.id)")
                } else {
                    Text(finding.lever.instruction).foregroundStyle(TriptychPalette.textSecondary)
                }
                HStack {
                    if let fix {
                        if CuratorFixPack.isApplied(fix) {
                            Button("Revert") {
                                CuratorFixPack.revert(fix)
                                applied.remove(finding.id)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("curator-revert-\(fix.id)")
                        } else {
                            Button("Apply fix") { apply(finding) }
                                .buttonStyle(.borderedProminent)
                                .disabled(drafting)
                                .accessibilityIdentifier("curator-apply-\(finding.signature)")
                        }
                    } else if finding.lever != .reportOnly {
                        Button(applied.contains(finding.id) ? "Applied" : "Apply") {
                            if case .restart = finding.lever {
                                restart = finding
                            } else {
                                apply(finding)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(applied.contains(finding.id) || drafting)
                        .accessibilityIdentifier("curator-apply-\(finding.signature)")
                    }
                    reportButton(for: finding)
                }
            }
            .font(.subheadline)
        }
    }

    private func modelCard(_ summary: CuratorModel.Summary) -> some View {
        TriptychPanelCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(result?.findings.isEmpty == false ? "Other errors in the logs" : "On-device summary").font(.headline)
                Text(summary.summary).accessibilityIdentifier("curator-model-summary")
                if !summary.likelyArea.isEmpty, summary.likelyArea != "Unknown" {
                    Text("Likely area · \(summary.likelyArea)").foregroundStyle(TriptychPalette.textSecondary)
                }
                ForEach(Array(summary.stepsTried.enumerated()), id: \.offset) { _, step in
                    Text(step).foregroundStyle(TriptychPalette.textSecondary)
                }
                if !summary.suggestedFix.isEmpty {
                    Label {
                        Text("Suggested fix · \(summary.suggestedFix)")
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver")
                    }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("curator-suggested-fix")
                }
                reportButton(for: nil)
            }
            .font(.subheadline)
        }
    }

    private func reportButton(for finding: Triage.Finding?) -> some View {
        Button(drafting ? "Preparing report…" : "Report") { prepareReport(finding) }
            .buttonStyle(.bordered)
            .disabled(drafting || working)
            .accessibilityIdentifier("curator-report-\(finding?.signature ?? "unmatched")")
    }

    private func check() {
        work?.cancel()
        working = true
        modelSummary = nil
        TriptychLog.log("curator", "checking Provenance logs")
        work = Task {
            defer { working = false }
            let checked = await Task.detached(priority: .userInitiated) {
                Triage.check(LogExport.collect())
            }.value
            guard !Task.isCancelled else { return }
            result = checked
            TriptychLog.log("curator", "checked \(checked.filesRead) files, found \(checked.findings.count) known failures")
            // The on-device model reads the error lines no rule matched, even when rules found something else.
            // Findings stay usable meanwhile; only the model's own card waits.
            if !checked.unmatchedExcerpt.isEmpty {
                working = false
                summarizing = true
                defer { summarizing = false }
                let summary = await CuratorModel.summarize(checked.unmatchedExcerpt)
                guard !Task.isCancelled else { return }
                modelSummary = summary
            }
        }
    }

    private func apply(_ finding: Triage.Finding) {
        guard !applied.contains(finding.id) else { return }
        if let fix = CuratorFixPack.fix(for: finding.signature, in: pack) {
            CuratorFixPack.apply(fix)
            applied.insert(finding.id)
            return
        }
        switch finding.lever {
        case .smallerCodeCache:
            UserDefaults.standard.set(512, forKey: JITBootstrap.codeCacheKey)
            TriptychLog.log("curator", "applied \(finding.signature): code cache 512 MB")
        case .enableJITAtLaunch:
            UserDefaults.standard.set(true, forKey: JITCoordinator.autoEnableKey)
            TriptychLog.log("curator", "applied \(finding.signature): JIT on launch enabled")
        case .restart(let system):
            TriptychLog.log("curator", "applied \(finding.signature): restart into \(system.rawValue)")
            Relaunch.restart(into: system)
        case .reportOnly:
            return
        }
        applied.insert(finding.id)
    }

    private func prepareReport(_ finding: Triage.Finding?) {
        guard let result, !drafting else { return }
        drafting = true
        let didApply = finding.map { applied.contains($0.id) } ?? false
        TriptychLog.log("curator", "preparing report for \(finding?.signature ?? "unmatched logs")")
        work = Task {
            defer { drafting = false }
            do {
                let prepared = try await CuratorReport.prepare(finding: finding, result: result, applied: didApply)
                guard !Task.isCancelled else { prepared.removeAttachment(); return }
                report = prepared
            } catch is CancellationError {
                return
            } catch {
                TriptychLog.log("curator", "report preparation failed")
                failure = "Curator could not prepare the report. \(error.localizedDescription)"
            }
        }
    }
}

private struct CuratorReportView: View {
    @Environment(\.dismiss) private var dismiss
    let report: CuratorReport
    private var reporter: GitHubReporter { CuratorUploadBridge.reporter }
    @State private var signedIn = false
    @State private var showingSignIn = false
    @State private var sending = false
    @State private var submitted: URL?
    @State private var failure: String?

    var body: some View {
        let shown = CuratorUploadBridge.scrubbed(report.draft)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Submitting sends this draft to the public GitHub issue tracker and includes the diagnostic attachment.")
                        .foregroundStyle(TriptychPalette.textSecondary)
                    if let sendMode {
                        Text(sendMode)
                            .foregroundStyle(TriptychPalette.textSecondary)
                            .accessibilityIdentifier("curator-send-mode")
                    }
                    TriptychPanelCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(shown.title).font(.headline).accessibilityIdentifier("curator-preview-title")
                            Text(shown.body).textSelection(.enabled).accessibilityIdentifier("curator-preview-body")
                            Text("Labels · \(shown.labels.joined(separator: ", "))")
                                .foregroundStyle(TriptychPalette.textSecondary)
                        }
                    }
                    DisclosureGroup(report.draft.logZipURL?.lastPathComponent ?? "Diagnostic attachment") {
                        Text(LogScrubber.scrub(report.diagnosticText))
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let failure {
                        Text(failure).foregroundStyle(TriptychPalette.warn).accessibilityIdentifier("curator-failure")
                    }
                    if let submitted {
                        Link("Open GitHub issue", destination: submitted).accessibilityIdentifier("curator-issue-link")
                    } else {
                        if sending {
                            ProgressView("Submitting…")
                        } else {
                            reportActions
                        }
                    }
                }
                .font(.subheadline)
                .padding(16)
                .triptychColumn()
            }
            .background { TriptychBackdrop() }
            .navigationTitle("Review report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(submitted == nil ? "Cancel" : "Done") { dismiss() }.disabled(sending)
                }
            }
        }
        .interactiveDismissDisabled(sending)
        .onAppear { signedIn = reporter.isSignedIn }
        .fullScreenCover(isPresented: $showingSignIn, onDismiss: { signedIn = reporter.isSignedIn }) {
            CuratorGitHubSignInView(reporter: reporter)
        }
    }

    /// How the report will be sent, from the current sign-in state (it changes after signing in on this sheet).
    private var sendMode: String? {
        if signedIn { return "Sending as your signed-in GitHub account." }
        if reporter.anonymousAvailable { return "Sending anonymously. No GitHub account or token is used." }
        if reporter.canSignInWithOAuth { return "Sign in with GitHub to send this report from your account." }
        return nil
    }

    @ViewBuilder private var reportActions: some View {
        if signedIn {
            Button("Send with my account") { submit(anonymous: false) }
                .buttonStyle(TriptychPrimaryButtonStyle(enabled: true))
                .accessibilityIdentifier("curator-send-account")
        } else if reporter.canSignInWithOAuth {
            Button("Sign in with GitHub") { showingSignIn = true }
                .buttonStyle(TriptychPrimaryButtonStyle(enabled: true))
                .accessibilityIdentifier("curator-sign-in")
        }
        if reporter.anonymousAvailable {
            Button("Send anonymously") { submit(anonymous: true) }
                .buttonStyle(TriptychPrimaryButtonStyle(enabled: true))
                .accessibilityIdentifier("curator-send-anonymous")
        } else if !signedIn && !reporter.canSignInWithOAuth {
            Text("Reporting is unavailable in this build. GitHub sign-in and the anonymous relay are both unconfigured.")
                .accessibilityIdentifier("curator-report-unavailable")
        }
    }

    private func submit(anonymous: Bool) {
        guard !sending, submitted == nil else { return }
        sending = true
        failure = nil
        TriptychLog.log("curator", "user confirmed GitHub report submission")
        Task {
            defer {
                signedIn = reporter.isSignedIn
                sending = false
            }
            do {
                submitted = try await CuratorUploadBridge.submit(report.draft, anonymous: anonymous)
                TriptychLog.log("curator", "report submitted")
            } catch {
                TriptychLog.log("curator", "report submission failed")
                failure = error.localizedDescription
            }
        }
    }
}
