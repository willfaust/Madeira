// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Security
import SwiftUI
import UIKit

// Signing that runs out, renewed by Madeira itself (docs/JIT.md, "Refreshing the
// signing").
//
// A copy signed with a free Apple ID opens for seven days: that is how long its
// provisioning profile lasts. A new profile for the same App ID, installed on the
// device, gives it seven more, with nothing installed again (what SideStore and
// AltStore call a refresh). That takes two things:
//
// 1. A sign-in to Apple's developer portal, to ask for the profile: a portal token
//    and the anisette identity it goes with, never a password. SideInstaller, when
//    it installs Madeira, leaves the ones it signed in with in
//    Library/Application Support/SigningAccount.plist, and Madeira moves them into
//    the Keychain when it starts (SigningAccountStore). A copy installed another
//    way gets them from an Apple ID sign-in under Settings (AppleSignIn.swift).
// 2. A connection to this device, to install the profile: the pairing file
//    Built-in StikJIT uses, through LocalDevVPN (madeira_rppairing_install_profile,
//    build/rppairing-ios).
//
// Madeira refreshes when the library is on screen, LocalDevVPN is connected and
// five days or fewer are left, and offers it in the last two days. The profile in
// its bundle stays the one it was installed with, so the new date is kept in
// UserDefaults, for this installation. An extension an installer gave a profile
// of its own (SideStore and AltStore do) is renewed with the app.
//
// Log tag: [signing] (states, days and Apple's error codes: no token, identifier
// or account).

// MARK: - The profile

/// A provisioning profile: the one this copy was installed with, or a new one.
struct SigningProfile {
    let uuid: String
    let created: Date
    let expires: Date
    /// The signing certificates it covers, DER-encoded.
    let certificates: [Data]
    /// The entitlements it grants. This copy is signed with those of the profile it was
    /// installed with, so one that grants fewer does not cover it.
    let entitlements: Set<String>
    /// The app groups among them: SideStore, AltStore and iloader sign an app into one.
    let groups: [String]
    /// The team it was issued to.
    let teamID: String?
    /// The App ID it was issued for, without the team in front. nil for a wildcard.
    let appIdentifier: String?

    /// How long a free Apple ID's profile lasts, in days.
    static let week = 7
    static let increasedMemory = "com.apple.developer.kernel.increased-memory-limit"

    /// A free Apple ID's profile lasts a week. A paid account's lasts a year, and none
    /// of this applies to it.
    var weekly: Bool { expires.timeIntervalSince(created) <= Double(Self.week + 1) * 86400 }

    /// From the bytes of a `.mobileprovision`: a plist inside a CMS envelope.
    init?(mobileprovision data: Data) {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let object = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound),
                                                                       options: [], format: nil),
              let plist = object as? [String: Any],
              let uuid = plist["UUID"] as? String,
              let created = plist["CreationDate"] as? Date,
              let expires = plist["ExpirationDate"] as? Date
        else { return nil }
        self.uuid = uuid
        self.created = created
        self.expires = expires
        certificates = plist["DeveloperCertificates"] as? [Data] ?? []
        let granted = plist["Entitlements"] as? [String: Any] ?? [:]
        entitlements = Set(granted.keys)
        groups = granted[Self.appGroups] as? [String] ?? []
        teamID = (plist["TeamIdentifier"] as? [String])?.first ?? granted["com.apple.developer.team-identifier"] as? String
        // "ABCDE12345.com.example.app": the App ID is what follows the team.
        let application = (granted["application-identifier"] as? String).flatMap { $0.split(separator: ".", maxSplits: 1).dropFirst().first }
        appIdentifier = application.flatMap { $0.contains("*") ? nil : String($0) }
    }

    static let appGroups = "com.apple.security.application-groups"

    private static func embedded(in bundle: Bundle) -> SigningProfile? {
        bundle.path(forResource: "embedded", ofType: "mobileprovision")
            .flatMap { FileManager.default.contents(atPath: $0) }
            .flatMap(SigningProfile.init(mobileprovision:))
    }

    static let embedded: SigningProfile? = embedded(in: .main)

    /// A profile this copy was installed with and what it signs: the app, or an extension
    /// with an App ID of its own.
    struct Installed {
        let profile: SigningProfile
        /// The App ID to ask a new profile for.
        let identifier: String
        let name: String
    }

    /// The weekly profiles in this copy, the app's first. An extension signed with the
    /// app's profile (SideInstaller and iloader sign it so) adds none.
    static let installed: [Installed] = {
        var found: [Installed] = []
        let extensions = Bundle.main.builtInPlugInsURL
            .flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        for bundle in [Bundle.main] + extensions.filter({ $0.pathExtension == "appex" }).compactMap(Bundle.init(url:)) {
            guard let profile = embedded(in: bundle), profile.weekly,
                  let identifier = profile.appIdentifier ?? bundle.bundleIdentifier,
                  !found.contains(where: { $0.identifier == identifier }) else { continue }
            found.append(Installed(profile: profile, identifier: identifier,
                                   name: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Madeira"))
        }
        return found
    }()
}

// MARK: - The sign-in

/// What it takes to ask Apple's developer portal for a profile: the portal token of an
/// Apple ID and the anisette identity it was issued to. No password. The token only
/// reaches the developer portal, and Apple gives it an expiry. SideInstaller hands one
/// over when it installs Madeira; an Apple ID sign-in in Madeira makes one too.
struct SigningAccount: Codable, Equatable {
    /// The version of this hand-over Madeira reads, declared in Info.plist
    /// (MadeiraSigningAccountVersion) so that an installer only leaves one it can use.
    static let version = 1

    var version: Int
    var teamID: String
    /// Apple's identifier for the account, and its com.apple.gs.xcode.auth token.
    var adsID: String
    var token: String
    var tokenExpires: Date?
    /// The anisette identity: 16 bytes, and the provisioning Apple issued for them.
    var anisetteIdentifier: Data
    var anisetteProvisioning: Data
    /// The anisette servers that turn the identity into one-time headers, the one the
    /// installer signed in through first. Any of them does: the rest are for when it is down.
    var anisetteServers: [String]
    /// The Apple ID, when it was signed in to in Madeira: an installer's hand-over names none.
    var appleID: String?

    var usable: Bool {
        version == Self.version && !teamID.isEmpty && !adsID.isEmpty && !token.isEmpty
            && anisetteIdentifier.count == 16 && !anisetteProvisioning.isEmpty
            && !anisetteServers.isEmpty && anisetteServers.allSatisfy { URL(string: $0)?.scheme == "https" }
    }
}

/// Where the sign-in is kept: the Keychain, for this device only and readable while it is
/// unlocked, as the pairing file is. An installer cannot write there, so it leaves its
/// sign-in in a file outside Documents, which Madeira takes in and deletes when it starts,
/// before any Windows program runs.
enum SigningAccountStore {
    private static let service = "MadeiraSigningAccount"
    private static let keychainAccount = "developer-portal"
    private static let refusedKey = "madeiraSigningAccountRefused"

    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: keychainAccount]
    }

    /// Library/Application Support/SigningAccount.plist, where SideInstaller leaves it.
    static var handoff: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SigningAccount.plist")
    }

    /// Apple turned the stored token down: only a new sign-in or hand-over helps.
    static var refused: Bool {
        get { UserDefaults.standard.bool(forKey: refusedKey) }
        set { UserDefaults.standard.set(newValue, forKey: refusedKey) }
    }

    static func load() -> SigningAccount? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let account = try? PropertyListDecoder().decode(SigningAccount.self, from: data), account.usable
        else { return nil }
        return account
    }

    @discardableResult
    static func store(_ account: SigningAccount) -> Bool {
        guard account.usable, let data = try? PropertyListEncoder().encode(account) else { return false }
        SecItemDelete(item as CFDictionary)
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func forget() {
        SecItemDelete(item as CFDictionary)
        refused = false
    }

    /// Moves a sign-in an installer left into the Keychain. The file goes once the
    /// Keychain holds it, or at once when it is not one Madeira can use.
    static func takeIn() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: handoff.path) else { return }
        guard let data = try? Data(contentsOf: handoff),
              let account = try? PropertyListDecoder().decode(SigningAccount.self, from: data), account.usable else {
            try? manager.removeItem(at: handoff)
            LogStore.shared.log("[signing] a sign-in was left for Madeira that it cannot read; removed", level: .error)
            return
        }
        guard store(account) else { return }   // a locked device keeps it for later
        try? manager.removeItem(at: handoff)
        refused = false
        LogStore.shared.log("[signing] sign-in from the installer moved into the Keychain")
    }
}

// MARK: - Apple's developer portal

/// The few developer-portal requests a refresh takes, as Xcode makes them (and
/// SideStore and isideload after it), signed in with a `SigningAccount`.
struct DeveloperPortal {
    enum Failure: LocalizedError {
        /// The anisette server gave no headers.
        case anisette(String)
        /// Apple no longer accepts the token.
        case signInRefused
        case apple(code: Int, message: String)
        case unreachable(String)
        case unexpected(String)

        var errorDescription: String? {
            switch self {
            case .anisette(let why): return "No anisette server gave an answer Madeira can use (\(why)). Try again later."
            case .signInRefused: return SigningRefresh.signInRefusedMessage
            case .apple(let code, let message): return "Apple did not issue a new profile: \(message) (error \(code))."
            case .unreachable(let why): return "Madeira couldn't reach Apple (\(why)). Check the internet connection, then try again."
            case .unexpected(let what): return what
            }
        }
    }

    struct AppID {
        let id: String
        let identifier: String
        let name: String
        /// Whether its App Groups capability is on.
        let grouped: Bool
    }

    private static let service = "https://developerservices2.apple.com/services"
    private static let clientID = "XABBG36SBA"
    private static let protocolVersion = "QH65B2"
    /// The App Groups capability, as the portal names it.
    private static let appGroupsFeature = "APG3427HIY"
    /// The client Apple's servers are told is asking: its own sign-in daemon.
    private static let clientHeaders = [
        "X-Mme-Client-Info": "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
        "User-Agent": "akd/1.0 CFNetwork/808.1.4",
        "X-Xcode-Version": "14.2 (14C18)",
        "X-Apple-App-Info": "com.apple.gs.xcode.auth",
    ]

    let account: SigningAccount
    /// The identity's one-time headers. Apple accepts them for about a minute, which
    /// covers one refresh.
    private let machine: [String: String]
    private let session: URLSession

    /// Asks an anisette server for the identity's headers: the first that gives them.
    static func open(_ account: SigningAccount, session: URLSession = .shared) async throws -> DeveloperPortal {
        var failure = Failure.anisette("none was given")
        for server in account.anisetteServers {
            do {
                return try await open(account, through: server, session: session)
            } catch let refused as Failure {
                failure = refused
            }
        }
        throw failure
    }

    private static func open(_ account: SigningAccount, through server: String, session: URLSession) async throws -> DeveloperPortal {
        guard let url = URL(string: server)?.appendingPathComponent("v3/get_headers") else {
            throw Failure.anisette("its address is invalid")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": account.anisetteIdentifier.base64EncodedString(),
            "adi_pb": account.anisetteProvisioning.base64EncodedString(),
        ])
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.anisette(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status), answer["result"] as? String == "Headers",
              let password = answer["X-Apple-I-MD"] as? String, let machineID = answer["X-Apple-I-MD-M"] as? String else {
            throw Failure.anisette(answer["message"] as? String ?? "HTTP \(status)")
        }
        let identifier = account.anisetteIdentifier.withUnsafeBytes { NSUUID(uuidBytes: $0.bindMemory(to: UInt8.self).baseAddress) }
        return DeveloperPortal(account: account,
                               machine: ["X-Apple-I-MD": password, "X-Apple-I-MD-M": machineID,
                                         "X-Mme-Device-Id": identifier.uuidString.lowercased()],
                               session: session)
    }

    private func signed(_ url: URL, method: String, contentType: String, body: Data) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in Self.clientHeaders.merging(machine, uniquingKeysWith: { $1 }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(account.token, forHTTPHeaderField: "X-Apple-GS-Token")
        request.setValue(account.adsID, forHTTPHeaderField: "X-Apple-I-Identity-Id")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(contentType, forHTTPHeaderField: "Accept")
        return request
    }

    private func answer(to request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { throw Failure.signInRefused }
            return (data, status)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
    }

    /// One request to the portal's plist interface.
    private func send(_ action: String, _ parameters: [String: Any] = [:]) async throws -> [String: Any] {
        var body: [String: Any] = ["clientId": Self.clientID, "protocolVersion": Self.protocolVersion,
                                   "requestId": UUID().uuidString, "userLocale": ["en_US"], "teamId": account.teamID]
        body.merge(parameters) { $1 }
        let url = URL(string: "\(Self.service)/\(Self.protocolVersion)/ios/\(action).action?clientId=\(Self.clientID)")!
        let (data, status) = try await answer(to: signed(url, method: "POST", contentType: "text/x-xml-plist",
                                                         body: PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)))
        guard (200..<300).contains(status),
              let result = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            throw Failure.unexpected("Apple answered \(action) with HTTP \(status) and nothing Madeira can read.")
        }
        let code = (result["resultCode"] as? NSNumber)?.intValue ?? 0
        guard code == 0 else {
            // 1100: "Your session has expired. Please log in."
            if code == 1100 { throw Failure.signInRefused }
            throw Failure.apple(code: code, message: result["userString"] as? String ?? result["resultString"] as? String ?? "no reason given")
        }
        return result
    }

    private static func appID(_ entry: [String: Any]) -> AppID? {
        guard let id = entry["appIdId"] as? String, let identifier = entry["identifier"] as? String else { return nil }
        return AppID(id: id, identifier: identifier, name: entry["name"] as? String ?? "",
                     grouped: (entry["features"] as? [String: Any])?[appGroupsFeature] as? Bool ?? false)
    }

    /// Apple refuses a name with anything but ASCII letters and digits in it.
    private static func plain(_ name: String) -> String {
        let plain = String(String.UnicodeScalarView(name.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }))
        return plain.isEmpty ? "App" : plain
    }

    /// The App ID registered for `bundleID`, if it still is: a free Apple ID's lasts a week.
    func appID(for bundleID: String) async throws -> AppID? {
        let listed = try await send("listAppIds")["appIds"] as? [[String: Any]] ?? []
        return listed.compactMap(Self.appID).first { $0.identifier == bundleID }
    }

    func addAppID(name: String, bundleID: String) async throws -> AppID {
        let added = try await send("addAppId", ["identifier": bundleID, "name": Self.plain(name)])
        guard let app = (added["appId"] as? [String: Any]).flatMap(Self.appID) else {
            throw Failure.unexpected("Apple registered the App ID and did not say which.")
        }
        return app
    }

    /// Turns on Increased Memory Limit, which a new App ID comes without.
    func enableIncreasedMemory(for app: AppID) async throws {
        let capability: [String: Any] = [
            "type": "bundleIdCapabilities",
            "attributes": ["enabled": true, "settings": [Any]()] as [String: Any],
            "relationships": ["capability": ["data": ["type": "capabilities", "id": "INCREASED_MEMORY_LIMIT"]]],
        ]
        let body: [String: Any] = ["data": [
            "type": "bundleIds",
            "id": app.id,
            "attributes": ["identifier": app.identifier, "name": app.name, "teamId": account.teamID, "seedId": account.teamID,
                           "bundleType": "bundle", "hasExclusiveManagedCapabilities": false] as [String: Any],
            "relationships": ["bundleIdCapabilities": ["data": [capability]]],
        ] as [String: Any]]
        let url = URL(string: "\(Self.service)/v1/bundleIds/\(app.id)")!
        let (data, status) = try await answer(to: signed(url, method: "PATCH", contentType: "application/vnd.api+json",
                                                         body: JSONSerialization.data(withJSONObject: body)))
        guard (200..<300).contains(status) else {
            let errors = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["errors"] as? [[String: Any]]
            throw Failure.apple(code: status, message: errors?.first?["detail"] as? String ?? "Increased Memory Limit was not enabled")
        }
    }

    /// Puts the App ID in the app groups `identifiers`, as its installer did. A new App ID
    /// is in none, and the team's groups run out as its App IDs do, so one that is gone is
    /// registered again.
    func assign(groups identifiers: [String], to app: AppID, named name: String) async throws {
        if !app.grouped {
            _ = try await send("updateAppId", ["appIdId": app.id, Self.appGroupsFeature: true])
        }
        let registered = try await send("listApplicationGroups")["applicationGroupList"] as? [[String: Any]] ?? []
        var groups: [String] = []
        for identifier in identifiers {
            var group = registered.first { $0["identifier"] as? String == identifier }
            if group == nil {
                group = try await send("addApplicationGroup", ["identifier": identifier, "name": Self.plain(name)])["applicationGroup"] as? [String: Any]
            }
            guard let id = group?["applicationGroup"] as? String else {
                throw Failure.unexpected("Apple registered the app group and did not say which.")
            }
            groups.append(id)
        }
        // One group goes as iloader sends it, several as AltStore does.
        _ = try await send("assignApplicationGroupToAppId",
                           ["appIdId": app.id, "applicationGroups": groups.count == 1 ? groups[0] as Any : groups as Any])
    }

    /// A new provisioning profile for the App ID. Apple makes a free Apple ID's anew on
    /// every request.
    func profile(for app: AppID) async throws -> (data: Data, profile: SigningProfile) {
        let answer = try await send("downloadTeamProvisioningProfile", ["appIdId": app.id])
        guard let data = (answer["provisioningProfile"] as? [String: Any])?["encodedProfile"] as? Data,
              let profile = SigningProfile(mobileprovision: data) else {
            throw Failure.unexpected("Apple's answer held no provisioning profile.")
        }
        return (data, profile)
    }

    /// A new profile that covers the copy installed with `installed`: for its App ID,
    /// registered again when the old one has run out, granting what that profile granted
    /// (its app groups among it) and listing one of its certificates.
    static func renewedProfile(for bundleID: String, named name: String, account: SigningAccount,
                               covering installed: SigningProfile,
                               session: URLSession = .shared) async throws -> (data: Data, profile: SigningProfile) {
        let portal = try await open(account, session: session)
        let app: AppID
        if let registered = try await portal.appID(for: bundleID) {
            app = registered
        } else {
            app = try await portal.addAppID(name: name, bundleID: bundleID)
            LogStore.shared.log("[signing] App ID had run out; registered again")
        }
        var new = try await portal.profile(for: app)
        // What a new App ID comes without is turned on, then the profile asked for again.
        let memory = installed.entitlements.contains(SigningProfile.increasedMemory)
            && !new.profile.entitlements.contains(SigningProfile.increasedMemory)
        let groups = !Set(installed.groups).isSubset(of: new.profile.groups)
        if memory { try await portal.enableIncreasedMemory(for: app) }
        if groups { try await portal.assign(groups: installed.groups, to: app, named: name) }
        if memory || groups { new = try await portal.profile(for: app) }
        var missing = installed.entitlements.subtracting(new.profile.entitlements)
        if !Set(installed.groups).isSubset(of: new.profile.groups) { missing.insert(SigningProfile.appGroups) }
        guard missing.isEmpty else {
            throw Failure.unexpected("Apple's new profile does not grant \(missing.sorted().joined(separator: ", ")), "
                + "which this copy is signed with. Install Madeira again to renew it.")
        }
        guard installed.certificates.isEmpty || !Set(installed.certificates).isDisjoint(with: new.profile.certificates) else {
            throw Failure.unexpected("This copy was signed with a certificate the Apple ID no longer has, "
                + "so a new profile cannot renew it. Install Madeira again.")
        }
        return new
    }
}

// MARK: - Refreshing

@MainActor final class SigningRefresh: ObservableObject {
    static let shared = SigningRefresh()

    /// Off by default: no Settings section, no refresh or offer over the library and no
    /// sign-in taken from an installer. A refresh asks Apple's portal for a profile on the
    /// Apple ID that signs other apps too, so the installer that signed Madeira renews it.
    /// `env.MADEIRA_SIGNING_REFRESH = 1` brings all of it back.
    nonisolated static var enabled: Bool { MadeiraConfig.flag("MADEIRA_SIGNING_REFRESH", fallback: false) }

    /// Madeira refreshes by itself from this many days before the signing runs out, and
    /// offers it from `offerDays`.
    static let automaticDays = 5
    static let offerDays = 2
    /// The device's remote-pairing port through LocalDevVPN, as StikJIT reaches it.
    nonisolated static let devicePort: UInt16 = 49152

    nonisolated static let signInRefusedMessage = "Apple no longer accepts Madeira's sign-in. "
        + "Sign in with your Apple ID under Settings › Signing, or install Madeira again with SideInstaller."
    nonisolated static let unreachableMessage = "Madeira couldn't reach this device. Connect LocalDevVPN, then try again."

    private static let renewedUntilKey = "madeiraSigningRenewedUntil"
    private static let renewedForKey = "madeiraSigningRenewedFor"
    private static let offeredKey = "madeiraSigningRefreshOffered"
    private static let attemptedKey = "madeiraSigningRefreshAttempted"

    enum Status: Equatable {
        case idle
        case working(String)
        case refreshed
        case failed(String)
    }

    /// What the alert over the library says.
    enum Prompt: Equatable {
        /// The signing is about to run out and Madeira could not refresh it by itself.
        case expiring
        case failed(String)
    }

    /// When this copy stops opening; nil when its signing does not run out weekly, or
    /// when that date has passed and Madeira still runs (something renewed it without
    /// saying until when: SideStore and AltStore refresh that way).
    @Published private(set) var expires: Date?
    @Published private(set) var account: SigningAccount?
    @Published private(set) var signInRefused = false
    @Published private(set) var status: Status = .idle
    /// The last refresh failed for want of LocalDevVPN.
    @Published private(set) var deviceUnreachable = false
    @Published var prompt: Prompt?
    /// The Apple ID sheet (AppleSignIn.swift) is open. It is presented from one place,
    /// SigningRefreshOffer, whoever asks for it: a sheet on a Form's Section is one sheet
    /// per row, of which UIKit presents the first and refuses the rest, and SwiftUI then
    /// closes the one on screen, the sign-in under way with it.
    @Published var signingIn = false

    private init() { update() }

    /// This copy was signed with a free Apple ID: its signing runs out weekly, and that
    /// Apple ID's sign-in renews it.
    var weekly: Bool { SigningProfile.embedded?.weekly == true }

    private func update() {
        account = SigningAccountStore.load()
        signInRefused = account != nil && SigningAccountStore.refused
        guard let profile = SigningProfile.embedded, profile.weekly else { expires = nil; return }
        let defaults = UserDefaults.standard
        var date = profile.expires
        // A date from a refresh counts for the installation it renewed.
        if defaults.string(forKey: Self.renewedForKey) == profile.uuid {
            date = max(date, Date(timeIntervalSince1970: defaults.double(forKey: Self.renewedUntilKey)))
        }
        expires = date > Date() ? date : nil
    }

    /// Calendar days until the signing runs out: 0 is today.
    var daysLeft: Int? {
        guard let expires else { return nil }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                           to: calendar.startOfDay(for: expires)).day ?? 0
        return max(0, days)
    }

    /// "expires tomorrow", after "Madeira" or "Madeira's signing".
    var summary: String {
        switch daysLeft {
        case nil: return "does not expire soon"
        case 0: return "expires today"
        case 1: return "expires tomorrow"
        case let days?: return "expires in \(days) days"
        }
    }

    var working: Bool {
        if case .working = status { return true }
        return false
    }

    /// The library is on screen, at start, after a game or back from another app: take
    /// in a sign-in an installer left, refresh when it is time, and say so when the
    /// signing is about to run out and that did not work.
    func libraryAppeared() {
        SigningAccountStore.takeIn()
        update()
        refreshIfDue()
    }

    /// An Apple ID sign-in in Madeira (AppleSignIn.swift) left a sign-in in the Keychain.
    func signedIn() {
        SigningAccountStore.refused = false
        // The refresh Apple turned down is tried again at once.
        UserDefaults.standard.removeObject(forKey: Self.attemptedKey)
        status = .idle
        prompt = nil
        update()
        LogStore.shared.log("[signing] signed in with an Apple ID")
        refreshIfDue()
    }

    private func refreshIfDue() {
        guard account != nil, let days = daysLeft, !working else { return }
        // A refresh that failed is not tried again for six hours; one that could not
        // start (no LocalDevVPN) costs nothing and is.
        let rested = Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: Self.attemptedKey) > 6 * 3600
        if days <= Self.automaticDays, !signInRefused, rested, refresh(automatic: true) { return }
        offerIfDue()
    }

    private func offerIfDue() {
        // Not under the Apple ID sheet: while it waits for the code, Apple's own sign-in
        // alert takes Madeira out of the foreground and back, which gets here.
        guard account != nil, let days = daysLeft, days <= Self.offerDays, prompt == nil, !signingIn,
              !OnboardingModel.shared.presented else { return }
        let today = Int(Date().timeIntervalSince1970 / 86400)
        guard UserDefaults.standard.integer(forKey: Self.offeredKey) != today else { return }
        UserDefaults.standard.set(today, forKey: Self.offeredKey)
        LogStore.shared.log("[signing] refresh offered days-left=\(days)")
        prompt = .expiring
    }

    /// Asks Apple for a new profile and installs it on this device. An automatic refresh
    /// starts only when it can work, and fails quietly. Returns whether it started.
    @discardableResult
    func refresh(automatic: Bool = false) -> Bool {
        let installed = SigningProfile.installed
        guard !working, let account, let main = SigningProfile.embedded, !installed.isEmpty else { return false }
        func stop(_ message: String, unreachable: Bool = false) -> Bool {
            guard !automatic else { return false }
            deviceUnreachable = unreachable
            status = .failed(message)
            prompt = .failed(message)
            return false
        }
        if signInRefused { return stop(Self.signInRefusedMessage) }
        // A profile from another team's Apple ID cannot renew this copy, and asking for
        // one would spend an App ID there.
        if let team = main.teamID, team != account.teamID {
            return stop("Madeira's sign-in is for another Apple ID than the one this copy was signed with. "
                + "Forget it under Settings › Signing, then sign in with the Apple ID that installed Madeira.")
        }
        // A second connection to the device while the debugger holds one is not worth
        // a game that fails to start.
        if isDebuggerAttached() || JITCoordinator.shared.busy {
            return stop("JIT is being enabled or is waiting for a game. Refresh before enabling JIT, or after playing.")
        }
        guard let pairing = try? JITPairingFileStore.data() else {
            return stop("Madeira has no pairing file for this device. Set up Built-in StikJIT under JIT setup, then refresh.")
        }
        guard LoopbackProbe.vpnInterfaceUp else { return stop(Self.unreachableMessage, unreachable: true) }

        deviceUnreachable = false
        status = .working("Asking Apple for a new profile…")
        LogStore.shared.log("[signing] refresh started automatic=\(automatic ? 1 : 0) days-left=\(daysLeft.map(String.init) ?? "unknown")")
        Task {
            do {
                // Every profile is asked for before any is installed.
                var renewed: [(data: Data, profile: SigningProfile)] = []
                for item in installed {
                    renewed.append(try await DeveloperPortal.renewedProfile(for: item.identifier, named: item.name,
                                                                            account: account, covering: item.profile))
                }
                status = .working("Installing it on this device…")
                for new in renewed { try await Self.install(new.data, pairing: pairing) }
                let until = renewed.map(\.profile.expires).min() ?? main.expires
                UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.renewedUntilKey)
                UserDefaults.standard.set(main.uuid, forKey: Self.renewedForKey)
                update()
                status = .refreshed
                if prompt == .expiring { prompt = nil }
                LogStore.shared.log("[signing] refreshed profiles=\(renewed.count) days-left=\(daysLeft.map(String.init) ?? "unknown")", level: .success)
            } catch {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.attemptedKey)
                if case DeveloperPortal.Failure.signInRefused = error {
                    SigningAccountStore.refused = true
                    signInRefused = true
                }
                if case InstallFailure.unreachable = error { deviceUnreachable = true }
                let message = error.localizedDescription
                status = .failed(message)
                LogStore.shared.log("[signing] refresh failed: \(Self.logged(error))", level: .error)
                if automatic { offerIfDue() } else { prompt = .failed(message) }
            }
        }
        return true
    }

    func forgetAccount() {
        SigningAccountStore.forget()
        status = .idle
        update()
        LogStore.shared.log("[signing] sign-in forgotten")
    }

    /// The failure for the log: its kind and Apple's code, without the server's words.
    private static func logged(_ error: Error) -> String {
        switch error {
        case DeveloperPortal.Failure.anisette: return "anisette"
        case DeveloperPortal.Failure.signInRefused: return "sign-in refused"
        case DeveloperPortal.Failure.apple(let code, _): return "apple error \(code)"
        case DeveloperPortal.Failure.unreachable: return "apple unreachable"
        case InstallFailure.unreachable: return "device unreachable"
        case InstallFailure.pairing: return "pairing refused"
        default: return "other"
        }
    }

    enum InstallFailure: LocalizedError {
        case unreachable
        case pairing
        case device(String)

        var errorDescription: String? {
            switch self {
            case .unreachable: return SigningRefresh.unreachableMessage
            case .pairing: return "This device no longer accepts Madeira's pairing file. Pair again under JIT setup, then refresh."
            case .device(let why): return "This device did not take the new profile: \(why)."
            }
        }
    }

    /// Installs the profile through the pairing file's tunnel. Blocking, so off the main thread.
    nonisolated private static func install(_ profile: Data, pairing: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var message: UnsafeMutablePointer<CChar>?
                let code = pairing.withUnsafeBytes { pairingBytes in
                    profile.withUnsafeBytes { profileBytes in
                        madeira_rppairing_install_profile(pairingBytes.bindMemory(to: UInt8.self).baseAddress, pairing.count,
                                                          LoopbackProbe.address, devicePort,
                                                          profileBytes.bindMemory(to: UInt8.self).baseAddress, profile.count,
                                                          20, &message)
                    }
                }
                let why = message.map { String(cString: $0) } ?? "no reason given"
                madeira_rppairing_string_free(message)
                switch code {
                case 0: continuation.resume()
                case 1: continuation.resume(throwing: InstallFailure.unreachable)
                case 2: continuation.resume(throwing: InstallFailure.pairing)
                default: continuation.resume(throwing: InstallFailure.device(why))
                }
            }
        }
    }
}

// MARK: - Settings and the offer

/// Settings › Signing: when this copy's signing runs out, the refresh, and the Apple ID
/// sign-in for a copy no installer left one for. Empty for a copy whose signing does not
/// run out weekly and that holds no sign-in.
struct SigningSettingsSection: View {
    @ObservedObject private var signing = SigningRefresh.shared

    private var signIn: String {
        if signing.signInRefused { return "No longer accepted" }
        if let until = signing.account?.tokenExpires {
            return until > Date() ? "Until \(until.formatted(date: .abbreviated, time: .omitted))" : "Expired"
        }
        return signing.account?.appleID == nil ? "From SideInstaller" : "Signed in"
    }

    private var footer: String {
        let weekly = "Madeira was signed with a free Apple ID, so it stops opening when this runs out. "
        guard let account = signing.account else {
            return weekly + "Refresh it with the app that installed it before then, or sign in with the Apple ID it was installed with and Madeira renews its own signing when it is open and LocalDevVPN is connected. Installed with SideInstaller, Madeira needs no sign-in."
        }
        let source = account.appleID == nil ? "the sign-in SideInstaller gave it" : "your Apple ID's sign-in"
        return weekly + "With \(source) (a token for Apple's developer service, not your password, kept in this device's Keychain), Madeira renews its own signing when it is open and LocalDevVPN is connected. It asks Apple and an anisette server, \(account.anisetteServers.first.flatMap { URL(string: $0)?.host } ?? "the one it was given") first."
    }

    var body: some View {
        if signing.expires != nil || signing.account != nil || signing.weekly {
            Section {
                if signing.expires != nil {
                    LabeledContent("Madeira", value: signing.summary.prefix(1).uppercased() + signing.summary.dropFirst())
                }
                if signing.weekly, signing.account == nil || signing.signInRefused {
                    // SigningRefreshOffer, over the library, presents the sheet.
                    Button {
                        signing.signingIn = true
                    } label: {
                        Label(signing.account == nil ? "Sign in with Apple ID…" : "Sign in again…", systemImage: "person.crop.circle")
                    }
                }
                if let appleID = signing.account?.appleID {
                    LabeledContent("Apple ID", value: appleID)
                }
                if signing.account != nil {
                    LabeledContent("Apple sign-in", value: signIn)
                    Button {
                        signing.refresh()
                    } label: {
                        if case .working(let step) = signing.status {
                            HStack { ProgressView(); Text(step) }
                        } else {
                            Label("Refresh now", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(signing.working || signing.signInRefused || !signing.weekly)
                    if case .failed(let message) = signing.status {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        if signing.deviceUnreachable { Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() } }
                    } else if signing.status == .refreshed {
                        Label("Refreshed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Button("Forget Apple sign-in", role: .destructive) { signing.forgetAccount() }
                }
            } header: {
                Text("Signing")
            } footer: {
                Text(footer)
            }
        }
    }
}

/// Over the library: the refresh when it is time, what to do when the signing is about
/// to run out and Madeira could not refresh it, and the Apple ID sheet, for this alert
/// and for Settings.
struct SigningRefreshOffer: ViewModifier {
    @ObservedObject private var signing = SigningRefresh.shared

    private var title: String {
        if case .failed = signing.prompt { return "Couldn't Refresh Madeira" }
        return "Madeira's signing \(signing.summary)"
    }

    private var message: String {
        if case .failed(let why) = signing.prompt { return why }
        if signing.signInRefused { return SigningRefresh.signInRefusedMessage }
        return LoopbackProbe.vpnInterfaceUp
            ? "Madeira can renew it for another \(SigningProfile.week) days."
            : "Connect LocalDevVPN and come back: Madeira then renews it for another \(SigningProfile.week) days."
    }

    /// What the alert offers besides closing it: a sign-in when Apple turned the last one
    /// down, LocalDevVPN when that is what is missing, else the refresh.
    private var needsSignIn: Bool { signing.signInRefused && signing.weekly }

    private var needsLocalDevVPN: Bool {
        if case .failed = signing.prompt { return signing.deviceUnreachable }
        return !signing.signInRefused && !LoopbackProbe.vpnInterfaceUp
    }

    func body(content: Content) -> some View {
        // Switched off (SigningRefresh.enabled), nothing starts a refresh or sets a prompt.
        content
            .onAppear { if SigningRefresh.enabled { signing.libraryAppeared() } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                if SigningRefresh.enabled { signing.libraryAppeared() }
            }
            .alert(title, isPresented: Binding(get: { signing.prompt != nil }, set: { if !$0 { signing.prompt = nil } })) {
                if needsSignIn {
                    Button("Sign In…") { signing.signingIn = true }
                } else if needsLocalDevVPN {
                    Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                } else if signing.prompt == .expiring, !signing.signInRefused {
                    Button("Refresh Now") { signing.refresh() }
                }
                Button(signing.prompt == .expiring ? "Later" : "OK", role: .cancel) {}
            } message: {
                Text(message)
            }
            .sheet(isPresented: $signing.signingIn) { AppleSignInSheet() }
    }
}
