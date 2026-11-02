#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Compile LogSummary with Madeira Dock's report parser; synthetic logs only.

The lines below copy the shape of a real CS2 session (2026-10-25): the JIT pool
shrunk to 560 MB at launch, v8.dll failed to load once the pool ran out, and
cs2.exe ended itself with exit code 1 while the Valve logo stayed on screen.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile
root = Path(__file__).resolve().parents[2]
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
dock = (root / 'app/Madeira/MadeiraDock.swift').read_text()
report = dock[dock.index('    struct Report {'):dock.index('    @MainActor private static var lastReport =')]
summary = (root / 'app/Madeira/LogSummary.swift').read_text()
checks = r'''
let cs2 = #"""
[22:02:13.263] [INFO] [build] v0.1.3 (4)
[22:02:40.904] [ERR] ml1036: no hole fits a 896MB pool — SHRINKING to 560MB (the alternative is fatal)
[22:02:41.548] [OK] JIT pool: RX=0x148000000, RW=0x7000000000, size=560MB
[22:02:41.600] [INFO] [WineProc] Target exe: C:\madeira\dockhost.exe
[jit-pool] image 0x119810000+0x70000 (?) → pool 0x148004000 used=0x78000/0x23000000 tramp+0x4000
0024:err:module:load_dll [dll-missing] rev=ml336 #1 L"winemac.drv" status=c0000135 -- note
0024:err:module:load_dll [dll-missing] ml718 UNCAPPED L"winemac.drv" status=c0000135 (subsystem dependency)
0024:err:module:load_dll [dll-missing] rev=ml336 #2 L"winex11.drv" status=c0000135 -- note
[srv-own] new_thread tid=008c pid=0088 requester=0024 request_unixfd=-1 rev=ml586
008c:err:process:NtCreateUserProcess NtCreateUserProcess: image=L"C:\\Program Files (x86)\\Steam\\steamapps\\common\\Counter-Strike Global Offensive\\game\\bin\\win64\\cs2.exe" cmdline=L"x"
[session-log] Steam game cs2.exe: logs/cs2.exe-2026-10-25_22-02-51.txt
[22:02:52.654] [INFO] [dock-report] launch-client-error=0
[srv-own] new_thread tid=00ac pid=00a8 requester=008c request_unixfd=-1 rev=ml586
[srv-own] new_thread tid=00b0 pid=00a8 requester=00ac request_unixfd=-1 rev=ml586
00b0:err:module:load_dll [dll-missing] rev=ml336 #9 L"C:\\windows\\system32\\gameoverlayrenderer64.dll" status=c000007b -- note
[jit-pool] tail BIG: granting 0x8000000 (tail_resv=0x2008000) rev=ml480
[jit-pool] EXHAUSTED (image 0x73f5f00000+0x3059000): want=0x3060000 bump=0x17664000/0x23000000 tail_resv=0xa008000 freelist=0 — FAILING the load
00ac:err:module:load_dll [dll-missing] rev=ml336 #15 L"v8.dll" status=c0000017 -- note
[22:02:59.001] [INFO] tick
00ac:err:process:NtTerminateProcess NtTerminateProcess(handle=0xffffffffffffffff, exit_code=0x1) syscalls=0 unix_calls=14904
[22:03:05.120] [INFO] [frontend] graceful close requested
[22:03:10.898] [INFO] [dock-report] probe-result=0
"""#
assert(LogSummary.mb(UInt64.max) == 17592186044416)
let f = LogSummary.facts(lines: cs2.split(separator: "\n", omittingEmptySubsequences: false))
assert(f.sawSession && f.game == "cs2.exe" && f.steamGame == "cs2.exe")
assert(f.smallPool && f.poolWantedMB == 896 && f.poolMB == 560)
assert(f.exhausted == 1 && f.exhaustedWant == 0x3060000 && f.poolPeak == 0x17664000 && f.poolTotal == 0x23000000)
assert(f.tailGrants == [0x8000000])
assert(f.processes.count == 1 && f.processes[0].image == "cs2.exe" && f.processes[0].pid == "00a8")
assert(f.processes[0].exitCode == 1 && f.processes[0].endedAt == "22:02:59")
assert(f.harmlessMissing == 2)
assert(f.missing.count == 2)
assert(f.missing[0].name == "gameoverlayrenderer64.dll" && f.missing[0].status == "c000007b" && f.missing[0].program == "cs2.exe")
assert(f.missing[1].name == "v8.dll" && f.missing[1].status == "c0000017" && f.missing[1].program == "cs2.exe")
assert(f.quitAsked == "22:03:05" && !f.forceClosed)
assert(f.dock["launch-client-error"] == "0" && f.dock["probe-result"] == "0")
let text = LogSummary.text(f, source: "test")
for needle in ["Program: cs2.exe (Steam, through Madeira Dock)", "got 560 MB instead of 896 MB", "pool-split = 1",
               "ran out 1x (largest request 48 MB)", "v8.dll could not be loaded: out of memory (in cs2.exe)",
               "cs2.exe ended itself with exit code 1 around 22:02:59", "Quit game was pressed at 22:03:05",
               "gameoverlayrenderer64.dll (wrong architecture) - cs2.exe", "2 known harmless ones skipped",
               "JIT pool: 560 MB, peak use 374 MB of 560 MB, largest code cache 128 MB", "Steam launch: accepted, Madeira Dock result 0"] {
    if !text.contains(needle) { print(text); fatalError("missing: \(needle)") }
}
assert(!text.contains("v8.dll -") && !text.contains("winemac"))
assert(!text.contains("Madeira Dock: "))

// A Windows error code, a Dock refusal, and Force close.
let crashed = LogSummary.facts(lines: [
    "[WineProc] Target exe: C:\\game\\game.exe",
    "[srv-own] new_thread tid=0020 pid=0010 requester=0000",
    "0020:err:process:NtCreateUserProcess NtCreateUserProcess: image=L\"C:\\\\game\\\\game.exe\" cmdline=L\"\"",
    "[srv-own] new_thread tid=0030 pid=0028 requester=0020",
    "0030:err:process:NtTerminateProcess NtTerminateProcess(handle=0xffffffffffffffff, exit_code=0xc0000005) syscalls=0",
    "[12:00:00.000] [INFO] [dock-report] launch-client-error=22",
    "[12:00:30.000] [WARN] [frontend] force close: the game ignored Quit game",
])
let crashedText = LogSummary.text(crashed, source: "test")
assert(crashed.game == "game.exe" && crashed.forceClosed)
assert(crashedText.contains("game.exe ended itself with Windows error 0xC0000005"))
assert(crashedText.contains("Madeira was force-closed") && crashedText.contains("Steam launch: refused, error 22"))
assert(crashedText.contains("Madeira Dock: "))

// A game folder with spaces that hands over to Steam: the program is the game, not "C:\Program".
let spaced = LogSummary.facts(lines: [
    "[WineProc] Target exe: C:\\Program Files (x86)\\Steam\\steamapps\\common\\Fallout New Vegas\\FalloutNV.exe (bundle=aarch64-windows)",
    "[srv-own] new_thread tid=0020 pid=0010 requester=0000",
    "[srv-own] new_thread tid=0030 pid=0028 requester=0020",
    "0020:err:process:NtCreateUserProcess NtCreateUserProcess: image=L\"C:\\\\Program Files (x86)\\\\Steam\\\\steam.exe\" cmdline=L\"\"",
    "[WineProc] the main process exited while 1 child process(es) it started still run (steam.exe); the session ends with it (MADEIRA_WAIT_CHILDREN=1 keeps it while they run)",
])
assert(spaced.game == "FalloutNV.exe")
assert(LogSummary.text(spaced, source: "test").contains("The game started Steam and closed itself"))
assert(!text.contains("started Steam and closed itself"))

// A game's crash address, Wine's fixme notes left out, and Madeira closing after iPadOS refused a program's code.
let faulted = LogSummary.facts(lines: [
    "[srv-own] new_thread tid=0020 pid=0010 requester=0000",
    "0020:err:process:NtCreateUserProcess NtCreateUserProcess: image=L\"C:\\\\Games\\\\FalloutNV.exe\" cmdline=L\"\"",
    "[srv-own] new_thread tid=0108 pid=0028 requester=0020",
    "0100:fixme:rawinput:NtUserRegisterRawInputDevices Unhandled flags 0x230 for device 0.",
    "wine: Unhandled page fault on write access to 00000000 at address 00B57AA9 (thread 0108), starting debugger...",
    "0108:err:process:NtTerminateProcess NtTerminateProcess(handle=0xffffffffffffffff, exit_code=0xc000001d) syscalls=0",
    "[exec-recover] pg=0x13daa4000 fault=0x13daa5d9c mprotect_rx=-1(errno=13) reuse-cancel=0 retry#1 pool-rx",
    "[redeliv] terminating process rev=ml465",
    "[12:00:00.000] [ERR] [dock-start-program] app=22380 launcher=FalloutNVLauncher.exe program=Nope.exe failed: Nope.exe is not in the game's folder",
])
let faultedText = LogSummary.text(faulted, source: "test")
for needle in ["FalloutNV.exe crashed: page fault on write access to 00000000 at address 00B57AA9.",
               "Madeira closed: iPadOS refused to run a program's code.", "Game details > Steam > Steam starts",
               "Windows error 0xC000001D (an instruction this CPU lacks: try Game details > Compatibility > AVX and AVX2)",
               "Steam starts: the chosen program was not put in place (Nope.exe is not in the game's folder)"] {
    if !faultedText.contains(needle) { print(faultedText); fatalError("missing: \(needle)") }
}
assert(!faultedText.contains("Unhandled exception") && !faultedText.contains("fixme"))
assert(!text.contains("Madeira closed:") && !text.contains("crashed:"))

// Fatal startup failures can occur before Wine logs its target or starts a process.
let poolFailed = LogSummary.facts(lines: [
    "[12:00:00.000] [ERR] JIT pool allocation FAILED — not starting Wine.",
])
let poolFailedText = LogSummary.text(poolFailed, source: "test")
assert(poolFailed.sawSession && poolFailedText.contains("The JIT pool could not be allocated, so Wine was not started."))
assert(!poolFailedText.contains("Problems found: none"))
let windowFailed = LogSummary.facts(lines: [
    "[wow-window] session armed: a 32-bit process is expected",
    "[wow-window] main-process reserve FAILED 0xc0000017 — a 32-bit main image cannot run without a guest window; terminating this process",
])
let windowFailedText = LogSummary.text(windowFailed, source: "test")
assert(windowFailed.sawSession && windowFailedText.contains("A 32-bit program could not reserve its 4 GB guest-memory window."))
assert(!windowFailedText.contains("Problems found: none") && !windowFailedText.contains("entitlement"))
for refusal in [
    "[wow-window] refused: map too small (ends at 0xfc0000000, MADEIRA_WOW_MIN_MAP_GB=64)",
    "[wow-window] refused: map too small (6405 MB free VA; a window needs 4096 MB plus MADEIRA_WOW_MIN_FREE_GB=8 left over)",
    "[wow-window] refused: map too small for another window (1 of at most 1 held; MADEIRA_WOW_SMALL_VA_SLOTS)",
] {
    let refused = LogSummary.facts(lines: [refusal])
    assert(refused.sawSession && LogSummary.text(refused, source: "test").contains("could not reserve its 4 GB guest-memory window"))
}
// A rejected candidate slot is normal when a later slot works.
let healthyWindow = LogSummary.facts(lines: [
    "[WineProc] Target exe: C:\\Games\\game.exe",
    "[wow-window] B=0x7100000000 REJECTED: the 4GB range is not free",
    "[wow-window] B=0x7200000000: reserved exactly 4GB; guard BORROWED from the inaccessible neighbour",
    "[wow-window] main-process window reserved (i386 main image)",
])
let healthyWindowText = LogSummary.text(healthyWindow, source: "test")
assert(healthyWindowText.contains("Problems found: none") && !healthyWindowText.contains("could not reserve"))
assert(!text.contains("could not be allocated") && !text.contains("could not reserve"))

// A launch with no session leaves the last summary alone; a file is read across 1 MB chunks.
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let empty = dir.appendingPathComponent("empty.txt"), logFile = dir.appendingPathComponent("madeira-log.txt")
try! "[10:00:00.000] [INFO] [build] v0.1.3 (4)\n".write(to: empty, atomically: true, encoding: .utf8)
assert(!LogSummary.write(from: empty, source: "test"))
assert(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(LogSummary.fileName).path))
let startup = dir.appendingPathComponent("startup.txt")
try! "[12:00:00.000] [ERR] JIT pool allocation FAILED — not starting Wine.\n".write(to: startup, atomically: true, encoding: .utf8)
assert(LogSummary.write(from: startup, source: "test"))
let startupWritten = try! String(contentsOf: dir.appendingPathComponent(LogSummary.fileName), encoding: .utf8)
assert(startupWritten.contains("The JIT pool could not be allocated, so Wine was not started."))
let padding = String(repeating: "[xp] filler line that is not a marker\n", count: 40000)
try! (padding + cs2 + "\n").write(to: logFile, atomically: true, encoding: .utf8)
assert(LogSummary.facts(fromFileAt: logFile)!.processes.first?.exitCode == 1)
assert(LogSummary.write(from: logFile, source: "madeira-log.txt (this session)"))
let written = try! String(contentsOf: dir.appendingPathComponent(LogSummary.fileName), encoding: .utf8)
assert(written.hasPrefix("=== Madeira session summary ===") && written.contains("v8.dll could not be loaded"))
// Get Help from Claude: a summarized game session is also kept as madeira-last-game-log.txt,
// and a later run with no game leaves it alone.
let kept = dir.appendingPathComponent(LogSummary.gameLogName)
assert(FileManager.default.contentsEqual(atPath: kept.path, andPath: logFile.path))
try! "[10:00:00.000] [INFO] [build] v0.1.3 (5)\n".write(to: logFile, atomically: true, encoding: .utf8)
assert(!LogSummary.write(from: logFile, source: "madeira-log.txt (no game)"))
assert((try! String(contentsOf: kept, encoding: .utf8)).contains("v8.dll"))
assert(LogSummary.write(from: kept, source: "kept") && FileManager.default.fileExists(atPath: kept.path))
print("PASS: log summary finds fatal startup failures, the small JIT pool, the pool running out, out-of-memory and wrong-architecture DLLs, exit codes per program, Quit and Force close, and Madeira Dock's result")
'''
if not Path(SWIFTC).exists():
    if '--require-swift' in sys.argv: sys.exit('FAIL: Swift compiler unavailable')
    print('SKIP: Swift compiler unavailable locally'); sys.exit(0)
with tempfile.TemporaryDirectory(prefix='madeira-log-summary-') as directory:
    source = Path(directory) / 'main.swift'; binary = Path(directory) / 'check'
    source.write_text('import Foundation\nenum MadeiraDock {\n' + report + '\n}\n'
                      + summary.replace('import Foundation\n', '', 1) + '\n' + checks)
    subprocess.run([SWIFTC, str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary), directory], check=True)
