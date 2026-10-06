// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Epic Games sign-in, modeled on Legendary's auth flow
// (https://github.com/derrod/legendary). The user logs in on Epic's site in
// an embedded web view; Madeira reads the authorizationCode from Epic's
// redirect page and exchanges it for OAuth tokens. The password is entered
// on Epic's site and never touches the app; tokens live in the Keychain.

import Foundation
import Security
import SwiftUI
import WebKit
import Combine

enum EpicAuthError: Error {
    case notSignedIn
    case network
    case rejected(String)
    case correctiveAction(String?)

    var message: String {
        switch self {
        case .notSignedIn: return "Sign in to Epic Games first."
        case .network: return "Could not reach Epic Games. Check your connection and try again."
        case .rejected(let code): return "Epic Games refused the sign-in (\(code)). Try again."
        case .correctiveAction(let detail):
            return "Epic Games needs an extra step: \(detail ?? "open Epic's site and follow the prompt")."
        }
    }
}

/// Epic Games authentication: OAuth login through Epic's site, token
/// exchange and refresh, Keychain storage. Mirrors Legendary's auth_code flow.
final class EpicAuth: ObservableObject {
    static let shared = EpicAuth()

    @Published private(set) var accountName: String?
    @Published var signInError: String?
    @Published private(set) var isBusy = false

    /// Epic's public launcher client credentials (the same ones Legendary uses).
    private let clientID = "34a02cf8f4414e29b15921876da36f9a"
    private let clientSecret = "daafbccc737745039dffe53d94fc76cf"
    private let oauthHost = "account-public-service-prod03.ol.epicgames.com"
    private let userAgent = "UELauncher/11.0.1-14907503+++Portal+Release-Live Windows/10.0.19041.1.256.64bit"

    private let store = EpicTokenStore()

    var signedIn: Bool { accountName != nil }

    /// The saved login is read at start, so the library shows the account's games
    /// without visiting Settings first.
    private init() {
        accountName = store.loadTokens()?.displayName
    }

    /// Epic's login page. After login, Epic shows a JSON page containing the
    /// authorizationCode, which the embedded web view captures.
    var loginURL: URL {
        var components = URLComponents(string: "https://www.epicgames.com/id/login")!
        let redirect = "https://www.epicgames.com/id/api/redirect?clientId=\(clientID)&responseType=code"
        components.queryItems = [URLQueryItem(name: "redirectUrl", value: redirect)]
        return components.url!
    }

    func refresh() {
        accountName = store.loadTokens()?.displayName
        signInError = nil
    }

    /// Pull an authorizationCode out of pasted text: either the raw code or
    /// the whole JSON blob from Epic's redirect page (like Legendary's CLI).
    static func extractCode(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = json["authorizationCode"] as? String, !code.isEmpty {
            return code
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Exchange an authorizationCode for tokens.
    func exchange(authorizationCode code: String) {
        guard !isBusy else { return }
        isBusy = true
        signInError = nil
        Task {
            do {
                let tokens = try await requestTokens(grant: [
                    ("grant_type", "authorization_code"),
                    ("code", code),
                    ("token_type", "eg1"),
                ])
                store.save(tokens: tokens)
                await MainActor.run {
                    self.accountName = tokens.displayName
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.signInError = (error as? EpicAuthError)?.message ?? error.localizedDescription
                    self.isBusy = false
                }
            }
        }
    }

    /// A valid access token, refreshing first when expired.
    func validAccessToken() async throws -> String {
        guard var tokens = store.loadTokens() else { throw EpicAuthError.notSignedIn }
        if tokens.expiresAt > Date().addingTimeInterval(60) {
            return tokens.accessToken
        }
        tokens = try await requestTokens(grant: [
            ("grant_type", "refresh_token"),
            ("refresh_token", tokens.refreshToken),
            ("token_type", "eg1"),
        ])
        store.save(tokens: tokens)
        await MainActor.run { self.accountName = tokens.displayName }
        return tokens.accessToken
    }

    /// Legendary's get_game_token: exchange codes are fetched for one launch and never saved.
    func gameArguments(appName: String) async throws -> String {
        let token = try await validAccessToken()
        guard let account = store.loadTokens() else { throw EpicAuthError.notSignedIn }
        var request = URLRequest(url: URL(string: "https://\(oauthHost)/account/api/oauth/exchange")!)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String, !code.isEmpty else { throw EpicAuthError.network }
        let arguments = ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=" + code, "-AUTH_TYPE=exchangecode",
                         "-epicapp=" + appName, "-epicenv=Prod", "-EpicPortal",
                         "-epicusername=" + account.displayName, "-epicuserid=" + account.accountID, "-epiclocale=en"]
        // Madeira's tokenizer groups double-quoted values; embedded quotes/control characters
        // cannot be represented and must not turn an account name into another argument.
        guard arguments.allSatisfy({ !$0.contains("\"") && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw EpicContentError.invalid("Epic returned invalid launch parameters.")
        }
        return arguments.map { "\"" + $0 + "\"" }.joined(separator: " ")
    }

    func signOut() {
        store.delete()
        accountName = nil
        signInError = nil
    }

    // MARK: - Token endpoint

    private func requestTokens(grant: [(String, String)]) async throws -> EpicTokens {
        var request = URLRequest(url: URL(string: "https://\(oauthHost)/account/api/oauth/token")!)
        request.httpMethod = "POST"
        let credentials = "\(clientID):\(clientSecret)".data(using: .utf8)!.base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        var body = URLComponents()
        body.queryItems = grant.map { URLQueryItem(name: $0.0, value: $0.1) }
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EpicAuthError.network
        }
        if let code = json["errorCode"] as? String {
            if code == "errors.com.epicgames.oauth.corrective_action_required" {
                throw EpicAuthError.correctiveAction(json["errorMessage"] as? String)
            }
            throw EpicAuthError.rejected(code)
        }
        guard http.statusCode < 400,
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            throw EpicAuthError.rejected("unknown")
        }
        let expiresIn: Double
        if let d = json["expires_in"] as? Double { expiresIn = d }
        else if let i = json["expires_in"] as? Int { expiresIn = Double(i) }
        else { expiresIn = 7200 }
        return EpicTokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn - 60),
            accountID: json["account_id"] as? String ?? "",
            displayName: json["displayName"] as? String ?? "",
            savedAt: Date()
        )
    }
}

/// The OAuth tokens, kept in the Keychain like Steam's tokens.
struct EpicTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var accountID: String
    var displayName: String
    var savedAt: Date
}

final class EpicTokenStore {
    private let serviceName = "madeira.epic.tokens"

    func save(tokens: EpicTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "epic_tokens",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func loadTokens() -> EpicTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "epic_tokens",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let tokens = try? JSONDecoder().decode(EpicTokens.self, from: data) else {
            return nil
        }
        return tokens
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "epic_tokens",
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// WKWebView wrapper that watches for Epic's redirect page and pulls the
/// authorizationCode out of its JSON, so the user never pastes anything.
struct EpicLoginWebView: UIViewRepresentable {
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: EpicAuth.shared.loginURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void
        private var didCapture = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didCapture,
                  let url = webView.url?.absoluteString,
                  url.contains("id/api/redirect") else { return }
            webView.evaluateJavaScript("document.body.innerText") { [weak self] result, _ in
                guard let self = self, !self.didCapture,
                      let text = result as? String,
                      text.contains("authorizationCode") else { return }
                let code = EpicAuth.extractCode(from: text)
                guard !code.isEmpty else { return }
                self.didCapture = true
                self.onCode(code)
            }
        }
    }
}
