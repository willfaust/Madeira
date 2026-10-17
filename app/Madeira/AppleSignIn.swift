// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

// Apple ID sign-in for the signing refresh (SigningRefresh.swift; docs/JIT.md,
// "Refreshing the signing"), for a copy no installer left a sign-in for, or whose
// sign-in Apple no longer takes.
//
// The sign-in is isideload's, the library SideInstaller and iloader sign in with
// (madeira_apple_sign_in, build/rppairing-ios/src/apple_id.rs): Apple's SRP exchange,
// in which the password does not leave the device, then the second factor. What comes
// back is what an installer hands over: the developer-portal token and the anisette
// identity it was issued to. Those go into the Keychain (SigningAccountStore); the
// password is not kept. An anisette server supplies the device data Apple asks for,
// and sees neither the Apple ID nor the password.
//
// Log tag: [signing] (how a sign-in ended, never the Apple ID, a code or a token).

// MARK: - The second factor

/// What a sign-in is waiting for, as the library describes it.
struct TwoFactorPrompt: Decodable, Equatable {
    enum Method: String, Decodable {
        /// A code went to the account's trusted Apple devices.
        case device
        /// A code was texted to the selected number.
        case sms
        /// The last way failed and no code is on its way, so the user picks one.
        case choose
    }

    struct Number: Decodable, Equatable, Identifiable {
        let id: UInt32
        /// Masked by Apple, as in "+39 ••• ••• ••89".
        let number: String
        /// "sms" or "voice", or empty when Apple does not say. A voice-only number,
        /// such as a landline, cannot take a text.
        let pushMode: String

        var takesTexts: Bool { pushMode != "voice" }
    }

    let method: Method
    let selectedNumberId: UInt32?
    let lastError: String?
    let numbers: [Number]

    /// For a request that cannot be read: the one prompt that always makes sense.
    static let deviceOnly = TwoFactorPrompt(method: .device, selectedNumberId: nil, lastError: nil, numbers: [])

    var selectedNumber: Number? { numbers.first { $0.id == selectedNumberId } }
    /// Whether a code is on its way, so the sheet asks for it.
    var expectsCode: Bool { method != .choose }

    static func read(_ json: String) -> TwoFactorPrompt {
        (try? JSONDecoder().decode(TwoFactorPrompt.self, from: Data(json.utf8))) ?? deviceOnly
    }
}

/// The user's answer, as the library reads it.
enum TwoFactorAnswer: Equatable {
    case code(String)
    case sms(UInt32)
    case devices
    case resend

    var json: String {
        let object: [String: Any]
        switch self {
        case .code(let code): object = ["action": "code", "code": code]
        case .sms(let id): object = ["action": "sms", "id": id]
        case .devices: object = ["action": "devices"]
        case .resend: object = ["action": "resend"]
        }
        return (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// Carries the second factor between the sign-in's thread, which blocks until the user
/// has answered, and the sheet.
private final class SecondFactor: @unchecked Sendable {
    private let lock = NSLock()
    private let answered = DispatchSemaphore(value: 0)
    private var waiting = false
    private var answer: TwoFactorAnswer?
    private var abandoned = false
    /// Shows the prompt. Called on the sign-in's thread.
    var ask: (@Sendable (TwoFactorPrompt) -> Void)?

    /// On the sign-in's thread: the user's answer, or nil when they gave up.
    func wait(for prompt: TwoFactorPrompt) -> TwoFactorAnswer? {
        lock.lock()
        if abandoned {
            lock.unlock()
            return nil
        }
        waiting = true
        answer = nil
        lock.unlock()
        ask?(prompt)
        answered.wait()
        lock.lock()
        defer { lock.unlock() }
        return answer
    }

    /// Hands the waiting sign-in its answer; nil gives up. Returns whether one waited.
    @discardableResult
    func give(_ answer: TwoFactorAnswer?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard waiting else { return false }
        waiting = false
        self.answer = answer
        answered.signal()
        return true
    }

    /// The sheet is gone: a prompt, now or later, is answered by giving up.
    func abandon() {
        lock.lock()
        abandoned = true
        lock.unlock()
        give(nil)
    }
}

private let secondFactorCallback: MadeiraAppleTwoFactorCallback = { context, request, reply, capacity in
    guard let context, let reply, capacity > 1 else { return 0 }
    let bridge = Unmanaged<SecondFactor>.fromOpaque(context).takeUnretainedValue()
    let prompt = request.map { TwoFactorPrompt.read(String(cString: $0)) } ?? .deviceOnly
    guard let bytes = bridge.wait(for: prompt).map({ Array($0.json.utf8) }), bytes.count < capacity else { return 0 }
    reply.withMemoryRebound(to: UInt8.self, capacity: capacity) { buffer in
        for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        buffer[bytes.count] = 0
    }
    return 1
}

// MARK: - The sign-in

/// One Apple ID sign-in, from the credentials to a `SigningAccount` in the Keychain.
@MainActor final class AppleSignIn: ObservableObject {
    enum Phase: Equatable {
        case entering
        /// Apple or the anisette server is being asked.
        case working
        case twoFactor(TwoFactorPrompt)
        /// The user answered and the sign-in is acting on it.
        case answering(TwoFactorPrompt, TwoFactorAnswer)
        case done
    }

    /// Anisette servers from the community list SideStore and SideInstaller read
    /// (servers.sidestore.io), tried in this order. The two on Apple's library for
    /// Windows (win.ani.sidestore.io, ani.jkcoxson.com) are left out: Apple has a
    /// new machine of theirs resynced first, which isideload 0.4.4 cannot do
    /// (`NEEDS_RESYNC` in apple_id.rs).
    nonisolated static let anisetteServers = [
        "https://ani.sidestore.io", "https://ani.stikstore.app", "https://ani.npeg.us",
        "https://ani.sidestore.app", "https://ani.sidestore.zip", "https://ani.846969.xyz",
    ]
    /// How many a sign-in tries, and a `SigningAccount` keeps.
    nonisolated static let serverLimit = 6

    @Published private(set) var phase: Phase = .entering
    @Published private(set) var failure: String?
    private var secondFactor: SecondFactor?

    var working: Bool { phase != .entering && phase != .done }

    /// What the library returns for a sign-in that worked.
    struct Answer: Equatable {
        struct Team: Equatable {
            let id: String
            let name: String
        }

        var adsID: String
        var token: String
        var tokenExpires: Date?
        var anisetteIdentifier: Data
        var anisetteProvisioning: Data
        var teams: [Team]

        init?(json: String) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
                  let adsID = object["adsID"] as? String, let token = object["token"] as? String,
                  let identifier = (object["anisetteIdentifier"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let provisioning = (object["anisetteProvisioning"] as? String).flatMap({ Data(base64Encoded: $0) })
            else { return nil }
            self.adsID = adsID
            self.token = token
            tokenExpires = (object["tokenExpires"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            anisetteIdentifier = identifier
            anisetteProvisioning = provisioning
            teams = (object["teams"] as? [[String: Any]] ?? []).compactMap { team in
                (team["id"] as? String).map { Team(id: $0, name: team["name"] as? String ?? "") }
            }
        }

        /// The sign-in Madeira keeps, for the team this copy was signed by: a profile
        /// from any other team does not renew it.
        func account(appleID: String, signedBy team: String?, through servers: [String]) throws -> SigningAccount {
            guard let team else { throw Failure.failed("This copy of Madeira has no provisioning profile to renew.") }
            guard teams.contains(where: { $0.id == team }) else {
                throw Failure.failed("That is not the Apple ID this copy of Madeira was signed with (team \(team)). "
                    + "Sign in with the Apple ID it was installed with.")
            }
            let account = SigningAccount(version: SigningAccount.version, teamID: team, adsID: adsID, token: token,
                                         tokenExpires: tokenExpires, anisetteIdentifier: anisetteIdentifier,
                                         anisetteProvisioning: anisetteProvisioning, anisetteServers: servers, appleID: appleID)
            guard account.usable else { throw Failure.failed("Apple's answer held no sign-in Madeira can use.") }
            return account
        }
    }

    enum Failure: LocalizedError, Equatable {
        case cancelled
        /// No anisette server gave an identity Apple takes.
        case anisette(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return nil
            case .anisette(let why): return "No anisette server gave an answer Apple takes (\(why)). Try again later."
            case .failed(let why): return why
            }
        }
    }

    /// The servers a sign-in tries: those of the sign-in Madeira already holds first,
    /// since its identity came through them, then the list.
    nonisolated static func servers(after known: [String]) -> [String] {
        var seen = Set<String>()
        return Array((known + anisetteServers).filter { URL(string: $0)?.scheme == "https" && seen.insert($0).inserted }
            .prefix(serverLimit))
    }

    func start(appleID: String, password: String) {
        let appleID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .entering, !appleID.isEmpty, !password.isEmpty else { return }
        let bridge = SecondFactor()
        bridge.ask = { [weak self, weak bridge] prompt in
            Task { @MainActor in
                if let bridge { self?.asked(prompt, by: bridge) }
            }
        }
        secondFactor = bridge
        failure = nil
        phase = .working
        // The identity of a sign-in Apple already trusts is signed in as again: with
        // it, Apple seldom asks for the second factor a second time.
        let held = SigningAccountStore.load()
        let team = SigningProfile.embedded?.teamID
        LogStore.shared.log("[signing] sign-in started identity=\(held == nil ? "new" : "kept")")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> SigningAccount in
                let signed = try Self.signIn(appleID: appleID, password: password, held: held, bridge: bridge)
                return try signed.answer.account(appleID: appleID, signedBy: team,
                                                 through: Self.servers(after: [signed.server] + (held?.anisetteServers ?? [])))
            }
            Task { @MainActor [weak self] in self?.finished(result, for: bridge) }
        }
    }

    /// Blocking: one sign-in per anisette server until one gives an identity Apple
    /// takes. Apple hears the password's proof once, from the first that does.
    nonisolated private static func signIn(appleID: String, password: String, held: SigningAccount?,
                                           bridge: SecondFactor) throws -> (answer: Answer, server: String) {
        // The held identity gets its own two servers, then a new one gets them all.
        var attempts = held.map { held in servers(after: held.anisetteServers).prefix(2).map { ($0, Optional(held)) } } ?? []
        attempts += servers(after: []).map { ($0, nil) }
        var failure = Failure.anisette("none was tried")
        let context = Unmanaged.passUnretained(bridge).toOpaque()
        for (server, identity) in attempts {
            var result: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let identifier = identity.map { [UInt8]($0.anisetteIdentifier) }
            let provisioning = identity.map { [UInt8]($0.anisetteProvisioning) }
            let code = madeira_apple_sign_in(appleID, password, server, identifier, identifier?.count ?? 0,
                                             provisioning, provisioning?.count ?? 0, secondFactorCallback, context, &result, &error)
            let answer = result.map { String(cString: $0) }
            let why = error.map { String(cString: $0) } ?? "no reason given"
            madeira_rppairing_string_free(result)
            madeira_rppairing_string_free(error)
            switch code {
            case 0:
                guard let answer = answer.flatMap(Answer.init(json:)) else { throw Failure.failed("Apple's answer held no sign-in Madeira can use.") }
                return (answer, server)
            case 1: throw Failure.cancelled
            case 2: failure = .anisette(why)
            default: throw Failure.failed(why)
            }
        }
        throw failure
    }

    private func asked(_ prompt: TwoFactorPrompt, by bridge: SecondFactor) {
        guard secondFactor === bridge else { return }
        phase = .twoFactor(prompt)
    }

    func answer(_ answer: TwoFactorAnswer) {
        guard case .twoFactor(let prompt) = phase, secondFactor?.give(answer) == true else { return }
        phase = .answering(prompt, answer)
    }

    /// The sheet was closed. A sign-in that is under way ends at its next prompt, and
    /// what it brings back is dropped.
    func cancel() {
        secondFactor?.abandon()
        secondFactor = nil
        if phase != .done { phase = .entering }
    }

    private func finished(_ result: Result<SigningAccount, Error>, for bridge: SecondFactor) {
        guard secondFactor === bridge else { return }
        secondFactor = nil
        switch result {
        case .success(let account):
            guard SigningAccountStore.store(account) else {
                phase = .entering
                failure = "Madeira couldn't keep the sign-in in this device's Keychain."
                LogStore.shared.log("[signing] sign-in failed: keychain", level: .error)
                return
            }
            phase = .done
            SigningRefresh.shared.signedIn()
        case .failure(let error):
            phase = .entering
            failure = error.localizedDescription
            switch error {
            case Failure.cancelled:
                failure = nil
                LogStore.shared.log("[signing] sign-in cancelled")
            case Failure.anisette: LogStore.shared.log("[signing] sign-in failed: anisette", level: .error)
            default: LogStore.shared.log("[signing] sign-in failed", level: .error)
            }
        }
    }
}

// MARK: - The sheet

/// Settings › Signing › Sign in with Apple ID: the credentials, then the second factor
/// when Apple asks for it.
struct AppleSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var signIn = AppleSignIn()
    @State private var appleID = SigningRefresh.shared.account?.appleID ?? ""
    @State private var password = ""
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    private var prompt: TwoFactorPrompt? {
        switch signIn.phase {
        case .twoFactor(let prompt), .answering(let prompt, _): return prompt
        default: return nil
        }
    }

    /// The answer the sign-in is acting on, while it does.
    private var pending: TwoFactorAnswer? {
        if case .answering(_, let answer) = signIn.phase { return answer }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let prompt { secondFactor(prompt) } else { credentials }
            }
            .navigationTitle(prompt.map { $0.expectsCode ? "Two-Factor Code" : "Choose How to Get a Code" } ?? "Apple ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let prompt {
                        if prompt.expectsCode {
                            Button("Verify") { signIn.answer(.code(code)) }.disabled(pending != nil || code.count != 6)
                        }
                    } else {
                        Button("Sign In") { signIn.start(appleID: appleID, password: password) }
                            .disabled(signIn.working || appleID.isEmpty || password.isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled(signIn.working)
        .onChange(of: signIn.phase) { _, phase in
            switch phase {
            case .done: dismiss()
            // A new prompt, after a wrong code or with a new code on its way, starts empty.
            case .twoFactor(let prompt):
                code = ""
                // The field was disabled while the last answer was on its way, and only
                // takes the keyboard once this update has enabled it again.
                DispatchQueue.main.async { codeFocused = prompt.expectsCode }
            default: break
            }
        }
        .onDisappear { signIn.cancel() }
    }

    @ViewBuilder private var credentials: some View {
        Section {
            TextField("Apple ID", text: $appleID)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(.password)
                .onSubmit { signIn.start(appleID: appleID, password: password) }
            if signIn.phase == .working {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Signing in…").foregroundStyle(.secondary)
                }
            }
            if let failure = signIn.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        } footer: {
            Text("Sign in with the Apple ID this copy of Madeira was installed with. Madeira signs in to Apple itself: your password does not leave this device and is not kept. What is kept, in this device's Keychain, is a token for Apple's developer service. An anisette server (\(URL(string: AppleSignIn.anisetteServers[0])?.host ?? "") first) supplies the device data Apple asks for, and sees neither your Apple ID nor your password.")
        }
        .disabled(signIn.working)
    }

    @ViewBuilder private func secondFactor(_ prompt: TwoFactorPrompt) -> some View {
        // What Apple said of the last answer, until the next one is on its way.
        if let error = prompt.lastError, pending == nil {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        Section {
            Text(instructions(for: prompt)).foregroundStyle(.secondary)
            if prompt.expectsCode {
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                    // Lets a texted code fill itself in from Messages.
                    .textContentType(.oneTimeCode)
                    .font(.title2.monospacedDigit())
                    .focused($codeFocused)
                    .disabled(pending != nil)
                    .onChange(of: code) { _, typed in
                        let digits = String(typed.filter(\.isNumber).prefix(6))
                        if digits != typed { code = digits }
                    }
            }
            if let pending {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(status(for: pending, in: prompt)).foregroundStyle(.secondary)
                }
            }
        }
        Section {
            // Every other way to a code, leaving out the one in use.
            switch prompt.method {
            case .device: option("Send a new code to my devices", "arrow.clockwise", .resend)
            case .sms: option("Text me a new code", "arrow.clockwise", .resend)
            case .choose: EmptyView()
            }
            if prompt.method != .device {
                option("Send a code to my Apple devices", "laptopcomputer.and.iphone", .devices)
            }
            ForEach(prompt.numbers) { number in
                if number.takesTexts, !(prompt.method == .sms && number.id == prompt.selectedNumberId) {
                    option("Text \(number.number)", "message", .sms(number.id))
                }
            }
        } header: {
            if prompt.expectsCode { Text("Didn't get it?") }
        }
        .disabled(pending != nil)
    }

    private func option(_ title: String, _ systemImage: String, _ answer: TwoFactorAnswer) -> some View {
        Button { signIn.answer(answer) } label: { Label(title, systemImage: systemImage) }
    }

    private func instructions(for prompt: TwoFactorPrompt) -> String {
        switch prompt.method {
        case .device: return "Enter the code Apple just sent to your trusted devices."
        case .sms: return "Enter the code Apple texted to \(prompt.selectedNumber?.number ?? "your phone")."
        case .choose: return "Choose how Apple should send your verification code."
        }
    }

    private func status(for answer: TwoFactorAnswer, in prompt: TwoFactorPrompt) -> String {
        switch answer {
        case .code: return "Checking the code…"
        case .resend: return "Requesting a new code…"
        case .devices: return "Sending a code to your devices…"
        case .sms(let id): return "Texting a code to \(prompt.numbers.first { $0.id == id }?.number ?? "your phone")…"
        }
    }
}
