// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Combine
import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

enum JITMethod: String, CaseIterable, Identifiable {
    case automatic
    case stikDebug
    case builtIn

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .stikDebug: return "StikDebug"
        case .builtIn: return "Built-in StikJIT"
        }
    }
}

/// Where Built-in StikJIT's pairing file came from.
enum JITPairingSource: String {
    /// Made by Madeira on this device (iOS 27, OnDevicePairing).
    case onDevice
    /// Imported from a file made on a computer.
    case imported
}

/// This iPhone's remote pairing file for Built-in StikJIT. It is a credential
/// for the device itself, so it lives in the Keychain (this device only, while
/// unlocked), as the Steam sign-in token does, and never in Documents, where
/// the Files app and every Windows program in Madeira could read it. Its bytes
/// go only to the bundled helper, over XPC, for one request. A copy an earlier
/// build left at Documents/StikJIT/pairingFile.plist moves into the Keychain
/// and is deleted; an installer that already holds this device's pairing file
/// (SideInstaller) hands it over by writing it there.
enum JITPairingFileStore {
    private static let service = "MadeiraJITPairing"
    private static let account = "rppairing"
    private static let sourceKey = "madeiraJITPairingSource"

    static var isImported: Bool { (try? data()) != nil }

    /// Files stored before on-device pairing existed were all imported.
    static var source: JITPairingSource? {
        guard isImported else { return nil }
        return UserDefaults.standard.string(forKey: sourceKey).flatMap(JITPairingSource.init(rawValue:)) ?? .imported
    }

    static func data() throws -> Data {
        moveLegacyFile()
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            throw NSError(domain: "MadeiraJIT", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "No pairing file is stored for this device."])
        }
        return data
    }

    static func importFile(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try store(try Data(contentsOf: source), source: .imported)
    }

    /// Validates an RPPairing plist and makes it the pairing file.
    static func store(_ data: Data, source: JITPairingSource) throws {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let publicKey = dictionary["public_key"] as? Data, publicKey.count == 32,
              let privateKey = dictionary["private_key"] as? Data, privateKey.count == 32,
              let identifier = dictionary["identifier"] as? String, !identifier.isEmpty else {
            throw NSError(domain: "MadeiraJIT", code: 10,
                          userInfo: [NSLocalizedDescriptionKey:
                            "That is not a StikDebug remote pairing file. Create one with iloader and try again."])
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(item as CFDictionary)
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "MadeiraJIT", code: 12,
                          userInfo: [NSLocalizedDescriptionKey:
                            "The pairing file could not be saved in the Keychain (\(status)). Unlock this device and try again."])
        }
        UserDefaults.standard.set(source.rawValue, forKey: sourceKey)
    }

    /// Documents/StikJIT/pairingFile.plist, where builds before the Keychain kept it,
    /// and where an installer leaves one for Madeira to take in.
    private static var legacyFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
    }

    private static func moveLegacyFile() {
        let manager = FileManager.default
        let file = legacyFolder.appendingPathComponent("pairingFile.plist")
        guard manager.fileExists(atPath: file.path), let data = try? Data(contentsOf: file) else { return }
        let kept = UserDefaults.standard.string(forKey: sourceKey).flatMap(JITPairingSource.init(rawValue:)) ?? .imported
        // Deleted only once the Keychain holds it (a locked device keeps it for later).
        if (try? store(data, source: kept)) != nil {
            try? manager.removeItem(at: file)
            if (try? manager.contentsOfDirectory(atPath: legacyFolder.path))?.isEmpty == true {
                try? manager.removeItem(at: legacyFolder)
            }
            LogStore.shared.log("[jit] pairing file moved from Documents into the Keychain")
        }
    }
}

@MainActor
final class JITCoordinator: ObservableObject {
    static let shared = JITCoordinator()

    enum CoordinatorError: LocalizedError {
        case setupRequired(String)
        case pairingMissing
        case scriptMissing

        var errorDescription: String? {
            switch self {
            case .setupRequired(let message): return message
            case .pairingMissing: return "Pair this device or import its pairing file first."
            case .scriptMissing: return "Madeira's JIT script is missing from this installation. Reinstall Madeira."
            }
        }
    }

    /// Why the built-in helper could not reach this device, read from its error.
    enum ConnectionProblem: Equatable {
        /// Nothing answered at LocalDevVPN's address: the VPN is off or not routing.
        case vpn
        /// The device closed the connection, usually because it no longer accepts this
        /// pairing (every new pairing replaces the last).
        case pairing

        init?(helperMessage: String) {
            let text = helperMessage.lowercased()
            let has = { (needles: [String]) in needles.contains(where: text.contains) }
            if has(["connectionreset", "connection reset", "device refused connection"]) {
                self = .pairing
            } else if has(["connectionrefused", "connection refused", "timedout", "timed out",
                           "networkunreachable", "network unreachable", "hostunreachable", "host unreachable", "no route"]) {
                self = .vpn
            } else {
                return nil
            }
        }

        var message: String {
            switch self {
            case .vpn:
                return MadeiraVPN.available
                    ? "Madeira couldn't reach this device through its VPN. Check Settings › VPN, then try again."
                    : "Madeira couldn't reach this device. Connect LocalDevVPN, then try again."
            case .pairing:
                return "This device closed the connection, which usually means it no longer accepts Madeira's pairing. Pair again, and check that \(LocalDevVPN.name) is connected."
            }
        }
    }

    @Published var method: JITMethod {
        didSet { UserDefaults.standard.set(method.rawValue, forKey: "madeiraJITMethod") }
    }
    @Published private(set) var connectionProblem: ConnectionProblem?
    /// What the last loopback check found (nil: none ran). A JIT failure after it found no
    /// lockdownd is a LocalDevVPN problem whatever the helper's message says: a network
    /// that accepts any connection makes the helper's read end early ("early eof").
    private var loopbackAnswered: Bool?
    @Published var showSetup = false
    var inlineSetupVisible = false
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var txmPresent: Bool?
    @Published private(set) var pairingImported = JITPairingFileStore.isImported
    @Published private(set) var pairingSource = JITPairingFileStore.source

    @Published var automaticStartup = UserDefaults.standard.object(forKey: "madeiraAutomaticJIT") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticStartup, forKey: "madeiraAutomaticJIT") }
    }
    private var enableCompletions: [(Result<Void, Error>) -> Void] = []
    private var pairingWait: AnyCancellable?
    /// This request already paired again after the device refused the stored pairing.
    private var repaired = false
    /// The user asked for this request (Play, Set up JIT): a refused pairing may be
    /// replaced on the spot, and LocalDevVPN opened to connect. Not so for the automatic
    /// start at launch, which would send the user to Settings or another app unasked;
    /// Play joining it makes it so.
    private var interactive = true
    private var activeWait: NSObjectProtocol?

    private init() {
        method = UserDefaults.standard.string(forKey: "madeiraJITMethod")
            .flatMap(JITMethod.init(rawValue:)) ?? .automatic
        // StikDebug stored before Automatic could stay in Madeira: Automatic now
        // takes the built-in helper whenever a pairing is stored, so move to it
        // once. StikDebug chosen again later stays.
        let movedKey = "madeiraJITMethodAutomaticV1"
        if !UserDefaults.standard.bool(forKey: movedKey) {
            UserDefaults.standard.set(true, forKey: movedKey)
            if method == .stikDebug {
                method = .automatic
                UserDefaults.standard.set(method.rawValue, forKey: "madeiraJITMethod")
                LogStore.shared.log("[jit] method StikDebug -> Automatic (built-in when paired)")
            }
        }
    }

    var resolvedMethod: JITMethod {
        guard method == .automatic else { return method }
        // An already paired, bundled helper avoids leaving the app for StikDebug.
        if MadeiraBuiltInJIT.isAvailable && JITPairingFileStore.isImported { return .builtIn }
        return StikJITHelper.isAvailable ? .stikDebug : .builtIn
    }

    var automaticDescription: String {
        resolvedMethod == .builtIn
            ? "Madeira uses its built-in helper and connects \(LocalDevVPN.name) when needed."
            : "StikDebug will enable JIT; \(LocalDevVPN.name) connects automatically when needed."
    }

    func refreshPairingStatus() {
        pairingImported = JITPairingFileStore.isImported
        pairingSource = JITPairingFileStore.source
    }

    /// `interactive`: see the property. The automatic start at launch passes false.
    func enable(interactive: Bool = true, completion: @escaping (Result<Void, Error>) -> Void) {
        // Play may arrive while automatic startup is already preparing JIT. Join the
        // same request rather than opening a second VPN/shortcut/helper session.
        if !enableCompletions.isEmpty {
            enableCompletions.append(completion)
            self.interactive = self.interactive || interactive
            return
        }
        guard !busy else {
            completion(.failure(CoordinatorError.setupRequired("JIT setup is already working. Wait for it to finish.")))
            return
        }
        enableCompletions = [completion]
        repaired = false
        self.interactive = interactive
        busy = true
        // An interrupted prior launch may still be restoring its network. Finish
        // that operation before starting another connection/shortcut request.
        JITNetworkShortcut.shared.restoreIfNeeded { [weak self] in
            self?.beginEnable { [weak self] result in
            guard let self else { return }
            self.busy = false
            if case .success = result { UserDefaults.standard.removeObject(forKey: Self.repairRefusedKey) }
            self.pairingWait?.cancel()
            self.pairingWait = nil
            let callbacks = self.enableCompletions
            self.enableCompletions.removeAll()
            callbacks.forEach { $0(result) }
            }
        }
    }

    private func beginEnable(completion: @escaping (Result<Void, Error>) -> Void) {
        guard SigningStatus.current.debuggable else {
            completion(.failure(NSError(
                domain: "MadeiraJIT", code: 11,
                userInfo: [NSLocalizedDescriptionKey: SigningStatus.notDebuggableMessage])))
            return
        }
        if StikJITHelper.ready {
            completion(.success(()))
            return
        }
        error = nil
        status = nil
        connectionProblem = nil
        // Built-in JIT with no pairing and no way to make one here (before iOS 27): say
        // so before connecting a VPN for nothing.
        if resolvedMethod == .builtIn, !JITPairingFileStore.isImported, !OnDevicePairing.isSupported {
            let message = "Import this device's pairing file to finish JIT setup."
            error = message
            if !inlineSetupVisible { showSetup = true }
            completion(.failure(CoordinatorError.setupRequired(message)))
            return
        }
        ensureLoopback(then: { [weak self] restoreOnFailure in
            self?.enableResolved { result in
                // Nothing will hold the network open now: put back what the shortcut changed.
                if restoreOnFailure, case .failure = result {
                    JITNetworkShortcut.shared.restoreIfNeeded {}
                }
                completion(result)
            }
        }, stopped: { [weak self] message in
            // The shortcut itself failed: say so (no connect action, which would only run
            // it again), skip a JIT attempt that cannot reach the device, and put back
            // whatever it changed before it stopped.
            self?.status = nil
            self?.error = message
            JITNetworkShortcut.shared.restoreIfNeeded {}
            completion(.failure(NSError(domain: "MadeiraJIT", code: 14,
                                        userInfo: [NSLocalizedDescriptionKey: message])))
        })
    }

    /// LocalDevVPN's loopback first (milliseconds when it already works). When it does
    /// not answer and the Madeira JIT shortcut is on, the shortcut turns Cellular Data
    /// off without Wi-Fi and connects LocalDevVPN, and the loopback is checked again
    /// while the VPN settles. JIT starts only after lockdownd answers through the
    /// local tunnel. `proceed`'s argument records whether the shortcut ran.
    private func ensureLoopback(then proceed: @escaping (Bool) -> Void, stopped: @escaping (String) -> Void) {
        let vpnWasUp = LoopbackProbe.vpnInterfaceUp
        LoopbackProbe.check { [weak self] probe in
            LogStore.shared.log(String(format: "[jit-loopback] %@ in %.0f ms (vpn-interface=%d, %@)",
                                       probe.reachable ? "reachable" : "unreachable", probe.milliseconds,
                                       vpnWasUp ? 1 : 0, probe.detail))
            self?.loopbackAnswered = probe.reachable
            guard let self else { return }
            guard !probe.reachable else { proceed(false); return }
            guard JITNetworkShortcut.shared.enabled else {
                status = "Connecting \(LocalDevVPN.name)…"
                LocalDevVPNControl.shared.connect(openingApps: self.interactive) { [weak self] result in
                    switch result {
                    case .success:
                        self?.loopbackAnswered = true
                        proceed(false)
                    case .failure(let failure):
                        self?.loopbackAnswered = false
                        self?.connectionProblem = .vpn
                        stopped(failure.localizedDescription)
                    }
                }
                return
            }
            status = "Running the \(JITNetworkShortcut.name) shortcut…"
            JITNetworkShortcut.shared.start { [weak self] outcome in
                if case .failed(let why) = outcome {
                    stopped("Your \(JITNetworkShortcut.name) shortcut stopped: \(why) Check its steps in Shortcuts, then try again.")
                    return
                }
                // LocalDevVPN's Connect returns before its tunnel routes (about 5 s
                // on the 18 Pro): go on the moment lockdownd answers.
                self?.status = "Waiting for LocalDevVPN…"
                let waitStart = CFAbsoluteTimeGetCurrent()
                LoopbackProbe.waitUntilReachable(within: 15) { [weak self] probe in
                    LogStore.shared.log(String(format: "[jit-loopback] after the shortcut: %@ after %.1f s (vpn-interface=%d, %@)",
                                               probe.reachable ? "reachable" : "unreachable",
                                               CFAbsoluteTimeGetCurrent() - waitStart,
                                               LoopbackProbe.vpnInterfaceUp ? 1 : 0, probe.detail))
                    self?.loopbackAnswered = probe.reachable
                    if probe.reachable { proceed(true) }
                    else { stopped(ConnectionProblem.vpn.message) }
                }
            }
        }
    }

    /// JIT setup's connect action with the Madeira JIT shortcut on: the shortcut connects
    /// LocalDevVPN (turning Cellular Data off without Wi-Fi); then the loopback is checked.
    func connectWithShortcut() {
        busy = true
        error = nil
        status = "Running the \(JITNetworkShortcut.name) shortcut…"
        JITNetworkShortcut.shared.start { [weak self] outcome in
            if case .failed(let why) = outcome {
                self?.busy = false
                self?.status = nil
                self?.error = "The \(JITNetworkShortcut.name) shortcut did not run: \(why)."
                return
            }
            LoopbackProbe.waitUntilReachable(within: 15) { [weak self] probe in
                self?.busy = false
                if probe.reachable {
                    self?.connectionProblem = nil
                    self?.status = "LocalDevVPN reaches this device."
                } else {
                    self?.status = nil
                    self?.error = ConnectionProblem.vpn.message
                }
            }
        }
    }

    private func enableResolved(_ completion: @escaping (Result<Void, Error>) -> Void) {
        switch resolvedMethod {
        case .automatic:
            assertionFailure("Automatic must resolve to a concrete JIT method")
        case .stikDebug:
            guard StikJITHelper.isAvailable else {
                let message = "StikDebug is not installed. Install it or choose Built-in StikJIT."
                error = message
                if !inlineSetupVisible { showSetup = true }
                completion(.failure(CoordinatorError.setupRequired(message)))
                return
            }
            busy = true
            status = "Waiting for StikDebug…"
            StikJITHelper.enableJIT { [weak self] result in
                Task { @MainActor in
                    self?.busy = false
                    self?.status = (try? result.get()).map { _ in "StikDebug is attached." }
                    if case .failure(let failure) = result { self?.error = failure.localizedDescription }
                    completion(result)
                }
            }
        case .builtIn:
            guard JITPairingFileStore.isImported else {
                if !inlineSetupVisible { showSetup = true }
                guard OnDevicePairing.isSupported else {
                    let message = "Import this device's pairing file to finish JIT setup."
                    error = message
                    completion(.failure(CoordinatorError.setupRequired(message)))
                    return
                }
                pairThenEnable(completion: completion)
                return
            }
            enableBuiltInRepairing(completion: completion)
        }
    }

    /// iOS must approve pairing. Keep the original Play request so the game starts
    /// after approval, without another Enable JIT tap.
    private func pairThenEnable(completion: @escaping (Result<Void, Error>) -> Void) {
        status = "Finish pairing in iOS Settings; JIT will continue when you return."
        pairingWait = OnDevicePairing.shared.$phase.dropFirst()
            .receive(on: DispatchQueue.main).sink { [weak self] phase in
                guard let self else { return }
                switch phase {
                case .paired:
                    self.pairingWait?.cancel(); self.pairingWait = nil
                    self.showSetup = false
                    // Settings is still in front: LocalDevVPN and the helper stall in
                    // the background, so JIT continues once Madeira is back.
                    self.whenActive { [weak self] in self?.beginEnable(completion: completion) }
                case .failed(let message):
                    self.error = message
                    completion(.failure(CoordinatorError.setupRequired(message)))
                case .idle:
                    completion(.failure(CoordinatorError.setupRequired("Pairing was cancelled.")))
                default: break
                }
            }
        // Already pairing: wait for that one. Nothing started and nothing will: say so now.
        guard OnDevicePairing.shared.start() || OnDevicePairing.shared.active else {
            pairingWait?.cancel(); pairingWait = nil
            let message = "Madeira could not start pairing. Try again in a moment."
            error = message
            completion(.failure(CoordinatorError.setupRequired(message)))
            return
        }
    }

    /// Built-in JIT with the stored pairing. A connection reset is tried once more
    /// (it can be transient); a second means the device refused the pairing, since
    /// each new pairing on a device replaces the last (pairing another app undoes
    /// Madeira's). Madeira then pairs again on the spot and keeps this request, so
    /// the game still starts once Settings approves, without another tap.
    /// A pairing made on the spot was refused as well: the resets come from something
    /// else, so later requests stop pairing again on their own until JIT works or the
    /// user pairs (Pair Again still offers it).
    private static let repairRefusedKey = "madeiraJITRepairRefused"

    private func enableBuiltInRepairing(retried: Bool = false, completion: @escaping (Result<Void, Error>) -> Void) {
        enableBuiltIn { [weak self] result in
            guard let self, case .failure = result, self.connectionProblem == .pairing else {
                completion(result); return
            }
            if !retried {
                LogStore.shared.log("[jit] connection reset: trying once more")
                self.busy = true
                self.status = "Retrying JIT…"
                // The retry's own failure decides; a stale .pairing must not discard a pairing
                // the device still accepts.
                self.connectionProblem = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    MainActor.assumeIsolated { self?.enableBuiltInRepairing(retried: true, completion: completion) }
                }
                return
            }
            if self.repaired {
                LogStore.shared.log("[jit] the new pairing was refused too: not pairing again on its own")
                UserDefaults.standard.set(true, forKey: Self.repairRefusedKey)
                completion(result); return
            }
            guard OnDevicePairing.isSupported, self.interactive,
                  !UserDefaults.standard.bool(forKey: Self.repairRefusedKey) else { completion(result); return }
            LogStore.shared.log("[jit] stored pairing refused: pairing again")
            self.repaired = true
            self.busy = true
            self.error = nil
            self.connectionProblem = nil
            if !self.inlineSetupVisible { self.showSetup = true }
            self.pairThenEnable(completion: completion)
        }
    }

    /// Runs `work` now when Madeira is in front, else when it next becomes active.
    private func whenActive(_ work: @escaping @MainActor () -> Void) {
        if let activeWait { NotificationCenter.default.removeObserver(activeWait) }
        activeWait = nil
        guard UIApplication.shared.applicationState != .active else { work(); return }
        activeWait = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let wait = self?.activeWait { NotificationCenter.default.removeObserver(wait) }
                self?.activeWait = nil
                work()
            }
        }
    }

    func importPairingFile(_ source: URL) {
        do {
            try JITPairingFileStore.importFile(from: source)
            OnDevicePairing.shared.cancel()
            refreshPairingStatus()
            status = "Pairing file imported."
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// OnDevicePairing finished: its file becomes the pairing file and Built-in StikJIT the method.
    func storeOnDevicePairing(_ data: Data) throws {
        try JITPairingFileStore.store(data, source: .onDevice)
        refreshPairingStatus()
        UserDefaults.standard.removeObject(forKey: Self.repairRefusedKey)
        method = .builtIn
        status = "Paired in Madeira."
        error = nil
        // Paired from Pair Again or setup with no Play waiting: switch JIT on once
        // Madeira is back in front, so the next game starts straight away.
        if pairingWait == nil, !busy, !StikJITHelper.ready {
            whenActive { [weak self] in self?.enable { _ in } }
        }
    }

    func prepareBuiltIn() {
        guard SigningStatus.current.debuggable else {
            error = SigningStatus.notDebuggableMessage
            return
        }
        guard MadeiraBuiltInJIT.isAvailable else {
            error = MadeiraBuiltInJIT.unavailableReason
            return
        }
        guard let pairing = try? JITPairingFileStore.data() else {
            error = CoordinatorError.pairingMissing.localizedDescription
            return
        }
        busy = true
        error = nil
        connectionProblem = nil
        status = "Checking LocalDevVPN and the Developer Disk Image…"
        MadeiraBuiltInJIT.send(.prepare(pairingData: pairing)) { [weak self] result in
            guard let self else { return }
            busy = false
            switch result {
            case .success(let response):
                txmPresent = response.txmPresent
                status = response.success ? response.message : nil
                error = response.success ? nil : helperFailure(response.message)
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }

    func enableBuiltIn(completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        guard MadeiraBuiltInJIT.isAvailable else {
            let failure = NSError(
                domain: "MadeiraJIT", code: 12,
                userInfo: [NSLocalizedDescriptionKey:
                    MadeiraBuiltInJIT.unavailableReason ?? "Built-in JIT is unavailable."])
            error = failure.localizedDescription
            completion(.failure(failure))
            return
        }
        guard let pairing = try? JITPairingFileStore.data() else {
            error = CoordinatorError.pairingMissing.localizedDescription
            completion(.failure(CoordinatorError.pairingMissing))
            return
        }
        guard let script = StikJITHelper.scriptData else {
            error = CoordinatorError.scriptMissing.localizedDescription
            completion(.failure(CoordinatorError.scriptMissing))
            return
        }

        busy = true
        error = nil
        status = "Starting Madeira's JIT helper…"
        var readinessTimer: Timer?
        var readinessFinished = false
        MadeiraBuiltInJIT.send(
            .enable(targetPID: getpid(), pairingData: pairing,
                    scriptBase64: script.base64EncodedString()),
            started: { [weak self] in
                self?.status = "Waiting for Madeira's JIT helper to attach…"
                readinessTimer = StikJITHelper.waitForDebugger { [weak self] result in
                    guard !readinessFinished else { return }
                    readinessFinished = true
                    self?.busy = false
                    switch result {
                    case .success:
                        self?.status = "Built-in JIT is attached."
                        self?.error = nil
                    case .failure(let failure):
                        self?.error = failure.localizedDescription
                    }
                    completion(result)
                }
            },
            completion: { [weak self] result in
                switch result {
                case .success(let response):
                    self?.txmPresent = response.txmPresent
                    LogStore.shared.log("[jit-built-in] \(response.message)",
                                        level: response.success ? .success : .error)
                    if !response.success && !readinessFinished, let self {
                        readinessFinished = true
                        readinessTimer?.invalidate()
                        busy = false
                        let message = helperFailure(response.message)
                        error = message
                        completion(.failure(NSError(
                            domain: "MadeiraJIT", code: 13,
                            userInfo: [NSLocalizedDescriptionKey: message])))
                    }
                case .failure(let failure):
                    if !readinessFinished {
                        readinessFinished = true
                        readinessTimer?.invalidate()
                        self?.busy = false
                        self?.error = failure.localizedDescription
                        completion(.failure(failure))
                    }
                }
            })
    }

    /// The helper's failure as shown: a connection problem gets its plain explanation
    /// (the helper's own message is already in the log).
    private func helperFailure(_ message: String) -> String {
        connectionProblem = ConnectionProblem(helperMessage: message) ?? (loopbackAnswered == false ? .vpn : nil)
        return connectionProblem?.message ?? message
    }

    func resetDDI() {
        busy = true
        error = nil
        status = "Resetting the Developer Disk Image cache…"
        MadeiraBuiltInJIT.send(.resetDDI) { [weak self] result in
            self?.busy = false
            switch result {
            case .success(let response):
                self?.status = response.success ? response.message : nil
                self?.error = response.success ? nil : response.message
            case .failure(let failure):
                self?.error = failure.localizedDescription
            }
        }
    }
}

/// LocalDevVPN, which built-in JIT and StikDebug reach the device through: open it to
/// connect when it is installed, otherwise its App Store page.
enum LocalDevVPN {
    static let appStore = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    /// `enable` connects the VPN; `scheme` has LocalDevVPN return to Madeira a second later.
    static let connect = URL(string: "localdevvpn://enable?scheme=madeira")!

    /// True with Madeira's own VPN in this build (MadeiraVPN), which stands in for it.
    static var isInstalled: Bool { MadeiraVPN.available || appInstalled }
    /// The LocalDevVPN app itself is installed.
    static var appInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!) }
    /// The VPN JIT goes through, as the user knows it.
    static var name: String { MadeiraVPN.available && !fellBack ? "Madeira's VPN" : "LocalDevVPN" }
    /// Madeira's VPN did not start and LocalDevVPN connected instead (LocalDevVPNControl).
    nonisolated(unsafe) static var fellBack = false
    static var actionTitle: String {
        MadeiraVPN.available ? "Connect Madeira's VPN" : isInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN"
    }

    static func open() {
        if MadeiraVPN.available {
            LogStore.shared.log("[jit] Madeira's VPN connect")
            MainActor.assumeIsolated { LocalDevVPNControl.shared.connect { _ in } }
            return
        }
        let installed = isInstalled
        LogStore.shared.log("[jit] LocalDevVPN \(installed ? "connect" : "app-store")")
        UIApplication.shared.open(installed ? connect : appStore)
    }
}

/// The fix a JIT connection problem offers: pair again (rejected pairing) and LocalDevVPN.
/// With the Madeira JIT shortcut on, LocalDevVPN is connected by the shortcut, never by
/// its link: `retry` enables JIT again (which runs the shortcut when the loopback does not
/// answer); without it the shortcut runs on its own.
@MainActor func jitConnectionActions(_ problem: JITCoordinator.ConnectionProblem,
                                     retry: (() -> Void)? = nil,
                                     then dismiss: @escaping () -> Void = {}) -> some View {
    Group {
        if problem == .pairing {
            Button(OnDevicePairing.isSupported ? "Pair Again" : "Open JIT Setup") {
                dismiss()
                if OnDevicePairing.isSupported { OnDevicePairing.shared.start() }
                JITCoordinator.shared.showSetup = true
            }
        }
        if JITNetworkShortcut.shared.enabled {
            Button("Connect with \(JITNetworkShortcut.name)") {
                dismiss()
                if let retry { retry() } else { JITCoordinator.shared.connectWithShortcut() }
            }
        } else {
            Button(LocalDevVPN.actionTitle) { dismiss(); LocalDevVPN.open() }
        }
    }
}

/// The normal path: one action connects the local tunnel, obtains any missing
/// pairing approval, and enables JIT. Advanced methods remain available separately.
struct JITQuickSetup: View {
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var vpn = LocalDevVPNControl.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var waitingForInstall = false
    @State private var ready = StikJITHelper.ready
    @State private var failure: String?
    var completed: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Madeira connects the local VPN and prepares JIT for you. After the first setup, just open a game.")
                .foregroundStyle(.secondary)
            row(LocalDevVPN.name, done: vpn.connected,
                detail: vpn.connected ? "Connected" : LocalDevVPN.isInstalled ? "Connects automatically" : "Install the free app once")
            row("This device", done: jit.pairingImported,
                detail: jit.pairingImported ? "Pairing saved securely"
                    : OnDevicePairing.isSupported ? "Approve pairing once when iOS asks"
                    : "Import this device's pairing file under Advanced")
            row("JIT", done: ready, detail: ready ? "Ready to play" : "Prepared automatically")
            if jit.busy {
                HStack { ProgressView(); Text(jit.status ?? "Preparing…") }
            }
            if pairing.active { OnDevicePairingPanel() }
            if let message = failure ?? jit.error, !jit.busy {
                Text(message).foregroundStyle(.orange).font(.callout)
                if let problem = jit.connectionProblem { jitConnectionActions(problem) }
            } else if let status = jit.status, !jit.busy {
                Text(status).foregroundStyle(.secondary).font(.callout)
            }
            Button(action: { if ready { completed?() } else { begin() } }) {
                Label(ready ? "Ready — continue" : waitingForInstall ? "Continue setup" : "Set up JIT",
                      systemImage: ready ? "checkmark.circle.fill" : "bolt.fill")
                    .fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(jit.busy || vpn.busy || (ready && completed == nil))
            .accessibilityIdentifier("jit.quickSetup")
            Text("If iOS asks, allow the VPN configuration and Local Network access. On Wi-Fi, no shortcut is needed.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onAppear { jit.inlineSetupVisible = true; jit.refreshPairingStatus(); vpn.refresh(); ready = StikJITHelper.ready }
        // A newer error, an import or a pairing replaces this view's own message.
        .onChange(of: jit.error) { _, _ in failure = nil }
        .onChange(of: jit.pairingImported) { _, _ in failure = nil }
        .onDisappear { jit.inlineSetupVisible = false }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                vpn.refresh()
                if waitingForInstall && LocalDevVPN.isInstalled { begin() }
            }
        }
    }

    private func row(_ title: String, done: Bool, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func begin() {
        failure = nil
        guard LocalDevVPN.isInstalled else {
            waitingForInstall = true
            UIApplication.shared.open(LocalDevVPN.appStore)
            return
        }
        waitingForInstall = false
        // The method, the shortcut and automatic start stay as the user set them: Automatic
        // already takes the built-in helper once a pairing is stored.
        jit.enable { result in
            switch result {
            case .success: ready = true; completed?()
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }
}

struct JITShortcutAdvanced: View {
    @ObservedObject private var shortcut = JITNetworkShortcut.shared
    var body: some View {
        Toggle("Use a network shortcut", isOn: $shortcut.enabled)
        Text("Optional for cellular-only connections or restoring another VPN. Normal Wi-Fi setup connects LocalDevVPN directly.")
            .font(.caption).foregroundStyle(.secondary)
        if shortcut.enabled, JITShortcutFile.supported, let url = JITShortcutFile.url {
            Button("Add Madeira JIT shortcut") { UIApplication.shared.open(JITShortcutFile.iCloudLink) }
            ShareLink("Import a local copy", item: url)
            Text("Allow its actions once in Shortcuts. It temporarily turns cellular data off and restores the previous network after JIT starts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct JITSettingsSection: View {
    @ObservedObject private var coordinator = JITCoordinator.shared
    @ObservedObject private var onboarding = OnboardingModel.shared
    var body: some View {
        Section("JIT") {
            Toggle("Prepare JIT automatically", isOn: $coordinator.automaticStartup)
            Button { coordinator.showSetup = true } label: {
                Label("Set up JIT", systemImage: "bolt.fill")
            }
            Text("Madeira connects \(LocalDevVPN.name) and prepares JIT when you open a game.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Advanced") {
                Picker("JIT method", selection: $coordinator.method) {
                    ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
                }
                JITShortcutAdvanced()
                if onboarding.available { Button("Run full setup again") { onboarding.rerun() } }
            }
        }
    }
}

struct JITSetupView: View {
    @ObservedObject private var coordinator = JITCoordinator.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @State private var importing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section { JITQuickSetup() }
                Section {
                    DisclosureGroup("Advanced setup & troubleshooting") {
                        Picker("Method", selection: $coordinator.method) {
                            ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
                        }
                        if OnDevicePairing.isSupported {
                            Button("Pair this device again") { pairing.start() }
                                .disabled(coordinator.busy || pairing.active)
                            if pairing.active { OnDevicePairingPanel() }
                        }
                        Button("Import pairing file") { importing = true }
                            .disabled(coordinator.busy)
                        Link("Pairing file instructions", destination: URL(string: "https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md")!)
                        Button("Enable selected JIT method") { coordinator.enable { _ in } }
                            .disabled(coordinator.busy)
                        JITShortcutAdvanced()
                        Button("Reset Developer Disk Image", role: .destructive) { coordinator.resetDDI() }
                            .disabled(coordinator.busy)
                        if let txm = coordinator.txmPresent { LabeledContent("TXM/SPTM", value: txm ? "Present" : "Not present") }
                    }
                }
            }
            .navigationTitle("Set up JIT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { coordinator.showSetup = false; dismiss() }
            } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .data]) { result in
            if case .success(let url) = result {
                coordinator.importPairingFile(url)
            } else if case .failure(let failure) = result {
                LogStore.shared.log("[jit-built-in] pairing import failed: \(failure.localizedDescription)", level: .error)
            }
        }
        .onAppear { coordinator.refreshPairingStatus() }
    }
}
