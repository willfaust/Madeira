// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct CuratorReport: Identifiable {
    let id = UUID()
    let draft: IssueDraft
    let diagnosticText: String

    static func prepare(finding: Triage.Finding?, result: Triage.Result, applied: Bool) async throws -> Self {
        let title = finding?.title ?? "Triptych diagnostic report"
        let area = finding?.system?.title ?? "Unknown"
        let summary = finding?.explanation ?? "Curator found no known failure signature."
        let steps = applied ? ["Applied the suggested setting in Curator."] : []
        let version = DeviceInfo.ownInfo["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = DeviceInfo.ownInfo["CFBundleVersion"] as? String ?? "Unknown"
        // Reconstruct the attachment from matched signatures and fixed fields. Raw excerpts stay on device.
        let signatures = finding.map { [$0] } ?? result.findings
        let diagnosticText = ([
            "Triptych \(version) (\(build))",
        ] + DeviceInfo.contextLines() + [
            "Provenance logs checked: \(result.filesRead)",
        ] + signatures.map {
            "\($0.signature) | \($0.system?.rawValue ?? "unknown") | \($0.fromPreviousRun ? "previous run" : "current run")"
        }).joined(separator: "\n")
        let facts = [
            summary, "Likely area: \(area)", "Steps tried: \(steps.joined(separator: ", "))",
        ].joined(separator: "\n")
        let wording = await CuratorModel.wordReport(facts)
        try Task.checkCancellation()
        let body = """
            ## Summary

            \(wording?.summary ?? summary)

            ## Likely area

            \(area == "Unknown" ? (wording?.likelyArea ?? area) : area)

            ## Steps tried

            \(steps.isEmpty ? "No steps recorded." : steps.joined(separator: "\n"))

            ## Diagnostics

            \(diagnosticText)
            """
        let zip = try makeArchive(diagnosticText)
        let crashSignature = finding.map {
            CrashSignature(engine: $0.system?.rawValue ?? "unknown", targetExe: "unknown", canonicalCrashLine: $0.signature)
        }
        return Self(draft: IssueDraft(title: title, body: body, labels: ["curator"], logZipURL: zip,
                                      crashSignature: crashSignature),
                    diagnosticText: diagnosticText)
    }

    private static func makeArchive(_ text: String) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Triptych-logs-Curator-\(UUID())", isDirectory: true)
        let staging = root.appendingPathComponent("diagnostics", isDirectory: true)
        let zip = root.appendingPathComponent("Triptych-curator-logs.zip")
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: staging.appendingPathComponent("curator-diagnostics.txt"))
            try LogExport.zipDirectory(staging, to: zip)
            try fm.removeItem(at: staging)
            return zip
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    func removeAttachment() {
        guard let zip = draft.logZipURL else { return }
        try? FileManager.default.removeItem(at: zip.deletingLastPathComponent())
    }
}
