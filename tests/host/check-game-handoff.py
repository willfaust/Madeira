#!/usr/bin/env python3
"""Exercise the production Steam gate, guest-fault guard and saved launch request."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'


def block(text, header):
    start = text.index(header)
    brace = text.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


process = (root / 'build/ntdll-unix/process_ios.c').read_text()
gate_start = process.index('        {\n            extern void wine_steam_run_requested(')
gate = process[gate_start:process.index('        static const char * const blocked_names[]', gate_start)]
assert 'found && wine_steam_run_requested' in gate
bridge = (app / 'WineProcessBridge.m').read_text()
signals = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()
fault_start = signals.index('    {\n        extern void *ios_jit_rx_base_global;',
                            signals.index('/* A 32-bit program\'s call or jump'))
fault = block(signals[fault_start:], '    {')
native = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint16_t WCHAR;
#define STATUS_ACCESS_DENIED 1
#define dprintf(...) ((void)0)
#define ERR(...) ((void)0)
'''
native += block(process, 'static int ios_image_name_is(')
native += '\nstatic uint32_t g_steam_run_app; static uint64_t g_launch_exit;\n'
hooks = ''
for name in ['void wine_steam_run_requested(', 'int wine_steam_run_request(', 'void wine_exit_status_reset(']:
    hooks += block(bridge, name) + '\n'
native += '''
struct string { const WCHAR *Buffer; unsigned Length; };
struct parameters { struct string CommandLine, ImagePathName; };
static int gate(struct parameters *params) {
''' + gate + '\nreturn 0; }\n' + hooks
native += r'''
static struct { int WowTebOffset; } teb;
#define NtCurrentTeb() (&teb)
struct context { uintptr_t pc, lr; };
#define PC_sig(c) ((c)->pc)
#define LR_sig(c) ((c)->lr)
void *ios_jit_rx_base_global = (void *)0x100000;
size_t ios_jit_pool_size_global = 0x1000;
static int ios_jit_low_contains(uintptr_t p) { return p >= 0x300000 && p < 0x301000; }
static uintptr_t fault_pc(uintptr_t pc, uintptr_t lr, uintptr_t address, int wow) {
    struct context state = {pc, lr}, *context = &state;
    struct { void *si_addr; } info = {(void *)address}, *siginfo = &info;
    teb.WowTebOffset = wow;
''' + fault + '\nreturn state.pc; }\n'
native += r'''
static void check(const char *image, const char *command, const char *dock, const char *enabled,
                  uint32_t expected) {
    WCHAR im[256], cl[1024];
    size_t i;
    for (i = 0; image[i]; i++) im[i] = (unsigned char)image[i];
    struct parameters p = {.ImagePathName = {im, i * 2}};
    for (i = 0; command[i]; i++) cl[i] = (unsigned char)command[i];
    p.CommandLine = (struct string){cl, i * 2};
    if (dock) setenv("MADEIRA_DOCK_SESSION", dock, 1); else unsetenv("MADEIRA_DOCK_SESSION");
    if (enabled) setenv("MADEIRA_DOCK_STEAM_RUN", enabled, 1); else unsetenv("MADEIRA_DOCK_STEAM_RUN");
    wine_exit_status_reset();
    assert(gate(&p) == (expected != 0));
    uint32_t actual = 0;
    assert(wine_steam_run_request(&actual) == (expected != 0) && actual == expected);
    wine_exit_status_reset();
    assert(!wine_steam_run_request(NULL));
}
int main(void) {
'''
cases = [
    ('steam.exe', 'steam.exe steam://run/212910', '1', None, 212910),
    ('C:\\Steam\\STEAM.EXE', '"steam.exe" "STEAM://RUNGAMEID/202970"', '1', '1', 202970),
    ('steam.exe', 'steam://run/202990//-flag', '1', None, 202990),
    ('steam.exe', 'steam://run/4294967295', '1', None, 4294967295),
    ('steam.exe', 'steam://run/4294967296', '1', None, 0),
    ('steam.exe', 'steam://run/12345678901234567890', '1', None, 0),
    ('steam.exe', 'steam://run/0 steam://run/212910', '1', None, 212910),
    ('steam.exe', 'steam://run/0', '1', None, 0),
    ('steam.exe', 'steam://run/212910abc', '1', None, 0),
    ('steam.exe', 'badsteam://run/212910', '1', None, 0),
    ('steam.exe', 'steam://run/', '1', None, 0),
    ('steam.exe', 'steam://run/212910', None, None, 0),
    ('steam.exe', 'steam://run/212910', '0', None, 0),
    ('steam.exe', 'steam://run/212910', '1', '0', 0),
    ('game.exe', 'steam://run/212910', '1', None, 0),
]
for image, command, dock, enabled, expected in cases:
    args = [json.dumps(s) if s is not None else 'NULL' for s in [image, command, dock, enabled]]
    native += 'check(' + ', '.join(args) + f', {expected}u);\n'
native += r'''
int enabled = !getenv("MADEIRA_WOW_LOW_RIP_GUEST") || strcmp(getenv("MADEIRA_WOW_LOW_RIP_GUEST"), "0");
assert(fault_pc(0, 0x100104, 0, 1) == (enabled ? 0x100100 : 0));
assert(fault_pc(1, 0x300104, 1, 1) == (enabled ? 0x300100 : 1));
assert(fault_pc(0, 0x101000, 0, 1) == (enabled ? 0x100ffc : 0));
assert(fault_pc(0, 0x100000, 0, 1) == 0);
assert(fault_pc(0, 0x300000, 0, 1) == 0);
assert(fault_pc(0, 0x100104, 1, 1) == 0);
assert(fault_pc(0, 0x100104, 0, 0) == 0);
assert(fault_pc(0x10000, 0x100104, 0x10000, 1) == 0x10000);
assert(fault_pc(0, 3, 0, 1) == 0);
assert(fault_pc(0, 0x200000, 0, 1) == 0);
puts("PASS Steam gate, bridge reset and WoW64 fault boundaries");
}
'''
swift = '''import Foundation
let suite = "madeira.test." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
''' + block((app / 'SavesAndShortcuts.swift').read_text(), 'enum NextSteamApp {').replace('UserDefaults.standard', 'defaults')
swift += r'''
let key = "madeira.nextSteamApp"
NextSteamApp.set(212910)
precondition(NextSteamApp.take() == 212910 && NextSteamApp.take() == nil)
for app in [0, -1, Int(UInt32.max) + 1] {
    NextSteamApp.set(app); precondition(NextSteamApp.take() == nil)
}
for age in [1801.0, -3600.0, Double.nan, Double.infinity] {
    defaults.set(["app": 212910, "at": Date().timeIntervalSince1970 - age], forKey: key)
    precondition(NextSteamApp.take() == nil && NextSteamApp.take() == nil)
}
defaults.set(["app": "bad", "at": 0], forKey: key)
precondition(NextSteamApp.take() == nil)
print("PASS one-use Steam launch request, expiry and invalid saved values")
'''
content = (app / 'ContentView.swift').read_text()
shortcut = block(content, 'private func launchPendingShortcut()')
assert shortcut.index('_ = NextSteamApp.take()') < shortcut.index('launchShortcut(exe)')
assert 'LibraryModel.sessionsThisRun == 0' in shortcut
with tempfile.TemporaryDirectory(prefix='madeira-game-handoff-') as folder:
    folder = Path(folder)
    (folder / 'test.c').write_text(native)
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                    str(folder / 'test.c'), '-o', str(folder / 'native')], check=True)
    subprocess.run([str(folder / 'native')], env={**os.environ, 'MADEIRA_WOW_LOW_RIP_GUEST': '1'}, check=True)
    subprocess.run([str(folder / 'native')], env={**os.environ, 'MADEIRA_WOW_LOW_RIP_GUEST': '0'}, check=True)
    (folder / 'main.swift').write_text(swift)
    subprocess.run(['swiftc', str(folder / 'main.swift'), '-o', str(folder / 'swift')], check=True)
    subprocess.run([str(folder / 'swift')], check=True)
