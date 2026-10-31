#!/usr/bin/env python3
"""Square Enix sign-in for FINAL FANTASY XIV (docs/SQUARE_ENIX_SIGNIN.md).

Source checks (every host): app/Madeira/SquareEnixSignIn.swift is in the Xcode
project's sources, imports only Foundation and CryptoKit (so this fixture can
compile it), and names no third-party launcher: the sign-in is a clean
implementation of the specification, and must not cite or borrow from other
launchers' code.

The Swift fixture (macOS) compiles the real SquareEnixSignIn.swift with a
scripted transport and checks how an installation is recognised and read
(version files, the boot hash against Python's own SHA-1s), the request
builders (form encoding of a password full of reserved characters, step 6's
exact body), the reply parsers on hand-written pages shaped like the observed
ones (a commented-out error call on every login page must not count as a
refusal), the whole sign-in's request sequence, and that no password,
one-time password, _STORED_ token, SID or session ID reaches a log line or an
error message. Hosts without Swift run the source checks; --require-swift
turns a missing compiler into a failure.
"""
from pathlib import Path
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
source_file = root / 'app/Madeira/SquareEnixSignIn.swift'
source = source_file.read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()

assert 'A1001001 /* SquareEnixSignIn.swift in Sources */,' in project, 'SquareEnixSignIn.swift is not in the sources phase'
assert 'path = SquareEnixSignIn.swift;' in project
assert sorted(set(re.findall(r'^import (\w+)', source, re.M))) == ['CryptoKit', 'Foundation'], 'Foundation and CryptoKit only'
for name in ('xivlauncher', 'quicklauncher', 'goatcorp', 'xiv on mac', 'xiv-on-mac', 'marzent', 'astra', 'redstrate',
             'microlaunch', 'l4-cpp', 'kawari'):
    # Whole words: the game's own ffxivlauncher64.exe contains "xivlauncher".
    assert not re.search(r'\b' + re.escape(name) + r'\b', source.lower()), f'SquareEnixSignIn.swift names {name!r}'

# Windows license: wine_get_host_version hidden from run-time lookups (the PE ntdll patch).
patch_file = root / 'build/wine-pe/patches/ntdll-hide-wine-host-version.patch'
patch = patch_file.read_text()
build_ntdll = (root / 'build/wine-pe/build-ntdll.sh').read_text()
library = (root / 'app/Madeira/Library.swift').read_text()
assert '+++ b/dlls/ntdll/loader.c' in patch and patch.count('+++ ') == 1, 'the patch touches dlls/ntdll/loader.c only'
assert '+    else if (hide_wine_host_version( name )) ret = STATUS_PROCEDURE_NOT_FOUND;' in patch, \
    'LdrGetProcedureAddress refuses the hidden name before looking it up'
assert 'L"MADEIRA_HIDE_WINE_HOST_VERSION"' in patch and 'static const char hidden[] = "wine_get_host_version";' in patch
assert re.search(r'PATCHES=\("\$R"/build/wine-pe/patches/ntdll-\*\.patch\)', build_ntdll) and 'trap revert_patches EXIT' in build_ntdll, \
    'build-ntdll.sh applies the ntdll patches and reverts them on exit'
assert build_ntdll.index('trap revert_patches EXIT') < build_ntdll.index('make dlls/ntdll/arm64ec-windows/ntdll.dll'), \
    'the revert is armed before the build'
assert ('if Self.transientProgram(for: id) != nil, squareEnixLicense == "windows" {\n'
        '            setenv("MADEIRA_HIDE_WINE_HOST_VERSION", "1", 1)\n        } else {\n'
        '            unsetenv("MADEIRA_HIDE_WINE_HOST_VERSION")') in library, \
    'configureLaunch hides the function only for a signed-in FFXIV launch under a Windows license'
assert ('usesLaunchOptions && (launchMode == "desktop" || (Self.transientProgram(for: id) != nil && '
        'squareEnixLicense == "windows"))') in library, \
    'a signed-in FFXIV launch under a Windows license starts in the Wine desktop (the game re-launches itself)'
wine = root / 'wine'
if (wine / 'dlls/ntdll/loader.c').exists() and shutil.which('git'):
    check = subprocess.run(['git', '-C', str(wine), 'apply', '--check', str(patch_file)], capture_output=True, text=True)
    applied = subprocess.run(['git', '-C', str(wine), 'apply', '--reverse', '--check', str(patch_file)], capture_output=True)
    assert check.returncode == 0 or applied.returncode == 0, f'the ntdll patch no longer applies to the wine submodule: {check.stderr}'
    print('PASS: the ntdll patch applies to the wine submodule')
print('PASS: source checks')

# The installation the fixture reads: four of the wiki's six boot programs, as in
# today's installation, and two expansions (ex10 checks numeric order).
BOOT_FILES = {'ffxivboot.exe': b'boot32' * 7, 'ffxivboot64.exe': b'boot64' * 11,
              'ffxivlauncher64.exe': b'launcher' * 13, 'ffxivupdater64.exe': b'updater' * 5}
expected_hash = ','.join(f'{name}/{len(BOOT_FILES[name])}/{hashlib.sha1(BOOT_FILES[name]).hexdigest()}'
                         for name in ('ffxivboot.exe', 'ffxivboot64.exe', 'ffxivlauncher64.exe', 'ffxivupdater64.exe'))

main = r'''
import Foundation

var failures = 0
func check(_ condition: Bool, _ what: String) {
    if condition { print("ok: \(what)") } else { print("FAIL: \(what)"); failures += 1 }
}

let env = ProcessInfo.processInfo.environment
let gameRoot = URL(fileURLWithPath: env["FFXIV_ROOT"]!)
let expectedHash = env["EXPECTED_BOOT_HASH"]!

// Recognising an installation.
let install = FFXIVInstall(program: gameRoot.appendingPathComponent("boot/ffxivboot.exe"))
check(install?.root.standardizedFileURL == gameRoot.standardizedFileURL, "boot/ffxivboot.exe finds the installation")
check(FFXIVInstall(program: gameRoot.appendingPathComponent("game/ffxiv_dx11.exe")) != nil, "game/ffxiv_dx11.exe too")
check(FFXIVInstall(program: gameRoot.appendingPathComponent("boot/FFXIVLAUNCHER64.EXE")) != nil, "the program name's case does not matter")
check(FFXIVInstall(program: gameRoot.appendingPathComponent("boot/ffxivconfig64.exe")) == nil, "a helper program is not the game")
check(FFXIVInstall(program: gameRoot.appendingPathComponent("game/other.exe")) == nil, "another program is not the game")
let other = URL(fileURLWithPath: env["OTHER_ROOT"]!)
check(FFXIVInstall(program: other.appendingPathComponent("game/ffxiv_dx11.exe")) == nil, "the right name without the version files is not")
check(install?.clientProgram.lastPathComponent == "ffxiv_dx11.exe", "Play starts the client")

// Reading it.
let versions = try! install!.versions()
check(versions == FFXIVInstall.Versions(boot: "2026.08.18.0000.0001", game: "2026.10.16.0000.0000",
                                          expansions: [.init(number: 1, version: "2026.08.20.0000.0000"),
                                                       .init(number: 2, version: "2026.08.21.0000.0000"),
                                                       .init(number: 10, version: "2026.10.16.0000.0000")]),
      "version files, expansions in numeric order, trailing newline ignored")
check(try! install!.bootHash() == expectedHash, "boot hash: the four programs present, in the wiki's order, Python's SHA-1s")
check(!FFXIVInstall.isVersion("2026.10.16.0000.0000/../x") && !FFXIVInstall.isVersion("2026.1.16.0000.0000")
      && FFXIVInstall.isVersion("2015.06.12.0000.0001"), "only the YYYY.MM.DD.NNNN.NNNN shape is a version")
let bad = URL(fileURLWithPath: env["BAD_ROOT"]!)
do { _ = try FFXIVInstall(program: bad.appendingPathComponent("boot/ffxivboot.exe"))!.versions(); check(false, "a bad version file throws") }
catch let error as SquareEnixSignInError { check(error == .installUnreadable("ffxivgame.ver"), "a bad version file throws") }
catch { check(false, "a bad version file throws SquareEnixSignInError") }

// Request builders.
let password = "p+a&s=s%w ord/é"
let options = SquareEnixSignInOptions(license: .mac, region: 2, installID: "0123456789")
let credentials = SquareEnixCredentials(id: "someone", password: password, oneTimePassword: "123456")
let post = SquareEnixProtocol.credentialsRequest(stored: "a&b=c", credentials: credentials, options: options)
check(String(decoding: post.httpBody!, as: UTF8.self)
      == "token=&_STORED_=a%26b%3Dc&sqexid=someone&password=p%2Ba%26s%3Ds%25w%20ord%2F%C3%A9&otppw=123456",
      "form body: launcher order, no saveid, reserved and non-ASCII characters percent-encoded")
check(post.httpMethod == "POST" && post.url == SquareEnixProtocol.loginSendURL
      && post.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded"
      && post.value(forHTTPHeaderField: "Referer") == SquareEnixProtocol.loginSendURL.absoluteString
      && post.url!.query == nil, "credentials go in a POST body, never the URL")
check(SquareEnixProtocol.loginPageURL(options).absoluteString
      == "https://ffxiv-login.square-enix.com/oauth/ffxivarr/login/top?lng=en&rgn=2&isft=0&cssmode=2&isnew=1&launchver=3",
      "login page query")
var trial = options; trial.freeTrial = true
check(SquareEnixProtocol.loginPageURL(trial).query!.contains("isft=1"), "free trial sets isft=1")
check(SquareEnixProtocol.gateStatusURL(language: "en-us").absoluteString
      == "https://frontier.ffxiv.com/worldStatus/gate_status.json?lang=en-us", "gate status URL")
check(SquareEnixProtocol.bootCheckURL(bootVersion: "2026.08.18.0000.0001").scheme == "http", "boot check is plain HTTP")
check(SquareEnixProtocol.sessionBody(versions: versions, bootHash: "H")
      == "2026.08.18.0000.0001=H\nex1\t2026.08.20.0000.0000\nex2\t2026.08.21.0000.0000\nex10\t2026.10.16.0000.0000",
      "session body: boot line, a tab-separated line per expansion, no final newline")
check(SquareEnixLicense.mac.signInUserAgent(installID: "x") == "macSQEXAuthor/2.0.0(MacOSX; ja-jp)"
      && SquareEnixLicense.windows.signInUserAgent(installID: "abc") == "SQEXAuthor/2.0.0(Windows 6.2; ja-jp; abc)"
      && SquareEnixLicense.mac.patchUserAgent == "FFXIV-MAC PATCH CLIENT"
      && SquareEnixLicense.windows.patchUserAgent == "FFXIV PATCH CLIENT", "User-Agents by license")
let ids = (0..<500).map { _ in SquareEnixSignInOptions.newInstallID() }
check(ids.allSatisfy { $0.count == 10 && $0.allSatisfy { $0.isHexDigit && !$0.isUppercase } }, "install ID: ten lowercase hex digits")
check(ids.allSatisfy(SquareEnixSignInOptions.isValidInstallID), "install ID: its five bytes add up to a multiple of 256")
check(Set(ids).count == ids.count, "install IDs differ")
// The login page accepted 5fd2faa332 (the wiki's example) and refused 5fd2faa333 (2026-10-29).
check(SquareEnixSignInOptions.isValidInstallID("5fd2faa332") && !SquareEnixSignInOptions.isValidInstallID("5fd2faa333")
      && !SquareEnixSignInOptions.isValidInstallID("0123456789") && !SquareEnixSignInOptions.isValidInstallID("5FD2FAA332")
      && !SquareEnixSignInOptions.isValidInstallID("5fd2faa3"), "install ID check: the accepted and refused examples")

// Reply parsers, on hand-written pages shaped like the observed ones.
let loginPage = """
<html><body>
<form action="login.send" method="post" name="mainForm">
\t<input type="hidden" name="token" id="token">
\t\t<input type="hidden" name="_STORED_" value="tok&amp;en&#x2B;1">
\t<input class="item-input" name="sqexid" id="sqexid" type="text" value="" maxLength="16" />
</form></body></html>
"""
check(SquareEnixProtocol.storedToken(inLoginPage: loginPage) == "tok&en+1", "_STORED_ found, entities decoded")
check(SquareEnixProtocol.storedToken(inLoginPage: "<INPUT value='v' name='_STORED_'>") == "v", "_STORED_ in any attribute order and quoting")
check(SquareEnixProtocol.storedToken(inLoginPage: "<input name=\"sqexid\" value=\"x\">") == nil, "no _STORED_, no token")

let commented = """
function ctrEvent ( formName )
{
\tif (g_clickCheck)
\t{
\t\t//window.external.user('login=auth,ng,err,The data has already been sent.');
\t\treturn;
\t}
}
"""
let signedIn = commented + "\n<script>\n\t\twindow.external.user(\"login=auth,ok,sid,0a1b2c,terms,1,region,2,etmadd,0,playable,1,ps3pkg,0,maxex,5,product,1\");\n</script>"
let refused = commented + "\n<script>\nwindow.external.user(\"login=auth,ng,err,The Square Enix ID or password is incorrect.\\r\\nTry again.\");\n</script>"
check(SquareEnixProtocol.loginReply(signedIn) == .signedIn(["sid": "0a1b2c", "terms": "1", "region": "2", "etmadd": "0",
                                                            "playable": "1", "ps3pkg": "0", "maxex": "5", "product": "1"]),
      "success: name, value pairs, the commented-out error call ignored")
check(SquareEnixProtocol.loginReply(refused) == .refused("The Square Enix ID or password is incorrect.\r\nTry again."),
      "refusal: Square Enix's message with its escapes undone")
check(SquareEnixProtocol.loginReply(commented) == .unrecognised, "only a commented-out call: not understood, not refused")
check(SquareEnixProtocol.loginReply("window.external.user(\"login=auth,ok,sid,1,region\");") == .unrecognised, "an odd field count")

check(SquareEnixProtocol.isOpen(Data("{\"status\":1}".utf8)), "status 1 is open")
check(SquareEnixProtocol.isOpen(Data("{\"status\":1,\"message\":[\"The game is unavailable for play during maintenance.\"]}".utf8)),
      "the gate's maintenance message alone does not close it")
check(!SquareEnixProtocol.isOpen(Data("{\"status\":0}".utf8)) && !SquareEnixProtocol.isOpen(Data("oops".utf8)), "anything else is closed")

let patchList = Data(("--B\r\nContent-Type: application/octet-stream\r\nX-Patch-Length: 10\r\n\r\n" +
                      "10\t20\t16\t15\t2026.08.18.0000.0001\thttp://patch-dl.ffxiv.com/boot/x/D2026.08.18.0000.0001.patch\r\n--B--\r\n").utf8)
check(SquareEnixProtocol.bootCheck(status: 204, body: Data()) == .current, "204: current")
check(SquareEnixProtocol.bootCheck(status: 200, body: patchList) == .update("2026.08.18.0000.0001"), "200 patch list: the target version")
check(SquareEnixProtocol.bootCheck(status: 200, body: Data()) == .current, "empty 200: current (the wiki's reading)")
check(SquareEnixProtocol.bootCheck(status: 404, body: Data()) == .unknownVersion, "404: unknown version")
check(SquareEnixProtocol.bootCheck(status: 500, body: Data()) == .unexpected(500), "anything else: unexpected")

// The whole sign-in, against a scripted transport.
final class Scripted: SquareEnixTransport {
    var requests: [URLRequest] = []
    var replies: [String: (Int, [String: String], Data)] = [:]
    var fail: String?
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        let key = url.host! + url.path
        if let fail = fail, key.hasPrefix(fail) { throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url]) }
        guard let reply = replies.first(where: { key.hasPrefix($0.key) })?.value else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
        return (reply.2, HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: reply.1)!)
    }
}

let sid = "5ec2e75ec2e75ec2e7"
let sessionID = "5e5510n1d5e5510n1d"
func script(_ transport: Scripted, reply: String) {
    transport.replies = [
        "frontier.ffxiv.com/worldStatus/login_status.json": (200, [:], Data("{\"status\":1}".utf8)),
        "frontier.ffxiv.com/worldStatus/gate_status.json": (200, [:], Data("{\"status\":1,\"message\":[\"m\"]}".utf8)),
        "patch-bootver.ffxiv.com/": (204, ["X-Latest-Version": "2026.08.18.0000.0001"], Data()),
        "ffxiv-login.square-enix.com/oauth/ffxivarr/login/top": (200, [:], Data(loginPage.utf8)),
        "ffxiv-login.square-enix.com/oauth/ffxivarr/login/login.send": (200, [:], Data(reply.utf8)),
        "patch-gamever.ffxiv.com/": (200, ["X-Patch-Unique-Id": sessionID], Data()),
    ]
}
let goodReply = signedIn.replacingOccurrences(of: "sid,0a1b2c", with: "sid,\(sid)")
var lines: [String] = []
let secrets = [password, "123456", "tok&en+1", "tok%26en%2B1", sid, sessionID]
func leaks(_ text: String) -> String? { secrets.first { text.contains($0) } }

func run(_ transport: Scripted, _ options: SquareEnixSignInOptions = options) -> Result<SquareEnixLaunch, Error> {
    let done = DispatchSemaphore(value: 0)
    var result: Result<SquareEnixLaunch, Error>!
    Task {
        do {
            let launch = try await SquareEnixSignIn(transport: transport, log: { lines.append($0) })
                .signIn(install: install!, options: options, credentials: credentials)
            result = .success(launch)
        } catch { result = .failure(error) }
        done.signal()
    }
    done.wait()
    return result
}

let transport = Scripted()
script(transport, reply: goodReply)
guard case .success(let launch) = run(transport) else { fatalError("the scripted sign-in failed") }
check(transport.requests.map { $0.url!.host! + $0.url!.path } == [
    "frontier.ffxiv.com/worldStatus/login_status.json",
    "patch-bootver.ffxiv.com/http/win32/ffxivneo_release_boot/2026.08.18.0000.0001",
    "ffxiv-login.square-enix.com/oauth/ffxivarr/login/top",
    "ffxiv-login.square-enix.com/oauth/ffxivarr/login/login.send",
    "frontier.ffxiv.com/worldStatus/gate_status.json",
    "patch-gamever.ffxiv.com/http/win32/ffxivneo_release_game/2026.10.16.0000.0000/\(sid)",
], "steps in order: login status, boot check, login page, credentials, gate, session")
let session = transport.requests.last!
check(session.httpMethod == "POST" && session.value(forHTTPHeaderField: "X-Hash-Check") == "enabled"
      && session.value(forHTTPHeaderField: "User-Agent") == "FFXIV-MAC PATCH CLIENT"
      && String(decoding: session.httpBody!, as: UTF8.self).hasPrefix("2026.08.18.0000.0001=\(expectedHash)\nex1\t"),
      "session registration: headers and the real boot hash")
check(transport.requests[3].value(forHTTPHeaderField: "User-Agent") == "macSQEXAuthor/2.0.0(MacOSX; ja-jp)", "Mac license signs in as the Mac app")
check(launch.program.lastPathComponent == "ffxiv_dx11.exe"
      && launch.arguments.contains("DEV.TestSID=\(sessionID)") && launch.arguments.contains("DEV.MaxEntitledExpansionID=5")
      && launch.arguments.contains("SYS.Region=2") && launch.arguments.contains("ver=2026.10.16.0000.0000")
      && !launch.arguments.contains { $0.contains(sid) }, "launch: the session ID (not the SID), maximum expansion, region, version")
check(lines.contains { $0 == "[sqex-signin] boot hash: \(expectedHash)" }, "the boot hash is logged in full")

var windows = options; windows.license = .windows
let windowsTransport = Scripted(); script(windowsTransport, reply: goodReply)
_ = run(windowsTransport, windows)
check(windowsTransport.requests[3].value(forHTTPHeaderField: "User-Agent") == "SQEXAuthor/2.0.0(Windows 6.2; ja-jp; 0123456789)"
      && windowsTransport.requests.last!.value(forHTTPHeaderField: "User-Agent") == "FFXIV PATCH CLIENT", "Windows license User-Agents")

func failure(_ configure: (Scripted) -> Void) -> SquareEnixSignInError? {
    let transport = Scripted(); script(transport, reply: goodReply); configure(transport)
    if case .failure(let error) = run(transport) { return error as? SquareEnixSignInError }
    return nil
}
check(failure { $0.replies["frontier.ffxiv.com/worldStatus/login_status.json"] = (200, [:], Data("{\"status\":0}".utf8)) } == .closed,
      "closed login status stops before the password is sent")
check(failure { $0.replies["frontier.ffxiv.com/worldStatus/gate_status.json"] = (200, [:], Data("{\"status\":0}".utf8)) } == .closed,
      "closed gate stops before the session")
check(failure { $0.replies["patch-bootver.ffxiv.com/"] = (200, [:], patchList) } == .gameUpdateNeeded("2026.08.18.0000.0001"),
      "outdated boot files: update needed, with the target")
check(failure { $0.replies["ffxiv-login.square-enix.com/oauth/ffxivarr/login/login.send"] = (200, [:], Data(refused.utf8)) }
      == .refused("The Square Enix ID or password is incorrect.\r\nTry again."), "a refusal carries Square Enix's message")
let notPlayable = goodReply.replacingOccurrences(of: "playable,1", with: "playable,0")
check(failure { $0.replies["ffxiv-login.square-enix.com/oauth/ffxivarr/login/login.send"] = (200, [:], Data(notPlayable.utf8)) }
      == .notPlayable, "playable 0 stops")
check(failure { $0.replies["patch-gamever.ffxiv.com/"] = (409, [:], patchList) } == .sessionRejected, "no X-Patch-Unique-Id: rejected")
check(lines.contains { $0.contains("no X-Patch-Unique-Id") && $0.contains("patches to 2026.08.18.0000.0001") }, "a rejected session logs the patch targets")
check(failure { $0.fail = "patch-gamever.ffxiv.com/" } == .unreachable(.session), "a network error maps to its step")
for error in [SquareEnixSignInError.unreachable(.session), .unexpectedReply(.credentials), .closed, .gameUpdateNeeded(nil),
              .notPlayable, .sessionRejected, .installUnreadable("x"), .cancelled] {
    check(leaks(error.localizedDescription) == nil, "message for \(error) holds no secret")
}

let leaked = lines.compactMap { line in leaks(line).map { "\(line) (\($0))" } }
check(leaked.isEmpty, "no log line holds a password, one-time password, _STORED_ token, SID or session ID: \(leaked)")

if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
print("PASS: Square Enix sign-in fixture")
'''


def write_install(base, versions=True, bad_game=False):
    (base / 'boot').mkdir(parents=True)
    (base / 'game/sqpack').mkdir(parents=True)
    for name, data in BOOT_FILES.items():
        (base / 'boot' / name).write_bytes(data)
    (base / 'boot/ffxivconfig64.exe').write_bytes(b'config')
    (base / 'game/ffxiv_dx11.exe').write_bytes(b'client')
    if not versions:
        return
    (base / 'boot/ffxivboot.ver').write_text('2026.08.18.0000.0001')
    (base / 'game/ffxivgame.ver').write_text('not a version' if bad_game else '2026.10.16.0000.0000\n')
    for number, version in ((1, '2026.08.20.0000.0000'), (2, '2026.08.21.0000.0000'), (10, '2026.10.16.0000.0000')):
        (base / f'game/sqpack/ex{number}').mkdir()
        (base / f'game/sqpack/ex{number}/ex{number}.ver').write_text(version)
    (base / 'game/sqpack/ffxiv').mkdir()        # the base game's folder is not an expansion
    (base / 'game/sqpack/ex3').mkdir()          # an expansion folder without a version file is skipped


with tempfile.TemporaryDirectory(prefix='madeira-sqex-') as directory:
    temporary = Path(directory)
    compiler = shutil.which('swiftc')
    if compiler:
        write_install(temporary / 'ffxiv')
        write_install(temporary / 'other', versions=False)
        write_install(temporary / 'bad', bad_game=True)
        (temporary / 'main.swift').write_text(main)
        binary = temporary / 'sqex-signin'
        subprocess.run([compiler, str(source_file), str(temporary / 'main.swift'), '-o', str(binary)], check=True)
        env = dict(os.environ, FFXIV_ROOT=str(temporary / 'ffxiv'), OTHER_ROOT=str(temporary / 'other'),
                   BAD_ROOT=str(temporary / 'bad'), EXPECTED_BOOT_HASH=expected_hash)
        subprocess.run([str(binary)], check=True, env=env)
    elif args.require_swift:
        raise SystemExit('Swift compiler required for the Square Enix sign-in fixture')
    else:
        print('SKIP: Swift compiler unavailable locally; run on macOS with --require-swift')
