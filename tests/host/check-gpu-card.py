#!/usr/bin/env python3
"""Graphics card the game sees (app/Madeira/GPUCards.swift).

One choice per game names the same card in DXGI and Direct3D 9 (DXMT's
dxgi.custom* and d3d9.custom* options), in NVAPI (DXMT_ENABLE_NVEXT follows the
maker) and in Windows' own adapter, which win32u registers from
MADEIRA_GPU_VENDOR / MADEIRA_GPU_DEVICE / MADEIRA_GPU_NAME
(build/win32u-unix/sysparams_ios.c). A chosen card replaces the two NVIDIA
switches; without one nothing changes.

Checks the Swift table against win32u's list of identities a launch removes
again, the launch wiring, and compiles win32u's new functions on the host with
stubs and runs them.
"""
from pathlib import Path
import re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
cards = (app / 'GPUCards.swift').read_text(encoding='utf-8')
bcd = (app / 'LibraryBCD.swift').read_text(encoding='utf-8')
prefs = (app / 'LibraryPrefs.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
content = (app / 'ContentView.swift').read_text(encoding='utf-8')
bridge = (app / 'WineProcessBridge.m').read_text(encoding='utf-8')
pbx = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
sysparams = (root / 'build/win32u-unix/sysparams_ios.c').read_text(encoding='utf-8')
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def block(text, start):
    i = text.index(start)
    depth, j = 0, text.index('{', i)
    while True:
        if text[j] == '{':
            depth += 1
        elif text[j] == '}':
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
        j += 1


# The table.
VENDORS = {'appleVendor': 0x106b, 'nvidiaVendor': 0x10de, 'amdVendor': 0x1002, 'intelVendor': 0x8086}
rows = re.findall(r'GPUCard\(id: "([a-z0-9-]+)", title: "([^"]+)", vendor: (\w+), device: 0x([0-9a-f]{4}),\s*name: (nil|"[^"]*")',
                  cards)
table = [(i, VENDORS.get(v, -1), int(d, 16), None if n == 'nil' else n.strip('"')) for i, _, v, d, n in rows]
check(len(table) >= 6 and len({r[0] for r in table}) == len(table), f'{len(table)} cards with distinct ids')
check(all(v > 0 for _, v, _, _ in table), 'every card names a known vendor')
check(('nvidia-rtx3060', 0x10de, 0x2544, 'NVIDIA GeForce RTX 3060') in table,
      'the RTX 3060 card is the identity "Report an NVIDIA GPU" already reports')
check(('nvidia-7900gs', 0x10de, 0x0292, 'NVIDIA GeForce 7900 GS') in table and 'driver: "nv4_disp.dll"' in cards
      and 'static let olderNvidiaName = "NVIDIA GeForce 7900 GS"' in bcd,
      'the 7900 GS card is "Older NVIDIA card (Direct3D 9)"\'s identity, driver file included')
check(('apple', 0x106b, 0x0001, None) in table, "the Apple card uses the Metal name and win32u's default ids")
check('import Metal' not in cards and 'import SwiftUI' not in cards, 'GPUCards.swift is plain values (Foundation only)')

known = [(int(v, 16), int(d, 16)) for v, d in
         re.findall(r'\{ 0x([0-9a-f]{4}), 0x([0-9a-f]{4}) \}', block(sysparams, 'ios_known_gpus[] =') + '}')]
check((0x106b, 0x0001) in known and (0x10de, 0x2544) in known, "win32u's list has the two identities it had before")
missing = [(i, hex(v), hex(d)) for i, v, d, _ in table if (v, d) not in known]
check(not missing, f"every card is in win32u's ios_known_gpus, so a later launch removes its adapter (missing: {missing})")

# DXMT's options: the longest card must leave room under DXMT's 259 characters.
def dxmt_options(vendor, device, name, driver, names=True):
    out = []
    for api in ['dxgi', 'd3d9']:
        out += [f'{api}.customVendorId={vendor:04x}', f'{api}.customDeviceId={device:04x}']
    if driver:
        out.append(f'd3d9.customDriver={driver}')
    if names and name:
        out += [f'{api}.customDeviceDesc="{name}"' for api in ['dxgi', 'd3d9']]
    return out


longest = max(len(';'.join(dxmt_options(v, d, n, 'nv4_disp.dll' if i == 'nvidia-7900gs' else None))) for i, v, d, n in table)
check(longest <= 230, f'the longest card takes {longest} of DXMT_CONFIG\'s 259 characters')
without_dxgi = max(len(';'.join(o for o in dxmt_options(v, d, n, 'nv4_disp.dll' if i == 'nvidia-7900gs' else None)
                                 if not o.startswith('dxgi.customDeviceDesc'))) for i, v, d, n in table)
check(without_dxgi <= 180, f'without DXGI\'s name, {without_dxgi}: room for the game\'s own DXMT lines')
for rule in ['out.append("\\(api).customVendorId=\\(card.vendorHex)")', 'out.append("\\(api).customDeviceId=\\(card.deviceHex)")',
             'if let driver = card.driver { out.append("d3d9.customDriver=\\(driver)") }',
             'for api in ["dxgi", "d3d9"] { out.append("\\(api).customDeviceDesc=\\"\\(name)\\"") }',
             'String(format: "%04x", vendor)']:
    check(rule in cards, f'Swift builds the same options: {rule}')
envblock = block(cards, 'static func environment(')
check('("DXMT_ENABLE_NVEXT", card.isNVIDIA ? "1" : "0")' in envblock,
      'NVAPI follows the maker; "0" also keeps madeira.cfg\'s env line from turning it on (per-launch key)')
for name in ['MADEIRA_GPU_VENDOR', 'MADEIRA_GPU_DEVICE', 'MADEIRA_GPU_NAME']:
    check(f'"{name}"' in envblock and f'"{name}"' in cards.split('static let identityNames')[1].split('\n')[0],
          f'{name} is exported for a card and unset without one')

# Per game, and the launch.
check('gpuCardKey = "madeira.library.gpuCard"' in prefs and 'static func setGPUCard(' in prefs, 'LibraryPrefs keeps the choice per game')
apply = block(bcd, 'static func applyLibrary(')
check('let card = GPUCards.card(LibraryPrefs.gpuCard(path))' in apply
      and 'let nvidia = card == nil && LibraryPrefs.nvidia(path)' in apply
      and 'let olderNvidia = card == nil && LibraryPrefs.olderNvidia(path)' in apply
      and 'olderNvidia: olderNvidia, card: card, profile: profile)' in apply,
      'a library launch passes the card and turns both NVIDIA switches off for it')
check('D3D9Identity.syncGamePrefs(appID: appID, card: card)' in apply,
      "Fallout 3 / New Vegas prefs get the chosen card's name")
extras = block(bcd, 'static func applyExtras(')
check(extras.index('if olderNvidia {') < extras.index('if let card {') < extras.index('setenv("MADEIRA_DXMT_EXTRA"'),
      "the card's DXMT options go after both switches' and into MADEIRA_DXMT_EXTRA")
check('for name in GPUCards.identityNames { unsetenv(name) }' in extras, 'a launch without a card unsets win32u\'s names')
reassert = block(content, 'static func reassertBCDSwitches(')
check('if LibraryPrefs.nvidia(path), card == nil {' in reassert and 'GPUCards.environment(card, metalName: metalName)' in reassert,
      'after applyEnvironment the card\'s switches are set again, the NVIDIA switch\'s only without a card')
check('static let nameKeys = ["dxgi.customDeviceDesc", "d3d9.customDeviceDesc"]' in cards
      and 'for key in GPUCards.nameKeys where dxmtOptions.joined(separator: ";").utf16.count > 259 {' in content
      and content.index('for key in GPUCards.nameKeys') < content.index('setenv("DXMT_CONFIG"'),
      'past DXMT\'s limit the names are dropped (DXGI\'s first) before DXMT_CONFIG is set, not every option')
per_launch = block(bridge, 'static const char *const per_launch[] =')
for name in ['MADEIRA_GPU_VENDOR', 'MADEIRA_GPU_DEVICE', 'MADEIRA_GPU_NAME']:
    check(f'"{name}"' in per_launch and f'unsetenv("{name}");' in bridge, f'{name}: the game\'s choice wins over madeira.cfg and ends with the session')

# The page.
check('compatLabel("Graphics card the game sees"' in library and 'LibraryPrefs.setGPUCard(id, for: entry.windowsPath)' in library
      and 'ForEach(GPUCards.all, id: \\.id)' in library, 'Game details > Compatibility shows the picker')
check('.disabled(GPUCards.card(bcd.gpuCard) != nil)' in library, 'the NVIDIA switches are greyed out while a card is chosen')
check('gpuCard = LibraryPrefs.gpuCard(windowsPath) ?? ""' in library, 'the page reads the choice')
check(len([l for l in pbx.splitlines() if 'GPUCards.swift' in l]) == 4, 'GPUCards.swift is in the app target')

# prefsText, in Python: the same rules.
OURS = {n for _, _, _, n in table if n}


def prefs_text(text, wanted, metal):
    lines = text.split('\n'); changed = False
    for i, raw in enumerate(lines):
        cr = raw.endswith('\r'); line = raw[:-1] if cr else raw
        if not line.lower().startswith('sd3ddevice='):
            continue
        key = line.split('=', 1)[0]; cur = line[len(key) + 1:].strip('" \t')
        target = wanted if wanted is not None else (metal if cur in OURS else None)
        if not target or target == cur:
            continue
        lines[i] = f'{key}="{target}"' + ('\r' if cr else ''); changed = True
    return '\n'.join(lines) if changed else None


src = '[Display]\r\nsD3DDevice="Apple M4 GPU"\r\n'
amd = prefs_text(src, 'AMD Radeon RX 6700 XT', 'Apple M4 GPU')
check(amd == '[Display]\r\nsD3DDevice="AMD Radeon RX 6700 XT"\r\n', 'a card: its name, CRLF kept')
check(prefs_text(amd, 'AMD Radeon RX 6700 XT', 'Apple M4 GPU') is None, 'the same card again: nothing to write')
check(prefs_text(amd, None, 'Apple M4 GPU') == src, 'no card: the Metal name back over a card\'s name')
check(prefs_text('sD3DDevice="NVIDIA GeForce 7900 GS"\n', None, 'Apple M4 GPU') == 'sD3DDevice="Apple M4 GPU"\n',
      'no card: the older switch\'s name goes back too, as D3D9Identity did')
check(prefs_text('sD3DDevice="Something Else"\n', None, 'Apple M4 GPU') is None, 'no card: a name we did not write stays')
for rule in ['let target = wanted ?? (ours.contains(current) ? metalName : nil)',
             'guard let target, !target.isEmpty, target != current else { continue }', '(cr ? "\\r" : "")']:
    check(rule in cards, f'Swift has the same rule: {rule}')

# win32u's new functions, compiled and run on the host.
cc = shutil.which('cc') or shutil.which('clang') or shutil.which('gcc')
if cc:
    start = sysparams.index('static const struct { UINT16 vendor, device; } ios_known_gpus[] =')
    end = sysparams.index('/* Every game shares one prefix', start)
    harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned short UINT16; typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
static const char *gpu_device_name( UINT16 vendor, UINT16 device, const char *default_name )
{ return vendor == 0x10de && device == 0x2544 ? "NVIDIA GeForce RTX 3060" : default_name; }
''' + sysparams[start:end] + r'''
static int fails;
static void expect( const char *label, UINT16 v, UINT16 d, const char *name )
{
    UINT16 vendor, device; const char *n;
    ios_virtual_gpu_ids( &vendor, &device ); n = ios_virtual_gpu_name( vendor, device );
    if (vendor != v || device != d || strcmp( n, name )) { fails++; printf( "FAIL: %s: %04x:%04x %s\n", label, vendor, device, n ); }
    else printf( "PASS: %s\n", label );
}
int main(void)
{
    unsigned int i;
    expect( "win32u: no switch, Apple 106B:0001", 0x106b, 0x0001, "Madeira Display" );
    setenv( "DXMT_ENABLE_NVEXT", "1", 1 );
    expect( "win32u: Report an NVIDIA GPU, the RTX 3060", 0x10de, 0x2544, "NVIDIA GeForce RTX 3060" );
    setenv( "MADEIRA_GPU_VENDOR", "1002", 1 ); setenv( "MADEIRA_GPU_DEVICE", "73df", 1 );
    setenv( "MADEIRA_GPU_NAME", "AMD Radeon RX 6700 XT", 1 );
    expect( "win32u: a card wins over DXMT_ENABLE_NVEXT", 0x1002, 0x73df, "AMD Radeon RX 6700 XT" );
    unsetenv( "DXMT_ENABLE_NVEXT" ); unsetenv( "MADEIRA_GPU_NAME" );
    expect( "win32u: no name, the PCI table's", 0x1002, 0x73df, "Madeira Display" );
    setenv( "MADEIRA_GPU_DEVICE", "73dfz", 1 ); setenv( "MADEIRA_GPU_NAME", "X", 1 );
    expect( "win32u: a bad id is ignored, with its name", 0x106b, 0x0001, "Madeira Display" );
    setenv( "MADEIRA_GPU_VENDOR", "0", 1 ); setenv( "MADEIRA_GPU_DEVICE", "0001", 1 );
    expect( "win32u: vendor 0 is ignored", 0x106b, 0x0001, "Madeira Display" );
    setenv( "MADEIRA_GPU_VENDOR", "106b", 1 ); setenv( "MADEIRA_GPU_NAME", "Apple M4 GPU", 1 );
    expect( "win32u: the Apple card with the Metal name", 0x106b, 0x0001, "Apple M4 GPU" );
    for (i = 0; i < ARRAY_SIZE(ios_known_gpus); i++) printf( "%04x:%04x\n", ios_known_gpus[i].vendor, ios_known_gpus[i].device );
    return fails != 0;
}
'''
    with tempfile.TemporaryDirectory() as d:
        c, exe = Path(d) / 'gpu.c', Path(d) / 'gpu'
        c.write_text(harness)
        r = subprocess.run([cc, '-Wall', '-Werror', '-Wno-unused-function', str(c), '-o', str(exe)], capture_output=True, text=True)
        check(r.returncode == 0, "win32u's functions compile with -Wall -Werror" + (': ' + r.stderr if r.returncode else ''))
        if r.returncode == 0:
            r = subprocess.run([str(exe)], capture_output=True, text=True, env={})
            lines = r.stdout.splitlines()
            for line in lines:
                if line.startswith(('PASS', 'FAIL')):
                    print(line)
            check(r.returncode == 0, "win32u's functions behave")
            listed = {tuple(int(x, 16) for x in l.split(':')) for l in lines if re.fullmatch(r'[0-9a-f]{4}:[0-9a-f]{4}', l)}
            check(listed == set(known), 'the compiled list is the one parsed above')
else:
    print('SKIP: no C compiler')
for site in ['name = ios_virtual_gpu_name( pci.vendor, pci.device );',
             'snprintf( id->name, sizeof(id->name), "%s", ios_virtual_gpu_name( pci.vendor, pci.device ) );',
             'ios_forget_virtual_gpu( ios_known_gpus[i].vendor, ios_known_gpus[i].device );']:
    check(site in sysparams, f'win32u uses it: {site}')

# DXMT reads every key (submodule checked out).
dxgi, d3d9 = root / 'dxmt/src/dxgi/dxgi_options.cpp', root / 'dxmt/src/d3d9/d3d9_interface.cpp'
if dxgi.exists() and d3d9.exists():
    t, u = dxgi.read_text(encoding='utf-8'), d3d9.read_text(encoding='utf-8')
    check(all(f'"dxgi.{k}"' in t for k in ['customVendorId', 'customDeviceId', 'customDeviceDesc']), 'DXMT\'s DXGI reads its three keys')
    check(all(f'"d3d9.{k}"' in u for k in ['customVendorId', 'customDeviceId', 'customDeviceDesc']), 'DXMT\'s Direct3D 9 reads its keys')
else:
    print('SKIP: dxmt submodule not checked out')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
