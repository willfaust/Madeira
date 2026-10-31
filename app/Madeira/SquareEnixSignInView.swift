// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Trey Boyer
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Security
import SwiftUI

// FINAL FANTASY XIV in the library (docs/SQUARE_ENIX_SIGNIN.md, "In Madeira").
// A recognised entry gets a Square Enix section on its details page, and Play
// signs in here, in a sheet over that page, before the launch starts: a wrong
// password or a one-time password is answered in the sheet, and nothing of the
// app run's one Wine session is used until there is a game session. The
// sign-in itself is SquareEnixSignIn.swift.

enum SquareEnixGame {
    /// The installation an entry starts, or nil for any other entry. Steam and
    /// Epic games and the Desktop start their own way and are never one.
    static func install(for entry: LibraryEntry) -> FFXIVInstall? {
        guard entry.desktop != true, entry.steamAppID == nil, entry.epicAppName == nil else { return nil }
        return FFXIVInstall(program: LibraryModel.drive.appendingPathComponent(entry.relativePath))
    }

    /// What Play starts, relative to drive_c: game/ffxiv_dx11.exe beside the
    /// entry's program's folder (FFXIVInstall.programs are all one folder deep).
    static func clientRelativePath(for entry: LibraryEntry) -> String {
        let root = entry.relativePath.split(separator: "/").dropLast(2).joined(separator: "/")
        return root.isEmpty ? "game/ffxiv_dx11.exe" : root + "/game/ffxiv_dx11.exe"
    }

    static func license(of entry: LibraryEntry) -> SquareEnixLicense? {
        entry.squareEnixLicense.flatMap { SquareEnixLicense(rawValue: $0) }
    }

    private static let installIDKey = "madeira.squareenix.install-id"

    /// The Windows User-Agent's ID: one per Madeira installation, made once.
    static var installID: String {
        if let id = UserDefaults.standard.string(forKey: installIDKey), SquareEnixSignInOptions.isValidInstallID(id) { return id }
        let id = SquareEnixSignInOptions.newInstallID()
        UserDefaults.standard.set(id, forKey: installIDKey)
        return id
    }

    static func options(for entry: LibraryEntry, license: SquareEnixLicense) -> SquareEnixSignInOptions {
        var options = SquareEnixSignInOptions(license: license, installID: installID)
        options.freeTrial = entry.squareEnixFreeTrial == true
        return options
    }
}

/// Square Enix › Remember sign-in: the Square Enix ID and password in the
/// Keychain, service `madeira.squareenix.signin`, one item per library entry,
/// this device only, while unlocked. Nothing is stored while the switch is off;
/// a one-time password never is.
enum SquareEnixCredentialStore {
    struct Saved: Codable {
        var id: String
        var password: String
    }

    private static let service = "madeira.squareenix.signin"

    static func load(for entry: UUID) -> Saved? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: entry.uuidString, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    @discardableResult static func save(_ saved: Saved, for entry: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(saved) else { return false }
        delete(for: entry)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: entry.uuidString, kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                   kSecAttrSynchronizable as String: false]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(for entry: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: entry.uuidString]
        SecItemDelete(query as CFDictionary)
    }
}

/// Game details › Square Enix, for a recognised FINAL FANTASY XIV entry.
struct SquareEnixEntrySection: View {
    @Binding var entry: LibraryEntry

    var body: some View {
        Section {
            Picker("License", selection: Binding(get: { entry.squareEnixLicense ?? "" },
                                                 set: { entry.squareEnixLicense = $0.isEmpty ? nil : $0 })) {
                if entry.squareEnixLicense == nil { Text("Choose").tag("") }
                Text("Windows").tag(SquareEnixLicense.windows.rawValue)
                Text("Mac").tag(SquareEnixLicense.mac.rawValue)
            }
            Toggle("Free trial account", isOn: Binding(get: { entry.squareEnixFreeTrial == true },
                                                        set: { entry.squareEnixFreeTrial = $0 ? true : nil }))
            Toggle("Remember sign-in", isOn: Binding(get: { entry.squareEnixRemember == true }, set: { on in
                entry.squareEnixRemember = on ? true : nil
                if !on { SquareEnixCredentialStore.delete(for: entry.id) }
            }))
        } header: {
            Text("Square Enix")
        } footer: {
            Text("Remember sign-in keeps your Square Enix ID and password in this device's Keychain; a one-time password is never kept.")
        }
    }
}

/// Play's sign-in for a FINAL FANTASY XIV entry. `signedIn` gets what to start;
/// the sheet then closes itself.
struct SquareEnixSignInSheet: View {
    let entry: LibraryEntry
    let install: FFXIVInstall
    let license: SquareEnixLicense
    var signedIn: (SquareEnixLaunch) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var password = ""
    @State private var oneTimePassword = ""
    @State private var step: SquareEnixStep?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var focus: Field?

    private enum Field { case id, password, oneTime }

    private var busy: Bool { task != nil }
    private var trimmedID: String { id.trimmingCharacters(in: .whitespaces) }

    static func label(_ step: SquareEnixStep) -> String {
        switch step {
        case .status: return "Checking the servers…"
        case .bootCheck: return "Checking the game version…"
        case .loginPage: return "Opening sign-in…"
        case .credentials: return "Signing in…"
        case .gate: return "Checking the servers…"
        case .session: return "Starting a game session…"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Square Enix ID", text: $id)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .id)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focus = .oneTime }
                    TextField("One-time password (if used)", text: $oneTimePassword)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .focused($focus, equals: .oneTime)
                } footer: {
                    Text((license == .mac ? "Mac license" : "Windows license") +
                         (entry.squareEnixFreeTrial == true ? ", free trial account." : ".") +
                         (entry.squareEnixRemember == true ? " Your ID and password are kept in the Keychain after signing in." : ""))
                }
                .disabled(busy)
                if busy, let step {
                    Section { HStack(spacing: 12) { ProgressView(); Text(Self.label(step)) } }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section {
                    Button(action: signIn) {
                        HStack {
                            Text("Sign In and Play")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || trimmedID.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("Square Enix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { task?.cancel(); dismiss() }
                }
            }
            .interactiveDismissDisabled(busy)
            .onAppear {
                if entry.squareEnixRemember == true, let saved = SquareEnixCredentialStore.load(for: entry.id) {
                    id = saved.id
                    password = saved.password
                    focus = .oneTime
                } else {
                    focus = .id
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private func signIn() {
        guard !busy else { return }
        error = nil
        step = nil
        focus = nil
        let credentials = SquareEnixCredentials(id: trimmedID, password: password,
                                                oneTimePassword: oneTimePassword.trimmingCharacters(in: .whitespaces))
        let options = SquareEnixGame.options(for: entry, license: license)
        let remember = entry.squareEnixRemember == true
        let entryID = entry.id
        let install = install
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let launch = try await SquareEnixSignIn(log: { LogStore.shared.log($0) }).signIn(
                    install: install, options: options, credentials: credentials,
                    progress: { next in DispatchQueue.main.async { step = next } })
                if remember { SquareEnixCredentialStore.save(.init(id: credentials.id, password: credentials.password), for: entryID) }
                password = ""
                oneTimePassword = ""
                signedIn(launch)
                dismiss()
            } catch SquareEnixSignInError.cancelled {
                // Cancel closed the sheet.
            } catch let failure as SquareEnixSignInError {
                // A one-time password is good once; a refused password is not tried
                // again by itself, nor kept: repeated wrong passwords can lock the account.
                oneTimePassword = ""
                if case .refused = failure {
                    password = ""
                    if remember { SquareEnixCredentialStore.delete(for: entryID) }
                    focus = .password
                }
                error = failure.localizedDescription
            } catch {
                self.error = SquareEnixSignInError.unexpectedReply(.status).localizedDescription
            }
        }
    }
}
