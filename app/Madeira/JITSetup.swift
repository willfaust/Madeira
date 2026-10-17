// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

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
                return "Madeira couldn't reach this device. Connect LocalDevVPN, then try again."
            case .pairing:
                return "This device closed the connection, which usually means it no longer accepts Madeira's pairing. Pair again, and check that LocalDevVPN is connected."
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
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var txmPresent: Bool?
    @Published private(set) var pairingImported = JITPairingFileStore.isImported
    @Published private(set) var pairingSource = JITPairingFileStore.source

    private init() {
        method = UserDefaults.standard.string(forKey: "madeiraJITMethod")
            .flatMap(JITMethod.init(rawValue:)) ?? .automatic
    }

    var resolvedMethod: JITMethod {
        guard method == .automatic else { return method }
        return StikJITHelper.isAvailable ? .stikDebug : .builtIn
    }

    var automaticDescription: String {
        StikJITHelper.isAvailable
            ? "StikDebug is installed, so Madeira will open it directly."
            : "StikDebug was not detected, so Madeira will use its built-in helper."
    }

    func refreshPairingStatus() {
        pairingImported = JITPairingFileStore.isImported
        pairingSource = JITPairingFileStore.source
    }

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
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
    /// while the VPN settles. Either way JIT is then attempted, so a failure still gets
    /// the usual explanation. `proceed`'s argument: the shortcut ran.
    private func ensureLoopback(then proceed: @escaping (Bool) -> Void, stopped: @escaping (String) -> Void) {
        let vpnWasUp = LoopbackProbe.vpnInterfaceUp
        LoopbackProbe.check { [weak self] probe in
            LogStore.shared.log(String(format: "[jit-loopback] %@ in %.0f ms (vpn-interface=%d, %@)",
                                       probe.reachable ? "reachable" : "unreachable", probe.milliseconds,
                                       vpnWasUp ? 1 : 0, probe.detail))
            self?.loopbackAnswered = probe.reachable
            guard let self, !probe.reachable, JITNetworkShortcut.shared.enabled else { proceed(false); return }
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
                    proceed(true)
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
                showSetup = true
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
                let message = "Pair this device or import its pairing file to finish Built-in StikJIT setup."
                error = message
                showSetup = true
                completion(.failure(CoordinatorError.setupRequired(message)))
                return
            }
            enableBuiltIn(completion: completion)
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
        method = .builtIn
        status = "Paired in Madeira."
        error = nil
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

    static var isInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!) }
    static var actionTitle: String { isInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN" }

    static func open() {
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

struct JITSettingsSection: View {
    @ObservedObject private var coordinator = JITCoordinator.shared
    @ObservedObject private var onboarding = OnboardingModel.shared
    @ObservedObject private var shortcut = JITNetworkShortcut.shared

    var body: some View {
        Section {
            Picker("JIT method", selection: $coordinator.method) {
                ForEach(JITMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            Button {
                coordinator.showSetup = true
            } label: {
                Label("JIT setup", systemImage: "bolt.badge.clock")
            }
            if onboarding.available {
                Button {
                    onboarding.rerun()
                } label: {
                    Label("Run setup again", systemImage: "wand.and.stars")
                }
            }
            if coordinator.method == .automatic {
                Text(coordinator.automaticDescription)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if JITShortcutFile.supported, let url = JITShortcutFile.url {
                Button {
                    LogStore.shared.log("[jit-shortcut] add: iCloud link")
                    UIApplication.shared.open(JITShortcutFile.iCloudLink)
                } label: {
                    Label("Add the \(JITNetworkShortcut.name) shortcut", systemImage: "plus.square.on.square")
                }
                ShareLink(item: url) {
                    Label("No internet connection? Add local copy", systemImage: "square.and.arrow.up")
                }
            }
            Toggle("\(JITNetworkShortcut.name) shortcut", isOn: $shortcut.enabled)
        } header: {
            Text("JIT")
        } footer: {
            Text("When LocalDevVPN can't reach this device, Enable JIT runs your \(JITNetworkShortcut.name) shortcut: it turns Cellular Data off when there's no Wi-Fi and connects LocalDevVPN, then puts both back once the game has started. Each run opens Shortcuts for a moment.")
        }
    }
}

struct JITSetupView: View {
    @ObservedObject private var coordinator = JITCoordinator.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @State private var importing = false
    @Environment(\.dismiss) private var dismiss

    private var pairingLabel: String {
        switch coordinator.pairingSource {
        case .onDevice: return "Paired in Madeira"
        case .imported: return "File imported"
        case nil: return "Not set up"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Method", selection: $coordinator.method) {
                        ForEach(JITMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    if coordinator.method == .automatic {
                        Text(coordinator.automaticDescription)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("StikDebug",
                                   value: StikJITHelper.isAvailable ? "Installed" : "Not detected")
                    LabeledContent("Built-in helper",
                                   value: MadeiraBuiltInJIT.isAvailable ? "Available" : "Unavailable")
                } header: {
                    Text("JIT method")
                } footer: {
                    Text("Automatic uses StikDebug when it is installed. Madeira does not silently change methods after a failure.")
                }

                if coordinator.method != .stikDebug {
                    Section {
                        LabeledContent("Pairing", value: pairingLabel)
                        if OnDevicePairing.isSupported {
                            Button(coordinator.pairingSource == .onDevice ? "Pair in Madeira again" : "Pair in Madeira") {
                                pairing.start()
                            }
                            .disabled(pairing.active)
                            OnDevicePairingPanel()
                        }
                        Button("Import pairing file") { importing = true }
                        Link("How to create a pairing file",
                             destination: URL(string: "https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md")!)
                        Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                    } header: {
                        Text("Built-in StikJIT")
                    } footer: {
                        Text(OnDevicePairing.isSupported
                             ? "Pair in Madeira or import a pairing file made on a computer, connect LocalDevVPN, then check setup. The pairing file is kept in this device's Keychain."
                             : "Import this device's pairing file, connect LocalDevVPN, then check setup. The pairing file is kept in this device's Keychain. Pairing in Madeira needs iOS 27 or later.")
                    }

                    Section {
                        Button("Check setup") { coordinator.prepareBuiltIn() }
                            .disabled(coordinator.busy || !coordinator.pairingImported)
                        Button("Enable JIT") { coordinator.enableBuiltIn() }
                            .disabled(coordinator.busy || !coordinator.pairingImported)
                        Button("Reset Developer Disk Image", role: .destructive) {
                            coordinator.resetDDI()
                        }.disabled(coordinator.busy)
                    }
                } else {
                    Section {
                        if StikJITHelper.isAvailable {
                            Button("Enable JIT with StikDebug") { coordinator.enable() { _ in } }
                        } else {
                            Link("Install StikDebug",
                                 destination: URL(string: "https://github.com/StikDebug/StikDebug/releases/latest")!)
                        }
                    } footer: {
                        Text("StikDebug needs a pairing file and an active LocalDevVPN connection. Madeira sends its own script automatically.")
                    }
                }

                if coordinator.busy {
                    Section { HStack { ProgressView(); Text(coordinator.status ?? "Working…") } }
                } else if let error = coordinator.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        if let problem = coordinator.connectionProblem { jitConnectionActions(problem) }
                    }
                } else if let status = coordinator.status {
                    Section { Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                if let txm = coordinator.txmPresent {
                    Section { LabeledContent("TXM/SPTM", value: txm ? "Present" : "Not present") }
                }
            }
            .navigationTitle("JIT setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { coordinator.showSetup = false; dismiss() }
                }
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.propertyList, .data]) { result in
            if case .success(let url) = result {
                coordinator.importPairingFile(url)
            } else if case .failure(let failure) = result {
                LogStore.shared.log("[jit-built-in] pairing import failed: \(failure.localizedDescription)",
                                    level: .error)
            }
        }
        .onAppear { coordinator.refreshPairingStatus() }
    }
}
