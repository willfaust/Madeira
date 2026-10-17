#!/usr/bin/env python3
"""Exercise per-game desktop choices through the production launch and cfg code.

Uses check-frontend's host stubs to compile LibraryEntry, then links the actual
Objective-C environment-export loops from WineProcessBridge. Requires macOS,
Swift and cc; does not run Wine or build the app.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
frontend = root / "tests/host/check-frontend.py"
# Reuse only its declarations and production-source extraction, before tests run.
setup = frontend.read_text().split("swift += r'''", 1)[0]
scope = {"__file__": str(frontend)}
exec(compile(setup, str(frontend), "exec"), scope)
swift = scope["swift"]
bridge = scope["bridge"]
start = bridge.index("                static const char *const per_launch[] = {")
end = bridge.index("                {   /* madeira-bcd: the server's per-launch switches", start)
export = bridge[start:end]
cleanup = bridge[bridge.index("g_wine_running = 0;\n        /* ml1184"):]
cleanup = cleanup[:cleanup.index("// Stop wineserver")]
unsets = "\n".join(re.findall(r'unsetenv\("[A-Z0-9_]+"\);', cleanup))
native = r'''
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define LOG(...) ((void)0)
void madeira_host_apply_config(const char *global)
{
    NSString *text = [NSString stringWithUTF8String:global];
''' + export + r'''
}
void madeira_host_finish_session(void)
{
''' + unsets + r'''
}
'''
swift += r'''
@_silgen_name("madeira_host_apply_config")
func nativeApplyConfig(_ global: UnsafePointer<CChar>)
@_silgen_name("madeira_host_finish_session")
func finishSession()
func applyGlobal(_ text: String) { text.withCString { nativeApplyConfig($0) } }
var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print("\(condition ? "PASS" : "FAIL"): \(message)")
    if !condition { failures += 1 }
}
unsetenv("MADEIRA_CFG_GAME")
var game = LibraryEntry(title: "Windowed game", relativePath: "Games/A Game/game.exe", bits: 32)
game.resolution = "1280x720"
game.arguments = "-windowed \"-name=a b\""

// A missing launchMode is the persisted default, and must defeat a global 1.
setenv("MADEIRA_DESKTOP", "1", 1)
game.applyEnvironment()
applyGlobal("MADEIRA_DESKTOP=1\nMADEIRA_DESKTOP=1\n")
expect(env("MADEIRA_DESKTOP") == "0", "default direct mode wins over global desktop=1")
expect(env("MADEIRA_EXE") == "C:\\Games\\A Game\\game.exe"
       && env("MADEIRA_ARGS") == "-windowed \"-name=a b\"",
       "direct launch preserves the executable and quoted arguments")
finishSession()
expect(env("MADEIRA_DESKTOP") == nil, "session end clears desktop mode")
setenv("MADEIRA_DIRECT_WINDOW_SIZE", "1", 1)
finishSession()
expect(env("MADEIRA_DIRECT_WINDOW_SIZE") == nil, "session end clears the direct window resize opt-in")

game.launchMode = "desktop"
game.applyEnvironment()
applyGlobal("MADEIRA_DESKTOP=0\n")
expect(env("MADEIRA_DESKTOP") == "1", "desktop mode wins over global desktop=0")
expect(env("MADEIRA_EXE") == "explorer.exe"
       && env("MADEIRA_ARGS") == "/desktop=shell,1280x720 \"C:\\Games\\A Game\\game.exe\" -windowed \"-name=a b\"",
       "desktop launch preserves explorer, resolution, program and arguments")
finishSession()
expect(env("MADEIRA_DESKTOP") == nil, "desktop session does not leak into the next launch")

game.launchMode = "direct"
game.applyEnvironment()
applyGlobal("MADEIRA_DESKTOP=1\n")
expect(env("MADEIRA_DESKTOP") == "0", "an explicit direct launch after desktop stays direct")

// Advanced game cfg is intentionally last, matching every other per-game switch.
let cfg = URL(fileURLWithPath: CommandLine.arguments[1])
try "env.MADEIRA_DESKTOP = 1\n".write(to: cfg, atomically: true, encoding: .utf8)
setenv("MADEIRA_CFG_GAME", cfg.path, 1)
game.applyEnvironment()
applyGlobal("MADEIRA_DESKTOP=0\n")
expect(env("MADEIRA_DESKTOP") == "1", "advanced game cfg still wins over launch mode and global cfg")
finishSession()
unsetenv("MADEIRA_CFG_GAME")

// With no library launch, the developer interface keeps global last-line-wins.
applyGlobal("MADEIRA_DESKTOP=1\nMADEIRA_DESKTOP=0\n")
expect(env("MADEIRA_DESKTOP") == "0", "without a launch choice, the last global cfg line wins")
finishSession()
applyGlobal("MADEIRA_DESKTOP=1\n")
expect(env("MADEIRA_DESKTOP") == "1", "a later session can take its global desktop setting")
exit(failures == 0 ? 0 : 1)
'''
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    m = tmp / "config.m"
    obj = tmp / "config.o"
    s = tmp / "desktop.swift"
    exe = tmp / "desktop"
    m.write_text(native)
    s.write_text(swift)
    subprocess.run(["cc", "-fobjc-arc", "-Wall", "-Werror", "-c", str(m), "-o", str(obj)], check=True)
    subprocess.run(["swiftc", str(s), str(obj), "-framework", "Foundation", "-o", str(exe)], check=True)
    subprocess.run([str(exe), str(tmp / "game.cfg")], check=True)
