// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import Triptych

final class TriageTests: XCTestCase {
    // Scrubbed lines from Provenance device runs l3, l5, l8 and l9 (build/userlogs).
    private func fixture(_ name: String, as source: String) throws -> Triage.Result {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "txt"))
        return Triage.check([(url, source)])
    }

    // Excerpts of every Provenance bundle in build/userlogs, scrubbed with LogScrubber rules.
    // Each bundle is split into the source-name classes Triage cares about.
    private static let bundleSources: [(suffix: String, source: String)] = [
        ("current", "Documents__henge.log"),
        ("current-prev", "Documents__henge-prev.log"),
        ("serial", "AppSupport__WindowsPC__serial.log"),
        ("serial-prev", "AppSupport__WindowsPC__serial-prev.log"),
    ]

    private func findingIDs(bundle: String) throws -> [String] {
        let files = try Self.bundleSources.compactMap { suffix, source -> (url: URL, name: String)? in
            guard let url = Bundle(for: Self.self).url(forResource: "\(bundle)-\(suffix)", withExtension: "txt") else { return nil }
            return (url, source)
        }
        XCTAssertFalse(files.isEmpty, bundle)
        for file in files {
            let text = try String(contentsOf: file.url, encoding: .utf8)
            XCTAssertEqual(LogScrubber.scrub(text), text, "\(file.url.lastPathComponent) is not scrubbed")
        }
        return Triage.check(files).findings.map { $0.id + ($0.fromPreviousRun ? " (prev)" : "") }.sorted()
    }

    func testDeviceBundleFindings() throws {
        let expected: [String: [String]] = [
            "l3": ["jit-debugger-idle: (prev)", "jit-prewarm:", "jit-region:", "jit-required:macapps (prev)"],
            "l4": ["edk2-exception:winpc", "jit-debugger-idle: (prev)", "jit-prewarm:", "jit-region:", "jit-required:macapps (prev)", "windows-bugcheck:winpc"],
            "l5": ["edk2-exception:winpc", "jit-prewarm: (prev)", "jit-region: (prev)"],
            "l6": ["edk2-exception:winpc", "jit-prewarm: (prev)", "jit-region: (prev)", "mac-signature:macapps", "windows-bugcheck:winpc"],
            "l7": ["edk2-exception:winpc", "mac-signature:macapps", "windows-bugcheck:winpc (prev)"],
            "l8": ["edk2-exception:winpc (prev)", "linux-start:linux (prev)", "mac-signature:macapps (prev)", "windows-bugcheck:winpc"],
            "l9": ["edk2-exception:winpc (prev)", "mac-signature:macapps", "shared-launch:macos (prev)", "shared-launch:winpc", "windows-bugcheck:winpc (prev)"],
        ]
        for bundle in ["l3", "l4", "l5", "l6", "l7", "l8", "l9"] {
            let ids = try findingIDs(bundle: bundle)
            XCTAssertEqual(ids, expected[bundle], bundle)
        }
    }

    func testDeviceJITFailures() throws {
        let result = try fixture("jit-device", as: "Documents__henge-prev.log")
        XCTAssertEqual(result.filesRead, 1)
        let findings = Dictionary(uniqueKeysWithValues: result.findings.map { ($0.signature, $0) })
        XCTAssertEqual(findings["jit-region"]?.lever, .smallerCodeCache)
        XCTAssertEqual(findings["jit-prewarm"]?.lever, .reportOnly)
        XCTAssertEqual(findings["jit-required"]?.lever, .enableJITAtLaunch)
        XCTAssertTrue(result.findings.allSatisfy(\.fromPreviousRun))
    }

    func testDeviceLinuxStartAndSwitchTarget() throws {
        let result = try fixture("linux-and-switch-device", as: "Documents__Logs__triptych.log")
        XCTAssertEqual(result.findings.map(\.signature), ["linux-start", "shared-launch"])
        XCTAssertEqual(result.findings.last?.lever, .restart(.winpc))
    }

    func testDeviceFirmwareAndBugcheck() throws {
        let result = try fixture("windows-device", as: "AppSupport__WindowsPC__serial.log")
        XCTAssertEqual(Set(result.findings.map(\.signature)), ["edk2-exception", "windows-bugcheck"])
        XCTAssertTrue(result.findings.allSatisfy { $0.system == .winpc && $0.lever == .reportOnly })
    }

    func testDeviceHelperDriverAndFirmwareBootSignatures() throws {
        let result = try fixture("boot-and-helper-device", as: "AppSupport__WindowsPC__serial.log")
        let findings = Dictionary(uniqueKeysWithValues: result.findings.map { ($0.signature, $0) })
        XCTAssertEqual(Set(findings.keys), ["jit-debugger-idle", "windows-driver-load", "firmware-boot-timeout", "firmware-no-boot-disk"])
        XCTAssertEqual(findings["jit-debugger-idle"]?.lever, .enableJITAtLaunch)
        XCTAssertNil(findings["jit-prewarm"])
        XCTAssertEqual(findings["windows-driver-load"]?.fromPreviousRun, true)
        XCTAssertEqual(findings["windows-driver-load"]?.system, .winpc)
        XCTAssertEqual(findings["firmware-boot-timeout"]?.system, .winpc)
    }

    func testDeviceMacAppSignatureDenial() throws {
        let result = try fixture("macapps-device", as: "Documents__henge-native.log")
        XCTAssertEqual(result.findings.map(\.signature), ["mac-signature"])
        XCTAssertEqual(result.findings.first?.system, .macapps)
        XCTAssertEqual(result.findings.first?.confidence, .high)
    }

    func testCurrentMatchReplacesPreviousCopyAndKeepsUnmatchedEvidence() throws {
        let text = """
            [    15.63ms][prev] [macapps] Sample returned -1: Turn on JIT first.
            [    21.03ms][macapps] Sample returned -1: Turn on JIT first.
            Renderer reported an unknown error.
            """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = Triage.check([(file, "Documents__henge.log")])
        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(result.findings.first?.fromPreviousRun, false)
        XCTAssertEqual(result.unmatchedExcerpt, "Renderer reported an unknown error.")
    }

    func testReportPackagesOnlySelectedDiagnosticFacts() async throws {
        let match = try fixture("macapps-device", as: "Documents__henge-native.log")
        let result = Triage.Result(findings: match.findings, unmatchedExcerpt: "error in /Users/example/private", filesRead: 1)
        let report = try await CuratorReport.prepare(finding: result.findings.first, result: result, applied: false)
        defer { report.removeAttachment() }
        let url = try XCTUnwrap(report.draft.logZipURL)
        XCTAssertEqual(Array(try Data(contentsOf: url).prefix(2)), [0x50, 0x4b])
        let attachment = try XCTUnwrap(CuratorUploadBridge.logText(from: url))
        XCTAssertTrue(attachment.contains(report.diagnosticText))
        XCTAssertTrue(report.diagnosticText.contains("mac-signature | macapps | current run"))
        XCTAssertFalse(report.draft.body.contains("/Users/example"))
        XCTAssertFalse(report.diagnosticText.contains("/Users/example"))
    }
}
