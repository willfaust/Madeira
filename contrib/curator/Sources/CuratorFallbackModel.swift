// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import os
import UIKit

/// Loads a fresh context for each request. No weights or KV cache are retained between requests.
final class CuratorFallbackModel: @unchecked Sendable {
    static let shared = CuratorFallbackModel()
    static let minimumHeadroom = 1_280 << 20
    private static let modelSize = 396_705_472
    private static let modelSHA256 = "ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a"
    private static let modelName = "Qwen3-0.6B-Q4_K_M.gguf"
    private static let source = URL(string: "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/50968a4468ef4233ed78cd7c3de230dd1d61a56b/\(modelName)")!

    private let queue = DispatchQueue(label: "app.triptych.curator.llama", qos: .userInitiated)
    private let lock = NSLock()
    private var engineStarted = false
    private var activeRequest: Request?
    private var memoryWarning: NSObjectProtocol?

    private init() {
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.cancelInference()
        }
    }

    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var shouldContinue: Bool { lock.withLock { !cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private static var modelURL: URL {
        URL.applicationSupportDirectory.appending(path: "Curator/Models/\(modelName)")
    }

    /// Memory this process may still use. The Simulator has no per-app limit and reports 0, so it counts
    /// half the Mac's RAM there.
    static func availableMemory() -> Int {
        #if targetEnvironment(simulator)
        return Int(ProcessInfo.processInfo.physicalMemory / 2)
        #else
        return os_proc_available_memory()
        #endif
    }

    static var installed: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    static func canLoad(installed: Bool, engineStarted: Bool, availableMemory: Int) -> Bool {
        installed && !engineStarted && availableMemory >= minimumHeadroom
    }

    var available: Bool {
        lock.withLock {
            Self.canLoad(installed: Self.installed, engineStarted: engineStarted,
                         availableMemory: Self.availableMemory())
        }
    }

    /// Engines retain process-wide resources, so fallback inference stays disabled until relaunch.
    /// The queue barrier waits for an in-flight request to release its model before the engine starts.
    func prepareForEngineStart() {
        lock.withLock {
            engineStarted = true
            activeRequest?.cancel()
        }
        queue.sync {}
    }

    private func cancelInference() {
        lock.withLock { activeRequest?.cancel() }
    }

    func summarize(_ evidence: String, task: String) async -> CuratorModel.Summary? {
        let request = Request()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    guard activeRequest == nil, request.shouldContinue,
                          Self.canLoad(installed: Self.installed, engineStarted: engineStarted,
                                       availableMemory: Self.availableMemory()) else {
                        TriptychLog.log("curator", "offline model not started (installed \(Self.installed), engine started \(engineStarted), free memory \(Self.availableMemory() >> 20) MB)")
                        continuation.resume(returning: nil)
                        return
                    }
                    activeRequest = request
                    queue.async {
                        let result = Self.generate(evidence, task: task, request: request)
                        self.lock.withLock { self.activeRequest = nil }
                        continuation.resume(returning: request.shouldContinue ? result : nil)
                    }
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    private static func generate(_ evidence: String, task: String, request: Request) -> CuratorModel.Summary? {
        guard request.shouldContinue, Self.availableMemory() >= minimumHeadroom else { return nil }
        // Qwen's ChatML format with thinking disabled. Neutralize marker delimiters in diagnostic data.
        let excerpt = String(decoding: evidence.utf8.prefix(1_200), as: UTF8.self)
            .replacingOccurrences(of: "<|", with: "< |")
            .replacingOccurrences(of: "\0", with: "")
        let prompt = """
            <|im_start|>system
            You assist with Triptych diagnostics. Do not invent facts.
            \(task)
            Remedies:
            \(CuratorModel.remedyList)
            Answer in exactly two lines:
            Summary: <one or two short sentences>
            Fix: <the number of the best remedy><|im_end|>
            <|im_start|>user
            Diagnostic data:
            \(excerpt)<|im_end|>
            <|im_start|>assistant
            <think>

            </think>

            """ + "\n"
        var output = [CChar](repeating: 0, count: 4096)
        let completed = curator_llama_generate(modelURL.path, prompt, { pointer in
            guard let pointer else { return false }
            return Unmanaged<Request>.fromOpaque(pointer).takeUnretainedValue().shouldContinue
        }, Unmanaged.passUnretained(request).toOpaque(), &output, output.count)
        guard completed, let text = String(validatingUTF8: output) else {
            TriptychLog.log("curator", "offline model produced no answer")
            return nil
        }
        return parse(text)
    }

    /// Splits the "Summary:" / "Fix:" answer. A missing Fix line falls back to the Report remedy.
    static func parse(_ text: String) -> CuratorModel.Summary? {
        var summary = "", fix = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("fix:") {
                fix = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("summary:") {
                summary = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if fix.isEmpty, !trimmed.isEmpty {
                summary += (summary.isEmpty ? "" : " ") + trimmed
            }
        }
        guard !summary.isEmpty else { return nil }
        return CuratorModel.Summary(summary: summary, likelyArea: "Unknown", stepsTried: [],
                                    suggestedFix: CuratorModel.matchRemedy(fix))
    }

    static func download() async throws {
        let (temporary, response) = try await URLSession.shared.download(from: source)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.server }
        try verifyModel(at: temporary, expectedSize: modelSize, sha256: modelSHA256)
        try Task.checkCancellation()

        let destination = modelURL
        var directory = destination.deletingLastPathComponent()
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try directory.setResourceValues(properties)
        // The checked file is published only after verification finishes.
        try files.moveItem(at: temporary, to: destination)
    }

    static func verifyModel(at url: URL, expectedSize: Int, sha256: String) throws {
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == expectedSize else {
            throw DownloadError.integrity
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == sha256 else { throw DownloadError.integrity }
    }

    static func removeDownload() throws {
        try FileManager.default.removeItem(at: modelURL)
    }

    private enum DownloadError: LocalizedError {
        case server, integrity

        var errorDescription: String? {
            switch self {
            case .server: return "Hugging Face could not serve the model. Try again later."
            case .integrity: return "The model download failed verification. Try downloading it again."
            }
        }
    }
}
