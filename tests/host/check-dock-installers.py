#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Madeira Dock: a game's one-time installs before the host starts it.

Synthetic data only: no Steam, Wine, iOS or credentials. Compiles production
Swift (app/Madeira/DockInstallers.swift plus DockGame from MadeiraDock.swift)
under AddressSanitizer and checks:
  * install scripts: repeated "Run Process" sections, entries without a
    "HasRunKey" under Steam's per-app key, both registry views, argument and
    path rules;
  * the plan: done / missing / unsupported (by package type and PE machine
    against the bundle, never by name) / pending / per-start limit, and its note;
  * the batch: result file, service-manager step (or "services off"), every
    redirection after a space, nothing written to the registry by the batch;
  * the result parser and the progress text;
  * prepare() end to end in a synthetic prefix: case-insensitive paths, the
    One-time installs choice (a start that runs them turns the choice to Skip,
    Skip runs nothing), results recorded in system.reg (both views) at the next
    start, the per-session madsync request, fusion.dll placement, every switch;
  * madsync_enabled() from build/madsync/madsync.c with the production
    madeira_cfg.h: default on, MADEIRA_MADSYNC_SESSION=0 turns it off, nothing
    else does.
When Windows cmd.exe is reachable (WSL interop) the generated batch also runs for
real with stand-in installers, and with the staged dockhost.exe when it is built.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
CC = os.environ.get('CC') or shutil.which('cc') or shutil.which('clang')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


dock = (app / 'MadeiraDock.swift').read_text(encoding='utf-8')
installers = (app / 'DockInstallers.swift').read_text(encoding='utf-8')
content = (app / 'ContentView.swift').read_text(encoding='utf-8')
view = (app / 'MadeiraDockView.swift').read_text(encoding='utf-8')
steam_games = (app / 'SteamGames.swift').read_text(encoding='utf-8')
madsync = (root / 'build/madsync/madsync.c').read_text(encoding='utf-8')

# ------------------------------------------------------------------ static rules
lower = installers.lower()
# One documented exception: .NET Framework setups (isDotNetFramework, env.MADEIRA_INSTALL_SKIP_DOTNET),
# which do not finish under Wine's own .NET. Outside that function no name decides anything.
named = re.sub(r'nonisolated static func isdotnetframework.*?\n    \}\n', '', lower, flags=re.S)
require('func isdotnetframework' in lower and 'dotnetfx' not in named and
        not any(n in lower for n in ('dxsetup', 'vcredist', 'vc_redist', 'dxwebsetup', 'physx', 'ndp4')),
        'no redistributable names: nothing is decided by program name, except the .NET Framework setups')
require('SteamSignIn.flag(name, default: true)' in installers, 'every installer switch defaults on and reads env.NAME')
for switch in ('MADEIRA_DOCK_INSTALLERS', 'MADEIRA_INSTALL_DEFAULT_KEY', 'MADEIRA_DOCK_INSTALL_CHOICE',
               'MADEIRA_DOCK_INSTALL_SCM', 'MADEIRA_DOCK_INSTALL_SERVER_SYNC', 'MADEIRA_DOTNET_FUSION',
               'MADEIRA_INSTALL_SKIP_DOTNET'):
    require(f'flag("{switch}")' in installers, f'switch {switch} is read')
require('reg.exe' not in installers, 'the batch never writes the registry (no reg.exe in the bundle)')
require(content.count('setenv("MADEIRA_MADSYNC_SESSION", "0", 1)') == 1 and
        re.search(r'if DockInstallers\.serverSync \|\| scmServerSync \{\n\s*setenv\("MADEIRA_MADSYNC_SESSION", "0", 1\)', content) and
        'unsetenv("MADEIRA_MADSYNC_SESSION")' in content,
        'madsync is turned off only for a Dock start that runs installers or starts the service manager')
for name, text in [('MadeiraDock.swift', dock), ('MadeiraDockView.swift', view)]:
    require('MADEIRA_MADSYNC_SESSION' not in text, f'{name}: does not touch the madsync session switch')
start = content.index('private func startDock(')
body = content[start:content.index('\n    }\n', start)]
require(body.index('try MadeiraDock.writeHandoff(') < body.index('DockInstallers.prepare(') < body.index('runWineFullSequence('),
        'installers are planned after the launch checks, before the session starts')
require('installers: DockInstallers.script' in body, 'the planned batch goes into the launch arguments')
require('DockInstallers.poll(drive: MadeiraDock.drive)' in view and 'Picker(game.name' in view and
        'Text("Run at next start").tag(true)' in view and 'Text("Skip").tag(false)' in view, 'the Dock sheet shows the choice and progress')
require('Copyright 2026 125hz' in installers.split('\n', 3)[1], 'new file carries the owner copyright')
# Record as done / Reset: saved from the app, applied by prepare() before it reads the registry.
prep = installers[installers.index('    static func prepare('):]
prep = prep[:prep.index('\n    }\n')]
require(prep.index('absorbResults(') < prep.index('applyRequest(game, found: found, prefix: prefix, drive: drive, others: others)') < prep.index('let registry = '),
        'a saved request is applied after the last results and before the plan reads the registry')
require('var unfinished: [String: [String]]? = nil' in installers and 'var requests: [String: String]? = nil' in installers,
        'new ledger fields are optional (older files still load) and requests are stored by raw value')
require('DockInstallRequestRows(dock: dock, appID: game.id, name: game.name)' in view and
        'DockInstallRequestRows(dock: dock, appID: appID, name: entry.title)' in steam_games and
        'Button("Record as done…")' in view and 'Button("Reset one-time installs…", role: .destructive)' in view and
        view.count('.confirmationDialog(') == 2, 'the Dock sheet and the game page offer Record as done and Reset, each confirmed')
require('[dock-reset]' in installers and 'still running' in installers and 'last-run=unfinished' in installers,
        'reset, stall and unfinished log tags')

# ------------------------------------------------------------------ compiled Swift
game_src = dock[dock.index('/// A game Steam\'s client has installed'):dock.index('/// Madeira Dock: a small headless host')]
stubs = r'''
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
enum SteamSignIn {
    static func flag(_ name: String, default fallback: Bool) -> Bool { getenv(name).map { String(cString: $0) != "0" } ?? fallback }
}
enum MadeiraConfig {
    nonisolated(unsafe) static var values: [String: String] = [:]
    static func get(_ key: String) -> String? { values[key] }
    static var gameURL: URL? { nil }
    // DockGameSession.swift (compiled with the production installers for isMicrosoftKey)
    static func flag(_ name: String, fallback: Bool = true) -> Bool { getenv(name).map { String(cString: $0) != "0" } ?? fallback }
    static func parse(_ text: String) -> [String: String] { [:] }
}
struct LogEntry { enum Level { case info, success, error, debug } }
@MainActor final class LogStore {
    static let shared = LogStore()
    var lines: [String] = []
    func log(_ message: String, level: LogEntry.Level = .info) { lines.append(message) }
}
enum MadeiraDock { static let executable = "C:\\windows\\system32\\dockhost.exe" }
''' + game_src

checks = r'''
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}
func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
/// A minimal PE header with the given machine.
func pe(_ url: URL, machine: UInt16) throws {
    var bytes = [UInt8](repeating: 0, count: 64 + 24)
    bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
    bytes[64] = 0x50; bytes[65] = 0x45
    bytes[68] = UInt8(machine & 0xff); bytes[69] = UInt8(machine >> 8)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: url)
}
@MainActor func logged(_ text: String) -> Bool { LogStore.shared.lines.contains { $0.contains(text) } }

@main struct Checks {
    @MainActor static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        // ---- install scripts
        let script = """
        "installscript"
        {
            "registry" { "HKEY_LOCAL_MACHINE\\\\SOFTWARE\\\\Fixture Vendor" { "string" { "Install Dir" "%INSTALLDIR%" } } }
            "run process"
            {
                "Runtime A"
                {
                    "process 1"   "%INSTALLDIR%\\\\_CommonRedist\\\\RuntimeA\\\\setup32.exe"
                    "command 1"   "/silent"
                }
            }
            "run process"
            {
                "Tool"
                {
                    "HasRunKey"   "HKEY_LOCAL_MACHINE\\\\SOFTWARE\\\\Fixture Tool"
                    "process 1"   "%INSTALLDIR%\\\\redist\\\\tool.exe"
                    "MinimumHasRunValue" "81017"
                }
                "Package" { "process 1" "%INSTALLDIR%/redist/pkg.msi" "command 1" "/qn" }
                "Gone" { "process 1" "%INSTALLDIR%\\\\missing.exe" }
                "Unsafe" { "process 1" "%INSTALLDIR%\\\\x.exe" "command 1" "/a & calc" }
                "Escape" { "process 1" "%INSTALLDIR%\\\\..\\\\..\\\\x.exe" }
                "NoProgram" { "NoCleanUp" "1" }
            }
            "run process on uninstall" { "Cleanup" { "process 1" "%INSTALLDIR%\\\\cleanup.exe" } }
        }
        """
        let dir = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Fixture Game"
        let withKey = DockInstallScripts.processes(script: Data(script.utf8), installDir: dir, appID: 7000)
        require(withKey.map(\.run.name) == ["runtime a", "tool", "package", "gone"], "repeated sections all count; unsafe, escaping and uninstall entries dropped (\(withKey.map(\.run.name)))")
        let withoutKey = DockInstallScripts.processes(script: Data(script.utf8), installDir: dir)
        require(withoutKey.map(\.run.name) == ["tool"], "without an app ID only HasRunKey entries count")
        let runtime = withKey[0], tool = withKey[1], package = withKey[2]
        require(runtime.run.hive == .machine && runtime.run.key == "Software\\Valve\\Steam\\Apps\\7000" && runtime.run.value == 1, "no HasRunKey: Steam's per-app key, value 1")
        require(tool.run.key == "SOFTWARE\\Fixture Tool" && tool.run.value == 81017, "HasRunKey and minimum kept")
        require(runtime.arguments == "/silent" && runtime.executable == dir + "\\_CommonRedist\\RuntimeA\\setup32.exe", "program and arguments expanded")
        require(package.executable == dir + "\\redist\\pkg.msi" && package.arguments == "/qn", "forward slashes become Windows separators")
        require(SteamInstallScripts.keys(runtime.run) == ["Software\\Valve\\Steam\\Apps\\7000", "Software\\Wow6432Node\\Valve\\Steam\\Apps\\7000"], "both registry views")
        require(SteamInstallScripts.keys(SteamInstallRun(name: "u", hive: .user, key: "Software\\X", value: 1)) == ["Software\\X"], "HKCU: one view")
        require(SteamInstallScripts.entries(script: Data(script.utf8), appID: 0).count == 1, "invalid app IDs add nothing")

        // ---- recorded values
        let record = """
        WINE REGISTRY Version 2

        [Software\\\\Wow6432Node\\\\Valve\\\\Steam\\\\Apps\\\\7000] 1700000000
        "runtime a"=dword:00000001

        [Software\\\\Wow6432Node\\\\Fixture Tool] 1700000000
        "Tool"=dword:00000010
        """
        require(DockInstallScripts.marked(runtime.run, in: record), "a Windows client's own record (32-bit view) counts")
        require(DockInstallScripts.recorded(tool.run, in: record) == 16 && !DockInstallScripts.marked(tool.run, in: record), "a value below the minimum is not done")
        let (marked, changed) = SteamInstallScripts.mark([tool.run], in: record, now: 1)
        require(changed == 2 && DockInstallScripts.recorded(tool.run, in: marked) == 81017 && DockInstallScripts.marked(tool.run, in: marked), "mark raises both views")
        require(SteamInstallScripts.mark([tool.run], in: marked, now: 2).changed == 0, "marking again changes nothing")
        let (unmarked, removedValues) = SteamInstallScripts.unmark([tool.run], in: marked)
        require(removedValues == 2 && DockInstallScripts.recorded(tool.run, in: unmarked) == nil &&
                unmarked.contains("[SOFTWARE\\\\Fixture Tool]") && DockInstallScripts.marked(runtime.run, in: unmarked),
                "unmark removes the entry's value from both views; keys and other entries stay")
        require(SteamInstallScripts.unmark([tool.run], in: unmarked).removed == 0, "unmarking again removes nothing")

        // ---- plan and note
        let none: (SteamInstallRun) -> Bool = { _ in false }
        var plan = DockInstallScripts.plan(withKey, done: none, exists: { _ in true })
        require(plan.map(\.status) == [.pending, .pending, .pending, .pending], "everything pending, whatever the program")
        plan = DockInstallScripts.plan(withKey, done: { $0.name == "tool" }, exists: { !$0.hasSuffix("missing.exe") },
                                       runnable: { $0.executable.hasSuffix(".msi") ? "Windows Installer package" : nil })
        require(plan.map(\.status) == [.pending, .done, .unsupported, .missing], "done, missing, unsupported, pending (\(plan.map(\.status.rawValue)))")
        let note = DockInstallScripts.note(plan) ?? ""
        require(note.contains("Runs first: runtime a") && note.contains("Already done: tool") && note.contains("Installer file missing: gone") &&
                note.contains("Cannot run in this build: package (Windows Installer package)"), "the note names every fate (\(note))")
        require(DockInstallScripts.note(DockInstallScripts.plan(withKey, done: { _ in true }, exists: { _ in true })) == nil, "all done: no note")
        plan = DockInstallScripts.plan(withKey, limit: 1, done: none, exists: { _ in true })
        require(plan.map(\.status) == [.pending, .limit, .limit, .limit], "per-start limit")
        require(DockInstallScripts.label(SteamInstallRun(name: "a&b|c>%d\"e f", hive: .machine, key: "k", value: 1)) == "abcde f", "labels keep only safe characters")

        // ---- the batch
        let result = "C:\\madeira-dock-installers.result"
        let r = " >>\"C:\\madeira-dock-installers.result\""
        let batch = DockInstallScripts.batch([runtime, package], resultFile: result, services: .start("C:\\windows\\system32\\dockhost.exe"))
        let lines = batch.components(separatedBy: "\r\n")
        require(batch.hasPrefix("@echo off\r\n") && batch.hasSuffix("\r\n"), "CRLF batch")
        let order = ["echo begin 2 >\"C:\\madeira-dock-installers.result\"",
                     "\"C:\\windows\\system32\\dockhost.exe\" --start-services" + r,
                     "if not \"%ERRORLEVEL%\"==\"0\" echo services failed" + r,
                     "echo start 1 runtime a" + r, "call \"" + runtime.executable + "\" /silent", "echo exit 1 %ERRORLEVEL%" + r,
                     "echo start 2 package" + r, "C:\\windows\\system32\\msiexec.exe /i \"" + package.executable + "\" /qn", "echo exit 2 %ERRORLEVEL%" + r,
                     "echo end" + r].map { lines.firstIndex(of: $0) }
        require(order.allSatisfy { $0 != nil } && zip(order, order.dropFirst()).allSatisfy { $0! < $1! }, "begin, services, each program with its exit, end")
        require(!lines.contains { $0.contains(">>\"") && !$0.contains(" >>\"") }, "every redirection follows a space")
        require(lines.filter { $0.contains("--start-services") }.count == 1, "services started once")
        let off = DockInstallScripts.batch([runtime], resultFile: result, services: .off)
        require(off.contains("echo services off" + r) && !off.contains("--start-services"), "services off: recorded, dockhost not run")
        require(!batch.lowercased().contains("reg.exe") && !batch.contains("errorlevel 1"), "the batch records nothing itself; no 'if not errorlevel 1'")

        // ---- results
        let parsed = DockInstallScripts.results("begin 3 \r\nservices started\r\nstart 1 runtime a \r\nexit 1 -9 \r\nstart 2 tool \r\nexit 2 3010 \r\nstart 3 package \r\n")
        require(parsed.total == 3 && parsed.exits == [1: -9, 2: 3010] && parsed.started[3] == "package" && parsed.services == "started", "parsed statuses and labels")
        require(parsed.running == 3 && !parsed.ended, "running program, not ended")
        require(!DockInstallScripts.Results.succeeded(-9) && DockInstallScripts.Results.succeeded(3010) &&
                DockInstallScripts.Results.succeeded(1641) && DockInstallScripts.Results.succeeded(0), "success statuses")
        require(DockInstallScripts.results("services timeout\n").services == "timeout" && DockInstallScripts.results("services st&a|rted>\n").services == "started", "service outcomes, letters only")
        require(DockInstallScripts.results("start 99 x\nexit abc\nbogus\nservices\n") == DockInstallScripts.Results(), "malformed lines ignored")

        // ---- ledger
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dock-installers-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        let prefix = base.appendingPathComponent("wine"), drive = prefix.appendingPathComponent("drive_c")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        require(DockInstallLedger.load(prefix: prefix) == DockInstallLedger() && DockInstallLedger().runsNext(1), "no file: empty ledger; a fresh game runs its installs")
        var ledger = DockInstallLedger(); ledger.session = [tool.run]; ledger.sessionApp = 7000; ledger.runNext["7000"] = false
        try ledger.save(prefix: prefix)
        require(DockInstallLedger.load(prefix: prefix) == ledger && !ledger.runsNext(7000), "JSON round trip")
        try write(prefix.appendingPathComponent(DockInstallLedger.fileName), "{not json")
        require(DockInstallLedger.load(prefix: prefix) == DockInstallLedger(), "a damaged file reads as empty")
        // A file written before the unfinished/requests fields existed still loads.
        try write(prefix.appendingPathComponent(DockInstallLedger.fileName), "{\"runNext\":{\"7000\":false},\"session\":[],\"sessionApp\":0}")
        let older = DockInstallLedger.load(prefix: prefix)
        require(!older.runsNext(7000) && older.requests == nil && older.unfinished == nil, "an older ledger file keeps its choice")
        try write(prefix.appendingPathComponent(DockInstallLedger.fileName), "{\"runNext\":{\"7000\":false},\"session\":[],\"sessionApp\":0,\"requests\":{\"7000\":\"later\"}}")
        let unknown = DockInstallLedger.load(prefix: prefix)
        require(!unknown.runsNext(7000) && unknown.request(7000) == nil, "an unknown request value reads as none, the choice stays")
        var requested = DockInstallLedger()
        requested.setRequest(7000, .record); requested.setUnfinished(7000, ["tool"])
        require(requested.request(7000) == .record && requested.unfinishedRuns(7000) == ["tool"], "request and unfinished entries kept per game")
        requested.setRequest(7000, nil); requested.setUnfinished(7000, [])
        require(requested == DockInstallLedger(), "cleared entries are stored as absent")

        // ---- paths and what this build can run
        let game = DockGame(id: 7000, name: "Fixture", installDir: "Fixture Game", library: "Program Files (x86)/Steam/steamapps",
                            installed: true, customExecutables: false)
        let common = drive.appendingPathComponent("Program Files (x86)/Steam/steamapps/common")
        let folder = common.appendingPathComponent("Fixture Game")
        try write(folder.appendingPathComponent("installscript.vdf"), script)
        try pe(folder.appendingPathComponent("_CommonRedist/RuntimeA/setup32.exe"), machine: 0x14c)
        try pe(folder.appendingPathComponent("Redist/Tool.EXE"), machine: 0x8664)
        try write(folder.appendingPathComponent("Redist/PKG.msi"), "msi")
        try write(common.appendingPathComponent("Steamworks Shared/_CommonRedist/Shared/2015/installscript.vdf"),
                  "\"installscript\" { \"run process\" { \"Shared Runtime\" { \"HasRunKey\" \"HKEY_LOCAL_MACHINE\\\\Software\\\\Fixture Shared\" \"process 1\" \"%INSTALLDIR%\\\\_CommonRedist\\\\Shared\\\\2015\\\\setup.exe\" } } }")
        try pe(common.appendingPathComponent("Steamworks Shared/_CommonRedist/Shared/2015/setup.exe"), machine: 0x8664)
        try write(folder.appendingPathComponent("bin/other.vdf"), "\"nothing\" { }")
        require(DockInstallers.resolve(dir + "\\redist\\tool.exe", drive: drive)?.lastPathComponent == "Tool.EXE", "paths resolve case-insensitively")
        require(DockInstallers.resolve(dir + "\\..\\..\\x.exe", drive: drive) == nil && DockInstallers.resolve("D:\\x.exe", drive: drive) == nil &&
                DockInstallers.resolve(dir + "\\nothing.exe", drive: drive) == nil, "parent references, other drives and absent files do not resolve")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: base)
        require(DockInstallers.resolve(dir + "\\link\\wine", drive: drive) == nil, "a link out of drive_c does not resolve")
        require(DockInstallers.machine(folder.appendingPathComponent("_CommonRedist/RuntimeA/setup32.exe")) == 0x14c &&
                DockInstallers.machine(folder.appendingPathComponent("Redist/PKG.msi")) == nil, "PE machine read")
        require(DockInstallers.runnable(runtime, drive: drive, has32Bit: false, hasMsiexec: false) == "32-bit installer" &&
                DockInstallers.runnable(runtime, drive: drive, has32Bit: true, hasMsiexec: false) == nil, "a 32-bit installer needs 32-bit support")
        require(DockInstallers.runnable(tool, drive: drive, has32Bit: false, hasMsiexec: false) == nil, "an x64 installer runs")
        require(DockInstallers.runnable(package, drive: drive, has32Bit: true, hasMsiexec: false) == "Windows Installer package" &&
                DockInstallers.runnable(package, drive: drive, has32Bit: false, hasMsiexec: true) == nil, "a package needs msiexec.exe")
        // .NET Framework setups: Wine's own .NET answers for them (Arkham City's DotNetFx35.exe never finished).
        func setup(_ exe: String, key: String = "Software\\Valve\\Steam\\Apps\\200260") -> SteamInstallProcess {
            SteamInstallProcess(run: SteamInstallRun(name: "dotnet", hive: .machine, key: key, value: 1), executable: exe, arguments: "/q")
        }
        let fx35 = setup("C:\\Games\\Setup\\DotNetFx35.exe")
        require(DockInstallers.runnable(fx35, drive: drive, has32Bit: true, hasMsiexec: true, skipDotNet: true) == "Wine's own .NET is used" &&
                DockInstallers.runnable(fx35, drive: drive, has32Bit: true, hasMsiexec: true) == nil, "a .NET Framework setup is left out only with skipDotNet")
        require(DockInstallers.isDotNetFramework(setup("C:\\x\\NDP472-KB4054530-x86-x64-AllOS-ENU.exe")) &&
                DockInstallers.isDotNetFramework(setup("C:\\x\\setup.exe", key: "SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full")) &&
                DockInstallers.isDotNetFramework(setup("C:\\x\\setup.exe", key: "Software\\Valve\\Steam\\Apps\\CommonRedist\\DotNet\\3.5")),
                "  found by file name or by its setup key")
        require(!DockInstallers.isDotNetFramework(setup("C:\\x\\windowsdesktop-runtime-8.0.11-win-x64.exe")) &&
                !DockInstallers.isDotNetFramework(setup("C:\\x\\DXSETUP.exe", key: "Software\\Valve\\Steam\\Apps\\CommonRedist\\DirectX\\Jun2010")) &&
                !DockInstallers.isDotNetFramework(tool), "  newer .NET, DirectX and other programs still run")
        let (found, scripts) = DockInstallers.found(game, drive: drive, defaultKey: true)
        require(scripts == 2 && found.map(\.run.name) == ["runtime a", "tool", "package", "gone", "shared runtime"], "game and shared scripts (\(found.map(\.run.name)))")
        require(found[4].executable == "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Steamworks Shared\\_CommonRedist\\Shared\\2015\\setup.exe",
                "shared scripts expand %INSTALLDIR% to Steamworks Shared")
        require(DockInstallers.found(game, drive: drive, defaultKey: false).processes.map(\.run.name) == ["tool", "shared runtime"],
                "MADEIRA_INSTALL_DEFAULT_KEY=0: entries without a key are ignored")
        require(DockInstallers.programCount(game, drive: drive) == 5, "the sheet's program count")

        // ---- prepare(): a first start on a bundle without 32-bit support or msiexec
        MadeiraConfig.values["inproc-sync"] = "1"   // madsync chosen: the per-session request applies
        setenv("MADEIRA_DOCK_INSTALL_SEPARATE", "0", 1)   // the same session; the installs-only default is checked below
        try? FileManager.default.removeItem(at: prefix.appendingPathComponent(DockInstallLedger.fileName))
        try write(prefix.appendingPathComponent("system.reg"), "WINE REGISTRY Version 2\n\n[Software\\\\Wow6432Node\\\\Fixture Shared] 1700000000\n\"Shared Runtime\"=dword:00000001\n")
        try write(prefix.appendingPathComponent("user.reg"), "WINE REGISTRY Version 2\n")
        DockInstallers.prepare(game, drive: drive, prefix: prefix, has32Bit: false, hasMsiexec: false, fusionSource: nil)
        require(DockInstallers.script == "C:\\madeira-dock-installers.cmd" && DockInstallers.serverSync, "pending program: batch and a per-session madsync request")
        let written = (try? String(contentsOf: drive.appendingPathComponent("madeira-dock-installers.cmd"), encoding: .utf8)) ?? ""
        require(written.contains("echo start 1 tool") && !written.contains("start 2") && written.contains("--start-services"), "the batch runs only the runnable pending program, after the service step")
        ledger = DockInstallLedger.load(prefix: prefix)
        require(ledger.session == [tool.run] && ledger.sessionApp == 7000 && !ledger.runsNext(7000), "session recorded; the choice turns to Skip")
        let firstNote = DockInstallers.note ?? ""
        require(firstNote.contains("Runs first: tool") && firstNote.contains("runtime a (32-bit installer)") && firstNote.contains("package (Windows Installer package)") &&
                firstNote.contains("Installer file missing: gone") && firstNote.contains("Already done: shared runtime") && firstNote.contains("standard synchronization"),
                "the sheet's note (\(firstNote))")
        require(logged("dotnet-fusion=no-source") && logged("program=runtime a file=setup32.exe status=unsupported reason=32-bit-installer"), "fusion and per-program log lines")
        require(MadeiraDockLaunch.arguments(DockInstallers.script) ==
                "/desktop=madeira,1280x720 C:\\windows\\system32\\cmd.exe /c call C:\\madeira-dock-installers.cmd & C:\\windows\\system32\\dockhost.exe",
                "installers first, then the host, in one session, no quoted tokens")
        require(DockInstallers.poll(drive: drive) == "Starting this game's one-time installs…", "progress before the batch starts")
        try write(drive.appendingPathComponent("madeira-dock-installers.result"), "begin 1 \r\nservices started\r\nstart 1 tool \r\n")
        require(DockInstallers.poll(drive: drive) == "Running one-time install 1 of 1: tool…" && logged("services=started") && logged("start 1/1 program=tool"), "progress while running")
        require(DockInstallers.finishedAt == nil, "not finished while a program runs")
        let finished = "begin 1 \r\nservices started\r\nstart 1 tool \r\nexit 1 0 \r\nend \r\n"
        try write(drive.appendingPathComponent("madeira-dock-installers.result"), finished)
        require(DockInstallers.poll(drive: drive) == "One-time installs finished: 1 of 1 succeeded." && logged("exit 1/1 program=tool status=0 succeeded"), "progress when finished")
        let ended = DockInstallers.finishedAt
        _ = DockInstallers.poll(drive: drive)
        require(ended != nil && DockInstallers.finishedAt == ended &&
                LogStore.shared.lines.filter({ $0.contains("[dock-installers] end succeeded=1 failed=0 of=1; the host starts next") }).count == 1,
                "the end is logged once and its time kept (the starting screen times the host from it)")
        unsetenv("MADEIRA_DOCK_INSTALL_SEPARATE")
        // The words count what succeeded and name what failed (the text reads only the result file).
        try write(drive.appendingPathComponent("madeira-dock-installers.result"),
                  "begin 3 \r\nservices started\r\nstart 1 tool \r\nexit 1 0 \r\nstart 2 b \r\nexit 2 5 \r\nstart 3 c \r\nexit 3 -1073741819 \r\nend \r\n")
        require(DockInstallers.poll(drive: drive) == "One-time installs finished: 1 of 3 succeeded.\nFailed: b (exit 5), c (exit -1073741819)",
                "finished with failures: how many succeeded, which failed")
        try write(drive.appendingPathComponent("madeira-dock-installers.result"), finished)

        // ---- the next start records the result and plans again: nothing is left to run
        DockInstallers.prepare(game, drive: drive, prefix: prefix, has32Bit: false, hasMsiexec: false, fusionSource: nil)
        let system = (try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)) ?? ""
        require(DockInstallScripts.recorded(tool.run, in: system) == 81017 && system.contains("[Software\\\\Wow6432Node\\\\Fixture Tool]") &&
                system.contains("[SOFTWARE\\\\Fixture Tool]"), "a program that exited 0 is recorded in both views at the next start")
        require(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg.madeira-bak").path), "a backup of system.reg is kept once")
        require(logged("results reason=next-start succeeded=1 failed=0 recorded-values=2 services=started ended=1 statuses=tool=0"), "one summary line")
        require(DockInstallers.script == nil && !DockInstallers.serverSync && DockInstallers.finishedAt == nil,
                "nothing pending: no batch, madsync untouched, no installs' end")
        require(!FileManager.default.fileExists(atPath: drive.appendingPathComponent("madeira-dock-installers.result").path) &&
                DockInstallLedger.load(prefix: prefix).session.isEmpty, "result file and session list cleared")

        // ---- Skip, then Run at next start, with 32-bit support and fusion.dll
        let fusion = base.appendingPathComponent("bundle/i386-windows/fusion.dll")
        try write(fusion, "MZ fusion")
        DockInstallers.prepare(game, drive: drive, prefix: prefix, has32Bit: true, hasMsiexec: false, fusionSource: fusion)
        require(DockInstallers.script == nil && logged("choice=skip pending=1") && (DockInstallers.note ?? "").contains("skipped"), "Skip starts without the pending program")
        DockInstallers.setRunsNext(7000, true, prefix: prefix)
        require(DockInstallLedger.load(prefix: prefix).runsNext(7000), "Run at next start is saved")
        DockInstallers.prepare(game, drive: drive, prefix: prefix, has32Bit: true, hasMsiexec: false, fusionSource: fusion)
        let second = (try? String(contentsOf: drive.appendingPathComponent("madeira-dock-installers.cmd"), encoding: .utf8)) ?? ""
        require(DockInstallers.script != nil && second.contains("echo start 1 runtime a") && second.contains("/silent"), "with 32-bit support the 32-bit installer runs")
        let placed = drive.appendingPathComponent("windows/Microsoft.NET/Framework/v2.0.50727/fusion.dll")
        require((try? String(contentsOf: placed, encoding: .utf8)) == "MZ fusion" && logged("dotnet-fusion=placed"), "fusion.dll placed before a start that runs installers")
        require(DockInstallers.placeDotNetFusion(drive: drive, source: fusion) == "present", "an existing fusion.dll is never replaced")
        // The batch did not run at all (the app was closed first): nothing recorded, the program is pending again.
        DockInstallers.setRunsNext(7000, true, prefix: prefix)
        DockInstallers.prepare(game, drive: drive, prefix: prefix, has32Bit: true, hasMsiexec: false, fusionSource: fusion)
        require(logged("none: the batch did not start") && DockInstallers.script != nil, "a batch that never ran records nothing")

        // ---- switches
        setenv("MADEIRA_DOCK_INSTALL_CHOICE", "0", 1)
        DockInstallers.setRunsNext(7000, true, prefix: prefix)
        DockInstallers.prepare(game, drive: drive, prefix: prefix, has32Bit: true, hasMsiexec: false, fusionSource: nil)
        require(DockInstallers.script != nil && DockInstallLedger.load(prefix: prefix).runNext["7000"] == nil, "MADEIRA_DOCK_INSTALL_CHOICE=0: runs every start, choice untouched")
        unsetenv("MADEIRA_DOCK_INSTALL_CHOICE")
        setenv("MADEIRA_DOCK_INSTALL_SERVER_SYNC", "0", 1)
        DockInstallers.setRunsNext(7000, true, prefix: prefix)
        DockInstallers.prepare(game, drive: drive, prefix: prefix, has32Bit: true, hasMsiexec: false, fusionSource: nil)
        let keep = (try? String(contentsOf: drive.appendingPathComponent("madeira-dock-installers.cmd"), encoding: .utf8)) ?? ""
        require(DockInstallers.script != nil && !DockInstallers.serverSync && keep.contains("echo services off") && !keep.contains("--start-services"),
                "MADEIRA_DOCK_INSTALL_SERVER_SYNC=0 with madsync: madsync kept, service step left out")
        MadeiraConfig.values["inproc-sync"] = "0"
        DockInstallers.setRunsNext(7000, true, prefix: prefix)
        DockInstallers.prepare(game, drive: drive, prefix: prefix, has32Bit: true, hasMsiexec: false, fusionSource: nil)
        require(!DockInstallers.serverSync && ((try? String(contentsOf: drive.appendingPathComponent("madeira-dock-installers.cmd"), encoding: .utf8)) ?? "").contains("--start-services"),
                "madsync already off in madeira.cfg: the service step runs without a session request")
        MadeiraConfig.values = [:]
        DockInstallers.setRunsNext(7000, true, prefix: prefix)
        DockInstallers.prepare(game, drive: drive, prefix: prefix, has32Bit: true, hasMsiexec: false, fusionSource: nil)
        require(!DockInstallers.serverSync && ((try? String(contentsOf: drive.appendingPathComponent("madeira-dock-installers.cmd"), encoding: .utf8)) ?? "").contains("--start-services")
                && !(DockInstallers.note ?? "").contains("standard synchronization"),
                "no inproc-sync (fastsync, the default engine): the service step runs, no madsync note")
        require((DockInstallers.note ?? "").contains("This start runs only them; afterwards restart Madeira and start the game again.")
                && logged("this session runs only the one-time installs"),
                "MADEIRA_DOCK_INSTALL_SEPARATE (on by default): a start that runs installers runs only them")
        unsetenv("MADEIRA_DOCK_INSTALL_SERVER_SYNC")
        setenv("MADEIRA_DOCK_INSTALL_SCM", "0", 1)
        DockInstallers.setRunsNext(7000, true, prefix: prefix)
        DockInstallers.prepare(game, drive: drive, prefix: prefix, has32Bit: true, hasMsiexec: false, fusionSource: nil)
        require(((try? String(contentsOf: drive.appendingPathComponent("madeira-dock-installers.cmd"), encoding: .utf8)) ?? "").contains("echo services off"),
                "MADEIRA_DOCK_INSTALL_SCM=0: services off")
        unsetenv("MADEIRA_DOCK_INSTALL_SCM")
        try? FileManager.default.removeItem(at: placed)
        setenv("MADEIRA_DOTNET_FUSION", "0", 1)
        DockInstallers.setRunsNext(7000, true, prefix: prefix)
        DockInstallers.prepare(game, drive: drive, prefix: prefix, has32Bit: true, hasMsiexec: false, fusionSource: fusion)
        require(!FileManager.default.fileExists(atPath: placed.path), "MADEIRA_DOTNET_FUSION=0 leaves the folder alone")
        unsetenv("MADEIRA_DOTNET_FUSION")
        setenv("MADEIRA_DOCK_INSTALLERS", "0", 1)
        DockInstallers.setRunsNext(7000, true, prefix: prefix)
        DockInstallers.prepare(game, drive: drive, prefix: prefix, has32Bit: true, hasMsiexec: true, fusionSource: nil)
        require(DockInstallers.script == nil && !DockInstallers.serverSync && DockInstallers.note == nil && !DockInstallers.choiceEnabled &&
                DockInstallers.programCount(game, drive: drive) == 0, "MADEIRA_DOCK_INSTALLERS=0: nothing runs, nothing is shown")
        unsetenv("MADEIRA_DOCK_INSTALLERS")

        // ---- per-start limit keeps the choice
        var many = "\"installscript\" { \"run process\" {"
        for i in 1...9 { many += " \"P\(i)\" { \"HasRunKey\" \"HKEY_LOCAL_MACHINE\\\\Software\\\\Many\" \"process 1\" \"%INSTALLDIR%\\\\p\(i).exe\" }" }
        many += " } }"
        let big = DockGame(id: 7001, name: "Many", installDir: "Many", library: "Program Files (x86)/Steam/steamapps", installed: true, customExecutables: false)
        try write(common.appendingPathComponent("Many/installscript.vdf"), many)
        for i in 1...9 { try pe(common.appendingPathComponent("Many/p\(i).exe"), machine: 0x8664) }
        DockInstallers.prepare(big, drive: drive, prefix: prefix, has32Bit: true, hasMsiexec: true, fusionSource: nil)
        require(DockInstallLedger.load(prefix: prefix).session.count == 8 && DockInstallLedger.load(prefix: prefix).runsNext(7001) &&
                (DockInstallers.note ?? "").contains("Next start: p9"), "over the limit: 8 run, the rest next start, choice stays Run")

        // ---- an installer that never closes: the stall notice, its unfinished record, Record as done, Reset
        let solo = DockGame(id: 7002, name: "Solo", installDir: "Solo", library: "Program Files (x86)/Steam/steamapps", installed: true, customExecutables: false)
        try write(common.appendingPathComponent("Solo/installscript.vdf"),
                  "\"installscript\" { \"run process\" { \"Setup\" { \"HasRunKey\" \"HKEY_LOCAL_MACHINE\\\\Software\\\\Solo\" \"process 1\" \"%INSTALLDIR%\\\\setup.exe\" } } }")
        try pe(common.appendingPathComponent("Solo/setup.exe"), machine: 0x8664)
        let soloFound = DockInstallers.found(solo, drive: drive, defaultKey: true).processes
        let setupRun = soloFound.first(where: { $0.run.name == "setup" })!.run
        let sharedRun = soloFound.first(where: { $0.run.name == "shared runtime" })!.run
        require(DockInstallers.own(soloFound, game: solo) == [setupRun], "Record as done / Reset act on the game's own programs, not shared redistributables")
        DockInstallers.prepare(solo, drive: drive, prefix: prefix, has32Bit: true, hasMsiexec: true, fusionSource: nil)
        require(DockInstallers.script != nil && !DockInstallLedger.load(prefix: prefix).runsNext(7002), "first start runs the game's installer")
        try write(drive.appendingPathComponent("madeira-dock-installers.result"), "begin 1 \r\nservices started\r\nstart 1 setup \r\n")
        let t0 = Date()
        require(DockInstallers.poll(drive: drive, now: t0) == "Running one-time install 1 of 1: setup…", "a fresh run: no stall words")
        let stalled = DockInstallers.poll(drive: drive, now: t0.addingTimeInterval(601)) ?? ""
        require(stalled.hasPrefix("Running one-time install 1 of 1: setup… (10 min)\nIf its window no longer changes") && stalled.contains("Record as done"),
                "after 10 minutes on one program the text names the minutes and the way out (\(stalled))")
        _ = DockInstallers.poll(drive: drive, now: t0.addingTimeInterval(900))
        require(LogStore.shared.lines.filter({ $0.contains("[dock-installers] still running 1/1 program=setup after 601 s") }).count == 1 &&
                !logged("after 900 s"), "the stall is logged once per program")
        // The session ended with the installer still open: the next start keeps it unfinished.
        DockInstallers.prepare(solo, drive: drive, prefix: prefix, has32Bit: true, hasMsiexec: true, fusionSource: nil)
        require(logged("statuses=setup=unfinished") && DockInstallLedger.load(prefix: prefix).unfinishedRuns(7002) == ["setup"], "an unfinished program is remembered")
        require(DockInstallers.script == nil && logged("program=setup file=setup.exe status=pending") && logged("last-run=unfinished") &&
                logged("app=7002 unfinished=setup") && (DockInstallers.note ?? "").contains("Last run did not finish: setup") &&
                (DockInstallers.note ?? "").contains("Record as done"), "Skip: the log and the note name the unfinished program (\(DockInstallers.note ?? ""))")
        // Record as done: saved now, applied at the next start.
        DockInstallers.setRequest(7002, .record, prefix: prefix)
        var soloSystem = (try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)) ?? ""
        require(DockInstallLedger.load(prefix: prefix).request(7002) == .record && !DockInstallScripts.marked(setupRun, in: soloSystem),
                "a request changes nothing in the prefix until the next start")
        DockInstallers.setRequest(7002, nil, prefix: prefix)
        require(DockInstallLedger.load(prefix: prefix).requests == nil, "a request can be cancelled")
        DockInstallers.setRequest(7002, .record, prefix: prefix)
        DockInstallers.prepare(solo, drive: drive, prefix: prefix, has32Bit: true, hasMsiexec: true, fusionSource: nil)
        soloSystem = (try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)) ?? ""
        require(logged("[dock-installers] app=7002 record-as-done: records written programs=setup values=2 shared-kept=1") &&
                DockInstallScripts.marked(setupRun, in: soloSystem) && DockInstallers.script == nil && DockInstallers.note == nil,
                "Record as done: recorded in both views before the plan, nothing runs")
        ledger = DockInstallLedger.load(prefix: prefix)
        require(ledger.request(7002) == nil && ledger.unfinishedRuns(7002).isEmpty, "the request and the unfinished entry are cleared")
        // madeira-bcd: other games of the prefix. Twin's own installer records under Solo's key,
        // Triplet runs its own copy of Solo's setup.exe, Other shares neither (shareReset).
        func extra(_ id: Int, _ name: String, _ script: String, _ file: String) throws -> (DockGame, [SteamInstallRun]) {
            let game = DockGame(id: id, name: name, installDir: name, library: "Program Files (x86)/Steam/steamapps", installed: true, customExecutables: false)
            try write(common.appendingPathComponent(name + "/installscript.vdf"), script)
            try pe(common.appendingPathComponent(name + "/" + file), machine: 0x8664)
            let runs = DockInstallers.own(DockInstallers.found(game, drive: drive, defaultKey: true).processes, game: game)
            _ = try SteamInstallScripts.mark(runs, prefix: prefix)
            return (game, runs)
        }
        let (twin, twinRuns) = try extra(7003, "Twin", "\"installscript\" { \"run process\" { \"Helper\" { \"HasRunKey\" \"HKEY_LOCAL_MACHINE\\\\Software\\\\Solo\" \"process 1\" \"%INSTALLDIR%\\\\helper.exe\" } } }", "helper.exe")
        let (triplet, tripletRuns) = try extra(7004, "Triplet", "\"installscript\" { \"run process\" { \"Copy\" { \"HasRunKey\" \"HKEY_LOCAL_MACHINE\\\\Software\\\\Triplet\" \"process 1\" \"%INSTALLDIR%\\\\Setup.exe\" } } }", "Setup.exe")
        let (other, otherRuns) = try extra(7005, "Other", "\"installscript\" { \"run process\" { \"Own\" { \"HasRunKey\" \"HKEY_LOCAL_MACHINE\\\\Software\\\\Other\" \"process 1\" \"%INSTALLDIR%\\\\own.exe\" } } }", "own.exe")
        DockInstallers.setRunsNext(7003, false, prefix: prefix); DockInstallers.setRunsNext(7004, false, prefix: prefix); DockInstallers.setRunsNext(7005, false, prefix: prefix)
        require(twinRuns.count == 1 && tripletRuns.count == 1 && otherRuns.count == 1, "the other games each have one own program")
        // Reset: the records go, the choice turns to Run, and the installer runs at that start.
        // madeira-bcd: what the installers put in moves into a backup first (DockReset.swift;
        // this prefix has none of it, so nothing moves).
        DockInstallers.setRequest(7002, .reset, prefix: prefix)
        DockInstallers.prepare(solo, drive: drive, prefix: prefix, others: [solo, twin, triplet, other], has32Bit: true, hasMsiexec: true, fusionSource: nil)
        soloSystem = (try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)) ?? ""
        let rerun = (try? String(contentsOf: drive.appendingPathComponent("madeira-dock-installers.cmd"), encoding: .utf8)) ?? ""
        require(logged("[dock-reset] app=7002 reset: installed components moved to the backup, records removed, choice=run programs=setup values=2 shared-kept=1") &&
                DockInstallScripts.recorded(setupRun, in: soloSystem) == nil && DockInstallScripts.marked(sharedRun, in: soloSystem),
                "Reset removes only the game's own records; the shared redistributable stays recorded")
        require(logged("[dock-reset] app=7002 clean sign-out=0 moved=0 entries=0 keys=0 values=0 template-keys=0 backup=Documents/madeira-reset-backup/") &&
                FileManager.default.fileExists(atPath: base.appendingPathComponent("madeira-reset-backup").path),
                "Reset backs up the registry next to the prefix and moves nothing the installers did not put in")
        let shareLedger = DockInstallLedger.load(prefix: prefix)
        require(logged("[dock-reset] app=7002 also app=7003 programs=helper values=2: records removed, choice=run") &&
                logged("[dock-reset] app=7002 also app=7004 programs=copy values=2: records removed, choice=run") && !logged("also app=7005") &&
                DockInstallScripts.recorded(twinRuns[0], in: soloSystem) == nil && DockInstallScripts.recorded(tripletRuns[0], in: soloSystem) == nil &&
                DockInstallScripts.marked(otherRuns[0], in: soloSystem) && shareLedger.runsNext(7003) && shareLedger.runsNext(7004) && !shareLedger.runsNext(7005),
                "the reset's installs go back to Run for games under the same key or with the same installer, not for others")
        require(DockInstallers.script != nil && rerun.contains("echo start 1 setup") && !DockInstallLedger.load(prefix: prefix).runsNext(7002) &&
                DockInstallLedger.load(prefix: prefix).requests == nil, "after Reset the installer runs at that start, then the choice is Skip again")

        // Fixture batch for the optional real cmd.exe run: stand-in programs under @DIR@.
        func fixture(_ name: String, _ file: String) -> SteamInstallProcess {
            SteamInstallProcess(run: SteamInstallRun(name: name, hive: .machine, key: "Software\\Fixture\\" + name, value: 1),
                                executable: "@DIR@\\" + file, arguments: "/quiet")
        }
        let real = DockInstallScripts.batch([fixture("ok", "ok.cmd"), fixture("negative", "negative.cmd"), fixture("restart", "restart.cmd"), fixture("fails", "fails.cmd")],
                                            resultFile: "@DIR@\\result.txt", services: .start("@DOCK@"))
        try Data(real.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/null"))

        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all Dock installer Swift checks")
    }
}
'''
launch = dock[dock.index('    static func launchArguments('):]
launch = launch[:launch.index('\n    }\n') + 7]
launch_src = ('enum MadeiraDockLaunch {\n    static let executable = MadeiraDock.executable\n' + launch +
              '    static func arguments(_ installers: String?) -> String { launchArguments(width: 1280, height: 720, installers: installers) }\n}\n')

with tempfile.TemporaryDirectory(prefix='madeira-dock-installers-') as tmp:
    tmp = Path(tmp)
    (tmp / 'stubs.swift').write_text(stubs + launch_src, encoding='utf-8')
    (tmp / 'checks.swift').write_text(checks, encoding='utf-8')
    exe = tmp / 'check'
    batch_text = ''
    if not Path(SWIFTC).exists() and not shutil.which(SWIFTC):
        # The compiled checks need a Swift toolchain; without one only the static rules and
        # the C part run. --require-swift turns a missing compiler into a failure.
        if '--require-swift' in sys.argv:
            require(False, 'Swift compiler available (--require-swift)')
        else:
            print('SKIP: Swift compiler unavailable; the compiled installer checks did not run')
        build = None
    else:
        build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-o', str(exe),
                                str(tmp / 'stubs.swift'), str(tmp / 'checks.swift'), str(app / 'DockInstallers.swift'),
                                str(app / 'DockReset.swift'), str(app / 'DockGameSession.swift')])
        require(build.returncode == 0, 'production installer Swift compiles on the host')
    if build is not None and build.returncode == 0:
        run = subprocess.run([str(exe), str(tmp / 'fixture.cmd')], env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))
        require(run.returncode == 0, 'installer checks pass under AddressSanitizer')
        batch_text = (tmp / 'fixture.cmd').read_text() if (tmp / 'fixture.cmd').exists() else ''

    # ---- madsync_enabled() with the production madeira_cfg.h
    fn = madsync[madsync.index('int madsync_enabled(void)'):]
    fn = fn[:fn.index('\n}\n') + 3]
    (tmp / 'm.c').write_text('#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n#include "madeira_cfg.h"\n' + fn +
                             'int main(void) { int a = madsync_enabled(); int b = madsync_enabled(); printf("madsync=%d\\n", a && b); return a != b; }\n')
    cc = subprocess.run([CC, '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-fsanitize=address,undefined',
                         '-I', str(root / 'build'), str(tmp / 'm.c'), '-o', str(tmp / 'm')])
    require(cc.returncode == 0, 'madsync_enabled() compiles with the production madeira_cfg.h')
    if cc.returncode == 0:
        docs = tmp / 'docs'; docs.mkdir()

        def madsync_run(cfg=None, session=None):
            (docs / 'madeira.cfg').unlink(missing_ok=True)
            if cfg is not None:
                (docs / 'madeira.cfg').write_text(cfg)
            env = {k: v for k, v in os.environ.items() if k != 'MADEIRA_MADSYNC_SESSION'}
            env.update(MADEIRA_DOCS_DIR=str(docs), HOME=str(tmp))
            if session is not None:
                env['MADEIRA_MADSYNC_SESSION'] = session
            out = subprocess.run([str(tmp / 'm')], env=env, capture_output=True, text=True)
            return int(re.search(r'madsync=(\d)', out.stdout).group(1)), out.stderr

        on, log = madsync_run()
        require(on == 0 and 'disabled' in log and 'off for this session' not in log, 'no madeira.cfg, no session switch: madsync off (fastsync is the default)')
        require(madsync_run('inproc-sync = 1\n')[0] == 1 and madsync_run('other = 1\n')[0] == 0, 'madsync only with inproc-sync = 1')
        require(madsync_run('inproc-sync = 0\n')[0] == 0, 'inproc-sync = 0 still turns it off')
        on, log = madsync_run('inproc-sync = 1\n', session='0')
        require(on == 0 and '[madsync] off for this session (MADEIRA_MADSYNC_SESSION=0' in log, 'MADEIRA_MADSYNC_SESSION=0: off for this session, logged')
        require(all(madsync_run('inproc-sync = 1\n', session=v)[0] == 1 for v in ('1', '', '00', 'off', '0 ')), 'any other session value leaves madsync on')
        require(madsync_run('inproc-sync = 0\n', session='1')[0] == 0, 'the session switch never turns madsync on')

# ---- optional: run the generated batch with Windows cmd.exe (WSL interop)
cmd = shutil.which('cmd.exe') or ('/mnt/c/Windows/System32/cmd.exe' if Path('/mnt/c/Windows/System32/cmd.exe').exists() else None)
staged = app / 'arm64ec-windows/dockhost.exe'
if batch_text and cmd and shutil.which('wslpath'):
    win_temp = subprocess.run([cmd, '/d', '/c', 'echo %TEMP%'], capture_output=True, text=True, cwd='/mnt/c').stdout.strip()
    work_win = win_temp + '\\madeira-dock-installers-%d' % os.getpid()
    work = Path(subprocess.run(['wslpath', '-u', work_win], capture_output=True, text=True).stdout.strip())
    work.mkdir(parents=True, exist_ok=True)
    try:
        for name, code in [('ok', 0), ('negative', -9), ('restart', 3010), ('fails', 1603)]:
            (work / (name + '.cmd')).write_text('@exit /b %d\r\n' % code, newline='')

        def run(dock_win):
            (work / 'result.txt').unlink(missing_ok=True)
            (work / 'run.cmd').write_text(batch_text.replace('@DIR@', work_win).replace('@DOCK@', dock_win), newline='')
            subprocess.run([cmd, '/d', '/c', 'call', work_win + '\\run.cmd'], cwd='/mnt/c', capture_output=True, text=True, timeout=120)
            return [l.strip() for l in (work / 'result.txt').read_text(errors='replace').replace('\r', '').split('\n') if l.strip()]

        programs = ['start 1 ok', 'exit 1 0', 'start 2 negative', 'exit 2 -9', 'start 3 restart', 'exit 3 3010', 'start 4 fails', 'exit 4 1603', 'end']
        lines = run(work_win + '\\missing-dockhost.exe')
        require(lines == ['begin 4', 'services failed'] + programs, f'cmd.exe ran the batch: statuses 0/-9/3010/1603 reported; a service step that cannot run records "services failed" ({lines})')
        if staged.exists():
            shutil.copy(staged, work / 'dockhost.exe')
            lines = run(work_win + '\\dockhost.exe')
            require(lines[:2] == ['begin 4', 'services already'] and lines[2:] == programs,
                    f'with the staged dockhost.exe --start-services (connect only on Windows): "services already" ({lines[:2]})')
        else:
            print('SKIP: dockhost.exe not staged (build/madeira-dock/build.sh); service step checked with a missing executable only')
    finally:
        shutil.rmtree(work, ignore_errors=True)
else:
    print('SKIP: cmd.exe not reachable; batch flow checked textually only')

if failures:
    print(f'FAILURES: {failures}')
    sys.exit(1)
print('PASS: all Dock installer checks; device execution still required')
