// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Epic Games sign-in sheet: log in on Epic's site in an embedded web view
// (the authorizationCode is captured automatically), or paste one manually.
// When signed in it shows the account and the owned-games list.

import SwiftUI

struct EpicSignInView: View {
    @ObservedObject private var auth = EpicAuth.shared
    @ObservedObject private var library = EpicLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showPaste = false
    @State private var pastedCode = ""

    var body: some View {
        NavigationStack {
            Group {
                if let name = auth.accountName {
                    account(name)
                } else {
                    login
                }
            }
            .navigationTitle("Epic Games").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(auth.signedIn ? "Done" : "Cancel") { dismiss() }
                }
                if !auth.signedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Paste an authorization code") { showPaste = true }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .alert("Authorization code", isPresented: $showPaste) {
                TextField("authorizationCode", text: $pastedCode)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Sign in") {
                    auth.exchange(authorizationCode: EpicAuth.extractCode(from: pastedCode))
                    pastedCode = ""
                }
                Button("Cancel", role: .cancel) { pastedCode = "" }
            }
            .onAppear { auth.refresh() }
            // Signed in from the login page: fetch the games and close, like Steam's sign-in.
            .onChange(of: auth.accountName) { old, name in
                guard name != nil else { library.clear(); return }
                library.refresh()
                if old == nil { dismiss() }
            }
        }
    }

    /// Epic's own login page, filling the sheet; the authorization code it ends on is
    /// captured and exchanged without the user seeing it.
    private var login: some View {
        ZStack {
            EpicLoginWebView { code in auth.exchange(authorizationCode: code) }
                .ignoresSafeArea(edges: .bottom)
            if auth.isBusy {
                Color(uiColor: .systemBackground).opacity(0.85).ignoresSafeArea()
                ProgressView("Signing in…")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = auth.signInError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red)
                    .padding(12).frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
    }

    private func account(_ name: String) -> some View {
        Form {
            Section {
                LabeledContent("Signed in as", value: name.isEmpty ? "Epic account" : name)
                LabeledContent("Games", value: library.isLoading ? "Loading…" : "\(library.games.count)")
                Button("Sign out of Epic Games", role: .destructive) {
                    auth.signOut()
                    library.clear()
                }
            }
            if let error = library.error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
        }
    }
}

/// Settings › Epic Games, after Steam's section: the account and Sign out, or Sign in.
/// The sheet is presented by LibraryView, as Steam's (SteamSettingsSection).
struct EpicSettingsSection: View {
    let open: (SettingsSheet) -> Void
    @ObservedObject private var auth = EpicAuth.shared
    @State private var confirmSignOut = false

    var body: some View {
        Section {
            if let name = auth.accountName {
                LabeledContent("Signed in as", value: name.isEmpty ? "Epic account" : name)
                Button("Sign out of Epic Games", role: .destructive) { confirmSignOut = true }
            } else {
                Button { open(.epicSignIn) } label: { Label("Sign in to Epic Games", systemImage: "person.crop.circle.badge.plus") }
            }
        } header: {
            Text("Epic Games")
        } footer: {
            Text("You sign in on Epic's own page. Madeira keeps the Epic sign-in token in this device's Keychain; signing out removes it.")
        }
        .confirmationDialog("Sign out of Epic Games?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                auth.signOut()
                EpicLibrary.shared.clear()
            }
        }
    }
}
