// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// The private NSExtension API (ExtensionFoundation) that starts an app extension of
/// Madeira's own: the same calls LiveContainer uses to start its LiveProcess.
@objc private protocol NSExtensionClassShim {
    @objc(extensionWithIdentifier:error:)
    func `extension`(withIdentifier identifier: String) throws -> AnyObject
}

@objc private protocol NSExtensionShim {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func beginExtensionRequest(withInputItems items: [Any], completion: @escaping (NSUUID?) -> Void)
    @objc(pidForRequestIdentifier:)
    func pid(forRequestIdentifier identifier: NSUUID) -> Int32
    @objc(setRequestCompletionBlock:)
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void)
    @objc(setRequestCancellationBlock:)
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void)
    @objc(setRequestInterruptionBlock:)
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void)
}

/// Starts the separate helper process required to debug Madeira without
/// deadlocking Madeira itself.
///
/// The helper is a classic app extension (PlugIns/MadeiraJITHelper.appex, on
/// com.apple.ar.viewer as LiveContainer's LiveProcess is), started by the bundle ID it
/// has in this installation. Sideloaders that sign with the user's own Apple ID rename
/// Madeira's bundle ID and the helper's along with it (SideStore, AltStore and Plume
/// append the team ID), and that is all this lookup needs. An ExtensionKit extension
/// point, which the helper used before, is named in files sideloaders do not rewrite, so
/// iOS registered none for a renamed Madeira ("Failed to add observer").
///
/// One extension request per MadeiraJITRequest: the request goes as JSON in the input
/// item's userInfo, and the helper completes the request with the JSON response in the
/// returned item's userInfo. Log tag: [jit-helper].
@MainActor
enum MadeiraBuiltInJIT {
    static let helperFile = "MadeiraJITHelper.appex"

    /// Requests that have started and not finished, kept alive until they do.
    private static var running: [HelperRequest] = []

    static var unavailableReason: String? {
#if targetEnvironment(simulator)
        return "Built-in JIT is available only on a physical device."
#else
        guard #available(iOS 26.0, *) else {
            return "Built-in JIT requires iOS 26 or later."
        }
        if getenv("LC_HOME_PATH") != nil {
            return "Built-in JIT is unavailable inside LiveContainer. Choose StikDebug instead."
        }
        return nil
#endif
    }

    static var isAvailable: Bool { unavailableReason == nil }

    /// The helper's bundle ID in this installation, read from its own Info.plist; nil when
    /// a sideloader left it out.
    static var helperIdentifier: String? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(helperFile) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    static func send(_ request: MadeiraJITRequest,
                     started: @escaping () -> Void = {},
                     completion: @escaping (Result<MadeiraJITRequest.Response, Error>) -> Void) {
        func fail(_ code: Int, _ message: String) {
            LogStore.shared.log("[jit-helper] \(message)", level: .error)
            completion(.failure(NSError(domain: "MadeiraBuiltInJIT", code: code,
                                        userInfo: [NSLocalizedDescriptionKey: message])))
        }
        guard unavailableReason == nil else {
            fail(1, unavailableReason ?? "Built-in JIT is unavailable.")
            return
        }
        guard let identifier = helperIdentifier else {
            fail(2, "Madeira's JIT helper is missing from this installation. Reinstall Madeira, and keep its app extensions if your sideloader asks.")
            return
        }
        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let extensionClass = NSClassFromString("NSExtension") else {
            fail(3, "iOS did not provide the extension API Madeira's JIT helper needs.")
            return
        }
        let factory = unsafeBitCast(extensionClass as AnyObject, to: NSExtensionClassShim.self)
        let found: AnyObject
        do { found = try factory.extension(withIdentifier: identifier) }
        catch {
            fail(2, "Madeira's JIT helper (\(identifier)) could not be found: \(error.localizedDescription) Reinstall Madeira.")
            return
        }
        guard let data = try? JSONEncoder().encode(request) else {
            fail(4, "The request for Madeira's JIT helper could not be encoded.")
            return
        }
        let helper = HelperRequest(extension: found, operation: request.operation.rawValue, completion: completion)
        running.append(helper)
        helper.begin(data: data, identifier: identifier, started: started)
    }

    fileprivate static func finished(_ helper: HelperRequest) {
        running.removeAll { $0 === helper }
    }
}

/// One request to the helper, from its start to its one result.
@MainActor
private final class HelperRequest {
    private let shim: NSExtensionShim
    private let `extension`: AnyObject   // the NSExtension, kept alive for the request
    private let operation: String
    private var completion: ((Result<MadeiraJITRequest.Response, Error>) -> Void)?

    init(extension found: AnyObject, operation: String,
         completion: @escaping (Result<MadeiraJITRequest.Response, Error>) -> Void) {
        self.extension = found
        self.shim = unsafeBitCast(found, to: NSExtensionShim.self)
        self.operation = operation
        self.completion = completion
    }

    func begin(data: Data, identifier: String, started: @escaping () -> Void) {
        // The blocks can arrive on any queue; everything below runs on the main thread.
        shim.setRequestCompletionBlock { [weak self] _, items in
            let info = (items?.first as? NSExtensionItem)?.userInfo
            let payload = info?[MadeiraJITRequest.Response.itemKey] as? Data
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.returned(payload) } }
        }
        shim.setRequestCancellationBlock { [weak self] _, error in
            let message = error?.localizedDescription ?? "the request was cancelled"
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.end(.failure(Self.error(5, "Madeira's JIT helper stopped: \(message)")))
            } }
        }
        shim.setRequestInterruptionBlock { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.end(.failure(Self.error(6, "Madeira's JIT helper stopped unexpectedly. Try again.")))
            } }
        }
        let item = NSExtensionItem()
        item.userInfo = [MadeiraJITRequest.itemKey: data]
        shim.beginExtensionRequest(withInputItems: [item]) { [weak self] uuid in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                guard let uuid else {
                    self.end(.failure(Self.error(7, "Madeira's JIT helper did not start. Reinstall Madeira, and keep its app extensions if your sideloader asks.")))
                    return
                }
                LogStore.shared.log("[jit-helper] \(self.operation): started \(identifier) as pid \(self.shim.pid(forRequestIdentifier: uuid))")
                started()
            } }
        }
    }

    private func returned(_ payload: Data?) {
        guard let payload, let response = try? JSONDecoder().decode(MadeiraJITRequest.Response.self, from: payload) else {
            end(.failure(Self.error(8, "Madeira's JIT helper finished without an answer.")))
            return
        }
        LogStore.shared.log("[jit-helper] \(operation): finished success=\(response.success ? 1 : 0)")
        end(.success(response))
    }

    private func end(_ result: Result<MadeiraJITRequest.Response, Error>) {
        guard let completion else { return }   // the first result counts
        self.completion = nil
        if case .failure(let error) = result {
            LogStore.shared.log("[jit-helper] \(operation): \(error.localizedDescription)", level: .error)
        }
        MadeiraBuiltInJIT.finished(self)
        completion(result)
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "MadeiraBuiltInJIT", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// ml1310: the opt-in extension-process probe (docs/PROCESS_MODEL_ML1310.md). With
/// env.MADEIRA_EXT_PROBE = 1 in madeira.cfg, each session start asks the JIT helper
/// extension what its own process may map and logs the answer as "[ext-probe] ml1310 ...".
/// Read-only in the helper; it needs no pairing file and never waits behind JIT.
@MainActor
enum MadeiraExtensionProbe {
    static func runIfRequested() {
        // MADEIRA_EXT_PROBE=1: at session start the JIT helper extension reports the address space and memory limit its own process gets (ml1310 feasibility probe for extension processes)
        guard MadeiraConfig.flag("MADEIRA_EXT_PROBE", fallback: false) else { return }
        if let reason = MadeiraBuiltInJIT.unavailableReason {
            LogStore.shared.log("[ext-probe] ml1310 skipped: \(reason)")
            return
        }
        LogStore.shared.log("[ext-probe] ml1310 asking the helper extension")
        MadeiraBuiltInJIT.send(.probe) { result in
            switch result {
            case .success(let response):
                LogStore.shared.log("[ext-probe] ml1310 \(response.message)")
            case .failure(let error):
                LogStore.shared.log("[ext-probe] ml1310 failed: \(error.localizedDescription)", level: .error)
            }
        }
    }
}
