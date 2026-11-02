#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""A Dock game session's service manager (ml2020): the app's decision from the prefix's
system.reg, its export to the host and the madsync rule, and the host's matching switches.

Static anchors, then the production DockGameSession.swift compiled on the host with a
MadeiraConfig stub and run against synthetic registry text. Needs swiftc; no Steam, Wine
or credentials.
"""
import os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

session = (ROOT / 'app/Madeira/DockGameSession.swift').read_text(encoding='utf-8')
content = (ROOT / 'app/Madeira/ContentView.swift').read_text(encoding='utf-8')
dock = (ROOT / 'app/Madeira/MadeiraDock.swift').read_text(encoding='utf-8')
docs = (ROOT / 'docs/MADEIRA_DOCK.md').read_text(encoding='utf-8')
pbx = (ROOT / 'app/Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')

# --- static -------------------------------------------------------------------------------
check('DockGameSession.decide(prefix:' in content and 'MadeiraDock.prefix' in content,
      'the Dock start decides from the Dock prefix before the session starts')
check(re.search(r'setenv\("MADEIRA_DOCK_GAME_SCM", \w+\.exported, 1\)', content) is not None,
      'the decision is exported to the host as MADEIRA_DOCK_GAME_SCM (0 or 1)')
check('DockGameSession.serverSyncOff(' in content and 'DockInstallers.madsyncConfigured' in content,
      'madsync is turned off for a session that starts the service manager')
check('thirdPartyInstalls: DockInstallers.thirdPartyInstalls' in content, "the game's third-party install-script programs feed the decision")
check('DockGameSession.has32BitProgram(in: gameFolder, machine: DockInstallers.machine)' in content
      and 'setenv("MADEIRA_WOW_HOLD_WINDOWS", "1", 1)' in content and 'unsetenv("MADEIRA_WOW_HOLD_WINDOWS")' in content,
      'a Dock game with a 32-bit program of its own has ntdll hold one guest-window placeholder; every other start clears it')
ntdll = (ROOT / 'build/ntdll-unix/virtual_ios.c').read_text(encoding='utf-8', errors='replace')
check(re.search(r'getenv\( "MADEIRA_WOW_HOLD_WINDOWS" \);\s*/\* N:', ntdll) is not None
      and 'want = hold_n > IOS_WOW_MAX_WINDOWS ? IOS_WOW_MAX_WINDOWS : (unsigned)hold_n;' in ntdll,
      'ntdll reads MADEIRA_WOW_HOLD_WINDOWS at session start, bounded by the window registry')
tick = ntdll[ntdll.find('\nvoid ios_wow_pressure_tick( unsigned cycle )'):]
tick = tick[:tick.find('\n}\n')]
check(re.search(r'getenv\( "MADEIRA_WOW_PRESSURE_RELEASE_MB" \);\s*/\* MB:', tick) is not None
      and 'if (!threshold_mb || !ios_wow_placeholder_count || (cycle % 5)) return;' in tick
      and 'ios_wow_reclaim_dead_windows();' in tick
      and 'remove_reserved_area( (void *)base, IOS_WOW_WINDOW_SIZE );' in tick
      and 'ios_wow_placeholders[i].adopted || ios_wow_slot_at_base(' in tick,
      'under band pressure ntdll tears down exited windows and hands back only unadopted placeholders (0 keeps them)')
check('ios_wow_pressure_tick( cycle );' in ntdll, 'the pool warmer runs the pressure check')
installers = (ROOT / 'app/Madeira/DockInstallers.swift').read_text(encoding='utf-8')
check('DockGameSession.isMicrosoftKey(' in installers and 'thirdPartyInstalls = 0' in installers,
      'DockInstallers counts the non-Microsoft records and resets the count at every prepare')
check(re.search(r'if DockInstallers\.serverSync \|\| \w+ \{\s*setenv\("MADEIRA_MADSYNC_SESSION", "0", 1\)', content) is not None,
      'MADEIRA_MADSYNC_SESSION=0 is set for the installers case or the service-manager case, never otherwise')
check(content.count('unsetenv("MADEIRA_MADSYNC_SESSION")') >= 1, 'the variable is cleared for every other session')
check(re.search(r'if scmServerSync, !DockInstallers\.serverSync, getenv\("MADEIRA_FASTSYNC"\) == nil,\s*'
                r'MadeiraConfig\.flag\("MADEIRA_DOCK_GAME_SCM_FASTSYNC"\) \{[^\n]*//[^\n]*\n\s*setenv\("MADEIRA_FASTSYNC", "auto", 1\)', content) is not None,
      'a game session that gives madsync up for the service manager runs fastsync, unless the game set its own value (0 keeps Wine sync)')
check('logStore.log(decision.logLine)' in content or 'logStore.log(scm.logLine)' in content,
      'the decision is logged ([dock-game-scm])')
allowed = dock[dock.index('static let reportAllowed'):dock.index('static let reportRounds')]
for field in ['game-scm', 'game-scm-services', 'game-scm-timeout', 'launch-keep-alive', 'launch-keep-alive-held']:
    check(f'"{field}"' in allowed, f'the report allow-list accepts {field}')
rounds = dock[dock.index('static let reportRounds'):dock.index('static func parseReport')]
check('"ml2020"' in rounds, 'the report accepts the host round ml2020')
check('MADEIRA_DOCK_GAME_SCM`' in docs and 'MADEIRA_DOCK_GAME_SCM_SERVER_SYNC`' in docs and 'MADEIRA_DOCK_KEEP_ALIVE`' in docs,
      'docs/MADEIRA_DOCK.md lists the three switches')
check(pbx.count('DockGameSession.swift') == 6 and 'DockGameSession.swift in Sources */,' in pbx,
      'the project compiles DockGameSession.swift (build file, file reference, group, sources phase)')
check(re.search(r'getenv\("MADEIRA_DOCK_GAME_SCM"\)[^\n]*//', session) is not None
      and re.search(r'flag\("MADEIRA_DOCK_GAME_SCM_SERVER_SYNC"\)[^\n]*//', session) is not None,
      'both reads carry the trailing note the config catalog takes')
catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    for key in ['env.MADEIRA_DOCK_GAME_SCM', 'env.MADEIRA_DOCK_GAME_SCM_FASTSYNC', 'env.MADEIRA_DOCK_GAME_SCM_SERVER_SYNC', 'env.MADEIRA_WOW_HOLD_WINDOWS',
                'env.MADEIRA_WOW_PRESSURE_RELEASE_MB']:
        check(f'key: "{key}"' in text, f'the config catalog documents {key}')
host_launch = ROOT / 'madeira-dock/src/launch.c'
if host_launch.exists():
    launch = host_launch.read_text(encoding='utf-8')
    check('MADEIRA_DOCK_GAME_SCM' in launch and 'MADEIRA_DOCK_KEEP_ALIVE' in launch and 'sh_hold_poll' in launch,
          'the pinned host reads both switches and follows the game tree')
    check((ROOT / 'madeira-dock/src/hold.c').exists(), 'the pinned host has the tracker (src/hold.c)')
    build = (ROOT / 'build/madeira-dock/build.sh').read_text(encoding='utf-8')
    check('-luser32' in build, "Madeira's Dock build links user32 for the host's window enumeration")
else:
    print('SKIP: madeira-dock not checked out; host anchors not checked')
check('no game names' not in session.lower() and not re.search(r'\b(GTA|Rockstar|Red Dead)\b', session + content[content.find('dock-game-scm') - 2000: content.find('dock-game-scm') + 2000]),
      'no game or publisher names in the new code')

# --- compiled -------------------------------------------------------------------------------
swiftc = shutil.which('swiftc')
if not swiftc:
    print('SKIP: swiftc not found; compiled checks not run')
    sys.exit(1 if failures else 0)

stub = '''
import Foundation
enum MadeiraConfig {
    nonisolated(unsafe) static var values: [String: String] = [:]
    nonisolated(unsafe) static var flags: [String: String] = [:]
    static func get(_ key: String) -> String? { values[key] }
    static func flag(_ name: String, fallback: Bool = true) -> Bool {
        if let v = flags[name] { return v != "0" }
        return getenv(name).map { String(cString: $0) != "0" } ?? fallback
    }
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \\.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            out[t[..<eq].trimmingCharacters(in: .whitespaces)] = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}
'''

main = r'''
import Foundation
func expect(_ cond: Bool, _ text: String) { if !cond { print("FAIL: " + text); exit(1) } else { print("PASS: " + text) } }
typealias S = DockGameSession

// modes
expect(S.mode(nil) == .auto && S.mode("") == .auto && S.mode("x") == .auto, "unset, empty and other values mean auto")
expect(S.mode("0") == .off && S.mode(" 1 ") == .on, "0 off, 1 on (whitespace ignored)")
expect(S.configuredMode(gameConfig: "env.MADEIRA_DOCK_GAME_SCM = 1\n") == .on, "the game's own lines win")
MadeiraConfig.values["env.MADEIRA_DOCK_GAME_SCM"] = "0"
expect(S.configuredMode(gameConfig: nil) == .off, "then madeira.cfg")
expect(S.configuredMode(gameConfig: "env.MADEIRA_DOCK_GAME_SCM = 1\n") == .on, "a game line beats madeira.cfg")
MadeiraConfig.values = [:]
setenv("MADEIRA_DOCK_GAME_SCM", "1", 1)
expect(S.configuredMode(gameConfig: nil) == .on, "then the environment")
unsetenv("MADEIRA_DOCK_GAME_SCM")
expect(S.configuredMode(gameConfig: "other = 1\n") == .auto, "a game file without the key leaves auto")

// registry pieces
expect(S.serviceName(section: "[System\\\\CurrentControlSet\\\\Services\\\\PublisherSvc] 1700000000") == "PublisherSvc", "a service section")
expect(S.serviceName(section: "[system\\\\currentcontrolset\\\\services\\\\x] 1") == "x", "section names compare without case")
expect(S.serviceName(section: "[System\\\\CurrentControlSet\\\\Services\\\\PublisherSvc\\\\Parameters] 1") == nil, "a sub-key is not a service")
expect(S.serviceName(section: "[Software\\\\Wine] 1") == nil && S.serviceName(section: "[System\\\\CurrentControlSet\\\\Services] 1") == nil, "other sections")
expect(S.dword("dword:00000002") == 2 && S.dword("dword:00000110") == 0x110 && S.dword("\"x\"") == nil, "dword values")
expect(S.registryString("\"C:\\\\Program Files\\\\P\\\\svc.exe\"") == "C:\\Program Files\\P\\svc.exe", "a REG_SZ image path, backslashes undone")
expect(S.registryString("str(2):\"%SystemRoot%\\\\system32\\\\svchost.exe -k netsvcs\"") == "%SystemRoot%\\system32\\svchost.exe -k netsvcs", "a REG_EXPAND_SZ image path")
expect(S.registryString("\"a \\\"quoted\\\" b\"") == "a \"quoted\" b", "escaped quotes")
expect(S.registryString("dword:00000001") == nil && S.registryString("hex:00,01") == nil, "non-strings")
let kv = S.registryValue("\"ImagePath\"=\"C:\\\\x.exe\"")
expect(kv?.0 == "ImagePath" && kv?.1 == "\"C:\\\\x.exe\"", "key and raw value")
expect(S.registryValue("@=\"default\"") == nil && S.registryValue("\"NoEquals\"") == nil, "non key=value lines")

// the test itself, same as the host's sh_service_is_foreign_autostart
expect(S.isForeignAutoStart(type: 0x10, start: 2, image: "\"C:\\Program Files\\Publisher\\Service.exe\""), "an automatic own-process service outside Windows")
expect(S.isForeignAutoStart(type: 0x20, start: 2, image: "C:\\Games\\svc.exe --run"), "a shared-process one too")
expect(S.isForeignAutoStart(type: 0x10, start: 3, image: "C:\\Games\\svc.exe"), "demand start counts: the program starts it through the manager")
expect(!S.isForeignAutoStart(type: 0x10, start: 4, image: "C:\\Games\\svc.exe"), "disabled does not count")
expect(!S.isForeignAutoStart(type: 0x10, start: 0, image: "C:\\Games\\svc.exe") && !S.isForeignAutoStart(type: 0x10, start: 1, image: "C:\\Games\\svc.exe"), "boot and system start do not count")
expect(!S.isForeignAutoStart(type: 0x1, start: 2, image: "C:\\Games\\drv.sys"), "a kernel driver does not count")
expect(!S.isForeignAutoStart(type: 0x10, start: 2, image: "%SystemRoot%\\system32\\svchost.exe -k x"), "Wine's svchost services do not count")
expect(!S.isForeignAutoStart(type: 0x10, start: 2, image: "C:\\windows\\system32\\spoolsv.exe"), "a Windows-folder image does not count")
expect(!S.isForeignAutoStart(type: 0x10, start: 2, image: "\\SystemRoot\\System32\\drivers\\x.sys") && !S.isForeignAutoStart(type: 0x10, start: 2, image: "System32\\x.exe"), "relative Windows images do not count")
expect(!S.isForeignAutoStart(type: 0x10, start: 2, image: "\\??\\C:\\windows\\system32\\drivers\\y.sys"), "an NT-prefixed Windows path does not count")
expect(!S.isForeignAutoStart(type: 0x10, start: 2, image: "") && !S.isForeignAutoStart(type: 0x10, start: 2, image: "\"\""), "an empty image does not count")
expect(S.isWindowsImage("d:\\windows\\x.exe") && S.isWindowsImage("c:/windows/x.exe") && !S.isWindowsImage("c:\\windows2\\x.exe") && !S.isWindowsImage("c:\\games\\windows\\x.exe"), "the Windows folder on any drive, not a look-alike")

// a Wine system.reg excerpt: Wine's own services, a demand-start anti-cheat style service, one foreign automatic service
let reg = """
WINE REGISTRY Version 2
;; All keys relative to \\\\Machine

#arch=win64

[System\\\\CurrentControlSet\\\\Services\\\\MountMgr] 1700000000
#time=1dc1234
"ErrorControl"=dword:00000001
"ImagePath"=str(2):"%SystemRoot%\\\\system32\\\\winedevice.exe"
"Start"=dword:00000002
"Type"=dword:00000010

[System\\\\CurrentControlSet\\\\Services\\\\PlugPlay] 1700000000
"ImagePath"="C:\\\\windows\\\\system32\\\\plugplay.exe"
"Start"=dword:00000002
"Type"=dword:00000010

[System\\\\CurrentControlSet\\\\Services\\\\DisabledSvc] 1700000000
"ImagePath"="\\"C:\\\\Program Files (x86)\\\\Common Files\\\\AC\\\\acsvc.exe\\""
"Start"=dword:00000004
"Type"=dword:00000010

[System\\\\CurrentControlSet\\\\Services\\\\PublisherService] 1700000000
#time=1dc5678
"DisplayName"="Publisher Library Service"
"ErrorControl"=dword:00000001
"ImagePath"="\\"C:\\\\Program Files\\\\Publisher\\\\Launcher\\\\PublisherService.exe\\""
"ObjectName"="LocalSystem"
"Start"=dword:00000002
"Type"=dword:00000010

[System\\\\CurrentControlSet\\\\Services\\\\PublisherService\\\\Parameters] 1700000000
"Start"=dword:00000002

[System\\\\CurrentControlSet\\\\Services\\\\Spooler] 1700000000
"ImagePath"=str(2):"%SystemRoot%\\\\system32\\\\spoolsv.exe"
"Start"=dword:00000002
"Type"=dword:00000110

"""
let found = S.foreignAutoStartServices(systemReg: reg)
expect(found.map(\.name) == ["PublisherService"], "only the publisher's startable service is found (not Wine's, not a disabled one): \(found.map(\.name))")
expect(found.first?.image == "\"C:\\Program Files\\Publisher\\Launcher\\PublisherService.exe\"", "its image is the registry string")
expect(S.foreignAutoStartServices(systemReg: "").isEmpty && S.foreignAutoStartServices(systemReg: "garbage\n[x\n\"a\"=b").isEmpty, "empty or malformed text finds nothing")

// decisions
let auto = S.Decision(mode: .auto, services: found)
expect(auto.on && auto.exported == "1", "auto with a foreign service: on, exported as 1")
expect(!S.Decision(mode: .auto, services: []).on && S.Decision(mode: .auto, services: []).exported == "0", "auto without: off, exported as 0")
expect(S.Decision(mode: .on, services: []).on && !S.Decision(mode: .off, services: found).on, "on and off ignore the registry")
expect(auto.logLine == "[dock-game-scm] mode=auto services=1 (PublisherService) third-party-installs=0 service-manager=on", "the log line: \(auto.logLine)")
expect(!auto.logLine.contains("Program Files"), "no image path in the log")

// a game whose install script recorded a publisher's program: the service is registered only on
// that program's first run, through the manager, so the registry cannot show it yet
let installs = S.Decision(mode: .auto, services: [], installs: 2)
expect(installs.on && installs.exported == "1", "auto with a third-party install-script program: on")
expect(installs.logLine == "[dock-game-scm] mode=auto services=0 third-party-installs=2 service-manager=on", "its log line: \(installs.logLine)")
expect(!S.Decision(mode: .off, services: [], installs: 2).on, "off still wins")
expect(S.isMicrosoftKey("Software\\Microsoft\\DirectX") && S.isMicrosoftKey("Software\\Wow6432Node\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\x64"),
       "Microsoft's redistributable keys, also through Wow6432Node")
expect(S.isMicrosoftKey("SOFTWARE/microsoft/.NETFramework") && S.isMicrosoftKey("Microsoft\\XNA\\Framework"), "any case, either separator, with or without Software")
expect(!S.isMicrosoftKey("Software\\Publisher\\Steam\\Launcher") && !S.isMicrosoftKey("Software\\Wow6432Node\\Publisher\\SDK") && !S.isMicrosoftKey("Software\\Valve\\Steam\\Apps\\1"),
       "a publisher's key is not Microsoft's")
expect(!S.isMicrosoftKey("") && !S.isMicrosoftKey("Software"), "empty keys are not Microsoft's")

// the prefix read
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("madeira-dock-game-session-\(getpid())", isDirectory: true)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
try! reg.write(to: dir.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
expect(S.decide(prefix: dir, gameConfig: nil).on, "decide reads system.reg from the prefix")
expect(!S.decide(prefix: dir, gameConfig: "env.MADEIRA_DOCK_GAME_SCM = 0\n").on, "a game's 0 wins without reading")
expect(!S.decide(prefix: dir.appendingPathComponent("missing"), gameConfig: nil).on, "a missing registry means off in auto")
expect(S.decide(prefix: dir.appendingPathComponent("missing"), gameConfig: nil, thirdPartyInstalls: 1).on, "unless the game's install script recorded a third-party program")
expect(S.decide(prefix: dir.appendingPathComponent("missing"), gameConfig: nil, thirdPartyInstalls: -3).installs == 0, "a negative count reads as none")
try? FileManager.default.removeItem(at: dir)

// a 32-bit program of the game's own, behind a 64-bit launcher: a synthetic folder of tiny PE files
func pe(_ url: URL, machine: UInt16) {
    var bytes = [UInt8](repeating: 0, count: 64)
    bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
    bytes += [0x50, 0x45, 0, 0, UInt8(machine & 0xff), UInt8(machine >> 8)] + [UInt8](repeating: 0, count: 10)
    try! Data(bytes).write(to: url)
}
let readMachine: (URL) -> UInt16? = { url in
    guard let d = try? Data(contentsOf: url), d.count >= 70, d[0] == 0x4d, d[1] == 0x5a else { return nil }
    return UInt16(d[68]) | UInt16(d[69]) << 8
}
let game = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("madeira-dock-32bit-\(getpid())", isDirectory: true)
try? FileManager.default.removeItem(at: game)
try! FileManager.default.createDirectory(at: game.appendingPathComponent("Installers"), withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: game.appendingPathComponent("bin/deep"), withIntermediateDirectories: true)
pe(game.appendingPathComponent("PlayGame.exe"), machine: 0x8664)
pe(game.appendingPathComponent("Installers/vc_redist.x86.exe"), machine: 0x14c)
pe(game.appendingPathComponent("DXSETUP.exe"), machine: 0x14c)
pe(game.appendingPathComponent("bin/deep/Game32.exe"), machine: 0x14c)
expect(!S.has32BitProgram(in: game, machine: readMachine), "a 64-bit program, a 32-bit redistributable and a 32-bit setup are not a 32-bit game program (depth 2 excluded)")
pe(game.appendingPathComponent("bin/Game32.exe"), machine: 0x14c)
expect(S.has32BitProgram(in: game, machine: readMachine), "a 32-bit program one folder down is")
try? FileManager.default.removeItem(at: game.appendingPathComponent("bin/Game32.exe"))
pe(game.appendingPathComponent("Game.exe"), machine: 0x14c)
expect(S.has32BitProgram(in: game, machine: readMachine), "a 32-bit program at the top is")
expect(!S.has32BitProgram(in: game, machine: readMachine, limit: 0), "the scan is bounded (a limit of 0 looks at nothing)")
expect(!S.has32BitProgram(in: game.appendingPathComponent("missing"), machine: readMachine), "a missing folder has none")
expect(S.isRedistributable("vc_redist.x64.exe") && S.isRedistributable("_CommonRedist") && S.isRedistributable("unins000.exe") && !S.isRedistributable("Game.exe"),
       "the redistributable marks")
try? FileManager.default.removeItem(at: game)

// madsync
expect(S.serverSyncOff(auto, madsyncConfigured: true), "madsync configured and the manager on: this session runs server sync")
expect(!S.serverSyncOff(auto, madsyncConfigured: false), "fastsync configured: nothing to turn off")
expect(!S.serverSyncOff(S.Decision(mode: .auto, services: []), madsyncConfigured: true), "manager off: madsync stays")
MadeiraConfig.flags["MADEIRA_DOCK_GAME_SCM_SERVER_SYNC"] = "0"
expect(!S.serverSyncOff(auto, madsyncConfigured: true), "MADEIRA_DOCK_GAME_SCM_SERVER_SYNC=0 keeps madsync")
print("dock-game-session: compiled checks passed")
'''

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'Stub.swift').write_text(stub)
    (tmp / 'main.swift').write_text(main)
    shutil.copy(ROOT / 'app/Madeira/DockGameSession.swift', tmp / 'DockGameSession.swift')
    exe = tmp / 'check'
    cmd = [swiftc, '-swift-version', '5', '-o', str(exe), str(tmp / 'Stub.swift'), str(tmp / 'DockGameSession.swift'), str(tmp / 'main.swift')]
    build = subprocess.run(cmd, capture_output=True, text=True)
    if build.returncode:
        print(build.stdout, build.stderr)
        check(False, 'the production DockGameSession.swift compiles on the host')
    else:
        run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120)
        print(run.stdout.rstrip())
        if run.stderr.strip(): print(run.stderr.rstrip())
        check(run.returncode == 0, 'the compiled checks pass')

print(f'check-dock-game-session: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
