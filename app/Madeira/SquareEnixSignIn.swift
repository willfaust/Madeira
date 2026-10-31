// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Trey Boyer
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CryptoKit
import Foundation

// Square Enix sign-in for FINAL FANTASY XIV, written from the protocol
// specification in docs/SQUARE_ENIX_SIGNIN.md; "step N" below is the step of
// that document. Foundation and CryptoKit only, so
// tests/host/check-square-enix-signin.py compiles this file on a Mac with a
// stand-in transport.
//
// Nothing here logs or returns in an error the password, the one-time
// password, the _STORED_ token, the SID or the session ID. Transport errors
// are never passed on as they are: step 6's URL ends in the SID, and a
// URLError carries its URL. The boot hash (sizes and SHA-1s of Square Enix's
// public boot programs) is logged in full, because step 6 fails when it is
// wrong.

/// Which license the account plays on (Game details › Square Enix › License).
enum SquareEnixLicense: String, Codable, CaseIterable {
    case windows, mac

    /// Steps 1, 3 and 4. The Mac form is what Square Enix's macOS app sent; the
    /// Windows form is the wiki's and unconfirmed.
    func signInUserAgent(installID: String) -> String {
        switch self {
        case .mac: return "macSQEXAuthor/2.0.0(MacOSX; ja-jp)"
        case .windows: return "SQEXAuthor/2.0.0(Windows 6.2; ja-jp; \(installID))"
        }
    }

    /// Steps 2 and 6. The launcher holds both strings; which one it sends in
    /// step 6 is inferred, so SquareEnixSignInOptions can override it.
    var patchUserAgent: String { self == .mac ? "FFXIV-MAC PATCH CLIENT" : "FFXIV PATCH CLIENT" }
}

struct SquareEnixSignInOptions {
    var license: SquareEnixLicense
    /// `isft` of step 3.
    var freeTrial = false
    /// `lng` of step 3: the launcher's language setting.
    var language = "en"
    /// `lang` of the gate check (step 1), in the frontier server's form.
    var frontierLanguage = "en-us"
    /// `rgn` of step 3. The launcher sends its region setting; signing in with 3
    /// instead of 2 changed nothing (the reply's own `region` stayed 2), so
    /// Madeira always sends 2 and starts the client with the reply's region.
    var region = 2
    /// The per-installation id in the Windows User-Agent (newInstallID()).
    var installID: String
    /// Steps 2 and 6; nil sends the license's form.
    var patchUserAgent: String? = nil

    /// Ten lowercase hex digits: four random bytes and a check byte that makes
    /// the five add up to a multiple of 256. The login page refuses an ID
    /// without it (docs/SQUARE_ENIX_SIGNIN.md, "Windows and Mac licenses").
    /// Kept by the caller.
    static func newInstallID() -> String {
        let data = (0..<4).map { _ in UInt8.random(in: 0...255) }
        let check = UInt8(truncatingIfNeeded: 256 - data.reduce(0) { $0 + Int($1) } % 256)
        return (data + [check]).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidInstallID(_ id: String) -> Bool {
        guard id.count == 10, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return false }
        let bytes = stride(from: 0, to: 10, by: 2).compactMap {
            UInt8(id[id.index(id.startIndex, offsetBy: $0)..<id.index(id.startIndex, offsetBy: $0 + 2)], radix: 16)
        }
        return bytes.count == 5 && bytes.reduce(0) { $0 + Int($1) } % 256 == 0
    }
}

struct SquareEnixCredentials {
    var id: String
    var password: String
    /// Empty when the account has no one-time password.
    var oneTimePassword = ""
}

/// The steps, in the order SquareEnixSignIn runs them; shown as progress.
enum SquareEnixStep: String, CaseIterable {
    case status, bootCheck, loginPage, credentials, gate, session
}

enum SquareEnixSignInError: Error, Equatable, LocalizedError {
    /// No reply, or a network error.
    case unreachable(SquareEnixStep)
    /// A reply this code does not understand.
    case unexpectedReply(SquareEnixStep)
    /// Sign-in or the gate is closed (maintenance).
    case closed
    /// The boot or game files are not current; the target version when the patch list names one.
    case gameUpdateNeeded(String?)
    /// Square Enix's own message, shown as sent.
    case refused(String)
    case notPlayable
    /// Step 6 gave no session ID: an update is needed or the game's files were changed.
    case sessionRejected
    /// A version file or boot program could not be read.
    case installUnreadable(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Couldn't reach Square Enix. Check your internet connection and try again."
        case .unexpectedReply:
            return "Square Enix sent a reply Madeira doesn't understand. Try again later."
        case .closed:
            return "FINAL FANTASY XIV is under maintenance. Check the FFXIV Lodestone for more details."
        case .gameUpdateNeeded(let target):
            return "The game needs an update" + (target.map { " (to \($0))" } ?? "") + " before you can play."
        case .refused(let message):
            return message
        case .notPlayable:
            return "This account can't play right now. Check its subscription or license on the Mog Station."
        case .sessionRejected:
            return "Square Enix didn't start a game session. The game may need an update, or its files were changed."
        case .installUnreadable(let file):
            return "Madeira couldn't read the game's \(file)."
        case .cancelled:
            return "Sign-in was cancelled."
        }
    }
}

/// A FINAL FANTASY XIV installation: the folder holding boot/ and game/.
struct FFXIVInstall: Equatable {
    let root: URL

    /// The game's own programs a library entry may name.
    static let programs = ["boot/ffxivboot.exe", "boot/ffxivboot64.exe", "boot/ffxivlauncher64.exe", "game/ffxiv_dx11.exe"]

    /// Step 5, in the wiki's order; the files the installation lacks are left out.
    static let bootHashFiles = ["ffxivboot.exe", "ffxivboot64.exe", "ffxivlauncher.exe",
                                "ffxivlauncher64.exe", "ffxivupdater.exe", "ffxivupdater64.exe"]

    struct Expansion: Equatable {
        let number: Int
        let version: String
    }

    struct Versions: Equatable {
        let boot: String
        let game: String
        /// The installed expansions, in order.
        let expansions: [Expansion]
    }

    /// The installation `program` belongs to, or nil when it is not one of the
    /// game's own programs beside boot/ffxivboot.ver and game/ffxivgame.ver.
    init?(program: URL, fileManager: FileManager = .default) {
        let program = program.standardizedFileURL
        let tail = program.pathComponents.suffix(2).joined(separator: "/").lowercased()
        guard program.pathComponents.count > 2, Self.programs.contains(tail) else { return nil }
        let root = program.deletingLastPathComponent().deletingLastPathComponent()
        guard fileManager.fileExists(atPath: root.appendingPathComponent("boot/ffxivboot.ver").path),
              fileManager.fileExists(atPath: root.appendingPathComponent("game/ffxivgame.ver").path) else { return nil }
        self.root = root
    }

    /// What Play starts, whichever program the entry names (step 7).
    var clientProgram: URL { root.appendingPathComponent("game/ffxiv_dx11.exe") }

    func versions(fileManager: FileManager = .default) throws -> Versions {
        let sqpack = root.appendingPathComponent("game/sqpack")
        var expansions: [Expansion] = []
        for name in (try? fileManager.contentsOfDirectory(atPath: sqpack.path)) ?? [] {
            guard name.hasPrefix("ex"), let number = Int(name.dropFirst(2)), number > 0, "ex\(number)" == name else { continue }
            let file = sqpack.appendingPathComponent("\(name)/\(name).ver")
            guard fileManager.fileExists(atPath: file.path) else { continue }
            expansions.append(Expansion(number: number, version: try Self.version(at: file, name: "\(name).ver")))
        }
        return Versions(boot: try Self.version(at: root.appendingPathComponent("boot/ffxivboot.ver"), name: "ffxivboot.ver"),
                        game: try Self.version(at: root.appendingPathComponent("game/ffxivgame.ver"), name: "ffxivgame.ver"),
                        expansions: expansions.sorted { $0.number < $1.number })
    }

    /// Step 5's string: name/size/sha1 per boot program present, joined with commas.
    func bootHash(fileManager: FileManager = .default) throws -> String {
        var parts: [String] = []
        for name in Self.bootHashFiles {
            let file = root.appendingPathComponent("boot/\(name)")
            guard fileManager.fileExists(atPath: file.path) else { continue }
            guard let (size, sha1) = try? Self.sizeAndSHA1(of: file) else { throw SquareEnixSignInError.installUnreadable(name) }
            parts.append("\(name)/\(size)/\(sha1)")
        }
        guard !parts.isEmpty else { throw SquareEnixSignInError.installUnreadable("boot programs") }
        return parts.joined(separator: ",")
    }

    /// A version file's text, which goes into URLs and step 6's body, so only
    /// the YYYY.MM.DD.NNNN.NNNN shape is accepted.
    static func version(at file: URL, name: String) throws -> String {
        guard let data = try? Data(contentsOf: file) else { throw SquareEnixSignInError.installUnreadable(name) }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isVersion(text) else { throw SquareEnixSignInError.installUnreadable(name) }
        return text
    }

    static func isVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.map(\.count) == [4, 2, 2, 4, 4] && parts.allSatisfy { $0.allSatisfy { ("0"..."9").contains($0) } }
    }

    static func sizeAndSHA1(of file: URL) throws -> (Int, String) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        var size = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += chunk.count
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

/// The account values step 4 returns, from its name, value pairs.
struct SquareEnixAccount: Equatable {
    let sid: String
    let region: Int
    let maxExpansion: Int
    let playable: Bool
    /// Every pair, for logging; holds the SID, so never log it whole.
    let fields: [String: String]

    init?(fields: [String: String]) {
        guard let sid = fields["sid"], !sid.isEmpty, sid.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let region = fields["region"].flatMap({ Int($0) }), let maxExpansion = fields["maxex"].flatMap({ Int($0) })
        else { return nil }
        self.sid = sid
        self.region = region
        self.maxExpansion = maxExpansion
        self.playable = fields["playable"] == "1"
        self.fields = fields
    }
}

/// What a successful sign-in starts (step 7).
struct SquareEnixLaunch: Equatable {
    let program: URL
    let arguments: [String]
}

/// Requests and replies of each step, without any networking.
enum SquareEnixProtocol {
    static let loginStatusURL = URL(string: "https://frontier.ffxiv.com/worldStatus/login_status.json")!
    static let loginSendURL = URL(string: "https://ffxiv-login.square-enix.com/oauth/ffxivarr/login/login.send")!

    static func gateStatusURL(language: String) -> URL {
        var components = URLComponents(string: "https://frontier.ffxiv.com/worldStatus/gate_status.json")!
        components.queryItems = [URLQueryItem(name: "lang", value: language)]
        return components.url!
    }

    static func loginPageURL(_ options: SquareEnixSignInOptions) -> URL {
        var components = URLComponents(string: "https://ffxiv-login.square-enix.com/oauth/ffxivarr/login/top")!
        components.queryItems = [
            URLQueryItem(name: "lng", value: options.language),
            URLQueryItem(name: "rgn", value: String(options.region)),
            URLQueryItem(name: "isft", value: options.freeTrial ? "1" : "0"),
            URLQueryItem(name: "cssmode", value: "2"),
            URLQueryItem(name: "isnew", value: "1"),
            URLQueryItem(name: "launchver", value: "3"),
        ]
        return components.url!
    }

    /// Plain HTTP: the host's HTTPS certificate does not cover it (step 2).
    static func bootCheckURL(bootVersion: String) -> URL {
        URL(string: "http://patch-bootver.ffxiv.com/http/win32/ffxivneo_release_boot/\(bootVersion)")!
    }

    /// `sid` is checked to be ASCII letters and digits (SquareEnixAccount), and
    /// the version's shape by FFXIVInstall, so neither can change the path.
    static func sessionURL(gameVersion: String, sid: String) -> URL {
        URL(string: "https://patch-gamever.ffxiv.com/http/win32/ffxivneo_release_game/\(gameVersion)/\(sid)")!
    }

    static func statusRequest(_ url: URL, userAgent: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        return request
    }

    static func loginPageRequest(_ options: SquareEnixSignInOptions) -> URLRequest {
        var request = URLRequest(url: loginPageURL(options))
        request.setValue(options.license.signInUserAgent(installID: options.installID), forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    /// The form fields in the order the launcher sent them; `saveid` is left
    /// out, as a page with "Remember Square Enix ID" unticked would.
    static func credentialsRequest(stored: String, credentials: SquareEnixCredentials,
                                   options: SquareEnixSignInOptions) -> URLRequest {
        var request = URLRequest(url: loginSendURL)
        request.httpMethod = "POST"
        request.setValue(options.license.signInUserAgent(installID: options.installID), forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(loginSendURL.absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = formBody([("token", ""), ("_STORED_", stored), ("sqexid", credentials.id),
                                     ("password", credentials.password), ("otppw", credentials.oneTimePassword)])
        return request
    }

    static func bootCheckRequest(bootVersion: String, userAgent: String) -> URLRequest {
        var request = URLRequest(url: bootCheckURL(bootVersion: bootVersion))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static func sessionRequest(gameVersion: String, sid: String, body: String, userAgent: String) -> URLRequest {
        var request = URLRequest(url: sessionURL(gameVersion: gameVersion, sid: sid))
        request.httpMethod = "POST"
        request.setValue("enabled", forHTTPHeaderField: "X-Hash-Check")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return request
    }

    /// Step 6's body: the boot version and hash, then a tab-separated line per
    /// expansion, with no newline after the last line.
    static func sessionBody(versions: FFXIVInstall.Versions, bootHash: String) -> String {
        (["\(versions.boot)=\(bootHash)"] + versions.expansions.map { "ex\($0.number)\t\($0.version)" })
            .joined(separator: "\n")
    }

    /// application/x-www-form-urlencoded with everything but ASCII letters,
    /// digits and -._~ percent-encoded, so a password's +, &, = or % (or any
    /// non-ASCII letter) reaches the server as typed.
    static func formBody(_ pairs: [(String, String)]) -> Data {
        Data(pairs.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&").utf8)
    }

    static let formSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func formEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: formSafe) ?? ""
    }

    /// Steps 1: open when the JSON object's `status` is 1.
    static func isOpen(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (object["status"] as? Int) == 1
    }

    /// Step 3: the `value` of the input named `_STORED_`, wherever its
    /// attributes are and however they are spaced.
    static func storedToken(inLoginPage html: String) -> String? {
        var rest = html[...]
        while let start = rest.range(of: "<input", options: .caseInsensitive) {
            guard let end = rest[start.upperBound...].firstIndex(of: ">") else { return nil }
            let attributes = tagAttributes(String(rest[start.upperBound..<end]))
            if attributes["name"] == "_STORED_", let value = attributes["value"], !value.isEmpty {
                return decodeEntities(value)
            }
            rest = rest[end...]
        }
        return nil
    }

    /// name="value" and name='value' attributes of one tag; names lowercased.
    static func tagAttributes(_ tag: String) -> [String: String] {
        var attributes: [String: String] = [:]
        var index = tag.startIndex
        func skipSpaces() { while index < tag.endIndex, tag[index].isWhitespace { index = tag.index(after: index) } }
        while index < tag.endIndex {
            skipSpaces()
            let nameStart = index
            while index < tag.endIndex, !tag[index].isWhitespace, tag[index] != "=", tag[index] != "/" {
                index = tag.index(after: index)
            }
            let name = tag[nameStart..<index].lowercased()
            skipSpaces()
            guard index < tag.endIndex, tag[index] == "=" else {
                if index < tag.endIndex, name.isEmpty { index = tag.index(after: index) }
                continue
            }
            index = tag.index(after: index)
            skipSpaces()
            guard index < tag.endIndex else { break }
            let quote = tag[index]
            if quote == "\"" || quote == "'" {
                let valueStart = tag.index(after: index)
                guard let valueEnd = tag[valueStart...].firstIndex(of: quote) else { break }
                attributes[name] = String(tag[valueStart..<valueEnd])
                index = tag.index(after: valueEnd)
            } else {
                let valueStart = index
                while index < tag.endIndex, !tag[index].isWhitespace { index = tag.index(after: index) }
                attributes[name] = String(tag[valueStart..<index])
            }
        }
        return attributes
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            output += rest[..<amp]
            guard let semicolon = rest[amp...].firstIndex(of: ";"), rest.distance(from: amp, to: semicolon) <= 10 else {
                output += rest[amp...]
                return output
            }
            let entity = rest[rest.index(after: amp)..<semicolon]
            let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]
            var scalar: Unicode.Scalar?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
            } else if entity.hasPrefix("#") {
                scalar = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init)
            }
            if let replacement = named[String(entity)] ?? scalar.map({ String(Character($0)) }) {
                output += replacement
            } else {
                output += rest[amp...semicolon]
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        return output + rest
    }

    enum LoginReply: Equatable {
        case signedIn([String: String])
        /// Square Enix's message, as sent.
        case refused(String)
        case unrecognised
    }

    /// Step 4: the string passed to window.external.user(...). Lines that are
    /// comments are skipped: every login page carries a commented-out call
    /// with an error message, whatever the outcome.
    static func loginReply(_ html: String) -> LoginReply {
        let ok = "login=auth,ok,", refused = "login=auth,ng,err,"
        for raw in html.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), let call = line.range(of: "window.external.user(") else { continue }
            guard let argument = stringLiteral(startingAt: call.upperBound, in: line) else { continue }
            if argument.hasPrefix(ok) {
                let values = argument.dropFirst(ok.count).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard values.count % 2 == 0 else { return .unrecognised }
                var fields: [String: String] = [:]
                for pair in stride(from: 0, to: values.count, by: 2) { fields[values[pair]] = values[pair + 1] }
                return .signedIn(fields)
            }
            if argument.hasPrefix(refused) {
                let message = argument.dropFirst(refused.count).trimmingCharacters(in: .whitespacesAndNewlines)
                return .refused(message.isEmpty ? "Square Enix refused the sign-in." : message)
            }
        }
        return .unrecognised
    }

    /// A JavaScript string literal ('…' or "…") at `index`, with its escapes undone.
    static func stringLiteral(startingAt index: String.Index, in line: String) -> String? {
        var index = index
        while index < line.endIndex, line[index].isWhitespace { index = line.index(after: index) }
        guard index < line.endIndex, line[index] == "\"" || line[index] == "'" else { return nil }
        let quote = line[index]
        var value = ""
        index = line.index(after: index)
        while index < line.endIndex {
            let character = line[index]
            if character == quote { return value }
            if character == "\\" {
                index = line.index(after: index)
                guard index < line.endIndex else { return nil }
                switch line[index] {
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                default: value.append(line[index])
                }
            } else {
                value.append(character)
            }
            index = line.index(after: index)
        }
        return nil
    }

    enum BootCheck: Equatable {
        case current
        /// The version the patch list ends at, when it names one.
        case update(String?)
        case unknownVersion
        case unexpected(Int)
    }

    /// Step 2: 204 (or an empty 200, the wiki's reading) is current; a 200
    /// patch list or a 404 for an unknown version is not.
    static func bootCheck(status: Int, body: Data) -> BootCheck {
        switch status {
        case 204: return .current
        case 200:
            let targets = patchTargets(body)
            return targets.isEmpty && body.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 })
                ? .current : .update(targets.last)
        case 404: return .unknownVersion
        default: return .unexpected(status)
        }
    }

    /// The target versions of a patch list: the fifth tab-separated field of
    /// each line that has one.
    static func patchTargets(_ body: Data) -> [String] {
        String(decoding: body, as: UTF8.self).components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 6 else { return nil }
            let target = fields[4].trimmingCharacters(in: .whitespaces)
            return FFXIVInstall.isVersion(target) ? target : nil
        }
    }

    /// Step 6's session ID, from the X-Patch-Unique-Id header.
    static func sessionID(from response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: "X-Patch-Unique-Id")?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty, value.allSatisfy({ $0.isASCII && !$0.isWhitespace && $0.asciiValue.map { $0 >= 0x21 && $0 < 0x7F } == true })
        else { return nil }
        return value
    }

    /// Step 7: one `name=value` token per argument, unencrypted; the client
    /// started and played with exactly these (iPhone, 2026-10-29). `language`
    /// is left out: it was not needed, and its value format is unknown.
    static func clientArguments(sessionID: String, account: SquareEnixAccount, gameVersion: String) -> [String] {
        ["DEV.DataPathType=1", "DEV.MaxEntitledExpansionID=\(account.maxExpansion)", "DEV.TestSID=\(sessionID)",
         "DEV.UseSqPack=1", "SYS.Region=\(account.region)", "ver=\(gameVersion)"]
    }
}

protocol SquareEnixTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// An ephemeral URLSession per sign-in: no cookie (such as the remembered-ID
/// `_rsid`) or cache outlives it.
final class SquareEnixURLSessionTransport: SquareEnixTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Runs steps 1 to 6 and returns what to start (step 7).
final class SquareEnixSignIn {
    private let transport: SquareEnixTransport
    private let log: (String) -> Void

    init(transport: SquareEnixTransport = SquareEnixURLSessionTransport(), log: @escaping (String) -> Void) {
        self.transport = transport
        self.log = log
    }

    func signIn(install: FFXIVInstall, options: SquareEnixSignInOptions, credentials: SquareEnixCredentials,
                progress: @escaping (SquareEnixStep) -> Void = { _ in }) async throws -> SquareEnixLaunch {
        do {
            return try await run(install: install, options: options, credentials: credentials, progress: progress)
        } catch is CancellationError {
            log("[sqex-signin] cancelled")
            throw SquareEnixSignInError.cancelled
        }
    }

    private func run(install: FFXIVInstall, options: SquareEnixSignInOptions, credentials: SquareEnixCredentials,
                     progress: (SquareEnixStep) -> Void) async throws -> SquareEnixLaunch {
        let versions = try install.versions()
        let signInAgent = options.license.signInUserAgent(installID: options.installID)
        let patchAgent = options.patchUserAgent ?? options.license.patchUserAgent
        log("[sqex-signin] start license=\(options.license.rawValue) trial=\(options.freeTrial ? 1 : 0) " +
            "boot=\(versions.boot) game=\(versions.game) ex=\(versions.expansions.map { "\($0.number):\($0.version)" }.joined(separator: ","))")

        progress(.status)
        try await requireOpen(SquareEnixProtocol.loginStatusURL, userAgent: signInAgent, step: .status, name: "login status")

        progress(.bootCheck)
        let (bootBody, bootReply) = try await send(
            SquareEnixProtocol.bootCheckRequest(bootVersion: versions.boot, userAgent: patchAgent), step: .bootCheck)
        let bootCheck = SquareEnixProtocol.bootCheck(status: bootReply.statusCode, body: bootBody)
        log("[sqex-signin] boot check: HTTP \(bootReply.statusCode) \(bootCheck)")
        switch bootCheck {
        case .current: break
        case .update(let target): throw SquareEnixSignInError.gameUpdateNeeded(target)
        case .unknownVersion: throw SquareEnixSignInError.gameUpdateNeeded(nil)
        case .unexpected: throw SquareEnixSignInError.unexpectedReply(.bootCheck)
        }

        progress(.loginPage)
        let (page, pageReply) = try await send(SquareEnixProtocol.loginPageRequest(options), step: .loginPage)
        guard pageReply.statusCode == 200,
              let stored = SquareEnixProtocol.storedToken(inLoginPage: String(decoding: page, as: UTF8.self)) else {
            log("[sqex-signin] login page: HTTP \(pageReply.statusCode), no _STORED_ input")
            throw SquareEnixSignInError.unexpectedReply(.loginPage)
        }

        try Task.checkCancellation()
        progress(.credentials)
        let (reply, credentialsReply) = try await send(
            SquareEnixProtocol.credentialsRequest(stored: stored, credentials: credentials, options: options), step: .credentials)
        guard credentialsReply.statusCode == 200 else {
            log("[sqex-signin] credentials: HTTP \(credentialsReply.statusCode)")
            throw SquareEnixSignInError.unexpectedReply(.credentials)
        }
        let account: SquareEnixAccount
        switch SquareEnixProtocol.loginReply(String(decoding: reply, as: UTF8.self)) {
        case .refused(let message):
            log("[sqex-signin] credentials refused by Square Enix")
            throw SquareEnixSignInError.refused(message)
        case .unrecognised:
            log("[sqex-signin] credentials: reply not understood")
            throw SquareEnixSignInError.unexpectedReply(.credentials)
        case .signedIn(let fields):
            guard let parsed = SquareEnixAccount(fields: fields) else {
                log("[sqex-signin] credentials: fields \(fields.keys.sorted().joined(separator: ",")) lack sid, region or maxex")
                throw SquareEnixSignInError.unexpectedReply(.credentials)
            }
            account = parsed
        }
        log("[sqex-signin] signed in: " + account.fields.filter { $0.key != "sid" }.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        guard account.playable else { throw SquareEnixSignInError.notPlayable }

        progress(.gate)
        try await requireOpen(SquareEnixProtocol.gateStatusURL(language: options.frontierLanguage),
                              userAgent: signInAgent, step: .gate, name: "gate status")

        try Task.checkCancellation()
        progress(.session)
        let bootHash = try install.bootHash()
        log("[sqex-signin] boot hash: \(bootHash)")
        let body = SquareEnixProtocol.sessionBody(versions: versions, bootHash: bootHash)
        let (sessionBody, sessionReply) = try await send(
            SquareEnixProtocol.sessionRequest(gameVersion: versions.game, sid: account.sid, body: body, userAgent: patchAgent),
            step: .session)
        // An outdated game gets a patch list AND an X-Patch-Unique-Id (2026-10-31),
        // so a list in the body stops here before the header is trusted.
        let pending = SquareEnixProtocol.patchTargets(sessionBody)
        if !pending.isEmpty {
            log("[sqex-signin] session: HTTP \(sessionReply.statusCode), \(pending.count) game patches pending, to \(pending.max()!)")
            throw SquareEnixSignInError.gameUpdateNeeded(pending.max())
        }
        guard let sessionID = SquareEnixProtocol.sessionID(from: sessionReply) else {
            let targets = SquareEnixProtocol.patchTargets(sessionBody)
            log("[sqex-signin] session: HTTP \(sessionReply.statusCode), no X-Patch-Unique-Id, body \(sessionBody.count) bytes" +
                (targets.isEmpty ? "" : ", patches to \(targets.joined(separator: ","))"))
            throw SquareEnixSignInError.sessionRejected
        }
        log("[sqex-signin] session registered: HTTP \(sessionReply.statusCode)")
        return SquareEnixLaunch(program: install.clientProgram,
                                arguments: SquareEnixProtocol.clientArguments(sessionID: sessionID, account: account,
                                                                               gameVersion: versions.game))
    }

    private func requireOpen(_ url: URL, userAgent: String, step: SquareEnixStep, name: String) async throws {
        let (data, reply) = try await send(SquareEnixProtocol.statusRequest(url, userAgent: userAgent), step: step)
        let open = reply.statusCode == 200 && SquareEnixProtocol.isOpen(data)
        log("[sqex-signin] \(name): HTTP \(reply.statusCode) \(open ? "open" : "closed")")
        guard open else { throw SquareEnixSignInError.closed }
    }

    /// Only the step and the URLError code are logged: the error's URL may hold the SID.
    private func send(_ request: URLRequest, step: SquareEnixStep) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            log("[sqex-signin] \(step.rawValue): no reply (URLError \((error as? URLError)?.code.rawValue ?? 0))")
            throw SquareEnixSignInError.unreachable(step)
        }
    }
}
