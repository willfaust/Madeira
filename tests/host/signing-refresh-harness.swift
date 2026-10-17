// SPDX-License-Identifier: GPL-3.0-or-later
// Host harness for tests/host/check-signing-refresh.py: the signing refresh's
// developer-portal client and the Apple ID sign-in's flow (app/Madeira/SigningRefresh.swift,
// AppleSignIn.swift), compiled for macOS with the parts below standing in for Apple, the
// anisette server, the Keychain and libmadeira_rppairing.a. Nothing leaves this Mac and
// nothing touches its Keychain. Run once with --fixtures, which writes the profiles of a
// pretend installation next to the binary, then without.

import Foundation

// MARK: - The app's side

final class LogStore {
    enum Level { case info, error, success }
    static let shared = LogStore()
    var lines: [String] = []
    func log(_ message: String, level: Level = .info) { lines.append(message) }
}

@MainActor final class SigningRefresh {
    static let shared = SigningRefresh()
    nonisolated static let signInRefusedMessage = "REFUSED"
    var signedInCount = 0
    func signedIn() { signedInCount += 1 }
}

/// The Keychain's stand-in: nothing here touches the Mac's.
enum SigningAccountStore {
    static var held: SigningAccount?
    static var refused = false
    static var fails = false
    static func load() -> SigningAccount? { held }
    @discardableResult static func store(_ account: SigningAccount) -> Bool {
        guard account.usable, !fails else { return false }
        held = account
        return true
    }
}

// MARK: - The library's stand-in

typealias MadeiraAppleTwoFactorCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Int32

/// What `madeira_apple_sign_in` is scripted to do.
enum Library {
    struct Call {
        let appleID: String
        let password: String
        let server: String
        let identity: Data?
        let provisioning: Data?
    }

    enum Outcome {
        case anisette(String)
        case refused(String)
        /// Ask for the second factor with each request in turn, then answer.
        case twoFactor([String], then: String)
        case signedIn(String)
    }

    static let lock = NSLock()
    static var calls: [Call] = []
    static var replies: [String] = []
    static var script: (Call) -> Outcome = { _ in .refused("no script") }
    static var thread: Thread?

    static func reset(_ script: @escaping (Call) -> Outcome) {
        lock.lock(); calls = []; replies = []; self.script = script; lock.unlock()
    }
}

func madeira_apple_sign_in(_ appleID: UnsafePointer<CChar>?, _ password: UnsafePointer<CChar>?, _ server: UnsafePointer<CChar>?,
                           _ identity: UnsafePointer<UInt8>?, _ identityLength: Int,
                           _ provisioning: UnsafePointer<UInt8>?, _ provisioningLength: Int,
                           _ twoFactor: MadeiraAppleTwoFactorCallback?, _ context: UnsafeMutableRawPointer?,
                           _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                           _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    let call = Library.Call(appleID: String(cString: appleID!), password: String(cString: password!), server: String(cString: server!),
                            identity: identity.map { Data(bytes: $0, count: identityLength) },
                            provisioning: provisioning.map { Data(bytes: $0, count: provisioningLength) })
    Library.lock.lock()
    Library.calls.append(call)
    Library.thread = Thread.current
    let outcome = Library.script(call)
    Library.lock.unlock()
    switch outcome {
    case .anisette(let why): error?.pointee = strdup(why); return 2
    case .refused(let why): error?.pointee = strdup(why); return 3
    case .signedIn(let json): result?.pointee = strdup(json); return 0
    case .twoFactor(let requests, let json):
        for request in requests {
            var reply = [CChar](repeating: 0, count: 512)
            guard let twoFactor, twoFactor(context, request, &reply, reply.count) == 1 else {
                error?.pointee = strdup("cancelled")
                return 1
            }
            Library.lock.lock(); Library.replies.append(String(cString: reply)); Library.lock.unlock()
        }
        result?.pointee = strdup(json)
        return 0
    }
}

func madeira_rppairing_string_free(_ string: UnsafeMutablePointer<CChar>?) { free(string) }

// MARK: - Apple and the anisette server

// A stand-in for the anisette server and Apple's developer portal, answering in
// the shapes isideload parses, and recording what it was asked.
final class Stub: URLProtocol {
    struct Seen { let url: URL; let method: String; let headers: [String: String]; let body: Data }
    static var seen: [Seen] = []
    static var appIDs: [[String: Any]] = []
    static var capabilityEnabled = false
    static var resultCode = 0
    static var status = 200
    static var anisetteFails = false
    static var certificate = Data([1, 2, 3])
    // App groups: the team's, whether the App ID's capability is on, and the ones it is in.
    static var groups: [[String: Any]] = []
    static var groupFeature = false
    static var assigned: [String] = []
    static var assignmentsStick = true

    static func profile(entitlements: [String], groups: [String] = [], team: String = "TEAM123456",
                        appID: String = "com.willfaust.madeora.TEAM123456", days: Double = 7) -> Data {
        var granted: [String: Any] = [:]
        for key in entitlements { granted[key] = true }
        granted["application-identifier"] = "\(team).\(appID)"
        granted["com.apple.developer.team-identifier"] = team
        if !groups.isEmpty { granted["com.apple.security.application-groups"] = groups }
        let plist: [String: Any] = ["UUID": UUID().uuidString, "CreationDate": Date(), "ExpirationDate": Date().addingTimeInterval(days * 86400),
                                    "DeveloperCertificates": [certificate], "Entitlements": granted, "TeamIdentifier": [team]]
        let xml = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return Data([0x30, 0x82, 0x10, 0x00]) + xml + Data([0xA0, 0x82, 0x01])      // a CMS envelope's worth of bytes around it
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
        }
        let url = request.url!
        Stub.seen.append(Seen(url: url, method: request.httpMethod ?? "", headers: request.allHTTPHeaderFields ?? [:], body: body))
        var status = 200
        var answer = Data()
        if url.host == "down.example.org" {
            status = 503
        } else if url.host == "ani.example.org" {
            let json: [String: Any] = Stub.anisetteFails
                ? ["result": "GetHeadersError", "message": "not provisioned"]
                : ["result": "Headers", "X-Apple-I-MD": "otp", "X-Apple-I-MD-M": "machine", "X-Apple-I-MD-RINFO": "17106176"]
            answer = try! JSONSerialization.data(withJSONObject: json)
        } else if url.path.hasPrefix("/services/v1/bundleIds/") {
            Stub.capabilityEnabled = true
            answer = Data("{}".utf8)
        } else {
            status = Stub.status
            var plist: [String: Any] = ["resultCode": Stub.resultCode]
            if Stub.resultCode != 0 { plist["userString"] = "Your session has expired. Please log in."; plist["resultString"] = "session expired" }
            let asked = (try? PropertyListSerialization.propertyList(from: body, options: [], format: nil)) as? [String: Any] ?? [:]
            switch url.lastPathComponent {
            case "listAppIds.action":
                plist["appIds"] = Stub.appIDs.map { $0.merging(["features": ["APG3427HIY": Stub.groupFeature, "gameCenter": false]]) { old, _ in old } }
            case "addAppId.action":
                let added: [String: Any] = ["appIdId": "NEWID", "identifier": asked["identifier"] ?? "", "name": asked["name"] ?? ""]
                Stub.appIDs.append(added)
                Stub.groupFeature = false
                Stub.assigned = []
                plist["appId"] = added
            case "updateAppId.action":
                if asked["APG3427HIY"] as? Bool == true { Stub.groupFeature = true }
                plist["appId"] = ["appIdId": asked["appIdId"] ?? "", "identifier": "x", "name": "x"]
            case "listApplicationGroups.action":
                plist["applicationGroupList"] = Stub.groups
            case "addApplicationGroup.action":
                let added: [String: Any] = ["applicationGroup": "GRP\(Stub.groups.count + 1)", "identifier": asked["identifier"] ?? "", "name": asked["name"] ?? ""]
                Stub.groups.append(added)
                plist["applicationGroup"] = added
            case "assignApplicationGroupToAppId.action":
                // Apple refuses a group for an App ID whose capability is off.
                if !Stub.groupFeature { plist["resultCode"] = 9400; plist["userString"] = "App Groups is not enabled for this App ID." }
                else if Stub.assignmentsStick {
                    let ids = (asked["applicationGroups"] as? [String]) ?? (asked["applicationGroups"] as? String).map { [$0] } ?? []
                    Stub.assigned = Stub.groups.filter { ids.contains($0["applicationGroup"] as? String ?? "") }.compactMap { $0["identifier"] as? String }
                }
            case "downloadTeamProvisioningProfile.action":
                var granted = ["get-task-allow", "keychain-access-groups"]
                if Stub.capabilityEnabled { granted.append("com.apple.developer.kernel.increased-memory-limit") }
                plist["provisioningProfile"] = ["encodedProfile": Stub.profile(entitlements: granted, groups: Stub.assigned), "UUID": "x"]
            default: break
            }
            answer = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer)
        client?.urlProtocolDidFinishLoading(self)
    }
}

var failures = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "PASS: " : "FAIL: ") + what); if !ok { failures += 1 } }

let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [Stub.self]
let session = URLSession(configuration: configuration)

let identifier = Data((0..<16).map { UInt8($0 * 17) })
let account = SigningAccount(version: 1, teamID: "TEAM123456", adsID: "000123-08-abcdef", token: "TOKEN", tokenExpires: nil,
                             anisetteIdentifier: identifier, anisetteProvisioning: Data([9, 9, 9]), anisetteServers: ["https://ani.example.org"])
let bundleID = "com.willfaust.madeora.TEAM123456"
let group = "group.com.willfaust.madeora.TEAM123456"
let installedGrants = ["get-task-allow", "keychain-access-groups", "com.apple.developer.kernel.increased-memory-limit"]
let installed = SigningProfile(mobileprovision: Stub.profile(entitlements: installedGrants))!
let grouped = SigningProfile(mobileprovision: Stub.profile(entitlements: installedGrants, groups: [group]))!

// This copy's own profiles, where Bundle.main finds them for a command-line tool: next
// to it. The app's, an extension with an App ID of its own (as SideStore signs one), an
// extension signed with the app's profile (as SideInstaller does) and one that does not
// run out weekly. Written by a first run (--fixtures), since Bundle.main lists its
// folder once, when it is first asked.
if CommandLine.arguments.contains("--fixtures") {
    let here = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
    try! Stub.profile(entitlements: installedGrants, groups: [group]).write(to: here.appendingPathComponent("embedded.mobileprovision"))
    for (name, appID, days) in [("JITHelper", bundleID + ".JITHelper", 7.0), ("Shared", bundleID, 7.0), ("Yearly", bundleID + ".Yearly", 365.0)] {
        let folder = here.appendingPathComponent("PlugIns/\(name).appex")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try! Stub.profile(entitlements: ["get-task-allow"], appID: appID, days: days).write(to: folder.appendingPathComponent("embedded.mobileprovision"))
        let info: [String: Any] = ["CFBundleIdentifier": appID, "CFBundleName": name, "CFBundlePackageType": "XPC!"]
        try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: folder.appendingPathComponent("Info.plist"))
    }
    exit(0)
}

func run(covering profile: SigningProfile = installed) async -> Result<(data: Data, profile: SigningProfile), Error> {
    Stub.seen = []
    do { return .success(try await DeveloperPortal.renewedProfile(for: bundleID, named: "Madeira Games!", account: account, covering: profile, session: session)) }
    catch { return .failure(error) }
}
func plist(_ seen: Stub.Seen) -> [String: Any] { (try? PropertyListSerialization.propertyList(from: seen.body, options: [], format: nil)) as? [String: Any] ?? [:] }
var asked: [String] { Stub.seen.map { $0.url.lastPathComponent.replacingOccurrences(of: ".action", with: "") } }

func portalChecks() async {
    check(account.usable && installed.weekly && installed.entitlements.count == 5 && installed.certificates == [Data([1, 2, 3])],
          "the account is usable and a profile inside an envelope is read")
    check(installed.teamID == "TEAM123456" && installed.appIdentifier == bundleID && installed.groups.isEmpty && grouped.groups == [group],
          "a profile names its team, its App ID without the team, and its app groups")
    let wildcard = SigningProfile(mobileprovision: Stub.profile(entitlements: [], appID: "*"))
    check(wildcard?.appIdentifier == nil && wildcard?.teamID == "TEAM123456", "a wildcard profile names no App ID")

    // 1. The App ID is still registered and has the capability.
    Stub.appIDs = [["appIdId": "OLDID", "identifier": bundleID, "name": "Madeira"], ["appIdId": "X", "identifier": "com.other", "name": "Other"]]
    Stub.capabilityEnabled = true
    var result = await run()
    check((try? result.get()) != nil, "an App ID that is still registered gives a profile")
    check(asked == ["get_headers", "listAppIds", "downloadTeamProvisioningProfile"], "three requests: anisette headers, the App IDs, the profile (\(asked))")
    let anisette = Stub.seen[0]
    let sent = (try? JSONSerialization.jsonObject(with: anisette.body)) as? [String: String] ?? [:]
    check(anisette.url.absoluteString == "https://ani.example.org/v3/get_headers" && anisette.method == "POST"
          && sent["identifier"] == identifier.base64EncodedString() && sent["adi_pb"] == Data([9, 9, 9]).base64EncodedString(),
          "the anisette server gets the identity as isideload sends it")
    let list = Stub.seen[1]
    check(list.url.absoluteString == "https://developerservices2.apple.com/services/QH65B2/ios/listAppIds.action?clientId=XABBG36SBA" && list.method == "POST",
          "the portal's address is Xcode's")
    let h = list.headers
    check(h["X-Apple-GS-Token"] == "TOKEN" && h["X-Apple-I-Identity-Id"] == "000123-08-abcdef" && h["X-Apple-I-MD"] == "otp" && h["X-Apple-I-MD-M"] == "machine"
          && h["X-Mme-Device-Id"] == "00112233-4455-6677-8899-aabbccddeeff" && h["Content-Type"] == "text/x-xml-plist" && h["Accept"] == "text/x-xml-plist"
          && h["X-Apple-App-Info"] == "com.apple.gs.xcode.auth" && h["X-Xcode-Version"] == "14.2 (14C18)" && h["User-Agent"] == "akd/1.0 CFNetwork/808.1.4"
          && (h["X-Mme-Client-Info"] ?? "").contains("com.apple.akd"),
          "a request carries the token, the account, the one-time headers and the device id (\(h["X-Mme-Device-Id"] ?? "none"))")
    let body = plist(list)
    check(body["clientId"] as? String == "XABBG36SBA" && body["protocolVersion"] as? String == "QH65B2" && body["teamId"] as? String == "TEAM123456"
          && body["userLocale"] as? [String] == ["en_US"] && UUID(uuidString: body["requestId"] as? String ?? "") != nil
          && String(data: list.body, encoding: .utf8)?.hasPrefix("<?xml") == true,
          "the body is an XML plist with Xcode's fields and the team")
    check(plist(Stub.seen[2])["appIdId"] as? String == "OLDID", "the profile is asked for the app's own App ID")

    // 2. The App ID has run out: registered again, the capability enabled, the profile asked for twice.
    Stub.appIDs = [["appIdId": "X", "identifier": "com.other", "name": "Other"]]
    Stub.capabilityEnabled = false
    result = await run()
    check((try? result.get())?.profile.entitlements.contains(SigningProfile.increasedMemory) == true, "an App ID that ran out is registered again and gets its capability")
    check(asked == ["get_headers", "listAppIds", "addAppId", "downloadTeamProvisioningProfile", "NEWID", "downloadTeamProvisioningProfile"], "in that order (\(asked))")
    let add = plist(Stub.seen[2])
    check(add["identifier"] as? String == bundleID && add["name"] as? String == "MadeiraGames", "the new App ID has the bundle ID and a name of letters and digits (\(add["name"] ?? "none"))")
    let patch = Stub.seen[4]
    let json = (try? JSONSerialization.jsonObject(with: patch.body)) as? [String: Any] ?? [:]
    let data = json["data"] as? [String: Any] ?? [:]
    let attributes = data["attributes"] as? [String: Any] ?? [:]
    let capabilities = ((data["relationships"] as? [String: Any])?["bundleIdCapabilities"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
    let capability = ((capabilities.first?["relationships"] as? [String: Any])?["capability"] as? [String: Any])?["data"] as? [String: Any] ?? [:]
    check(patch.method == "PATCH" && patch.url.absoluteString == "https://developerservices2.apple.com/services/v1/bundleIds/NEWID"
          && patch.headers["Content-Type"] == "application/vnd.api+json" && patch.headers["X-Apple-GS-Token"] == "TOKEN"
          && data["type"] as? String == "bundleIds" && data["id"] as? String == "NEWID"
          && attributes["identifier"] as? String == bundleID && attributes["teamId"] as? String == "TEAM123456" && attributes["seedId"] as? String == "TEAM123456"
          && attributes["bundleType"] as? String == "bundle" && attributes["hasExclusiveManagedCapabilities"] as? Bool == false && attributes["name"] as? String == "MadeiraGames"
          && capability["id"] as? String == "INCREASED_MEMORY_LIMIT" && capability["type"] as? String == "capabilities"
          && (capabilities.first?["attributes"] as? [String: Any])?["enabled"] as? Bool == true
          && capabilities.first?["type"] as? String == "bundleIdCapabilities",
          "Increased Memory Limit is enabled with the request isideload makes")
    check(LogStore.shared.lines.allSatisfy { !$0.contains("TOKEN") && !$0.contains("000123") && !$0.contains(bundleID) }, "the log names no token, account or bundle ID")

    // 2b. A copy signed into an app group (iloader, SideStore): the App ID that ran out is
    // registered again, its capability turned on, the group registered again and assigned.
    Stub.appIDs = []; Stub.capabilityEnabled = false; Stub.groups = []; Stub.groupFeature = false; Stub.assigned = []
    result = await run(covering: grouped)
    check((try? result.get())?.profile.groups == [group], "a copy signed into an app group gets a profile with the group (\(result))")
    check(asked == ["get_headers", "listAppIds", "addAppId", "downloadTeamProvisioningProfile", "NEWID", "updateAppId", "listApplicationGroups",
                    "addApplicationGroup", "assignApplicationGroupToAppId", "downloadTeamProvisioningProfile"],
          "the capability is turned on before the group is assigned, and the profile asked for once more (\(asked))")
    let update = plist(Stub.seen[5]), newGroup = plist(Stub.seen[7]), assign = plist(Stub.seen[8])
    check(update["appIdId"] as? String == "NEWID" && update["APG3427HIY"] as? Bool == true && update["teamId"] as? String == "TEAM123456",
          "App Groups is turned on for the App ID as isideload does it")
    check(newGroup["identifier"] as? String == group && newGroup["name"] as? String == "MadeiraGames", "a group that ran out is registered again under its identifier")
    check(assign["appIdId"] as? String == "NEWID" && assign["applicationGroups"] as? String == "GRP1", "the App ID is put in the group Apple named (\(assign["applicationGroups"] ?? "none"))")

    // 2c. The App ID and its group are still there: nothing but the profile is asked for.
    result = await run(covering: grouped)
    check((try? result.get()) != nil && asked == ["get_headers", "listAppIds", "downloadTeamProvisioningProfile"], "an App ID still in its group needs nothing new (\(asked))")

    // 2d. The group is still registered and the capability on, the App ID not in it.
    Stub.assigned = []
    result = await run(covering: grouped)
    check((try? result.get())?.profile.groups == [group]
          && asked == ["get_headers", "listAppIds", "downloadTeamProvisioningProfile", "listApplicationGroups", "assignApplicationGroupToAppId", "downloadTeamProvisioningProfile"],
          "a registered group is assigned, not registered twice (\(asked))")

    // 2e. Two groups go to Apple as a list.
    Stub.assigned = []
    let two = SigningProfile(mobileprovision: Stub.profile(entitlements: installedGrants, groups: [group, group + ".second"]))!
    result = await run(covering: two)
    check((try? result.get())?.profile.groups == [group, group + ".second"]
          && plist(Stub.seen.first { $0.url.lastPathComponent.hasPrefix("assign") }!)["applicationGroups"] as? [String] == ["GRP1", "GRP2"],
          "two groups are assigned together (\(asked))")

    // 2f. Apple's profile still lacks the group: nothing is installed.
    Stub.assigned = []; Stub.assignmentsStick = false
    result = await run(covering: grouped)
    if case .failure(DeveloperPortal.Failure.unexpected(let why)) = result { check(why.contains("application-groups"), "a profile without the copy's app group is refused") }
    else { check(false, "a profile without the copy's app group is refused: \(result)") }
    Stub.assignmentsStick = true; Stub.groups = []; Stub.groupFeature = false; Stub.assigned = []
    Stub.appIDs = [["appIdId": "OLDID", "identifier": bundleID, "name": "Madeira"]]

    // 3. A certificate that is gone.
    Stub.capabilityEnabled = true
    Stub.certificate = Data([7, 7, 7])
    result = await run()
    if case .failure(DeveloperPortal.Failure.unexpected(let why)) = result { check(why.contains("certificate"), "a profile without the copy's certificate is refused") }
    else { check(false, "a profile without the copy's certificate is refused") }
    Stub.certificate = Data([1, 2, 3])

    // 4. Apple turns the token down, in either of its two ways.
    Stub.resultCode = 1100
    result = await run()
    if case .failure(DeveloperPortal.Failure.signInRefused) = result { check(true, "error 1100 is a refused sign-in") } else { check(false, "error 1100 is a refused sign-in: \(result)") }
    Stub.resultCode = 0; Stub.status = 401
    result = await run()
    if case .failure(DeveloperPortal.Failure.signInRefused) = result { check(true, "HTTP 401 is a refused sign-in") } else { check(false, "HTTP 401 is a refused sign-in: \(result)") }
    Stub.status = 200; Stub.resultCode = 9120
    result = await run()
    if case .failure(DeveloperPortal.Failure.apple(let code, let message)) = result { check(code == 9120 && message.contains("session"), "another error keeps Apple's code and words") }
    else { check(false, "another error keeps Apple's code and words: \(result)") }
    Stub.resultCode = 0

    // 5. The anisette server gives no headers.
    Stub.anisetteFails = true
    result = await run()
    if case .failure(DeveloperPortal.Failure.anisette(let why)) = result { check(why == "not provisioned" && Stub.seen.count == 1, "no anisette headers: Apple is not asked") }
    else { check(false, "no anisette headers: Apple is not asked") }
    Stub.anisetteFails = false

    // 5b. The first anisette server is down: the next one given is asked.
    var spare = account
    spare.anisetteServers = ["https://down.example.org", "https://ani.example.org"]
    Stub.seen = []
    let through = try? await DeveloperPortal.renewedProfile(for: bundleID, named: "Madeira", account: spare, covering: installed, session: session)
    check(through != nil && Stub.seen.prefix(3).map { $0.url.host ?? "" } == ["down.example.org", "ani.example.org", "developerservices2.apple.com"],
          "an anisette server that is down is passed over for the next (\(Stub.seen.prefix(3).map { $0.url.host ?? "" }))")

    // 6. The hand-over SideInstaller writes decodes as the account, and others are refused.
    let handoff: [String: Any] = ["version": 1, "teamID": "TEAM123456", "adsID": "000123-08-abcdef", "token": "TOKEN", "tokenExpires": Date(timeIntervalSince1970: 1_800_000_000),
                                  "anisetteIdentifier": identifier, "anisetteProvisioning": Data([9, 9, 9]), "anisetteServers": ["https://ani.example.org"]]
    let binary = try! PropertyListSerialization.data(fromPropertyList: handoff, format: .binary, options: 0)
    let decoded = try? PropertyListDecoder().decode(SigningAccount.self, from: binary)
    check(decoded?.usable == true && decoded?.tokenExpires == Date(timeIntervalSince1970: 1_800_000_000) && decoded?.anisetteIdentifier == identifier
          && decoded?.appleID == nil, "a binary plist with these keys is the hand-over, and names no Apple ID")
    var later = handoff; later["version"] = 2
    var plain = handoff; plain["anisetteServers"] = ["https://ani.example.org", "http://ani.example.org"]
    var none = handoff; none["anisetteServers"] = [String]()
    var short = handoff; short["anisetteIdentifier"] = Data([1, 2, 3])
    var undated = handoff; undated.removeValue(forKey: "tokenExpires")
    func usable(_ dict: [String: Any]) -> Bool {
        (try? PropertyListDecoder().decode(SigningAccount.self, from: PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)))?.usable == true
    }
    check(!usable(later) && !usable(plain) && !usable(none) && !usable(short) && usable(undated), "another version, a plain-HTTP server, no server or a short identifier is not; no expiry is")
    var named = account; named.appleID = "ada@example.org"
    let kept = try? PropertyListDecoder().decode(SigningAccount.self, from: PropertyListEncoder().encode(named))
    check(kept == named && kept?.appleID == "ada@example.org", "a sign-in made in Madeira keeps its Apple ID through the Keychain's encoding")

    // 7. The profiles this copy was installed with.
    let found = SigningProfile.installed
    check(SigningProfile.embedded?.teamID == "TEAM123456" && SigningProfile.embedded?.groups == [group], "the app's own profile is read from its bundle")
    check(found.map(\.identifier) == [bundleID, bundleID + ".JITHelper"] && found.map(\.name).last == "JITHelper",
          "an extension with an App ID of its own is renewed too; one signed with the app's profile, or not weekly, is not (\(found.map(\.identifier)))")
}

// MARK: - The Apple ID sign-in

let signedIn = #"{"adsID":"000999-08-fedcba","token":"NEWTOKEN","tokenExpires":1800000000,"anisetteIdentifier":"AQEBAQEBAQEBAQEBAQEBAQ==","anisetteProvisioning":"AgIC","teams":[{"id":"OTHERTEAM1","name":"Work","type":"Company"},{"id":"TEAM123456","name":"Ada Lovelace (Personal Team)","type":"Individual"}]}"#
let devicePrompt = #"{"method":"device","selectedNumberId":null,"lastError":null,"numbers":[{"id":1,"number":"+39 ••• ••• ••89","pushMode":"sms"},{"id":2,"number":"+39 •• ••• ••12","pushMode":"voice"}]}"#
let wrongCodePrompt = #"{"method":"device","selectedNumberId":null,"lastError":"Incorrect verification code","numbers":[{"id":1,"number":"+39 ••• ••• ••89","pushMode":"sms"}]}"#
let smsPrompt = #"{"method":"sms","selectedNumberId":1,"lastError":null,"numbers":[{"id":1,"number":"+39 ••• ••• ••89","pushMode":"sms"}]}"#

@MainActor func until(_ what: String, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    print("TIMEOUT: \(what)")
    return false
}

@MainActor func signInChecks() async {
    // Servers: the held sign-in's first, HTTPS only, each once, six at most.
    let defaults = AppleSignIn.anisetteServers
    check(defaults.count == 6 && defaults.allSatisfy { $0.hasPrefix("https://") } && Set(defaults).count == 6, "six anisette servers, all HTTPS")
    check(AppleSignIn.servers(after: []) == defaults
          && AppleSignIn.servers(after: ["https://ani.example.org", "http://plain.example.org", defaults[2]]) == ["https://ani.example.org", defaults[2], defaults[0], defaults[1], defaults[3], defaults[4]],
          "a held sign-in's servers come first, without plain HTTP or repeats, six in all")

    // The library's answer.
    let answer = AppleSignIn.Answer(json: signedIn)
    check(answer?.adsID == "000999-08-fedcba" && answer?.token == "NEWTOKEN" && answer?.tokenExpires == Date(timeIntervalSince1970: 1_800_000_000)
          && answer?.anisetteIdentifier == Data(repeating: 1, count: 16) && answer?.anisetteProvisioning == Data(repeating: 2, count: 3)
          && answer?.teams.map(\.id) == ["OTHERTEAM1", "TEAM123456"], "the library's answer is read")
    check(AppleSignIn.Answer(json: signedIn.replacingOccurrences(of: "1800000000", with: "null"))?.tokenExpires == nil
          && AppleSignIn.Answer(json: #"{"adsID":"x"}"#) == nil && AppleSignIn.Answer(json: "") == nil, "no expiry is read as none, and an answer short of a field as nothing")
    let made = try? answer?.account(appleID: "ada@example.org", signedBy: "TEAM123456", through: ["https://ani.example.org"])
    check(made?.usable == true && made?.teamID == "TEAM123456" && made?.appleID == "ada@example.org" && made?.token == "NEWTOKEN"
          && made?.version == SigningAccount.version, "the sign-in kept is for the team this copy was signed by, not the account's first")
    for (team, word) in [("NOTMYTEAM1" as String?, "NOTMYTEAM1"), (nil, "no provisioning profile")] {
        do { _ = try answer!.account(appleID: "a", signedBy: team, through: ["https://ani.example.org"]); check(false, "another team is refused") }
        catch { check(error.localizedDescription.contains(word), "an Apple ID that did not sign this copy is refused (\(word))") }
    }

    // The second factor's wire format.
    let prompt = TwoFactorPrompt.read(devicePrompt)
    check(prompt.method == .device && prompt.expectsCode && prompt.numbers.count == 2 && prompt.numbers[0].takesTexts && !prompt.numbers[1].takesTexts
          && TwoFactorPrompt.read(smsPrompt).selectedNumber?.id == 1 && TwoFactorPrompt.read("nonsense") == .deviceOnly
          && !TwoFactorPrompt.read(#"{"method":"choose","numbers":[]}"#).expectsCode, "the library's prompt is read, and an unreadable one asks for a device code")
    func object(_ answer: TwoFactorAnswer) -> NSDictionary { (try? JSONSerialization.jsonObject(with: Data(answer.json.utf8))) as? NSDictionary ?? [:] }
    check(object(.code("123456")) == ["action": "code", "code": "123456"] && object(.sms(2)) == ["action": "sms", "id": 2]
          && object(.devices) == ["action": "devices"] && object(.resend) == ["action": "resend"], "answers are the JSON the library reads")

    // 1. No sign-in held; the first server's identity is no good, the second signs in.
    SigningAccountStore.held = nil
    Library.reset { $0.server == defaults[0] ? .anisette("end provisioning error") : .signedIn(signedIn) }
    var signIn = AppleSignIn()
    signIn.start(appleID: "  ada@example.org ", password: "hunter2")
    check(signIn.phase == .working && signIn.working, "a sign-in starts working at once")
    signIn.start(appleID: "ada@example.org", password: "hunter2")
    _ = await until("signed in") { signIn.phase == .done }
    check(signIn.phase == .done && signIn.failure == nil && Library.calls.map(\.server) == [defaults[0], defaults[1]]
          && Library.calls.allSatisfy { $0.identity == nil && $0.provisioning == nil && $0.appleID == "ada@example.org" && $0.password == "hunter2" },
          "a server whose identity Apple does not take is passed over; a second start while one runs does nothing (\(Library.calls.map(\.server)))")
    check(Library.thread != nil && Library.thread?.isMainThread == false, "the blocking sign-in runs off the main thread")
    let stored = SigningAccountStore.held
    check(stored?.usable == true && stored?.teamID == "TEAM123456" && stored?.adsID == "000999-08-fedcba" && stored?.appleID == "ada@example.org"
          && stored?.anisetteServers.first == defaults[1] && stored?.anisetteServers.count == 6 && Set(stored?.anisetteServers ?? []).count == 6
          && SigningRefresh.shared.signedInCount == 1,
          "the sign-in goes into the Keychain with the server that worked first, and the refresh is told")

    // 2. A sign-in is held: its identity is signed in as again, through its own servers first.
    var held = account
    held.anisetteServers = ["https://ani.example.org", "https://second.example.org", "https://third.example.org"]
    SigningAccountStore.held = held
    Library.reset { $0.identity != nil ? .anisette("not provisioned") : .signedIn(signedIn) }
    signIn = AppleSignIn()
    signIn.start(appleID: "ada@example.org", password: "hunter2")
    _ = await until("signed in again") { signIn.phase == .done }
    check(Library.calls.map(\.server) == ["https://ani.example.org", "https://second.example.org", defaults[0]]
          && Library.calls.prefix(2).allSatisfy { $0.identity == identifier && $0.provisioning == Data([9, 9, 9]) } && Library.calls[2].identity == nil,
          "the held identity is tried through its own two servers, then a new one (\(Library.calls.map(\.server)))")
    check(SigningAccountStore.held?.token == "NEWTOKEN" && SigningAccountStore.held?.anisetteIdentifier == Data(repeating: 1, count: 16)
          && SigningAccountStore.held?.anisetteServers.prefix(2) == [defaults[0], "https://ani.example.org"],
          "the new sign-in replaces the held one")

    // 3. The second factor: a wrong code, then a text, then the right code.
    SigningAccountStore.held = nil
    Library.reset { _ in .twoFactor([devicePrompt, wrongCodePrompt, smsPrompt], then: signedIn) }
    signIn = AppleSignIn()
    signIn.start(appleID: "ada@example.org", password: "hunter2")
    _ = await until("asked for a code") { if case .twoFactor = signIn.phase { return true }; return false }
    check(signIn.phase == .twoFactor(TwoFactorPrompt.read(devicePrompt)), "Apple's request for a code reaches the sheet")
    signIn.answer(.code("111111"))
    check(signIn.phase == .answering(TwoFactorPrompt.read(devicePrompt), .code("111111")), "the sheet shows the code being checked")
    signIn.answer(.code("222222"))      // a second tap while the first is on its way
    _ = await until("asked again") { signIn.phase == .twoFactor(TwoFactorPrompt.read(wrongCodePrompt)) }
    check(signIn.phase == .twoFactor(TwoFactorPrompt.read(wrongCodePrompt)), "a wrong code asks again with what Apple said")
    signIn.answer(.sms(1))
    _ = await until("texted") { signIn.phase == .twoFactor(TwoFactorPrompt.read(smsPrompt)) }
    signIn.answer(.code("333333"))
    _ = await until("signed in with a code") { signIn.phase == .done }
    check(signIn.phase == .done && Library.replies.map { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? NSDictionary }
          == [["action": "code", "code": "111111"], ["action": "sms", "id": 1], ["action": "code", "code": "333333"]]
          && Library.calls.count == 1 && SigningAccountStore.held?.token == "NEWTOKEN",
          "each answer goes to the library once, in order (\(Library.replies))")

    // 4. The sheet is closed at the code: the sign-in gives up and nothing is kept.
    SigningAccountStore.held = nil
    let told = SigningRefresh.shared.signedInCount
    Library.reset { _ in .twoFactor([devicePrompt], then: signedIn) }
    signIn = AppleSignIn()
    signIn.start(appleID: "ada@example.org", password: "hunter2")
    _ = await until("asked for a code") { if case .twoFactor = signIn.phase { return true }; return false }
    signIn.cancel()
    check(signIn.phase == .entering && !signIn.working, "closing the sheet ends the prompt")
    try? await Task.sleep(nanoseconds: 100_000_000)
    check(Library.calls.count == 1 && Library.replies.isEmpty && SigningAccountStore.held == nil && SigningRefresh.shared.signedInCount == told
          && signIn.failure == nil, "a sign-in given up at the code is not tried through another server, and keeps nothing")

    // 4b. Closed while Apple is being asked: what comes back is dropped, and a late prompt is refused.
    Library.reset { _ in Thread.sleep(forTimeInterval: 0.15); return .twoFactor([devicePrompt], then: signedIn) }
    signIn = AppleSignIn()
    signIn.start(appleID: "ada@example.org", password: "hunter2")
    signIn.cancel()
    try? await Task.sleep(nanoseconds: 400_000_000)
    check(signIn.phase == .entering && Library.replies.isEmpty && SigningAccountStore.held == nil, "a sign-in closed while it works keeps nothing")

    // 5. Apple refuses the password: said once, with Apple's words, and no other server is tried.
    Library.reset { _ in .refused("Apple said: Enter the correct password for this Apple Account. (error -22406)") }
    signIn = AppleSignIn()
    signIn.start(appleID: "ada@example.org", password: "wrong")
    _ = await until("refused") { signIn.failure != nil }
    check(signIn.phase == .entering && signIn.failure?.contains("-22406") == true && Library.calls.count == 1 && SigningAccountStore.held == nil,
          "a refused password is told Apple once (\(Library.calls.count) sign-in)")

    // 6. The Apple ID is not the one this copy was signed with.
    Library.reset { _ in .signedIn(signedIn.replacingOccurrences(of: "TEAM123456", with: "SOMEONEELS")) }
    signIn = AppleSignIn()
    signIn.start(appleID: "grace@example.org", password: "hunter2")
    _ = await until("another team") { signIn.failure != nil }
    check(signIn.phase == .entering && signIn.failure?.contains("TEAM123456") == true && SigningAccountStore.held == nil,
          "another Apple ID's sign-in is not kept (\(signIn.failure ?? "none"))")

    // 7. No anisette server gives an identity Apple takes.
    Library.reset { _ in .anisette("end provisioning error") }
    signIn = AppleSignIn()
    signIn.start(appleID: "ada@example.org", password: "hunter2")
    _ = await until("no anisette") { signIn.failure != nil }
    check(Library.calls.count == 6 && Set(Library.calls.map(\.server)) == Set(defaults) && signIn.failure?.contains("end provisioning error") == true,
          "every server is tried once, then the last one's reason is given")

    // 8. The Keychain does not take it.
    SigningAccountStore.fails = true
    Library.reset { _ in .signedIn(signedIn) }
    signIn = AppleSignIn()
    signIn.start(appleID: "ada@example.org", password: "hunter2")
    _ = await until("keychain") { signIn.failure != nil }
    check(signIn.phase == .entering && signIn.failure?.contains("Keychain") == true && SigningRefresh.shared.signedInCount == told, "a sign-in the Keychain does not take is not announced")
    SigningAccountStore.fails = false

    // Nothing that identifies the account is logged.
    check(LogStore.shared.lines.contains { $0.contains("[signing] sign-in") }
          && LogStore.shared.lines.allSatisfy { !$0.contains("example.org") && !$0.contains("hunter2") && !$0.contains("NEWTOKEN") && !$0.contains("000999") && !$0.contains("111111") },
          "the log names no Apple ID, password, code or token")
    // An empty field starts nothing.
    Library.reset { _ in .signedIn(signedIn) }
    signIn = AppleSignIn()
    signIn.start(appleID: " ", password: "hunter2")
    signIn.start(appleID: "ada@example.org", password: "")
    check(signIn.phase == .entering && Library.calls.isEmpty, "nothing starts without an Apple ID and a password")
}

Task {
    await portalChecks()
    await signInChecks()
    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
