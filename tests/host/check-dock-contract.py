#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Madeira Dock's app-side contract, compiled from production Swift on the host.

Synthetic data only: no Steam, Wine or credentials. Covers the JIT pool policy
(opt-in, Dock-only), installed-game discovery from Steam's own app manifests and
library list, launch validation, the one-use transfer envelope, the host's
environment (including the Dock-only image-retire switch) and launch arguments,
the one-launch request, lossless Steam Input overrides, and static rules:
no program-name lists, no credential in a log line, the compact pool off by
default, madeira.cfg `pool` still winning, and no built Dock binary tracked.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile
root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


dock = (app / 'MadeiraDock.swift').read_text()
view = (app / 'MadeiraDockView.swift').read_text()
runtime = (app / 'SteamRuntime.swift').read_text()
content = (app / 'ContentView.swift').read_text()
installers = (app / 'DockInstallers.swift').read_text()

# ------------------------------------------------------------------ static
for name, text in [('MadeiraDock.swift', dock), ('MadeiraDockView.swift', view), ('SteamRuntime.swift', runtime),
                   ('DockInstallers.swift', installers)]:
    literals = set(re.findall(r'"([^"\n]*?\.exe)\\?"', text)) | set(re.findall(r'\\"([^"\n]*?\.exe)\\"', text))
    names = {l.replace('/', '\\').split('\\')[-1].lower() for l in literals}
    # DockInstallers.swift checks the ".exe" suffix of install-script programs and whether the
    # bundle has Windows Installer (msiexec.exe); it keys nothing on a program's name.
    require(names <= {'dockhost.exe', 'explorer.exe', 'steam.exe', '.exe', 'msiexec.exe'}, f'{name}: no program-name list ({sorted(names)})')
    for line in text.splitlines():
        if re.search(r'SteamLog\.(event|trace)|LogStore|print\(|NSLog', line):
            require(re.search(r'\\\((account|token|signIn|secret|data|url|name)\b', line) is None,
                    f'{name}: no credential or path in "{line.strip()[:60]}"')
require('SteamSignIn.flag("MADEIRA_DOCK_COMPACT_POOL", default: false)' in view, 'compact pool is off unless opted in')
pool = content.index('let dockLaunch = MadeiraDock.takeLaunchRequest()')
require(pool < content.index('if let txt = MadeiraConfig.get("pool")', pool), 'madeira.cfg pool is applied after the Dock policy (explicit wins)')
require('DockPerformancePolicy.sessionPoolMB(standard: 896, dock: dockLaunch.dock, compact: dockLaunch.compact)' in content,
        'the standard 896 MB pool is unchanged outside a compact Dock launch')
require(content.count('MadeiraDock.requestLaunch(') == 1, 'only the Dock launch requests the Dock pool policy')
require('SteamSignIn.credentialsForDock()' in content, 'the launch uses the sign-in API')
handoff = dock[dock.index('    @MainActor static func writeHandoff('):dock.index("    /// The host's environment for one launch.")]
require(handoff.index('try forceSteamInput(') < handoff.index('setenv("MADEIRA_DOCK_AUTH_FILE"'),
        'Steam Input is forced before the sign-in transfer is published')
# Image retire is a Dock-session switch: only MadeiraDock.configure sets it, and
# only the Dock launch calls configure.
for name, text in [('ContentView.swift', content), ('MadeiraDockView.swift', view), ('SteamRuntime.swift', runtime)]:
    require('MADEIRA_JIT_IMAGE_RETIRE' not in text, f'{name}: does not set the image-retire switch')
require(dock.count('setenv("MADEIRA_JIT_IMAGE_RETIRE"') == 1 and
        dock.index('setenv("MADEIRA_JIT_IMAGE_RETIRE"') > dock.index('static func configure('),
        'the image-retire switch is set only in the Dock launch environment')
require(content.count('MadeiraDock.configure(') == 1, 'only the Dock launch configures the host environment')
# The image-map guard is also a Dock-session switch, set only by MadeiraDock.configure.
for name, text in [('ContentView.swift', content), ('MadeiraDockView.swift', view), ('SteamRuntime.swift', runtime)]:
    require('MADEIRA_IMAGE_MAP_GUARD' not in text, f'{name}: does not set the image-map guard')
require(dock.count('setenv("MADEIRA_IMAGE_MAP_GUARD"') == 1 and
        dock.index('setenv("MADEIRA_IMAGE_MAP_GUARD"') > dock.index('static func configure('),
        'the image-map guard is set only in the Dock launch environment')
# A Dock session publishes no fixed Steam game identity; every other launch keeps it.
bridge = (app / 'WineProcessBridge.m').read_text()
flag = bridge.index('const char *dock_session = getenv("MADEIRA_DOCK_SESSION");')
require(bridge.index('unsetenv("SteamAppId");', flag) < bridge.index('} else if (direct_app', flag) <
        bridge.index('setenv("SteamAppId",  direct_app, 1);', flag) < bridge.index('} else {', flag) <
        bridge.index('setenv("SteamAppId",  "356400", 1);', flag),
        "the bridge clears the fixed Steam identity only for a Dock session (a direct start publishes its game's own)")
require(content.count('setenv("MADEIRA_DOCK_SESSION", "1", 1)') == 1 and
        'if dockLaunch.dock && SteamSignIn.flag("MADEIRA_DOCK_CLEAR_STEAM_ID", default: true) {' in content and
        'unsetenv("MADEIRA_DOCK_SESSION")' in content,
        'only a Dock launch sets MADEIRA_DOCK_SESSION; every other launch clears it')
git =subprocess.run(['git', '-C', str(root), 'rev-parse', '--git-dir'], capture_output=True, text=True)
if git.returncode == 0:
    tracked = subprocess.run(['git', '-C', str(root), 'ls-files', 'app/Madeira/arm64ec-windows/dockhost.exe',
                              'app/Madeira/arm64ec-windows/dock-notices.txt'], capture_output=True, text=True).stdout.strip()
    require(tracked == '', 'no built Dock executable or notices are tracked')
    gitlink = subprocess.run(['git', '-C', str(root), 'ls-files', '-s', 'madeira-dock'], capture_output=True, text=True).stdout
    require(gitlink.startswith('160000 3cadfbea700e4da4b04e331dd7ef1ba633dfacef'), 'madeira-dock is pinned at 3cadfbe')
else:
    print('SKIP: not a usable git checkout here; tracked-binary and submodule-pin checks not run')

# ------------------------------------------------------------------ compiled
head = dock[dock.index('enum DockPerformancePolicy {'):dock.index('enum MadeiraDock {')]
body = (dock[dock.index('enum MadeiraDock {'):dock.index('    @MainActor private static var lastReport =')] +
        dock[dock.index("    /// The host's environment for one launch."):])
stubs = r'''
import Foundation
import Glibc
enum SteamSignIn {
    static func flag(_ name: String, default fallback: Bool) -> Bool { getenv(name).map { String(cString: $0) != "0" } ?? fallback }
}
enum SteamLog { static func event(_ m: String) {}; static func trace(_ m: @autoclosure () -> String) {} }
enum SteamRuntimeFiles {
    enum Failure: Error { case conflict }
    static let relativeRoot = "Program Files (x86)/Steam"
    static let windowsRoot = "C:\\Program Files (x86)\\Steam"
}
'''
runtime_paths = runtime[runtime.index('    static func validPath('):runtime.index('    // Parse the central directory')]
stubs = stubs.replace('enum SteamRuntimeFiles {', 'enum SteamRuntimeFiles {\n' + runtime_paths)
checks = r'''
import Foundation
import Glibc
var failures = 0
func require(_ condition: @autoclosure () throws -> Bool, _ label: String) {
    if (try? condition()) == true { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}
func env(_ name: String) -> String? { getenv(name).map { String(cString: $0) } }
func manifest(_ body: String) -> Data { Data(("\"AppState\"\n{\n" + body + "\n}\n").utf8) }
func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
func jwt(_ claims: String) -> String {
    let p = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return "eyJhbGciOiJFZERTQSJ9." + p + ".c2ln"
}

@main struct Checks {
    static func main() throws {
        // Pool policy: only a Dock launch that opted in gets the compact pool.
        require(DockPerformancePolicy.sessionPoolMB(standard: 896, dock: false, compact: true) == 896, "no Dock launch: standard pool")
        require(DockPerformancePolicy.sessionPoolMB(standard: 896, dock: true, compact: false) == 896, "Dock without the option: standard pool")
        require(DockPerformancePolicy.sessionPoolMB(standard: 896, dock: true, compact: true) == 512, "Dock with the option: 512 MB")
        require(DockPerformancePolicy.sessionPoolMB(standard: 384, dock: true, compact: true) == 384, "never larger than the standard pool")
        require(MadeiraDock.takeLaunchRequest() == (false, false), "no request by default")
        MadeiraDock.requestLaunch(compactPool: true)
        require(MadeiraDock.takeLaunchRequest() == (true, true), "a Dock launch request is read once")
        require(MadeiraDock.takeLaunchRequest() == (false, false), "and cleared for later launches")

        // App manifests.
        let good = manifest(#""appid" "4000" "name" "Fixture" "installdir" "Fixture Game" "StateFlags" "4" "CheckGuid" { "0" "bin\\game.exe" }"#)
        let game = MadeiraDock.game(manifest: good, library: "Program Files (x86)/Steam/steamapps")!
        require(game.id == 4000 && game.name == "Fixture" && game.installed && game.customExecutables, "installed manifest with custom executables")
        require(game.windowsInstallPath == "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Fixture Game", "expected install path for the host")
        let updating = MadeiraDock.game(manifest: manifest(#""appid" "4001" "installdir" "B" "StateFlags" "6""#), library: "L")!
        require(updating.installed && !updating.customExecutables && updating.name == "App 4001", "installed plus update-required counts as installed; unnamed apps get a label")
        require(!MadeiraDock.game(manifest: manifest(#""appid" "4002" "installdir" "C" "StateFlags" "2""#), library: "L")!.installed, "not fully installed")
        for (label, body) in [("parent folder", #""appid" "1" "installdir" "..""#), ("separator", #""appid" "1" "installdir" "a\\b""#),
                              ("slash", #""appid" "1" "installdir" "a/b""#), ("drive", #""appid" "1" "installdir" "C:x""#),
                              ("App ID 0", #""appid" "0" "installdir" "a""#), ("App ID too large", #""appid" "4294967295" "installdir" "a""#),
                              ("no install folder", #""appid" "5""#)] {
            require(MadeiraDock.game(manifest: manifest(body), library: "L") == nil, "rejected: \(label)")
        }
        require(MadeiraDock.game(manifest: Data("\"Other\" { }".utf8), library: "L") == nil, "not an app manifest")
        require(MadeiraDock.game(manifest: Data(count: (1 << 20) + 1), library: "L") == nil, "oversized manifest")
        require(MadeiraDock.libraryRelative("C:\\Games\\Library") == "Games/Library/steamapps", "C: library folder")
        require(MadeiraDock.libraryRelative("D:\\Games") == nil && MadeiraDock.libraryRelative("C:\\..\\x") == nil &&
                MadeiraDock.libraryRelative("C:\\") == nil, "other drives, parent references and the root are ignored")

        // Discovery in a synthetic drive_c.
        let drive = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dock-contract-\(getpid())/drive_c")
        defer { try? FileManager.default.removeItem(at: drive.deletingLastPathComponent()) }
        let apps = drive.appendingPathComponent("Program Files (x86)/Steam/steamapps")
        try write(apps.appendingPathComponent("appmanifest_20.acf"), "\"AppState\" { \"appid\" \"20\" \"name\" \"Zeta\" \"installdir\" \"Z\" \"StateFlags\" \"4\" }")
        try write(apps.appendingPathComponent("appmanifest_10.acf"), "\"AppState\" { \"appid\" \"10\" \"name\" \"alpha\" \"installdir\" \"A\" \"StateFlags\" \"4\" }")
        try write(apps.appendingPathComponent("appmanifest_11.acf"), "\"AppState\" { \"appid\" \"11\" \"installdir\" \"../escape\" }")
        try write(apps.appendingPathComponent("libraryfolders.vdf"),
                  "\"libraryfolders\" { \"0\" { \"path\" \"C:\\\\Program Files (x86)\\\\Steam\" } \"1\" { \"path\" \"C:\\\\Other\\\\Lib\" } \"2\" { \"path\" \"D:\\\\Games\" } }")
        let other = drive.appendingPathComponent("Other/Lib/steamapps")
        try write(other.appendingPathComponent("appmanifest_30.acf"), "\"AppState\" { \"appid\" \"30\" \"name\" \"Mid\" \"installdir\" \"M\" \"StateFlags\" \"4\" }")
        try write(other.appendingPathComponent("appmanifest_10.acf"), "\"AppState\" { \"appid\" \"10\" \"name\" \"dup\" \"installdir\" \"A\" \"StateFlags\" \"4\" }")
        let found = MadeiraDock.games(drive: drive)
        require(found.map(\.id) == [10, 30, 20], "games from both C: libraries, sorted by name, invalid and duplicate skipped (\(found.map(\.id)))")
        require(found.first { $0.id == 30 }!.library == "Other/Lib/steamapps", "a game keeps its own library")

        // Validation.
        let alpha = found[0]
        func refused(_ run: () throws -> Void, _ text: String) -> Bool {
            do { try run(); return false } catch { return (error as? DockError)?.errorDescription?.contains(text) == true }
        }
        require(refused({ try MadeiraDock.validate(alpha, drive: drive, bundled: false) }, "not built"), "no built host: refused")
        require(refused({ try MadeiraDock.validate(alpha, drive: drive, bundled: true) }, "client files"), "no client DLL: refused")
        try write(drive.appendingPathComponent("Program Files (x86)/Steam/steamclient64.dll"), "MZ")
        require(refused({ try MadeiraDock.validate(alpha, drive: drive, bundled: true) }, "fully installed"), "missing game folder: refused")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("common/A"), withIntermediateDirectories: true)
        require((try? MadeiraDock.validate(alpha, drive: drive, bundled: true)) != nil, "installed game with client: accepted")
        require(refused({ try MadeiraDock.validate(updating, drive: drive, bundled: true) }, "fully installed"), "a game whose folder is absent is refused")

        // Steam Input: synthetic account settings, never a real Steam installation.
        do {
            let config = drive.appendingPathComponent("Program Files (x86)/Steam/userdata/1/config/localconfig.vdf")
            func override(_ app: Int) throws -> String? {
                var parser = try SteamKeyValues(Data(contentsOf: config))
                return try parser.read()["UserLocalConfigStore"]?["Software"]?["Valve"]?["Steam"]?["apps"]?[String(app)]?["UseSteamControllerConfig"]?.string
            }
            try MadeiraDock.forceSteamInput(appID: 20, accountID: 1, drive: drive)
            require(try override(20) == "2", "missing settings: explicit Steam Input enablement created")
            let original = #"""
            // preserve comments, key casing, escapes and other game settings
            "UserLocalConfigStore" {
              "Software" { "Valve" { "Steam" { "apps" {
                "20" { "useSteamControllerConfig" "0" "LaunchOptions" "-name=\"quoted\"" }
                "30" { "UseSteamControllerConfig" "0" }
              } } } }
              "Unknown" { "Duplicate" "first" "Duplicate" "second" }
            }
            "Unrelated" "keep"
            """#
            try write(config, original)
            try MadeiraDock.forceSteamInput(appID: 20, accountID: 1, drive: drive)
            let expected = Data(original.replacingOccurrences(of: #""useSteamControllerConfig" "0""#, with: #""useSteamControllerConfig" "2""#).utf8)
            require(try Data(contentsOf: config) == expected, "disabled override changed; every unrelated byte preserved")
            require(try override(30) == "0", "another game's settings are not rewritten prematurely")
            try MadeiraDock.forceSteamInput(appID: 20, accountID: 1, drive: drive)
            require(try Data(contentsOf: config) == expected, "repeated launch is idempotent")
            try MadeiraDock.forceSteamInput(appID: 30, accountID: 1, drive: drive)
            require(try override(30) == "2" && override(20) == "2", "each game receives the same forced override when launched")
            try MadeiraDock.forceSteamInput(appID: 40, accountID: 1, drive: drive)
            require(try override(40) == "2" && override(20) == "2", "future games get an override without losing existing entries")
            let other = drive.appendingPathComponent("Program Files (x86)/Steam/userdata/2/config/localconfig.vdf")
            try write(other, original)
            for invalid in ["\"UserLocalConfigStore\" {", "\"UserLocalConfigStore\" { \"Software\" \"scalar\" }"] {
                try write(config, invalid)
                require((try? MadeiraDock.forceSteamInput(appID: 20, accountID: 1, drive: drive)) == nil, "malformed or conflicting settings refuse the launch")
                require(try Data(contentsOf: config) == Data(invalid.utf8), "failed edit preserves the settings file")
            }
            require(try Data(contentsOf: other) == Data(original.utf8), "other accounts are untouched")
            try FileManager.default.removeItem(at: config)
            try FileManager.default.createSymbolicLink(at: config, withDestinationURL: other)
            require((try? MadeiraDock.forceSteamInput(appID: 20, accountID: 1, drive: drive)) == nil, "symlinked settings are refused")
            require(try Data(contentsOf: other) == Data(original.utf8), "symlink target is untouched")
            let duplicate = Data(#""Root" { "Setting" "0" "Setting" "1" }"#.utf8)
            require(try SteamKeyValues.setting(duplicate, path: ["Root", "Setting"], value: "2") == Data(#""Root" { "Setting" "2" "Setting" "2" }"#.utf8), "duplicate target keys are all forced")
        }

        // Transfer envelope (synthetic account 1 SteamID).
        let steamID: UInt64 = 76561197960265729
        let data = try MadeiraDock.envelope(account: "fixture", token: "a.b-c_d", steamID: steamID, appID: 10)
        var expected = Data("MDOCK001".utf8)
        for i in 0..<8 { expected.append(UInt8(truncatingIfNeeded: steamID >> (i * 8))) }
        expected += Data([10, 0, 0, 0, 7, 0, 7, 0]) + Data("fixture".utf8) + Data("a.b-c_d".utf8)
        require(data == expected, "MDOCK001 layout: SteamID, App ID, lengths, account, token")
        for (label, run) in [("empty account", { _ = try MadeiraDock.envelope(account: "", token: "t", steamID: steamID, appID: 1) }),
                             ("space in account", { _ = try MadeiraDock.envelope(account: "a b", token: "t", steamID: steamID, appID: 1) }),
                             ("token character", { _ = try MadeiraDock.envelope(account: "a", token: "t/", steamID: steamID, appID: 1) }),
                             ("oversized token", { _ = try MadeiraDock.envelope(account: "a", token: String(repeating: "t", count: 8193), steamID: steamID, appID: 1) }),
                             ("non-individual SteamID", { _ = try MadeiraDock.envelope(account: "a", token: "t", steamID: 1, appID: 1) }),
                             ("App ID 0", { _ = try MadeiraDock.envelope(account: "a", token: "t", steamID: steamID, appID: 0) })] as [(String, () throws -> Void)] {
            require((try? run()) == nil, "envelope refuses \(label)")
        }
        require((try? MadeiraDock.subject(jwt(#"{"sub":"76561197960265729"}"#))) == steamID, "JWT subject selects the account")
        require((try? MadeiraDock.subject("opaque")) == nil && (try? MadeiraDock.subject(jwt(#"{"sub":"x"}"#))) == nil, "no usable subject: refused")

        // Host environment and launch.
        setenv("MADEIRA_STEAM_HOST_ACCOUNT", "stale", 1); setenv("MADEIRA_STEAM_HOST_STEAMID", "1", 1)
        MadeiraDock.configure(game)
        require(["MADEIRA_STEAM_HOST_PROBE", "MADEIRA_STEAM_HOST_SESSION", "MADEIRA_STEAM_HOST_LOGIN", "MADEIRA_STEAM_HOST_LAUNCH"].allSatisfy { env($0) == "1" }, "host gates on")
        require(env("MADEIRA_STEAM_HOST_APPID") == "4000" && env("MADEIRA_STEAM_HOST_CLIENT_DIR") == "C:\\Program Files (x86)\\Steam" &&
                env("MADEIRA_STEAM_HOST_EXPECTED_INSTALL") == game.windowsInstallPath && env("MADEIRA_STEAM_HOST_LOG") == "C:\\madeira-dock.txt", "host inputs")
        require(env("MADEIRA_STEAM_HOST_ACCOUNT") == nil && env("MADEIRA_STEAM_HOST_STEAMID") == nil, "the cached-account test path is never selected")
        require(env("MADEIRA_STEAM_HOST_CEG") == "1", "custom executables: Dock asks the client to prepare them")
        setenv("MADEIRA_DOCK_CEG", "0", 1); MadeiraDock.configure(game)
        require(env("MADEIRA_STEAM_HOST_CEG") == nil, "MADEIRA_DOCK_CEG=0 never asks")
        unsetenv("MADEIRA_DOCK_CEG"); MadeiraDock.configure(alpha)
        require(env("MADEIRA_STEAM_HOST_CEG") == nil, "no custom executables: not asked")
        require(env("MADEIRA_JIT_IMAGE_RETIRE") == "1", "a Dock launch turns the engine's image-retire switch on")
        unsetenv("MADEIRA_JIT_IMAGE_RETIRE"); setenv("MADEIRA_DOCK_IMAGE_RETIRE", "0", 1); MadeiraDock.configure(alpha)
        require(env("MADEIRA_JIT_IMAGE_RETIRE") == nil, "MADEIRA_DOCK_IMAGE_RETIRE=0 leaves image retire off")
        unsetenv("MADEIRA_DOCK_IMAGE_RETIRE")
        require(env("MADEIRA_IMAGE_MAP_GUARD") == "1", "a Dock launch turns Wine's image-map guard on")
        unsetenv("MADEIRA_IMAGE_MAP_GUARD"); setenv("MADEIRA_DOCK_IMAGE_MAP_GUARD", "0", 1); MadeiraDock.configure(alpha)
        require(env("MADEIRA_IMAGE_MAP_GUARD") == nil, "MADEIRA_DOCK_IMAGE_MAP_GUARD=0 leaves the image-map guard off")
        unsetenv("MADEIRA_DOCK_IMAGE_MAP_GUARD")
        require(MadeiraDock.launchArguments(width: 1280, height: 720) == "/desktop=madeira,1280x720 C:\\windows\\system32\\dockhost.exe", "explorer desktop runs the host")
        require(!MadeiraDock.launchArguments(width: 1280, height: 720).contains("\""), "no quotes: MADEIRA_ARGS is split at spaces and passed on as is")
        require(!MadeiraDock.executable.contains(" "), "the host path has no spaces")
        require(MadeiraDock.launchArguments(width: 1280, height: 720, installers: "C:\\i.cmd") ==
                "/desktop=madeira,1280x720 C:\\windows\\system32\\cmd.exe /c call C:\\i.cmd & C:\\windows\\system32\\dockhost.exe",
                "with one-time installs: cmd.exe runs them, then the host, in the same session")
        require(MadeiraDock.handoffGuestPath(URL(fileURLWithPath: "/var/x/launch.auth")) == "\\\\?\\unix\\var\\x\\launch.auth", "transfer path through Wine's Unix namespace")

        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all Dock contract Swift checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-dock-contract-') as tmp:
    tmp = Path(tmp)
    native_import = 'import Darwin' if sys.platform == 'darwin' else 'import Glibc'
    (tmp / 'stubs.swift').write_text(stubs.replace('import Glibc', native_import) + head)
    (tmp / 'dock.swift').write_text('import Foundation\n' + native_import + '\n' + body)
    (tmp / 'checks.swift').write_text(checks.replace('import Glibc', native_import))
    exe = tmp / 'check'
    build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-o', str(exe),
                            str(tmp / 'stubs.swift'), str(tmp / 'dock.swift'), str(tmp / 'checks.swift'), str(app / 'SteamKeyValues.swift')])
    require(build.returncode == 0, 'production Dock Swift compiles on the host')
    if build.returncode == 0:
        run = subprocess.run([str(exe)], env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))
        require(run.returncode == 0, 'Dock contract checks pass under AddressSanitizer')

if failures:
    print(f'FAILURES: {failures}')
    sys.exit(1)
print('PASS: all Dock contract checks')
