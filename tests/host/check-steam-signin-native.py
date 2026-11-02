#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Host checks for Steam sign-in (app/Madeira/SwiftSteam); never contacts Steam.

Part A is static: every file carries its licence header, the sign-in files hold
no library, download or launch code (the owned library and downloads have their
own files and their own test, check-steam-library.py), the Keychain item stays
on this device, and no log line interpolates a credential.

Part B compiles the production Swift on the host (protobuf helpers, the
IAuthenticationService messages, SteamError, SteamAuthAPI and the pure part of
SteamSignIn) and checks Valve's field numbers, response decoding, hostile
lengths, the x-eresult mapping, the request shapes through a stub URLProtocol,
and the token-expiry rule behind SteamSignIn.credentialsForDock().
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
steam = app / 'SwiftSteam'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def block(source, start_marker):
    """Return the declaration starting at start_marker through its closing brace."""
    start = source.index(start_marker)
    depth, i = 0, source.index('{', start)
    while True:
        c = source[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return source[start:i + 1] + '\n'
        i += 1


# ---------------------------------------------------------------- Part A
files = sorted(steam.rglob('*.swift'))
signin_files = {'SteamSignIn.swift', 'SteamSignInView.swift', 'SteamAuthAPI.swift', 'SteamCredentialAuth.swift',
                'SteamQRAuth.swift', 'SteamTokenStore.swift', 'SteamError.swift', 'SteamProtoMessages.swift',
                'SteamDevice.swift', 'SteamLog.swift'}
# The owned library and downloads (docs/STEAM_LIBRARY.md). SteamError and SteamProtoMessages are shared.
library_files = {'CMServerList.swift', 'LicenseListBox.swift', 'SteamCMSession.swift', 'SteamConnection.swift', 'SteamMessageCodec.swift',
                 'SteamProtocol.swift', 'SteamSession.swift', 'ContentDecryptor.swift', 'DepotDownloader.swift',
                 'DepotManifest.swift', 'SteamLANPeer.swift', 'SteamAppInfo.swift', 'SteamLibraryFetcher.swift', 'AppManifestWriter.swift'}
shared_files = {'SteamError.swift', 'SteamProtoMessages.swift'}
require(signin_files <= {f.name for f in files} <= signin_files | library_files,
        'SwiftSteam holds the sign-in files and, besides them, only the library files (check-steam-library.py lists those)')
require({f.name for f in steam.rglob('*') if f.is_file() and f.suffix != '.swift'} <=
        {'chunk_zip.c', 'chunk_zip.h', 'lzma_shim.c', 'lzma_shim.h', 'zstd_edu.c', 'zstd_edu.h'},
        'the only C sources in SwiftSteam are the content decoders')
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
for f in files:
    rel = f.relative_to(app).as_posix()
    text = f.read_text()
    require(f'/* {rel} in Sources */' in project, f'{rel} is built by the Xcode project')
    head = text.split('\n', 3)
    require(head[0] == '// SPDX-License-Identifier: GPL-3.0-or-later' and head[1].startswith('// Copyright 2026 ')
            and head[2] == '// Madeira Converter Exception: see LICENSE-EXCEPTION.md', f'{rel} licence header')
    if 'Jfishin' in head[1]:
        require("Derived from Jfishin's Madeira Steam client" in text or "Jfishin's" in text, f'{rel} credits Jfishin')
    # No depot, library, CM connection or launch code belongs in the sign-in files.
    if f.name in signin_files and f.name not in shared_files:
        for word in ['DepotDownloader', 'SteamSession', 'SteamConnection', 'CMsgClientLogon', 'ChannelEncrypt',
                     'PICS', 'appmanifest', 'steamclient64', 'steamclient.dll', 'LaunchApp', 'emulat']:
            require(word not in text, f'{rel} has no {word}')
    # Credentials never reach a log line.
    for line in text.splitlines():
        if re.search(r'SteamLog\.(event|trace)|LogStore|print\(|NSLog|os_log', line):
            bad = re.search(r'\\\((password|refresh|access|refreshToken|accessToken|account|accountName|name|token|tokens|guardCode)\b', line)
            require(bad is None, f'{rel}: no credential interpolated in "{line.strip()[:60]}"')
store = (steam / 'Auth/SteamTokenStore.swift').read_text()
require('kSecAttrAccessibleWhenUnlockedThisDeviceOnly' in store, 'Keychain item stays on this device, available while unlocked')
require('kSecAttrSynchronizable' not in store, 'Keychain item is not synchronised')
signin_view = (steam / 'SteamSignInView.swift').read_text()
require('password = ""' in signin_view, 'the password field is cleared after submitting')
content = (app / 'ContentView.swift').read_text()
require('Button("Steam sign-in")' in content and 'SteamSignIn.isEnabled' in content, 'developer interface opens the sheet')

# ---------------------------------------------------------------- Part B
signin = (steam / 'SteamSignIn.swift').read_text()
api = (steam / 'Auth/SteamAuthAPI.swift').read_text()
stubs = r'''
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
enum MadeiraConfig { static func get(_ key: String) -> String? { nil } }
enum SteamLog { static func trace(_ m: @autoclosure () -> String) {}; static func event(_ m: String) {} }
final class SteamTokenStore {
    struct StoredTokens { var accountName: String; var refreshToken: String; var accessToken: String; var steamID: UInt64; var savedAt: Date }
    static var saved: StoredTokens?
    func saveTokens(accountName: String, refreshToken: String, accessToken: String, steamID: UInt64) {
        Self.saved = StoredTokens(accountName: accountName, refreshToken: refreshToken, accessToken: accessToken, steamID: steamID, savedAt: Date())
    }
    func loadTokens() -> StoredTokens? { Self.saved }
    func clearTokens() { Self.saved = nil }
}
'''
api_source = api.replace('import Foundation\n', 'import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n', 1)

checks = r'''
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}
func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

/// Stub transport: records the request and answers with the queued response.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var eresult: String? = "1"
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastURL: URL?
    nonisolated(unsafe) static var lastMethod: String?
    nonisolated(unsafe) static var lastBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastURL = request.url; Self.lastMethod = request.httpMethod
        if let body = request.httpBody { Self.lastBody = body }
        else if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close(); Self.lastBody = data
        } else { Self.lastBody = nil }
        var headers: [String: String] = [:]
        if let e = Self.eresult { headers["X-eresult"] = e }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func expectError(_ expected: SteamError, _ label: String, _ run: () async throws -> Data) async {
    do { _ = try await run(); require(false, label) }
    catch let error as SteamError { require(error == expected, label + " (\(error))") }
    catch { require(false, label + " (\(error))") }
}

@main struct Checks {
    static func main() async throws {
        // Requests carry Valve's field numbers (steammessages_auth.steamclient.proto).
        var rsa = CAuthentication_GetPasswordRSAPublicKey_Request(); rsa.accountName = "abc"
        require(hex(rsa.serialize()) == "0a03616263", "GetPasswordRSAPublicKey: account_name = 1")

        var begin = CAuthentication_BeginAuthSessionViaCredentials_Request()
        begin.accountName = "acct"; begin.encryptedPassword = "PW=="; begin.encryptionTimestamp = 300
        begin.deviceFriendlyName = "dev"
        var e = ProtobufDecoder(begin.serialize()); var fields: [UInt32: Int] = [:]
        var strings: [UInt32: String] = [:]; var ints: [UInt32: UInt64] = [:]
        while let tag = try e.readTag() {
            fields[tag.fieldNumber, default: 0] += 1
            switch tag.wireType {
            case .lengthDelimited: let d = try e.readBytes(); strings[tag.fieldNumber] = String(decoding: d, as: UTF8.self)
            case .varint: ints[tag.fieldNumber] = try e.readVarint()
            default: try e.skip(wireType: tag.wireType)
            }
        }
        require(strings[1] == "dev" && strings[2] == "acct" && strings[3] == "PW==", "credentials: device name 1, account 2, encrypted password 3")
        require(ints[4] == 300 && ints[6] == 1 && ints[7] == 1, "credentials: timestamp 4, platform 6 (SteamClient), persistence 7")
        require(strings[8] == "Client" && fields[9] == 1, "credentials: website_id 8 and device_details 9")

        var qr = CAuthentication_BeginAuthSessionViaQR_Request(); qr.deviceFriendlyName = "d"
        require(hex(qr.serialize()) == "0a01641001", "BeginAuthSessionViaQR: device name 1, platform 2")

        var code = CAuthentication_UpdateAuthSessionWithSteamGuardCode_Request()
        code.clientID = 5; code.steamid = 0x0110000100000001; code.code = "AB12C"; code.codeType = 3
        require(hex(code.serialize()) == "0805" + "11" + "0100000001001001" + "1a054142313243" + "2003",
                "UpdateAuthSessionWithSteamGuardCode: client 1, fixed64 steamid 2, code 3, type 4")

        var poll = CAuthentication_PollAuthSessionStatus_Request(); poll.clientID = 300; poll.requestID = Data([9, 8])
        require(hex(poll.serialize()) == "08ac02" + "12020908", "PollAuthSessionStatus: client 1, request id 2")

        // Responses.
        var r = Data([0x0a, 0x02]) + Data(bytes("ab")) + Data([0x12, 0x02]) + Data(bytes("03")) + Data([0x18, 0x96, 0x01])
        let rsaResponse = try CAuthentication_GetPasswordRSAPublicKey_Response.deserialize(from: r)
        require(rsaResponse.publicKeyMod == "ab" && rsaResponse.publicKeyExp == "03" && rsaResponse.timestamp == 150, "RSA key response")

        let five = Float(2.5).bitPattern
        r = Data([0x08, 0x07, 0x12, 0x01, 0x42, 0x1d]) + withUnsafeBytes(of: five.littleEndian) { Data($0) }
        r += Data([0x22, 0x02, 0x08, 0x03, 0x22, 0x07, 0x08, 0x02, 0x12, 0x03]) + Data(bytes("x.y"))
        r += Data([0x28, 0x2a])
        let started = try CAuthentication_BeginAuthSessionViaCredentials_Response.deserialize(from: r)
        require(started.clientID == 7 && started.requestID == Data([0x42]) && started.interval == 2.5, "credentials response: client, request, float interval")
        require(started.allowedConfirmations.map(\.confirmationType) == [3, 2] && started.allowedConfirmations[1].associatedMessage == "x.y",
                "credentials response: every allowed confirmation with its hint")
        require(started.steamid == 42, "credentials response: varint steamid")

        r = Data([0x08, 0x01, 0x12, 0x03]) + Data(bytes("u:1")) + Data([0x1a, 0x01, 0x07, 0x25]) + withUnsafeBytes(of: five.littleEndian) { Data($0) }
        let qrResponse = try CAuthentication_BeginAuthSessionViaQR_Response.deserialize(from: r)
        require(qrResponse.clientID == 1 && qrResponse.challengeURL == "u:1" && qrResponse.requestID == Data([7]) && qrResponse.interval == 2.5, "QR response")

        r = Data([0x08, 0x09, 0x12, 0x01]) + Data(bytes("n")) + Data([0x1a, 0x01]) + Data(bytes("R")) + Data([0x22, 0x01]) + Data(bytes("A"))
        r += Data([0x28, 0x01, 0x32, 0x01]) + Data(bytes("z")) + Data([0x48, 0x01])
        let polled = try CAuthentication_PollAuthSessionStatus_Response.deserialize(from: r)
        require(polled.newClientID == 9 && polled.newChallengeURL == "n" && polled.refreshToken == "R" && polled.accessToken == "A"
                && polled.hadRemoteInteraction && polled.accountName == "z", "poll response, unknown field skipped")

        // Hostile or truncated input throws instead of trapping.
        for (label, data) in [("oversized length", Data([0x12, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f])),
                              ("length past end", Data([0x12, 0x05, 0x01])),
                              ("skipped oversized length", Data([0x7a, 0xff, 0xff, 0xff, 0xff, 0x0f])),
                              ("truncated fixed32", Data([0x1d, 0x01])),
                              ("unterminated varint", Data([0x08, 0x80])),
                              ("group wire type", Data([0x0b]))] {
            do { _ = try CAuthentication_PollAuthSessionStatus_Response.deserialize(from: data); require(false, label + " is rejected") }
            catch { require(error is SteamError, label + " is rejected") }
        }
        var big = ProtobufDecoder(Data([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]))
        do { _ = try big.readVarint(); require(false, "11-byte varint is rejected") } catch { require(true, "11-byte varint is rejected") }

        // x-eresult codes.
        require(SteamAuthAPI.error(for: 5) == .invalidCredentials && SteamAuthAPI.error(for: 18) == .invalidCredentials, "InvalidPassword / AccountNotFound")
        require(SteamAuthAPI.error(for: 84) == .rateLimited && SteamAuthAPI.error(for: 87) == .rateLimited, "rate limits")
        require(SteamAuthAPI.error(for: 17) == .accountDisabled, "banned")
        require(SteamAuthAPI.error(for: 9) == .authSessionExpired && SteamAuthAPI.error(for: 27) == .authSessionExpired, "expired session")
        if case .authenticationFailed(let text) = SteamAuthAPI.error(for: 65) { require(text.contains("Steam Guard"), "wrong code") } else { require(false, "wrong code") }
        if case .authenticationFailed(let text) = SteamAuthAPI.error(for: 2) { require(text.contains("(code 2)"), "other codes are named") } else { require(false, "other codes are named") }

        // Transport, through a stub protocol.
        _ = URLProtocol.registerClass(StubProtocol.self)
        StubProtocol.body = Data([0x08, 0x01])
        let ok = try await SteamAuthAPI.call("PollAuthSessionStatus", body: Data([0xfb, 0xff]))
        require(ok == Data([0x08, 0x01]), "eresult 1 returns the body")
        require(StubProtocol.lastMethod == "POST" && StubProtocol.lastURL?.absoluteString == "https://api.steampowered.com/IAuthenticationService/PollAuthSessionStatus/v1/",
                "POST to the IAuthenticationService method")
        let form = StubProtocol.lastBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        require(form == "input_protobuf_encoded=%2B%2F8%3D", "body is the percent-encoded base64 protobuf (\(form))")
        _ = try await SteamAuthAPI.call("GetPasswordRSAPublicKey", body: Data([0xfb, 0xff]), httpMethod: "GET")
        require(StubProtocol.lastMethod == "GET" && StubProtocol.lastURL?.query == "input_protobuf_encoded=%2B%2F8%3D", "GET carries the protobuf in the query")
        StubProtocol.eresult = "5"
        await expectError(.invalidCredentials, "HTTP 200 with x-eresult 5 is a wrong password") { try await SteamAuthAPI.call("X", body: Data()) }
        StubProtocol.eresult = nil; StubProtocol.status = 429
        await expectError(.rateLimited, "HTTP 429 is a rate limit") { try await SteamAuthAPI.call("X", body: Data()) }
        StubProtocol.status = 503
        await expectError(.authenticationFailed("Steam sign-in is unavailable right now (HTTP 503)."), "other HTTP errors") { try await SteamAuthAPI.call("X", body: Data()) }

        // SteamSignIn: the Dock's view of the stored sign-in.
        func jwt(_ claims: String) -> String {
            let p = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "eyJhbGciOiJFZERTQSJ9." + p + ".c2ln"
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let live = jwt(#"{"exp":2000000100}"#), dead = jwt(#"{"exp":1999999999}"#)
        require(SteamSignIn.usable(accountName: " a ", refreshToken: live, now: now)! == ("a", live), "a live token is handed over, name trimmed")
        require(SteamSignIn.usable(accountName: "a", refreshToken: dead, now: now) == nil, "an expired token counts as signed out")
        require(SteamSignIn.usable(accountName: "", refreshToken: live, now: now) == nil, "no account name, no sign-in")
        require(SteamSignIn.usable(accountName: "a", refreshToken: "", now: now) == nil, "no token, no sign-in")
        require(SteamSignIn.usable(accountName: "a", refreshToken: "opaque", now: now) != nil, "a token without claims is left to Steam")
        require(SteamSignIn.expiry(of: jwt(#"{"sub":"1"}"#)) == nil, "no exp claim, no expiry")

        require(!SteamSignIn.isSignedIn && SteamSignIn.credentialsForDock() == nil, "signed out at start")
        require(SteamSignIn.store(accountName: "a", refreshToken: live, accessToken: "x"), "store reports a kept sign-in")
        require(SteamSignIn.credentialsForDock()! == ("a", live) && SteamSignIn.accountName == "a" && SteamSignIn.isSignedIn, "credentialsForDock reads the store")
        SteamSignIn.signOut()
        require(SteamSignIn.credentialsForDock() == nil && !SteamSignIn.isSignedIn, "sign out removes it")
        require(SteamSignIn.flag("MADEIRA_STEAM_SIGNIN_HOSTTEST", default: true) && !SteamSignIn.flag("MADEIRA_STEAM_SIGNIN_HOSTTEST", default: false),
                "unset switches keep their default")
        setenv("MADEIRA_STEAM_SIGNIN_HOSTTEST", "0", 1)
        require(!SteamSignIn.flag("MADEIRA_STEAM_SIGNIN_HOSTTEST", default: true), "=0 turns a switch off")

        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all Steam sign-in Swift checks")
    }
}
'''

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'stubs.swift').write_text(stubs + block(signin, 'enum SteamSignIn {'))
    (tmp / 'api.swift').write_text(api_source)
    (tmp / 'checks.swift').write_text(checks)
    sources = [tmp / 'stubs.swift', tmp / 'api.swift', tmp / 'checks.swift',
               steam / 'Proto/SteamProtoMessages.swift', steam / 'Core/SteamError.swift']
    exe = tmp / 'swift-checks'
    build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-o', str(exe)] + [str(s) for s in sources])
    require(build.returncode == 0, 'production sign-in Swift compiles on the host')
    if build.returncode == 0:
        # LeakSanitizer is off: it reports Swift runtime allocations still live at exit.
        run = subprocess.run([str(exe)], env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))
        require(run.returncode == 0, 'Swift checks pass under AddressSanitizer')

if failures:
    print(f'FAILURES: {failures}')
    sys.exit(1)
print('PASS: all Steam sign-in host checks')
